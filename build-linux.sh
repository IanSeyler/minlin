#!/usr/bin/env bash
#
# Build and boot a "naked" Linux kernel with a hand-written init, following
# https://nick.zoic.org/art/boot-naked-linux/
#
# Downloads the Linux v7.1 source zip, compiles a small static init.c (with
# musl when available), embeds it as the kernel's built-in initramfs, and
# configures a minimal x86-64 build for KVM microVMs (virtio-mmio, no PCI).

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
WORKDIR="${1:-$PWD/linux-src}"
KERNEL_DIR="$WORKDIR/linux"
JOBS="$(nproc)"
KERNEL_VERSION="7.1"
KERNEL_ZIP_URL="https://github.com/torvalds/linux/archive/refs/tags/v${KERNEL_VERSION}.zip"
KERNEL_ZIP="$SCRIPT_DIR/linux-${KERNEL_VERSION}.zip"

log() { printf '\n>>> %s\n' "$*"; }

check_deps() {
    local missing=()
    for tool in curl unzip make gcc bc flex bison mkfs.ext4 qemu-system-x86_64; do
        command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        echo "Missing required tools: ${missing[*]}" >&2
        echo "On Debian/Ubuntu: sudo apt install curl unzip build-essential bc flex bison e2fsprogs qemu-system-x86" >&2
        exit 1
    fi
}

fetch_kernel() {
    if [ -d "$KERNEL_DIR" ]; then
        log "Kernel source already present at $KERNEL_DIR, skipping download"
        return
    fi

    if [ ! -f "$KERNEL_ZIP" ]; then
        log "Downloading Linux v$KERNEL_VERSION into $KERNEL_ZIP"
        curl -L -o "$KERNEL_ZIP" "$KERNEL_ZIP_URL"
    else
        log "Zip already present at $KERNEL_ZIP, skipping download"
    fi

    log "Extracting kernel source into $KERNEL_DIR"
    unzip -q "$KERNEL_ZIP" -d "$WORKDIR"
    mv "$WORKDIR/linux-${KERNEL_VERSION}" "$KERNEL_DIR"
}

configure_kernel() {
    log "Generating tinyconfig for x86_64"
    make -C "$KERNEL_DIR" ARCH=x86_64 tinyconfig

    log "Enabling options needed for console, ELF init and virtio-mmio disk/net"
    "$KERNEL_DIR/scripts/config" --file "$KERNEL_DIR/.config" \
        --enable BINFMT_ELF \
        --enable PRINTK \
        --enable PRINTK_TIME \
        --set-val LOG_BUF_SHIFT 12 \
        --enable DEVTMPFS \
        --enable DEVTMPFS_MOUNT \
        --enable TTY \
        --enable SERIAL_8250 \
        --enable SERIAL_8250_CONSOLE \
        --set-val SERIAL_8250_NR_UARTS 1 \
        --set-val SERIAL_8250_RUNTIME_UARTS 1 \
        --enable HYPERVISOR_GUEST \
        --enable PARAVIRT \
        --enable KVM_GUEST \
        --enable BLOCK \
        --enable VIRTIO_MENU \
        --enable VIRTIO \
        --enable VIRTIO_MMIO \
        --enable VIRTIO_MMIO_CMDLINE_DEVICES \
        --enable VIRTIO_BLK \
        --enable NET \
        --enable NETDEVICES \
        --enable VIRTIO_NET \
        --enable INET \
        --disable IPV6 \
        --enable PROC_FS \
        --enable EXT4_FS \
        --set-val LOCALVERSION '""'

    log "Embedding init as an uncompressed built-in initramfs"
    "$KERNEL_DIR/scripts/config" --file "$KERNEL_DIR/.config" \
        --enable BLK_DEV_INITRD \
        --set-str INITRAMFS_SOURCE "$WORKDIR/initramfs.list" \
        --enable INITRAMFS_COMPRESSION_NONE \
        --disable RD_GZIP --disable RD_BZIP2 --disable RD_LZMA \
        --disable RD_XZ --disable RD_LZO --disable RD_LZ4 --disable RD_ZSTD

    # A KVM microVM has no PCI bus, VGA, keyboard, microcode loading or
    # partitioned disks, so drop everything olddefconfig would pull in for them.
    log "Disabling hardware and features a microVM never uses"
    "$KERNEL_DIR/scripts/config" --file "$KERNEL_DIR/.config" \
        --disable PCI \
        --disable VT --disable VGA_CONSOLE --disable DUMMY_CONSOLE \
        --disable INPUT --disable SERIO --disable HID_SUPPORT \
        --disable LEGACY_PTYS --disable UNIX98_PTYS \
        --disable EARLY_PRINTK \
        --disable CPU_SUP_HYGON --disable CPU_SUP_CENTAUR --disable CPU_SUP_ZHAOXIN \
        --disable SWAP \
        --disable BLOCK_LEGACY_AUTOLOAD \
        --enable PARTITION_ADVANCED --disable MSDOS_PARTITION --disable EFI_PARTITION \
        --disable EXT4_USE_FOR_EXT2 \
        --disable INET_DIAG \
        --set-val INET_TABLE_PERTURB_ORDER 8 \
        --disable WLAN --disable ETHERNET \
        --disable PROC_SYSCTL --disable PROC_PAGE_MONITOR --disable PROC_PID_ARCH_STATUS \
        --enable INIT_STACK_NONE --disable INIT_STACK_ALL_ZERO \
        --enable NO_HZ_IDLE --disable HZ_PERIODIC \
        --enable HZ_100 --disable HZ_250

    log "Resolving dependencies with olddefconfig"
    make -C "$KERNEL_DIR" ARCH=x86_64 olddefconfig
}

build_kernel() {
    log "Building kernel (-j$JOBS)"
    make -C "$KERNEL_DIR" ARCH=x86_64 -j"$JOBS"
}

write_init() {
    log "Copying init.c"
    cp "$SCRIPT_DIR/init.c" "$WORKDIR/init.c"
}

build_init() {
    # init stays resident in the initramfs, so prefer musl: a static glibc
    # binary is ~850KB of guest RAM versus a few tens of KB with musl.
    local cc=musl-gcc
    if ! command -v "$cc" >/dev/null 2>&1; then
        echo "WARNING: musl-gcc not found, falling back to static glibc (much larger init)." >&2
        echo "         On Debian/Ubuntu: sudo apt install musl-tools" >&2
        cc=gcc
    fi

    log "Compiling init statically with $cc"
    "$cc" -Os -static -s -Wall -fno-asynchronous-unwind-tables \
        -o "$WORKDIR/init" "$WORKDIR/init.c"
}

write_initramfs_list() {
    log "Writing initramfs file list"
    printf '%s\n' \
        'dir /dev 0755 0 0' \
        'nod /dev/console 0600 0 0 c 5 1' \
        "file /init $WORKDIR/init 0755 0 0" \
        > "$WORKDIR/initramfs.list"
}

build_diskimage() {
    if [ -f "$WORKDIR/diskimage" ]; then
        log "diskimage already exists, skipping"
    else
        log "Creating 128MiB ext4 diskimage"
        dd if=/dev/zero of="$WORKDIR/diskimage" bs=1M count=128 status=none
        mkfs.ext4 -q "$WORKDIR/diskimage"
    fi
}

boot_qemu() {
    log "Booting under QEMU"
    "$SCRIPT_DIR/boot-qemu.sh" "$WORKDIR"
}

rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
check_deps
fetch_kernel
write_init
build_init
write_initramfs_list
configure_kernel
build_kernel
build_diskimage
#boot_qemu

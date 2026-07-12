#!/usr/bin/env bash
#
# Build and boot a "naked" Linux kernel with a hand-written init, following
# https://nick.zoic.org/art/boot-naked-linux/
#
# Downloads the Linux v7.1 source zip, configures a minimal x86-64 build,
# compiles a tiny static init.c that mounts devtmpfs and the ext4 disk
# image, packs it into an initramfs, and boots the whole thing under QEMU.

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
    for tool in curl unzip make gcc bc flex bison cpio mkfs.ext4 qemu-system-x86_64; do
        command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        echo "Missing required tools: ${missing[*]}" >&2
        echo "On Debian/Ubuntu: sudo apt install curl unzip build-essential bc flex bison cpio e2fsprogs qemu-system-x86" >&2
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

    log "Enabling options needed for initramfs, console, ELF init and /dev/vda"
    "$KERNEL_DIR/scripts/config" --file "$KERNEL_DIR/.config" \
        --enable BLK_DEV_INITRD \
        --enable BINFMT_ELF \
        --enable PRINTK \
        --enable PRINTK_TIME \
        --enable EARLY_PRINTK \
        --enable DEVTMPFS \
        --enable DEVTMPFS_MOUNT \
        --enable TTY \
        --enable SERIAL_8250 \
        --enable SERIAL_8250_CONSOLE \
        --enable PCI \
        --enable BLOCK \
        --enable VIRTIO_MENU \
        --enable VIRTIO \
        --enable VIRTIO_PCI \
        --enable VIRTIO_BLK \
        --enable NET \
        --enable NETDEVICES \
        --enable VIRTIO_NET \
        --enable INET \
        --disable IPV6 \
        --enable PROC_FS \
        --enable EXT4_FS \
        --set-val LOCALVERSION '""'

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
    log "Compiling init statically"
    gcc -static -o "$WORKDIR/init" "$WORKDIR/init.c"
}

build_initrd() {
    log "Packing initramfs"
    (cd "$WORKDIR" && echo init | cpio -o --format=newc | gzip -c > initrd)
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
configure_kernel
build_kernel
write_init
build_init
build_initrd
build_diskimage
#boot_qemu

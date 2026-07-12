#!/usr/bin/env bash
#
# Boot the kernel/initramfs/diskimage produced by build-linux.sh under QEMU.

set -euo pipefail

WORKDIR="${1:-$PWD/linux-src}"
KERNEL_DIR="$WORKDIR/linux"

kvm_flag=()
[ -w /dev/kvm ] && kvm_flag=(-enable-kvm)

qemu-system-x86_64 "${kvm_flag[@]}" -m 32M -nographic \
    -kernel "$KERNEL_DIR/arch/x86/boot/bzImage" \
    -initrd "$WORKDIR/initrd" \
    -append "console=ttyS0" \
    -drive id=disk0,file="$WORKDIR/diskimage",if=none,format=raw \
    -device virtio-blk,drive=disk0 \
    -netdev socket,id=testnet1,listen=:1234 \
    -device virtio-net-pci,netdev=testnet1,mac=10:11:12:00:1A:F4 \
    -monitor telnet:localhost:8086,server,nowait

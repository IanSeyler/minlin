#!/usr/bin/env bash
#
# Boot the kernel/diskimage produced by build-linux.sh under QEMU's microvm
# machine. The initramfs is built into the kernel. With acpi=off QEMU appends
# virtio_mmio.device= entries to the kernel command line for each device.
# microvm has no ACPI or i8042 to power off with, so init reboots instead:
# reboot=t makes that a triple fault, which -no-reboot turns into QEMU exiting.

set -euo pipefail

WORKDIR="${1:-$PWD/linux-src}"
KERNEL_DIR="$WORKDIR/linux"

kvm_flag=()
[ -w /dev/kvm ] && kvm_flag=(-enable-kvm -cpu host)

qemu-system-x86_64 "${kvm_flag[@]}" -m 32M -nographic -nodefaults -no-reboot \
    -M microvm,acpi=off,pcie=off,pic=off,rtc=off \
    -serial stdio \
    -kernel "$KERNEL_DIR/arch/x86/boot/bzImage" \
    -append "console=ttyS0 reboot=t ip=192.168.1.2:::255.255.255.0::eth0:off" \
    -drive id=disk0,file="$WORKDIR/diskimage",if=none,format=raw \
    -device virtio-blk-device,drive=disk0 \
    -netdev socket,id=testnet1,listen=:1234 \
    -device virtio-net-device,netdev=testnet1,mac=10:11:12:00:1A:F4 \
    -monitor telnet:localhost:8086,server,nowait

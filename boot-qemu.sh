#!/usr/bin/env bash
#
# Boot the kernel/diskimage produced by build-linux.sh under QEMU's microvm
# machine. The initramfs is built into the kernel. With acpi=off QEMU appends
# virtio_mmio.device= entries to the kernel command line for each device.
# microvm has no ACPI or i8042 to power off with, so init reboots instead:
# reboot=t makes that a triple fault, which -no-reboot turns into QEMU exiting.
#
# By default the NIC is a socket netdev listening on :1234. Set HOSTFWD to a
# host port to use user-mode networking instead and forward that port to the
# guest's port 80, e.g. to reach lighttpd:
#   HOSTFWD=8080 ./boot-qemu.sh && curl http://localhost:8080/
# SSHFWD does the same for the guest's port 22 (the sshd app), and either one
# or both can be set:
#   SSHFWD=2222 ./boot-qemu.sh && ssh -p 2222 root@localhost
#
# Guest RAM is 32MB unless MEM= says otherwise (in MB). The guest's hostname
# is the kernel's default (minlin) unless GUEST_NAME= gives one.
#
# Kernel messages are hidden (quiet) unless --debug is given.

set -euo pipefail

DEBUG=0
args=()
for arg in "$@"; do
    case "$arg" in
        --debug) DEBUG=1 ;;
        *) args+=("$arg") ;;
    esac
done
set -- "${args[@]}"

# quiet keeps kernel messages off the slow emulated serial console, which
# roughly halves boot time; --debug shows them.
quiet=quiet
[ "$DEBUG" -eq 1 ] && quiet=

WORKDIR="${1:-$PWD/linux-src}"
KERNEL_DIR="$WORKDIR/linux"

HOSTFWD="${HOSTFWD:-}"
SSHFWD="${SSHFWD:-}"
MEM="${MEM:-32}"
GUEST_NAME="${GUEST_NAME:-}"

kvm_flag=()
[ -w /dev/kvm ] && kvm_flag=(-enable-kvm -cpu host)

if [ -n "$HOSTFWD$SSHFWD" ]; then
    ip="10.0.2.15::10.0.2.2:255.255.255.0:$GUEST_NAME:eth0:off"
    netdev="user,id=testnet1"
    [ -n "$HOSTFWD" ] && netdev+=",hostfwd=tcp::$HOSTFWD-:80"
    [ -n "$SSHFWD" ] && netdev+=",hostfwd=tcp::$SSHFWD-:22"
else
    ip="192.168.1.2:::255.255.255.0:$GUEST_NAME:eth0:off"
    netdev="socket,id=testnet1,listen=:1234"
fi

qemu-system-x86_64 "${kvm_flag[@]}" -m "${MEM}M" -nographic -nodefaults -no-reboot \
    -M microvm,acpi=off,pcie=off,pic=off,rtc=off \
    -serial stdio \
    -kernel "$KERNEL_DIR/arch/x86/boot/bzImage" \
    -append "console=ttyS0 $quiet reboot=t ip=$ip" \
    -drive id=disk0,file="$WORKDIR/diskimage",if=none,format=raw \
    -device virtio-blk-device,drive=disk0 \
    -netdev "$netdev" \
    -device virtio-net-device,netdev=testnet1,mac=10:11:12:00:1A:F4 \
    -monitor telnet:localhost:8086,server,nowait

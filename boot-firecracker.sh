#!/usr/bin/env bash
#
# Boot the kernel/diskimage produced by build-linux.sh under Firecracker.
# Firecracker loads the uncompressed vmlinux (the initramfs is built into it)
# and appends virtio_mmio.device= entries to the kernel command line itself.
# Firecracker exits when the guest resets through its emulated i8042, so
# reboot=k turns init's reboot(RB_AUTOBOOT) into a clean VMM exit.
#
# The guest NIC is backed by a tap device on an existing bridge. If $TAP does
# not exist it is created (via sudo) owned by this user, attached to $BRIDGE,
# and removed again on exit; an existing $TAP is used as-is and left alone.
#
# The guest's address is passed on the kernel command line as
# ip=<client>::<gateway>:<netmask>::eth0:off, which init applies. By default
# it is taken from $BRIDGE's subnet: the gateway is the bridge's own address
# and the guest gets the next address up. Override with GUEST_IP=.
#   BRIDGE=br0 TAP=fctap0 GUEST_IP=172.19.0.50 ./boot-firecracker.sh

set -euo pipefail

WORKDIR="${1:-$PWD/linux-src}"
KERNEL_DIR="$WORKDIR/linux"
BRIDGE="${BRIDGE:-br0}"
TAP="${TAP:-fctap0}"
GUEST_IP="${GUEST_IP:-}"

if [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
    echo "Firecracker needs read/write access to /dev/kvm" >&2
    exit 1
fi

ip2int() {
    local IFS=. a b c d
    read -r a b c d <<<"$1"
    echo $(( (a << 24) | (b << 16) | (c << 8) | d ))
}

int2ip() {
    echo "$(( ($1 >> 24) & 255 )).$(( ($1 >> 16) & 255 )).$(( ($1 >> 8) & 255 )).$(( $1 & 255 ))"
}

if ! ip link show "$BRIDGE" type bridge >/dev/null 2>&1; then
    echo "Bridge $BRIDGE not found (set BRIDGE=...)" >&2
    exit 1
fi

bridge_cidr="$(ip -4 -o addr show dev "$BRIDGE" | awk '{ print $4; exit }')"
if [ -z "$bridge_cidr" ]; then
    echo "Bridge $BRIDGE has no IPv4 address to derive the guest network from" >&2
    exit 1
fi
gateway="${bridge_cidr%/*}"
prefix="${bridge_cidr#*/}"
mask=$(( (0xffffffff << (32 - prefix)) & 0xffffffff ))
netmask="$(int2ip "$mask")"
if [ -z "$GUEST_IP" ]; then
    GUEST_IP="$(int2ip $(( $(ip2int "$gateway") + 1 )))"
fi
guest=$(ip2int "$GUEST_IP")
if [ $(( guest & mask )) -ne $(( $(ip2int "$gateway") & mask )) ] ||
   [ $(( guest | mask )) -eq 4294967295 ] || [ "$GUEST_IP" = "$gateway" ]; then
    echo "Guest address $GUEST_IP is not usable on $bridge_cidr (set GUEST_IP=...)" >&2
    exit 1
fi
echo "Guest network: $GUEST_IP/$prefix via $gateway on $BRIDGE" >&2

as_root() {
    if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi
}

created_tap=0
cleanup() {
    rm -f "${config:-}"
    if [ "$created_tap" -eq 1 ]; then
        as_root ip link del "$TAP" || true
    fi
}
trap cleanup EXIT

if ip link show "$TAP" >/dev/null 2>&1; then
    echo "Using existing tap device $TAP" >&2
else
    echo "Creating tap device $TAP on bridge $BRIDGE" >&2
    as_root ip tuntap add dev "$TAP" mode tap user "$(id -un)"
    created_tap=1
    as_root ip link set "$TAP" master "$BRIDGE" up
fi

config="$(mktemp --tmpdir firecracker-config.XXXXXX.json)"

cat > "$config" <<EOF
{
    "boot-source": {
        "kernel_image_path": "$KERNEL_DIR/vmlinux",
        "boot_args": "console=ttyS0 reboot=k panic=1 ip=$GUEST_IP::$gateway:$netmask::eth0:off"
    },
    "drives": [{
        "drive_id": "disk0",
        "path_on_host": "$WORKDIR/diskimage",
        "is_root_device": false,
        "is_read_only": false
    }],
    "network-interfaces": [{
        "iface_id": "eth0",
        "guest_mac": "10:11:12:00:1A:F4",
        "host_dev_name": "$TAP"
    }],
    "machine-config": {
        "vcpu_count": 1,
        "mem_size_mib": 32
    }
}
EOF

firecracker --no-api --config-file "$config"

# Sourced by build-disk.sh: installs the host's tailscaled (a static Go
# binary), the CA certificates for TLS to the control server, and a config
# file that brings the node up when tailscaled starts.
#
# Set TS_AUTHKEY to an auth key (ideally ephemeral) to log the node in; it is
# written into the config file on the disk.
#
# Set TS_EXIT_NODE=1 to advertise the node as an exit node (it still has to
# be approved in the admin console). init then turns on IPv4 forwarding from
# etc/sysctl.conf, and tailscaled masquerades the forwarded traffic with
# nftables. The guest has no IPv6, so exit traffic is IPv4 only.
#
# The tailscale CLI isn't installed: it's a second ~24MB Go binary, and a
# 32MB guest can't page in both. tailscaled's --config does what
# "tailscale up" would.

require tailscaled tailscale
require strip binutils

# Debug info isn't needed to run and is over a quarter of the binary.
install_binary "$(command -v tailscaled)"
strip "$ROOTFS$(command -v tailscaled)"
cp --parents -L /etc/ssl/certs/ca-certificates.crt "$ROOTFS"
mkdir -p "$ROOTFS/var/lib/tailscale"

[ -n "${TS_AUTHKEY:-}" ] ||
    echo "WARNING: TS_AUTHKEY not set, tailscaled will start but never log in." >&2

# Without an exit node to NAT for, tailscaled has no need to touch netfilter.
netfilter=off
if [ "${TS_EXIT_NODE:-0}" = 1 ]; then
    netfilter=on
    echo "net.ipv4.ip_forward = 1" > "$ROOTFS/etc/sysctl.conf"
fi

(
    umask 077
    printf '{\n    "Version": "alpha0",\n    "Enabled": true,\n'
    # tailscaled is a copy of the host's, replaced by rebuilding the disk, so
    # don't let the tailnet's auto-update default try to update it.
    printf '    "AutoUpdate": {"Check": false, "Apply": false},\n'
    [ -n "${TS_AUTHKEY:-}" ] && printf '    "AuthKey": "%s",\n' "$TS_AUTHKEY"
    [ "$netfilter" = on ] &&
        printf '    "AdvertiseRoutes": ["0.0.0.0/0", "::/0"],\n'
    printf '    "NetfilterMode": "%s"\n}\n' "$netfilter"
) > "$ROOTFS/etc/tailscaled.conf"

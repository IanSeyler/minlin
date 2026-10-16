#!/usr/bin/env bash
#
# Build the ext2 diskimage that init mounts as / for one app.
#
#   ./build-disk.sh <app> [workdir]
#
# An app lives in apps/<app>/:
#   rootfs/     copied onto the disk as-is. It should include etc/init.conf,
#               which tells init what to start.
#   install.sh  optional; sourced after rootfs/ is copied. It can call
#               install_binary to pull host programs (and the shared
#               libraries they need) onto the disk, copy anything else into
#               $ROOTFS, and set DISK_SIZE if 128M is not enough.
#
# The kernel from build-linux.sh does not depend on the app, so switching
# apps only needs this script re-run.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

if [ "$#" -lt 1 ]; then
    echo "Usage: $0 <app> [workdir]" >&2
    echo "Apps: $(ls "$SCRIPT_DIR/apps" | tr '\n' ' ')" >&2
    exit 1
fi

APP="$1"
APP_DIR="$SCRIPT_DIR/apps/$APP"
WORKDIR="${2:-$PWD/linux-src}"
ROOTFS="$WORKDIR/rootfs"
DISK_SIZE=128M

log() { printf '\n>>> %s\n' "$*"; }

# Fail with an install hint unless the given host command exists.
require() {
    local cmd="$1" pkg="${2:-$1}"
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "$cmd not found. On Debian/Ubuntu: sudo apt install $pkg" >&2
        exit 1
    }
}

# Copy a host binary into the rootfs at the same path, along with every
# shared library it needs (and the dynamic loader), as reported by ldd.
install_binary() {
    local bin="$1"
    cp --parents -L "$bin" "$ROOTFS"
    # "|| true": a file with no dependencies gives grep nothing to match.
    ldd "$bin" | { grep -o '/[^ ]*' || true; } | while read -r lib; do
        [ -e "$ROOTFS$lib" ] || cp --parents -L "$lib" "$ROOTFS"
    done
}

[ -d "$APP_DIR" ] || { echo "No such app: $APP_DIR" >&2; exit 1; }
require ldd libc-bin
require mkfs.ext2 e2fsprogs

log "Assembling root filesystem for $APP in $ROOTFS"
rm -rf "$ROOTFS"
mkdir -p "$ROOTFS"
[ -d "$APP_DIR/rootfs" ] && cp -a "$APP_DIR/rootfs/." "$ROOTFS/"
if [ -f "$APP_DIR/install.sh" ]; then
    # shellcheck source=/dev/null
    source "$APP_DIR/install.sh"
fi
[ -f "$ROOTFS/etc/init.conf" ] ||
    echo "WARNING: $APP has no etc/init.conf, init will have nothing to run." >&2

log "Creating $DISK_SIZE ext2 diskimage from $ROOTFS"
rm -f "$WORKDIR/diskimage"
mkfs.ext2 -q -E root_owner=0:0 -d "$ROOTFS" "$WORKDIR/diskimage" "$DISK_SIZE"

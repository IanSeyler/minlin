# Sourced by build-disk.sh: installs the host's bash, setsid (util-linux) to
# give it the console as its controlling terminal, the terminfo entry for that
# console, and a handful of everyday commands to use from it.

require bash
require setsid util-linux

install_binary "$(command -v bash)"
install_binary "$(command -v setsid)"
# The prompt. Copied here, not just left in rootfs/, so that apps which
# source this file for their shell (apps/sshd) get it too.
cp "$SCRIPT_DIR/apps/bash/rootfs/etc/bash.bashrc" "$SCRIPT_DIR/apps/bash/rootfs/etc/profile" "$ROOTFS/etc/"

# Anything here that the host has is installed; the rest are skipped.
# Where the host's coreutils are uutils (Ubuntu's default), every command is
# a link to one ~11MB multi-call binary, so GNU coreutils' gnu-prefixed
# copies are used instead when they're installed (gnu-coreutils).
for cmd in ls cat cp mv rm mkdir rmdir ln touch chmod head tail wc sort \
           uniq grep sed df du free ps uname date sleep env id stat tty; do
    path="$(command -v "$cmd")" || { echo "Skipping $cmd (not on host)" >&2; continue; }
    gnu="$(dirname "$path")/gnu$cmd"
    if [ -x "$gnu" ]; then
        install_binary "$gnu"
        mv "$ROOTFS$gnu" "$ROOTFS$path"
    else
        install_binary "$path"
    fi
done

# The kernel starts init with TERM=linux, which init passes on to bash.
# readline needs that terminal's description for line editing.
terminfo="$(find /usr/share/terminfo /lib/terminfo -path '*/l/linux' -print -quit 2>/dev/null)"
[ -n "$terminfo" ] || { echo "No terminfo entry for 'linux' (ncurses-base)" >&2; exit 1; }
cp --parents -L "$terminfo" "$ROOTFS"

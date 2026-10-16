# Sourced by build-disk.sh: installs the host's top (procps) and the terminfo
# entry for the console it draws on.

require top procps

install_binary "$(command -v top)"
# The kernel starts init with TERM=linux, which init passes on to top.
# ncurses needs that terminal's description to draw the screen.
terminfo="$(find /usr/share/terminfo /lib/terminfo -path '*/l/linux' -print -quit 2>/dev/null)"
[ -n "$terminfo" ] || { echo "No terminfo entry for 'linux' (ncurses-base)" >&2; exit 1; }
cp --parents -L "$terminfo" "$ROOTFS"

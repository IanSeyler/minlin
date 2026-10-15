# Sourced by build-disk.sh: installs the host's python3, its standard library
# and the shared libraries its extension modules need.

require python3

install_binary "$(command -v python3)"

stdlib="$(python3 -c 'import sysconfig; print(sysconfig.get_path("stdlib"))')"
cp -a --parents "$stdlib" "$ROOTFS"
# Drop what a headless VM never imports: the test suite, GUI and pip
# bootstrap packages, and the static libpython used to embed Python.
# sitecustomize.py is a symlink to Debian's /etc hook, which isn't copied.
(cd "$ROOTFS$stdlib" && rm -rf test idlelib tkinter turtledemo ensurepip \
    config-*/ sitecustomize.py)
# Extension modules (ssl, sqlite3, ctypes, ...) link against host libraries.
for mod in "$ROOTFS$stdlib"/lib-dynload/*.so; do
    install_binary "${mod#"$ROOTFS"}"
done

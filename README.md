# minlin
Minimal Linux

A tiny x86-64 kernel (tinyconfig plus virtio-mmio) with a hand-written
`init.c` built into its initramfs, booting under QEMU microvm or Firecracker
and running ordinary, dynamically linked Linux programs from an ext2 disk.

## Build and boot

    ./build-linux.sh                 # kernel, with init built in
    ./build-disk.sh lighttpd         # linux-src/diskimage for apps/lighttpd
                                     # (or: ./build-disk.sh python / top)
    HOSTFWD=8080 ./boot-qemu.sh      # then: curl http://localhost:8080/
    ./boot-firecracker.sh            # tap on br0; guest gets the next IP up

The kernel doesn't depend on the app, so switching apps only needs
`build-disk.sh` re-run. The lighttpd app needs `lighttpd` installed on the
host (`sudo apt install lighttpd`); the host's binary, its modules and shared
libraries (found with `ldd`) are copied into the disk image.

## Boot sequence

1. The kernel runs `/init` from the built-in initramfs.
2. init configures `eth0` from the `ip=` kernel parameter.
3. init mounts `/dev/vda` (ext2), moves it over `/` and chroots into it, then
   mounts `/dev`, `/proc` and `/tmp` there.
4. init runs the programs listed in `/etc/init.conf`, reaps children, and
   reboots (ending the VM) once nothing is left running.

## Apps

Each directory in `apps/` is something the VM can run. `build-disk.sh <app>`
builds the disk from it:

- `rootfs/` is copied onto the disk as-is. It should hold `etc/init.conf`,
  which says what init starts. Each line is
  `<wait|once|respawn> /absolute/path [args...]`.
- `install.sh` (optional) is sourced afterwards. It can call
  `install_binary /path/on/host` to copy a host program and the shared
  libraries it needs onto the disk, `require <cmd> [apt-package]` to check the
  host has something, copy anything else into `$ROOTFS`, and set `DISK_SIZE`
  if the default 128M is too small.

`apps/lighttpd` serves `rootfs/var/www` on port 80 with its access log on the
console.

`apps/python` runs `rootfs/app/main.py` with the host's `python3` (so the host
needs Python 3): a small `http.server` on port 80 that reports the Python
version, kernel and boot parameters, memory (from `/proc/meminfo`) and disk
space, as HTML at `/` and as JSON at `/metrics.json`. Its standard library is
copied too, minus the test suite, GUI packages and the static libpython, along
with the shared libraries its extension modules (ssl, sqlite3, ...) link
against.

`apps/top` runs the host's `top` (procps) on the serial console, along with
the `linux` terminfo entry it draws with (the kernel starts init with
`TERM=linux`). Press `q` to quit top, which also ends the VM.

To add another app, create `apps/<name>/` with an `etc/init.conf` and an
`install.sh` that installs whatever it needs. The kernel is still very small
(for example no `CONFIG_UNIX`, `CONFIG_MULTIUSER` or `CONFIG_SHMEM`), so some
programs will need more kernel options enabled in `build-linux.sh`.

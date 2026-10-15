# minlin
Minimal Linux

A tiny x86-64 kernel (tinyconfig plus virtio-mmio) with a hand-written
`init.c` built into its initramfs, booting under QEMU microvm or Firecracker
and running ordinary, dynamically linked Linux programs from an ext4 disk.

## Build and boot

    ./build-linux.sh                 # kernel, with init built in
    ./build-disk.sh lighttpd         # linux-src/diskimage for apps/lighttpd
    HOSTFWD=8080 ./boot-qemu.sh      # then: curl http://localhost:8080/
    ./boot-firecracker.sh            # tap on br0; guest gets the next IP up

The kernel doesn't depend on the app, so switching apps only needs
`build-disk.sh` re-run. The lighttpd app needs `lighttpd` installed on the
host (`sudo apt install lighttpd`); the host's binary, its modules and shared
libraries (found with `ldd`) are copied into the disk image.

## Boot sequence

1. The kernel runs `/init` from the built-in initramfs.
2. init configures `eth0` from the `ip=` kernel parameter.
3. init mounts `/dev/vda` (ext4), moves it over `/` and chroots into it, then
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

To add another app (Python, say), create `apps/<name>/` with an
`etc/init.conf` and an `install.sh` that installs the interpreter and whatever
else it needs (for Python, its standard library directory too). The kernel is
still very small (for example no `CONFIG_UNIX`, `CONFIG_MULTIUSER` or
`CONFIG_SHMEM`), so some programs will need more kernel options enabled in
`build-linux.sh`.

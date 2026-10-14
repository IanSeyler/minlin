# minlin
Minimal Linux

A tiny x86-64 kernel (tinyconfig plus virtio-mmio) with a hand-written
`init.c` built into its initramfs, booting under QEMU microvm or Firecracker
and running ordinary, dynamically linked Linux programs from an ext4 disk.

## Build and boot

    ./build-linux.sh                 # kernel + linux-src/diskimage
    HOSTFWD=8080 ./boot-qemu.sh      # then: curl http://localhost:8080/
    ./boot-firecracker.sh            # tap on br0; guest gets the next IP up

Building needs `lighttpd` installed on the host (`sudo apt install lighttpd`).
The host's binary, its modules and shared libraries (found with `ldd`) are
copied into the disk image.

## Boot sequence

1. The kernel runs `/init` from the built-in initramfs.
2. init configures `eth0` from the `ip=` kernel parameter.
3. init mounts `/dev/vda` (ext4), moves it over `/` and chroots into it, then
   mounts `/dev`, `/proc` and `/tmp` there.
4. init runs the programs listed in `/etc/init.conf`, reaps children, and
   reboots (ending the VM) once nothing is left running.

## Disk contents

`rootfs/` is copied onto the disk as-is:

- `etc/init.conf`: what init starts. Each line is
  `<wait|once|respawn> /absolute/path [args...]`.
- `etc/lighttpd/lighttpd.conf`: serves `/var/www` on port 80, access log on
  the console.
- `var/www/index.html`: the page served.

To run another program, add it to `build_rootfs` in `build-linux.sh` with
`install_binary` and list it in `rootfs/etc/init.conf`. The kernel is still
very small (for example no `CONFIG_UNIX`, `CONFIG_MULTIUSER` or
`CONFIG_SHMEM`), so some programs will need more kernel options enabled.

# bash on minlin

This app runs the host's `bash` as the only program in a minlin microVM, on
the serial console, along with a handful of everyday commands from the host.
It has job control and a working Ctrl-C, and `exit` (or Ctrl-D) ends the VM.

`apps/sshd` uses this app's `install.sh` for its login shell, so everything
here applies to ssh sessions too.

## Requirements

On the host:

- bash, and util-linux for `setsid`.
- GNU coreutils under its `gnu`-prefixed names (`gnu-coreutils`) if the
  host's coreutils are uutils (see [Commands](#commands)).
- What minlin itself needs (see the top-level README).

## Build and boot

    ./build-linux.sh                     # once, or after kernel/init changes
    ./build-disk.sh bash
    ./boot-qemu.sh

The console is QEMU's stdio. Type `exit` or Ctrl-D to leave bash, which ends
the VM. `GUEST_NAME=` sets the hostname shown in the prompt.

## Prompt

`/etc/bash.bashrc` sets a Debian-style prompt, `user@host:dir` followed by
`#` for root or `$` for anyone else, with the user and host in green and the
directory in blue:

    root@minlin:/usr/bin#

Interactive shells read `/etc/bash.bashrc` directly. Login shells (ssh
sessions) read `/etc/profile`, which loads it. On the console, init sets
`HOME=/`, so the shell starts in `/` rather than `~`.

## Commands

Apart from bash's builtins, the disk has:

    cat chmod cp date df du env free grep head id ln ls mkdir mv ps rm rmdir
    sed sleep sort stat tail touch tty uname uniq wc

To add one, add it to the list in `install.sh`. A command the host doesn't
have is skipped with a message.

On Ubuntu the default coreutils are uutils, where each command is a link to
one ~11MB multi-call binary. Copying that once per command overflows the
128MB disk. When the host has GNU coreutils' `gnu`-prefixed copies (`gnuls`,
`gnucat`, ...), `install.sh` installs those under the plain names instead.

## Controlling terminal

init starts each program in a new session with no controlling terminal.
Without one, bash prints `cannot set terminal process group` and runs
without job control, and Ctrl-C can't interrupt a command. So
`/etc/init.conf` starts bash through util-linux `setsid -c`, which makes the
console bash's controlling terminal:

    once /usr/bin/setsid -c -w /usr/bin/bash -i

`-w` makes setsid wait for bash, so init sees the shell exit.

## Terminal

The kernel starts init with `TERM=linux`, which init passes on to bash.
readline needs that terminal's terminfo entry for line editing, so it's
copied from the host. A serial console can't report its size, so bash
assumes 80x24, and lines longer than the real window wrap oddly when
edited. There's no `stty` on the disk to change that.

## Memory

The disk holds 9.6MB, mostly shared libraries. The default 32MB of RAM is
plenty: with bash at its prompt, `free` reports about 17MB available.

## What's on the disk

| Path | Purpose |
|------|---------|
| `/usr/bin/bash` | the host's bash |
| `/usr/bin/setsid` | gives bash the console as its controlling terminal |
| `/usr/bin/*` | the commands listed above |
| `/etc/init.conf` | starts bash on the console |
| `/etc/bash.bashrc`, `/etc/profile` | the prompt |
| `/etc/passwd` | `root`, so the prompt can show a user name |
| `/usr/share/terminfo/l/linux` | the console's terminfo entry |
| `/lib64/`, `/usr/lib/x86_64-linux-gnu/` | shared libraries the programs need |

The disk is writable. bash saves its history to `/.bash_history` on exit, so
it carries over to the next boot until the disk is rebuilt. Because ext2 has
no journal, killing the VM (Ctrl-A x in QEMU) instead of typing `exit` can
leave the disk inconsistent. Rebuild it, or run
`e2fsck -f linux-src/diskimage`, if that happens.

## Kernel support

bash needs nothing beyond the options every app uses: it ran on the kernel
before the sshd options were added.

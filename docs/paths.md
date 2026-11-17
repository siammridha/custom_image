# Paths the programs know about

The programs in the image have file paths built in or in their settings.
Many of these files are not in the image. This list says, for each one,
whether that is on purpose, what was removed and how to bring it back.
Check here first when a program fails because a file is missing.

Checked on 2026-11-17 (Buildroot 2026.08.2, busybox 1.38.0, dropbear
2026.94, musl 1.2.6, e2fsprogs 1.47.4, util-linux 2.41.5, Tailscale 1.104.7,
NetBird 0.83.1).

## Removed on purpose

| What | Was | Now | Where | To bring back |
|---|---|---|---|---|
| udhcpc default script | `/usr/share/udhcpc/default.script` (deleted) | `/usr/libexec/wyse/udhcpc-event` (wyse-init) | `CONFIG_UDHCPC_DEFAULT_SCRIPT` in `busybox.config` | - |
| dropbear SFTP | `/usr/libexec/sftp-server` (never in the image) | Off | `DROPBEAR_SFTPSERVER 0` in `dropbear-localoptions.h` | Set to 1 and add an sftp-server. Modern `scp` uses SFTP, so `scp` to the device fails; copy with `ssh ... 'cat > file' < file`. |
| dropbear login message | `/etc/motd` | Off | `DO_MOTD 0` in `dropbear-localoptions.h` | Set to 1 and add `/etc/motd` |
| dropbear pid file | `/var/run/dropbear.pid`, nothing read it | Not written | `DROPBEAR_PIDFILE ""` in `dropbear-localoptions.h` (fopen("") fails) | Remove the line, or run dropbear with `-P <file>` |
| dropbear agent forwarding | `/tmp/dropbear-*/auth-*` sockets (`ssh -A`) | Off | `DROPBEAR_SVR_AGENTFWD 0` in `dropbear-localoptions.h` | Set to 1 |
| dropbear login records | utmp (musl's functions do nothing) | Off | `--disable-utmp --disable-pututline --disable-pututxline` in `external.mk` | Remove that line |
| busybox `login` extras | `/etc/securetty`, `/etc/nologin`, shadow passwords, busybox crypt | Off. `login` itself stays: NetBird SSH starts every terminal session with `login -f root -h <ip> -p` (`client/ssh/server/userswitching_unix.go`); without it the session fails with "login command not available". `-f` skips the password check. | `FEATURE_NOLOGIN`, `FEATURE_SECURETTY`, `FEATURE_SHADOWPASSWDS`, `USE_BB_CRYPT(_SHA)` in `busybox.config` | Turn them on for password logins |
| busybox login records | `/var/run/utmp`, `/var/log/wtmp` (musl's functions do nothing) | Off | `CONFIG_FEATURE_UTMP`, `CONFIG_FEATURE_WTMP` | Turn on (still does nothing with musl) |
| busybox `ip` | `/etc/iproute2` | `ip` removed; wyse-init sets addresses and routes itself (`wyse-init/src/net.rs`) | `CONFIG_IP` in `busybox.config` | `alpine apk add iproute2` and run `alpine ip ...` |
| Users | daemon, bin, sys, sync, mail, www-data, operator, nobody, with homes (`/home`, `/var/www`, `/var/spool/mail`) and shell `/bin/false` that do not exist | Only root in `/etc/passwd` and `/etc/shadow` | `post-build.sh` | A program that must run as another user needs its line added back in `post-build.sh`. Alpine in `/data/alpine` has its own users. |
| Groups | 26 groups | Only `tty:x:5:` in `/etc/group` | `post-build.sh` | `ls -l` shows group numbers (`0`), not names. Add a line in `post-build.sh` if a name is needed. `tty` must stay: fstab mounts devpts with `gid=5`, and dropbear makes SSH terminals 0620 with it (0622 without). |
| `/etc/services` | Port names | Removed | `post-build.sh` | Go has `http`, `https`, `ssh`, `domain` and a few more built in. busybox reads it only for a port given as a name (`host:ntp`); use numbers. Alpine has its own. |
| `/etc/protocols` | Protocol names | Removed | `post-build.sh` | Go and musl have `icmp`, `igmp`, `tcp`, `udp`, `ipv6-icmp` built in. |
| `/etc/profile` | `EDITOR=/bin/vi` (no vi in the image) and a `PS1` block that `profile.d/prompt.sh` always replaced | Own `/etc/profile` in the overlay | `rootfs-overlay/etc/profile` | - |
| `/run/lock/subsys`, `/var/lock` | Made at boot by inittab, link in the image; nothing in the main system used them | Removed | `inittab`, `post-build.sh` | Alpine has its own `/run` (and `/run/lock`, which `alsactl` needs) |
| fstab `/dev/root / ext2 rw,noauto` | `/dev/root` does not exist and root is not ext2 | Removed | `post-build.sh` | - |
| inittab `mount -o remount,rw /` | Root is the overlay that preinit already mounted writable | Removed | `inittab` | - |
| The image's `/dev` | `log -> ../tmp/log`, `fd`, `stdin`, `stdout`, `stderr`, `pts`, `shm` | Empty folder | `post-build.sh` | Never seen: the kernel mounts devtmpfs on `/dev` at boot. inittab makes the links, syslogd makes `/dev/log`. |
| Tailscale features | Code for Synology, OpenWrt, Kubernetes, AWS, systemd, apt and yum, and many features | Built with only the parts used | `TAILSCALE_TAGS` in `external.mk` | Add the feature to the `--add=` list and make the tags again (command in `external.mk`). Removed and possibly needed later: `tailnetlock` (Tailnet Lock), `posture` (device posture checks), `useroutes` and `useexitnode` (subnet routes, exit nodes), `logtail` (log upload to Tailscale), `iptables` (only `--netfilter-mode=off` works). Do not remove `unixsocketidentity`: without it every `tailscale` command gets "access denied" (Tailscale bug: the socket is never marked as a unix socket). |

## Not in the image, and fine

Read only if the file exists, or the path exists at runtime, or the code
is never reached on this device.

| Program | Path | Why it is fine |
|---|---|---|
| busybox mount | `/etc/filesystems` | Only for `mount` without `-t`; falls back to `/proc/filesystems` |
| busybox init | `/etc/init.d/rcS` | Only used when there is no `/etc/inittab` |
| busybox modprobe | `/etc/modprobe.conf`, `/etc/modprobe.d` | Optional module options. Put a file there if a driver needs options. |
| syslogd | `/var/log/messages` | `/var/log` links to `/tmp`; made at runtime |
| libuuid | `/var/lib/libuuid/clock*.txt` | Only for time-based UUIDs; mke2fs uses random ones |
| libblkid | `/etc/blkid.conf`, `/etc/blkid.tab`, `/run/blkid/` | Optional settings and cache, made at runtime if needed |
| libblkid | `dmsetup`, `lvdisplay` | Only for LVM disks |
| musl | `/etc/localtime`, zoneinfo folders | No time zone file means UTC |
| musl | `/var/run/nscd/socket`, `/etc/tcb/`, `/bin/csh` | Never used here |
| libfdisk | `/usr/ucb/mdec` | Only for BSD disk labels |
| e2fsck | `/etc/e2fsck.conf`, `/var/lib/e2fsprogs` | Optional |
| mke2fs | `/var/lib/e2fsprogs` | Optional |
| sfdisk | `/etc/terminal-colors.d` | Optional colors |
| dropbear | `/etc/dropbear/*_host_key` | `/etc/dropbear` links to `/persist/dropbear`; keys made with `-R` |
| dropbear | `/bin/cp`, `/usr/bin/dbclient` | Only used by `scp`, which is not in the image |
| wyse-init | `/sbin/openrc` | Run inside `/data/alpine` |
| wyse-init | `/usr/local/rustup/.../library/...rs` (15) | Rust library source paths in error messages. Removing them needs nightly Rust. |
| wyse-init | `/etc/localtime`, zoneinfo | musl, linked in |
| tailscaled, netbird | About 100 paths for other systems: `/etc/os-release`, `/etc/alpine-release`, `/etc/openwrt_release`, `/etc/synoinfo.conf`, `/etc/pki/...`, `/etc/apt/...`, `/etc/yum.repos.d/...`, `/run/systemd/...`, `/var/run/dbus/...`, `/etc/machine-id`, `/etc/nsswitch.conf`, `/etc/resolvconf/...`, `/etc/tailscale/tailscaled-env.txt`, `/etc/netbird/certs`, ... | Go code that looks for other systems, or reads optional files. Without `/etc/nsswitch.conf` Go uses files then DNS. |
| tailscaled | `/var/run/tailscale/tailscaled.sock` | Made at runtime (`/var/run` links to `/run`) |
| netbird | `/var/log/netbird/client.log` | Made at runtime (wyse-init makes the folder; `/var/log` links to `/tmp`) |

## Settings that point to runtime places

| Link or setting | Points to |
|---|---|
| `/etc/mtab` | `/proc/self/mounts` |
| `/etc/resolv.conf` | `/run/resolv.conf` (written by the udhcpc handler) |
| `/var/lib/tailscale`, `/var/lib/netbird`, `/etc/netbird`, `/etc/dropbear` | Folders on `/persist`, made by `wyse-init boot` |
| `/var/log`, `/var/tmp` | `/tmp` |
| `/var/run` | `/run` |

## How this list was made

- Links: `find target -xtype l`.
- Built-in paths: `strings` on every ELF file in the image, each absolute
  path checked against the image (`missing.txt` in the session notes).
- Text files under `/etc`: each absolute path checked the same way.
- Each missing path was then looked up in the program's source.

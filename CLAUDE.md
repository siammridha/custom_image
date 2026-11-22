# How to work in this repo

- Explain things in plain, simple language. Short sentences, everyday words.
  No buzzwords, metaphors or figures of speech. Be direct and literal.
- Answer only what is asked. No extra commentary or caveats.
- Do not add Co-Authored-By trailers to commits.
- Work on your own until the task is done, then give one short summary.
- Write or update docs only after the real work is done and tested.
- This repo is public. Never commit secrets: `config/` (except its README
  and network.example), `.env`, `keys/`, and anything with a
  NetBird/Tailscale key or SSH private key.
  Built images contain these secrets, so images are built locally and never
  published.
- Base new code on what a real, working reference implementation does (read
  its source first), not on memory or a spec.
- Rust is the only programming language: no Go, Python or others. Shell
  scripts are fine.
- Long commands on the device (flashing, big transfers): run them in the
  background and use `ssh -n`. A foreground run once looked frozen.
- Every build: the user must see its progress. Build with `./build.sh`
  run in the background: it prints the progress bar to the shell output
  (full log in `build.log`). Do not run `make` with its output sent to a file
  instead.

# What this is

A small Linux image for Dell Wyse 3040 and 5020 thin clients, built with
Buildroot. The devices sit at remote sites, so the VPNs (NetBird first,
Tailscale as backup) must always come back up.

User's rules for the image:
- Remove everything the device does not use, down to a single file or
  character. Every saved byte counts as a gain, however small; whatever is
  needed later gets installed (`alpine apk add ...`). Small means
  removing what this project does not need, not packing the image
  smaller (compression).
- Smaller than Alpine. All software built from source; driver firmware
  binaries are OK.
- Built in: Tailscale, NetBird, the private root CA, the SSH keys.
- No monitor. The GPU is only for video encode/decode (VA-API). No FFmpeg.
- Don't add software to the image without asking. Drivers or programs that
  only some apps need: drivers go into the model's list
  (`external/board/wyse/modules-<model>`), programs into `/data` (Alpine
  packages).
- Don't add anything to the image only so that scripts outside it (deploy,
  test) can use it. Those scripts get what they need another way (an
  argument, the repo, what the device already has). If something is really
  needed, add it only to development builds; production images never have
  it.

# Layout

- `buildroot/` git submodule: Buildroot 2026.08.2, unchanged. Our edits to
  it are in `patches/buildroot-wyse.patch`; `make` applies it before the
  build and takes it out after, so `buildroot/` shows no changes. To change
  Buildroot: `git -C buildroot apply ../patches/buildroot-wyse.patch`, edit,
  save the diff back (`git -C buildroot diff > patches/buildroot-wyse.patch`)
  and `git -C buildroot checkout .`.
- `external/` Buildroot external tree: `configs/wyse_defconfig`,
  `board/wyse/` (kernel fragments, genimage, grub, post-build, rootfs
  overlay), `package/netbird`.
- `wyse-init/` Rust program (x86_64 musl) that does preinit, boot, services,
  vpn-guard, apps setup and DHCP lease handling. No boot shell scripts.
- `apps/<name>/install.sh` installs an app on a running device.
- `config/` the user's settings and keys, git-ignored (`config/README`):
  `network`, `private-ca-certificates.crt`, `ssh_keys`, `devices/<name>`.
  Files are `name = value` lines, read by `get` in `scripts/config.sh`.
- `build.sh` builds one image per device file (`config/devices/*`).
- `scripts/device-keys.sh` checks a device file, makes its missing keys and
  writes them into the image (run by build.sh and post-build.sh).
- `scripts/deploy.sh <host name>` puts a built image on a running
  device over SSH (IP: `address` in its device file).
  `scripts/install.sh <host name>` writes the whole `disk.img.gz` over SSH
  (first install from Alpine, or a full reinstall; erases `/data`).
- `scripts/check-updates.sh` shows which parts of the image have a newer
  release and their release notes. `scripts/set-version.sh <part> <version>`
  changes the version and checksum of linux, netbird, tailscale, go,
  linux-firmware or buildroot.

# Disk and boot

Partitions: p1 EFI/boot (64M at 1M), p2 read-only squashfs root (512M at
65M), p3 `/data` (rest of the disk; grown on the first boot).
- The overlay is in RAM: every boot starts fresh from the image. `/data` is
  the only place that keeps changes.
- The VPN and SSH keys and the host name are baked into the image, so they
  are the same after every boot. One image per device. Each device has a
  file `config/devices/<any name>`: `model`, `host`, `address` (IP for
  deploy and test), and `ssh_key` (ed25519 seed, hex; also NetBird SSH),
  `netbird` (WireGuard key, base64), `tailscale_state` (below). Only the
  first three are written by hand:
  `scripts/device-keys.sh` makes missing keys and adds them at the end.
  Keys already there are kept, so a device keeps its peers. Unknown or
  repeated names are an error. Tailscale has no key: a new device (empty
  `tailscale_state`) boots logged out; log in by hand (`tailscale up --ssh
  --netfilter-mode=off --hostname=<host>`, open the link), turn off key
  expiry on the Machines page, copy `/var/lib/tailscale/tailscaled.state`
  to `config/tailscale/<name>` and set `tailscale_state = <name>`. Every
  later image boots as that same device and IP, with no login.
- Logs: syslogd writes `/data/log/messages` (kept across reboots, about
  1 MB at most). After a kernel panic, wyse-init boot saves the panic
  text that pstore kept in EFI variables to `/data/log/crash-<time>`.
  After a hardware watchdog reset (3040), the kernel logs `iTCO_wdt: ...
  previous reset was by the watchdog` (`external/patches/linux/`). Other
  resets (power cut, forced reboot) leave no trace: the BIOS clears the
  chip's reset-status registers.
- `/data` keeps apps and `/data/alpine` (an Alpine root: `alpine apk add ...`,
  `alpine <cmd>` runs a command in it). It is a separate subsystem with its
  own busybox (Alpine's); the system's `/bin/busybox` has only the commands
  the main system uses. The image's Alpine archive is trimmed and has the
  private root CA: see `external/board/wyse/alpine-root.sh`.
- Apps are OpenRC services in `/data/alpine`: wyse-init runs `openrc
  sysinit/boot/default` in the chroot (no Alpine init, no PID namespace) and
  `openrc shutdown` at shutdown (`wyse-init stop-apps`). Use
  `alpine rc-status`, `alpine rc-service <name> restart`.
- Apps run as root without some root powers (`as_app()` and `lock_down()`
  in `wyse-init/src/alpine.rs`): no mount, chroot, ptrace, mknod, modules,
  kexec; disk devices in Alpine's /dev are /dev/null; /proc/sys and /sys
  are read-only there. `alpine` commands get the same limits, so
  `/proc/1/root/...` does not work from `alpine`.
- Priorities (`wyse-init/src/prio.rs`): cgroup `vpn` (SSH, VPNs, watchdog,
  ntpd, vpn-guard) has the highest cpu and io weight and memory.min 128M;
  cgroup `apps` has weight 1, memory.max = RAM - 256M, pids.max 4096.
  iocost is turned on for the disk. Each interface gets a 2-band `prio`
  qdisc; an nftables rule (table `ip wyse`) puts traffic from `apps` in the
  low band.
- VPN settings are fixed in the image (no settings file). `config/network`
  `netbird_key` goes to `/etc/wyse/netbird.key` (root only). vpn-guard
  passes the file path (`--setup-key-file`), so the key is never on a
  command line, where apps could read it. The management URL
  (`netbird_url`, required) and the `up` arguments are built into
  wyse-init (`wyse-init/src/config.rs`). `static_host` (one IP and name)
  goes into `/etc/hosts`. `config/ssh_keys` becomes root's
  authorized_keys. `config/private-ca-certificates.crt` (one or more
  certificates) is added to the system bundle between `# begin/end
  private-ca-certificates.crt` lines (replaced on every build) and to
  Alpine's.

# Build

- Fill in `config/` (`config/README`). The private SSH key is not in the
  repo: it is in the Mac's SSH agent, which VS Code forwards to the
  container; deploy and test use the agent (no `-i`).
- `./build.sh [host name ...] [prod]` (no name: every device file),
  or `make MODEL=3040 DEVICE=config/devices/<name>`. Images go to
  `/home/vscode/wyse-build/images/<host name>/`. Each model has its own
  build folder: the Makefile adds `board/wyse/linux-<model>.fragment` to the
  kernel and passes the model to post-build.sh (the device file goes as
  `WYSE_DEVICE`). Builds are development builds unless `prod` is given
  (`make ... PROD=1`). A development build adds the BusyBox commands in
  `board/wyse/busybox-dev.fragment` (ls, grep, ...), a root shell on the
  monitor (tty1, no password), all boot messages on it (no `quiet`) and
  the `test_lockup` module (freezes the CPUs, to test the watchdog);
  production images don't have these. The host name and the model's drivers are built into
  wyse-init (`config.rs`); the dropbear key is `/etc/wyse/dropbear_host_key`.
  Changing `dropbear-localoptions.h` needs `make MODEL=... dropbear-dirclean`. First
  build of a model takes about an hour, later builds minutes. Buildroot
  does not notice kernel fragment changes: run `make MODEL=... linux-reconfigure`.
- Output is in `/home/vscode/wyse-build/output-<model>`, downloads in
  `/home/vscode/wyse-build/dl` (a container volume), not the workspace: the
  Mac file sharing corrupted a download once.
- Go modules for Tailscale and NetBird come from the Go module proxy
  (`external/external.mk`); Buildroot's default clones each module's git
  repo and got stuck on aws-sdk-go-v2. Tailscale is built with only the
  features used (`TAILSCALE_TAGS` in `external/external.mk`); only
  `--netfilter-mode=off` works. NetBird is built without inlining.
- `docs/paths.md`: paths the programs know about that are not in the image,
  what was removed and how to bring it back. Check it when a file is missing.
- The build host is Alpine on arm64. Go is built from source and needs the
  host `go` to start. Host packages are in `.devcontainer/Dockerfile`; if the
  build fails on a missing host tool, add it there.
- Kernel modules: only the system's 8 (IMAGE_MODULES in post-build.sh) and
  the model's drivers (`board/wyse/modules-<model>`, with their
  dependencies) stay in the image; wyse-init loads the model list at boot
  (built into it by post-build.sh).
  Only files matching `board/wyse/firmware-<model>` stay in /lib/firmware;
  lines with a package name come from that Alpine package (SOF firmware
  from `sof-firmware`). 5020 has no lists yet.
- Wyse 3040 at `address` in `config/devices/wyse-3040`. SSH:
  `ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@<ip>`.
  No scp on the device; copy with `ssh ... 'cat > file' < file`.
- Deploy: `scripts/deploy.sh <host name>` (keeps `/data`). It writes only p1 and
  p2, so it can't change the partition layout. `scripts/install.sh` can (erases
  `/data`).
- The image's busybox has no ls, grep, head, sleep, mv, chmod, gzip and more
  (only what the image uses). Use `alpine <cmd>`; scripts bring Alpine's
  busybox from the Alpine archive in the download folder. Unpack `.tar.gz` files with
  `alpine tar -xzf - -C <dir> < f.tar.gz`.
- Built-in sound: SOF driver, card `rt5672`, firmware from Alpine's
  `sof-firmware`. Inside `/data/alpine`, `alsactl` needs `/run/lock`.

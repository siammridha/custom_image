# How to work in this repo

- Explain things in plain, simple language. Short sentences, everyday words.
  No buzzwords, metaphors or figures of speech. Be direct and literal.
- Answer only what is asked. No extra commentary or caveats.
- Do not add Co-Authored-By trailers to commits.
- Work on your own until the task is done, then give one short summary.
- Write or update docs only after the real work is done and tested.
- This repo is public. Never commit secrets: `.env`, `keys/`, `root_ca.crt`,
  and anything with a NetBird/Tailscale key or SSH private key.
  Built images contain these secrets, so images are built locally and never
  published.
- Base new code on what a real, working reference implementation does (read
  its source first), not on memory or a spec.
- This project is Rust only: write new programs and tools in Rust, not Go
  or any other language.
- Long commands on the device (flashing, big transfers): run them in the
  background and use `ssh -n`. A foreground run once looked frozen.
- Every build: the user must see its progress. Build with `./build.sh <model>`
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
  needed later gets installed (`alpine apk add ...`).
- Smaller than Alpine. All software built from source; driver firmware
  binaries are OK.
- Built in: Tailscale, NetBird, the private root CA, the SSH keys.
- No monitor. The GPU is only for video encode/decode (VA-API). No FFmpeg.
- Don't add software to the image without asking. Drivers or programs that
  only some apps need: drivers go into the model's list
  (`external/board/wyse/modules-<model>`), programs into `/data` (Alpine
  packages).

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
- `device-keys/` Rust program run by post-build.sh: bakes the VPN and SSH
  keys into the image.
- `wyse-init/` Rust program (x86_64 musl) that does preinit, boot, services,
  vpn-guard, apps setup and DHCP lease handling. No boot shell scripts.
- `apps/<name>/install.sh` installs an app on a running device.
- `build.sh` asks for the model and builds the image.
- `scripts/deploy.sh <model> [ip]` puts a built image on a running device
  over SSH.

# Disk and boot

Partitions: p1 EFI/boot (64M at 1M), p2 read-only squashfs root (512M at
65M), p3 `/data` (rest of the disk; grown on the first boot).
- The overlay is in RAM: every boot starts fresh from the image. `/data` is
  the only place that keeps changes.
- The VPN and SSH keys and the host name are baked into the image, so they
  are the same after every boot. `device-keys/` (Rust, runs at build time)
  computes each key as SHA-256(secret + label) from `keys/device.secret`
  (made if missing); the host name is `keys/device.hostname` (`build.sh`
  asks). One image per device. Tailscale logs in again at every boot with
  `TAILSCALE_KEY`, so that key must be reusable and not expire.
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
- VPN settings are fixed in the image (no settings file). `.env`
  `NETBIRD_KEY` and `TAILSCALE_KEY` go to `/etc/wyse/netbird.key` and
  `/etc/wyse/tailscale.key` (root only). vpn-guard passes the file paths
  (`--setup-key-file`, `--auth-key=file:`), so the keys are never on a
  command line, where apps could read them. The management URL (from
  `HOST_DOMAIN` or `NETBIRD_URL`) and the `up` arguments are built into
  wyse-init (`wyse-init/src/config.rs`).

# Build

- `cp .env.example .env`, fill it in; make an SSH key (`keys/README`); put
  the private root CA in `root_ca.crt` (`ROOT_CA` in `.env` points to it).
- `./build.sh` or `make MODEL=3040` / `MODEL=5020`. One image per model:
  the Makefile adds `board/wyse/linux-<model>.fragment` to the kernel and
  passes the model to post-build.sh (written to `/etc/wyse/model`). First
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
  dependencies) stay in the image; wyse-init loads the model list at boot.
  Only files matching `board/wyse/firmware-<model>` stay in /lib/firmware;
  lines with a package name come from that Alpine package (SOF firmware
  from `sof-firmware`). 5020 has no lists yet.
- Wyse 3040 at `DEVICE_IP` in `.env`. SSH:
  `ssh -i keys/wyse_ed25519 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@<ip>`.
  No scp on the device; copy with `ssh ... 'cat > file' < file`.
- Deploy: `scripts/deploy.sh 3040` (keeps `/data`). It writes only p1 and
  p2, so it can't change the partition layout.
- The image's busybox has no gzip or gunzip: unpack `.tar.gz` files with
  `alpine tar -xzf - -C <dir> < f.tar.gz`.
- Built-in sound: SOF driver, card `rt5672`, firmware from Alpine's
  `sof-firmware`. Inside `/data/alpine`, `alsactl` needs `/run/lock`.

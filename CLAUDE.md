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
- Long commands on the device (flashing, big transfers): run them in the
  background and use `ssh -n`. A foreground run once looked frozen.

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
  only some apps need go into `/data` (driver packs, Alpine packages).

# Layout

- `buildroot/` git submodule: Buildroot 2026.02.3, unchanged. Our edits to
  it are in `patches/buildroot-wyse.patch`; `make` applies it. To change
  Buildroot, edit in `buildroot/` and save the diff back to the patch
  (`git -C buildroot diff > patches/buildroot-wyse.patch`).
- `external/` Buildroot external tree: `configs/wyse_defconfig`,
  `board/wyse/` (kernel fragments, genimage, grub, post-build, rootfs
  overlay), `package/netbird`.
- `wyse-init/` Rust program (x86_64 musl) that does preinit, boot, services,
  vpn-guard, apps setup and DHCP lease handling. No boot shell scripts.
- `drivers/` driver packs (see `drivers/README`).
- `apps/<name>/install.sh` installs an app on a running device.
- `build.sh` asks for the model and builds the image and its driver packs.
- `scripts/deploy.sh <model> [ip]` puts a built image on a running device
  over SSH.

# Disk and boot

Partitions: p1 EFI/boot (64M at 1M), p2 read-only squashfs root (512M at
65M), p3 `/persist` (128M), p4 overlay/`/data`.
- The overlay is in RAM: every boot starts fresh from the image.
- `/persist` keeps the VPN identities, dropbear host keys and `wyse.conf`.
- `/data` keeps apps and `/data/alpine` (an Alpine root: `alpine apk add ...`,
  `alpine <cmd>` runs a command in it). It is a separate subsystem with its
  own busybox (Alpine's); the system's `/bin/busybox` has only the commands
  the main system uses. The image's Alpine archive is trimmed and has the
  private root CA: see `external/board/wyse/alpine-root.sh`.
- Apps run from `/data/services/<name>/run` under runsvdir (`sv` works).
- `/etc/wyse/vpn.conf` is locked: values come from `.env` at build time.

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
  repo and got stuck on aws-sdk-go-v2. Tailscale is built with
  `ts_omit_aws` (no AWS state store).
- The build host is Alpine on arm64. Go is built from source and needs the
  host `go` to start. Host packages are in `.devcontainer/Dockerfile`; if the
  build fails on a missing host tool, add it there.
- Kernel modules: only 8 stay in the image; the rest go to driver packs
  (`drivers/build.sh <model> <pack>`, lists in `drivers/<model>/`). Packs only load into the exact kernel they
  were built with, so rebuild them after any kernel change.

# Test device

- Wyse 3040 at `DEVICE_IP` in `.env`. SSH:
  `ssh -i keys/wyse_ed25519 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@<ip>`.
  No scp on the device; copy with `ssh ... 'cat > file' < file`.
- Deploy: `scripts/deploy.sh 3040` (keeps `/persist` and `/data`).
- The image's busybox has no `tar -z`: use `gunzip -c f.tar.gz | tar -x`.
- Built-in sound: SOF driver, card `rt5672`, firmware from Alpine's
  `sof-firmware`. Inside `/data/alpine`, `alsactl` needs `/run/lock`.

# custom-image

A small Linux image for Dell Wyse 3040 and 5020 thin clients, built with
Buildroot. Headless. NetBird and Tailscale are built in, so remote devices
stay reachable.

## Build

Clone with `git clone --recursive` (Buildroot is a submodule; the build also
fetches it). Open the folder in its dev container (`.devcontainer/`), then:

    cp .env.example .env        # fill in your keys
    cp /path/to/ca.crt root_ca.crt   # private root CA of your NetBird server
    ssh-keygen -t ed25519 -N '' -C wyse -f keys/wyse_ed25519
    ./build.sh                  # asks: 3040 or 5020

The first build of a model takes about an hour; later builds only redo what
changed. `./build.sh 3040` skips the question. The full log is in `build.log`.

The image is `/home/vscode/wyse-build/output-<model>/images/disk.img`.
Each model has its own image: the kernel drivers differ. The drivers a
model uses are in the image (`external/board/wyse/modules-<model>`) and
load at boot; only the firmware files on `firmware-<model>` are kept.

Your VPN keys and SSH key are baked into the image. Keep built images
private.

## Install

- New device: write `disk.img` to its eMMC.
- Running device: `scripts/deploy.sh <model> [ip]`. Keeps `/persist` and
  `/data`. Refuses if the device runs the other model's image.

## Alpine subsystem

The device has a second, small system: Alpine Linux in `/data/alpine`. It
keeps the main system small and unchanged.

- `alpine apk add <package>` installs Alpine packages into it (kept on
  `/data`).
- `alpine` opens a shell inside it; `alpine <cmd>` runs one command in it.
  `exit` goes back to the main system.
- All apps run inside it (with `chroot`). wyse-init starts Alpine's
  OpenRC, which starts the apps; each app's `supervise-daemon` restarts it
  when it stops (`alpine rc-status`, `alpine rc-service <name> restart`).
  At shutdown `openrc shutdown` stops the apps cleanly.
- It shares the main system's processes: `alpine ps` and `alpine top` show
  everything.
- It has its own busybox (Alpine's). The main system's busybox has only the
  commands the main system uses.
- SSH, NetBird and Tailscale stay in the main system.
- Apps run as root, but can't reach the main system's files: they can't
  see `/persist` (VPN and SSH keys) or the disk, mount anything, leave the
  Alpine folder, load kernel modules or change kernel settings (`/proc/sys`
  and `/sys` are read-only in Alpine). They can still see, stop and kill
  system processes; init starts those again.
- SSH and the VPNs come first. They get almost all of the CPU, disk and
  network when they need it, and 128 MB of RAM that apps can't take. Apps
  can't use the last 256 MB of RAM, can't run more than 4096 processes and
  can't use real-time priority. App network traffic waits behind the VPNs'
  traffic.
- If the network link goes down and comes back (cable, switch, router),
  the device gets its default route back within 30 s: vpn-guard asks
  udhcpc to renew the lease whenever there is no default route.

## Apps and drivers

Apps are installed after boot into `/data` and run in the Alpine subsystem:

- `apps/audio-player/install.sh` - audio player on port 3000.
- `apps/simple-kvm/install.sh` - KVM over the web on port 3001.

Copy the script to the device and run `sh install.sh`. Both need a Wyse
3040: its sound and GPU drivers are in the image.

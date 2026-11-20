# custom-image

A small Linux image for Dell Wyse 3040 and 5020 thin clients, built with
Buildroot. Headless. NetBird and Tailscale are built in, so remote devices
stay reachable.

## Build

Clone with `git clone --recursive` (Buildroot is a submodule; the build also
fetches it). Open the folder in its dev container (`.devcontainer/`), then:

    mkdir -p config/devices
    cp config/network.example config/network     # fill it in
    cp /path/to/ca.crt config/private-ca-certificates.crt
    cat ~/.ssh/wyse_ed25519.pub > config/ssh_keys
    printf 'model   = 3040\nhost    = shop-01\naddress = 192.168.1.20\n' > config/devices/shop-01
    ./build.sh                  # development images, one per config/devices/ file
    ./build.sh prod             # production images (put these on devices at sites)

`config/README` explains each file. Your private SSH key stays on your
computer, in its SSH agent (`ssh-add`); VS Code passes the agent into the
container, and deploy uses it.

The first build of a model takes about an hour; later builds only redo what
changed, and every further device of the same model takes minutes. The full
log is in `build.log`.

The images are in `/home/vscode/wyse-build/images/<host name>/` (`efi-part.vfat` and `rootfs.squashfs` for deploy,
`disk.img.gz` for install: the whole disk, packed).
Images of different models differ in their kernel drivers. The drivers a
model uses are in the image (`external/board/wyse/modules-<model>`) and
load at boot; only the firmware files on `firmware-<model>` are kept.

Your VPN keys and SSH key are baked into the image. Keep built images
private.

Each device has its own image and its own file `config/devices/<any name>`
with `model`, `host` and `address` (its IP, for deploy). The build makes
the device's SSH host key, NetBird key and Tailscale key and adds them to
the file (see `scripts/device-keys.sh`). The keys are the same after every boot
and every new image. Keep a copy of the files: without them the devices get
new VPN identities.

## Install

- Device running Linux with SSH (Alpine, or this image):
  `scripts/install.sh <host name>`. Writes the whole disk and its partitions;
  erases `/data`. Sends `disk.img.gz` (about 43 MB) and asks for the host
  name first.
- Running device: `scripts/deploy.sh <host name>`. Keeps `/data`.
  Refuses if the device's BIOS model name is not the device file's model.

## Updates

The main system (Linux, NetBird, Tailscale, ...) only changes with a new
image. To see which parts have a newer release, and what changed since your
version:

    scripts/check-updates.sh

To change a part's version (with its checksum):

    scripts/set-version.sh <linux|netbird|tailscale|go|linux-firmware|buildroot> <version>

Parts marked "Buildroot" change when Buildroot is updated. Parts marked
"next build" (the Alpine archive, sof-firmware, OpenRC) update by themselves
at every build. Rust: `rustup update` in the dev container. After a change:
build, deploy to a test device and run `scripts/test-device.sh <host name>`
before putting it on devices at sites.

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
  read the VPN and SSH keys or the disk, mount anything, leave the
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

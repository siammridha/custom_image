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
changed. `./build.sh 3040` skips the question. It also builds that model's
driver packs. The full log is in `build.log`.

The image is `/home/vscode/wyse-build/output-<model>/images/disk.img`.
Each model has its own image: the kernel drivers differ.

Your VPN keys and SSH key are baked into the image. Keep built images
private.

## Install

- New device: write `disk.img` to its eMMC.
- Running device: `scripts/deploy.sh <model> [ip]`. Keeps `/persist` and
  `/data`. Refuses if the device runs the other model's image.

## Apps and drivers

Apps are installed after boot into `/data`:

- `apps/audio-player/install.sh` - audio player on port 3000 (needs the
  `sound` driver pack).
- `apps/simple-kvm/install.sh` - KVM over the web on port 3001 (needs the
  `kvm` driver pack).

Copy the script and the driver pack to the device and run
`sh install.sh wyse-drivers-3040-<pack>-<kernel>.tar.gz`. Drivers that only some apps need are shipped
as driver packs: see `drivers/README`.

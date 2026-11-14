# custom-image

A small Linux image for Dell Wyse 3040 and 5020 thin clients, built with
Buildroot. Headless. NetBird and Tailscale are built in, so remote devices
stay reachable.

## Build

Clone with `git clone --recursive` (Buildroot is a submodule; `make` also
fetches it). Open the folder in its dev container (`.devcontainer/`), then:

    cp .env.example .env        # fill in your keys
    cp /path/to/ca.crt root_ca.crt   # private root CA of your NetBird server
    ssh-keygen -t ed25519 -N '' -C wyse -f keys/wyse_ed25519
    make                        # about an hour the first time

The image is `/home/vscode/wyse-build/output/images/disk.img`.

Your VPN keys and SSH key are baked into the image. Keep built images
private.

## Install

- New device: write `disk.img` to its eMMC.
- Running device: `scripts/deploy.sh [ip]`. Keeps `/persist` and `/data`.

## Apps and drivers

Apps are installed after boot into `/data`, for example
`apps/audio-player/install.sh`. Drivers that only some apps need are shipped
as driver packs: see `drivers/README`.

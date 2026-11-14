# Shared tools (Rust, gh, Claude Code, ...) come from devbase; see
# base/Dockerfile in github.com/siammridha/devcontainer-template. devbase is
# Alpine, so the host tools Buildroot needs are Alpine packages.
FROM ghcr.io/siammridha/devbase:latest
USER root

# Buildroot host tools. GNU find/tar/coreutils: Buildroot's download and
# packaging steps fail with busybox's. go: bootstraps Buildroot's own Go
# (NetBird and Tailscale are Go). argp/fts/obstack/libintl: host elfutils
# (not gettext-dev: its libintl.h needs -lintl and libelf.so fails to link).
# qemu: test the image in a VM (BIOS boot; Alpine arm64 has no x86 OVMF).
RUN apk add --no-cache \
        bash build-base ncurses-dev perl wget cpio unzip rsync bc file patch \
        linux-headers python3 git which gawk tar xz bzip2 gzip diffutils \
        coreutils findutils grep sed util-linux mtools dosfstools e2fsprogs \
        e2fsprogs-extra squashfs-tools flex bison go \
        argp-standalone musl-fts-dev musl-obstack-dev musl-libintl \
        qemu-system-x86_64 openssh-client

# wyse-init (Rust) is built for the Wyse (x86_64 musl). chown: RUSTUP_HOME
# belongs to vscode, so `rustup update` still works inside the container.
RUN rustup target add x86_64-unknown-linux-musl \
    && chown -R vscode:vscode /usr/local/rustup
USER vscode

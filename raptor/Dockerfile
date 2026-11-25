# raptor (https://github.com/rosterloh/raptor): update server for the Wyse
# thin clients (hawkBit device API). raptor ships no Docker image, so it is
# built here from its source, with its web page built in (embed-ui).
# Built on GitHub (.github/workflows/raptor.yml) as ghcr.io/siammridha/raptor;
# the homeLab-server repo runs that image (raptor/docker-compose.yml there).
#
# Build steps from raptor's own release (.github/workflows/release.yml,
# mise.toml): `dx build --release --package raptor-ui`, then
# `cargo build --release` with the embed-ui feature.

# The raptor release to build (the workflow tags the image with it)
ARG RAPTOR_VERSION=1.3.2

# 1. The web page, on Debian like raptor's release (Ubuntu): dx downloads
# wasm-bindgen and tailwindcss built for glibc, which don't run on Alpine.
FROM rust:1.99.1-trixie AS ui
ARG RAPTOR_VERSION
# dioxus-cli version from raptor's mise.toml (must equal raptor-ui's dioxus)
RUN cargo install dioxus-cli --version 0.7.10 --locked
RUN git clone --depth 1 --branch v$RAPTOR_VERSION https://github.com/rosterloh/raptor /src
WORKDIR /src
# rust-toolchain.toml pins 1.99.1 with the wasm32 target
RUN rustup toolchain install
RUN dx build --release --package raptor-ui

# 2. The server, on Alpine (musl), with the page from step 1 built in.
FROM rust:1.99.1-alpine3.23 AS build
ARG RAPTOR_VERSION
RUN apk add --no-cache git musl-dev
RUN git clone --depth 1 --branch v$RAPTOR_VERSION https://github.com/rosterloh/raptor /src
WORKDIR /src
RUN rustup toolchain install
# embed-ui reads the page from here (raptor/src/ui.rs)
COPY --from=ui /src/target/dx/raptor-ui/release/web/public target/dx/raptor-ui/release/web/public
RUN cargo build --release --locked -p raptor --features embed-ui

FROM alpine:3.23
RUN adduser -D -H -u 1000 raptor && mkdir /data && chown raptor /data
COPY --from=build /src/target/release/raptor /usr/local/bin/raptor
USER raptor
ENTRYPOINT ["raptor", "serve", "--config", "/etc/raptor/config.toml"]

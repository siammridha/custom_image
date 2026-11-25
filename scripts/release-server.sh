#!/bin/sh
# Builds the raptor update server image on this machine and pushes it to
# ghcr.io, doing what .github/workflows/raptor.yml does. Needs Docker with
# buildx (not in the dev container: run it on the Mac) and a one-time
# `docker login ghcr.io` with a token that has `write:packages`.
#
# Usage: scripts/release-server.sh
# The version is raptor's: RAPTOR_VERSION in raptor/Dockerfile. To move to a
# new raptor release, change it there first.
set -eu

image=ghcr.io/siammridha/raptor
# The home server is x86; use PLATFORM=linux/arm64 if it ever moves to ARM.
platform="${PLATFORM:-linux/amd64}"

cd "$(dirname "$0")/.."
if [ -n "$(git status --porcelain raptor)" ]; then
  echo "Commit raptor/ first: the image is built from it." >&2
  exit 1
fi
version="$(sed -n 's/^ARG RAPTOR_VERSION=//p' raptor/Dockerfile)"
[ -n "$version" ] || { echo "No RAPTOR_VERSION in raptor/Dockerfile." >&2; exit 1; }
echo "Releasing raptor $version"

docker buildx build --platform "$platform" \
  -t "$image:latest" -t "$image:$version" \
  --push raptor
# The local image and build cache are kept, so the next build reuses them.

#!/bin/sh
# Build one image per device. Each device has its own file: keys/device.<any
# name> with the model and host name, and its keys (made on the first build;
# see scripts/device-keys.sh).
#
#   ./build.sh                     every keys/device.* file
#   ./build.sh keys/device.shop1   only these devices (one or more files)
#   ... dev                        development build: extra BusyBox commands
#                                  for scripts and SSH (busybox-dev.fragment).
#                                  Never for a device at a site.
#
# Images go to /home/vscode/wyse-build/images/<host name>/. The full log of
# the last build goes to build.log. The first build of a model takes about an
# hour; later builds (and every further device) only redo what changed.
set -eu
cd "$(dirname "$0")"

DEV=
FILES=
for a in "$@"; do
	case $a in
		dev) DEV=1 ;;
		*) [ -f "$a" ] || { echo "No such device file: $a" >&2; exit 1; }
		   FILES="$FILES $a" ;;
	esac
done
[ -n "$FILES" ] || FILES=$(ls keys/device.* 2>/dev/null || true)
if [ -z "$FILES" ]; then
	echo "No device files. Make one per device, for example keys/device.shop1:" >&2
	printf '  3040\n  shop-01\n' >&2
	echo "(model, then host name; the build adds the keys)" >&2
	exit 1
fi

# Settings baked into the image.
[ -f .env ] || { echo "No .env: copy .env.example to .env and fill it in." >&2; exit 1; }
CA=$(sed -n 's/^ROOT_CA=//p' .env | tr -d '"\r')
[ -z "$CA" ] || [ -f "$CA" ] || { echo "ROOT_CA in .env points to $CA, which does not exist." >&2; exit 1; }

# Check every file and make missing keys first, then build grouped by model
# (devices of the same model reuse the same build folder).
for f in $FILES; do scripts/device-keys.sh "$f"; done
LIST=$(for f in $FILES; do echo "$(sed -n 1p "$f") $(sed -n 2p "$f") $f"; done | sort)
echo "$LIST" | awk '{print $2}' | sort | uniq -d | grep . >&2 &&
	{ echo "These host names are in more than one device file." >&2; exit 1; }

start=$(date +%s)
echo "$LIST" | while read -r MODEL H F; do
	echo "Building $H (Wyse $MODEL${DEV:+, development}) from $F (log: build.log)..."
	make MODEL=$MODEL DEVICE="$F" DEV=$DEV > build.log 2>&1 &
	BUILD=$!
	# Progress bar (scripts/build-progress.sh) once the config exists.
	O=/home/vscode/wyse-build/output-$MODEL
	while kill -0 $BUILD 2>/dev/null && ! [ -f "$O/build/build-time.log" ]; do sleep 2; done
	kill -0 $BUILD 2>/dev/null && WYSE_BUILD_PID=$BUILD scripts/build-progress.sh "$MODEL" < /dev/null || true
	if ! wait $BUILD; then
		tail -n 20 build.log
		echo "Build of $H failed. See build.log." >&2
		exit 1
	fi
	I=/home/vscode/wyse-build/images/$H
	mkdir -p "$I" && chmod 700 "$I"
	cp "$O/images/efi-part.vfat" "$O/images/rootfs.squashfs" "$O/images/disk.img" "$I/"
	echo "  $H: $I"
done
echo "Done in $(( ($(date +%s) - start) / 60 )) min."
echo "  Install on a running device:  scripts/deploy.sh <host name> [device-ip]"

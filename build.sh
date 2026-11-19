#!/bin/sh
# Build one image per device. Each device has its own file in
# config/devices/ (see config/README).
#
#   ./build.sh                  every device in config/devices/
#   ./build.sh shop-01 ...      only these devices (their host names)
#   ... prod                    production build. Without it: development
#                               build (extra BusyBox commands, root shell on
#                               the monitor). Never put a development build
#                               on a device at a site.
#
# Images go to /home/vscode/wyse-build/images/<host name>/. The full log of
# the last build goes to build.log. The first build of a model takes about an
# hour; later builds (and every further device) only redo what changed.
set -eu
cd "$(dirname "$0")"
CFG=config
. scripts/config.sh

PROD=
FILES=
for a in "$@"; do
	case $a in
		prod) PROD=1 ;;
		*) FILES="$FILES $(device_file "$a")" ;;
	esac
done
[ -n "$FILES" ] || FILES=$(ls config/devices/* 2>/dev/null || true)
if [ -z "$FILES" ]; then
	echo "No device files. Make one per device, for example config/devices/shop-01:" >&2
	printf '  model = 3040\n  host  = shop-01\n' >&2
	echo "(the build adds the keys; see config/README)" >&2
	exit 1
fi
[ -f config/network ] || { echo "No config/network: copy config/network.example and fill it in." >&2; exit 1; }

# Check every file and make missing keys first, then build grouped by model
# (devices of the same model reuse the same build folder).
for f in $FILES; do scripts/device-keys.sh "$f"; done
LIST=$(for f in $FILES; do echo "$(get "$f" model) $(get "$f" host) $f"; done | sort -u)
echo "$LIST" | awk '{print $2}' | sort | uniq -d | grep . >&2 &&
	{ echo "These host names are in more than one device file." >&2; exit 1; }

KIND=development; [ -z "$PROD" ] || KIND=production
start=$(date +%s)
echo "$LIST" | while read -r MODEL H F; do
	echo "Building $H (Wyse $MODEL, $KIND) from $F (log: build.log)..."
	make MODEL=$MODEL DEVICE="$F" PROD=$PROD > build.log 2>&1 &
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
echo "  Install on a running device:  scripts/deploy.sh <host name>"

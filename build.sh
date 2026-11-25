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

# Old versions: a production build stops, a development build only warns.
# These are the parts whose versions we set ourselves; the other Buildroot
# parts change with Buildroot. Fix with scripts/set-version.sh.
echo "Checking for newer versions..."
OLD=$(scripts/check-updates.sh 2>/dev/null | awk 'NF == 0 { exit } 1' |
	grep -E '^(Buildroot|Linux|linux-firmware|NetBird|Tailscale|Go|Rust) ' |
	grep -E 'UPDATE|can.t check' || true)
if [ -n "$OLD" ]; then
	echo "$OLD" >&2
	if [ -n "$PROD" ]; then
		echo "Production build stopped: the parts above are old (or couldn't be checked)." >&2
		echo "Update with scripts/set-version.sh <part> <version>, test on the dev device, then build again." >&2
		exit 1
	fi
	echo "Warning: the parts above are old. A production build would stop." >&2
fi

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
	rm -f "$I/efi-part.vfat"
	cp "$O/images/rootfs.squashfs" "$O/target/etc/wyse/version" "$I/"
	# Whole disk for scripts/install.sh, packed: about 360 MB, mostly empty.
	rm -f "$I/disk.img"
	gzip -c "$O/images/disk.img" > "$I/disk.img.gz"
	echo "  $H: $I"
done
echo "Done in $(( ($(date +%s) - start) / 60 )) min."
echo "  Install on a running device:  scripts/deploy.sh <host name>"

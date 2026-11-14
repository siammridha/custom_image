#!/bin/sh
# Make a driver pack: the kernel modules for one kind of hardware, taken
# from the image build, so an app's install script can put them in /data.
#
#   drivers/build.sh sound      modules listed in drivers/sound.modules
#
# Run after building the image ("make" in wyse/). Output:
#   drivers/out/wyse-drivers-<pack>-<kernel>.tar.gz
# It holds lib/modules/<kernel>/... for the listed modules and every module
# they need. Unpack it into /data/alpine and load the modules with Alpine's
# modprobe (apk add kmod).
#
# The pack's kernel settings are in board/wyse/linux.fragment. A pack only
# loads into the kernel it was made with: make the packs again after every
# kernel change.
set -eu

PACK=${1:?usage: drivers/build.sh <pack>}
HERE=$(cd "$(dirname "$0")" && pwd)
LIST=$HERE/$PACK.modules
OUT=${WYSE_OUT:-/home/vscode/wyse-build/output}
POOL=$OUT/build/wyse-driver-pool
[ -f "$LIST" ] || { echo "no $LIST" >&2; exit 1; }
[ -d "$POOL/lib/modules" ] || { echo "build the image first (no $POOL)" >&2; exit 1; }
KREL=$(ls "$POOL/lib/modules")
M=$POOL/lib/modules/$KREL
DEP=$M/modules.dep

# Module name -> its path in modules.dep ("-" and "_" are the same).
path_of() {
	n=$(echo "$1" | tr - _)
	awk -F: -v n="$n" '{ b = $1; sub(/.*\//, "", b); sub(/\.ko.*/, "", b); gsub(/-/, "_", b)
		if (b == n) { print $1; exit } }' "$DEP"
}

# The listed modules, plus everything they need (modules.dep and softdeps).
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
todo=$(grep -v '^#' "$LIST" | tr -s ' \n' '\n\n' | grep .)
: > "$W/files"
while [ -n "$todo" ]; do
	next=
	for m in $todo; do
		p=$(path_of "$m")
		[ -n "$p" ] || { echo "$m: not built (check board/wyse/linux.fragment)" >&2; exit 1; }
		grep -qxF "$p" "$W/files" && continue
		echo "$p" >> "$W/files"
		for d in $(grep "^$p:" "$DEP" | cut -d: -f2-); do
			next="$next ${d##*/}"
		done
		n=$(echo "$m" | tr - _)
		for d in $(awk -v n="$n" '$1 == "softdep" { x = $2; gsub(/-/, "_", x); if (x == n) for (i = 3; i <= NF; i++) if ($i !~ /:$/) print $i }' "$M/modules.softdep" 2>/dev/null); do
			[ -n "$(path_of "$d")" ] && next="$next $d"
		done
	done
	todo=$(echo "$next" | sed 's/\.ko[^ ]*//g')
done

R=$W/root/lib/modules/$KREL
mkdir -p "$R"
while read -r p; do
	mkdir -p "$R/$(dirname "$p")"
	cp "$M/$p" "$R/$p"
done < "$W/files"
cp "$M/modules.builtin" "$M/modules.builtin.modinfo" "$M/modules.order" "$R/" 2>/dev/null || true
"$OUT/host/sbin/depmod" -b "$W/root" "$KREL"

mkdir -p "$HERE/out"
T=$HERE/out/wyse-drivers-$PACK-$KREL.tar.gz
tar -czf "$T" -C "$W/root" --owner=0 --group=0 lib
echo "$T ($(du -h "$T" | cut -f1), $(wc -l < "$W/files") modules):"
sed 's|.*/||; s|\.ko.*||' "$W/files" | sort | tr '\n' ' '
echo

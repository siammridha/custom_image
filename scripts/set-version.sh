#!/bin/sh
# Change the version of one part of the image, with its checksum.
#
#   scripts/set-version.sh linux 6.18.65
#   scripts/set-version.sh netbird 0.84.0
#   scripts/set-version.sh tailscale 1.106.0
#   scripts/set-version.sh go 1.27.5
#   scripts/set-version.sh linux-firmware 20261120
#   scripts/set-version.sh buildroot 2026.11
#
# scripts/check-updates.sh shows which parts have a newer release.
# Then build, deploy to a test device and test before using the new version.
#
# Checksums: Go and linux-firmware from their official lists (go.dev,
# kernel.org). NetBird and Tailscale: Buildroot packs the source together
# with its Go modules into its own archive, so no official checksum exists;
# this downloads it once (make <part>-source) and records its checksum.
# Tailscale, Go and linux-firmware are set in patches/buildroot-wyse.patch.
set -eu
cd "$(dirname "$0")/.."
P=${1:?usage: $0 <linux|netbird|tailscale|go|linux-firmware|buildroot> <version>}
V=${2:?usage: $0 $P <version>}
V=${V#v}
PATCH=patches/buildroot-wyse.patch
DL=${WYSE_DL:-/home/vscode/wyse-build/dl}
MODEL=3040   # any model: only used to download the source
TMP=$(mktemp -d)
cp "$PATCH" external/package/netbird/netbird.mk external/package/netbird/netbird.hash \
	external/configs/wyse_defconfig "$TMP/"
restore() {
	cp "$TMP/buildroot-wyse.patch" "$PATCH"
	cp "$TMP/netbird.mk" "$TMP/netbird.hash" external/package/netbird/
	cp "$TMP/wyse_defconfig" external/configs/
}
ok=
trap '[ -n "$ok" ] || { git -C buildroot checkout -q . 2>/dev/null; restore; echo "Nothing changed." >&2; }; rm -rf "$TMP"' EXIT

get() { curl -fsSL --max-time 60 "$@"; }
# inbr CMD...: run CMD in buildroot/ with our patch applied, then save the
# changes back into the patch and leave buildroot/ unchanged.
inbr() {
	git -C buildroot apply "../$PATCH"
	(cd buildroot && "$@")
	git -C buildroot diff > "$PATCH"
	git -C buildroot checkout -q .
}
# setvar FILE VAR VALUE: change the line "VAR = ..." in FILE.
setvar() {
	grep -q "^$2 = " "$1" || { echo "$1: no $2 line" >&2; exit 1; }
	sed -i "s|^$2 = .*|$2 = $3|" "$1"
}
# fetch PKG: download PKG's source with Buildroot (log in $TMP/log).
fetch() {
	echo "Downloading $1 $V (log: $TMP/log)..."
	# Without this, Buildroot skips the download if it fetched this version before.
	rm -f "${WYSE_OUT:-/home/vscode/wyse-build/output-$MODEL}/build/$1-$V/.stamp_downloaded"
	make MODEL=$MODEL "$1-source" > "$TMP/log" 2>&1 || { tail -n 20 "$TMP/log"; exit 1; }
}
# vendored PKG HASHFILE: record the checksums of the source archive Buildroot
# made and of its LICENSE. HASHFILE relative to the current folder.
vendored() {
	f=$(ls "$DL/$1/$1-$V"-go*.tar.gz 2>/dev/null | sort -V | tail -n 1)
	[ -n "$f" ] || { echo "no $1-$V archive in $DL/$1" >&2; exit 1; }
	lic=$(tar -tzf "$f" | grep -m1 '^[^/]*/LICENSE$')
	{
		echo "# Locally computed (go-vendored tarball)"
		echo "sha256  $(sha256sum < "$f" | cut -d' ' -f1)  ${f##*/}"
		echo "sha256  $(tar -xzOf "$f" "$lic" | sha256sum | cut -d' ' -f1)  LICENSE"
	} > "$2"
}

case $P in
linux)
	get -I "https://cdn.kernel.org/pub/linux/kernel/v${V%%.*}.x/linux-$V.tar.xz" > /dev/null 2>&1 ||
		{ echo "no Linux $V on kernel.org" >&2; exit 1; }
	sed -i "s|^BR2_LINUX_KERNEL_CUSTOM_VERSION_VALUE=.*|BR2_LINUX_KERNEL_CUSTOM_VERSION_VALUE=\"$V\"|" external/configs/wyse_defconfig
	;;
netbird)
	setvar external/package/netbird/netbird.mk NETBIRD_VERSION "$V"
	mv external/package/netbird/netbird.hash "$TMP/netbird.hash.old"   # no hash file: Buildroot only warns
	fetch netbird
	vendored netbird external/package/netbird/netbird.hash
	;;
tailscale)
	# Without its hash file Buildroot only warns; then the file is written new.
	inbr sh -c "sed -i 's|^TAILSCALE_VERSION = .*|TAILSCALE_VERSION = $V|' package/tailscale/tailscale.mk && rm package/tailscale/tailscale.hash"
	fetch tailscale
	vendored tailscale "$TMP/tailscale.hash"
	inbr cp "$TMP/tailscale.hash" package/tailscale/tailscale.hash
	;;
go)
	h=$(get 'https://go.dev/dl/?mode=json&include=all' |
		jq -r --arg f "go$V.src.tar.gz" '.[].files[] | select(.filename == $f) | .sha256')
	[ -n "$h" ] || { echo "no Go $V on go.dev" >&2; exit 1; }
	inbr sh -c "sed -i 's|^GO_VERSION = .*|GO_VERSION = $V|' package/go/go.mk &&
		sed -i 's|^sha256  [0-9a-f]*  go[0-9.]*\.src\.tar\.gz\$|sha256  $h  go$V.src.tar.gz|' package/go/go.hash &&
		grep -q 'go$V.src.tar.gz' package/go/go.hash"
	;;
linux-firmware)
	h=$(get https://cdn.kernel.org/pub/linux/kernel/firmware/sha256sums.asc |
		awk -v f="linux-firmware-$V.tar.xz" '$2 == f { print $1 }')
	[ -n "$h" ] || { echo "no linux-firmware $V on kernel.org" >&2; exit 1; }
	inbr sh -c "sed -i 's|^LINUX_FIRMWARE_VERSION = .*|LINUX_FIRMWARE_VERSION = $V|' package/linux-firmware/linux-firmware.mk &&
		sed -i 's|^sha256  [0-9a-f]*  linux-firmware-[0-9]*\.tar\.xz\$|sha256  $h  linux-firmware-$V.tar.xz|' package/linux-firmware/linux-firmware.hash &&
		grep -q 'linux-firmware-$V.tar.xz' package/linux-firmware/linux-firmware.hash"
	;;
buildroot)
	git -C buildroot fetch -q --tags
	git -C buildroot checkout -q "$V"
	ok=1
	echo "buildroot/ is now at $V (commit it with: git add buildroot)."
	if git -C buildroot apply --check "../$PATCH" 2>"$TMP/err"; then
		echo "Our patch still applies."
	else
		echo "Our patch does NOT apply. These parts changed in Buildroot $V:"
		cat "$TMP/err"
		echo "Fix them (CLAUDE.md, \"To change Buildroot\"), or go back: git -C buildroot checkout <old version>"
	fi
	# Versions our patch sets, next to the new Buildroot's own.
	grep '^+[A-Z0-9_]*_VERSION = ' "$PATCH" | sed 's/^+//' | while read -r var _ ours; do
		f=$(grep -l "^$var = " buildroot/package/*/*.mk buildroot/package/*/*/*.mk 2>/dev/null | head -n 1)
		theirs=$(sed -n "s/^$var = //p" "$f")
		if [ "$(printf '%s\n%s\n' "$ours" "$theirs" | sort -V | tail -n 1)" = "$ours" ] && [ "$ours" != "$theirs" ]; then
			echo "  $var: patch $ours, Buildroot $theirs (keep the patch line)"
		else
			echo "  $var: patch $ours, Buildroot $theirs (Buildroot caught up: remove it from the patch)"
		fi
	done
	M=$(sed -n 's/^BR2_GCC_VERSION_\([0-9]*\)_X=y/\1/p' external/configs/wyse_defconfig)
	grep -q "^config BR2_GCC_VERSION_${M}_X" buildroot/package/gcc/Config.in.host ||
		echo "Buildroot $V has no GCC $M: change BR2_GCC_VERSION_${M}_X in wyse_defconfig."
	echo "A new Buildroot rebuilds everything: about an hour per model."
	exit 0
	;;
*) echo "unknown part: $P" >&2; exit 1 ;;
esac
ok=1
echo "$P set to $V. Next: ./build.sh, deploy to a test device, scripts/test-device.sh."

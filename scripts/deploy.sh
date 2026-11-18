#!/bin/sh
# Put the built image on a running Wyse over SSH, then reboot it.
#
#   scripts/deploy.sh <model> [device-ip]    (model: 3040 or 5020;
#                                             ip default: DEVICE_IP in .env)
#
# Writes only the boot (p1) and root (p2) partitions; /data is kept. The
# device runs scripts/update.sh from RAM with a copied busybox, so it does
# not depend on the old root filesystem while overwriting it. The busybox
# is Alpine's, from the archive the build downloaded: the image's own has
# only the commands the image uses.
# Same partition offsets as external/board/wyse/genimage.cfg.
set -eu
cd "$(dirname "$0")/.."
get() { sed -n "s/^$1=//p" .env 2>/dev/null | head -n 1 | tr -d '"\r'; }
MODEL=${1:-}
case $MODEL in 3040|5020) ;; *) echo "usage: $0 <3040|5020> [device-ip]" >&2; exit 1 ;; esac
IP=${2:-$(get DEVICE_IP)}
KEY=$(get SSH_KEY_FILE); KEY=${KEY:-keys/wyse_ed25519}
[ -n "$IP" ] || { echo "usage: $0 <3040|5020> <device-ip> (or DEVICE_IP in .env)" >&2; exit 1; }
O=${WYSE_OUT:-/home/vscode/wyse-build/output-$MODEL}
AT=$(ls "${WYSE_DL:-/home/vscode/wyse-build/dl}"/alpine/alpine-minirootfs-*-x86_64.tar.gz 2>/dev/null | sort -V | tail -n 1)
[ -n "$AT" ] || { echo "no Alpine archive in the download folder: build first" >&2; exit 1; }
SSH="ssh -i $KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10"
[ -f "$O/images/rootfs.squashfs" ] || { echo "no image: build it first (make MODEL=$MODEL)" >&2; exit 1; }

# The disk the device booted from: the read-only root (/rom) must be its
# partition 2. Then the device's model name from the BIOS (DMI), for
# example "Wyse 3040 Thin Client".
set -- $($SSH -n root@"$IP" 'p=$(readlink -f /sys/dev/block/$(mountpoint -d /rom))
	echo /dev/$(basename $(dirname $p)) $(cat $p/partition) $(cat /sys/class/dmi/id/product_name)')
DISK=${1:-}; PART=${2:-}; shift 2 || true; NAME="$*"
case "$NAME" in
	*"$MODEL"*) ;;
	*) echo "$IP is a \"$NAME\", not a Wyse $MODEL. Not installing." >&2; exit 1 ;;
esac
[ "$PART" = 2 ] && [ -n "$DISK" ] ||
	{ echo "can't find the device's disk (got '$DISK' partition '$PART')" >&2; exit 1; }

echo "Copying to $IP..."
# busybox, ld-musl and update.sh in /tmp/inst, sent as a tar so they keep
# their permissions.
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir "$TMP/inst"
tar -xzf "$AT" -C "$TMP" ./bin/busybox ./lib/ld-musl-x86_64.so.1
mv "$TMP/bin/busybox" "$TMP/lib/ld-musl-x86_64.so.1" "$TMP/inst/"
cp scripts/update.sh "$TMP/inst/"
tar -cf - -C "$TMP" inst | $SSH root@"$IP" 'tar -xf - -C /tmp'
for f in "$O/images/efi-part.vfat:boot.vfat" \
	"$O/images/rootfs.squashfs:rootfs.squashfs"; do
	$SSH root@"$IP" "cat > /tmp/inst/${f##*:}" < "${f%%:*}"
done

B=$(md5sum < "$O/images/efi-part.vfat" | cut -d' ' -f1)
R=$(md5sum < "$O/images/rootfs.squashfs" | cut -d' ' -f1)
echo "Writing $DISK and rebooting..."
$SSH -n -o ServerAliveInterval=5 -o ServerAliveCountMax=3 root@"$IP" \
	"/tmp/inst/ld-musl-x86_64.so.1 --library-path /tmp/inst /tmp/inst/busybox sh /tmp/inst/update.sh $DISK $B $R" 2>&1 |
	grep -vE 'records|copied' || true

#!/bin/sh
# Put the built image on a running Wyse over SSH, then reboot it.
#
#   scripts/deploy.sh <model> [device-ip]    (model: 3040 or 5020;
#                                             ip default: DEVICE_IP in .env)
#
# Writes only the boot (p1) and root (p2) partitions; /data is kept. The
# device runs scripts/update.sh from RAM with a copied busybox, so it does
# not depend on the old root filesystem while overwriting it.
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
SSH="ssh -i $KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10"
[ -f "$O/images/rootfs.squashfs" ] || { echo "no image: build it first (make MODEL=$MODEL)" >&2; exit 1; }

# The device's model (images from before /etc/wyse/model have none) and the
# disk it booted from: the read-only root (/rom) must be its partition 2.
set -- $($SSH -n root@"$IP" 'cat /etc/wyse/model 2>/dev/null || echo unknown
	p=$(readlink -f /sys/dev/block/$(mountpoint -d /rom))
	echo /dev/$(basename $(dirname $p)) $(cat $p/partition)')
DEV_MODEL=${1:-}; DISK=${2:-}; PART=${3:-}
if [ "$DEV_MODEL" != unknown ] && [ "$DEV_MODEL" != "$MODEL" ]; then
	echo "$IP is a Wyse $DEV_MODEL, not a $MODEL. Not installing." >&2; exit 1
fi
[ "$PART" = 2 ] && [ -n "$DISK" ] ||
	{ echo "can't find the device's disk (got '$DISK' partition '$PART')" >&2; exit 1; }

echo "Copying to $IP..."
$SSH -n root@"$IP" 'mkdir -p /tmp/inst'
for f in "$O/target/bin/busybox:busybox" \
	"$O/target/lib/ld-musl-x86_64.so.1:ld-musl-x86_64.so.1" \
	"scripts/update.sh:update.sh" \
	"$O/images/efi-part.vfat:boot.vfat" \
	"$O/images/rootfs.squashfs:rootfs.squashfs"; do
	$SSH root@"$IP" "cat > /tmp/inst/${f##*:}" < "${f%%:*}"
done
$SSH -n root@"$IP" 'chmod +x /tmp/inst/busybox /tmp/inst/ld-musl-x86_64.so.1'

B=$(md5sum < "$O/images/efi-part.vfat" | cut -d' ' -f1)
R=$(md5sum < "$O/images/rootfs.squashfs" | cut -d' ' -f1)
echo "Writing $DISK and rebooting..."
$SSH -n -o ServerAliveInterval=5 -o ServerAliveCountMax=3 root@"$IP" \
	"/tmp/inst/ld-musl-x86_64.so.1 --library-path /tmp/inst /tmp/inst/busybox sh /tmp/inst/update.sh $DISK $B $R" 2>&1 |
	grep -vE 'records|copied' || true

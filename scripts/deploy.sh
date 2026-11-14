#!/bin/sh
# Put the built image on a running Wyse over SSH, then reboot it.
#
#   scripts/deploy.sh [device-ip]      (default: DEVICE_IP from .env)
#
# Writes only the boot (p1) and root (p2) partitions; /persist and /data are
# kept. The device runs scripts/update.sh from RAM with a copied busybox, so
# it does not depend on the old root filesystem while overwriting it.
# Same partition offsets as external/board/wyse/genimage.cfg.
set -eu
cd "$(dirname "$0")/.."
get() { sed -n "s/^$1=//p" .env 2>/dev/null | head -n 1 | tr -d '"\r'; }
IP=${1:-$(get DEVICE_IP)}
KEY=$(get SSH_KEY_FILE); KEY=${KEY:-keys/wyse_ed25519}
[ -n "$IP" ] || { echo "usage: $0 <device-ip> (or DEVICE_IP in .env)" >&2; exit 1; }
O=${WYSE_OUT:-/home/vscode/wyse-build/output}
DISK=${DISK:-/dev/mmcblk1}
SSH="ssh -i $KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10"

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

#!/bin/sh
# Put the built image on a running Wyse over SSH, then reboot it.
#
#   scripts/deploy.sh <host name>
#
# The image is the one ./build.sh made for that host name; the model and the
# IP (model, address) come from the device file in config/devices/ with that
# host name. SSH logs in with the key in your SSH agent (config/README).
#
# Like an automatic update (wyse-init/src/update.rs): the root image is sent
# to `wyse-init install-slot`, which writes it into the unused root (a or b),
# checks it and marks it to be booted once. The device then reboots into it
# and keeps it only when NetBird or Tailscale comes up; otherwise the next
# boot is on the old root. /data is kept. GRUB (p1) is not changed: a new
# GRUB or disk layout needs scripts/install.sh.
set -eu
cd "$(dirname "$0")/.."
CFG=config
. scripts/config.sh
H=${1:?usage: $0 <host name>}
DF=$(device_file "$H")
MODEL=$(get "$DF" model)
IP=$(get "$DF" address)
[ -n "$IP" ] || { echo "$DF: no address (the device's IP)" >&2; exit 1; }
I=/home/vscode/wyse-build/images/$H
SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=6"
[ -f "$I/rootfs.squashfs" ] && [ -f "$I/version" ] ||
	{ echo "no image in $I: build it first (./build.sh $H)" >&2; exit 1; }
V=$(cat "$I/version")

# The device's model name from the BIOS (DMI), for example "Wyse 3040 Thin
# Client".
NAME=$($SSH -n root@"$IP" 'cat /sys/class/dmi/id/product_name')
case "$NAME" in
	*"$MODEL"*) ;;
	*) echo "$IP is a \"$NAME\", not a Wyse $MODEL. Not installing." >&2; exit 1 ;;
esac

SIZE=$(wc -c < "$I/rootfs.squashfs" | tr -d ' ')
SHA=$(sha256sum < "$I/rootfs.squashfs" | cut -d' ' -f1)
echo "Sending version $V ($SIZE bytes) to $IP..."
$SSH root@"$IP" "wyse-init install-slot $SIZE $SHA $V" < "$I/rootfs.squashfs"
echo "Rebooting $IP..."
$SSH -n root@"$IP" reboot || true
echo "It boots the new root once and keeps it when a VPN comes up (wyse-init update-status)."

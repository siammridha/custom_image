#!/bin/sh
# First install, or full reinstall: write the whole disk.img to a running
# Wyse over SSH, then reboot it.
#
#   scripts/install.sh <host name>
#
# The device must run Linux with SSH as root: Alpine, or this image.
# Everything on its disk is lost, /data too. To update a device that runs
# this image and keep /data, use scripts/deploy.sh.
#
# Sends disk.img.gz (made by ./build.sh; disk.img is 638 MB, mostly empty)
# and keeps it packed in a RAM folder on the device. A copied busybox (Alpine's,
# as in deploy.sh) unpacks it onto the disk, so nothing is read from the
# disk while it is being overwritten. The write is checked and tried twice;
# the device reboots only when the check passes. /data grows to the rest of
# the disk on the first boot.
set -eu
cd "$(dirname "$0")/.."
CFG=config
. scripts/config.sh
H=${1:?usage: $0 <host name>}
DF=$(device_file "$H")
MODEL=$(get "$DF" model)
IP=$(get "$DF" address)
[ -n "$IP" ] || { echo "$DF: no address (the device's IP)" >&2; exit 1; }
IMG=/home/vscode/wyse-build/images/$H/disk.img.gz
[ -f "$IMG" ] || { echo "no $IMG: build it first (./build.sh $H)" >&2; exit 1; }
AT=$(ls "${WYSE_DL:-/home/vscode/wyse-build/dl}"/alpine/alpine-minirootfs-*-x86_64.tar.gz 2>/dev/null | sort -V | tail -n 1)
[ -n "$AT" ] || { echo "no Alpine archive in the download folder: build first" >&2; exit 1; }
SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10"

# The disk the device runs from: the one holding its root (/rom on this
# image, / on Alpine), its size in bytes and the BIOS model name.
set -- $($SSH -n root@"$IP" 'r=/rom; mountpoint -q $r || r=/
	p=$(readlink -f /sys/dev/block/$(mountpoint -d $r))
	[ -f $p/partition ] || exit 0
	d=$(dirname $p)
	echo /dev/$(basename $d) $(( $(cat $d/size) * 512 )) $(cat /sys/class/dmi/id/product_name)')
DISK=${1:-}; DSIZE=${2:-0}; shift 2 || true; NAME="$*"
[ -n "$DISK" ] || { echo "can't find the disk $IP runs from (is its root on a disk partition?)" >&2; exit 1; }
case "$NAME" in
	*"$MODEL"*) ;;
	*) echo "$IP is a \"$NAME\", not a Wyse $MODEL. Not installing." >&2; exit 1 ;;
esac
SIZE=$(gunzip -c "$IMG" | wc -c)
[ "$DSIZE" -ge "$SIZE" ] || { echo "$DISK on $IP is smaller than disk.img" >&2; exit 1; }
MD5=$(gunzip -c "$IMG" | md5sum | cut -d' ' -f1)

echo "$H ($IP, $NAME): everything on $DISK will be erased, /data too."
printf 'Type the host name to go on: '
read -r a
[ "$a" = "$H" ] || { echo "Not installing."; exit 1; }

echo "Copying to $IP..."
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir "$TMP/inst"
tar -xzf "$AT" -C "$TMP" ./bin/busybox ./lib/ld-musl-x86_64.so.1
mv "$TMP/bin/busybox" "$TMP/lib/ld-musl-x86_64.so.1" "$TMP/inst/"
# A RAM folder: on Alpine /tmp is on the disk that gets overwritten.
R=/tmp/wyse-install
$SSH -n root@"$IP" "mkdir -p $R && { mountpoint -q $R || mount -t tmpfs -o size=128m tmpfs $R; }"
tar -cf - -C "$TMP/inst" . | $SSH root@"$IP" "tar -xf - -C $R"
$SSH root@"$IP" "cat > $R/disk.img.gz" < "$IMG"

echo "Writing $DISK and rebooting..."
$SSH -o ServerAliveInterval=5 -o ServerAliveCountMax=3 root@"$IP" \
	"$R/ld-musl-x86_64.so.1 --library-path $R $R/busybox sh -s $R $DISK $SIZE $MD5" <<'EOF' 2>&1 |
R=$1 DISK=$2 SIZE=$3 MD5=$4
B="$R/ld-musl-x86_64.so.1 --library-path $R $R/busybox"
$B sync
echo u > /proc/sysrq-trigger
$B sleep 2
for try in 1 2; do
	echo "write try $try"
	$B gunzip -c $R/disk.img.gz | $B dd of=$DISK bs=1M 2>&1
	$B sync
	echo 3 > /proc/sys/vm/drop_caches
	got=$($B dd if=$DISK bs=1M 2>/dev/null | $B head -c $SIZE | $B md5sum | $B cut -d' ' -f1)
	echo "disk.img md5 want $MD5 got $got"
	if [ "$got" = "$MD5" ]; then
		echo rebooting
		$B sleep 1
		echo b > /proc/sysrq-trigger
	fi
done
echo "VERIFY FAILED, not rebooting"
exit 1
EOF
	grep -vE 'records|copied' || true

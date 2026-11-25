#!/bin/sh
# First install, or full reinstall: write the whole disk.img to a running
# Wyse over SSH, then reboot it.
#
#   scripts/install.sh <host name> [disk]
#
# disk (for example /dev/mmcblk0): only when the device runs from RAM, like
# Alpine started from a USB stick. Otherwise it is the disk the device runs
# from.
#
# The device must run Linux with SSH as root: Alpine, or this image.
# Everything on its disk is lost, /data too. To update a device that runs
# this image and keep /data, use scripts/deploy.sh.
#
# Sends disk.img.gz (made by ./build.sh; disk.img is about 360 MB, mostly empty)
# and keeps it packed in a RAM folder on the device. A copied busybox (Alpine's,
# as in deploy.sh) unpacks it onto the disk, so nothing is read from the
# disk while it is being overwritten.
# Safe for a remote device:
# - The disk is touched only after the copy on the device has the right
#   checksum (the copy is tried 3 times).
# - The write runs on its own (setsid, output to a log in the RAM folder),
#   so it goes on if the SSH connection drops; this script reconnects to
#   show the log. The write is checked and tried 3 times; the device reboots
#   only when the check passes. /data grows to the rest of the disk on the
#   first boot.
set -eu
cd "$(dirname "$0")/.."
CFG=config
. scripts/config.sh
H=${1:?usage: $0 <host name> [disk]}
WANT=${2:-}
case $WANT in ''|/dev/[a-z]*[a-z0-9]) ;; *) echo "bad disk name: $WANT" >&2; exit 1 ;; esac
DF=$(device_file "$H")
MODEL=$(get "$DF" model)
IP=$(get "$DF" address)
[ -n "$IP" ] || { echo "$DF: no address (the device's IP)" >&2; exit 1; }
IMG=/home/vscode/wyse-build/images/$H/disk.img.gz
[ -f "$IMG" ] || { echo "no $IMG: build it first (./build.sh $H)" >&2; exit 1; }
AT=$(ls "${WYSE_DL:-/home/vscode/wyse-build/dl}"/alpine/alpine-minirootfs-*-x86_64.tar.gz 2>/dev/null | sort -V | tail -n 1)
[ -n "$AT" ] || { echo "no Alpine archive in the download folder: build first" >&2; exit 1; }
SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=3"

# The disk the device runs from: the one holding its root (/rom on this
# image, / on Alpine), its size in bytes and the BIOS model name.
set -- $($SSH -n root@"$IP" "w=$WANT;"'if [ -n "$w" ]; then d=/sys/block/${w#/dev/}; [ -d $d ] || exit 0; else
	r=/rom; mountpoint -q $r || r=/
	p=$(readlink -f /sys/dev/block/$(mountpoint -d $r))
	[ -f $p/partition ] || exit 0
	d=$(dirname $p); fi
	echo /dev/$(basename $d) $(( $(cat $d/size) * 512 )) $(cat /sys/class/dmi/id/product_name)')
DISK=${1:-}; DSIZE=${2:-0}; shift 2 || true; NAME="$*"
[ -n "$DISK" ] || { echo "can't find the disk $IP runs from (is its root on a disk partition? If it runs from RAM, give the disk: $0 $H /dev/mmcblk0)" >&2; exit 1; }
case "$NAME" in
	*"$MODEL"*) ;;
	*) echo "$IP is a \"$NAME\", not a Wyse $MODEL. Not installing." >&2; exit 1 ;;
esac
SIZE=$(gunzip -c "$IMG" | wc -c)
[ "$DSIZE" -ge "$SIZE" ] || { echo "$DISK on $IP is smaller than disk.img" >&2; exit 1; }
MD5=$(gunzip -c "$IMG" | md5sum | cut -d' ' -f1)
GZMD5=$(md5sum < "$IMG" | cut -d' ' -f1)

echo "$H ($IP, $NAME): everything on $DISK will be erased, /data too."
printf 'Type the host name to go on: '
read -r a
[ "$a" = "$H" ] || { echo "Not installing."; exit 1; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir "$TMP/inst"
tar -xzf "$AT" -C "$TMP" ./bin/busybox ./lib/ld-musl-x86_64.so.1
mv "$TMP/bin/busybox" "$TMP/lib/ld-musl-x86_64.so.1" "$TMP/inst/"

# Runs on the device from the RAM folder: write, check, reboot.
cat > "$TMP/inst/write.sh" <<'EOF'
R=$1 DISK=$2 SIZE=$3 MD5=$4
B="$R/ld-musl-x86_64.so.1 --library-path $R $R/busybox"
$B sync
echo u > /proc/sysrq-trigger
$B sleep 2
for try in 1 2 3; do
	echo "write try $try"
	$B gunzip -c $R/disk.img.gz | $B dd of=$DISK bs=1M 2>&1
	$B sync
	echo 3 > /proc/sys/vm/drop_caches
	got=$($B dd if=$DISK bs=1M 2>/dev/null | $B head -c $SIZE | $B md5sum | $B cut -d' ' -f1)
	echo "disk.img md5 want $MD5 got $got"
	if [ "$got" = "$MD5" ]; then
		echo rebooting
		$B sleep 3
		echo b > /proc/sysrq-trigger
	fi
done
echo "VERIFY FAILED, not rebooting"
EOF
# Shows the write's log until the device reboots; exits 1 if the write failed.
cat > "$TMP/inst/watch.sh" <<'EOF'
R=$1 # $2: first log line to show
B="$R/ld-musl-x86_64.so.1 --library-path $R $R/busybox"
$B tail -n +$2 -f $R/log &
t=$!
while :; do
	if $B grep -q '^VERIFY FAILED' $R/log; then $B sleep 1; kill $t; exit 1; fi
	$B sleep 2
done
EOF

# A RAM folder: on Alpine /tmp is on the disk that gets overwritten.
R=/tmp/wyse-install
B="$R/ld-musl-x86_64.so.1 --library-path $R $R/busybox"
ok=
for try in 1 2 3; do
	echo "Copying to $IP (try $try)..."
	if $SSH -n root@"$IP" "mkdir -p $R && { mountpoint -q $R || mount -t tmpfs -o size=128m tmpfs $R; }" &&
		tar -cf - -C "$TMP/inst" . | $SSH root@"$IP" "tar -xf - -C $R" &&
		$SSH root@"$IP" "cat > $R/disk.img.gz" < "$IMG"; then
		got=$($SSH -n root@"$IP" "$B md5sum $R/disk.img.gz" | cut -d' ' -f1) || got=
		echo "disk.img.gz md5 want $GZMD5 got $got"
		[ "$got" = "$GZMD5" ] && { ok=1; break; }
	fi
done
[ -n "$ok" ] || { echo "The copy on $IP is not right. Nothing was written." >&2; exit 1; }

echo "Writing $DISK and rebooting (the write goes on if SSH drops)..."
$SSH -n root@"$IP" "$B setsid $B sh $R/write.sh $R $DISK $SIZE $MD5 < /dev/null > $R/log 2>&1 &"
# Follow the log; reconnect when the connection drops, for up to 30 minutes.
L="$TMP/log"; : > "$L"; end=$(( $(date +%s) + 1800 ))
while [ "$(date +%s)" -lt "$end" ]; do
	rm -f "$TMP/rc"
	{ $SSH -n root@"$IP" "$B sh $R/watch.sh $R $(( $(wc -l < "$L") + 1 ))" || echo $? > "$TMP/rc"; } | tee -a "$L"
	rc=$(cat "$TMP/rc" 2>/dev/null || echo 0)
	if [ "$rc" = 1 ] && grep -q '^VERIFY FAILED' "$L"; then
		echo "The disk check failed 3 times. The device did not reboot and its disk is damaged: do not reboot it." >&2
		echo "The image is still in its RAM. To write it again:" >&2
		echo "  ssh root@$IP '$B setsid $B sh $R/write.sh $R $DISK $SIZE $MD5 < /dev/null > $R/log 2>&1 &'" >&2
		exit 1
	fi
	grep -q '^rebooting' "$L" && { echo "The device is rebooting into the new image."; exit 0; }
	echo "(connection lost, reconnecting)"
	sleep 5
done
echo "No answer from $IP for 30 minutes. If the write finished, the device has rebooted; check it on its VPN IPs." >&2
exit 1

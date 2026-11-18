# Runs on the Wyse from /tmp/inst (RAM). Writes boot (p1) and root (p2)
# contents only; the partition table and /data are kept.
# Usage: ld-musl busybox sh /tmp/inst/update.sh <disk> <boot md5> <root md5>
I=/tmp/inst
B="$I/ld-musl-x86_64.so.1 --library-path $I $I/busybox"
DISK=$1

check() { # file seek_MiB want_md5
	sz=$($B wc -c < $I/$1)
	got=$($B dd if=$DISK bs=1M skip=$2 2>/dev/null | $B head -c $sz | $B md5sum | $B cut -d' ' -f1)
	echo "$1 md5 want $3 got $got"
	[ "$got" = "$3" ]
}

$B sync
echo u > /proc/sysrq-trigger
$B sleep 2

ok=0
for try in 1 2; do
	echo "write try $try"
	$B dd if=$I/boot.vfat of=$DISK bs=1M seek=1 2>&1
	$B dd if=$I/rootfs.squashfs of=$DISK bs=1M seek=65 2>&1
	$B sync
	echo 3 > /proc/sys/vm/drop_caches
	check boot.vfat 1 $2 && check rootfs.squashfs 65 $3 && { ok=1; break; }
done
[ $ok = 1 ] || { echo "VERIFY FAILED, not rebooting"; exit 1; }
echo rebooting
$B sleep 1
echo b > /proc/sysrq-trigger

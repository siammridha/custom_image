#!/bin/sh
# $1 = target dir, $2 = model (3040 or 5020, from the Makefile)
set -e
T=${1:?target dir missing}
MODEL=${2:?model missing (build with: make MODEL=3040 or MODEL=5020)}
B=$(dirname "$0")

# Which model this image is for. Install scripts use it to pick the right
# driver packs.
mkdir -p "$T/etc/wyse"
echo "$MODEL" > "$T/etc/wyse/model"

# Mount points used by /sbin/preinit.
mkdir -p "$T/rom" "$T/persist" "$T/media/overlay" "$T/mnt" "$T/data"

# wyse-init: preinit, boot, services, vpn-guard, apps setup and the DHCP
# lease handler, in one Rust program (no boot scripts).
WI=$B/../../../wyse-init
CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER=$HOST_DIR/bin/x86_64-buildroot-linux-musl-gcc \
	cargo build -q --release --target x86_64-unknown-linux-musl \
	--manifest-path "$WI/Cargo.toml" --target-dir "$BUILD_DIR/wyse-init"
install -m 0755 "$BUILD_DIR/wyse-init/x86_64-unknown-linux-musl/release/wyse-init" "$T/sbin/wyse-init"
ln -sf wyse-init "$T/sbin/preinit"
mkdir -p "$T/usr/libexec/wyse"
ln -sf /sbin/wyse-init "$T/usr/libexec/wyse/udhcpc-event"
ln -sf /sbin/wyse-init "$T/usr/sbin/alpine"

# Alpine mini root filesystem. Unpacked into /data/alpine when that is
# missing, so apk works again after wyse-wipe-data, even offline.
# Always the latest stable release: its name and checksum come from
# Alpine's latest-releases.yaml. Offline, the newest cached copy is used.
AU=https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/x86_64
AD=${BR2_DL_DIR:-$BASE_DIR/../dl}/alpine
mkdir -p "$AD"
set -- $(wget -q -O- "$AU/latest-releases.yaml" 2>/dev/null | awk '
	/flavor:/ { m = ($2 == "alpine-minirootfs") }
	m && /^  file:/ { f = $2 }
	m && /^  sha256:/ { s = $2 }
	END { if (f && s) print f, s }')
if [ $# = 2 ]; then
	AF=$1; AS=$2
	if ! echo "$AS  $AD/$AF" | sha256sum -c - > /dev/null 2>&1; then
		wget -q -O "$AD/$AF" "$AU/$AF"
		echo "$AS  $AD/$AF" | sha256sum -c - > /dev/null ||
			{ rm -f "$AD/$AF"; echo "$AF: bad checksum"; exit 1; }
	fi
	echo "$AS" > "$AD/$AF.sha256"
else
	AF=$(cd "$AD" && ls alpine-minirootfs-*-x86_64.tar.gz 2>/dev/null | sort -V | tail -1)
	[ -n "$AF" ] && [ -f "$AD/$AF.sha256" ] ||
		{ echo "alpine-minirootfs: offline and no cached copy"; exit 1; }
	echo "$(cat "$AD/$AF.sha256")  $AD/$AF" | sha256sum -c - > /dev/null ||
		{ echo "$AF: bad checksum"; exit 1; }
	echo "alpine-minirootfs: offline, using cached $AF"
fi
echo "alpine-minirootfs: $AF"
# Made into the image's archive further down (alpine-root.sh), once the
# private root CA is known.

# State that must survive an overlay wipe lives on the persist partition.
# These links are part of the read-only image, so a wipe can't remove them.
mkdir -p "$T/var/lib"
ln -snf /persist/tailscale     "$T/var/lib/tailscale"
ln -snf /persist/netbird/state "$T/var/lib/netbird"
ln -snf /persist/netbird/etc   "$T/etc/netbird"
ln -snf /persist/dropbear      "$T/etc/dropbear"

# Driver packs (drivers/README): the kernel also builds the pack drivers,
# so the parts they need are inside the kernel. Only these modules stay in
# the image; the rest are set aside for drivers/build.sh.
IMAGE_MODULES="efivarfs.ko nf_log_syslog.ko softdog.ko x86_pkg_temp_thermal.ko
	xt_LOG.ko xt_MASQUERADE.ko xt_addrtype.ko xt_mark.ko"
KREL=$(ls "$T/lib/modules")
POOL=$BUILD_DIR/wyse-driver-pool
rm -rf "$POOL" && mkdir -p "$POOL/lib/modules"
cp -a "$T/lib/modules/$KREL" "$POOL/lib/modules/"
find "$T/lib/modules/$KREL" -name '*.ko*' | while read -r f; do
	echo " $IMAGE_MODULES " | tr '\n\t' '  ' | grep -qF " ${f##*/} " || rm -f "$f"
done
find "$T/lib/modules/$KREL" -type d -empty -delete
"$HOST_DIR/sbin/depmod" -b "$T" "$KREL"

# Only the programs the system uses. Debug tools are installed when needed
# into /data/alpine (alpine apk add ...) and removed after.
# util-linux, e2fsprogs, dropbear: keep only these.
KEEP_PROGS="sfdisk mke2fs e2fsck dropbear"
awk -F, '$1 == "util-linux" || $1 == "e2fsprogs" || $1 == "dropbear" { print $2 }' \
	"$BUILD_DIR/packages-file-list.txt" | grep -E '^\./(usr/)?s?bin/' | sort -u |
while read -r f; do
	echo " $KEEP_PROGS " | grep -qF " ${f##*/} " || rm -f "$T/$f"
done
# BusyBox: its config (busybox.config) has only the needed commands. The
# target folder is reused between builds, so remove links to commands that
# are no longer built, and add the ones another package's program (deleted
# above) was in the way of.
BBL=$(ls "$BUILD_DIR"/busybox-*/busybox.links)
for d in bin sbin usr/bin usr/sbin; do
	for f in "$T/$d"/*; do
		[ -L "$f" ] && [ "$(basename "$(readlink "$f")")" = busybox ] || continue
		grep -qxF "/$d/${f##*/}" "$BBL" || rm -f "$f"
	done
done
while read -r l; do
	[ -e "$T$l" ] || [ -L "$T$l" ] && continue
	case $l in
		/bin/*) ln -s busybox "$T$l" ;;
		/sbin/*) ln -s ../bin/busybox "$T$l" ;;
		/usr/*) ln -s ../../bin/busybox "$T$l" ;;
	esac
done < "$BBL"
# sh is the shell; the extra "ash" name is not used.
rm -f "$T/bin/ash"
sed -i '\|^/bin/ash$|d' "$T/etc/shells"
# Left from tools that are no longer built (crond, ifupdown).
rm -rf "$T/etc/cron" "$T/etc/network" "$T/var/www"
# Unused skeleton files.
rm -rf "$T/linuxrc" "$T/opt" "$T/etc/issue" "$T/lib64" "$T/usr/lib64" \
	"$T/var/cache" "$T/var/spool" "$T/var/lib/misc"
# Libraries no program loads (checked with readelf: NEEDED), the .so links
# that are only for compiling (lib/libc.so is musl itself, so it stays),
# and e2fsprogs' build scripts.
rm -f "$T"/lib/libstdc++.so* "$T"/usr/lib/libstdc++.so* "$T"/lib/libgcc_s.so* \
	"$T"/lib/libatomic.so* "$T"/lib/libmount.so* "$T"/usr/lib/libmount.so* \
	"$T"/usr/lib/libss.so*
for f in "$T"/lib/*.so "$T"/usr/lib/*.so; do
	[ -L "$f" ] && [ "${f##*/}" != libc.so ] && rm -f "$f"
done
rm -rf "$T/usr/share/et" "$T/usr/share/ss"
# Programs read the one bundle (/etc/ssl/certs/ca-certificates.crt, which
# also gets the private root CA below). The single files are copies.
find "$T/etc/ssl/certs" -mindepth 1 ! -name ca-certificates.crt -exec rm -f {} +
rm -rf "$T/usr/share/ca-certificates"

# Everything is started from /etc/inittab. Drop the packages' rc scripts
# and udhcpc's shell lease script.
rm -rf "$T/etc/init.d" "$T/usr/share/udhcpc"

# Cap the RAM-backed folders, so apps can't use up all RAM with files.
sed -i -e 's|^tmpfs\t\t/tmp\t\ttmpfs\tmode=1777\t|tmpfs\t\t/tmp\t\ttmpfs\tmode=1777,size=256m\t|' \
	-e 's|^tmpfs\t\t/dev/shm\ttmpfs\tmode=1777\t|tmpfs\t\t/dev/shm\ttmpfs\tmode=1777,size=64m\t|' \
	-e 's|^tmpfs\t\t/run\t\ttmpfs\tmode=0755,nosuid,nodev\t|tmpfs\t\t/run\t\ttmpfs\tmode=0755,nosuid,nodev,size=64m\t|' \
	"$T/etc/fstab"

# Mounts for the apps (cgroup) and the Alpine folder, done by "mount -a" at
# boot. nofail: skipped while /data/alpine does not exist yet; wyse-init
# runs "mount -a" again after unpacking it. /sys without its sub-mounts:
# Alpine's OpenRC then leaves the cgroups alone, so the apps stay in the
# apps cgroup. The main /proc: ps and top in Alpine see every process.
# Alpine's /run is mounted by wyse-init each time Alpine starts
# (wyse-init/src/alpine.rs).
sed -i -e '\|^cgroup2\t|d' -e '\|/data/alpine/|d' "$T/etc/fstab"
cat >> "$T/etc/fstab" <<'FSTAB'
cgroup2		/sys/fs/cgroup	cgroup2	nofail	0	0
/proc		/data/alpine/proc	none	bind,nofail	0	0
/sys		/data/alpine/sys	none	bind,nofail	0	0
/dev		/data/alpine/dev	none	rbind,nofail	0	0
/tmp		/data/alpine/tmp	none	bind,nofail	0	0
FSTAB

# No password login for root (SSH key only).
sed -i 's/^root:[^:]*:/root:*:/' "$T/etc/shadow"

# SSH keys allowed to log in as root, and /etc/hosts. Both are fixed in
# the image (rebuilt from scratch on every build).
K=$T/root/.ssh/authorized_keys
mkdir -p "$T/root/.ssh" && chmod 0700 "$T/root" "$T/root/.ssh"
: > "$K"
[ -f "$B/authorized_keys" ] && cat "$B/authorized_keys" >> "$K"
printf '127.0.0.1\tlocalhost\n' > "$T/etc/hosts"
rm -f "$T/etc/wyse/authorized_keys" "$T/etc/wyse/hosts"

# Settings from the repo's .env (or the file in $WYSE_ENV).
ENV=${WYSE_ENV:-$B/../../../.env}
CA=
if [ -f "$ENV" ]; then
	get() { sed -n "s/^$1=//p" "$ENV" | head -n 1 | tr -d '\r'; }
	setconf() { sed -i "s|^$1=.*|$1=\"$2\"|" "$T/etc/wyse/vpn.conf"; }

	v=$(get TAILSCALE_KEY); [ -n "$v" ] && setconf TS_AUTHKEY "$v"
	v=$(get NETBIRD_KEY); [ -n "$v" ] || v=$(get NETBITD_KEY)
	[ -n "$v" ] && setconf NB_SETUP_KEY "$v"

	# HOST_DOMAIN is the self-hosted NetBird server; HOST_IP is its address.
	# NETBIRD_URL in .env overrides the default management URL.
	ip=$(get HOST_IP); dom=$(get HOST_DOMAIN)
	if [ -n "$dom" ]; then
		v=$(get NETBIRD_URL)
		setconf NB_MANAGEMENT_URL "${v:-https://$dom:4478}"
		[ -n "$ip" ] && printf '%s\t%s\n' "$ip" "$dom" >> "$T/etc/hosts"
	fi

	v=$(get SSH_PUBLIC_KEY)
	[ -n "$v" ] && echo "$v" >> "$K"

	# ROOT_CA: the private root CA's certificate file (path relative to the
	# repo, e.g. root_ca.crt). Added to the system trust store; the NetBird
	# server's certificate is signed with it.
	v=$(get ROOT_CA)
	if [ -n "$v" ]; then
		case $v in /*) CA=$v ;; *) CA=$(dirname "$ENV")/$v ;; esac
		[ -f "$CA" ] || { echo "ROOT_CA: no file $CA"; exit 1; }
		grep -qF "$(sed -n 2p "$CA")" "$T/etc/ssl/certs/ca-certificates.crt" ||
			cat "$CA" >> "$T/etc/ssl/certs/ca-certificates.crt"
	fi
fi
chmod 0600 "$K"

# The Alpine archive, with OpenRC, trimmed and with the private root CA
# (see alpine-root.sh).
mkdir -p "$T/usr/share/wyse"
"$HOST_DIR/bin/fakeroot" -- sh "$B/alpine-root.sh" "$AD/$AF" \
	"$T/usr/share/wyse/alpine-minirootfs.tar" "$BUILD_DIR/wyse-alpine" "$AD" "$CA"


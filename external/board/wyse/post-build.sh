#!/bin/sh
# $1 = target dir
set -e
T=$1
B=$(dirname "$0")

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
# Swap in the default package sources (latest-stable). Owners, modes and
# device files stay as in Alpine's tarball, since it is never unpacked here.
W=$BUILD_DIR/wyse-alpine
rm -rf "$W" && mkdir -p "$W/etc/apk"
printf '%s\n' \
	https://dl-cdn.alpinelinux.org/alpine/latest-stable/main \
	https://dl-cdn.alpinelinux.org/alpine/latest-stable/community \
	> "$W/etc/apk/repositories"
gunzip -c "$AD/$AF" > "$W/rootfs.tar"
tar --delete -f "$W/rootfs.tar" ./etc/apk/repositories
tar -rf "$W/rootfs.tar" -C "$W" --owner=0 --group=0 --numeric-owner \
	--mode=0644 --mtime=@0 ./etc/apk/repositories
mkdir -p "$T/usr/share/wyse"
gzip -9n < "$W/rootfs.tar" > "$T/usr/share/wyse/alpine-minirootfs.tar.gz"
rm -rf "$W"

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

# Everything is started from /etc/inittab. Drop the packages' rc scripts
# and udhcpc's shell lease script.
rm -rf "$T/etc/init.d" "$T/usr/share/udhcpc"

# Cap the RAM-backed folders, so apps can't use up all RAM with files.
sed -i -e 's|^tmpfs\t\t/tmp\t\ttmpfs\tmode=1777\t|tmpfs\t\t/tmp\t\ttmpfs\tmode=1777,size=256m\t|' \
	-e 's|^tmpfs\t\t/dev/shm\ttmpfs\tmode=1777\t|tmpfs\t\t/dev/shm\ttmpfs\tmode=1777,size=64m\t|' \
	-e 's|^tmpfs\t\t/run\t\ttmpfs\tmode=0755,nosuid,nodev\t|tmpfs\t\t/run\t\ttmpfs\tmode=0755,nosuid,nodev,size=64m\t|' \
	"$T/etc/fstab"

# Mounts for the apps (cgroup) and the Alpine folder, done by "mount -a" at
# boot. nofail: skipped while /data/alpine does not exist yet; apps-setup
# runs "mount -a" again after unpacking it.
sed -i -e '\|^cgroup2\t|d' -e '\|/data/alpine/|d' "$T/etc/fstab"
cat >> "$T/etc/fstab" <<'FSTAB'
cgroup2		/sys/fs/cgroup	cgroup2	nofail	0	0
proc		/data/alpine/proc	proc	nofail	0	0
/sys		/data/alpine/sys	none	rbind,nofail	0	0
/dev		/data/alpine/dev	none	rbind,nofail	0	0
/tmp		/data/alpine/tmp	none	bind,nofail	0	0
run		/data/alpine/run	tmpfs	size=32m,mode=0755,nofail	0	0
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
		install -m 0644 "$CA" "$T/etc/ssl/certs/wyse-root-ca.pem"
		grep -qF "$(sed -n 2p "$CA")" "$T/etc/ssl/certs/ca-certificates.crt" ||
			cat "$CA" >> "$T/etc/ssl/certs/ca-certificates.crt"
	fi
fi
chmod 0600 "$K"


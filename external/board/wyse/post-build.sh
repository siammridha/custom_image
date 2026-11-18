#!/bin/sh
# $1 = target dir, $2 = model (3040 or 5020, from the Makefile)
set -e
T=${1:?target dir missing}
MODEL=${2:?model missing (build with: make MODEL=3040 or MODEL=5020)}
B=$(dirname "$0")

mkdir -p "$T/etc/wyse"
# Old images had these files; their contents are now built into wyse-init
# (Buildroot keeps old target files).
rm -f "$T/etc/wyse/model" "$T/etc/wyse/modules" "$T/etc/hostname"

# Mount points used by /sbin/preinit.
rm -rf "$T/persist"
mkdir -p "$T/rom" "$T/media/overlay" "$T/mnt" "$T/data"

# Settings from the repo's .env (or the file in $WYSE_ENV).
ENV=${WYSE_ENV:-$B/../../../.env}
[ -f "$ENV" ] || ENV=/dev/null
get() { sed -n "s/^$1=//p" "$ENV" | head -n 1 | tr -d '\r'; }
# HOST_DOMAIN is the self-hosted NetBird server; HOST_IP is its address.
# NETBIRD_URL in .env overrides the default management URL.
ip=$(get HOST_IP); dom=$(get HOST_DOMAIN)
NB_URL=$(get NETBIRD_URL)
[ -z "$NB_URL" ] && [ -n "$dom" ] && NB_URL=https://$dom:4478

# The device's host name (keys/device.hostname, asked by build.sh).
K=$B/../../../keys
H=$(cat "$K/device.hostname" 2>/dev/null || true)
echo "$H" | grep -qE '^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$' ||
	{ echo "keys/device.hostname: missing or not a valid host name (build with ./build.sh)"; exit 1; }
# The model's drivers (modules-<model>), loaded by wyse-init at boot.
ML=$B/modules-$MODEL
MODS=$( [ ! -f "$ML" ] || grep -v '^#' "$ML" | tr -s ' \t\n' '   ')

# wyse-init: preinit, boot, services, vpn-guard, apps setup and the DHCP
# lease handler, in one Rust program (no boot scripts). The host name, the
# model's drivers and the NetBird management URL are built into it
# (wyse-init/src/config.rs).
WI=$B/../../../wyse-init
WYSE_NB_MANAGEMENT_URL=$NB_URL WYSE_HOSTNAME=$H WYSE_MODULES=$MODS \
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

rm -f "$T/usr/sbin/set-hostname"  # old images had it; Buildroot keeps old files

# Login banner, shown by dropbear and by login (NetBird and Tailscale SSH).
# A development build (BusyBox's fragment not empty, see the Makefile) says
# so.
L=' -----------------------------------------------------'
# Terminal color codes: R reset; G green, Y yellow, C cyan, D grey,
# W red.
E=$(printf '\033')
R="$E[0m"; G="$E[1;32m"; Y="$E[33m"; C="$E[1;36m"; D="$E[90m"; W="$E[1;31m"
{
	echo
	# The logo: shades of blue, light at the top to dark at the bottom
	# (256-color codes).
	set -- 117 111 75 69 33 27
	while IFS= read -r l; do
		printf '%s[1;38;5;%sm%s%s\n' "$E" "$1" "$l" "$R"
		shift
	done <<'EOF'
__        __
\ \      / /   _ ___  ___
 \ \ /\ / / | | / __|/ _ \
  \ V  V /| |_| \__ \  __/
   \_/\_/  \__, |___/\___|
           |___/
EOF
	echo "$D$L$R"
	echo " ${G}Wyse $MODEL$R, built $(date +%Y-%m-%d)"
	echo " Linux $(ls "$T/lib/modules"), Buildroot $(sed -n 's/^VERSION_ID=//p' "$T/etc/os-release")"
	echo "$D$L$R"
	echo " The system is read-only and starts fresh at every boot."
	echo " Only the ${C}/data$R partition is mutable."
	echo " Software: ${Y}alpine apk add <package>$R   Apps: ${Y}alpine rc-status$R"
	echo "$D$L$R"
	if [ -s "$BASE_DIR/busybox-build.fragment" ]; then
		echo "$W=== WARNING! =========================================$R"
		echo " Development build: has extra commands for testing."
		echo " Do not install it on a device at a site."
		echo "$D$L$R"
	fi
} > "$T/etc/motd"

# Development builds: a root shell on the monitor (tty1), no
# password (root has none). The overlay copies inittab fresh each build.
if [ -s "$BASE_DIR/busybox-build.fragment" ]; then
	echo 'tty1::respawn:/bin/login -f root' >> "$T/etc/inittab"
fi

# VPN and SSH keys: computed from the device's secret (keys/device.secret)
# and baked into the image, so they are the same after every boot.
mkdir -p "$T/var/lib"
rm -rf "$T/var/lib/tailscale" "$T/var/lib/netbird" "$T/etc/wyse/dropbear" "$T/etc/netbird"
# The dropbear package's link (to /var/run/dropbear); the key is elsewhere.
rm -rf "$T/etc/dropbear"
ln -snf /var/run/dropbear "$T/etc/dropbear"
cargo run -q --release --manifest-path "$B/../../../device-keys/Cargo.toml" \
	--target-dir "$BUILD_DIR/device-keys" -- "$K/device.secret" "$T"

# Kernel modules: the system's own (IMAGE_MODULES) and the model's drivers
# (modules-<model>), each with every module it needs. The kernel builds
# more drivers than that for both models; the rest are removed. wyse-init
# loads the model's drivers at boot.
IMAGE_MODULES="efivarfs nf_log_syslog softdog x86_pkg_temp_thermal
	xt_LOG xt_MASQUERADE xt_addrtype xt_mark"
KREL=$(ls "$T/lib/modules")
M=$T/lib/modules/$KREL
"$HOST_DIR/sbin/depmod" -b "$T" "$KREL"
{ echo "$IMAGE_MODULES"; [ ! -f "$ML" ] || grep -v '^#' "$ML"; } |
	tr -s ' \t' '\n\n' | grep . | tr - _ > "$BUILD_DIR/wyse-modules.want"
# modules.dep: "<module>: <every module it needs>". "-" and "_" are the same.
awk -F': *' 'NR == FNR { want[$1] = 1; next }
	{ b = $1; sub(/.*\//, "", b); sub(/\.ko.*/, "", b); gsub(/-/, "_", b)
	  if (b in want) { found[b] = 1; print $1; n = split($2, d, " ")
	                   for (i = 1; i <= n; i++) print d[i] } }
	END { for (w in want) if (!(w in found)) { print "module not built: " w; bad = 1 }
	      exit bad }' "$BUILD_DIR/wyse-modules.want" "$M/modules.dep" > "$BUILD_DIR/wyse-modules" ||
	{ grep 'not built' "$BUILD_DIR/wyse-modules"; exit 1; }
find "$M" -name '*.ko*' | while read -r f; do
	grep -qxF "${f#"$M"/}" "$BUILD_DIR/wyse-modules" || rm -f "$f"
done
find "$M" -type d -empty -delete
"$HOST_DIR/sbin/depmod" -b "$T" "$KREL"

# Firmware: with a list for the model (firmware-<model>), only the files on
# it stay in /lib/firmware. Files from an Alpine package come from the same
# Alpine branch as the Alpine archive; apk checks the packages' signatures
# against Alpine's keys. Kept in the download folder for offline builds.
FL=$B/firmware-$MODEL
if [ -f "$FL" ]; then
	F=$BUILD_DIR/wyse-firmware
	rm -rf "$F" && mkdir -p "$F/keys" "$F/pkg"
	gunzip -c "$AD/$AF" | tar -xf - -C "$F/keys" ./etc/apk/keys
	AV=$(echo "$AF" | sed 's/^alpine-minirootfs-\([0-9]*\.[0-9]*\).*/\1/')
	P=$AD/firmware-v$AV
	mkdir -p "$P"
	PKGS=$(awk '!/^#/ && NF > 1 { print $2 }' "$FL" | sort -u)
	if [ -n "$PKGS" ]; then
		apk fetch --arch x86_64 --repositories-file /dev/null \
			--keys-dir "$F/keys/etc/apk/keys" --no-cache --quiet -o "$P" \
			-X "http://dl-cdn.alpinelinux.org/alpine/v$AV/main" \
			-X "http://dl-cdn.alpinelinux.org/alpine/v$AV/community" $PKGS ||
			echo "firmware: can't download $PKGS, using $P"
		for p in $PKGS; do
			a=$(ls "$P/$p"-[0-9]*.apk 2>/dev/null | sort -V | tail -1)
			[ -n "$a" ] || { echo "firmware: no $p package in $P" >&2; exit 1; }
			apk verify --keys-dir "$F/keys/etc/apk/keys" --quiet "$a"
			tar -xzf "$a" -C "$F/pkg" lib/firmware 2>/dev/null
		done
	fi
	awk '!/^#/ && NF > 1 { print $1 }' "$FL" | while read -r f; do
		[ -f "$F/pkg/lib/firmware/$f" ] || { echo "firmware: $f not found" >&2; exit 1; }
		mkdir -p "$T/lib/firmware/$(dirname "$f")"
		cp "$F/pkg/lib/firmware/$f" "$T/lib/firmware/$f"
	done
	PATS=$(awk '!/^#/ && NF { print $1 }' "$FL")
	set -f   # the patterns are matched with case, not against files here
	find "$T/lib/firmware" ! -type d | while read -r f; do
		r=${f#"$T"/lib/firmware/}
		keep=
		for p in $PATS; do
			# shellcheck disable=SC2254
			case $r in $p) keep=1; break ;; esac
		done
		[ -n "$keep" ] || rm -f "$f"
	done
	set +f
	find "$T/lib/firmware" -type d -empty -delete
fi

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
# The skeleton's "/dev/root / ext2" line is wrong here (root is the overlay
# set up by preinit) and nothing uses it.
sed -i -e '\|^/dev/root\t|d' -e '\|^cgroup2\t|d' -e '\|/data/alpine/|d' "$T/etc/fstab"
cat >> "$T/etc/fstab" <<'FSTAB'
cgroup2		/sys/fs/cgroup	cgroup2	nofail	0	0
/proc		/data/alpine/proc	none	bind,nofail	0	0
/sys		/data/alpine/sys	none	bind,nofail	0	0
/dev		/data/alpine/dev	none	rbind,nofail	0	0
/tmp		/data/alpine/tmp	none	bind,nofail	0	0
FSTAB

# Only root: every program runs as root. No password login for root (SSH
# key only). The one group used: tty (devpts gid=5 in fstab; dropbear makes
# SSH terminals 0620 with it).
sed -i '/^root:/!d' "$T/etc/passwd" "$T/etc/shadow"
sed -i 's/^root:[^:]*:/root:*:/' "$T/etc/shadow"
echo 'tty:x:5:' > "$T/etc/group"

# Files nothing reads (see docs/paths.md): Go has the port and protocol
# names it needs built in; nothing uses /var/lock. /dev is covered by
# devtmpfs at boot (inittab makes the /dev links), so the image's /dev
# stays empty.
rm -f "$T/etc/services" "$T/etc/protocols" "$T/var/lock"
find "$T/dev" -mindepth 1 -delete

# SSH keys allowed to log in as root, and /etc/hosts. Both are fixed in
# the image (rebuilt from scratch on every build).
K=$T/root/.ssh/authorized_keys
mkdir -p "$T/root/.ssh" && chmod 0700 "$T/root" "$T/root/.ssh"
: > "$K"
[ -f "$B/authorized_keys" ] && cat "$B/authorized_keys" >> "$K"
printf '127.0.0.1\tlocalhost\n' > "$T/etc/hosts"
rm -f "$T/etc/wyse/authorized_keys" "$T/etc/wyse/hosts"

# The VPN keys, in files only root can read. NetBird and Tailscale read
# them themselves (--setup-key-file, --auth-key=file:), so the keys are
# never on a command line, where apps could read them.
rm -f "$T/etc/wyse/vpn.conf" "$T/etc/wyse/netbird.key" "$T/etc/wyse/tailscale.key"
key() { [ -n "$2" ] && (umask 077; printf '%s\n' "$2" > "$T/etc/wyse/$1"); true; }
key netbird.key "$(get NETBIRD_KEY)"
key tailscale.key "$(get TAILSCALE_KEY)"

[ -n "$dom" ] && [ -n "$ip" ] && printf '%s\t%s\n' "$ip" "$dom" >> "$T/etc/hosts"

CA=
if [ -f "$ENV" ]; then
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


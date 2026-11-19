#!/bin/sh
# Make the Alpine starter archive that goes into the image. Run by
# post-build.sh under Buildroot's fakeroot, so owners and modes stay as in
# Alpine's archive.
#   alpine-root.sh <alpine-minirootfs.tar.gz> <out.tar> <work dir> \
#                  <download dir> [root CA]
#
# Alpine keeps its own busybox and gets OpenRC: on the device wyse-init runs
# OpenRC in Alpine, and OpenRC starts the apps (wyse-init/src/alpine.rs). Removed: packages and files apk, OpenRC and the
# apps don't use. The host's apk adds and removes the packages, so Alpine's
# package database stays correct.
set -eu
IN=$1 OUT=$2 W=$3 DL=$4 CA=${5:-}

rm -rf "$W"
mkdir -p "$W/root"
gunzip -c "$IN" | tar -xpf - -C "$W/root"
R=$W/root

# OpenRC from the same Alpine branch as the archive. Kept in the download
# folder for builds without network. Fetched over HTTP: apk checks each
# package's signature against Alpine's keys from the archive.
V=$(basename "$IN" | sed 's/^alpine-minirootfs-\([0-9]*\.[0-9]*\).*/\1/')
P=$DL/openrc-v$V
mkdir -p "$P"
apk fetch --arch x86_64 --repositories-file /dev/null --keys-dir "$R/etc/apk/keys" \
	-X "http://dl-cdn.alpinelinux.org/alpine/v$V/main" --no-cache --quiet \
	-o "$P" openrc openrc-user libcap2 ||
	echo "alpine-root.sh: can't download OpenRC, using $P"
set -- "$P"/openrc-[0-9]*.apk "$P"/openrc-user-*.apk "$P"/libcap2-*.apk
[ $# = 3 ] && [ -f "$1" ] && [ -f "$2" ] && [ -f "$3" ] ||
	{ echo "alpine-root.sh: need one each of openrc, openrc-user, libcap2 in $P" >&2; exit 1; }
apk verify --keys-dir "$R/etc/apk/keys" --quiet "$@"
# OpenRC needs a network setup program (ifupdown-any); the main system sets
# up the network, so a small package stands in for it. Its service "net"
# does nothing; it is there so services with "need net" can start.
mkdir -p "$W/net/etc/init.d"
cat > "$W/net/etc/init.d/net" <<'EOF'
#!/sbin/openrc-run
description="The network, set up by the main system"
start() { :; }
EOF
chmod 755 "$W/net/etc/init.d/net"
apk mkpkg -I name:wyse-net -I version:1-r0 -I arch:noarch \
	-I "description:network is set up by the main system" \
	-I provides:ifupdown-any -F "$W/net" -o "$W/wyse-net.apk"
apk --root "$R" --arch x86_64 --repositories-file /dev/null --no-network \
	--no-scripts --no-cache --logfile=no --quiet --allow-untrusted \
	add "$@" "$W/wyse-net.apk"
# Adding files pins them in world; unpin so "apk upgrade" updates them.
sed -i -e '/^libcap2></d' -e '/^openrc-user></d' -e 's/^openrc><.*/openrc/' \
	"$R/etc/apk/world"

# Packages apk does not need (a package that needs one pulls it back in):
#   musl-utils, scanelf: getconf getent iconv ldd ldconfig scanelf
# alpine-release stays: install scripts read /etc/alpine-release and
# /etc/os-release (for example to build the repository URL).
apk --root "$R" --arch x86_64 --repositories-file /dev/null --no-network \
	--no-scripts --no-cache --logfile=no --quiet \
	del musl-utils

# Files apk, OpenRC and the apps don't use, from packages that stay. apk
# reads keys only from /etc/apk/keys (libapk: etc/apk/keys, lib/apk/keys);
# OpenSSL runs without a config file; musl has /etc/protocols built in and
# does not read nsswitch.conf; the rest is for a booted Alpine (cron,
# modules, sysctl, login, network setup, DHCP, log rotation, clock, random
# seed, binfmt, s6 supervisor start), which the main system does. OpenRC's
# own services go too: the apps' services are added by their installers.
cd "$R"
rm -rf usr/share/apk usr/lib/engines-3 usr/lib/ossl-modules usr/lib/sysctl.d \
	etc/ssl1.1 etc/ssl/openssl.cnf etc/ssl/openssl.cnf.dist \
	etc/ssl/ct_log_list.cnf etc/ssl/ct_log_list.cnf.dist \
	etc/crontabs var/spool/cron etc/modprobe.d etc/modules \
	etc/motd etc/fstab etc/hostname etc/sysctl.conf etc/secfixes.d etc/nsswitch.conf \
	etc/protocols etc/profile.d/README etc/profile.d/color_prompt.sh.disabled \
	etc/securetty etc/udhcpc usr/share/udhcpc etc/network etc/logrotate.d \
	etc/conf.d/* etc/sysctl.d etc/local.d etc/periodic etc/modules-load.d \
	etc/runlevels/nonetwork \
	usr/libexec/rc/sbin/seedrng usr/libexec/rc/sbin/swclock \
	usr/libexec/rc/sh/binfmt.sh usr/libexec/rc/sh/s6-svscanboot.sh
find etc/init.d ! -type d ! -name functions.sh ! -name net -delete
cd - > /dev/null

# No inittab: Alpine's init is not used (wyse-init runs OpenRC).
rm "$R/etc/inittab"
# The network is up before Alpine starts. rc.conf: OpenRC's defaults.
ln -s /etc/init.d/net "$R/etc/runlevels/boot/net"
rm "$R/etc/rc.conf"

# The private CA certificates, trusted inside Alpine too: added to Alpine's bundle
# (what programs read), and put where Alpine's update-ca-certificates
# (package ca-certificates) takes local CAs from, so it stays if that
# package is installed later (it copies each file whole into the bundle,
# so one file with several certificates works: update-ca.c, copyfile).
if [ -n "$CA" ]; then
	mkdir -p "$R/usr/local/share/ca-certificates"
	cp "$CA" "$R/usr/local/share/ca-certificates/private-ca-certificates.crt"
	chmod 644 "$R/usr/local/share/ca-certificates/private-ca-certificates.crt"
	cat "$CA" >> "$R/etc/ssl/certs/ca-certificates.crt"
fi

# Default package sources (latest-stable).
printf '%s\n' \
	https://dl-cdn.alpinelinux.org/alpine/latest-stable/main \
	https://dl-cdn.alpinelinux.org/alpine/latest-stable/community \
	> "$R/etc/apk/repositories"

tar -cf "$OUT" -C "$R" --sort=name --numeric-owner .
rm -rf "$W"

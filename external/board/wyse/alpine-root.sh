#!/bin/sh
# Make the Alpine starter archive that goes into the image. Run by
# post-build.sh under Buildroot's fakeroot, so owners and modes stay as in
# Alpine's archive.
#   alpine-root.sh <alpine-minirootfs.tar.gz> <out.tar.gz> <work dir> [root CA]
#
# Alpine keeps its own busybox. Removed: packages and files apk and the apps
# don't use. The host's apk removes the packages, so Alpine's package
# database stays correct.
set -eu
IN=$1 OUT=$2 W=$3 CA=${4:-}

rm -rf "$W"
mkdir -p "$W/root"
gunzip -c "$IN" | tar -xpf - -C "$W/root"
R=$W/root

# Packages apk does not need (a package that needs one pulls it back in):
#   musl-utils, scanelf: getconf getent iconv ldd ldconfig scanelf
#   alpine-release: /etc/alpine-release, /etc/os-release, /etc/issue
apk --root "$R" --arch x86_64 --repositories-file /dev/null --no-network \
	--no-scripts --no-cache --logfile=no --quiet \
	del musl-utils alpine-release

# Files apk and the apps don't use, from packages that stay. apk reads keys
# only from /etc/apk/keys (libapk: etc/apk/keys, lib/apk/keys); OpenSSL runs
# without a config file; musl has /etc/protocols built in and does not read
# nsswitch.conf; the rest is for a booted Alpine (init, cron, modules,
# sysctl, login, network setup, DHCP, log rotation), not a chroot.
cd "$R"
rm -rf usr/share/apk usr/lib/engines-3 usr/lib/ossl-modules usr/lib/sysctl.d \
	etc/ssl1.1 etc/ssl/openssl.cnf etc/ssl/openssl.cnf.dist \
	etc/ssl/ct_log_list.cnf etc/ssl/ct_log_list.cnf.dist \
	etc/crontabs var/spool/cron etc/inittab etc/modprobe.d etc/modules \
	etc/motd etc/fstab etc/hostname etc/sysctl.conf etc/secfixes.d etc/nsswitch.conf \
	etc/protocols etc/profile.d/README etc/profile.d/color_prompt.sh.disabled \
	etc/securetty etc/udhcpc usr/share/udhcpc etc/network etc/logrotate.d
cd - > /dev/null

# The private root CA, trusted inside Alpine too: added to Alpine's bundle
# (what programs read), and put where Alpine's update-ca-certificates
# (package ca-certificates) takes local CAs from, so it stays if that
# package is installed later.
if [ -n "$CA" ]; then
	mkdir -p "$R/usr/local/share/ca-certificates"
	cp "$CA" "$R/usr/local/share/ca-certificates/wyse-root-ca.crt"
	chmod 644 "$R/usr/local/share/ca-certificates/wyse-root-ca.crt"
	cat "$CA" >> "$R/etc/ssl/certs/ca-certificates.crt"
fi

# Default package sources (latest-stable).
printf '%s\n' \
	https://dl-cdn.alpinelinux.org/alpine/latest-stable/main \
	https://dl-cdn.alpinelinux.org/alpine/latest-stable/community \
	> "$R/etc/apk/repositories"

tar -cf - -C "$R" --sort=name --numeric-owner . | gzip -9n > "$OUT"
rm -rf "$W"

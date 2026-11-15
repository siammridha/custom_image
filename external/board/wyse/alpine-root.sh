#!/bin/sh
# Make the Alpine starter archive that goes into the image. Run by
# post-build.sh under Buildroot's fakeroot, so owners and modes stay as in
# Alpine's archive.
#   alpine-root.sh <alpine-minirootfs.tar.gz> <out.tar.gz> <target dir> <work dir>
#
# Alpine's own busybox is removed. Inside /data/alpine, the system's
# /bin/busybox is used (bind-mounted from /etc/fstab), with links for the
# same commands the system has. The host's apk does the removal, so Alpine's
# package database stays correct:
#   - wyse-binsh: a tiny package that provides /bin/sh (in place of
#     busybox-binsh, which alpine-baselayout needs)
#     It also has Alpine's busybox trigger (aports main/busybox/busybox.trigger):
#     when a package changes /bin, /usr/bin, /sbin or /usr/sbin, missing links
#     are made again ("busybox --install -s" does not replace existing files).
#   - "!busybox" in world: later "apk add" runs can't bring it back
# The links are not owned by a package, like Alpine's own busybox links, so
# a real package (e.g. coreutils) can still replace them, and its removal
# brings them back.
set -eu
IN=$1 OUT=$2 T=$3 W=$4

rm -rf "$W"
mkdir -p "$W/root" "$W/pkg/bin"
printf '#!/bin/sh\n/bin/busybox --install -s\n' > "$W/trigger"
gunzip -c "$IN" | tar -xpf - -C "$W/root"
R=$W/root

# Alpine's busybox links (made by its install trigger, not in the database).
find "$R" -lname /bin/busybox -delete

ln -s /bin/busybox "$W/pkg/bin/sh"
apk mkpkg -I name:wyse-binsh -I version:1-r0 -I arch:noarch \
	-I "description:/bin/sh from the system busybox" \
	-I "provides:/bin/sh cmd:sh=1-r0" -I license:GPL-2.0-only \
	-s "trigger:$W/trigger" -t /bin -t /usr/bin -t /sbin -t /usr/sbin \
	-F "$W/pkg" -o "$W/wyse-binsh.apk"
apk --root "$R" --arch x86_64 --repositories-file /dev/null --no-network \
	--no-scripts --no-cache --logfile=no --allow-untrusted --quiet \
	add "$W/wyse-binsh.apk" '!busybox'

# Mount target for the system's busybox, and links for its commands.
: > "$R/bin/busybox"
chmod 755 "$R/bin/busybox"
for d in bin sbin usr/bin usr/sbin; do
	for l in "$T/$d"/*; do
		[ -L "$l" ] && [ "$(basename "$(readlink "$l")")" = busybox ] || continue
		[ -e "$R/$d/${l##*/}" ] || [ -L "$R/$d/${l##*/}" ] || ln -s /bin/busybox "$R/$d/${l##*/}"
	done
done

# Default package sources (latest-stable).
printf '%s\n' \
	https://dl-cdn.alpinelinux.org/alpine/latest-stable/main \
	https://dl-cdn.alpinelinux.org/alpine/latest-stable/community \
	> "$R/etc/apk/repositories"

tar -cf - -C "$R" --sort=name --numeric-owner . | gzip -9n > "$OUT"
rm -rf "$W"

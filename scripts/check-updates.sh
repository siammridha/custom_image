#!/bin/sh
# Check each part of the main system for a newer release, and show what
# changed in the releases since the version the image is built with.
#
#   scripts/check-updates.sh
#
# Only reports; changes nothing. Needs the network, curl and jq.
# "Where" says where the version is set. Parts marked "Buildroot" change
# when Buildroot is updated (or with a version line in
# patches/buildroot-wyse.patch). Parts marked "next build" are taken from
# Alpine's latest stable release at every build: "yours" is the copy the
# last build downloaded.
set -u
cd "$(dirname "$0")/.."
MAX=40   # shortcut: notes cut after 40 lines per part; the full notes are at the link
DL=${WYSE_DL:-/home/vscode/wyse-build/dl}
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
: > "$TMP/rows"; : > "$TMP/notes"

get() { curl -fsSL --max-time 30 "$@" 2>/dev/null; }
ghapi() {
	if [ -n "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ]; then
		get -H "Authorization: Bearer ${GH_TOKEN:-${GITHUB_TOKEN:-}}" "https://api.github.com/$1"
	else get "https://api.github.com/$1"; fi
}
# newer A B: B is a newer version than A.
newer() { [ -n "$2" ] && [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" = "$2" ]; }
# The highest version on stdin, one per line.
top() { sort -V | tail -n 1; }
html() { sed 's/&lt;/</g; s/&gt;/>/g; s/<[^>]*>//g; s/&quot;/"/g; s/&#39;/'"'"'/g; s/&amp;/\&/g'; }
# Lines from the one starting with $1 up to (not including) the one
# starting with $2. For change logs with the newest release first.
between() { awk -v a="$1" -v b="$2" 'index($0, b) == 1 && p { exit } index($0, a) == 1 { p = 1 } p'; }

# check NAME YOURS LATEST WHERE: adds the row; true if there is an update.
check() {
	if [ -z "$3" ]; then s="can't check"
	elif newer "$2" "$3"; then s=UPDATE
	else s="up to date"; fi
	printf '%-15s %-15s %-15s %-12s %s\n' "$1" "${2:--}" "${3:--}" "$s" "$4" >> "$TMP/rows"
	[ "$s" = UPDATE ]
}
# notes NAME YOURS LATEST LINK, with the notes on stdin.
notes() {
	cat > "$TMP/n"
	{
		echo; echo "=== $1: $2 -> $3"
		if [ -s "$TMP/n" ]; then
			sed -n "1,${MAX}p" "$TMP/n"
			[ "$(wc -l < "$TMP/n")" -le $MAX ] || echo "... (cut; more at the link)"
		else echo "(no notes found)"; fi
		echo "Full notes: $4"
	} >> "$TMP/notes"
}
# Version from Buildroot: our patch first, then Buildroot's .mk file.
# brver FILE VAR (FILE relative to buildroot/).
brver() {
	v=$(sed -n "s/^+$2 = //p" patches/buildroot-wyse.patch | head -n 1)
	[ -n "$v" ] || v=$(sed -n "s/^$2 = //p" "buildroot/$1")
	while :; do   # expand $(NAME) from the same file
		n=$(echo "$v" | sed -n 's/.*\$(\([A-Z0-9_]*\)).*/\1/p')
		[ -n "$n" ] || break
		r=$(sed -n "s/^$n = //p" "buildroot/$1"); [ -n "$r" ] || break
		v=$(echo "$v" | sed "s/\$($n)/$r/")
	done
	echo "$v"
}
echo "Checking..." >&2

# --- Buildroot
Y=$(git -C buildroot describe --tags 2>/dev/null)
L=$(git ls-remote --tags https://gitlab.com/buildroot.org/buildroot.git 2>/dev/null |
	sed -n 's|.*refs/tags/\([0-9]\{4\}\.[0-9][0-9]\(\.[0-9]*\)\{0,1\}\)$|\1|p' | top)
check Buildroot "$Y" "$L" "buildroot submodule" &&
	get https://gitlab.com/buildroot.org/buildroot/-/raw/master/CHANGES | between "$L," "$Y," |
	notes Buildroot "$Y" "$L" https://gitlab.com/buildroot.org/buildroot/-/blob/master/CHANGES

# --- Linux: newest release of the same longterm series
Y=$(sed -n 's/^BR2_LINUX_KERNEL_CUSTOM_VERSION_VALUE="\(.*\)"/\1/p' external/configs/wyse_defconfig)
S=${Y%.*}
L=$(get https://www.kernel.org/releases.json | jq -r --arg s "$S." '.releases[].version | select(startswith($s))' | top)
W="wyse_defconfig"
[ -n "$L" ] || W="$W (series $S not listed on kernel.org: end of life?)"
if check Linux "$Y" "$L" "$W"; then
	p=${Y##*.}
	while [ "$p" -lt "${L##*.}" ]; do
		p=$((p + 1))
		echo "--- $S.$p"
		get "https://cdn.kernel.org/pub/linux/kernel/v${S%%.*}.x/ChangeLog-$S.$p" |
			awk '/^commit [0-9a-f]+$/ { c = 1; next } c && /^    [^ ]/ { sub(/^ +/, ""); print; c = 0 }'
	done | notes Linux "$Y" "$L" "https://cdn.kernel.org/pub/linux/kernel/v${S%%.*}.x/ChangeLog-$L"
fi

# --- linux-firmware: only changes to the folders the images use
Y=$(brver package/linux-firmware/linux-firmware.mk LINUX_FIRMWARE_VERSION)
L=$(get https://cdn.kernel.org/pub/linux/kernel/firmware/ | sed -n 's/.*linux-firmware-\([0-9]\{8\}\)\.tar\.xz.*/\1/p' | top)
if check linux-firmware "$Y" "$L" "patch (version line)"; then
	since=$(echo "$Y" | sed 's/\(....\)\(..\)\(..\)/\1-\2-\3T23:59:59Z/')
	for d in $(cat external/board/wyse/firmware-* | awk '!/^#/ && NF == 1 { sub(/\/[^\/]*$/, ""); print }' | sort -u); do
		get "https://gitlab.com/api/v4/projects/kernel-firmware%2Flinux-firmware/repository/commits?path=$d&since=$since&per_page=100" |
			jq -r '.[] | "\(.created_at[:10]) \(.title)"'
	done | sort -r | notes "linux-firmware (used folders)" "$Y" "$L" https://gitlab.com/kernel-firmware/linux-firmware/-/commits/main
fi

# --- NetBird
Y=$(sed -n 's/^NETBIRD_VERSION = //p' external/package/netbird/netbird.mk)
ghapi "repos/netbirdio/netbird/releases?per_page=50" > "$TMP/nb.json"
L=$(jq -r '.[] | select(.prerelease | not) | .tag_name | ltrimstr("v")' "$TMP/nb.json" 2>/dev/null | top)
if check NetBird "$Y" "$L" "external/package/netbird/netbird.mk"; then
	jq -r '.[] | select(.prerelease | not) | .tag_name | ltrimstr("v")' "$TMP/nb.json" | sort -rV | while read -r v; do
		newer "$Y" "$v" || continue
		jq -r --arg t "v$v" '.[] | select(.tag_name == $t) | "--- \(.tag_name) (\(.published_at[:10]))\n\(.body)"' "$TMP/nb.json" | tr -d '\r'
	done | notes NetBird "$Y" "$L" https://github.com/netbirdio/netbird/releases
fi

# --- Tailscale (its GitHub releases only point to the change log)
Y=$(brver package/tailscale/tailscale.mk TAILSCALE_VERSION)
L=$(ghapi repos/tailscale/tailscale/releases/latest | jq -r '.tag_name // empty | ltrimstr("v")')
check Tailscale "$Y" "$L" "patch (version line)" &&
	get https://tailscale.com/changelog/index.xml | awk -v y="$Y" '
		/<item>/ { t = ""; d = ""; s = "" }
		/<title>Tailscale v[0-9.]*<\/title>/ { t = $0; gsub(/.*<title>Tailscale v|<\/title>.*/, "", t) }
		/<pubDate>/ { d = $0; gsub(/.*<pubDate>|<\/pubDate>.*/, "", d) }
		/<description>/ { s = 1 }
		s { b = b $0 "\n" }
		/<\/description>/ { s = 0 }
		/<\/item>/ { if (t != "") print "--- " t " (" d ")\n" b; b = "" }' |
	html | awk -v y="$Y" '/^--- / { split($2, v, "."); split(y, w, "."); for (i = 1; i <= 3; i++) { v[i] += 0; w[i] += 0 } keep = (v[1] > w[1] || (v[1] == w[1] && (v[2] > w[2] || (v[2] == w[2] && v[3] > w[3])))) } keep && NF' |
	notes Tailscale "$Y" "$L" https://tailscale.com/changelog

# --- Go (compiles NetBird and Tailscale; its library is inside both)
Y=$(brver package/go/go.mk GO_VERSION)
L=$(get 'https://go.dev/dl/?mode=json' | jq -r '.[].version | ltrimstr("go")' | top)
if check Go "$Y" "$L" "patch (version line)"; then
	get https://go.dev/doc/devel/release > "$TMP/go.html"
	for v in $(grep -o 'id="go[0-9.]*"' "$TMP/go.html" | sed 's/id="go\(.*\)"/\1/' | sort -rV); do
		newer "$Y" "$v" || continue
		case $v in *.*.*) ;; *) echo "--- $v: new major release, see https://go.dev/doc/go$v"; continue ;; esac
		sed -n "/id=\"go$v\"/,/<\/p>/p" "$TMP/go.html" | html | tr -s ' \t\n' ' ' | fold -s -w 78; echo
	done | notes Go "$Y" "$L" https://go.dev/doc/devel/release
fi

# --- Rust (compiles wyse-init; its library is inside it)
Y=$(rustc --version 2>/dev/null | awk '{print $2}')
L=$(get https://static.rust-lang.org/dist/channel-rust-stable.toml | awk '/^\[pkg.rust\]/ { f = 1 } f && /^version/ { gsub(/"/, ""); print $3; exit }')
check Rust "$Y" "$L" "dev container (rustup update)" &&
	get https://raw.githubusercontent.com/rust-lang/rust/stable/RELEASES.md | between "Version $L " "Version $Y " |
	grep -v '^<a id=' | notes Rust "$Y" "$L" https://github.com/rust-lang/rust/blob/stable/RELEASES.md

# --- GCC: newest release of the major version wyse_defconfig picks
M=$(sed -n 's/^BR2_GCC_VERSION_\([0-9]*\)_X=y/\1/p' external/configs/wyse_defconfig)
Y=$(sed -n "s/.*default \"\([0-9.]*\)\".*if BR2_GCC_VERSION_${M}_X\$/\1/p" buildroot/package/gcc/Config.in.host)
L=$(get https://ftp.gnu.org/gnu/gcc/ | sed -n "s/.*gcc-\($M\.[0-9]*\.[0-9]*\)\/.*/\1/p" | top)
check "GCC $M" "$Y" "$L" "Buildroot (wyse_defconfig picks $M)" &&
	echo "Bug-fix release." | notes "GCC $M" "$Y" "$L" "https://gcc.gnu.org/gcc-$M/"

# --- musl (C library of every program in the image)
Y=$(brver package/musl/musl.mk MUSL_VERSION)
L=$(get https://musl.libc.org/releases.html | sed -n 's/.*musl-\([0-9.]*[0-9]\)\.tar\.gz.*/\1/p' | top)
check musl "$Y" "$L" "Buildroot" &&
	get https://git.musl-libc.org/cgit/musl/plain/WHATSNEW |   # oldest first: what follows ours
	awk -v y="$Y release notes" '$0 == y { f = 1; next } f && / release notes$/ { p = 1 } p' |
	notes musl "$Y" "$L" https://git.musl-libc.org/cgit/musl/plain/WHATSNEW

# --- BusyBox
Y=$(brver package/busybox/busybox.mk BUSYBOX_VERSION)
L=$(get https://busybox.net/downloads/ | sed -n 's/.*busybox-\([0-9]*\.[0-9]*\.[0-9]*\)\.tar\.bz2.*/\1/p' | top)
check BusyBox "$Y" "$L" "Buildroot" &&
	get https://busybox.net/ | awk -v y="$Y" '/<li><b>.*BusyBox [0-9.]* \(/ { p = (index($0, "BusyBox " y " ") == 0) ; if (!p) exit } p' |
	html | grep -v '^ *$' | notes BusyBox "$Y" "$L" https://busybox.net/

# --- Dropbear (SSH server)
Y=$(brver package/dropbear/dropbear.mk DROPBEAR_VERSION)
get https://raw.githubusercontent.com/mkj/dropbear/master/CHANGES > "$TMP/db"
L=$(sed -n 's/^\([0-9]\{4\}\.[0-9]*\) - .*/\1/p' "$TMP/db" | top)
check Dropbear "$Y" "$L" "Buildroot" &&
	between "$L - " "$Y - " < "$TMP/db" | notes Dropbear "$Y" "$L" https://github.com/mkj/dropbear/blob/master/CHANGES

# --- util-linux
Y=$(brver package/util-linux/util-linux.mk UTIL_LINUX_VERSION)
U=https://cdn.kernel.org/pub/linux/utils/util-linux
: > "$TMP/ul"
for d in $(get $U/ | sed -n 's/.*href="\(v[0-9.]*\)\/".*/\1/p' | sort -uV); do
	newer "v${Y%.*}" "$d" || [ "$d" = "v${Y%.*}" ] || continue
	get "$U/$d/" | sed -n "s/.*href=\"v\([0-9.]*\)-ReleaseNotes\".*/$d \1/p" >> "$TMP/ul"
done
L=$(awk '{print $2}' "$TMP/ul" | top)
check util-linux "$Y" "$L" "Buildroot" &&
	sort -k2,2rV "$TMP/ul" | while read -r d v; do
		newer "$Y" "$v" && { echo "--- $v"; get "$U/$d/v$v-ReleaseNotes"; }
	done | notes util-linux "$Y" "$L" "$U/"

# --- e2fsprogs
Y=$(brver package/e2fsprogs/e2fsprogs.mk E2FSPROGS_VERSION)
T=$(git ls-remote --tags https://github.com/tytso/e2fsprogs 2>/dev/null | sed -n 's|.*refs/tags/v\([0-9]*\.[0-9]*\.[0-9]*\)$|\1|p' | sort -uV)
L=$(echo "$T" | top)
check e2fsprogs "$Y" "$L" "Buildroot" &&
	for v in $(echo "$T" | sort -rV); do
		newer "$Y" "$v" && get "https://raw.githubusercontent.com/tytso/e2fsprogs/master/doc/RelNotes/v$v.txt"
	done | notes e2fsprogs "$Y" "$L" https://github.com/tytso/e2fsprogs/tree/master/doc/RelNotes

# --- GRUB (boot loader)
Y=$(brver boot/grub2/grub2.mk GRUB2_VERSION)
L=$(get https://ftp.gnu.org/gnu/grub/ | sed -n 's/.*grub-\([0-9]*\.[0-9]*\(\.[0-9]*\)\{0,1\}\)\.tar\.xz.*/\1/p' | top)
check GRUB "$Y" "$L" "Buildroot" &&
	get https://git.savannah.gnu.org/cgit/grub.git/plain/NEWS | between "New in $L:" "New in $Y:" |
	notes GRUB "$Y" "$L" https://git.savannah.gnu.org/cgit/grub.git/plain/NEWS

# --- ca-certificates (public root certificates, from Debian)
Y=$(brver package/ca-certificates/ca-certificates.mk CA_CERTIFICATES_VERSION)
L=$(get https://sources.debian.org/api/src/ca-certificates/ | jq -r '.versions[].version' | grep -v '[~-]' | top)
U=https://metadata.ftp-master.debian.org/changelogs/main/c/ca-certificates/unstable_changelog
check ca-certificates "$Y" "$L" "Buildroot" &&
	get $U | between "ca-certificates ($L)" "ca-certificates ($Y)" | notes ca-certificates "$Y" "$L" $U

# --- Alpine: the archive in the image and the Alpine packages taken into it
A=https://dl-cdn.alpinelinux.org/alpine/latest-stable
Y=$(ls "$DL"/alpine/alpine-minirootfs-*-x86_64.tar.gz 2>/dev/null | sed 's/.*minirootfs-\(.*\)-x86_64.*/\1/' | top)
L=$(get $A/releases/x86_64/latest-releases.yaml | awk '/flavor:/ { m = ($2 == "alpine-minirootfs") } m && /^  version:/ { print $2; exit }')
check Alpine "$Y" "$L" "next build" &&
	echo "Alpine releases: https://alpinelinux.org/releases/" | notes Alpine "$Y" "$L" https://alpinelinux.org/posts/
for r in main community; do get $A/$r/x86_64/APKINDEX.tar.gz | tar -xzOf - APKINDEX 2>/dev/null; done > "$TMP/apk"
apkver() { awk -v p="P:$1" '$0 == p { f = 1; next } f && /^V:/ { print substr($0, 3); exit } /^$/ { f = 0 }' "$TMP/apk"; }
# cached FOLDER PKG: version of the newest PKG package the build downloaded.
cached() { ls "$DL"/alpine/"$1"-v*/"$2"-[0-9]*.apk 2>/dev/null | sed "s|.*/$2-||; s|\.apk\$||" | top; }

Y=$(cached firmware sof-firmware); L=$(apkver sof-firmware)
U=$(ghapi repos/thesofproject/sof-bin/releases/latest | jq -r '.tag_name // empty')
check sof-firmware "$Y" "$L" "next build (Alpine package; upstream ${U:-?})" &&
	echo "Alpine package update. Upstream releases: https://github.com/thesofproject/sof-bin/releases" |
	notes sof-firmware "$Y" "$L" "https://pkgs.alpinelinux.org/package/edge/community/x86_64/sof-firmware"

Y=$(cached openrc openrc); L=$(apkver openrc)
check OpenRC "$Y" "$L" "next build (Alpine package)" &&
	echo "Alpine package update." | notes OpenRC "$Y" "$L" https://github.com/OpenRC/openrc/releases

printf '%-15s %-15s %-15s %-12s %s\n' PART YOURS LATEST STATUS WHERE
cat "$TMP/rows"
cat "$TMP/notes"

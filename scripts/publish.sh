#!/bin/sh
# Send built images to the update server (raptor, hawkBit Management API).
# The devices install them by themselves (wyse-init/src/update.rs).
#
#   scripts/publish.sh <host name> [host name ...]
#
# The hosts are done in the order given, one after the other: each device
# must report success before the next one gets its image. Put the test
# device first. It stops at the first failure.
#
# For each host:
#   - the device is created in raptor with its update_token (device file)
#     as its TargetToken, if it is not there yet
#   - rootfs.squashfs is uploaded as a software module: name = host,
#     version = the image's version (images/<host>/version)
#   - a distribution set with that module is made and assigned to the device
#   - then it waits (up to 40 min) until the device reports success
#
# Settings: update_admin_url in config/network (the local-network address of
# raptor's web page and API) and config/raptor (username, password). Old
# releases are deleted by raptor itself (keep_releases in its config).
set -eu
cd "$(dirname "$0")/.."
CFG=config
. scripts/config.sh
[ $# -gt 0 ] || { echo "usage: $0 <host name> [host name ...]" >&2; exit 1; }
URL=$(get "$CFG/network" update_admin_url); URL=${URL%/}
[ -n "$URL" ] || { echo "no update_admin_url in $CFG/network" >&2; exit 1; }
[ -f "$CFG/raptor" ] || { echo "no $CFG/raptor (username, password)" >&2; exit 1; }
RU=$(get "$CFG/raptor" username); RP=$(get "$CFG/raptor" password)
[ -n "$RU" ] && [ -n "$RP" ] || { echo "$CFG/raptor: username and password are needed" >&2; exit 1; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
# The login goes to curl in a file, not on its command line.
printf 'user = "%s:%s"\n' "$RU" "$RP" > "$TMP/auth"; chmod 600 "$TMP/auth"
# The web page's certificate is signed by the private root CA.
[ -f "$CFG/private-ca-certificates.crt" ] && printf 'cacert = "%s"\n' "$PWD/$CFG/private-ca-certificates.crt" >> "$TMP/auth"

# api <method> <path> [curl args...]: the reply body on stdout; fails
# (with the reply) on HTTP errors.
api() {
	m=$1 p=$2; shift 2
	code=$(curl -sS -K "$TMP/auth" -X "$m" -o "$TMP/out" -w '%{http_code}' "$@" "$URL$p") || return 1
	case $code in
		2??) cat "$TMP/out" ;;
		*) echo "$m $p: HTTP $code $(head -c 300 "$TMP/out")" >&2; return 1 ;;
	esac
}
json() { api "$1" "$2" -H 'Content-Type: application/json' --data-binary "$3"; }

# Check every host before sending anything.
for H in "$@"; do
	DF=$(device_file "$H")
	I=/home/vscode/wyse-build/images/$H
	[ -f "$I/rootfs.squashfs" ] && [ -f "$I/version" ] ||
		{ echo "no image in $I: build it first (./build.sh $H)" >&2; exit 1; }
	T=$(get "$DF" update_token)
	echo "$T" | grep -qE '^[0-9a-f]{64}$' ||
		{ echo "$DF: no update_token: build the image first (it adds one)" >&2; exit 1; }
done
api GET /rest/v1/targets?limit=1 > /dev/null || { echo "can't log in to $URL" >&2; exit 1; }

for H in "$@"; do
	DF=$(device_file "$H")
	I=/home/vscode/wyse-build/images/$H
	V=$(cat "$I/version")
	T=$(get "$DF" update_token)
	echo "$H: version $V"

	# The device, with its token (the token is also set if it changed).
	if curl -sS -K "$TMP/auth" -o /dev/null -w '%{http_code}' "$URL/rest/v1/targets/$H" | grep -q '^200$'; then
		json PUT "/rest/v1/targets/$H" "$(jq -nc --arg t "$T" '{securityToken: $t}')" > /dev/null
	else
		json POST /rest/v1/targets "$(jq -nc --arg h "$H" --arg t "$T" \
			'[{controllerId: $h, name: $h, securityToken: $t}]')" > /dev/null
		echo "  device added"
	fi

	# The image as a software module (type os) with one file.
	SM=$(json POST /rest/v1/softwaremodules "$(jq -nc --arg h "$H" --arg v "$V" \
		'[{name: $h, version: $v, type: "os"}]')" | jq -r '.[0].id')
	echo "  uploading rootfs.squashfs ($(wc -c < "$I/rootfs.squashfs" | tr -d ' ') bytes)..."
	SHA=$(sha256sum < "$I/rootfs.squashfs" | cut -d' ' -f1)
	GOT=$(api POST "/rest/v1/softwaremodules/$SM/artifacts" -F "file=@$I/rootfs.squashfs;filename=rootfs.squashfs" |
		jq -r '.hashes.sha256')
	[ "$GOT" = "$SHA" ] || { echo "  upload: server has sha256 $GOT, expected $SHA" >&2; exit 1; }

	# A distribution set with the module, assigned to the device.
	DS=$(json POST /rest/v1/distributionsets "$(jq -nc --arg h "$H" --arg v "$V" --argjson sm "$SM" \
		'[{name: $h, version: $v, type: "os", modules: [{id: $sm}]}]')" | jq -r '.[0].id')
	json POST "/rest/v1/targets/$H/assignedDS" "$(jq -nc --argjson ds "$DS" '[{id: $ds, type: "forced"}]')" > /dev/null
	echo "  assigned; waiting for $H to install it (up to 40 min)..."

	end=$(( $(date +%s) + 2400 )); last=
	while :; do
		A=$(api GET "/rest/v1/targets/$H/actions?limit=1&sort=id:DESC" 2>/dev/null | jq -c '.content[0] // {}') || A='{}'
		st=$(echo "$A" | jq -r '.status // ""'); det=$(echo "$A" | jq -r '.detailStatus // ""')
		[ "$st $det" = "$last" ] || { echo "  $(date +%I:%M%p) $st $det"; last="$st $det"; }
		# status: pending or finished (the action ended); detailStatus:
		# finished (success), error, canceled, or a step on the way.
		case "$st/$det" in
			finished/finished) break ;;
			finished/*) echo "$H: update failed ($det). Stopping here." >&2; exit 1 ;;
		esac
		[ "$(date +%s)" -lt "$end" ] || { echo "$H: no result in 40 min. Stopping here." >&2; exit 1; }
		sleep 20
	done
	echo "$H: running $V"
done

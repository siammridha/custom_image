#!/bin/sh
# A device's settings and keys, one value per line in its own file
# (keys/device.<any name>; the host name is always line 2):
#
#   3040                    model
#   shop-01                 host name
#   <64 hex>                SSH host key: ed25519 seed (dropbear and NetBird SSH)
#   <base64>                NetBird WireGuard private key (default.json PrivateKey)
#   privkey:<64 hex>        Tailscale machine key (tailscaled.state _machinekey)
#
#   scripts/device-keys.sh <file>            check it, make missing keys
#   scripts/device-keys.sh <file> <target>   also write the keys into the
#                                            image's target folder
#
# Only lines 1 and 2 are needed: missing keys are made from /dev/urandom and
# written back to the file. Keys already there are kept, so a device keeps
# its NetBird and Tailscale peer. File formats follow the programs' source:
#   - NetBird 0.83.1 default.json: PrivateKey and SSHKey (PKCS8 PEM, as Go's
#     x509.MarshalPKCS8PrivateKey makes it); NetBird fills in the rest.
#   - Tailscale 1.104.7 tailscaled.state (FileStore: JSON map, values base64).
#     WireGuard and Tailscale keys are clamped like clamp25519Private
#     (types/key/util.go); Tailscale doesn't clamp keys it loads.
#   - dropbear 2026.94 host key (buf_put_ed25519_priv_key): string
#     "ssh-ed25519", uint32 64, seed, public key. The server reads only this
#     format.
set -eu
F=${1:?usage: $0 <device file> [target dir]}
T=${2:-}
die() { echo "$F: $*" >&2; exit 1; }
[ -f "$F" ] || die "no such file"
line() { sed -n "${1}p" "$F" | tr -d '\r' | sed 's/^[ \t]*//;s/[ \t]*$//'; }
MODEL=$(line 1); HOST=$(line 2); SSH=$(line 3); NB=$(line 4); TS=$(line 5)
[ -z "$(sed -n '6,$p' "$F" | tr -d ' \t\r\n')" ] || die "more than 5 lines"

case $MODEL in 3040|5020) ;; *) die "line 1: model must be 3040 or 5020, not '$MODEL'" ;; esac
echo "$HOST" | grep -qE '^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$' ||
	die "line 2: '$HOST' is not a valid host name (letters, digits and '-', max 63)"

hex32() { echo "$1" | grep -qE '^[0-9a-f]{64}$'; }
rand() { od -An -tx1 -N32 /dev/urandom | tr -d ' \n'; }
clamp() {
	printf '%02x%s%02x' $((0x$(echo "$1" | cut -c1-2) & 248)) \
		"$(echo "$1" | cut -c3-62)" $(((0x$(echo "$1" | cut -c63-64) & 127) | 64))
}
b64() { xxd -r -p | base64 | tr -d '\n'; }

if [ -z "$SSH" ]; then SSH=$(rand); fi
hex32 "$SSH" || die "line 3: SSH key must be 64 hex characters"
if [ -z "$NB" ]; then NB=$(clamp "$(rand)" | b64); fi
NBHEX=$(printf %s "$NB" | base64 -d 2>/dev/null | xxd -p -c 64) || true
hex32 "$NBHEX" || die "line 4: NetBird key must be 32 bytes in base64"
if [ -z "$TS" ]; then TS=privkey:$(clamp "$(rand)"); fi
hex32 "${TS#privkey:}" && [ "${TS%%:*}" = privkey ] ||
	die "line 5: Tailscale key must be privkey:<64 hex characters>"

# Written back only when something changed (new keys, extra spaces, CRLF).
NEW=$(printf "%s\n" "$MODEL" "$HOST" "$SSH" "$NB" "$TS")
if [ "$NEW" != "$(cat "$F")" ]; then
	(umask 077; echo "$NEW" > "$F.new")
	mv "$F.new" "$F"
	echo "$F: updated"
fi
chmod 600 "$F"
[ -n "$T" ] || exit 0

# Into the image. Folders 700, files 600.
put() {
	mkdir -p "$(dirname "$T$1")" && chmod 700 "$(dirname "$T$1")"
	rm -f "$T$1"
	(umask 077; cat > "$T$1")
}
# PKCS8 for ed25519 (RFC 8410): version 0, algorithm 1.3.101.112, the seed
# in an OCTET STRING. Base64 of these 48 bytes is one 64-character line.
DER=302e020100300506032b657004220420$SSH
PUB=$(echo "$DER" | xxd -r -p | "${OPENSSL:-$HOST_DIR/bin/openssl}" pkey -inform DER \
	-pubout -outform DER | tail -c 32 | xxd -p -c 64)
hex32 "$PUB" || die "openssl could not compute the SSH public key"

printf '{\n    "PrivateKey": "%s",\n    "SSHKey": "-----BEGIN PRIVATE KEY-----\\n%s\\n-----END PRIVATE KEY-----\\n"\n}\n' \
	"$NB" "$(echo "$DER" | b64)" | put /var/lib/netbird/default.json
printf '{\n    "_machinekey": "%s"\n}\n' "$(printf %s "$TS" | base64 | tr -d '\n')" |
	put /var/lib/tailscale/tailscaled.state
echo "0000000b7373682d6564323535313900000040$SSH$PUB" | xxd -r -p | put /etc/wyse/dropbear_host_key
echo "device-keys: ssh host key: ssh-ed25519 $(echo "0000000b7373682d6564323535313900000020$PUB" | b64)"

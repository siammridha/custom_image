#!/bin/sh
# A device's settings and keys: its own file in config/devices/ (any name),
# "name = value" lines, # starts a comment line:
#
#   model     = 3040              3040 or 5020
#   host      = shop-01           host name
#   address   = 192.168.80.13     IP for scripts/deploy.sh and test-device.sh
#   ssh_key   = <64 hex>          SSH host key: ed25519 seed (dropbear and NetBird SSH)
#   netbird   = <base64>          NetBird WireGuard private key (default.json PrivateKey)
#   tailscale_state = <name>      tailscaled.state copied after the first login
#                                 (by hand), as config/tailscale/<name>: the
#                                 device keeps its Tailscale login. Empty: no
#                                 login yet
#
#   scripts/device-keys.sh <file>            check it, add missing keys
#   scripts/device-keys.sh <file> <target>   also write the keys into the
#                                            image's target folder
#
# Only model and host are needed: missing keys are made from /dev/urandom
# and added to the end of the file. Keys already there are kept, so a device
# keeps its NetBird peer. File formats follow the programs'
# source:
#   - NetBird 0.83.1 default.json: PrivateKey and SSHKey (PKCS8 PEM, as Go's
#     x509.MarshalPKCS8PrivateKey makes it), and the settings (below);
#     NetBird fills in the rest.
#   - The NetBird key is clamped like Tailscale's clamp25519Private
#     (types/key/util.go).
#   - Tailscale: tailscaled.state is copied as it is (it holds the machine
#     and node keys), so the device file has no Tailscale key.
#   - dropbear 2026.94 host key (buf_put_ed25519_priv_key): string
#     "ssh-ed25519", uint32 64, seed, public key. The server reads only this
#     format.
set -eu
F=${1:?usage: $0 <device file> [target dir]}
T=${2:-}
die() { echo "$F: $*" >&2; exit 1; }
[ -f "$F" ] || die "no such file"
. "$(dirname "$0")/config.sh"

NAMES="model host address ssh_key netbird tailscale_state"
BAD=$(grep -vE '^[ \t]*(#|$)' "$F" | tr -d '\r' |
	grep -vE "^[ \t]*($(echo $NAMES | tr ' ' '|'))[ \t]*=" || true)
[ -z "$BAD" ] || die "unknown line: $(echo "$BAD" | head -n 1) (names: $NAMES)"
for n in $NAMES; do
	[ "$(grep -cE "^[ \t]*$n[ \t]*=" "$F")" -le 1 ] || die "$n is there more than once"
done
MODEL=$(get "$F" model); HOST=$(get "$F" host)
SSH=$(get "$F" ssh_key); NB=$(get "$F" netbird)
TSS=$(get "$F" tailscale_state)

case $MODEL in 3040|5020) ;; *) die "model must be 3040 or 5020, not '$MODEL'" ;; esac
echo "$HOST" | grep -qE '^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$' ||
	die "host: '$HOST' is not a valid host name (letters, digits and '-', max 63)"

hex32() { echo "$1" | grep -qE '^[0-9a-f]{64}$'; }
rand() { od -An -tx1 -N32 /dev/urandom | tr -d ' \n'; }
clamp() {
	printf '%02x%s%02x' $((0x$(echo "$1" | cut -c1-2) & 248)) \
		"$(echo "$1" | cut -c3-62)" $(((0x$(echo "$1" | cut -c63-64) & 127) | 64))
}
b64() { xxd -r -p | base64 | tr -d '\n'; }

# Missing keys are added at the end; the rest of the file stays as it is.
add() {
	if [ -z "$ADDED" ]; then
		[ -z "$(tail -c 1 "$F")" ] || echo >> "$F"
		echo "# Made by the build. Keep them: new keys mean a new VPN peer." >> "$F"
	fi
	printf '%-9s = %s\n' "$1" "$2" >> "$F"
	ADDED="$ADDED $1"
}
ADDED=
if [ -z "$SSH" ]; then SSH=$(rand); add ssh_key "$SSH"; fi
hex32 "$SSH" || die "ssh_key must be 64 hex characters"
if [ -z "$NB" ]; then NB=$(clamp "$(rand)" | b64); add netbird "$NB"; fi
NBHEX=$(printf %s "$NB" | base64 -d 2>/dev/null | xxd -p -c 64) || true
hex32 "$NBHEX" || die "netbird must be 32 bytes in base64"
# Only a check that it is a tailscaled.state (FileStore JSON with a machine key).
if [ -n "$TSS" ]; then
	TSS=$(dirname "$F")/../tailscale/$TSS
	[ -f "$TSS" ] || die "tailscale_state: no such file $TSS"
	grep -q '"_machinekey"' "$TSS" ||
		die "tailscale_state: $TSS is not a tailscaled.state"
fi
[ -z "$ADDED" ] || echo "$F: added$ADDED"
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

# Also the settings vpn-guard's "up" uses (wyse-init/src/config.rs
# NB_UP_ARGS), so the daemon connects with them at start. Field names: NetBird
# 0.83.1 client/internal/profilemanager/config.go; ManagementURL is a Go
# url.URL, saved as its fields.
U=${NB_URL:?NB_URL (netbird_url) is needed to write default.json}
NB_SCHEME=${U%%://*}; NB_HOST=${U#*://}; NB_HOST=${NB_HOST%%/*}
printf '{\n    "PrivateKey": "%s",\n    "SSHKey": "-----BEGIN PRIVATE KEY-----\\n%s\\n-----END PRIVATE KEY-----\\n",\n    "ManagementURL": {"Scheme": "%s", "Host": "%s"},\n    "ServerSSHAllowed": true,\n    "EnableSSHRoot": true,\n    "DisableDNS": true,\n    "NetworkMonitor": true\n}\n' \
	"$NB" "$(echo "$DER" | b64)" "$NB_SCHEME" "$NB_HOST" | put /var/lib/netbird/default.json
# Tailscale: the state copied after the first login. A new device has none:
# tailscaled makes its keys, you log in by hand once and copy the state.
if [ -n "$TSS" ]; then
	put /var/lib/tailscale/tailscaled.state < "$TSS"
else
	rm -f "$T/var/lib/tailscale/tailscaled.state" # from an earlier build
fi
echo "0000000b7373682d6564323535313900000040$SSH$PUB" | xxd -r -p | put /etc/wyse/dropbear_host_key
echo "device-keys: ssh host key: ssh-ed25519 $(echo "0000000b7373682d6564323535313900000020$PUB" | b64)"

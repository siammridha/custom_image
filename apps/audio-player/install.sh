#!/bin/sh
# Install github.com/siammridha/audio_player on a Wyse running this image.
# Run on the Wyse as root, after boot:
#
#   sh install.sh
#
# Everything goes into /data, so it survives reboots and wyse-wipe-data
# removes it. Same steps as the app's own deploy/install.sh, adapted:
#   - packages go into the Alpine folder (/data/alpine)
#   - the sound drivers and firmware are in the image (modules-3040,
#     firmware-3040) and load at boot
#   - the OpenRC service runs in the Alpine subsystem and is restarted if
#     it stops
set -eu

REPO=siammridha/audio_player
MODEL=$(cat /etc/wyse/model 2>/dev/null || true)
A=/data/alpine

[ "$(id -u)" = 0 ] || { echo "Run this as root." >&2; exit 1; }
# The built-in sound setup below (SOF driver, rt5672 card) is the 3040's.
[ "$MODEL" = 3040 ] || { echo "Only the Wyse 3040 is supported (this is: ${MODEL:-unknown})." >&2; exit 1; }

echo "Installing packages into $A..."
alpine apk add --no-cache alsa-lib libgcc alsa-utils

echo "Downloading the latest release of $REPO..."
mkdir -p "$A/usr/local/bin"
alpine wget -qO /usr/local/bin/audio-player.new "https://github.com/$REPO/releases/latest/download/audio-player"
chmod 755 "$A/usr/local/bin/audio-player.new"
mv "$A/usr/local/bin/audio-player.new" "$A/usr/local/bin/audio-player"
mkdir -p "$A/var/lib/audio-player/audio"

cat > "$A/etc/init.d/audio-player" <<EOF
#!/sbin/openrc-run

name="audio-player"
description="Web-controlled audio player"

command="/usr/local/bin/audio-player"
supervisor=supervise-daemon
pidfile="/run/\${RC_SVCNAME}.pid"
output_log="/var/log/audio-player.log"
error_log="/var/log/audio-player.log"

: "\${PORT:=3000}"
: "\${MUSIC_DIR:=/var/lib/audio-player/audio}"
: "\${STATE_FILE:=/var/lib/audio-player/state.json}"
export PORT MUSIC_DIR STATE_FILE AUDIO_DEVICE RUST_LOG

depend() {
	need net
}

# The drivers load at boot; the built-in card appears once the sound
# chip's firmware has loaded.
start_pre() {
	i=0
	while [ \$i -lt 20 ] && ! grep -q rt5672 /proc/asound/cards 2>/dev/null; do
		sleep 1; i=\$((i + 1))
	done
	alsactl restore 2>/dev/null || true
}
EOF
chmod 755 "$A/etc/init.d/audio-player"
echo 'export RUST_LOG=error' > "$A/etc/conf.d/audio-player"

# The card is needed to set up the headphone output below.
i=0
while [ $i -lt 20 ] && ! grep -q rt5672 /proc/asound/cards; do sleep 1; i=$((i + 1)); done
grep -q rt5672 /proc/asound/cards || echo "Warning: built-in sound card not found (see dmesg)." >&2

# The Wyse 3040's headphone jack (rt5670 codec) boots with its internal
# output routing switched off. Saved with alsactl, restored by the service.
echo "Enabling headphone output routing..."
alpine /bin/sh -c '
	for c in "DAC1 MIXL DAC1" "DAC1 MIXR DAC1" "HPOVOL MIXL DAC1" \
		"HPOVOL MIXR DAC1" "HPO MIX DAC1" "HPO MIX HPVOL"; do
		amixer -c rt5672 sset "$c" on >/dev/null 2>&1
	done
	amixer -c rt5672 sset HP 100% >/dev/null 2>&1
	alsactl store 2>/dev/null' || true

alpine rc-update add audio-player default >/dev/null
alpine rc-service audio-player restart
echo "audio-player installed:"
echo "  http://<device-ip>:3000    music: $A/var/lib/audio-player/audio"

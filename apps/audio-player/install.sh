#!/bin/sh
# Install github.com/siammridha/audio_player on a Wyse running this image.
# Run on the Wyse as root, after boot:
#
#   sh install.sh [driver-pack.tar.gz]
#
# Everything goes into /data, so it survives reboots and wyse-wipe-data
# removes it. Same steps as the app's own deploy/install.sh, adapted:
#   - packages go into the Alpine folder (/data/alpine)
#   - the sound drivers are a driver pack made for this image's kernel
#     (drivers/build.sh 3040 sound), not part of the image
#   - the OpenRC service runs in the Alpine subsystem, is restarted if it
#     stops, and loads the drivers before it starts
set -eu

REPO=siammridha/audio_player
KREL=$(uname -r)
MODEL=$(cat /etc/wyse/model 2>/dev/null || true)
PACK_NAME=wyse-drivers-$MODEL-sound-$KREL.tar.gz
PACK=${1:-}
DRIVERS_URL=${DRIVERS_URL:-}   # optional: folder URL holding $PACK_NAME
A=/data/alpine
MODULES="snd-soc-rt5670 snd-soc-sst-cht-bsw-rt5672 snd-sof-acpi-intel-byt snd-usb-audio"

[ "$(id -u)" = 0 ] || { echo "Run this as root." >&2; exit 1; }
# The built-in sound setup below (SOF driver, rt5672 card) is the 3040's.
[ "$MODEL" = 3040 ] || { echo "Only the Wyse 3040 is supported (this is: ${MODEL:-unknown})." >&2; exit 1; }

echo "Installing packages into $A..."
alpine apk add --no-cache alsa-lib libgcc sof-firmware alsa-utils kmod

# A pack given on the command line is always installed (a new image build
# needs the drivers from that same build). Otherwise only when missing.
if [ -n "$PACK" ] || ! grep -qs snd-sof-acpi-intel-byt "$A/lib/modules/$KREL/modules.dep"; then
	echo "Installing the sound drivers for kernel $KREL..."
	if [ -z "$PACK" ] && [ -n "$DRIVERS_URL" ]; then
		alpine wget -qO "/tmp/$PACK_NAME" "$DRIVERS_URL/$PACK_NAME"
		PACK=$A/tmp/$PACK_NAME
	fi
	[ -n "$PACK" ] && [ -f "$PACK" ] || { echo "Need $PACK_NAME (argument or DRIVERS_URL)." >&2; exit 1; }
	# The main system has no gunzip: Alpine's tar unpacks it.
	alpine tar -xzf - -C / < "$PACK"
	# Other apps' packs share this folder: index all of them together.
	alpine depmod "$KREL"
fi

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

# Firmware and drivers live in the Alpine folder, not in the image. The
# kernel reads firmware by its path in the main system. The built-in card
# appears once the sound chip's firmware has loaded.
start_pre() {
	printf %s $A/lib/firmware > /sys/module/firmware_class/parameters/path
	modprobe -a $MODULES
	i=0
	while [ \$i -lt 20 ] && ! grep -q rt5672 /proc/asound/cards 2>/dev/null; do
		sleep 1; i=\$((i + 1))
	done
	alsactl restore 2>/dev/null || true
}
EOF
chmod 755 "$A/etc/init.d/audio-player"
echo 'export RUST_LOG=error' > "$A/etc/conf.d/audio-player"

# Load the drivers now, to set up the headphone output below.
printf %s "$A/lib/firmware" > /sys/module/firmware_class/parameters/path
alpine modprobe -a $MODULES
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

#!/bin/sh
# Install github.com/siammridha/simple_kvm on a Wyse running this image.
# Run on the Wyse as root, after boot:
#
#   sh install.sh [driver-pack.tar.gz]
#
# Everything goes into /data, so it survives reboots and wyse-wipe-data
# removes it. Same steps as the app's own deploy/install.sh, adapted:
#   - packages go into the Alpine folder (/data/alpine)
#   - the GPU, capture card and USB serial drivers are a driver pack made
#     for this image's kernel (drivers/build.sh 3040 kvm), not part of the
#     image
#   - the service is /data/services/simple-kvm/run instead of OpenRC
#   - it listens on port 3001 (audio-player has 3000)
set -eu

REPO=siammridha/simple_kvm
PORT=3001
KREL=$(uname -r)
MODEL=$(cat /etc/wyse/model 2>/dev/null || true)
PACK_NAME=wyse-drivers-$MODEL-kvm-$KREL.tar.gz
PACK=${1:-}
DRIVERS_URL=${DRIVERS_URL:-}   # optional: folder URL holding $PACK_NAME
MODULES="i915 uvcvideo ch341"
A=/data/alpine
S=/data/services/simple-kvm

[ "$(id -u)" = 0 ] || { echo "Run this as root." >&2; exit 1; }
# The encoder needs the Intel GPU (i965 VA-API driver): the 3040's.
[ "$MODEL" = 3040 ] || { echo "Only the Wyse 3040 is supported (this is: ${MODEL:-unknown})." >&2; exit 1; }

echo "Installing packages into $A..."
alpine apk add --no-cache libva libva-intel-driver libva-utils libgcc kmod curl

# A pack given on the command line is always installed (a new image build
# needs the drivers from that same build). Otherwise only when missing.
if [ -n "$PACK" ] || ! grep -qs '/i915.ko' "$A/lib/modules/$KREL/modules.dep"; then
	echo "Installing the GPU, capture and serial drivers for kernel $KREL..."
	if [ -z "$PACK" ] && [ -n "$DRIVERS_URL" ]; then
		alpine curl -fsSLo "/tmp/$PACK_NAME" "$DRIVERS_URL/$PACK_NAME"
		PACK=$A/tmp/$PACK_NAME
	fi
	[ -n "$PACK" ] && [ -f "$PACK" ] || { echo "Need $PACK_NAME (argument or DRIVERS_URL)." >&2; exit 1; }
	gunzip -c "$PACK" | tar -x -C "$A"
	# Other apps' packs share this folder: index all of them together.
	chroot "$A" depmod "$KREL"
fi

# Load the drivers now, to check the encoder below.
printf %s "$A/lib/firmware" > /sys/module/firmware_class/parameters/path
chroot "$A" modprobe -a $MODULES
i=0
while [ $i -lt 10 ] && ! ls /dev/dri/renderD* >/dev/null 2>&1; do sleep 1; i=$((i + 1)); done
ls /dev/dri/renderD* >/dev/null 2>&1 || { echo "No GPU render device (/dev/dri/renderD*), see dmesg." >&2; exit 1; }

# The app has no software encoder: it will not start without this.
if alpine vainfo 2>&1 | grep -q 'VAProfileH264ConstrainedBaseline.*VAEntrypointEncSlice'; then
	echo "GPU reports H.264 encode support."
else
	echo "Warning: vainfo did not report H.264 encode; the app may not start." >&2
fi
ls /dev/video* >/dev/null 2>&1 || echo "Note: no capture card plugged in yet (fine, the app starts without it)."
ls /dev/ttyUSB* >/dev/null 2>&1 || echo "Note: no CH9329 serial adapter plugged in yet (fine)."

echo "Downloading the latest release of $REPO..."
mkdir -p "$A/usr/local/bin"
alpine curl -fsSLo /usr/local/bin/simple_kvm.new "https://github.com/$REPO/releases/latest/download/simple_kvm"
chmod 755 "$A/usr/local/bin/simple_kvm.new"
mv "$A/usr/local/bin/simple_kvm.new" "$A/usr/local/bin/simple_kvm"

mkdir -p "$S"
cat > "$S/run.new" <<EOF
#!/bin/sh
# simple_kvm (installed by apps/simple-kvm/install.sh)
A=$A
# Drivers live in the Alpine folder, not in the image. Loaded at start so
# the capture card and serial adapter work when plugged in later.
printf %s "\$A/lib/firmware" > /sys/module/firmware_class/parameters/path
chroot "\$A" modprobe -a $MODULES
i=0
while [ \$i -lt 10 ] && ! ls /dev/dri/renderD* >/dev/null 2>&1; do
	sleep 1; i=\$((i + 1))
done
exec alpine /bin/sh -c '
	export HTTP_PORT=$PORT RUST_LOG=info
	exec /usr/local/bin/simple_kvm >> /var/log/simple_kvm.log 2>&1'
EOF
chmod 755 "$S/run.new"
mv "$S/run.new" "$S/run"
# runsvdir starts a new service by itself; restart an existing one.
sv restart "$S" >/dev/null 2>&1 || true
echo "simple_kvm installed. It starts within a few seconds:"
echo "  http://<device-ip>:$PORT    log: $A/var/log/simple_kvm.log"

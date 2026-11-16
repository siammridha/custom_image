#!/bin/sh
# Install github.com/siammridha/simple_kvm on a Wyse running this image.
# Run on the Wyse as root, after boot:
#
#   sh install.sh
#
# Everything goes into /data, so it survives reboots and wyse-wipe-data
# removes it. Same steps as the app's own deploy/install.sh, adapted:
#   - packages go into the Alpine folder (/data/alpine)
#   - the GPU, capture card and USB serial drivers are in the image
#     (modules-3040) and load at boot
#   - the OpenRC service runs in the Alpine subsystem and is restarted if
#     it stops
#   - it listens on port 3001 (audio-player has 3000)
set -eu

REPO=siammridha/simple_kvm
PORT=3001
MODEL=$(cat /etc/wyse/model 2>/dev/null || true)
A=/data/alpine

[ "$(id -u)" = 0 ] || { echo "Run this as root." >&2; exit 1; }
# The encoder needs the Intel GPU (i965 VA-API driver): the 3040's.
[ "$MODEL" = 3040 ] || { echo "Only the Wyse 3040 is supported (this is: ${MODEL:-unknown})." >&2; exit 1; }

echo "Installing packages into $A..."
alpine apk add --no-cache libva libva-intel-driver libva-utils libgcc

# The GPU driver loads at boot.
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
alpine wget -qO /usr/local/bin/simple_kvm.new "https://github.com/$REPO/releases/latest/download/simple_kvm"
chmod 755 "$A/usr/local/bin/simple_kvm.new"
mv "$A/usr/local/bin/simple_kvm.new" "$A/usr/local/bin/simple_kvm"

cat > "$A/etc/init.d/simple_kvm" <<EOF
#!/sbin/openrc-run

name="simple_kvm"
description="Simple KVM"

command="/usr/local/bin/simple_kvm"
supervisor=supervise-daemon
pidfile="/run/\${RC_SVCNAME}.pid"
output_log="/var/log/simple_kvm.log"
error_log="/var/log/simple_kvm.log"
export HTTP_PORT=$PORT

depend() {
	need net
}

# The drivers load at boot; wait for the GPU in case this runs early.
start_pre() {
	i=0
	while [ \$i -lt 10 ] && ! ls /dev/dri/renderD* >/dev/null 2>&1; do
		sleep 1; i=\$((i + 1))
	done
	return 0
}
EOF
chmod 755 "$A/etc/init.d/simple_kvm"
echo 'export RUST_LOG=info' > "$A/etc/conf.d/simple_kvm"

alpine rc-update add simple_kvm default >/dev/null
alpine rc-service simple_kvm restart
echo "simple_kvm installed:"
echo "  http://<device-ip>:$PORT    log: $A/var/log/simple_kvm.log"

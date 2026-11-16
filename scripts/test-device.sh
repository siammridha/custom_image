#!/bin/sh
# Deploy the built image to a test Wyse and check that it works.
#
#   scripts/test-device.sh <model> [device-ip]   (ip default: DEVICE_IP in .env)
#
# Only for a test device: it replaces /data/alpine with a fresh one (the old
# one is deleted at the end), removes all apps and installs both apps in
# apps/ again with the driver packs from drivers/out (build them first).
# The apps need a Wyse 3040.
cd "$(dirname "$0")/.." || exit 1
get() { sed -n "s/^$1=//p" .env 2>/dev/null | head -n 1 | tr -d '"\r'; }
MODEL=${1:-}
case $MODEL in 3040|5020) ;; *) echo "usage: $0 <3040|5020> [device-ip]" >&2; exit 1 ;; esac
IP=${2:-$(get DEVICE_IP)}
[ -n "$IP" ] || { echo "usage: $0 <3040|5020> <device-ip> (or DEVICE_IP in .env)" >&2; exit 1; }
KEY=$(get SSH_KEY_FILE); KEY=${KEY:-keys/wyse_ed25519}
HOST=$(get HOST_DOMAIN)
O=${WYSE_OUT:-/home/vscode/wyse-build/output-$MODEL}
KREL=$(ls "$O/target/lib/modules" 2>/dev/null | head -n 1)
K="-i $KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5"
D=root@$IP
S="ssh -n $K $D"
waitup() { sleep 20; for i in $(seq 40); do $S true 2>/dev/null && break; sleep 5; done; echo up; sleep 45; }

echo "#### deploy"
scripts/deploy.sh "$MODEL" "$IP" </dev/null 2>&1 | grep -E "md5|rebooting|FAIL|rror"
waitup
$S 'ip route | grep default; netbird status | grep -E "Management|Signal"; tailscale status | grep -c .
for a in sv runsv runsvdir chroot renice cp; do command -v $a >/dev/null && echo "still there: $a"; done; true'

echo "#### fresh /data/alpine"
$S 'mv /data/alpine /data/alpine.bad
pkill -f "[w]yse-init run apps"; wyse-init stop-apps   # init starts run apps again
grep -o " /data/alpine.bad[^ ]*" /proc/mounts | while read m; do umount -l $m; done 2>/dev/null
[ -d /data/services ] && mv /data/services /data/alpine.bad/   # deleted with it at the end
alpine sh -c "echo sh ok"
echo "--- ps in alpine"; alpine ps
echo "--- top in alpine"; alpine top -bn1
echo "--- rc-status"; alpine rc-status -a 2>&1 | head -20
alpine apk add --no-cache htop >/dev/null && alpine htop --version | head -1 && alpine apk del htop >/dev/null && echo apk ok
cat /data/alpine/etc/apk/world; alpine cat /proc/self/cgroup
echo "--- main system processes seen from alpine"; alpine ps | grep -cE "netbird|tailscaled|dropbear"'

for p in kvm:simple-kvm sound:audio-player; do
	pk=${p%%:*} a=${p#*:}
	f=drivers/out/wyse-drivers-$MODEL-$pk-$KREL.tar.gz
	echo "#### $a"
	[ -f "$f" ] || { echo "missing $f (drivers/build.sh $MODEL $pk)"; continue; }
	ssh $K $D "cat > /tmp/${f##*/}" < "$f"
	ssh $K $D "sh -s /tmp/${f##*/}" < apps/$a/install.sh 2>&1 | grep -v "^ *$" | sed -n '$p;/rror\|not found\|arning\|\*/p'
done

echo "#### after install"
# The main system has no pidof, wget or tail: these run inside Alpine.
$S 'sleep 5; alpine rc-status | grep -E "simple_kvm|audio-player"
alpine sh -c "for n in simple_kvm audio-player; do p=\$(pidof \$n); echo \$n pid=\$p cgroup=\$(cat /proc/\$p/cgroup 2>/dev/null); done"
for p in 3000 3001; do alpine wget -qO /dev/null http://127.0.0.1:$p/ && echo "port $p ok" || echo "port $p FAILED"; done
echo "--- kill simple_kvm, supervise-daemon restarts it"; alpine pkill -9 simple_kvm; sleep 8; alpine pidof simple_kvm || echo NOT RESTARTED'

echo "#### stop-apps (also runs at shutdown)"
$S 'wyse-init stop-apps; echo "left in apps cgroup: $(wc -l < /sys/fs/cgroup/apps/cgroup.procs)"'

echo "#### reboot"
$S reboot; waitup
$S 'alpine rc-status | grep -E "simple_kvm|audio-player"; alpine pidof simple_kvm audio-player
echo "--- cleanup"; [ -d /data/alpine.bad ] && mkdir -p /data/alpine/root/del && mv /data/alpine.bad /data/alpine/root/del/ && alpine rm -rf /root/del; echo /data/* /data/alpine/root/*
grep -ihE "not found|alpine:" /var/log/messages | grep -v WQBC | grep -v iptables'

echo "#### private CA"
$S "ls /data/alpine/usr/local/share/ca-certificates
[ -n '$HOST' ] && { alpine wget -q -O /dev/null https://$HOST:4478/; echo \"wget rc=\$? (5 = certificate not trusted)\"; }
alpine wget -q -O /dev/null https://github.com/; echo \"github rc=\$?\""

# sv already looks up names in /data/services (busybox SV_DEFAULT_SERVICE_DIR),
# so "sv stop simple-kvm" works. With no name, apply to every app:
# "sv status" lists them all.
sv() {
	if [ $# -eq 1 ] && [ -d /data/services ]; then
		(cd /data/services && set -- "$1" * && [ "$2" != "*" ] && command sv "$@")
	else
		command sv "$@"
	fi
}

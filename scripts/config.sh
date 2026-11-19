# Reading the config folder (config/). Sourced by build.sh, post-build.sh and
# the scripts, after they set CFG to the folder.
# Files are "name = value" lines; lines starting with # are comments.

# get <file> <name>: the value, or nothing.
get() { sed -n "s/^[ \t]*$2[ \t]*=[ \t]*//p" "$1" 2>/dev/null | head -n 1 | tr -d '\r' | sed 's/[ \t]*$//'; }

# device_file <host name>: the file in config/devices/ whose host is that name.
device_file() {
	for f in "$CFG"/devices/*; do
		[ -f "$f" ] && [ "$(get "$f" host)" = "$1" ] && { echo "$f"; return 0; }
	done
	echo "No device file in $CFG/devices/ with host = $1" >&2
	return 1
}

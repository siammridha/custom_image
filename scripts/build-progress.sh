#!/bin/sh
# Show how far a running build is: packages done out of all packages, and
# the package and step running now. Updates every 5 seconds until the build
# stops (Ctrl-C to quit). With -1: print once and exit.
#
#   scripts/build-progress.sh [-1] [model]   (model default: 3040)
#
# The bar counts packages, not time: GCC, the kernel and Go take much longer
# than most packages.
cd "$(dirname "$0")/.." || exit 1
ONCE=
[ "${1:-}" = -1 ] && { ONCE=1; shift; }
MODEL=${1:-3040}
O=${WYSE_OUT:-/home/vscode/wyse-build/output-$MODEL}
LOG=$O/build/build-time.log
LIST=$O/.wyse-packages
[ -f "$O/.config" ] || { echo "No build in $O (make MODEL=$MODEL)." >&2; exit 1; }

# All packages of this config, with their dependencies. Asking Buildroot
# takes about a minute, so the list is kept until the config changes.
if [ ! -s "$LIST" ] || [ "$O/.config" -nt "$LIST" ]; then
	echo "Getting the package list (about a minute)..."
	env -u MAKELEVEL -u MAKEFLAGS -u MFLAGS make -s -C buildroot \
		BR2_EXTERNAL="$PWD/external" O="$O" show-info 2>/dev/null |
		jq -r 'keys[]' > "$LIST.new" && [ -s "$LIST.new" ] &&
		mv "$LIST.new" "$LIST" || { rm -f "$LIST.new"; echo "Can't get the package list." >&2; exit 1; }
fi
TOTAL=$(wc -l < "$LIST")

show() {
	# A package is done when one of its install steps has ended.
	DONE=$(grep -s ':end  :install-' "$LOG" | sed 's/.*: //' | sort -u | grep -cxF -f "$LIST")
	# Packages running now: a step started and not yet ended.
	NOW=$(awk -F': *' '/:start:/ { r[$4] = 1 } /:end/ { delete r[$4] }
		END { for (p in r) printf "%s ", p }' "$LOG" 2>/dev/null)
	[ $DONE -gt $TOTAL ] && DONE=$TOTAL
	PCT=$((DONE * 100 / TOTAL))
	FULL=$((PCT * 30 / 100))
	BAR=$(printf "%${FULL}s" "" | tr ' ' '#')$(printf "%$((30 - FULL))s" "" | tr ' ' '.')
	# A terminal redraws one line; anything else (a log, Claude Code's shell
	# view) gets a new line each time something changes.
	if [ -t 1 ]; then
		printf "\r[%s] %3d%%  %d/%d packages  %-60.60s" "$BAR" $PCT $DONE $TOTAL "${NOW:-}"
	else
		LINE=$(printf "[%s] %3d%%  %d/%d packages  %s" "$BAR" $PCT $DONE $TOTAL "${NOW:-}")
		[ "$LINE" = "${LAST:-}" ] || echo "$LINE"
		LAST=$LINE
	fi
}
nl() { [ -t 1 ] && echo; }

# build.sh passes its make's process ID; otherwise look for a Buildroot make.
running() {
	if [ -n "${WYSE_BUILD_PID:-}" ]; then kill -0 "$WYSE_BUILD_PID" 2>/dev/null
	else pgrep -f "O=$O" > /dev/null; fi
}

if [ -n "$ONCE" ]; then
	show; nl
	exit 0
fi
while running; do
	show
	sleep 5
done
show; nl
[ -f "$O/images/disk.img" ] && [ "$O/images/disk.img" -nt "$LOG" ] &&
	echo "Build finished: $O/images/disk.img" || echo "The build is not running."

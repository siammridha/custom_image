#!/bin/sh
# Build the image. Asks which Wyse model it is for, then builds it.
#
#   ./build.sh            asks for the model
#   ./build.sh 3040       no question
#
# The full log goes to build.log. The first build of a model takes about an
# hour; later builds only redo what changed.
set -eu
cd "$(dirname "$0")"

MODEL=${1:-}
while :; do
	case $MODEL in
		3040|5020) break ;;
		"") ;;
		*) echo "Unknown model: $MODEL" ;;
	esac
	echo "Which model is the image for?"
	echo "  1) Wyse 3040 (Intel Atom)"
	echo "  2) Wyse 5020 (AMD)"
	printf "Choose 1 or 2: "
	read -r a || exit 1
	case $a in 1|3040) MODEL=3040 ;; 2|5020) MODEL=5020 ;; *) MODEL=$a ;; esac
done

# Settings baked into the image.
[ -f .env ] || { echo "No .env: copy .env.example to .env and fill it in." >&2; exit 1; }
CA=$(sed -n 's/^ROOT_CA=//p' .env | tr -d '"\r')
[ -z "$CA" ] || [ -f "$CA" ] || { echo "ROOT_CA in .env points to $CA, which does not exist." >&2; exit 1; }

echo "Building the Wyse $MODEL image (log: build.log)..."
start=$(date +%s)
make MODEL=$MODEL > build.log 2>&1 &
BUILD=$!
# Progress bar (scripts/build-progress.sh) once the config exists.
O=/home/vscode/wyse-build/output-$MODEL
while kill -0 $BUILD 2>/dev/null && ! [ -f "$O/build/build-time.log" ]; do sleep 2; done
kill -0 $BUILD 2>/dev/null && WYSE_BUILD_PID=$BUILD scripts/build-progress.sh "$MODEL" || true
if ! wait $BUILD; then
	tail -n 20 build.log
	echo "Build failed. See build.log." >&2
	exit 1
fi

O=/home/vscode/wyse-build/output-$MODEL/images
echo "Done in $(( ($(date +%s) - start) / 60 )) min."
echo "  Full disk image:  $O/disk.img"
echo "  Install on a running device:  scripts/deploy.sh $MODEL [device-ip]"

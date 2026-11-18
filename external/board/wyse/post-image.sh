#!/bin/sh
set -e
B=$(dirname "$0")
I=$BINARIES_DIR

# GRUB config for UEFI (/EFI/BOOT) and BIOS (/boot/grub) boot.
mkdir -p "$I/efi-part/EFI/BOOT" "$I/efi-part/boot/grub"
# Development builds: no "quiet", so all boot messages show on the monitor.
if [ -s "$BASE_DIR/busybox-build.fragment" ]; then
	sed 's/ quiet//' "$B/grub.cfg" > "$I/efi-part/EFI/BOOT/grub.cfg"
else
	cp "$B/grub.cfg" "$I/efi-part/EFI/BOOT/grub.cfg"
fi
cp "$I/efi-part/EFI/BOOT/grub.cfg" "$I/efi-part/boot/grub/grub.cfg"

# BIOS boot: MBR boot code loads the core image from LBA 34 (17K),
# the core image loads the rest of itself from LBA 35 on.
cp "$BUILD_DIR"/grub2-*/build-i386-pc/grub-core/boot.img "$I/boot.img"
python3 - "$I/boot.img" "$I/grub.img" <<'PY'
import struct, sys
boot, core = sys.argv[1], sys.argv[2]
with open(boot, "r+b") as f:
    f.seek(0x5c); f.write(struct.pack("<Q", 34))
with open(core, "r+b") as f:
    f.seek(0x1f4); f.write(struct.pack("<Q", 35))
PY

support/scripts/genimage.sh -c "$B/genimage.cfg"

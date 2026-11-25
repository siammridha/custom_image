#!/bin/sh
set -e
B=$(dirname "$0")
I=$BINARIES_DIR

# Partition 1: GRUB's config for UEFI (/EFI/BOOT) and BIOS (/boot/grub) boot,
# which only picks root a or b, and grubenv: GRUB's 1024-byte environment
# block (grub-core/lib/envblk.c), padded with '#'. A new disk boots root a.
mkdir -p "$I/efi-part/EFI/BOOT" "$I/efi-part/boot/grub"
cp "$B/grub.cfg" "$I/efi-part/EFI/BOOT/grub.cfg"
cp "$B/grub.cfg" "$I/efi-part/boot/grub/grub.cfg"
H='# GRUB Environment Block
slot=a
'
{ printf '%s' "$H"; head -c $((1024 - ${#H})) /dev/zero | tr '\0' '#'; } > "$I/efi-part/grubenv"
[ "$(wc -c < "$I/efi-part/grubenv")" = 1024 ] || { echo "grubenv is not 1024 bytes"; exit 1; }

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

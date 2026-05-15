#!/bin/bash
# images/installer/iso/mkiso.sh
#
# Assemble a bootable hybrid-EFI live ISO from a staged live rootfs.
# Runs INSIDE the gnunix-installer-build VM, where xorriso, mksquashfs,
# cpio, mtools, dosfstools, and grub-mkimage have all been pulled in
# via nix-env.
#
# Per ADR-017 § "Build flow".
#
# Inputs:
#   $1  source rootfs directory (already populated; e.g. /mnt/live-rootfs)
#   $2  output ISO path (e.g. /tmp/gnunix-installer-aarch64-0.2.0.iso)
#
# Env (optional overrides):
#   KVER         kernel version (default: ls /lib/modules | head -1)
#   ARCH         target arch (default: from uname -m)
#   LABEL        ISO volume label (default: GNUNIX_LIVE)
#   SCRIPT_DIR   this script's directory (auto)

set -euo pipefail

SCRIPT_DIR=${SCRIPT_DIR:-$(cd "$(dirname "$0")" && pwd)}
ROOTFS_SRC=${1:?usage: mkiso.sh <rootfs-src-dir> <out.iso>}
OUT_ISO=${2:?usage: mkiso.sh <rootfs-src-dir> <out.iso>}

[ -d "$ROOTFS_SRC" ] || { echo "[mkiso] not a directory: $ROOTFS_SRC" >&2; exit 1; }

ARCH=${ARCH:-$(uname -m)}
LABEL=${LABEL:-GNUNIX_LIVE}
KVER=${KVER:-$(ls /lib/modules 2>/dev/null | head -1)}
[ -n "$KVER" ] || { echo "[mkiso] no /lib/modules — kernel not installed?" >&2; exit 1; }

# Per ADR-006 + ADR-017, ISO is EFI-only (no BIOS). aarch64 → BOOTAA64.EFI;
# x86_64 → BOOTX64.EFI. nuc-installer (x86_64) uses this same script;
# only the GRUB target name differs.
case "$ARCH" in
  aarch64|arm64) EFI_BIN=BOOTAA64.EFI; GRUB_TARGET=arm64-efi ;;
  x86_64|amd64)  EFI_BIN=BOOTX64.EFI;  GRUB_TARGET=x86_64-efi ;;
  *) echo "[mkiso] unsupported arch: $ARCH" >&2; exit 1 ;;
esac

for t in mksquashfs xorriso mkfs.vfat mcopy grub-mkimage; do
  command -v "$t" >/dev/null || { echo "[mkiso] missing tool: $t" >&2; exit 1; }
done

WORK=$(mktemp -d -t mkiso.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
STAGE="$WORK/iso-stage"
mkdir -p "$STAGE/live" "$STAGE/EFI/BOOT" "$STAGE/boot/grub" "$STAGE/.disk"

# ---------------------------------------------------------------------
# 1) squashfs the rootfs (the live system itself).
# ---------------------------------------------------------------------
echo "[mkiso] squashing rootfs ($(du -sh "$ROOTFS_SRC" | cut -f1)) → rootfs.squashfs"
mksquashfs "$ROOTFS_SRC" "$STAGE/live/rootfs.squashfs" \
  -comp zstd -noappend \
  -e proc -e sys -e dev -e run -e tmp -e mnt

# ---------------------------------------------------------------------
# 2) build the initramfs.
# ---------------------------------------------------------------------
echo "[mkiso] building initramfs for kernel $KVER"
SCRIPT_DIR="$SCRIPT_DIR/../initramfs" \
  OUT_DIR="$STAGE/live" \
  KVER="$KVER" \
  bash "$SCRIPT_DIR/../initramfs/build-initramfs.sh"
mv "$STAGE/live/initrd.img" "$STAGE/live/initrd.img"  # path stable; build script writes here

# ---------------------------------------------------------------------
# 3) copy the kernel from the rootfs.
# ---------------------------------------------------------------------
KERNEL_SRC=""
for cand in "$ROOTFS_SRC/boot/vmlinuz-$KVER" "$ROOTFS_SRC/boot/vmlinuz" "$ROOTFS_SRC/boot/Image"; do
  [ -f "$cand" ] && { KERNEL_SRC="$cand"; break; }
done
[ -n "$KERNEL_SRC" ] || { echo "[mkiso] no kernel found under $ROOTFS_SRC/boot/" >&2; exit 1; }
cp "$KERNEL_SRC" "$STAGE/live/vmlinuz"
echo "[mkiso] kernel: $(du -h "$STAGE/live/vmlinuz" | cut -f1)"

# ---------------------------------------------------------------------
# 4) GRUB EFI binary + grub.cfg for the live menu.
# ---------------------------------------------------------------------
cat > "$WORK/grub-early.cfg" <<EOF
search --no-floppy --label --set=root $LABEL
set prefix=(\$root)/boot/grub
configfile \$prefix/grub.cfg
EOF

grub-mkimage \
  --format="$GRUB_TARGET" \
  --output="$WORK/$EFI_BIN" \
  --config="$WORK/grub-early.cfg" \
  --prefix="/boot/grub" \
  part_gpt part_msdos fat iso9660 normal configfile linux search search_label \
  echo regexp loadenv test all_video gfxterm

cat > "$STAGE/boot/grub/grub.cfg" <<EOF
set default=0
set timeout=5
insmod all_video

menuentry "Install GNUnix" {
    linux  /live/vmlinuz boot=live live-label=$LABEL quiet console=tty1 console=ttyAMA0,115200
    initrd /live/initrd.img
}

menuentry "Install GNUnix (verbose)" {
    linux  /live/vmlinuz boot=live live-label=$LABEL console=tty1 console=ttyAMA0,115200
    initrd /live/initrd.img
}

menuentry "Memory test (placeholder)" {
    echo "memtest binary not bundled; reboot to your firmware menu."
    sleep 5
}
EOF

# Build a FAT efi.img containing /EFI/BOOT/<EFI_BIN>.
# Size: ~4 MiB is plenty; round up.
EFI_IMG="$WORK/efi.img"
EFI_SIZE_KB=$(( ($(stat -c %s "$WORK/$EFI_BIN") / 1024) + 1024 ))
dd if=/dev/zero of="$EFI_IMG" bs=1K count=$EFI_SIZE_KB status=none
mkfs.vfat -F 16 -n EFI "$EFI_IMG" >/dev/null
mmd -i "$EFI_IMG" ::/EFI
mmd -i "$EFI_IMG" ::/EFI/BOOT
mcopy -i "$EFI_IMG" "$WORK/$EFI_BIN" "::/EFI/BOOT/$EFI_BIN"

# Mirror into the ISO tree so EFI firmware can also find it by path.
cp "$WORK/$EFI_BIN" "$STAGE/EFI/BOOT/$EFI_BIN"

# ---------------------------------------------------------------------
# 5) .disk/info — provenance.
# ---------------------------------------------------------------------
SHORT_VER=${VER:-unknown}
printf 'gnunix-installer %s %s\n' "$ARCH" "$SHORT_VER" > "$STAGE/.disk/info"

# ---------------------------------------------------------------------
# 6) xorriso — hybrid EFI ISO.
# ---------------------------------------------------------------------
echo "[mkiso] assembling $OUT_ISO"
xorriso -as mkisofs \
  -iso-level 3 \
  -full-iso9660-filenames \
  -volid "$LABEL" \
  -e --interval:appended_partition_2:all:: \
  -no-emul-boot \
  -append_partition 2 0xef "$EFI_IMG" \
  -appended_part_as_gpt \
  -partition_cyl_align off \
  -partition_offset 16 \
  -output "$OUT_ISO" \
  "$STAGE"

ls -lh "$OUT_ISO"
echo "[mkiso] done."

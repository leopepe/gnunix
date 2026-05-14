#!/bin/bash
# Build a bootable disk image from /mnt/lfs (the rootfs produced by build.sh)
# and an EFI partition containing GRUB. Output: /tmp/gnunix-base-disk.img.
#
# Runs INSIDE the gnunix-builder VM (uses losetup, sgdisk, mkfs.*, grub-mkimage).
# build-all.sh then copies the image back to the host for Tart import.

set -euo pipefail

REPO_ROOT=${REPO_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}
LFS=${LFS:-/mnt/lfs}

# Resolved for symmetry with the other image build scripts; not yet
# embedded in the disk image but useful in logs / future metadata.
# shellcheck disable=SC2034
VERSION=$(jq -r .lfs_image_version "$REPO_ROOT/tools/manifest.json")
KERNEL_VERSION=$(jq -r .kernel.version "$REPO_ROOT/tools/manifest.json")
ROOTFS_GB=$(jq -r .image_packaging.rootfs_size_gb "$REPO_ROOT/tools/manifest.json")
EFI_MB=$(jq -r .image_packaging.boot_partition_mb "$REPO_ROOT/tools/manifest.json")

WORK=$(mktemp -d)
IMG=/tmp/gnunix-base-disk.img
TOTAL_MB=$(( ROOTFS_GB * 1024 + EFI_MB + 64 ))

require() { command -v "$1" >/dev/null || { echo "[mkimage] missing tool: $1" >&2; exit 1; }; }
for t in truncate sgdisk losetup mkfs.vfat mkfs.ext4 grub-mkimage rsync; do require "$t"; done

echo "[mkimage] creating raw disk: ${TOTAL_MB}MB → $IMG"
rm -f "$IMG"
truncate -s "${TOTAL_MB}M" "$IMG"

# GPT layout: ESP (FAT32) + ext4 root
sgdisk --zap-all "$IMG"
sgdisk --new=1:0:+${EFI_MB}M --typecode=1:ef00 --change-name=1:'lfs-efi'  "$IMG"
sgdisk --new=2:0:0           --typecode=2:8300 --change-name=2:'lfs-root' "$IMG"

LOOP=$(losetup --show -fP "$IMG")
cleanup() {
  set +e
  mountpoint -q "$WORK/mnt/boot/efi" && umount "$WORK/mnt/boot/efi"
  mountpoint -q "$WORK/mnt"          && umount "$WORK/mnt"
  losetup -d "$LOOP" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

mkfs.vfat -F32 -n lfs-efi "${LOOP}p1"
mkfs.ext4 -F  -L lfs-root  "${LOOP}p2"

mkdir -p "$WORK/mnt"
mount "${LOOP}p2" "$WORK/mnt"
mkdir -p "$WORK/mnt/boot/efi"
mount "${LOOP}p1" "$WORK/mnt/boot/efi"

echo "[mkimage] copying rootfs from $LFS"
rsync -aHAX --info=progress2 \
  --exclude='/sources' --exclude='/repo' --exclude='/.lfs-stages' --exclude='/tools' \
  --exclude='/dev/*' --exclude='/proc/*' --exclude='/sys/*' --exclude='/run/*' --exclude='/tmp/*' \
  "$LFS/" "$WORK/mnt/"

echo "[mkimage] installing GRUB EFI"
mkdir -p "$WORK/mnt/boot/efi/EFI/BOOT" "$WORK/mnt/boot/grub"
grub-mkimage -O arm64-efi -p '(hd0,gpt1)/EFI/BOOT' \
  -o "$WORK/mnt/boot/efi/EFI/BOOT/BOOTAA64.EFI" \
  fat part_gpt ext2 normal linux configfile efi_gop

# Render grub.cfg with the actual kernel version. GRUB EFI's prefix above
# points to the ESP (/EFI/BOOT/), so the config must live there — not on
# the ext4 root. We also keep a copy at /boot/grub/grub.cfg in the rootfs
# for in-system tools that expect it there (grub-update, etc.).
sed "s/LFS_KERNEL_VERSION/$KERNEL_VERSION/g" \
  "$REPO_ROOT/images/gnunix-base/grub.cfg" > "$WORK/mnt/boot/efi/EFI/BOOT/grub.cfg"
cp "$WORK/mnt/boot/efi/EFI/BOOT/grub.cfg" "$WORK/mnt/boot/grub/grub.cfg"

sync; sync
umount "$WORK/mnt/boot/efi"
umount "$WORK/mnt"
losetup -d "$LOOP"
trap - EXIT
rm -rf "$WORK"

echo "[mkimage] done. Disk image at: $IMG"
ls -lh "$IMG"

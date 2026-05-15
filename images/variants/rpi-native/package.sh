#!/bin/bash
# images/variants/rpi-native/package.sh — Raspberry Pi 4 / 5 image packager.
#
# Takes an aarch64 gnunix-{minimal,desktop} raw disk image, extracts the ext4 root,
# and re-bundles it under the Raspberry Pi boot scheme (ADR-010):
#
#   MBR partition table:
#     part1  FAT32  256 MiB  /boot   (contains RPi firmware + DTB + kernel)
#     part2  ext4   rest     /
#
# Inputs:
#   $1  source disk image (must be aarch64)
#   $2  output disk image
#
# Status: SCAFFOLDED. To actually boot on real Pi hardware this needs:
#   1. The gnunix-base kernel rebuilt with CONFIG_ARCH_BCM2835 +
#      CONFIG_BCM2835_MMC + CONFIG_DRM_VC4 + CONFIG_BCMGENET + …
#   2. Raspberry Pi firmware blobs pinned in manifest.json:platforms.rpi-native.firmware
#      and downloaded by tools/fetch-sources.sh.
#   3. A device-tree blob (bcm2711-rpi-4-b.dtb for Pi 4, bcm2712-rpi-5-b.dtb for Pi 5).
#   4. /boot/config.txt + /boot/cmdline.txt generated from this script.
#
# Until those land this packager rejects the build with a clear message so
# CI doesn't silently ship an unbootable image.

set -euo pipefail

SRC=${1:?usage: package.sh <src.img> <out.img>}
# OUT is consumed once the real packager is wired up (see TODO above).
# shellcheck disable=SC2034
OUT=${2:?usage: package.sh <src.img> <out.img>}
REPO_ROOT=${REPO_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}

[ -f "$SRC" ] || { echo "[rpi-native] source not found: $SRC" >&2; exit 1; }

FW_VER=$(jq -r '.platforms["rpi-native"].firmware.version // empty' \
  "$REPO_ROOT/tools/manifest.json")
KERNEL_HAS_BCM=$(jq -r '.platforms["rpi-native"].kernel_has_bcm_drivers // false' \
  "$REPO_ROOT/tools/manifest.json")

if [ -z "$FW_VER" ] || [ "$KERNEL_HAS_BCM" != "true" ]; then
  cat >&2 <<EOF
[rpi-native] cannot package yet — prerequisites not satisfied:

  manifest.json:platforms.rpi-native.firmware.version       = '${FW_VER:-MISSING}'
  manifest.json:platforms.rpi-native.kernel_has_bcm_drivers = '${KERNEL_HAS_BCM}'

Both must be set, AND the gnunix-base kernel config must include the BCM2835/
BCM2712 driver stack (see ADR-010 § Phasing). This is the Phase 6 follow-up
tracked in docs/TODO.md. Until then this packager is intentionally a no-op
that fails loudly rather than ship an unbootable image.
EOF
  exit 2
fi

# When prerequisites are in place, the real packaging shape is:
#
#   1. losetup the source image; mount the ext4 root.
#   2. dd a zero image of the right size for the output.
#   3. sgdisk -m off; create MBR; partition (FAT32 256M, ext4 rest).
#   4. mkfs.vfat /boot ; mkfs.ext4 /
#   5. rsync the rootfs across; preserve perms/xattrs.
#   6. Drop firmware blobs into /boot/: bootcode.bin, start4.elf, fixup4.dat,
#      bcm2711-rpi-4-b.dtb, kernel8.img, overlays/.
#   7. Write /boot/config.txt and /boot/cmdline.txt.
#   8. umount; losetup -d; zstd -19.
#
# Implementation is intentionally NOT inlined here — landing it requires (a)
# the kernel config work in gnunix-base and (b) a regression test in tests/, both
# of which are non-trivial. Scaffolding the entry point now keeps the CI
# matrix shape stable.

echo "[rpi-native] not implemented yet — see ADR-010 § Phasing" >&2
exit 2

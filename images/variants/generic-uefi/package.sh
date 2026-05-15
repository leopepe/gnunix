#!/bin/bash
# images/variants/generic-uefi/package.sh — generic UEFI image packager.
#
# This is the *current* shape of lfs-{core,nix,wayland}-disk-<ver>.img:
# GPT + ESP (FAT32) + ext4 root with GRUB EFI. Same artifact, renamed under
# the platform-aware scheme defined in ADR-010.
#
# Inputs:
#   $1  the source disk image (e.g., cache/artifacts/gnunix-minimal-disk-0.1.0.img)
#   $2  the output path        (e.g., cache/artifacts/gnunix-minimal-generic-uefi-aarch64-0.1.0.img)
#
# Today this is a copy-with-rename; the real packaging is already done by
# images/gnunix-base/packaging/mkimage.sh. Keeping this layer exists so that the
# CI matrix has a uniform entry point across platforms — when rpi-native or
# nuc-installer need real transformation work, the dispatch model is already
# in place.

set -euo pipefail

SRC=${1:?usage: package.sh <src.img> <out.img>}
OUT=${2:?usage: package.sh <src.img> <out.img>}

[ -f "$SRC" ] || { echo "[generic-uefi] source not found: $SRC" >&2; exit 1; }
mkdir -p "$(dirname "$OUT")"

echo "[generic-uefi] $SRC -> $OUT"
cp "$SRC" "$OUT"

if command -v zstd >/dev/null; then
  rm -f "$OUT.zst"
  # Level 10: ~4-5x faster than -19, image grows ~15%.
  zstd -10 -f -k "$OUT" -o "$OUT.zst"
  ls -lh "$OUT.zst"
fi

echo "[generic-uefi] DONE"

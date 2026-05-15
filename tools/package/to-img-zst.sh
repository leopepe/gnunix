#!/bin/bash
# tools/package/to-img-zst.sh — compress a raw .img into .img.zst.
#
# Invoked by tools/package.sh with these env vars set:
#   IMAGE     gnunix-base | gnunix-minimal | gnunix-desktop
#   ARCH      aarch64 | x86_64
#   VER       semver
#   PLATFORM  generic-uefi (default) | rpi4 | nuc-installer | ...
#   OUT       full destination path (cache/artifacts/<canonical>.img.zst)
#   REPO_ROOT repo root absolute path
#
# Per ADR-018: the source is one of:
#   1. cache/artifacts/<IMAGE>-<ARCH>-<VER>.img        (new naming, preferred)
#   2. cache/artifacts/<IMAGE>-disk-<VER>.img          (legacy naming, fallback)
#
# Compresses with `zstd -10` (same level used inline in the legacy
# image build scripts — empirically ~4–5× faster than -19 at ~15%
# larger output). Skips work if OUT exists and is fresher than SRC.

set -euo pipefail

ART=$REPO_ROOT/cache/artifacts
SRC_NEW="$ART/${IMAGE}-${ARCH}-${VER}.img"
SRC_LEGACY="$ART/${IMAGE}-disk-${VER}.img"

if [ -f "$SRC_NEW" ]; then
  SRC=$SRC_NEW
elif [ -f "$SRC_LEGACY" ]; then
  SRC=$SRC_LEGACY
  echo "[to-img-zst] using legacy source name: $(basename "$SRC")"
  echo "[to-img-zst] (image build scripts emit new naming starting in PR-6)"
else
  echo "[to-img-zst] no source image found." >&2
  echo "             tried: $SRC_NEW" >&2
  echo "             tried: $SRC_LEGACY" >&2
  echo "             run 'tools/build-all.sh $IMAGE' first." >&2
  exit 3
fi

if [ -f "$OUT" ] && [ "$OUT" -nt "$SRC" ]; then
  echo "[to-img-zst] $(basename "$OUT") is up to date; nothing to do."
  exit 0
fi

command -v zstd >/dev/null || { echo "[to-img-zst] zstd not installed." >&2; exit 1; }

echo "[to-img-zst] compressing $(du -h "$SRC" | cut -f1) → $(basename "$OUT")"
zstd -10 -f -k -o "$OUT" "$SRC"

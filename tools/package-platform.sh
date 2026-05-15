#!/bin/bash
# tools/package-platform.sh <image> <arch> <platform>
#
# One entry point that the CI matrix calls. Dispatches to the platform's
# packager under images/variants/<platform>/package.sh. Per ADR-010.
#
# Examples:
#   tools/package-platform.sh gnunix-nix     aarch64 generic-uefi
#   tools/package-platform.sh gnunix-desktop aarch64 rpi-native      # scaffolded; fails today
#   tools/package-platform.sh gnunix-nix     x86_64  nuc-installer   # scaffolded; fails today
#
# Exit codes:
#   0    artifact produced
#   1    bad usage / unknown image
#   2    platform packager exists but prerequisites aren't met (intentional)
#   3    platform doesn't support this arch
#   4    no source image — run tools/build-all.sh <image> first

set -euo pipefail

REPO_ROOT=${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
# Exported so per-platform packagers under images/variants/*/package.sh
# can rely on it without re-deriving from $0 (paths differ once they're
# invoked from this dispatcher).
export REPO_ROOT
MANIFEST="$REPO_ROOT/tools/manifest.json"

usage() {
  cat <<EOF >&2
usage: $0 <image> <arch> <platform>
  image:    gnunix-base | gnunix-nix | gnunix-desktop
  arch:     aarch64 | x86_64
  platform: generic-uefi | rpi-native | nuc-installer
EOF
  exit 1
}

[ $# -eq 3 ] || usage
IMAGE=$1; ARCH=$2; PLATFORM=$3

case "$IMAGE" in gnunix-base|gnunix-nix|gnunix-desktop) ;; *) usage ;; esac

# Arch must be declared in manifest.archs.
declared=$(jq -r --arg a "$ARCH" '.archs[$a] // empty' "$MANIFEST")
[ -n "$declared" ] || { echo "[package] unknown arch '$ARCH' (not in manifest.archs)" >&2; exit 1; }

# Arch must equal active_arch. Today there's exactly one base image on disk
# at any time (the one the last `tools/build-all.sh` produced), and it lives
# at the arch-less path cache/artifacts/<image>-disk-<ver>.img. Cross-arch
# packaging would silently mislabel an aarch64 image as x86_64 (or vice
# versa) — refuse instead. Once per-arch base naming lands (see
# docs/TODO.md § Cross-cutting), remove this gate.
ACTIVE_ARCH=$(jq -r '.active_arch // .target_arch' "$MANIFEST")
if [ "$ARCH" != "$ACTIVE_ARCH" ]; then
  echo "[package] arch '$ARCH' != manifest.active_arch '$ACTIVE_ARCH'" >&2
  echo "         (rebuild the base image with active_arch='$ARCH' first;" >&2
  echo "          today only one arch can be staged at a time)" >&2
  exit 5
fi

# Platform must declare support for this arch.
supports=$(jq -r --arg p "$PLATFORM" --arg a "$ARCH" \
  '(.platforms[$p].archs // []) | index($a) // empty' "$MANIFEST")
if [ -z "$supports" ]; then
  echo "[package] platform '$PLATFORM' does not support arch '$ARCH'" >&2
  echo "         (manifest.platforms[$PLATFORM].archs = $(jq -c --arg p "$PLATFORM" '.platforms[$p].archs // []' "$MANIFEST"))" >&2
  exit 3
fi

VER=$(jq -r .lfs_image_version "$MANIFEST")
SRC="$REPO_ROOT/cache/artifacts/$IMAGE-disk-$VER.img"
if [ ! -f "$SRC" ]; then
  echo "[package] no source image at $SRC — run 'tools/build-all.sh $IMAGE' first" >&2
  exit 4
fi

PACKAGER=$(jq -r --arg p "$PLATFORM" '.platforms[$p].packager // empty' "$MANIFEST")
[ -n "$PACKAGER" ] || { echo "[package] no packager declared for '$PLATFORM'" >&2; exit 1; }
[ -x "$REPO_ROOT/$PACKAGER" ] || { echo "[package] packager not executable: $PACKAGER" >&2; exit 1; }

OUT_DIR="$REPO_ROOT/cache/artifacts"
mkdir -p "$OUT_DIR"

# Platform-specific output naming: hybrid ISO for nuc-installer, raw .img elsewhere.
case "$PLATFORM" in
  nuc-installer) OUT="$OUT_DIR/$IMAGE-$PLATFORM-$ARCH-$VER.iso" ;;
  *)             OUT="$OUT_DIR/$IMAGE-$PLATFORM-$ARCH-$VER.img" ;;
esac

echo "[package] $IMAGE / $ARCH / $PLATFORM → $OUT"
"$REPO_ROOT/$PACKAGER" "$SRC" "$OUT"
echo "[package] DONE"

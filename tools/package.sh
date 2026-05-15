#!/bin/bash
# tools/package.sh — unified packaging entry point.
#
# Per ADR-018, GNUnix publishes exactly three artifact types:
#   .iso      — bootable removable media           (gnunix-installer only)
#   .img.zst  — raw GPT/UEFI/ext4 disk             (base / minimal / desktop)
#   .tart.zst — Tart-importable VM tarball         (base / minimal / desktop)
#
# This script is the single way to produce any of them. It replaces
# the inline zstd in each image's build.sh and the platform-specific
# tools/package-platform.sh. (package-platform.sh is removed in PR-6.)
#
# Usage:
#   tools/package.sh <image> --as=<form> [--platform=<p>] [--arch=<a>] [--ver=<v>] [--out=<path>]
#
#   <image>       gnunix-base | gnunix-minimal | gnunix-desktop | gnunix-installer
#   --as=<form>   img.zst | tart.zst | iso
#   --platform=   generic-uefi (default; omitted from filename) | rpi4 | nuc-installer | …
#   --arch=       aarch64 (default: from manifest.json:active_arch) | x86_64
#   --ver=        default: from manifest.json:lfs_image_version
#   --out=        override the output path (otherwise emits canonical name to cache/artifacts/)
#
# Source-file conventions:
#   - For img.zst / tart.zst: reads the raw disk image at
#       cache/artifacts/<image>-<arch>-<ver>.img  (new naming, ADR-018), or
#       cache/artifacts/<image>-disk-<ver>.img    (legacy naming, fallback)
#   - For iso (gnunix-installer): the installer's build.sh writes the
#     ISO directly; this helper passes through with canonical naming.
#
# Image × form validity (per ADR-018):
#                | img.zst | tart.zst | iso
#   gnunix-base  |   ✓     |    ✓     |  ✗
#   minimal      |   ✓     |    ✓     |  ✗
#   desktop      |   ✓     |    ✓     |  ✗
#   installer    |   ✗     |    ✗     |  ✓
#
# Exit codes:
#   0   artifact produced
#   1   bad usage
#   2   invalid image × form combination
#   3   missing source artifact (run tools/build-all.sh <image> first)
#   4   helper script failed (its own message has the detail)

set -euo pipefail

REPO_ROOT=${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
MANIFEST="$REPO_ROOT/tools/manifest.json"

usage() {
  sed -n '3,33p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-1}"
}

# --- argument parsing -------------------------------------------------

IMAGE=""
FORM=""
PLATFORM="generic-uefi"
ARCH=""
VER=""
OUT=""

case "${1:-}" in
  ""|-h|--help) usage 0 ;;
esac

IMAGE=$1; shift

while [ $# -gt 0 ]; do
  case "$1" in
    --as=*)        FORM=${1#--as=} ;;
    --platform=*)  PLATFORM=${1#--platform=} ;;
    --arch=*)      ARCH=${1#--arch=} ;;
    --ver=*)       VER=${1#--ver=} ;;
    --out=*)       OUT=${1#--out=} ;;
    -h|--help)     usage 0 ;;
    *)             echo "[package] unknown argument: $1" >&2; usage 1 ;;
  esac
  shift
done

# --- validation -------------------------------------------------------

case "$IMAGE" in
  gnunix-base|gnunix-minimal|gnunix-desktop|gnunix-installer) ;;
  *) echo "[package] unknown image: '$IMAGE'" >&2; usage 1 ;;
esac

case "$FORM" in
  img.zst|tart.zst|iso) ;;
  "") echo "[package] --as=<form> is required" >&2; usage 1 ;;
  *)  echo "[package] unknown form: '$FORM'" >&2; usage 1 ;;
esac

# Image × form validity matrix (ADR-018).
is_valid_combo() {
  case "$1/$2" in
    gnunix-installer/iso)        return 0 ;;
    gnunix-installer/*)          return 1 ;;
    gnunix-base/img.zst|gnunix-base/tart.zst)        return 0 ;;
    gnunix-minimal/img.zst|gnunix-minimal/tart.zst)  return 0 ;;
    gnunix-desktop/img.zst|gnunix-desktop/tart.zst)  return 0 ;;
    */iso)                       return 1 ;;
  esac
  return 1
}

if ! is_valid_combo "$IMAGE" "$FORM"; then
  echo "[package] '$IMAGE' cannot be packaged as '$FORM' (see ADR-018 § Published images)." >&2
  exit 2
fi

# Resolve arch / version defaults from manifest.
if [ -z "$ARCH" ]; then
  ARCH=$(jq -r '.active_arch // .target_arch' "$MANIFEST")
fi
if [ -z "$VER" ]; then
  VER=$(jq -r '.lfs_image_version' "$MANIFEST")
fi

# Build canonical output filename per the ADR-018 grammar:
#   gnunix-<image>-<arch>[-<platform>]-<ver>.<ext>
# generic-uefi is the default and is omitted from the filename.
short_image=${IMAGE#gnunix-}     # base | minimal | desktop | installer
plat_suffix=""
if [ "$PLATFORM" != "generic-uefi" ]; then plat_suffix="-$PLATFORM"; fi

if [ -z "$OUT" ]; then
  OUT="$REPO_ROOT/cache/artifacts/gnunix-${short_image}-${ARCH}${plat_suffix}-${VER}.${FORM}"
fi

mkdir -p "$(dirname "$OUT")"

# --- dispatch ---------------------------------------------------------

# Helpers can see these:
export REPO_ROOT MANIFEST IMAGE FORM PLATFORM ARCH VER OUT

case "$FORM" in
  img.zst) helper="$REPO_ROOT/tools/package/to-img-zst.sh" ;;
  tart.zst) helper="$REPO_ROOT/tools/package/to-tart-zst.sh" ;;
  iso)      helper="$REPO_ROOT/tools/package/to-iso.sh" ;;
esac

[ -x "$helper" ] || { echo "[package] helper not executable: $helper" >&2; exit 1; }

echo "[package] $IMAGE  →  $(basename "$OUT")"
if ! "$helper"; then
  rc=$?
  echo "[package] helper '$helper' failed (rc=$rc)" >&2
  exit 4
fi

ls -lh "$OUT"
echo "[package] done."

#!/bin/bash
# tools/fetch-image.sh — fetch a published GNUnix image from a GH Release.
#
# Per ADR-018's release-dependency flow, CI fetches gnunix-minimal
# (the release-dep anchor) instead of rebuilding gnunix-base+minimal
# from scratch on every run. Used both by CI and by contributors who
# want to skip the 6–10 h base build.
#
# Usage:
#   tools/fetch-image.sh <image> [--ver=<v>] [--repo=<owner/name>]
#                                [--release-tag=<tag>] [--form=img.zst]
#                                [--no-import] [--out-dir=<dir>]
#
#   <image>        gnunix-base | gnunix-minimal | gnunix-desktop | gnunix-installer
#   --ver=         default: from tools/manifest.json:lfs_image_version
#   --repo=        default: this repo (from `gh repo view`).
#                  Forks fall back to the upstream gnunix repo if their
#                  own release isn't found.
#   --release-tag= default: `base-images-<ver>` for base/minimal,
#                            `v<ver>` for desktop/installer.
#   --form=        img.zst (default) | tart.zst | iso
#   --no-import    download + decompress only; skip the VM-import step.
#   --out-dir=     where to write the decompressed image
#                  (default: cache/artifacts/).
#
# Behaviour:
#   1. `gh release download` from <repo>:<release-tag>. If the asset is
#      missing AND <repo> looks like a fork, retries against the
#      upstream repo from `tools/manifest.json:upstream_repo`.
#   2. Decompresses .img.zst → .img (or extracts .tart.zst, or
#      keeps .iso as-is).
#   3. Verifies SHA256 against the SHA256SUMS asset in the release.
#   4. Unless --no-import, imports into the active VM driver
#      (Tart on macOS via tart-helpers, qemu on Linux — qemu path
#      stubbed; see scripts/vm-helpers.sh).
#
# Exit codes:
#   0   image ready
#   1   bad usage / missing prereqs
#   2   asset not found in repo or upstream
#   3   checksum mismatch
#   4   import step failed

set -euo pipefail

REPO_ROOT=${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
MANIFEST="$REPO_ROOT/tools/manifest.json"
ART="$REPO_ROOT/cache/artifacts"

usage() { sed -n '3,33p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-1}"; }

case "${1:-}" in ""|-h|--help) usage 0 ;; esac

IMAGE=$1; shift
VER=""
REPO=""
RELEASE_TAG=""
FORM="img.zst"
NO_IMPORT=""
OUT_DIR=""

while [ $# -gt 0 ]; do
  case "$1" in
    --ver=*)          VER=${1#--ver=} ;;
    --repo=*)         REPO=${1#--repo=} ;;
    --release-tag=*)  RELEASE_TAG=${1#--release-tag=} ;;
    --form=*)         FORM=${1#--form=} ;;
    --no-import)      NO_IMPORT=1 ;;
    --out-dir=*)      OUT_DIR=${1#--out-dir=} ;;
    -h|--help)        usage 0 ;;
    *)                echo "[fetch-image] unknown arg: $1" >&2; usage 1 ;;
  esac
  shift
done

case "$IMAGE" in
  gnunix-base|gnunix-minimal|gnunix-desktop|gnunix-installer) ;;
  *) echo "[fetch-image] unknown image: '$IMAGE'" >&2; usage 1 ;;
esac

command -v gh >/dev/null || { echo "[fetch-image] gh CLI not installed." >&2; exit 1; }
command -v jq >/dev/null || { echo "[fetch-image] jq not installed." >&2; exit 1; }

[ -z "$VER" ]      && VER=$(jq -r '.lfs_image_version' "$MANIFEST")
[ -z "$REPO" ]     && REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo "leopepe/gnunix")
[ -z "$OUT_DIR" ]  && OUT_DIR="$ART"
mkdir -p "$OUT_DIR"

ARCH=$(jq -r '.active_arch // .target_arch' "$MANIFEST")
UPSTREAM_REPO=$(jq -r '.upstream_repo // "leopepe/gnunix"' "$MANIFEST")

if [ -z "$RELEASE_TAG" ]; then
  case "$IMAGE" in
    gnunix-base|gnunix-minimal) RELEASE_TAG="base-images-${VER}" ;;
    *)                          RELEASE_TAG="v${VER}" ;;
  esac
fi

short_image=${IMAGE#gnunix-}
ASSET="gnunix-${short_image}-${ARCH}-${VER}.${FORM}"

# Try <repo>:<release-tag>; if missing AND <repo> != upstream, retry upstream.
try_download() {
  local repo=$1
  echo "[fetch-image] trying $repo:$RELEASE_TAG  →  $ASSET"
  if gh release download "$RELEASE_TAG" --repo "$repo" --pattern "$ASSET" --dir "$OUT_DIR" --clobber 2>/dev/null; then
    # Also fetch SHA256SUMS if present (for verification).
    gh release download "$RELEASE_TAG" --repo "$repo" \
       --pattern "SHA256SUMS-${IMAGE}-${VER}" --dir "$OUT_DIR" --clobber 2>/dev/null || true
    echo "$repo"
    return 0
  fi
  return 1
}

if SOURCE_REPO=$(try_download "$REPO"); then
  :
elif [ "$REPO" != "$UPSTREAM_REPO" ] && SOURCE_REPO=$(try_download "$UPSTREAM_REPO"); then
  echo "[fetch-image] (fell back to upstream $UPSTREAM_REPO)"
else
  echo "[fetch-image] asset '$ASSET' not found in $REPO:$RELEASE_TAG nor $UPSTREAM_REPO:$RELEASE_TAG" >&2
  exit 2
fi

ASSET_PATH="$OUT_DIR/$ASSET"

# Verify against SHA256SUMS if it was uploaded alongside.
SUMS_PATH="$OUT_DIR/SHA256SUMS-${IMAGE}-${VER}"
if [ -f "$SUMS_PATH" ]; then
  expected=$(awk -v f="$ASSET" '$2==f {print $1; exit}' "$SUMS_PATH")
  if [ -n "$expected" ]; then
    if command -v sha256sum >/dev/null; then
      actual=$(sha256sum "$ASSET_PATH" | awk '{print $1}')
    else
      actual=$(shasum -a 256 "$ASSET_PATH" | awk '{print $1}')
    fi
    if [ "$actual" != "$expected" ]; then
      echo "[fetch-image] CHECKSUM MISMATCH for $ASSET" >&2
      echo "              expected: $expected" >&2
      echo "              actual:   $actual" >&2
      exit 3
    fi
    echo "[fetch-image] checksum OK"
  fi
fi

# Decompress if zstd-wrapped.
case "$FORM" in
  img.zst)
    DEC_PATH="${ASSET_PATH%.zst}"
    if [ ! -f "$DEC_PATH" ] || [ "$ASSET_PATH" -nt "$DEC_PATH" ]; then
      echo "[fetch-image] decompressing → $(basename "$DEC_PATH")"
      command -v zstd >/dev/null || { echo "[fetch-image] zstd not installed." >&2; exit 1; }
      zstd -d -f -o "$DEC_PATH" "$ASSET_PATH"
    fi
    FINAL="$DEC_PATH"
    ;;
  tart.zst)
    FINAL="$ASSET_PATH"   # extraction handled in import step below
    ;;
  iso)
    FINAL="$ASSET_PATH"
    ;;
esac

echo "[fetch-image] ready: $FINAL"

# Optional VM import via the driver abstraction.
if [ -n "$NO_IMPORT" ]; then
  exit 0
fi

# shellcheck source=/dev/null
. "$REPO_ROOT/scripts/vm-helpers.sh"

VM_NAME="${IMAGE}-${VER}"
case "$VM_DRIVER:$FORM" in
  tart:img.zst)
    if vm_exists "$VM_NAME"; then
      echo "[fetch-image] Tart VM '$VM_NAME' already exists; not re-importing."
    else
      echo "[fetch-image] importing → Tart VM '$VM_NAME'"
      if tart create --help 2>&1 | grep -q -- --from-bootable-image; then
        tart create "$VM_NAME" --linux --from-bootable-image "$FINAL"
      else
        tart create "$VM_NAME" --linux
        cp -f "$FINAL" "$HOME/.tart/vms/$VM_NAME/disk.img"
      fi
    fi
    ;;
  tart:tart.zst)
    echo "[fetch-image] extracting Tart tarball → ~/.tart/vms/$VM_NAME"
    if vm_exists "$VM_NAME"; then
      echo "[fetch-image] VM '$VM_NAME' already exists; refusing to overwrite. Delete it first." >&2
      exit 4
    fi
    mkdir -p "$HOME/.tart/vms"
    tar -C "$HOME/.tart/vms" -xf "$FINAL"
    ;;
  qemu:*)
    echo "[fetch-image] qemu import — TODO (PR-3b: wire qemu driver in scripts/vm-helpers.sh)"
    echo "[fetch-image] image available at $FINAL; manual import:"
    echo "              qemu-system-aarch64 -drive if=virtio,file=$FINAL,format=raw …"
    ;;
  *)
    echo "[fetch-image] no import path for driver=$VM_DRIVER form=$FORM" >&2
    exit 4
    ;;
esac

echo "[fetch-image] done."

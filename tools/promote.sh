#!/bin/bash
# tools/promote.sh [<tag>]
#
# Package the current gnunix-base-<version> Tart VM as a .tvm.zst artifact and
# (if run with $GITHUB_TOKEN + gh CLI authenticated) attach it to a GitHub
# Release for the given tag. Called from .github/workflows/build.yml's
# release job (ADR-008).
#
# Without a tag, just produces the local artifact under cache/artifacts/.

set -euo pipefail

REPO_ROOT=${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
TAG=${1:-}
VERSION=$(jq -r .lfs_image_version "$REPO_ROOT/tools/manifest.json")
VM="gnunix-base-$VERSION"
OUT_DIR="$REPO_ROOT/cache/artifacts"
mkdir -p "$OUT_DIR"

command -v tart >/dev/null || { echo "need tart" >&2; exit 1; }
command -v zstd >/dev/null || { echo "need zstd (brew install zstd)" >&2; exit 1; }

tart list 2>/dev/null | awk 'NR>1 {print $2}' | grep -qx "$VM" \
  || { echo "$VM does not exist — run tools/build-all.sh gnunix-base first" >&2; exit 1; }

echo "[promote] exporting $VM"
tart export "$VM" --output "$OUT_DIR/$VM.tvm"

echo "[promote] compressing"
zstd -19 --rm "$OUT_DIR/$VM.tvm"   # produces $VM.tvm.zst

ls -lh "$OUT_DIR/$VM.tvm.zst"

if [ -n "$TAG" ]; then
  command -v gh >/dev/null || { echo "need gh CLI" >&2; exit 1; }
  echo "[promote] creating GitHub Release $TAG"
  gh release create "$TAG" \
    --title "gnunix-base $TAG" \
    --notes "Phase 2 image. Pinned versions in attached manifest.json. See docs/runbooks/build.md for what's in this image and how to reproduce." \
    "$OUT_DIR/$VM.tvm.zst" \
    "$REPO_ROOT/tools/manifest.json"
else
  echo "[promote] no tag passed — artifact at $OUT_DIR/$VM.tvm.zst (not uploaded)"
fi

#!/bin/bash
# tools/release-image.sh — publish a GNUnix image to a GitHub Release.
#
# Per ADR-018's release-dependency flow, gnunix-base and gnunix-minimal
# rebuilds happen locally on Apple Silicon (a 6–10 h job that doesn't
# fit hosted-runner CI per ADR-016). This script ships those images
# to a GitHub Release where downstream CI can fetch them via
# tools/fetch-image.sh.
#
# Usage:
#   tools/release-image.sh <image> [--ver=<v>] [--repo=<owner/name>]
#                                 [--release-tag=<tag>] [--draft]
#                                 [--forms=img.zst,tart.zst]
#                                 [--notes-file=<path>]
#
#   <image>        gnunix-base | gnunix-minimal | gnunix-desktop | gnunix-installer
#   --ver=         default: from tools/manifest.json:lfs_image_version
#   --repo=        default: $(gh repo view --json nameWithOwner -q .nameWithOwner)
#   --release-tag= default: `base-images-<ver>` for base/minimal,
#                            `v<ver>` for desktop/installer.
#                  (Two release tracks per ADR-018: base-images is the
#                   intermediate fetched by CI; v<ver> is the user-facing
#                   release rolled by release.yml from CI outputs.)
#   --draft        create the release as a draft (default for v<ver>,
#                  flipped off for base-images by default)
#   --forms=       comma-separated subset of {img.zst, tart.zst, iso}
#                  to upload (default: every form valid for the image
#                  per ADR-018's matrix that exists in cache/artifacts/).
#   --notes-file=  release notes markdown file (auto-generated otherwise)
#
# Behaviour:
#   1. Ensures each requested artifact form exists; if missing, runs
#      tools/package.sh to produce it. Won't run a from-scratch build —
#      the underlying raw .img must exist already.
#   2. Creates or reuses the GH Release at <release-tag>. Uploads each
#      artifact with `gh release upload --clobber` so re-runs are
#      idempotent.
#   3. Computes SHA256SUMS for the uploaded artifacts and uploads that too.
#
# Exit codes:
#   0  success
#   1  bad usage / missing prereqs
#   3  source raw .img not found (run tools/build-all.sh first)
#   4  gh CLI command failed

set -euo pipefail

REPO_ROOT=${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
MANIFEST="$REPO_ROOT/tools/manifest.json"
ART="$REPO_ROOT/cache/artifacts"

usage() { sed -n '3,32p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-1}"; }

case "${1:-}" in ""|-h|--help) usage 0 ;; esac

IMAGE=$1; shift
VER=""
REPO=""
RELEASE_TAG=""
DRAFT=""
FORMS=""
NOTES_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --ver=*)         VER=${1#--ver=} ;;
    --repo=*)        REPO=${1#--repo=} ;;
    --release-tag=*) RELEASE_TAG=${1#--release-tag=} ;;
    --draft)         DRAFT="--draft" ;;
    --forms=*)       FORMS=${1#--forms=} ;;
    --notes-file=*)  NOTES_FILE=${1#--notes-file=} ;;
    -h|--help)       usage 0 ;;
    *)               echo "[release-image] unknown arg: $1" >&2; usage 1 ;;
  esac
  shift
done

case "$IMAGE" in
  gnunix-base|gnunix-minimal|gnunix-desktop|gnunix-installer) ;;
  *) echo "[release-image] unknown image: '$IMAGE'" >&2; usage 1 ;;
esac

command -v gh   >/dev/null || { echo "[release-image] gh CLI not installed." >&2; exit 1; }
command -v jq   >/dev/null || { echo "[release-image] jq not installed." >&2; exit 1; }
command -v sha256sum >/dev/null || command -v shasum >/dev/null \
  || { echo "[release-image] need sha256sum or shasum." >&2; exit 1; }

[ -z "$VER" ]  && VER=$(jq -r '.lfs_image_version' "$MANIFEST")
[ -z "$REPO" ] && REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
ARCH=$(jq -r '.active_arch // .target_arch' "$MANIFEST")

# Resolve default release tag per ADR-018.
if [ -z "$RELEASE_TAG" ]; then
  case "$IMAGE" in
    gnunix-base|gnunix-minimal) RELEASE_TAG="base-images-${VER}" ;;
    *)                          RELEASE_TAG="v${VER}" ;;
  esac
fi

# Resolve default form list from the validity matrix.
if [ -z "$FORMS" ]; then
  case "$IMAGE" in
    gnunix-installer) FORMS="iso" ;;
    *)                FORMS="img.zst,tart.zst" ;;
  esac
fi

# Ensure each requested artifact exists (run tools/package.sh if missing).
short_image=${IMAGE#gnunix-}
declare -a ASSETS=()
IFS=',' read -ra FORM_LIST <<< "$FORMS"
for form in "${FORM_LIST[@]}"; do
  asset="$ART/gnunix-${short_image}-${ARCH}-${VER}.${form}"
  if [ ! -f "$asset" ]; then
    echo "[release-image] $form missing — invoking tools/package.sh"
    "$REPO_ROOT/tools/package.sh" "$IMAGE" "--as=$form" "--ver=$VER" "--arch=$ARCH" || {
      rc=$?; echo "[release-image] tools/package.sh failed (rc=$rc)" >&2; exit "$rc"
    }
  fi
  ASSETS+=("$asset")
done

# Build SHA256SUMS for the uploaded set (locally; uploaded as an asset too).
SUMS=$(mktemp)
trap 'rm -f "$SUMS"' EXIT
( cd "$ART" && \
  if command -v sha256sum >/dev/null; then
    sha256sum -- "${ASSETS[@]##*/}"
  else
    shasum -a 256 -- "${ASSETS[@]##*/}"
  fi
) | sort > "$SUMS"
ASSETS+=("$SUMS")
# Rename the temp so the uploaded asset is called SHA256SUMS.
SUMS_NAMED="$ART/SHA256SUMS-${IMAGE}-${VER}"
cp "$SUMS" "$SUMS_NAMED"
# Last asset in the array is the temp path; replace with the renamed file.
ASSETS[${#ASSETS[@]}-1]="$SUMS_NAMED"

# Auto-generate notes if none provided.
if [ -z "$NOTES_FILE" ]; then
  NOTES_FILE=$(mktemp)
  trap 'rm -f "$SUMS" "$NOTES_FILE"' EXIT
  {
    echo "## $IMAGE $VER ($ARCH)"
    echo
    echo "Auto-published by \`tools/release-image.sh\` per ADR-018."
    echo
    echo "**Manifest:**  \`tools/manifest.json:lfs_image_version=$VER\`"
    echo "**Built on:**  \`$(uname -srm) ($(date -u +%Y-%m-%dT%H:%M:%SZ))\`"
    echo
    echo "### Assets"
    for a in "${ASSETS[@]}"; do
      [ "$a" = "$SUMS_NAMED" ] && continue
      printf -- '- `%s` (%s)\n' "$(basename "$a")" "$(du -h "$a" | cut -f1)"
    done
    echo
    echo "### Verify"
    echo
    echo '```'
    echo "$(cat "$SUMS")"
    echo '```'
  } > "$NOTES_FILE"
fi

# Create or reuse the release.
if gh release view "$RELEASE_TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "[release-image] release $RELEASE_TAG exists; uploading with --clobber"
  if ! gh release upload "$RELEASE_TAG" --repo "$REPO" --clobber "${ASSETS[@]}"; then
    echo "[release-image] gh release upload failed" >&2; exit 4
  fi
else
  echo "[release-image] creating release $RELEASE_TAG"
  # base-images releases are NOT drafts by default (CI needs them visible);
  # v<ver> releases ARE drafts (per ADR-008, human reviews before publishing).
  case "$RELEASE_TAG" in
    base-images-*) ;;
    *)             [ -z "$DRAFT" ] && DRAFT="--draft" ;;
  esac
  # shellcheck disable=SC2086
  if ! gh release create "$RELEASE_TAG" --repo "$REPO" $DRAFT \
       --title "$IMAGE $VER ($ARCH)" \
       --notes-file "$NOTES_FILE" \
       "${ASSETS[@]}"; then
    echo "[release-image] gh release create failed" >&2; exit 4
  fi
fi

echo "[release-image] released: https://github.com/$REPO/releases/tag/$RELEASE_TAG"

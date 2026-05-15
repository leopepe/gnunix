#!/bin/bash
# Download and verify all source tarballs declared in tools/manifest.json.
#
# Sources land in $LFS/sources/ (host: $REPO_ROOT/cache/sources/ if $LFS unset).
# SHA256 fields in manifest.json:
#   - empty  → compute, print, and accept (one-time bootstrap; commit the value)
#   - set    → enforce; mismatch = abort
#
# Renovate (ADR-008) updates urls + sha256 together via PRs.
#
# Reliability:
#   - mirror fallback: each URL may have alternates (ftpmirror.gnu.org,
#     mirrors.kernel.org, ...); tried in order until one verifies.
#   - stall detection: kills downloads that drop below 1KB/s for 30s.
#   - retry-all-errors with 5s backoff up to 5 attempts per mirror.

set -euo pipefail

REPO_ROOT=${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
MANIFEST="$REPO_ROOT/tools/manifest.json"
DEST=${LFS:-$REPO_ROOT/cache}/sources
mkdir -p "$DEST"

command -v jq >/dev/null   || { echo "need jq" >&2; exit 1; }
command -v curl >/dev/null || { echo "need curl" >&2; exit 1; }

FAILED_URLS=()

# Print the primary URL followed by any fallback mirrors that serve identical bytes.
# GNU mirrors are documented at https://www.gnu.org/prep/ftp.html;
# kernel.org's mirror at https://mirrors.kernel.org/ carries /gnu/ in full.
mirrors_for() {
  local url=$1
  printf '%s\n' "$url"
  case "$url" in
    https://ftp.gnu.org/gnu/*)
      local tail=${url#https://ftp.gnu.org/gnu/}
      printf 'https://ftpmirror.gnu.org/%s\n' "$tail"
      printf 'https://mirrors.kernel.org/gnu/%s\n' "$tail"
      ;;
    https://mirrors.kernel.org/gnu/*)
      local tail=${url#https://mirrors.kernel.org/gnu/}
      printf 'https://ftpmirror.gnu.org/%s\n' "$tail"
      printf 'https://ftp.gnu.org/gnu/%s\n' "$tail"
      ;;
    https://cdn.kernel.org/*)
      local tail=${url#https://cdn.kernel.org/}
      printf 'https://mirrors.edge.kernel.org/%s\n' "$tail"
      ;;
    https://www.kernel.org/pub/*)
      local tail=${url#https://www.kernel.org/pub/}
      printf 'https://cdn.kernel.org/pub/%s\n' "$tail"
      printf 'https://mirrors.edge.kernel.org/pub/%s\n' "$tail"
      ;;
  esac
}

curl_get() {
  # Per-mirror budget: ~2 connect attempts (one retry), 15s connect, kill
  # any stream below 1KB/s for 30s. Total worst case per dead mirror is
  # roughly 60s before we fall through to the next mirror in mirrors_for().
  local url=$1 out=$2
  curl -fL \
    --retry 1 --retry-all-errors --retry-delay 3 \
    --connect-timeout 15 \
    --speed-time 30 --speed-limit 1024 \
    --max-time 1800 \
    -o "$out" "$url"
}

verify_sha() {
  local target=$1 expected=$2
  local got; got=$(sha256sum "$target" | awk '{print $1}')
  if [ -z "$expected" ]; then
    printf '%s\n' "$got"  # bootstrap mode: caller prints
    return 0
  fi
  [ "$got" = "$expected" ]
}

fetch_one() {
  local primary=$1 expected_sha=$2
  local fname; fname=$(basename "$primary")
  local target="$DEST/$fname"

  if [ -f "$target" ]; then
    if [ -n "$expected_sha" ]; then
      if verify_sha "$target" "$expected_sha"; then
        echo "[fetch] cached: $fname"
        return 0
      fi
      echo "[fetch] cached file failed sha256 check, refetching: $fname"
      rm -f "$target"
    else
      echo "[fetch] cached: $fname (no sha256 to verify)"
      return 0
    fi
  fi

  local attempted=0
  while IFS= read -r url; do
    attempted=$((attempted + 1))
    echo "[fetch] try #$attempted: $url"
    if curl_get "$url" "$target.partial"; then
      mv "$target.partial" "$target"
      if [ -z "$expected_sha" ]; then
        local got; got=$(sha256sum "$target" | awk '{print $1}')
        echo "[fetch] sha256 (record this in manifest.json): $fname  $got"
        return 0
      fi
      if verify_sha "$target" "$expected_sha"; then
        echo "[fetch] verified: $fname"
        return 0
      fi
      echo "[fetch] checksum mismatch on $url; trying next mirror"
      rm -f "$target"
    else
      echo "[fetch] mirror failed: $url"
      rm -f "$target.partial"
    fi
  done < <(mirrors_for "$primary")

  echo "[fetch] FAILED after $attempted mirror(s): $fname"
  FAILED_URLS+=("$primary")
  return 0
}

# Walk every entry that has a url and (optionally) sha256.
# Note: the host_distro entry intentionally omitted — it's a Tart image, not a tarball.
# Process substitution (not a pipe) so FAILED_URLS+= survives the loop.
while IFS=$'\t' read -r url sha; do
  [ -z "$url" ] && continue
  fetch_one "$url" "$sha"
done < <(jq -r '
  [
    (.toolchain         | to_entries[] | .value | select(type=="object") | select(.url) | {url, sha256: (.sha256 // "")}),
    (.toolchain.gcc_prereqs | to_entries[] | .value | {url, sha256: (.sha256 // "")}),
    (.kernel            | {url, sha256: (.sha256 // "")}),
    (.base_packages     | to_entries[] | .value | {url, sha256: (.sha256 // "")}),
    (.init_and_session  | to_entries[] | .value | {url, sha256: (.sha256 // "")}),
    (.bootloader        | to_entries[] | .value | {url, sha256: (.sha256 // "")}),
    # Phase 3: the Nix binary tarball used by images/gnunix-minimal/install-gnunix-minimal.sh.
    # Same sha256-pinned, mirror-fallback download path as base packages.
    {url: .nix.binary_url, sha256: .nix.binary_sha256}
  ]
  | .[] | "\(.url)\t\(.sha256)"
' "$MANIFEST")

if [ ${#FAILED_URLS[@]} -gt 0 ]; then
  echo "[fetch] ${#FAILED_URLS[@]} URL(s) exhausted all mirrors:"
  for u in "${FAILED_URLS[@]}"; do echo "  - $u"; done
  exit 1
fi
echo "[fetch] all sources present in $DEST"

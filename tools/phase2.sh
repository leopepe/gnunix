#!/bin/bash
# tools/phase2.sh
# End-to-end Phase 2 orchestrator: bootstrap-builder → build-all gnunix-base → smoke test.
#
# Each stage is gated by a [y/N] prompt so an unattended failure can't silently
# burn 12h of CPU. Set AUTO=1 to skip prompts (for CI or repeat runs).
#
# Re-runnable: stages 1 and 2 are themselves idempotent.

set -euo pipefail

REPO_ROOT=${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
VERSION=$(jq -r .lfs_image_version "$REPO_ROOT/tools/manifest.json")

confirm() {
  if [ "${AUTO:-0}" = "1" ]; then return 0; fi
  printf '%s [y/N]: ' "$1"
  read -r ans
  case "$ans" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

cat <<EOF
============================================
 Phase 2 pipeline → gnunix-base $VERSION
============================================
 Stages:
   0. Pre-fetch sources on host    (~5-15 min, network bound)
   1. Bootstrap gnunix-builder:base   (~10-25 min, network bound)
   2. Build gnunix-base                (~6-12 h,   compute bound)
   3. Smoke test gnunix-base-$VERSION  (~2 min)

 Pre-fetching on the host avoids the in-VM network bottleneck (the VM's
 NAT'd virtio-net link to ftp.gnu.org is the usual source of timeouts).
 Tarballs land in cache/sources/ and build-all.sh syncs them into the
 builder before the in-VM 'fetch' stage, which becomes a sha256 no-op.

 Pass AUTO=1 to skip the prompts between stages.
EOF
echo

if confirm "Run stage 0 (pre-fetch sources on host)?"; then
  "$REPO_ROOT/tools/fetch-sources.sh"
else
  echo "[phase2] stage 0 skipped — VM will fetch everything itself"
fi

if confirm "Run stage 1 (bootstrap-builder)?"; then
  "$REPO_ROOT/tools/bootstrap-builder.sh"
else
  echo "[phase2] stage 1 skipped"
fi

if confirm "Run stage 2 (build-all gnunix-base — MULTIPLE HOURS)?"; then
  "$REPO_ROOT/tools/build-all.sh" gnunix-base
else
  echo "[phase2] stage 2 skipped"; exit 0
fi

if confirm "Run stage 3 (boot-smoke on gnunix-base-$VERSION)?"; then
  "$REPO_ROOT/tests/boot-smoke.sh" "gnunix-base-$VERSION"
else
  echo "[phase2] stage 3 skipped"; exit 0
fi

echo "[phase2] done — Phase 2 milestone reached."

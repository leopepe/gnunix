#!/bin/bash
# tools/package/to-iso.sh — emit (or pass through) a bootable .iso.
#
# Invoked by tools/package.sh. Per ADR-018 the only image that
# emits .iso is gnunix-installer.
#
# Today: pass-through. images/installer/build.sh already produces an
# ISO; this helper just relocates / renames it to the canonical
# ADR-018 name at $OUT.
#
# Later (PR-4 — ADR-017 live-ISO implementation): the live ISO build
# moves OUT of images/installer/build.sh and INTO this helper,
# orchestrating images/installer/iso/mkiso.sh inside the build VM.
# When that lands, the entry point stays `tools/package.sh
# gnunix-installer --as=iso`; only the implementation behind this
# helper changes.
#
# Env (set by tools/package.sh):
#   IMAGE, ARCH, VER, OUT, REPO_ROOT

set -euo pipefail

if [ "$IMAGE" != gnunix-installer ]; then
  echo "[to-iso] only gnunix-installer emits .iso per ADR-018" >&2
  exit 1
fi

ART="$REPO_ROOT/cache/artifacts"
# Look for an existing ISO with either the new canonical name or the
# legacy build-script output (raw .img produced by the scaffolded
# installer build today — see ADR-019 for the migration plan).
SRC_NEW="$ART/gnunix-installer-${ARCH}-${VER}.iso"
SRC_LEGACY_IMG="$ART/gnunix-installer-${ARCH}-${VER}.img"   # pre-ADR-017 raw form

if [ -f "$SRC_NEW" ]; then
  # Already canonical — only act if OUT is somewhere else.
  if [ "$SRC_NEW" = "$OUT" ]; then
    echo "[to-iso] $(basename "$OUT") already at canonical path; nothing to do."
    exit 0
  fi
  echo "[to-iso] copying $(basename "$SRC_NEW") → $(basename "$OUT")"
  cp -f "$SRC_NEW" "$OUT"
  exit 0
fi

if [ -f "$SRC_LEGACY_IMG" ]; then
  echo "[to-iso] WARNING: only the pre-ADR-017 raw .img form is available." >&2
  echo "          The proper live ISO comes from PR-4 (images/installer/iso/mkiso.sh)." >&2
  echo "          For now this helper does NOT silently emit a misleading .iso" >&2
  echo "          from the raw .img — re-run after PR-4 lands." >&2
  exit 3
fi

echo "[to-iso] no installer artifact found." >&2
echo "          tried: $SRC_NEW" >&2
echo "          run 'tools/build-all.sh gnunix-installer' first." >&2
exit 3

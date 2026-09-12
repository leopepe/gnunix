#!/bin/bash
# Master orchestrator for the gnunix-base image build.
#
# This runs *inside* the gnunix-builder VM. It drives the four stages of the LFS
# build and produces a bootable rootfs at $LFS, then hands off to the packager.
#
# Stages are idempotent and resumable. Each stage writes a marker file in
# $LFS/.lfs-stages/ on completion; re-running skips completed stages unless
# --rebuild=<stage> is passed.
#
# Per ADR-021: --ci runs the LFS build on an arm64 GitHub-hosted runner,
# using the runner's own toolchain as the LFS host system. $LFS is the
# LFS tree being *built*; it is NOT a pre-provisioned distro rootfs.
# Stage 1 cross-compiles into $LFS/tools using the host gcc.
#
# Usage:
#   $0                     # Tart path (local Mac): bootstrap + build
#   $0 --ci                # CI path: all stages on /mnt/lfs, then package
#   $0 --ci --only=<stage> # CI path: run exactly one stage (see below)
#   $0 --rebuild=<stage>   # Rebuild a specific stage
#
# --only=<stage> exists so the CI job split (ADR-023 § Four-stage build
# split) can run one stage per job while sharing this orchestrator's
# environment setup and marker handling. Valid stages:
#   cross | temp-tools | chroot | finalize | package
# `fetch` always runs first (marker-guarded, cheap when sources are
# already staged); `--only=package` skips it.
#
# CI mode expects:
#   /mnt/lfs            — empty dir, or a partially-built LFS tree
#   /mnt/lfs/sources    — pre-fetched tarballs (optional; else fetched)
#
# Output:
#   /mnt/gnunix-base-disk.img  — raw GPT disk image (EFI + ext4),
#                                written by packaging/mkimage.sh
#   cache/artifacts/gnunix-base-<arch>-<ver>.img.zst  — compressed artifact

set -euo pipefail

CI_MODE=0
ONLY_STAGE=""
for arg in "$@"; do
  case "$arg" in
    --ci)     CI_MODE=1 ;;
    --only=*) ONLY_STAGE=${arg#--only=} ;;
  esac
done

case "$ONLY_STAGE" in
  ""|cross|temp-tools|chroot|finalize|package) ;;
  *) echo "[build] unknown --only stage: '$ONLY_STAGE'" >&2
     echo "        valid: cross temp-tools chroot finalize package" >&2
     exit 1 ;;
esac

if [ "$CI_MODE" = "1" ]; then
     # === CI mode: build the LFS tree at /mnt/lfs ===
     #
     # Per ADR-021: the LFS build runs on ubuntu-22.04-arm. No Tart, no
     # self-hosted runner. The runner's own Ubuntu toolchain is the LFS
     # host system; stages 1-2 cross-compile into $LFS/tools, stages 3-4
     # chroot into the tree those stages produced.

    echo "[build-ci] CI mode — running LFS stages on /mnt/lfs"

     # Stages 3 and 4 mount and chroot, so --ci is root-only. Requiring root
     # up front lets run_stage exec the stage scripts directly: the exports
     # below then reach them by plain inheritance, with no dependence on
     # `sudo -E` being permitted by the runner's sudoers policy.
    [ "$(id -u)" = 0 ] || {
      echo "[build-ci] --ci must run as root (try: sudo $0 $*)" >&2
      exit 1
    }

    LFS=/mnt/lfs
    REPO_ROOT=${REPO_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}
    export LFS
    export LFS_TGT=$(uname -m)-lfs-linux-gnu
    export LC_ALL=POSIX
    export PATH=$LFS/tools/bin:/usr/bin:/usr/sbin:/bin:/sbin

    STAGES_DIR=$LFS/.lfs-stages
    SOURCES_DIR=$LFS/sources
    LOGS_DIR=$LFS/logs

    mkdir -p "$LFS" "$STAGES_DIR" "$SOURCES_DIR" "$LOGS_DIR"

     # Pre-fetch sources if available (from CI cache or host).
    if [ -d "$REPO_ROOT/cache/sources" ] && \
       [ -n "$(ls -A "$REPO_ROOT/cache/sources" 2>/dev/null)" ]; then
      echo "[build-ci] staging $(ls "$REPO_ROOT/cache/sources" | wc -l | tr -d ' ') pre-fetched tarballs"
      mkdir -p "$SOURCES_DIR"
      rsync -a --ignore-existing "$REPO_ROOT/cache/sources/" "$SOURCES_DIR/"
    fi

    run_stage() {
      local name=$1 script=$2
       # With --only=<stage>, run just that stage. 'fetch' is exempt: every
       # build stage needs its tarballs, and its marker makes it a no-op
       # once the sources are staged.
      if [ -n "$ONLY_STAGE" ] && [ "$name" != "$ONLY_STAGE" ] && [ "$name" != fetch ]; then
        return 0
      fi
       # Check if stage is already done.
      if [ -f "$STAGES_DIR/$name.done" ]; then
        echo "[build-ci] stage '$name' already complete (skipping)"
        return 0
      fi
      echo "[build-ci] >>> stage: $name"
      mkdir -p "$LOGS_DIR"
      bash "$script" 2>&1 | tee "$LOGS_DIR/$name.log"
      touch "$STAGES_DIR/$name.done"
      sync
      echo "[build-ci] <<< stage: $name complete"
    }

    if [ -n "$ONLY_STAGE" ]; then
      echo "[build-ci] running single stage: $ONLY_STAGE"
    else
      echo "[build-ci] running LFS build stages"
    fi

    if [ "$ONLY_STAGE" != package ]; then
      run_stage fetch      "$REPO_ROOT/tools/fetch-sources.sh"
      run_stage cross      "$REPO_ROOT/images/gnunix-base/stages/01-cross-toolchain.sh"
      run_stage temp-tools "$REPO_ROOT/images/gnunix-base/stages/02-temp-tools.sh"
      run_stage chroot     "$REPO_ROOT/images/gnunix-base/stages/03-chroot.sh"
      run_stage finalize   "$REPO_ROOT/images/gnunix-base/stages/04-finalize.sh"
    fi

     # Report tree size: the CI cache has a hard 10 GB ceiling, and the
     # stage-split design (ADR-023) depends on the tree fitting under it.
    echo "[build-ci] LFS tree size: $(du -sh "$LFS" 2>/dev/null | cut -f1)"

    if [ -n "$ONLY_STAGE" ] && [ "$ONLY_STAGE" != package ]; then
      echo "[build-ci] stage '$ONLY_STAGE' done (--only); not packaging."
      exit 0
    fi

    echo "[build-ci] all stages complete. rootfs at: $LFS"

     # Package: produce the disk image.
    echo "[build-ci] packaging disk image"
    bash "$REPO_ROOT/images/gnunix-base/packaging/mkimage.sh"

     # Compress and upload artifact.
    ART_DIR="$REPO_ROOT/cache/artifacts"
    mkdir -p "$ART_DIR"
    VER=$(jq -r .lfs_image_version "$REPO_ROOT/tools/manifest.json")
     # manifest.json has no `.arch` key — the multi-arch axis (ADR-010) is
     # `.active_arch`, mirrored by legacy `.target_arch`. The old expression
     # always fell through to the "aarch64" literal.
    ARCH=$(jq -r '.active_arch // .target_arch' "$REPO_ROOT/tools/manifest.json")
    IMG="$ART_DIR/gnunix-base-${ARCH}-${VER}.img"
    ZST="$ART_DIR/gnunix-base-${ARCH}-${VER}.img.zst"

     # packaging/mkimage.sh writes $LFS/../gnunix-base-disk.img. The old
     # /tmp path here predates that and silently produced no artifact.
    DISK="$LFS/../gnunix-base-disk.img"
    if [ ! -f "$DISK" ]; then
      echo "[build-ci] expected disk image not found: $DISK" >&2
      exit 1
    fi
    cp "$DISK" "$IMG"

     # Compress with zstd (level 10: ~4-5x faster than -19, ~15% bigger).
    if command -v zstd >/dev/null 2>&1; then
      echo "[build-ci] compressing → $ZST (level 10)"
      zstd -10 -f -k "$IMG" -o "$ZST"
      ls -lh "$ZST"
    fi

    echo "[build-ci] done. Artifact: $ZST"
    exit 0
fi

# === Tart path (local Mac): bootstrap + build ===
#
# This runs inside the gnunix-builder VM. It drives the four stages of the LFS
# build and produces a bootable rootfs at $LFS, then hands off to the packager.
#
# Stages are idempotent and resumable. Each stage writes a marker file in
# $LFS/.lfs-stages/ on completion; re-running skips completed stages unless
# --rebuild=<stage> is passed.

REPO_ROOT=${REPO_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}
export LFS=${LFS:-/mnt/lfs}
export LFS_TGT=$(uname -m)-lfs-linux-gnu
export LC_ALL=POSIX
export PATH=$LFS/tools/bin:/usr/bin:/usr/sbin:/bin:/sbin

STAGES_DIR=$LFS/.lfs-stages
SOURCES_DIR=$LFS/sources
LOGS_DIR=$LFS/logs

REBUILD=""
for arg in "$@"; do
  case "$arg" in
     --rebuild=*) REBUILD="${arg#--rebuild=}" ;;
     --help|-h)
      cat <<EOF
Usage: $0 [--rebuild=<stage>] [--ci]

Stages (in order):
  fetch         download and verify all source tarballs
  cross         build the cross-toolchain (binutils-1, gcc-1, headers, glibc, libstdc++)
  temp-tools    build temporary tools (m4, ncurses, bash, coreutils, ...)
  chroot        chroot into \$LFS and build the final system
  finalize      install configs, kernel, bootloader; pack the rootfs

Marker files: \$LFS/.lfs-stages/<stage>.done

CI mode (--ci): runs on the checked-out ubuntu-22.04-arm rootfs at
/mnt/lfs. No Tart needed — the stage scripts are chroot-based and
only need a shell + arm64 rootfs (ADR-021).
EOF
      exit 0 ;;
  esac
done

require() {
  command -v "$1" >/dev/null || { echo "missing required tool: $1" >&2; exit 1; }
}

stage_done() { [ -f "$STAGES_DIR/$1.done" ]; }
# sync after marker mutation: the rootfs is ext4 with commit=30, and a
# 'tart stop' from the host within that window discards uncommitted writes,
# so stage progress can otherwise vanish when build-all.sh exits.
stage_mark() { mkdir -p "$STAGES_DIR" && touch "$STAGES_DIR/$1.done" && sync; }
stage_clear() { rm -f "$STAGES_DIR/$1.done"; sync; }

run_stage() {
  local name=$1 script=$2
  if [ "$REBUILD" = "$name" ] || [ "$REBUILD" = "all" ]; then
    stage_clear "$name"
  fi
  if stage_done "$name"; then
    echo "[build] stage '$name' already complete (skipping)"
    return 0
  fi
  echo "[build] >>> stage: $name"
  mkdir -p "$LOGS_DIR"
  bash "$script" 2>&1 | tee "$LOGS_DIR/$name.log"
  stage_mark "$name"
  echo "[build] <<< stage: $name complete"
}

require curl
require sha256sum
require tar
require make
require gcc

mkdir -p "$LFS" "$STAGES_DIR" "$SOURCES_DIR" "$LOGS_DIR"

cd "$REPO_ROOT"

run_stage fetch        "$REPO_ROOT/tools/fetch-sources.sh"
run_stage cross        "$REPO_ROOT/images/gnunix-base/stages/01-cross-toolchain.sh"
run_stage temp-tools   "$REPO_ROOT/images/gnunix-base/stages/02-temp-tools.sh"
run_stage chroot       "$REPO_ROOT/images/gnunix-base/stages/03-chroot.sh"
run_stage finalize     "$REPO_ROOT/images/gnunix-base/stages/04-finalize.sh"

echo "[build] all stages complete. rootfs at: $LFS"
echo "[build] next: run images/gnunix-base/packaging/mkimage.sh to produce a Tart image"

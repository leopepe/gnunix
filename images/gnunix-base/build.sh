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
# Per ADR-021: --ci runs the LFS build directly on the checked-out
# ubuntu-22.04-arm rootfs at /mnt/lfs. No Tart needed — the stage
# scripts are chroot-based and only need a shell + arm64 rootfs.
#
# Usage:
#   $0                    # Tart path (local Mac): bootstrap + build
#   $0 --ci               # CI path: run stages on /mnt/lfs, package
#   $0 --rebuild=<stage>  # Rebuild a specific stage (both paths)
#
# CI mode expects:
#   /mnt/lfs            — ubuntu-22.04-arm rootfs (provisioned by CI)
#   /mnt/lfs/sources    — pre-fetched tarballs (optional, from CI cache)
#
# Output:
#   /tmp/gnunix-base-disk.img   — raw GPT disk image (EFI + ext4)
#   cache/artifacts/gnunix-base-<arch>-<ver>.img.zst  — compressed artifact

set -euo pipefail

CI_MODE=0
REBUILD=""
for arg in "$@"; do
  case "$arg" in
    --ci) CI_MODE=1 ;;
    --rebuild=*) REBUILD="${arg#--rebuild=}" ;;
  esac
done

if [ "$CI_MODE" = "1" ]; then
    # === CI mode: run stages on the checked-out rootfs ===
    #
    # Per ADR-021: the LFS build runs on ubuntu-22.04-arm via chroot.
    # No Tart, no self-hosted runner. The stage scripts are chroot-based
    # and only need an arm64 rootfs at /mnt/lfs.
    #
    # Stage-resume: markers in $LFS/.lfs-stages/ are restored from the
    # actions/cache (LFS tree cache). When the cache is restored, the
    # stage markers are also restored, so completed stages are skipped.
    # When the cache is a miss (e.g., script changed), all stages run.
    # The --rebuild=<stage> flag clears a specific stage's marker and
    # forces it to run again.

    echo "[build-ci] CI mode — running LFS stages on /mnt/lfs"

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
      sudo mkdir -p "$SOURCES_DIR"
      sudo rsync -a --ignore-existing "$REPO_ROOT/cache/sources/" "$SOURCES_DIR/"
    fi

    # sync after marker mutation: the rootfs is ext4 with commit=30,
    # so stage progress can otherwise vanish if the process is killed
    # before the next sync.
    stage_mark() { mkdir -p "$STAGES_DIR" && touch "$STAGES_DIR/$1.done" && sync; }
    stage_clear() { rm -f "$STAGES_DIR/$1.done"; sync; }

    run_stage() {
        local name=$1 script=$2
        # Check if stage is already done.
        if [ -f "$STAGES_DIR/$name.done" ]; then
            # Respect --rebuild flag: clear marker and force rebuild.
            if [ "$REBUILD" = "$name" ] || [ "$REBUILD" = "all" ]; then
                echo "[build-ci] --rebuild=$name — clearing marker and rebuilding"
                stage_clear "$name"
            else
                echo "[build-ci] stage '$name' already complete (skipping)"
                return 0
            fi
        fi
        echo "[build-ci] >>> stage: $name"
        mkdir -p "$LOGS_DIR"
        sudo bash "$script" 2>&1 | tee "$LOGS_DIR/$name.log"
        stage_mark "$name"
        echo "[build-ci] <<< stage: $name complete"
    }

    echo "[build-ci] running LFS build stages"
    run_stage fetch      "$REPO_ROOT/tools/fetch-sources.sh"
    run_stage cross      "$REPO_ROOT/images/gnunix-base/stages/01-cross-toolchain.sh"
    run_stage temp-tools "$REPO_ROOT/images/gnunix-base/stages/02-temp-tools.sh"
    run_stage chroot     "$REPO_ROOT/images/gnunix-base/stages/03-chroot.sh"
    run_stage finalize   "$REPO_ROOT/images/gnunix-base/stages/04-finalize.sh"

    echo "[build-ci] all stages complete. rootfs at: $LFS"

    # Package: produce the disk image.
    echo "[build-ci] packaging disk image"
    sudo bash "$REPO_ROOT/images/gnunix-base/packaging/mkimage.sh"

    # Compress and upload artifact.
    ART_DIR="$REPO_ROOT/cache/artifacts"
    mkdir -p "$ART_DIR"
    VER=$(jq -r .lfs_image_version "$REPO_ROOT/tools/manifest.json")
    ARCH=$(jq -r '.arch // "aarch64"' "$REPO_ROOT/tools/manifest.json")
    IMG="$ART_DIR/gnunix-base-${ARCH}-${VER}.img"
    ZST="$ART_DIR/gnunix-base-${ARCH}-${VER}.img.zst"

    if [ -f /tmp/gnunix-base-disk.img ]; then
        cp /tmp/gnunix-base-disk.img "$IMG"
    fi

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

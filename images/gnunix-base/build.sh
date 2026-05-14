#!/bin/bash
# Master orchestrator for the gnunix-base image build.
#
# This runs *inside* the gnunix-builder VM. It drives the four stages of the LFS
# build and produces a bootable rootfs at $LFS, then hands off to the packager.
#
# Stages are idempotent and resumable. Each stage writes a marker file in
# $LFS/.lfs-stages/ on completion; re-running skips completed stages unless
# --rebuild=<stage> is passed.

set -euo pipefail

REPO_ROOT=${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
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
Usage: $0 [--rebuild=<stage>]

Stages (in order):
  fetch         download and verify all source tarballs
  cross         build the cross-toolchain (binutils-1, gcc-1, headers, glibc, libstdc++)
  temp-tools    build temporary tools (m4, ncurses, bash, coreutils, ...)
  chroot        chroot into \$LFS and build the final system
  finalize      install configs, kernel, bootloader; pack the rootfs

Marker files: \$LFS/.lfs-stages/<stage>.done
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

run_stage fetch       "$REPO_ROOT/tools/fetch-sources.sh"
run_stage cross       "$REPO_ROOT/images/gnunix-base/stages/01-cross-toolchain.sh"
run_stage temp-tools  "$REPO_ROOT/images/gnunix-base/stages/02-temp-tools.sh"
run_stage chroot      "$REPO_ROOT/images/gnunix-base/stages/03-chroot.sh"
run_stage finalize    "$REPO_ROOT/images/gnunix-base/stages/04-finalize.sh"

echo "[build] all stages complete. rootfs at: $LFS"
echo "[build] next: run images/gnunix-base/packaging/mkimage.sh to produce a Tart image"

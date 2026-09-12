#!/bin/sh
# Pack / unpack the LFS tree for the CI stage cache.
#
# actions/cache cannot handle $LFS directly. It runs as the unprivileged
# `runner` user, and /mnt is root-owned, so restoring `path: /mnt/lfs`
# fails with:
#     tar: ../../../../../mnt/lfs: Cannot mkdir: Permission denied
# Making /mnt/lfs runner-writable would fix the mkdir but not the real
# problem: a tree extracted by a non-root tar loses every ownership and
# setuid bit it carries, which is silent corruption for the chroot-stage
# rootfs (/usr/bin/su, /etc/shadow, device nodes).
#
# So the cache holds a tarball inside the workspace — a plain file the
# runner user owns — and root does both the packing and the unpacking,
# preserving ownership on the round trip.
#
# Usage:
#   scripts/ci-lfs-cache.sh pack   <tarball>   # run as root
#   scripts/ci-lfs-cache.sh unpack <tarball>   # run as root

set -eu

LFS=${LFS:-/mnt/lfs}
MODE=${1:-}
TARBALL=${2:-}

[ -n "$MODE" ] && [ -n "$TARBALL" ] || {
  echo "usage: $0 {pack|unpack} <tarball>" >&2
  exit 1
}

[ "$(id -u)" = 0 ] || {
  echo "[ci-lfs-cache] must run as root to preserve tree ownership" >&2
  exit 1
}

parent=$(dirname "$LFS")
base=$(basename "$LFS")

case "$MODE" in
  pack)
    [ -d "$LFS" ] || {
      echo "[ci-lfs-cache] nothing to pack: $LFS does not exist" >&2
      exit 1
    }
    mkdir -p "$(dirname "$TARBALL")"
    echo "[ci-lfs-cache] packing $LFS ($(du -sh "$LFS" | cut -f1))"
    # zstd -3: the tree is re-packed every stage, so favour speed. The
    # artifact is transient cache, not a published image.
    tar --use-compress-program='zstd -3 -T0' \
        -cf "$TARBALL" -C "$parent" "$base"
    # Hand the file back to the unprivileged user so actions/cache can
    # read it when it uploads.
    chown "$(stat -c '%u:%g' "$(dirname "$TARBALL")")" "$TARBALL"
    ls -lh "$TARBALL"
    ;;
  unpack)
    [ -f "$TARBALL" ] || {
      echo "[ci-lfs-cache] no cached tree at $TARBALL — nothing to unpack"
      exit 0
    }
    echo "[ci-lfs-cache] unpacking $TARBALL into $parent"
    mkdir -p "$parent"
    tar --use-compress-program=unzstd -xf "$TARBALL" -C "$parent"
    echo "[ci-lfs-cache] restored $LFS ($(du -sh "$LFS" | cut -f1))"
    ;;
  *)
    echo "[ci-lfs-cache] unknown mode: $MODE" >&2
    exit 1
    ;;
esac

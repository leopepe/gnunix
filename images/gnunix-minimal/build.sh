#!/bin/bash
# images/gnunix-minimal/build.sh — Phase 3 orchestrator.
#
# Layers the multi-user Nix daemon on top of gnunix-base-<ver> and produces
# gnunix-minimal-<ver>. ADRs: 003 (multi-user Nix), 004 (plain Nix +
# home-manager), 021 (hosted runners only).
#
# Flow:
#    1. Verify gnunix-base-<ver> exists (built by Phase 2).
#    2. Verify the Nix binary tarball is in cache/sources/ (downloaded
#       by tools/fetch-sources.sh, or fetched here as a fallback).
#    3. Clone base image, boot it, ssh in as root (key installed in Phase 2).
#    4. scp the tarball + install-gnunix-minimal.sh into the VM.
#    5. ssh + run install-gnunix-minimal.sh → multi-user install without systemd.
#    6. sync, stop VM.
#    7. Promote to versioned name.
#    8. Emit raw disk image + zstd compressed artifact.
#
# Per ADR-021: --ci runs on a local disk image (no Tart).
# The image is decompressed from a zstd artifact, loop-mounted,
# the Nix layer is installed, and the final image is emitted.

set -euo pipefail

CI_MODE=0
for arg in "$@"; do
  case "$arg" in
      --ci) CI_MODE=1 ;;
  esac
done

REPO_ROOT=${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
CORE_VER=$(jq -r .lfs_image_version "$REPO_ROOT/tools/manifest.json")
ARCH=$(jq -r '.active_arch // .target_arch' "$REPO_ROOT/tools/manifest.json")
NIX_TARBALL_URL=$(jq -r .nix.binary_url "$REPO_ROOT/tools/manifest.json")
NIX_TARBALL_SHA=$(jq -r .nix.binary_sha256 "$REPO_ROOT/tools/manifest.json")

if [ "$CI_MODE" = "1" ]; then
      # === CI mode: work on a local disk image ===
      #
      # The base image is a zstd-compressed artifact. We decompress it,
      # loop-mount the partitions, install the Nix layer, and emit the
      # final image.

    echo "[build-minimal-ci] CI mode — installing Nix layer on disk image"

    BASE_ART="$REPO_ROOT/cache/artifacts/gnunix-base-${ARCH}-${CORE_VER}.img.zst"
    [ -f "$BASE_ART" ] || { echo "[build-minimal-ci] base artifact not found: $BASE_ART" >&2; exit 1; }

    WORK=$(mktemp -d)
    trap 'rm -rf "$WORK"' EXIT

    BASE_IMG="$WORK/base.img"
    echo "[build-minimal-ci] decompressing base artifact → $BASE_IMG"
    zstd -d -c "$BASE_ART" > "$BASE_IMG"

        # Mount the disk image partitions.
    LOOP=$(losetup --show -fP "$BASE_IMG") || { echo "[build-minimal-ci] losetup failed" >&2; exit 1; }
    trap "losetup -d '$LOOP' 2>/dev/null || true; rm -rf '$WORK'" EXIT

    ROOT_PART="${LOOP}p2"
    MNT="$WORK/mnt"
    mkdir -p "$MNT"
    mount "$ROOT_PART" "$MNT"

        # The Nix tarball must be available. In CI mode, it comes from
        # the host's cache (downloaded by the workflow or a prior step).
    TARBALL_NAME=$(basename "$NIX_TARBALL_URL")
    TARBALL="$REPO_ROOT/cache/sources/$TARBALL_NAME"
    if [ ! -f "$TARBALL" ]; then
      echo "[build-minimal-ci] fetching Nix tarball"
      mkdir -p "$(dirname "$TARBALL")"
      curl -fL --connect-timeout 15 --speed-time 30 --speed-limit 1024 \
          --max-time 600 -o "$TARBALL" "$NIX_TARBALL_URL"
    fi
    GOT_SHA=$(shasum -a 256 "$TARBALL" | awk '{print $1}')
    [ "$GOT_SHA" = "$NIX_TARBALL_SHA" ] \
        || { echo "[build-minimal-ci] sha256 mismatch on $TARBALL_NAME"; echo "  expected $NIX_TARBALL_SHA"; echo "  got       $GOT_SHA"; exit 1; }

        # Copy the Nix tarball and installer into the rootfs.
    install -d -m 0755 "$MNT/root"
    cp "$TARBALL" "$MNT/root/$TARBALL_NAME"
    cp "$REPO_ROOT/images/gnunix-minimal/install-gnunix-minimal.sh" "$MNT/root/install-gnunix-minimal.sh"

        # Run the installer inside the mounted rootfs.
        # The installer uses /nix as its working directory; we need to
        # ensure the Nix daemon is accessible. Since we're on the host,
        # the Nix daemon at /nix/var/nix/profiles/default is the host's
        # Nix — we just need its binaries to extract and load the store.
    echo "[build-minimal-ci] running install-gnunix-minimal.sh"
    chroot "$MNT" /bin/bash /root/install-gnunix-minimal.sh \
        NIX_TARBALL="/root/$TARBALL_NAME" \
        HOME=/root \
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

        # Sync and cleanup.
    sync
    umount "$MNT"
    losetup -d "$LOOP"
    trap - EXIT

        # Emit the final artifact.
    ART_DIR="$REPO_ROOT/cache/artifacts"
    mkdir -p "$ART_DIR"
    RAW_OUT="$ART_DIR/gnunix-minimal-${ARCH}-${CORE_VER}.img"
    echo "[build-minimal-ci] emitting raw disk artifact → $RAW_OUT"
    cp "$BASE_IMG" "$RAW_OUT"
    ls -lh "$RAW_OUT"

    if command -v zstd >/dev/null 2>&1; then
      ZST_OUT="$RAW_OUT.zst"
      echo "[build-minimal-ci] compressing → $ZST_OUT (level 10, backgrounded)"
      rm -f "$ZST_OUT"
      ( zstd -10 -f -k "$RAW_OUT" -o "$ZST_OUT" && ls -lh "$ZST_OUT" ) &
      echo "[build-minimal-ci]   zstd pid=$! (will finish in background)"
    fi

    echo "[build-minimal-ci] === gnunix-minimal $CORE_VER built (CI). ==="
    echo "  Raw disk image: $RAW_OUT"
    exit 0
fi

# === Tart path (local Mac) ===

CORE_VM="gnunix-base-$CORE_VER"
BUILD_VM="gnunix-minimal-build"
NIX_VM="gnunix-minimal-$CORE_VER"

SSH_OPTS="-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

# 1. Base image must exist.
tart_exists "$CORE_VM" \
    || { echo "[build-minimal] $CORE_VM not found — run 'tools/build-all.sh gnunix-base' first" >&2; exit 1; }

# 2. Tarball must be on host (sha256-pinned).
TARBALL_NAME=$(basename "$NIX_TARBALL_URL")
TARBALL="$REPO_ROOT/cache/sources/$TARBALL_NAME"
if [ ! -f "$TARBALL" ]; then
  echo "[build-minimal] fetching $TARBALL_NAME"
  mkdir -p "$(dirname "$TARBALL")"
  curl -fL --connect-timeout 15 --speed-time 30 --speed-limit 1024 \
      --max-time 600 -o "$TARBALL" "$NIX_TARBALL_URL"
fi
GOT_SHA=$(shasum -a 256 "$TARBALL" | awk '{print $1}')
[ "$GOT_SHA" = "$NIX_TARBALL_SHA" ] \
    || { echo "[build-minimal] sha256 mismatch on $TARBALL_NAME"; echo "  expected $NIX_TARBALL_SHA"; echo "  got       $GOT_SHA"; exit 1; }

# 3. Clone base.
echo "[build-minimal] cloning $CORE_VM → $BUILD_VM"
tart_exists "$BUILD_VM" && tart delete "$BUILD_VM" || true
tart clone "$CORE_VM" "$BUILD_VM"

# 4. Boot and wait for ssh.
echo "[build-minimal] starting $BUILD_VM"
tart run --no-graphics "$BUILD_VM" >/dev/null 2>&1 &
BUILDER_PID=$!

stop_builder() {
  local ip
  ip=$(tart_ip "$BUILD_VM" 2>/dev/null || true)
  if [ -n "$ip" ]; then
    ssh $SSH_OPTS -o ConnectTimeout=5 "root@$ip" "sync; sync" 2>/dev/null || true
  fi
  tart stop "$BUILD_VM" >/dev/null 2>&1 || true
  kill "$BUILDER_PID" 2>/dev/null || true
}
trap stop_builder EXIT

echo "[build-minimal] waiting for ssh"
IP=""
for i in $(seq 1 30); do
  IP=$(tart_ip "$BUILD_VM" 2>/dev/null || true)
  if [ -n "$IP" ]; then
    if ssh $SSH_OPTS -o ConnectTimeout=2 "root@$IP" true 2>/dev/null; then
      break
    fi
  fi
  sleep 3
done
[ -n "$IP" ] || { echo "[build-minimal] ssh never came up"; exit 1; }
echo "[build-minimal] root@$IP ready"

# 5. Push tarball + installer.
echo "[build-minimal] copying tarball ($(du -h "$TARBALL" | cut -f1)) + install-gnunix-minimal.sh"
scp $SSH_OPTS "$TARBALL" "root@$IP:/root/$TARBALL_NAME"
scp $SSH_OPTS "$REPO_ROOT/images/gnunix-minimal/install-gnunix-minimal.sh" "root@$IP:/root/install-gnunix-minimal.sh"

# 6. Install.
echo "[build-minimal] running install-gnunix-minimal.sh inside VM"
ssh $SSH_OPTS "root@$IP" \
    "NIX_TARBALL=/root/$TARBALL_NAME bash /root/install-gnunix-minimal.sh"

# 7. Sync + stop.
echo "[build-minimal] sync + stop $BUILD_VM"
ssh $SSH_OPTS "root@$IP" "sync; sync"
tart stop "$BUILD_VM"
trap - EXIT

# 8. Promote to versioned name.
echo "[build-minimal] cloning $BUILD_VM → $NIX_VM"
tart_exists "$NIX_VM" && tart delete "$NIX_VM" || true
tart clone "$BUILD_VM" "$NIX_VM"

# 9. Emit the raw disk image as a portable artifact. The Tart VM dir at
#    ~/.tart/vms/$NIX_VM/disk.img is a generic raw GPT Linux image (FAT32
#    ESP + ext4 root, UEFI-bootable) — Tart is just one way to consume it.
#    qemu/libvirt/Proxmox/UTM/cloud-image-uploaders can all boot disk.img
#    directly. See docs/runbooks/test-image.md for host-agnostic options.
ART_DIR="$REPO_ROOT/cache/artifacts"
mkdir -p "$ART_DIR"
RAW_OUT="$ART_DIR/gnunix-minimal-$ARCH-$CORE_VER.img"
echo "[build-minimal] emitting raw disk artifact → $RAW_OUT"
cp "$HOME/.tart/vms/$NIX_VM/disk.img" "$RAW_OUT"
ls -lh "$RAW_OUT"

# Compressed artifact for distribution. Level 10 backgrounded — see ADR/
# rationale in tools/build-all.sh (the lfs-core path uses the same pattern).
if command -v zstd >/dev/null; then
  ZST_OUT="$RAW_OUT.zst"
  echo "[build-minimal] compressing → $ZST_OUT (level 10, backgrounded)"
  rm -f "$ZST_OUT"
  ( zstd -10 -f -k "$RAW_OUT" -o "$ZST_OUT" && ls -lh "$ZST_OUT" ) &
  echo "[build-minimal]   zstd pid=$! (will finish in background)"
fi

echo "[build-minimal] === gnunix-minimal $CORE_VER built. ==="
echo "  Tart VM:          $NIX_VM    (tart run $NIX_VM)"
echo "  Raw disk image:   $RAW_OUT"
echo "  Smoke test:      tests/minimal/minimal-smoke.sh $NIX_VM"

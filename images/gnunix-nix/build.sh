#!/bin/bash
# images/gnunix-nix/build.sh — Phase 3 orchestrator (runs on the macOS host).
#
# Layers the multi-user Nix daemon on top of gnunix-base-<ver> and produces
# gnunix-nix-<ver>. ADRs: 003 (multi-user Nix), 004 (plain Nix + home-manager),
# 005 (this Mac first).
#
# Flow:
#   1. Verify gnunix-base-<ver> exists in Tart (built by Phase 2).
#   2. Verify the Nix binary tarball is in cache/sources/ (downloaded by
#      tools/fetch-sources.sh, or fetched here as a fallback).
#   3. `tart clone gnunix-base-<ver> → gnunix-nix-build` (disposable working copy).
#   4. Boot gnunix-nix-build, ssh in as root (key installed in Phase 2).
#   5. scp the tarball + install-gnunix-nix.sh into the VM.
#   6. ssh + run install-gnunix-nix.sh → multi-user install without systemd.
#   7. sync, tart stop.
#   8. `tart clone gnunix-nix-build → gnunix-nix-<ver>` (the deliverable).

set -euo pipefail

REPO_ROOT=${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
. "$REPO_ROOT/scripts/tart-helpers.sh"

CORE_VER=$(jq -r .lfs_image_version "$REPO_ROOT/tools/manifest.json")
NIX_TARBALL_URL=$(jq -r .nix.binary_url "$REPO_ROOT/tools/manifest.json")
NIX_TARBALL_SHA=$(jq -r .nix.binary_sha256 "$REPO_ROOT/tools/manifest.json")

CORE_VM="gnunix-base-$CORE_VER"
BUILD_VM="gnunix-nix-build"
NIX_VM="gnunix-nix-$CORE_VER"

SSH_OPTS="-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

# 1. Base image must exist.
tart_exists "$CORE_VM" \
  || { echo "[build-nix] $CORE_VM not found — run 'tools/build-all.sh gnunix-base' first" >&2; exit 1; }

# 2. Tarball must be on host (sha256-pinned).
TARBALL_NAME=$(basename "$NIX_TARBALL_URL")
TARBALL="$REPO_ROOT/cache/sources/$TARBALL_NAME"
if [ ! -f "$TARBALL" ]; then
  echo "[build-nix] fetching $TARBALL_NAME"
  mkdir -p "$(dirname "$TARBALL")"
  curl -fL --connect-timeout 15 --speed-time 30 --speed-limit 1024 \
    --max-time 600 -o "$TARBALL" "$NIX_TARBALL_URL"
fi
GOT_SHA=$(shasum -a 256 "$TARBALL" | awk '{print $1}')
[ "$GOT_SHA" = "$NIX_TARBALL_SHA" ] \
  || { echo "[build-nix] sha256 mismatch on $TARBALL_NAME"; echo "  expected $NIX_TARBALL_SHA"; echo "  got      $GOT_SHA"; exit 1; }

# 3. Clone base.
echo "[build-nix] cloning $CORE_VM → $BUILD_VM"
tart_exists "$BUILD_VM" && tart delete "$BUILD_VM" || true
tart clone "$CORE_VM" "$BUILD_VM"

# 4. Boot and wait for ssh.
echo "[build-nix] starting $BUILD_VM"
tart run --no-graphics "$BUILD_VM" >/dev/null 2>&1 &
BUILDER_PID=$!

stop_builder() {
  local ip
  ip=$(tart_ip "$BUILD_VM" 2>/dev/null || true)
  if [ -n "$ip" ]; then
    # shellcheck disable=SC2086
    ssh $SSH_OPTS -o ConnectTimeout=5 "root@$ip" "sync; sync" 2>/dev/null || true
  fi
  tart stop "$BUILD_VM" >/dev/null 2>&1 || true
  kill "$BUILDER_PID" 2>/dev/null || true
}
trap stop_builder EXIT

echo "[build-nix] waiting for ssh"
IP=""
for i in $(seq 1 30); do
  IP=$(tart_ip "$BUILD_VM" 2>/dev/null || true)
  if [ -n "$IP" ]; then
    # shellcheck disable=SC2086
    if ssh $SSH_OPTS -o ConnectTimeout=2 "root@$IP" true 2>/dev/null; then
      break
    fi
  fi
  sleep 3
done
[ -n "$IP" ] || { echo "[build-nix] ssh never came up"; exit 1; }
echo "[build-nix] root@$IP ready"

# 5. Push tarball + installer.
echo "[build-nix] copying tarball ($(du -h "$TARBALL" | cut -f1)) + install-gnunix-nix.sh"
# shellcheck disable=SC2086
scp $SSH_OPTS "$TARBALL" "root@$IP:/root/$TARBALL_NAME"
# shellcheck disable=SC2086
scp $SSH_OPTS "$REPO_ROOT/images/gnunix-nix/install-gnunix-nix.sh" "root@$IP:/root/install-gnunix-nix.sh"

# 6. Install.
echo "[build-nix] running install-gnunix-nix.sh inside VM"
# shellcheck disable=SC2086
ssh $SSH_OPTS "root@$IP" \
  "NIX_TARBALL=/root/$TARBALL_NAME bash /root/install-gnunix-nix.sh"

# 7. Sync + stop.
echo "[build-nix] sync + stop $BUILD_VM"
# shellcheck disable=SC2086
ssh $SSH_OPTS "root@$IP" "sync; sync"
tart stop "$BUILD_VM"
trap - EXIT

# 8. Promote to versioned name.
echo "[build-nix] cloning $BUILD_VM → $NIX_VM"
tart_exists "$NIX_VM" && tart delete "$NIX_VM" || true
tart clone "$BUILD_VM" "$NIX_VM"

# 9. Emit the raw disk image as a portable artifact. The Tart VM dir at
#    ~/.tart/vms/$NIX_VM/disk.img is a generic raw GPT Linux image (FAT32
#    ESP + ext4 root, UEFI-bootable) — Tart is just one way to consume it.
#    qemu/libvirt/Proxmox/UTM/cloud-image-uploaders can all boot disk.img
#    directly. See docs/runbooks/test-image.md for host-agnostic options.
ART_DIR="$REPO_ROOT/cache/artifacts"
mkdir -p "$ART_DIR"
RAW_OUT="$ART_DIR/gnunix-nix-disk-$CORE_VER.img"
echo "[build-nix] emitting raw disk artifact → $RAW_OUT"
cp "$HOME/.tart/vms/$NIX_VM/disk.img" "$RAW_OUT"
ls -lh "$RAW_OUT"

# Compressed artifact for distribution. Level 10 backgrounded — see ADR/
# rationale in tools/build-all.sh (the lfs-core path uses the same pattern).
if command -v zstd >/dev/null; then
  ZST_OUT="$RAW_OUT.zst"
  echo "[build-nix] compressing → $ZST_OUT (level 10, backgrounded)"
  rm -f "$ZST_OUT"
  ( zstd -10 -f -k "$RAW_OUT" -o "$ZST_OUT" && ls -lh "$ZST_OUT" ) &
  echo "[build-nix]   zstd pid=$! (will finish in background)"
fi

echo "[build-nix] === gnunix-nix $CORE_VER built. ==="
echo "  Tart VM:        $NIX_VM   (tart run $NIX_VM)"
echo "  Raw disk image: $RAW_OUT"
echo "  Smoke test:     tests/nix-smoke.sh $NIX_VM"

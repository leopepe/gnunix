#!/bin/bash
# images/gnunix-desktop/build.sh — Phase 4 orchestrator (runs on the macOS host).
#
# Layers a Wayland graphical session on top of gnunix-minimal-<ver> and produces
# gnunix-desktop-<ver>. ADRs: 001 (sysvinit), 002 (elogind), 003 (multi-user Nix),
# 004 (plain Nix + home-manager), 009 (compositor + greeter + system services).
#
# Flow (mirrors images/gnunix-minimal/build.sh):
#   1. Verify gnunix-minimal-<ver> exists in Tart (built by Phase 3).
#   2. `tart clone gnunix-minimal-<ver> → gnunix-desktop-build` (disposable working copy).
#   3. Boot gnunix-desktop-build, ssh in as root.
#   4. Tar up images/gnunix-desktop/etc/ and the installer script, scp into VM.
#   5. Run install-gnunix-desktop.sh — adds nixpkgs channel, installs system services,
#      creates the unprivileged user, installs configs, enables rc scripts.
#   6. sync, tart stop.
#   7. `tart clone gnunix-desktop-build → gnunix-desktop-<ver>` (the deliverable).
#   8. Emit raw disk image artifact + zstd compression.

set -euo pipefail

REPO_ROOT=${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
. "$REPO_ROOT/scripts/tart-helpers.sh"

VER=$(jq -r .lfs_image_version "$REPO_ROOT/tools/manifest.json")
ARCH=$(jq -r '.active_arch // .target_arch' "$REPO_ROOT/tools/manifest.json")
CHANNEL=$(jq -r .nix.channel "$REPO_ROOT/tools/manifest.json")

NIX_VM="gnunix-minimal-$VER"
BUILD_VM="gnunix-desktop-build"
WAYLAND_VM="gnunix-desktop-$VER"

SSH_OPTS="-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

# 1. Base image must exist.
tart_exists "$NIX_VM" \
  || { echo "[build-wayland] $NIX_VM not found — run 'tools/build-all.sh gnunix-minimal' first" >&2; exit 1; }

# 2. Clone base.
echo "[build-wayland] cloning $NIX_VM → $BUILD_VM"
tart_exists "$BUILD_VM" && tart delete "$BUILD_VM" || true
tart clone "$NIX_VM" "$BUILD_VM"

# 3. Boot and wait for ssh.
echo "[build-wayland] starting $BUILD_VM"
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

echo "[build-wayland] waiting for ssh"
IP=""
for i in $(seq 1 60); do
  IP=$(tart_ip "$BUILD_VM" 2>/dev/null || true)
  if [ -n "$IP" ]; then
    # shellcheck disable=SC2086
    if ssh $SSH_OPTS -o ConnectTimeout=2 "root@$IP" true 2>/dev/null; then
      break
    fi
  fi
  sleep 3
done
[ -n "$IP" ] || { echo "[build-wayland] ssh never came up"; exit 1; }
echo "[build-wayland] root@$IP ready"

# 4. Pack the etc tree + installer into a tarball and copy it over.
WAYLAND_DIR="$REPO_ROOT/images/gnunix-desktop"
PAYLOAD=$(mktemp -t wayland-payload.XXXXXX.tar.gz)
trap 'rm -f "$PAYLOAD"; stop_builder' EXIT
echo "[build-wayland] building payload tarball"
tar -C "$WAYLAND_DIR" -czf "$PAYLOAD" etc install-gnunix-desktop.sh

echo "[build-wayland] copying payload ($(du -h "$PAYLOAD" | cut -f1))"
# shellcheck disable=SC2086
scp $SSH_OPTS "$PAYLOAD" "root@$IP:/root/wayland-payload.tar.gz"

# 5. Install. Pipe the script over stdin (heredoc) to avoid the nested
#    single-quote-in-double-quote hell that bites `ssh ... bash -c '...'`.
echo "[build-wayland] running install-gnunix-desktop.sh inside VM (channel: $CHANNEL)"
# SC2086: $SSH_OPTS deliberately splits into separate -o flags.
# SC2087: $CHANNEL is a local variable; we *want* it expanded on the
#   client side and embedded into the script that runs in the VM.
# shellcheck disable=SC2086,SC2087
ssh $SSH_OPTS "root@$IP" bash <<EOF
set -euo pipefail
cd /root
rm -rf wayland-payload
mkdir wayland-payload
tar -C wayland-payload -xzf wayland-payload.tar.gz
NIXPKGS_CHANNEL=$CHANNEL bash wayland-payload/install-gnunix-desktop.sh
EOF

# 6. Sync + stop.
echo "[build-wayland] sync + stop $BUILD_VM"
# shellcheck disable=SC2086
ssh $SSH_OPTS "root@$IP" "sync; sync"
tart stop "$BUILD_VM"
trap 'rm -f "$PAYLOAD"' EXIT

# 7. Promote to versioned name.
echo "[build-wayland] cloning $BUILD_VM → $WAYLAND_VM"
tart_exists "$WAYLAND_VM" && tart delete "$WAYLAND_VM" || true
tart clone "$BUILD_VM" "$WAYLAND_VM"

# 8. Emit the raw disk image as a portable artifact (same pattern as Phase 3).
ART_DIR="$REPO_ROOT/cache/artifacts"
mkdir -p "$ART_DIR"
RAW_OUT="$ART_DIR/gnunix-desktop-$ARCH-$VER.img"
echo "[build-wayland] emitting raw disk artifact → $RAW_OUT"
cp "$HOME/.tart/vms/$WAYLAND_VM/disk.img" "$RAW_OUT"
ls -lh "$RAW_OUT"

if command -v zstd >/dev/null; then
  ZST_OUT="$RAW_OUT.zst"
  echo "[build-wayland] compressing → $ZST_OUT (level 10, backgrounded)"
  rm -f "$ZST_OUT"
  ( zstd -10 -f -k "$RAW_OUT" -o "$ZST_OUT" && ls -lh "$ZST_OUT" ) &
  ZSTD_PID=$!
  echo "[build-wayland]   zstd pid=$ZSTD_PID (will finish in background)"
fi

rm -f "$PAYLOAD"

# gnunix-desktop is the last layer in the standard pipeline. Wait for the
# zstd we just kicked off so this script's exit point is also the artifact's
# completion point — otherwise smoke tests + downstream packaging could
# race with the still-running compression.
if [ -n "${ZSTD_PID:-}" ]; then
  echo "[build-wayland] waiting for zstd ($ZSTD_PID) to finish before exit"
  wait "$ZSTD_PID" 2>/dev/null || true
fi

echo "[build-wayland] === gnunix-desktop $VER built. ==="
echo "  Tart VM:        $WAYLAND_VM   (tart run $WAYLAND_VM)"
echo "  Raw disk image: $RAW_OUT"
echo "  Smoke test:     tests/wayland-session.sh $WAYLAND_VM"

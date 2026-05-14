#!/bin/bash
# images/installer/build.sh — produces gnunix-installer-<arch>-<ver>
# Tart VM + a raw .img artifact. Mirrors the gnunix-desktop pattern
# (clone → ssh in → install → promote → emit), but the in-VM step is
# `install-installer.sh` instead of `install-gnunix-desktop.sh`, and
# the deliverable is meant to be `dd`'d to a USB rather than imported
# into Tart by an end user.
#
# Per ADR-015.

set -euo pipefail

REPO_ROOT=${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
. "$REPO_ROOT/scripts/tart-helpers.sh"

VER=$(jq -r .lfs_image_version "$REPO_ROOT/tools/manifest.json")
DESKTOP_VM="gnunix-desktop-$VER"
BUILD_VM="gnunix-installer-build"
INSTALLER_VM="gnunix-installer-$VER"

SSH_OPTS="-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

# 1. Base must exist.
tart_exists "$DESKTOP_VM" \
  || { echo "[build-installer] $DESKTOP_VM not found — run 'tools/build-all.sh gnunix-desktop' first" >&2; exit 1; }

# 2. Clone.
echo "[build-installer] cloning $DESKTOP_VM → $BUILD_VM"
tart_exists "$BUILD_VM" && tart delete "$BUILD_VM" || true
tart clone "$DESKTOP_VM" "$BUILD_VM"

# 3. Boot.
echo "[build-installer] starting $BUILD_VM"
tart run --no-graphics "$BUILD_VM" >/dev/null 2>&1 &
BUILDER_PID=$!
stop_builder() {
  local ip; ip=$(tart_ip "$BUILD_VM" 2>/dev/null || true)
  if [ -n "$ip" ]; then
    # shellcheck disable=SC2086
    ssh $SSH_OPTS -o ConnectTimeout=5 "root@$ip" "sync; sync" 2>/dev/null || true
  fi
  tart stop "$BUILD_VM" >/dev/null 2>&1 || true
  kill "$BUILDER_PID" 2>/dev/null || true
}
trap stop_builder EXIT

echo "[build-installer] waiting for ssh"
IP=""
for i in $(seq 1 60); do
  IP=$(tart_ip "$BUILD_VM" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | tail -1 || true)
  if [ -n "$IP" ]; then
    # shellcheck disable=SC2086
    if ssh $SSH_OPTS -o ConnectTimeout=2 "root@$IP" true 2>/dev/null; then
      break
    fi
  fi
  sleep 3
done
[ -n "$IP" ] || { echo "[build-installer] ssh never came up"; exit 1; }
echo "[build-installer] root@$IP ready"

# 4. Payload tar — the installer TUI + profiles + themes.
PAYLOAD=$(mktemp -t installer-payload.XXXXXX.tar.gz)
trap 'rm -f "$PAYLOAD"; stop_builder' EXIT
echo "[build-installer] building payload tarball"
tar -C "$REPO_ROOT/images/installer" -czf "$PAYLOAD" installer install-installer.sh

echo "[build-installer] copying payload ($(du -h "$PAYLOAD" | cut -f1))"
# shellcheck disable=SC2086
scp $SSH_OPTS "$PAYLOAD" "root@$IP:/root/installer-payload.tar.gz"

# 5. Run the provisioner inside the VM.
echo "[build-installer] running install-installer.sh inside VM"
# shellcheck disable=SC2086
ssh $SSH_OPTS "root@$IP" bash <<EOF
set -euo pipefail
cd /root
rm -rf installer-payload
mkdir installer-payload
tar -C installer-payload -xzf installer-payload.tar.gz
bash installer-payload/install-installer.sh
EOF

# 6. Sync + stop.
echo "[build-installer] sync + stop $BUILD_VM"
# shellcheck disable=SC2086
ssh $SSH_OPTS "root@$IP" "sync; sync"
tart stop "$BUILD_VM"
trap 'rm -f "$PAYLOAD"' EXIT

# 7. Promote.
echo "[build-installer] cloning $BUILD_VM → $INSTALLER_VM"
tart_exists "$INSTALLER_VM" && tart delete "$INSTALLER_VM" || true
tart clone "$BUILD_VM" "$INSTALLER_VM"

# 8. Emit raw .img. (.iso emission is a follow-up; the .img is bootable
#    by `dd` to a USB stick on its own.)
ART_DIR="$REPO_ROOT/cache/artifacts"
ARCH=$(jq -r '.active_arch // .target_arch' "$REPO_ROOT/tools/manifest.json")
mkdir -p "$ART_DIR"
RAW_OUT="$ART_DIR/gnunix-installer-$ARCH-$VER.img"
echo "[build-installer] emitting raw disk artifact → $RAW_OUT"
cp "$HOME/.tart/vms/$INSTALLER_VM/disk.img" "$RAW_OUT"
ls -lh "$RAW_OUT"

# 9. zstd in background, same pattern as the other layers.
if command -v zstd >/dev/null; then
  ZST_OUT="$RAW_OUT.zst"
  echo "[build-installer] compressing → $ZST_OUT (level 10, backgrounded)"
  rm -f "$ZST_OUT"
  ( zstd -10 -f -k "$RAW_OUT" -o "$ZST_OUT" && ls -lh "$ZST_OUT" ) &
  ZSTD_PID=$!
  echo "[build-installer]   zstd pid=$ZSTD_PID (will finish in background)"
fi

rm -f "$PAYLOAD"

# Leaf of the lineage — wait for our own zstd, same as gnunix-desktop does.
if [ -n "${ZSTD_PID:-}" ]; then
  echo "[build-installer] waiting for zstd ($ZSTD_PID) to finish before exit"
  wait "$ZSTD_PID" 2>/dev/null || true
fi

echo "[build-installer] === gnunix-installer $VER built. ==="
echo "  Tart VM:        $INSTALLER_VM   (tart run --vnc-experimental $INSTALLER_VM to try the live boot)"
echo "  Raw disk image: $RAW_OUT"
echo "  USB write:      sudo dd if=$RAW_OUT of=/dev/sdX bs=4M status=progress conv=fsync"

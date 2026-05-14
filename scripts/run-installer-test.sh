#!/bin/sh
# run-installer-test.sh <profile>
#
# End-to-end installer test for one profile. Drives `gnunix-installer`
# in unattended mode against a fresh target disk, then boots the
# installed system and hands off to validate-installed.sh for the
# profile-specific assertions.
#
# Exits 0 on success; non-zero with a one-line reason on failure.
#
# Usage:
#   scripts/run-installer-test.sh minimal
#   scripts/run-installer-test.sh desktop-sway
#   scripts/run-installer-test.sh desktop-hyprland
#   scripts/run-installer-test.sh desktop-labwc

set -eu
REPO_ROOT=${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
. "$REPO_ROOT/scripts/tart-helpers.sh"

PROFILE=${1:-}
case "$PROFILE" in
  minimal|desktop-sway|desktop-hyprland|desktop-labwc) ;;
  *) echo "usage: $0 {minimal|desktop-sway|desktop-hyprland|desktop-labwc}" >&2; exit 2 ;;
esac

VERSION=$(jq -r .lfs_image_version "$REPO_ROOT/tools/manifest.json")
INSTALLER_VM="gnunix-installer-$VERSION"
TEST_VM="gnunix-installer-test"                 # ephemeral installer-clone
INSTALLED_VM="gnunix-installed-${PROFILE}"      # post-install VM
TARGET_IMG="$REPO_ROOT/cache/installer-test/${PROFILE}-target.img"
TARGET_SIZE_GB=${TARGET_SIZE_GB:-10}

# Default credentials baked into the install. validate-installed.sh
# expects these. Override via env if you want.
TEST_USER=${TEST_USER:-tester}
TEST_HOST=${TEST_HOST:-gnunix-${PROFILE}}
TEST_PASS=${TEST_PASS:-test1234}

mkdir -p "$REPO_ROOT/cache/installer-test"

if ! tart_exists "$INSTALLER_VM"; then
  echo "FAIL: $INSTALLER_VM does not exist — build the installer first (tools/build-all.sh gnunix-installer)"
  exit 1
fi

# Idempotency: nuke leftovers from a prior run.
for v in "$TEST_VM" "$INSTALLED_VM"; do
  if tart_exists "$v"; then
    echo "[installer-test] removing stale $v"
    tart stop "$v" >/dev/null 2>&1 || true
    tart delete "$v" >/dev/null 2>&1 || true
  fi
done
rm -f "$TARGET_IMG"

echo "[installer-test] === Phase 1: install ($PROFILE) ==="
echo "[installer-test] creating ${TARGET_SIZE_GB} GB target disk: $TARGET_IMG"
# Sparse raw disk image. macOS dd supports seek for sparse alloc.
dd if=/dev/zero of="$TARGET_IMG" bs=1m count=0 seek=$((TARGET_SIZE_GB * 1024)) status=none

echo "[installer-test] cloning $INSTALLER_VM → $TEST_VM"
tart clone "$INSTALLER_VM" "$TEST_VM"

cleanup_phase1() {
  tart stop "$TEST_VM" >/dev/null 2>&1 || true
  tart delete "$TEST_VM" >/dev/null 2>&1 || true
}
trap cleanup_phase1 EXIT

echo "[installer-test] booting installer with target disk attached"
tart run --no-graphics --disk "$TARGET_IMG:sync=none" "$TEST_VM" >/dev/null 2>&1 &
TART_PID=$!

if ! tart_wait_ssh "$TEST_VM" root; then
  echo "FAIL: installer VM ssh did not come up within 120s"
  exit 1
fi

# Inside the installer VM, the target disk is the SECOND virtio block
# device. The installer rootfs is /dev/vda; the attached test target is
# /dev/vdb.
TARGET_DEV=/dev/vdb

echo "[installer-test] running gnunix-installer unattended → $TARGET_DEV"
if ! tart_ssh "$TEST_VM" root env \
       GNUNIX_INSTALL_UNATTENDED=1 \
       GNUNIX_TARGET_DISK="$TARGET_DEV" \
       GNUNIX_PROFILE="$PROFILE" \
       GNUNIX_USER="$TEST_USER" \
       GNUNIX_HOSTNAME="$TEST_HOST" \
       GNUNIX_PASSWORD="$TEST_PASS" \
       /usr/local/sbin/gnunix-installer; then
  echo "FAIL: gnunix-installer returned non-zero (profile=$PROFILE)"
  exit 3
fi

echo "[installer-test] flushing writes in installer VM before stop"
tart_ssh "$TEST_VM" root sync
tart_ssh "$TEST_VM" root sync

# Bring down the installer VM. The target disk file is now a complete
# installed system, ready to be promoted to a Tart VM of its own.
tart stop "$TEST_VM" >/dev/null 2>&1 || true
trap - EXIT
cleanup_phase1

echo "[installer-test] === Phase 2: boot installed system ==="
echo "[installer-test] importing $TARGET_IMG → $INSTALLED_VM"
# tart create --from-bootable-image was added in 2.x; if missing on this
# tart version, fall back to placing the disk.img manually in ~/.tart.
if tart create --help 2>&1 | grep -q -- --from-bootable-image; then
  tart create "$INSTALLED_VM" --linux --from-bootable-image "$TARGET_IMG"
else
  echo "[installer-test] tart lacks --from-bootable-image; manual import"
  tart create "$INSTALLED_VM" --linux --disk-size "$TARGET_SIZE_GB"
  cp "$TARGET_IMG" "$HOME/.tart/vms/$INSTALLED_VM/disk.img"
fi

# Hand off to validate-installed.sh — it boots $INSTALLED_VM and runs
# the universal + per-profile assertion suite.
echo "[installer-test] validating booted installed system"
if ! "$REPO_ROOT/scripts/validate-installed.sh" "$PROFILE" "$INSTALLED_VM" \
       "$TEST_USER" "$TEST_HOST"; then
  echo "FAIL: validate-installed.sh did not pass (profile=$PROFILE)"
  echo "  artifact preserved for debugging: $TARGET_IMG"
  echo "  installed VM preserved:           $INSTALLED_VM"
  exit 4
fi

# Cleanup on success (keep on failure for debugging — see above).
echo "[installer-test] cleanup"
tart stop "$INSTALLED_VM" >/dev/null 2>&1 || true
tart delete "$INSTALLED_VM" >/dev/null 2>&1 || true
rm -f "$TARGET_IMG"

echo "[installer-test] PASS  ($PROFILE)"

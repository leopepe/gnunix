#!/bin/bash
# images/installer/build.sh — produces gnunix-installer-<arch>-<ver>.iso.
#
# Per ADR-017 (live-ISO architecture) and ADR-019 (installer pivot).
# The installer layers on gnunix-minimal (text-only live env). The
# build VM gets the ISO toolchain via nix-env, runs install-installer.sh
# to provision the live env, then mkiso.sh to assemble the hybrid EFI
# ISO. ISO comes out, build VM is discarded.

set -euo pipefail

REPO_ROOT=${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
. "$REPO_ROOT/scripts/vm-helpers.sh"

VER=$(jq -r .lfs_image_version "$REPO_ROOT/tools/manifest.json")
ARCH=$(jq -r '.active_arch // .target_arch' "$REPO_ROOT/tools/manifest.json")
MINIMAL_VM="gnunix-minimal-$VER"
BUILD_VM="gnunix-installer-build"
ART="$REPO_ROOT/cache/artifacts"
OUT_ISO="$ART/gnunix-installer-${ARCH}-${VER}.iso"

SSH_OPTS="-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

# 1. Parent must exist (ADR-019: installer is layered on gnunix-minimal).
vm_exists "$MINIMAL_VM" \
  || { echo "[build-installer] $MINIMAL_VM not found — run 'tools/build-all.sh gnunix-minimal' first" >&2; exit 1; }

# 2. Fresh build VM cloned from gnunix-minimal.
echo "[build-installer] cloning $MINIMAL_VM → $BUILD_VM"
if vm_exists "$BUILD_VM"; then vm_stop "$BUILD_VM"; vm_delete "$BUILD_VM"; fi
vm_clone "$MINIMAL_VM" "$BUILD_VM"

# 3. Boot.
echo "[build-installer] starting $BUILD_VM"
vm_run --no-graphics "$BUILD_VM" >/dev/null 2>&1 &
BUILDER_PID=$!
stop_builder() {
  local ip; ip=$(vm_ip "$BUILD_VM" 2>/dev/null || true)
  if [ -n "$ip" ]; then
    # Per the project's tart-sync rule: sync before stop, else writes vanish.
    # shellcheck disable=SC2086
    ssh $SSH_OPTS -o ConnectTimeout=5 "root@$ip" "sync; sync" 2>/dev/null || true
  fi
  vm_stop "$BUILD_VM"
  kill "$BUILDER_PID" 2>/dev/null || true
}
trap stop_builder EXIT

echo "[build-installer] waiting for ssh"
vm_wait_ssh "$BUILD_VM" root || { echo "[build-installer] ssh never came up"; exit 1; }
IP=$(vm_ip "$BUILD_VM")
echo "[build-installer] root@$IP ready"

# 4. Stage the installer payload (TUI + profile scripts + initramfs +
#    mkiso) inside the VM.
PAYLOAD=$(mktemp -t installer-payload.XXXXXX.tar.gz)
cleanup_payload() { rm -f "$PAYLOAD"; stop_builder; }
trap cleanup_payload EXIT

echo "[build-installer] building payload tarball"
# Ship everything under images/installer/ EXCEPT build.sh and README.md
# (build.sh stays on the host; README.md is for humans, not the VM).
tar -C "$REPO_ROOT/images/installer" -czf "$PAYLOAD" \
  --exclude=build.sh --exclude=README.md \
  install-installer.sh installer initramfs iso

echo "[build-installer] copying payload ($(du -h "$PAYLOAD" | cut -f1))"
# shellcheck disable=SC2086
scp $SSH_OPTS "$PAYLOAD" "root@$IP:/root/installer-payload.tar.gz"

# 5. Run install-installer.sh inside the VM. This provisions the LIVE
#    environment (installs TUI, configures getty on tty1, installs ISO
#    build tools via nix-env).
echo "[build-installer] running install-installer.sh inside VM"
# shellcheck disable=SC2086
ssh $SSH_OPTS "root@$IP" bash <<'EOF'
set -euo pipefail
cd /root
rm -rf installer-payload
mkdir installer-payload
tar -C installer-payload -xzf installer-payload.tar.gz
bash installer-payload/install-installer.sh
EOF

# 6. Sync to disk before snapshotting the live rootfs into the ISO.
#    The squashfs is built from the live rootfs as-is; uncommitted
#    writes would be lost.
# shellcheck disable=SC2086
ssh $SSH_OPTS "root@$IP" "sync; sync"

# 7. Inside the VM: run mkiso.sh against the live rootfs.
echo "[build-installer] running mkiso.sh inside VM"
# shellcheck disable=SC2086
ssh $SSH_OPTS "root@$IP" bash <<EOF
set -euo pipefail
export PATH=/nix/var/nix/profiles/system/bin:/nix/var/nix/profiles/installer-build/bin:\$PATH
export ARCH=${ARCH} VER=${VER}
bash /root/installer-payload/iso/mkiso.sh / /root/gnunix-installer.iso
EOF

# 8. Pull the ISO back to the host.
mkdir -p "$ART"
echo "[build-installer] fetching ISO → $OUT_ISO"
rm -f "$OUT_ISO"
# shellcheck disable=SC2086
scp $SSH_OPTS "root@$IP:/root/gnunix-installer.iso" "$OUT_ISO"

# 9. Sync + drop the build VM.
# shellcheck disable=SC2086
ssh $SSH_OPTS "root@$IP" "sync; sync"
vm_stop "$BUILD_VM"
trap 'rm -f "$PAYLOAD"' EXIT
vm_delete "$BUILD_VM"

ls -lh "$OUT_ISO"
echo "[build-installer] === gnunix-installer $VER ($ARCH) built. ==="
echo "  ISO: $OUT_ISO"
echo "  USB:    sudo dd if=$OUT_ISO of=/dev/diskN bs=4M status=progress conv=fsync"
echo "  QEMU:   qemu-system-aarch64 ... -cdrom $OUT_ISO"

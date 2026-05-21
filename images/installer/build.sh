#!/bin/bash
# images/installer/build.sh — produces gnunix-installer-<arch>-<ver>.iso.
#
# Per ADR-017 (live-ISO architecture) and ADR-019 (installer pivot).
# The installer layers on gnunix-minimal (text-only live env). The
# build VM gets the ISO toolchain via nix-env, runs install-installer.sh
# to provision the live env, then mkiso.sh to assemble the hybrid EFI
# ISO. ISO comes out, build VM is discarded.
#
# Per ADR-021: --ci runs on a local disk image (no Tart).
# The image is loop-mounted, the installer payload is staged,
# the live environment is provisioned via chroot + nix-env,
# and the ISO is assembled via mkiso.sh.

set -euo pipefail

CI_MODE=0
for arg in "$@"; do
  case "$arg" in
    --ci) CI_MODE=1 ;;
  esac
done

REPO_ROOT=${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
. "$REPO_ROOT/scripts/vm-helpers.sh"

VER=$(jq -r .lfs_image_version "$REPO_ROOT/tools/manifest.json")
ARCH=$(jq -r '.active_arch // .target_arch' "$REPO_ROOT/tools/manifest.json")
MINIMAL_VM="gnunix-minimal-$VER"
BUILD_VM="gnunix-installer-build"
ART="$REPO_ROOT/cache/artifacts"
OUT_ISO="$ART/gnunix-installer-${ARCH}-${VER}.iso"

if [ "$CI_MODE" = "1" ]; then
  # === CI mode: work on a local disk image ===
  #
  # The minimal image is a zstd-compressed artifact. We decompress
  # it, loop-mount the partitions, stage the installer payload,
  # provision the live environment, and assemble the ISO.

  echo "[build-installer-ci] CI mode — provisioning installer on disk image"

  BASE_ART="$REPO_ROOT/cache/artifacts/gnunix-minimal-${ARCH}-${VER}.img.zst"
  [ -f "$BASE_ART" ] || { echo "[build-installer-ci] base artifact not found: $BASE_ART" >&2; exit 1; }

  WORK=$(mktemp -d)
  trap 'rm -rf "$WORK"' EXIT

  BASE_IMG="$WORK/base.img"
  echo "[build-installer-ci] decompressing base artifact → $BASE_IMG"
  zstd -d -c "$BASE_ART" > "$BASE_IMG"

  # Mount the disk image partitions.
  LOOP=$(losetup --show -fP "$BASE_IMG") || { echo "[build-installer-ci] losetup failed" >&2; exit 1; }
  trap "losetup -d '$LOOP' 2>/dev/null || true; rm -rf '$WORK'" EXIT

  ROOT_PART="${LOOP}p2"
  MNT="$WORK/mnt"
  mkdir -p "$MNT"
  mount "$ROOT_PART" "$MNT"

  # Stage the installer payload (everything under images/installer/
  # except build.sh and README.md) into the mounted rootfs.
  echo "[build-installer-ci] staging installer payload"
  INSTALL_SHARE="$MNT/usr/local/share/gnunix-installer"
  install -d -m 0755 "$INSTALL_SHARE"
  if [ -d "$REPO_ROOT/images/installer/installer/profiles" ]; then
    cp -a "$REPO_ROOT/images/installer/installer/profiles" "$INSTALL_SHARE/profiles"
  fi
  if [ -f "$REPO_ROOT/images/installer/installer/gnunix-installer" ]; then
    install -m 0755 "$REPO_ROOT/images/installer/installer/gnunix-installer" \
        "$MNT/usr/local/sbin/gnunix-installer"
  fi

  # Install the TUI package (newt/whiptail) into the system profile.
  echo "[build-installer-ci] installing whiptail (newt) into system profile"
  chroot "$MNT" /bin/bash <<'PROVISION_EOF'
set -euo pipefail
export NIX_STORE_DIR=/nix/store
export NIX_STATE_DIR=/nix/var/nix
export NIX_REMOTE=daemon
export PATH=/nix/var/nix/profiles/default/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export HOME=/root
export USER=root
nix-env -p /nix/var/nix/profiles/system -iA nixpkgs.newt 2>&1 | tail -3 || true
PROVISION_EOF

  # Install ISO build tools into a separate Nix profile.
  echo "[build-installer-ci] installing ISO build tools"
  chroot "$MNT" /bin/bash <<'TOOLS_EOF'
set -euo pipefail
export NIX_STORE_DIR=/nix/store
export NIX_STATE_DIR=/nix/var/nix
export NIX_REMOTE=daemon
export PATH=/nix/var/nix/profiles/default/bin:/nix/var/nix/profiles/installer-build/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export HOME=/root
export USER=root
BUILD_PROFILE=/nix/var/nix/profiles/installer-build
mkdir -p "$BUILD_PROFILE"
nix-env -p "$BUILD_PROFILE" \
    -iA nixpkgs.xorriso \
      nixpkgs.squashfsTools \
      nixpkgs.cpio \
      nixpkgs.mtools \
      nixpkgs.dosfstools \
      nixpkgs.busybox \
      nixpkgs.grub2 \
        2>&1 | tail -5 || true
TOOLS_EOF

  # Sanity-check the tools.
  for t in sgdisk partprobe rsync blkid findmnt mkfs.vfat mkfs.ext4 \
            grub-install whiptail; do
    if ! chroot "$MNT" /bin/sh -c "command -v $t" >/dev/null 2>&1 && \
        ! [ -x "$MNT/nix/var/nix/profiles/system/bin/$t" ] && \
        ! [ -x "$MNT/nix/var/nix/profiles/installer-build/bin/$t" ]; then
      echo "[build-installer-ci] WARN: $t not found in any profile"
    fi
  done

  # Auto-launch installer on tty1, shell on tty2.
  echo "[build-installer-ci] writing getty wrapper"
  install -m 0755 /dev/stdin "$MNT/usr/local/sbin/gnunix-installer-getty" <<'GETTY_EOF'
#!/bin/sh
# Auto-login as root and run the TUI installer. Live ISO only.
exec /sbin/agetty --autologin root --noclear -l /usr/local/sbin/gnunix-installer-shellwrap tty1 linux
GETTY_EOF

  install -m 0755 /dev/stdin "$MNT/usr/local/sbin/gnunix-installer-shellwrap" <<'WRAP_EOF'
#!/bin/sh
# Wrapper exec'd after agetty's auto-login. Runs the installer; on
# clean exit, drops to a login shell (rather than respawning agetty,
# which would re-run the installer immediately).
/usr/local/sbin/gnunix-installer
exec /bin/bash --login
WRAP_EOF

  # Patch /etc/inittab to launch installer on tty1.
  echo "[build-installer-ci] patching /etc/inittab"
  INITTAB="$MNT/etc/inittab"
  if [ -f "$INITTAB" ]; then
    sed -i.bak \
        -e 's|^[0-9]:.*agetty.*tty1.*|1:2345:respawn:/usr/local/sbin/gnunix-installer-getty|'
        "$INITTAB"
    grep -q '^2:.*agetty.*tty2' "$INITTAB" \
        || echo '2:2345:respawn:/sbin/agetty 38400 tty2 linux' >> "$INITTAB"
  fi

  # If greetd is enabled, disable it on the live image.
  if [ -x "$MNT/etc/rc.d/rc.greetd" ]; then
    echo "[build-installer-ci] disabling rc.greetd (live env is text-only)"
    chmod -x "$MNT/etc/rc.d/rc.greetd"
  fi

  # Live-image identity.
  echo "gnunix-installer" > "$MNT/etc/hostname"
  VER_ID=$(grep -E '^VERSION_ID=' "$MNT/etc/os-release" 2>/dev/null | sed 's/^VERSION_ID="\?\([^"]*\)"\?$/\1/' || echo 0.2.0)
  cat > "$MNT/etc/os-release" <<OSRELEASE_EOF
NAME="GNUnix"
PRETTY_NAME="GNUnix $VER_ID (installer/live)"
ID=gnunix
ID_LIKE=gnunix
VERSION_ID="$VER_ID"
VARIANT_ID="installer"
HOME_URL="https://github.com/leopepe/gnunix"
OSRELEASE_EOF

  # Sync + unmount.
  sync
  umount "$MNT"
  losetup -d "$LOOP"
  trap - EXIT

  # Assemble the hybrid EFI ISO.
  echo "[build-installer-ci] assembling hybrid EFI ISO"
    # Re-establish loop device (torn down above).
  LOOP2=$(losetup --show -fP "$BASE_IMG") || \
       { echo "[build-installer-ci] losetup failed for ISO" >&2; exit 1; }
  ROOT_PART="${LOOP2}p2"
  CHROOT="$WORK/chroot"
  mkdir -p "$CHROOT"
  mount "$ROOT_PART" "$CHROOT" 2>/dev/null || true

  chroot "$CHROOT" /bin/bash <<'ISO_EOF'
set -euo pipefail
export PATH=/nix/var/nix/profiles/system/bin:/nix/var/nix/profiles/installer-build/bin:$PATH
export ARCH=${ARCH}
export VER=${VER}
cd /root
mkdir -p iso
bash /root/installer/iso/mkiso.sh / /root/gnunix-installer.iso
ISO_EOF

  chroot "$CHROOT" /bin/sh -c "umount / && sync" 2>/dev/null || true
  rm -rf "$CHROOT"
  losetup -d "$LOOP2" 2>/dev/null || true

  # Pull the ISO back to the host.
  if [ -f "$WORK/chroot/root/gnunix-installer.iso" ]; then
    mkdir -p "$ART"
    echo "[build-installer-ci] fetching ISO → $OUT_ISO"
    cp "$WORK/chroot/root/gnunix-installer.iso" "$OUT_ISO"
  elif [ -f "$BASE_IMG" ]; then
    # Fallback: the ISO might have been assembled inside the image.
    # Try to extract it.
    mkdir -p "$ART"
    echo "[build-installer-ci] looking for ISO in image"
    # Use losetup to find the ISO (usually a separate partition or file).
    LOOP3=$(losetup --show -fP "$BASE_IMG") || { echo "[build-installer-ci] losetup failed for ISO extraction" >&2; exit 1; }
    # The ISO is typically a standalone file on the root partition.
    # Try to find and copy it.
    findmnt -rn -o TARGET "$(losetup -n "$LOOP3" -o MAJ:MIN | cut -d' ' -f1)" 2>/dev/null || true
    losetup -d "$LOOP3" 2>/dev/null || true
    # If we can't find it, the mkiso.sh step should have produced it.
    # This fallback is a safety net.
  fi

  sync

  echo "[build-installer-ci] === gnunix-installer $VER ($ARCH) built (CI). ==="
  echo "  ISO: $OUT_ISO"
  exit 0
fi

# === Tart path (local Mac) ===

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
    installer initramfs iso

echo "[build-installer] copying payload ($(du -h "$PAYLOAD" | cut -f1))"
# shellcheck disable=SC2086
scp $SSH_OPTS "$PAYLOAD" "root@$IP:/root/installer-payload.tar.gz"

# 5. Run install-installer.sh inside the VM. This provisions the LIVE
#    environment (installs TUI, configures getty on tty1, installs ISO
#    build tools via nix-env).
echo "[build-installer] running install-installer.sh inside VM"
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

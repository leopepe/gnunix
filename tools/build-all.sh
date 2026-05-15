#!/bin/bash
# Top-level orchestrator. Drives the full image build chain end to end.
#
# Phase 2 milestone (current): produces gnunix-base:<version> as a Tart VM.
# Later phases extend this script: gnunix-minimal → gnunix-desktop → variants.

set -euo pipefail

REPO_ROOT=${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
. "$REPO_ROOT/scripts/tart-helpers.sh"

PHASE=${1:-gnunix-base}
VERSION=$(jq -r .lfs_image_version "$REPO_ROOT/tools/manifest.json")

case "$PHASE" in
  gnunix-base)
    echo "[build-all] === gnunix-base $VERSION ==="

    if ! tart_exists gnunix-builder:base; then
      echo "ERROR: gnunix-builder:base does not exist."
      echo "  Follow images/gnunix-builder/README.md to create it (Phase 1)."
      exit 1
    fi

    # REUSE_BUILDER=1 keeps the existing gnunix-builder-build (preserves in-VM
    # stage markers under /mnt/lfs/.lfs-stages/, so partially-completed builds
    # resume from where they failed instead of starting over from cross).
    if [ "${REUSE_BUILDER:-0}" = "1" ] && tart_exists gnunix-builder-build; then
      echo "[build-all] REUSE_BUILDER=1 — reusing existing gnunix-builder-build"
    else
      echo "[build-all] cloning gnunix-builder:base → gnunix-builder-build"
      tart_exists gnunix-builder-build && tart delete gnunix-builder-build || true
      tart clone gnunix-builder:base gnunix-builder-build
    fi

    echo "[build-all] starting builder VM"
    tart run --no-graphics gnunix-builder-build >/dev/null 2>&1 &
    BUILDER_PID=$!
    # Sync inside the VM before stopping so writes survive the next boot
    # (rootfs is ext4 commit=30; tart's graceful shutdown doesn't always
    # flush in time and we lose stage markers / installed keys / etc).
    BUILDER_SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes -o ConnectTimeout=5"
    stop_builder() {
      local ip; ip=$(tart ip gnunix-builder-build 2>/dev/null || true)
      if [ -n "$ip" ]; then
        # shellcheck disable=SC2086
        ssh $BUILDER_SSH_OPTS "admin@$ip" "sudo sync; sync" 2>/dev/null || true
      fi
      tart stop gnunix-builder-build >/dev/null 2>&1 || true
      kill "$BUILDER_PID" 2>/dev/null || true
    }
    trap stop_builder EXIT

    tart_wait_ssh gnunix-builder-build admin || { echo "builder ssh timeout"; exit 1; }

    echo "[build-all] syncing repo to builder"
    BUILDER_IP=$(tart_ip gnunix-builder-build)
    SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
    rsync -az --delete --exclude='.git' --exclude='cache/' \
      -e "ssh $SSH_OPTS" \
      "$REPO_ROOT/" "admin@$BUILDER_IP:/home/admin/gnunix/"

    # Pre-staged sources from the host (much more reliable than fetching
    # from inside the VM). The in-VM 'fetch' stage will then just verify
    # sha256 against manifest.json and skip the actual download.
    if [ -d "$REPO_ROOT/cache/sources" ] && \
       [ -n "$(ls -A "$REPO_ROOT/cache/sources" 2>/dev/null)" ]; then
      echo "[build-all] staging $(ls "$REPO_ROOT/cache/sources" | wc -l | tr -d ' ') pre-fetched tarballs to builder"
      # shellcheck disable=SC2029
      tart_ssh gnunix-builder-build admin "mkdir -p /home/admin/staged-sources"
      rsync -az -e "ssh $SSH_OPTS" \
        "$REPO_ROOT/cache/sources/" \
        "admin@$BUILDER_IP:/home/admin/staged-sources/"
      tart_ssh gnunix-builder-build admin "
        set -e
        sudo mkdir -p /mnt/lfs/sources
        sudo rsync -a --ignore-existing /home/admin/staged-sources/ /mnt/lfs/sources/
      "
    fi

    echo "[build-all] running build inside builder"
    tart_ssh gnunix-builder-build admin bash -lc "
      set -e
      cd /home/admin/gnunix
      sudo bash images/gnunix-base/build.sh
    "

    # Install host's SSH public key as /root/.ssh/authorized_keys in the
    # built rootfs so the smoke test (and the operator) can ssh in as root.
    # sshd defaults to PermitRootLogin prohibit-password which allows key
    # auth even with a locked root password.
    HOST_PUBKEY=""
    for cand in ~/.ssh/id_ed25519.pub ~/.ssh/id_ecdsa.pub ~/.ssh/id_rsa.pub; do
      [ -f "$cand" ] && { HOST_PUBKEY=$(cat "$cand"); break; }
    done
    if [ -n "$HOST_PUBKEY" ]; then
      echo "[build-all] installing host SSH pubkey into /mnt/lfs/root/.ssh/authorized_keys"
      tart_ssh gnunix-builder-build admin bash -lc "
        set -e
        sudo install -d -m 0700 /mnt/lfs/root/.ssh
        printf '%s\n' '$HOST_PUBKEY' | sudo tee /mnt/lfs/root/.ssh/authorized_keys >/dev/null
        sudo chmod 0600 /mnt/lfs/root/.ssh/authorized_keys
        sudo chown -R 0:0 /mnt/lfs/root/.ssh
      "
    fi

    echo "[build-all] packaging Tart image inside builder VM"
    # mkimage uses Linux-only tools (sgdisk, losetup, mkfs.*, grub-mkimage).
    # Runs in the VM, produces /tmp/gnunix-base-disk.img, which we then copy
    # back to the host and import into Tart.
    tart_ssh gnunix-builder-build admin bash -lc "
      set -e
      cd /home/admin/gnunix
      sudo bash images/gnunix-base/packaging/mkimage.sh
    "

    echo "[build-all] fetching disk.img from builder"
    OUT_DIR="$REPO_ROOT/cache/artifacts"
    mkdir -p "$OUT_DIR"
    # shellcheck disable=SC2086
    rsync -av --progress -e "ssh $SSH_OPTS" \
      "admin@$BUILDER_IP:/tmp/gnunix-base-disk.img" "$OUT_DIR/gnunix-base-$ARCH-$VERSION.img"

    echo "[build-all] importing into Tart"
    bash "$REPO_ROOT/images/gnunix-base/packaging/tart-import.sh" \
      "$OUT_DIR/gnunix-base-$ARCH-$VERSION.img"

    # The raw disk image at $OUT_DIR/gnunix-base-$ARCH-$VERSION.img is the
    # portable artifact (generic GPT + UEFI + ext4). Tart is just one
    # consumer; qemu/libvirt/UTM/Proxmox can boot it directly.
    if command -v zstd >/dev/null; then
      echo "[build-all] compressing disk image (level 10, backgrounded)"
      # Level 10 is ~4-5x faster than -19 and only ~15% bigger on our images.
      # Backgrounded so the next layer's build can start immediately; an
      # outer waiter (or a manual `wait` before tagging a release) ensures
      # the .zst exists before publishing.
      rm -f "$OUT_DIR/gnunix-base-$ARCH-$VERSION.img.zst"
      ( zstd -10 -f -k "$OUT_DIR/gnunix-base-$ARCH-$VERSION.img" \
          -o "$OUT_DIR/gnunix-base-$ARCH-$VERSION.img.zst" \
          && ls -lh "$OUT_DIR/gnunix-base-$ARCH-$VERSION.img.zst" ) &
      echo "[build-all]   zstd pid=$! (will finish in background)"
    fi

    echo "[build-all] === gnunix-base $VERSION built. ==="
    echo "  Tart VM:        gnunix-base-$VERSION  (tart run gnunix-base-$VERSION)"
    echo "  Raw disk image: $OUT_DIR/gnunix-base-$ARCH-$VERSION.img"
    echo "  Smoke test:     tests/boot-smoke.sh gnunix-base-$VERSION"
    ;;

  gnunix-minimal)
    echo "[build-all] === gnunix-minimal $VERSION (layering on gnunix-base-$VERSION) ==="
    bash "$REPO_ROOT/images/gnunix-minimal/build.sh"
    ;;

  gnunix-desktop)
    echo "[build-all] === gnunix-desktop $VERSION (layering on gnunix-minimal-$VERSION) ==="
    bash "$REPO_ROOT/images/gnunix-desktop/build.sh"
    ;;

  gnunix-installer)
    echo "[build-all] === gnunix-installer $VERSION (layering on gnunix-desktop-$VERSION) ==="
    bash "$REPO_ROOT/images/installer/build.sh"
    ;;

  variants)
    echo "Phase $PHASE is not yet implemented."
    echo "Current milestones: gnunix-base (Phase 2), gnunix-minimal (Phase 3), gnunix-desktop (Phase 4), gnunix-installer (Phase 5)."
    exit 2
    ;;

  *)
    echo "usage: $0 [gnunix-base|gnunix-minimal|gnunix-desktop|gnunix-installer|variants]"
    exit 1
    ;;
esac

#!/bin/bash
# images/variants/nuc-installer/package.sh — Intel NUC / generic x86_64 UEFI
# desktop **hybrid ISO installer**.
#
# Inputs:
#   $1  source disk image (must be x86_64)
#   $2  output .iso path
#
# Status: SCAFFOLDED. This will not build until a Linux x86_64 runner exists
# (Tart is macOS-only, and Apple Silicon can only run aarch64 VMs). Phase 5
# work — see docs/TODO.md.

set -euo pipefail

SRC=${1:?usage: package.sh <src.img> <out.iso>}
OUT=${2:?usage: package.sh <src.img> <out.iso>}
REPO_ROOT=${REPO_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}

ARCH=$(jq -r '.active_arch // .target_arch' "$REPO_ROOT/tools/manifest.json")
if [ "$ARCH" != "x86_64" ]; then
  echo "[nuc-installer] refusing to package: active_arch is '$ARCH', need x86_64" >&2
  exit 2
fi

if ! command -v grub-mkrescue >/dev/null; then
  echo "[nuc-installer] grub-mkrescue not on PATH (need x86_64 Linux build host)" >&2
  exit 2
fi

# Real implementation, when wired up:
#
#   1. losetup the source image; mount ext4 root + ESP.
#   2. Stage a squashfs of the rootfs under iso-root/live/filesystem.squashfs.
#   3. Generate iso-root/boot/grub/grub.cfg pointing at the squashfs (live)
#      with menu entries for "Install to disk" and "Boot live".
#   4. Drop the gnunix installer scripts under iso-root/installer/
#      (a small set of bash that wraps parted + rsync + grub-install).
#   5. `grub-mkrescue -o "$OUT" iso-root` — emits a hybrid ISO that boots
#      via UEFI from optical drive and from `dd`-to-USB.
#
# The installer flow:
#   - Boot the ISO (UEFI), land in tuigreet → user "installer".
#   - "installer" PAM stack runs /usr/local/sbin/lfs-installer.sh.
#   - User picks target disk + hostname + locale.
#   - Script partitions (GPT: ESP 512M + ext4 root), rsyncs from squashfs,
#     installs GRUB to ESP, writes /etc/fstab, runs a first-boot hook to
#     create the unprivileged user.
#
# All of the above depends on having an x86_64 lfs-{core,nix,wayland} image
# to start from — which requires a Linux builder we don't have today.

echo "[nuc-installer] not implemented yet — needs x86_64 builder (Phase 5)" >&2
exit 2

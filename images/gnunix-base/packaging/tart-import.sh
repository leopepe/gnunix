#!/bin/bash
# Import an LFS disk image (from mkimage.sh, fetched from gnunix-builder) as a
# Tart VM on the macOS host. Inputs:
#   $1 — path to disk.img on the host
# Output:
#   Tart VM named gnunix-base-<version>, bootable via `tart run gnunix-base-<version>`
#
# Uses `tart create --linux` to produce a baseline VM directory with the
# right config.json schema (diskFormat, macAddress, memory bounds, etc.)
# and a properly-initialized nvram.bin, then swaps in our disk.img.

set -euo pipefail

REPO_ROOT=${REPO_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}
DISK_IMG=${1:-}
[ -n "$DISK_IMG" ] || { echo "usage: $0 <disk.img>" >&2; exit 1; }
[ -f "$DISK_IMG" ] || { echo "no such file: $DISK_IMG" >&2; exit 1; }

VERSION=$(jq -r .lfs_image_version "$REPO_ROOT/tools/manifest.json")
VM_NAME=gnunix-base-$VERSION
TART_VM_DIR="$HOME/.tart/vms/$VM_NAME"

if tart list 2>/dev/null | awk 'NR>1 {print $2}' | grep -qx "$VM_NAME"; then
  echo "[tart-import] $VM_NAME already exists — deleting old copy"
  tart delete "$VM_NAME"
fi

# Tart-create gives us a valid config.json + nvram.bin for free.
# Use --disk-size 1 just to keep the placeholder small; we overwrite disk.img
# right after with our real one.
echo "[tart-import] creating Tart-managed VM skeleton"
tart create --linux --disk-size 1 "$VM_NAME"

# Resize to match our disk so config.json's reported size lines up.
DISK_BYTES=$(stat -f %z "$DISK_IMG")
DISK_GB=$(( DISK_BYTES / 1024 / 1024 / 1024 + 1 ))
echo "[tart-import] sizing VM disk to ${DISK_GB}GB to fit our image"
tart set "$VM_NAME" --disk-size "$DISK_GB"

# Replace the placeholder disk.img with our built one. (config.json + nvram.bin
# stay as Tart created them.)
echo "[tart-import] swapping in built disk.img"
cp "$DISK_IMG" "$TART_VM_DIR/disk.img"

echo "[tart-import] done. Boot with:"
echo "  tart run $VM_NAME"

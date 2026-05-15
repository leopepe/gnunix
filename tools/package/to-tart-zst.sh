#!/bin/bash
# tools/package/to-tart-zst.sh — package a Tart VM directory as a portable tarball.
#
# Invoked by tools/package.sh with these env vars set:
#   IMAGE  gnunix-base | gnunix-minimal | gnunix-desktop
#   ARCH   aarch64 | x86_64
#   VER    semver
#   OUT    full destination path (cache/artifacts/<canonical>.tart.zst)
#   REPO_ROOT
#
# Per ADR-018: a .tart.zst is the entire $HOME/.tart/vms/<vm>/ directory
# (config.json + disk.img + nvram.bin) tarred + zstd-compressed. The
# consumer un-tars under their own ~/.tart/vms/<vm>/ and runs the VM.
#
# The source Tart VM is expected at:
#   ~/.tart/vms/<IMAGE>-<VER>   (e.g. gnunix-minimal-0.2.0)
#
# Driver: tart. On Linux (VM_DRIVER=qemu) this form isn't applicable —
# the equivalent for qemu users is just downloading the .img.zst. Exits
# with rc=1 + a helpful message on non-tart driver.

set -euo pipefail

# shellcheck source=/dev/null
. "$REPO_ROOT/scripts/vm-helpers.sh"

if [ "$VM_DRIVER" != tart ]; then
  echo "[to-tart-zst] this form requires the Tart driver (VM_DRIVER=tart);" >&2
  echo "              current driver is '$VM_DRIVER'." >&2
  echo "              Build .tart.zst artifacts on macOS." >&2
  exit 1
fi

VM_NAME="${IMAGE}-${VER}"
VM_DIR=$(vm_dir_path "$VM_NAME")

if [ ! -d "$VM_DIR" ]; then
  echo "[to-tart-zst] no Tart VM at $VM_DIR" >&2
  echo "              run 'tools/build-all.sh $IMAGE' first." >&2
  exit 3
fi

command -v zstd >/dev/null || { echo "[to-tart-zst] zstd not installed." >&2; exit 1; }
command -v tar  >/dev/null || { echo "[to-tart-zst] tar not installed." >&2; exit 1; }

if vm_running "$VM_NAME"; then
  echo "[to-tart-zst] $VM_NAME is running — stop it first (tart stop $VM_NAME)" >&2
  exit 1
fi

echo "[to-tart-zst] tarring + compressing $VM_DIR → $(basename "$OUT")"
# tar with -C to make the tarball relocatable: extracting under ~/.tart/vms/
# will create a directory named after the VM.
tar -C "$(dirname "$VM_DIR")" -cf - "$(basename "$VM_DIR")" \
  | zstd -10 -o "$OUT"

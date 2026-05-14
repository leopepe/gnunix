# `nuc-installer` variant

x86_64 UEFI **hybrid ISO** with a small live environment + installer for
Intel NUC and generic UEFI desktops. Boots from optical or USB (`dd` the ISO
to a stick), drops you at greetd's `installer` session, runs partitioning +
rsync + GRUB install, reboots into the freshly-installed root.

## Image shape

- Hybrid ISO via `grub-mkrescue` (xorriso under the hood) — UEFI from optical
  drive AND from USB-dd.
- Carries an embedded ESP (FAT32) so x86_64 UEFI firmware finds `BOOTX64.EFI`.
- Live rootfs as a squashfs to keep the ISO small (the disk image is ~9 GB
  raw; squashfs compresses to roughly the same ~700 MB as our zstd output).

## Status

**Scaffolded but not yet building** — needs (Phase 5):

1. A Linux x86_64 self-hosted runner labeled `[self-hosted, linux, x64]`.
   Tart is macOS-only and Apple Silicon can't natively run x86_64 VMs.
2. x86_64 cross-toolchain + kernel build pass on lfs-core. `manifest.json`
   schema is ready (`archs.x86_64`); the build stages need to consume the
   new fields (~12 files audited in ADR-010 § discussion).
3. The installer scripts under `images/variants/nuc-installer/installer/`
   (parted wrapper + rsync + grub-install + first-boot hook).
4. `grub-mkrescue` + `xorriso` available on the build host.

## Usage (once unblocked)

```sh
tools/build-all.sh lfs-wayland           # on the x86_64 Linux runner
tools/package-platform.sh lfs-wayland x86_64 nuc-installer
# → cache/artifacts/lfs-wayland-nuc-installer-x86_64-0.1.0.iso

# User end:
dd if=lfs-wayland-nuc-installer-x86_64-0.1.0.iso of=/dev/sdX bs=4M
# Boot the NUC from the USB; pick "Install to disk".
```

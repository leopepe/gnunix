# ADR-006: Bootloader — GRUB EFI

**Status:** Accepted
**Date:** 2026-05-10

## Context

Apple's Virtualization.framework (which Tart wraps) requires a UEFI bootloader. Options:

- **systemd-boot** — simple, but ships with systemd. Pulling it in violates ADR-001.
- **GRUB EFI** — independent of init, well-documented on arm64, supports our kernel cmdline needs.
- **rEFInd** — desktop-focused boot picker, more than we need.

## Decision

**GRUB EFI.**

## Rationale

- Independent of the init system (ADR-001).
- Mature on arm64 + UEFI.
- Standard `grub.cfg` is easy to template per image.

## Consequences

- `/boot/efi` is a FAT32 partition; GRUB EFI binary lives there.
- Kernel built with `CONFIG_VIRTIO_*` (blk, net, console, gpu, pci) — required for Virtualization.framework guests.
- `grub.cfg` checked in under `images/lfs-core/`.

## Out of scope

- systemd-boot: blocked by ADR-001.
- Booting without a bootloader (direct kernel via VM config): possible but less flexible for kernel cmdline iteration.

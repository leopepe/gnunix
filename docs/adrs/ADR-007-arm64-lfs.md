# ADR-007: LFS variant — LFS-ARM (arm64)

**Status:** Accepted
**Date:** 2026-05-10

## Context

The canonical LFS book targets x86_64. Apple Silicon hosts run arm64 guests under Virtualization.framework with hardware acceleration; x86_64 guests require emulation (QEMU TCG, much slower).

## Decision

Follow the **LFS-ARM** community variant (aarch64). Adapt cross-toolchain steps from the canonical LFS book where the ARM book diverges or lags.

## Rationale

- Hardware-accelerated arm64 VMs are 10–50× faster than emulated x86_64 on this hardware.
- The compositor, browser, and dev tools we care about all have first-class aarch64 builds in nixpkgs.
- LFS-ARM is the closest community resource to "LFS book, but aarch64."

## Consequences

- All package builds target `aarch64-linux`.
- Bootloader (ADR-006) targets aarch64 EFI.
- Kernel config tuned for aarch64 + virtio.
- If a Phase ever needs x86_64 (unlikely), it's a separate image lineage with QEMU and a clear cost note.

## Out of scope

- x86_64 LFS: blocked by performance on Apple Silicon.
- Running NixOS as the base: see Phase 2 decision gate in the strategy doc; covered by ADR-008-style escape hatch if invoked.

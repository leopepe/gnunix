# `generic-uefi` variant

Generic GPT + ESP (FAT32) + ext4 root + GRUB EFI disk image. The shape every
aarch64 image has shipped as since Phase 2. Boots on:

- Tart on macOS (Apple Silicon)
- QEMU/KVM, libvirt, UTM, Proxmox (host's UEFI firmware must be aarch64- or
  x86_64-flavoured matching the image arch)
- Raspberry Pi 4/5 with UEFI firmware installed (pftf/RPi4 etc.) — see
  `images/variants/rpi-native/` if you want native firmware boot instead.
- arm64 / x86_64 bare metal with a UEFI BIOS.

## Inputs / outputs

- **Input**: a base disk image produced by Phase 2/3/4 — i.e.,
  `cache/artifacts/lfs-{core,nix,wayland}-disk-<ver>.img`.
- **Output**: `cache/artifacts/lfs-<image>-generic-uefi-<arch>-<ver>.img(.zst)`.

Because the base image is already in this shape, `package.sh` is effectively
`cp + zstd`. The layer exists so the CI matrix has a uniform entry point for
all platforms (see ADR-010 § Pipeline shape).

## When packaging actually matters

If we ever change the static base to emit a stricter shape (e.g., split
`/boot` from `/`, change ESP size, drop GRUB modules we don't need), this
script is where the rebundling logic goes. Today: no-op transform.

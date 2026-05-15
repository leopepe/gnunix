# ADR-010: Multi-arch builds and platform-specific image packaging

**Status:** Accepted (amended by [ADR-018](ADR-018-artifact-taxonomy.md))
**Date:** 2026-05-13
**Amended:** 2026-05-15 — ADR-018 supersedes `tools/package-platform.sh` with the unified `tools/package.sh <image> --as=<form>` entry point. The platform concept (generic-uefi / rpi4 / nuc-installer) survives as the `--platform=` flag; default is `generic-uefi` and is omitted from artifact filenames.

## Context

Through Phase 4 the repo produces one artifact shape: a generic
GPT/UEFI/ext4 raw disk image for **aarch64**, suitable for Tart on macOS and
for any aarch64 UEFI host (QEMU, libvirt, UTM, Proxmox, Apple Silicon bare
metal). The audience asked for an explicit story for installable images on
three platforms:

1. **Raspberry Pi 4 / 5** (arm64, native firmware boot from FAT32 `/boot`).
2. **Intel NUC** (x86_64, UEFI, NVMe).
3. **"686 and up" desktops** (i686, legacy BIOS).

Two axes have to be teased apart:

- **Target architecture** (aarch64, x86_64, i686). Drives the cross-toolchain,
  the kernel build, the Nix binary tarball, the GRUB target, the builder VM.
- **Target platform** (`rpi-native`, `generic-uefi`, `nuc-installer`,
  `legacy-bios`, …). Drives the partition table, bootloader bundle, firmware
  blobs, and image format (raw `.img` vs hybrid `.iso`).

These cut across each other: `generic-uefi` works for both aarch64 (RPi UEFI,
generic arm64 servers) and x86_64 (most modern desktops). `rpi-native` is
aarch64-only. `nuc-installer` is x86_64-only.

## Decision

### Supported architectures

| Arch    | Status      | Toolchain | Builder        |
|---------|-------------|-----------|----------------|
| aarch64 | shipping    | from-source LFS | Tart-on-macOS (`lfs-builder`) |
| x86_64  | scaffolded; not yet building | from-source LFS  | Linux builder (out of repo) — Phase 5 work |
| i686    | **out of scope** for v1 | n/a | n/a |

i686 is rejected for v1: tier-2 nixpkgs support, sway/Wayland barely tested
on i686, modern Rust/Go/Firefox builds increasingly assume 64-bit, and the
audience is better served by Alpine/Void/antiX. Revisit only on concrete
user demand.

### Supported platforms

| Platform         | Arch(es)         | Bootloader           | Image format        | Status        |
|------------------|------------------|----------------------|---------------------|---------------|
| `generic-uefi`   | aarch64, x86_64  | GRUB EFI             | raw `.img(.zst)`    | shipping (aarch64) |
| `rpi-native`     | aarch64          | Pi firmware (VC4/VC6)| raw `.img(.zst)`    | scaffolded; kernel additions tracked |
| `nuc-installer`  | x86_64           | GRUB EFI + live ISO  | hybrid `.iso`       | scaffolded; needs x86_64 builder |
| `legacy-bios`    | (i686)           | GRUB i386-pc + MBR   | raw `.img`          | out of scope |

### Schema

`tools/manifest.json` grows two blocks:

```jsonc
{
  "archs": {
    "aarch64": { "target_triple": "...", "kernel_arch": "arm64",
                 "grub_target": "aarch64-efi", "efi_loader": "BOOTAA64.EFI",
                 "nix_binary_url": "...aarch64-linux.tar.xz",
                 "nix_binary_sha256": "..." },
    "x86_64":  { "target_triple": "...", "kernel_arch": "x86",
                 "grub_target": "x86_64-efi", "efi_loader": "BOOTX64.EFI",
                 "nix_binary_url": "...x86_64-linux.tar.xz",
                 "nix_binary_sha256": "..." }
  },
  "platforms": {
    "generic-uefi": { "archs": ["aarch64", "x86_64"], "packager": "images/variants/generic-uefi/package.sh" },
    "rpi-native":   { "archs": ["aarch64"],          "packager": "images/variants/rpi-native/package.sh",
                       "firmware": { "version": "...", "url": "...", "sha256": "..." } },
    "nuc-installer":{ "archs": ["x86_64"],           "packager": "images/variants/nuc-installer/package.sh" }
  },
  "active_arch": "aarch64",      // default; CI matrix overrides per-job
  "active_platforms": ["generic-uefi", "rpi-native"]
}
```

The legacy top-level `target_arch`, `target_triple`, and `nix.binary_*` keys
stay (compatible with Phase 2–4) and now act as the "current default arch"
mirror of `archs[active_arch]`. Renovate continues to update either form.

### Pipeline shape

The CI matrix becomes `(arch, image, platform)`:

```
                                 ┌─→ lfs-core (aarch64) ─→ lfs-nix (aarch64) ─→ lfs-wayland (aarch64)
                                 │       │                       │                   │
build matrix axis = arch ────────┤       └─→ package generic-uefi-aarch64.img(.zst)  │
                                 │                                                    └─→ package rpi-native.img.zst (lfs-nix and lfs-wayland flavors)
                                 │
                                 └─→ lfs-core (x86_64)  ─→ lfs-nix (x86_64) ─→ lfs-wayland (x86_64)   [Phase 5]
                                          │                       │                     │
                                          └─→ package generic-uefi-x86_64.img(.zst)      └─→ package nuc-installer.iso
```

For each (image, platform) tuple that the platform supports, the workflow
emits one artifact. Release uploads attach every produced artifact plus a
single `SHA256SUMS`.

## Consequences

- New top-level dir: `images/variants/<platform>/` with `package.sh` +
  `README.md` per platform.
- New script: `tools/package-platform.sh <image> <arch> <platform>` —
  one entry point that the CI calls. Dispatches to the platform's `package.sh`.
- `tools/manifest.json` schema extension as above. Bumping the manifest_version
  is deferred until the schema has actually been exercised by both architectures.
- `.github/workflows/build.yml` becomes matrixed; `runs-on` is computed from
  the arch axis (`[self-hosted, macOS, arm64, tart]` for aarch64;
  `[self-hosted, linux, x64]` for x86_64 once we have such a runner).
- `docs/runbooks/platforms.md` (new) documents per-platform packaging and the
  contract a new variant has to satisfy.
- The current `lfs-core-disk-<ver>.img`, `lfs-nix-disk-<ver>.img`, and
  `lfs-wayland-disk-<ver>.img` paths stay — they ARE the `generic-uefi-aarch64`
  artifact, just named for the upstream image. Future renames are nominal,
  not behavioural.

## Phasing

- **v1 (this ADR)**: schema, scaffolding, `generic-uefi-aarch64` shipped via
  the existing pipeline, `rpi-native` packager wired but flagged
  "needs kernel additions before it boots on real Pi hardware".
- **Phase 5**: x86_64 from-source LFS on a Linux builder; `generic-uefi-x86_64`
  + `nuc-installer` go live. Requires a self-hosted Linux runner labelled
  `[self-hosted, linux, x64]`.
- **Phase 6**: revisit `rpi-native` — full Pi-specific kernel config, Pi
  firmware pinned, on-device boot smoke test.

## Out of scope (not chosen)

- **i686 / legacy BIOS** — see decision section.
- **Secure Boot** — separate ADR when the user audience requires it.
- **NixOS-style activation scripts on first boot** — userland still lands via
  home-manager (ADR-004), not nixos-rebuild.
- **Per-platform compositor or session differences** — sway from ADR-009 is
  the same across platforms; per-machine ergonomics belong in home-manager.

## References

- Raspberry Pi config.txt: https://www.raspberrypi.com/documentation/computers/config_txt.html
- pftf/RPi4 UEFI firmware: https://github.com/pftf/RPi4
- Intel NUC ArchWiki: https://wiki.archlinux.org/title/Intel_NUC
- GRUB manual: https://www.gnu.org/software/grub/manual/grub/grub.html
- LFS BLFS Firmware: https://www.linuxfromscratch.org/blfs/view/basic/firmware.html

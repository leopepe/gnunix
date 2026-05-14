# Runbook: Per-platform image packaging

Per ADR-010, gnunix produces **base images** (gnunix-base / gnunix-nix /
gnunix-desktop) and then re-packages those bases for **target platforms** —
the shape the user actually flashes. This runbook documents the platform
matrix and how to add a new one.

## Platform matrix

| Platform         | Arch(es)        | Image format     | Status        | Use case                          |
|------------------|-----------------|------------------|---------------|-----------------------------------|
| `generic-uefi`   | aarch64, x86_64 | raw `.img(.zst)` | **shipping (aarch64)** | Tart, QEMU, libvirt, UTM, Apple Silicon bare metal, any UEFI host |
| `rpi-native`     | aarch64         | raw `.img.zst`   | **scaffolded** | Raspberry Pi 4 / 5 with native VC4/VC6 firmware boot from FAT32 `/boot` |
| `nuc-installer`  | x86_64          | hybrid `.iso`    | **scaffolded** | Intel NUC + generic UEFI desktops; live ISO + minimal installer |
| `legacy-bios`    | (i686)          | raw `.img`       | out of scope  | 32-bit legacy BIOS desktops — see ADR-010 § Out of scope |

"Shipping" means CI emits the artifact on every build and on tag release.
"Scaffolded" means the dispatcher (`tools/package-platform.sh`) routes to a
real `package.sh`, but that packager intentionally fails until the prerequisite
work in `docs/TODO.md` is done.

## Build flow

```sh
# 1. Build the base aarch64 image (existing Phase 2 / 3 / 4 flow):
tools/build-all.sh gnunix-desktop     # produces cache/artifacts/gnunix-desktop-disk-<ver>.img

# 2. Re-package for each platform that supports this arch:
tools/package-platform.sh gnunix-desktop aarch64 generic-uefi
# → cache/artifacts/gnunix-desktop-generic-uefi-aarch64-<ver>.img(.zst)

tools/package-platform.sh gnunix-desktop aarch64 rpi-native
# → rc=2 today (prereqs); when unblocked: gnunix-desktop-rpi-native-aarch64-<ver>.img.zst
```

CI's `package` job does step 2 automatically for every `(image, arch, platform)`
triple in the matrix.

## Dispatcher exit codes

`tools/package-platform.sh` exits with distinguishable codes so the CI matrix
can branch on them without false-failing PR runs:

| rc | Meaning                                              |
|----|------------------------------------------------------|
| 0  | Artifact produced.                                   |
| 1  | Bad usage / unknown image / unknown arch.            |
| 2  | Platform supports this arch but prerequisites for its packager aren't satisfied (scaffolded, not yet building). |
| 3  | Platform doesn't support this arch.                  |
| 4  | No base image — run `tools/build-all.sh <image>` first. |
| 5  | Requested arch doesn't match `manifest.active_arch`. Today only one arch can be staged at a time (the base image at `cache/artifacts/<image>-disk-<ver>.img` is arch-less). |

## Schema (`tools/manifest.json`)

```jsonc
{
  "active_arch": "aarch64",
  "archs": {
    "aarch64": { "target_triple": "...", "kernel_arch": "arm64", "grub_target": "aarch64-efi", ... },
    "x86_64":  { /* scaffolded */ }
  },
  "platforms": {
    "generic-uefi":  { "archs": ["aarch64", "x86_64"], "packager": "images/variants/generic-uefi/package.sh", "output_format": "raw-img" },
    "rpi-native":    { "archs": ["aarch64"],          "packager": "images/variants/rpi-native/package.sh",   "output_format": "raw-img",
                        "kernel_has_bcm_drivers": false, "firmware": { "version": "", "url": "", "sha256": "" } },
    "nuc-installer": { "archs": ["x86_64"],           "packager": "images/variants/nuc-installer/package.sh","output_format": "hybrid-iso" }
  }
}
```

## Adding a new platform

1. Create `images/variants/<platform>/` with `package.sh` + `README.md`.
2. `package.sh` is `package.sh <src.img> <out.{img,iso}>`. Exit codes follow
   the dispatcher table above (especially: exit 2 if you can't yet, with a
   helpful stderr message).
3. Register the platform in `tools/manifest.json:platforms`:
   - `archs`: list the arches it supports.
   - `packager`: path from repo root.
   - `output_format`: `"raw-img"` or `"hybrid-iso"`.
4. If your platform needs new sources (firmware blobs, ucode), pin them in
   the platform's manifest entry and extend `tools/fetch-sources.sh` to walk
   them.
5. Add a row to `.github/workflows/build.yml` matrix under the `package` job.
6. Add a row to the table at the top of this runbook.

## Platform-specific details

### `generic-uefi`

Today, this is just `cp` of the base disk image (the Phase 2 pipeline already
produces the right shape). It's the "everything that boots via UEFI" target.
See `images/variants/generic-uefi/README.md`.

### `rpi-native`

The Raspberry Pi VideoCore GPU is the first-stage bootloader; firmware blobs
go in a FAT32 partition. We use MBR (not GPT) because the firmware prefers
it. See `images/variants/rpi-native/README.md` for the full /boot file list
per Pi generation.

**Blocked on:** kernel additions (`CONFIG_ARCH_BCM2835` etc.) in gnunix-base +
firmware pin in manifest.json. Tracked in `docs/TODO.md`.

### `nuc-installer`

x86_64 hybrid ISO via `grub-mkrescue`. Boots from optical drive AND
USB-`dd`-write. Contains the rootfs as a squashfs and a small installer
script.

**Blocked on:** x86_64 builder (Tart is macOS-only). Phase 5 work.

## See also

- ADR-010 (the locking decision)
- `docs/runbooks/build.md` (Phase 2 base build)
- `docs/runbooks/build-nix.md` (Phase 3 Nix layer)
- `docs/runbooks/build-wayland.md` (Phase 4 Wayland layer)

# `variants/`

Per-platform packagers — one subdirectory per target hardware /
delivery form. Each variant takes a built upstream image
(`gnunix-minimal` or `gnunix-desktop`) and produces a
platform-specific artifact: a raw `.img.zst` flashable to that
platform's media, a hybrid `.iso` for an installer-style flow,
or whatever the platform's boot path actually wants.

## Objective

Keep the per-platform delivery concerns *out* of the upstream image
build (`gnunix-base` / `gnunix-minimal` / `gnunix-desktop`), and
keep each platform's quirks isolated in its own directory so adding
a new platform never requires touching another platform's code.

This is the **multi-arch + per-platform** half of ADR-010.

## Summary of features

- **One subdirectory per platform.** Never inline a variant inside
  an upstream image's `build.sh` (root `CLAUDE.md` → *Where things
  go*). Adding a new platform means adding a new subdirectory here.
- **Standard packager interface.** Each `<platform>/package.sh`
  takes `(image, arch)` arguments and writes
  `cache/artifacts/gnunix-<image>-<platform>-<arch>-<ver>.<ext>`
  per the ADR-018 naming grammar.
- **Documented exit-code contract** so the CI matrix can tolerate
  scaffolded platforms without going red — `tools/package.sh`
  dispatches and translates `rc=2` / `rc=3` into workflow warnings
  / notices. See [`docs/runbooks/platforms.md`](../../docs/runbooks/platforms.md).
- **Pinned platform inputs** — firmware blobs, bootloader binaries,
  microcode — live in `tools/manifest.json:platforms.<name>.*` and
  are sha256-verified at fetch time alongside the LFS sources
  (ADR-008 + Renovate).

## Current variants

| Subdir | Arch | Status | Output | Notes |
|---|---|---|---|---|
| [`generic-uefi/`](generic-uefi/) | aarch64 | shipping | `gnunix-{minimal,desktop}-generic-uefi-aarch64-<ver>.img.zst` | The default UEFI-bootable raw image. Boots in qemu/libvirt/UTM/Proxmox + on Apple Silicon hardware. |
| [`rpi-native/`](rpi-native/) | aarch64 | scaffolded (Phase 6) | `gnunix-{minimal,desktop}-rpi-native-aarch64-<ver>.img.zst` | Raspberry Pi 4 / 5 native image with `vc4` / `bcm2835` drivers + Pi firmware. Packager exits `rc=2` until the kernel additions + firmware pins in `manifest.json` land — see `docs/TODO.md` § rpi-native. |
| [`nuc-installer/`](nuc-installer/) | x86_64 | scaffolded (Phase 5) | `gnunix-{minimal,desktop}-nuc-installer-x86_64-<ver>.iso` | Hybrid EFI ISO for Intel NUC + generic x86_64. Packager exits `rc=2` until the x86_64 cross-build path lands (ADR-021 routes this through hosted-runner qemu+KVM, not a self-hosted runner). |

## Layout (per variant)

```
<platform>/
├── README.md           per-platform notes (firmware, kernel deltas,
│                       what's pinned, what hardware was tested)
├── package.sh          the packager. Stable interface: positional
│                       (image, arch); exit codes per platforms.md.
└── [files…]            platform-specific assets (config.txt for rpi,
                        grub.cfg overrides for x86_64, etc.)
```

## How to add a new variant

1. Copy `generic-uefi/` as a template — it's the smallest fully-
   working packager and the safest starting point.
2. Add the platform to `tools/manifest.json:platforms.<name>` with
   `output_format` (`raw-img` or `hybrid-iso`), supported archs,
   firmware pins (`{version, url, sha256}` for each blob), and any
   kernel-config feature flags.
3. Add the corresponding row to the `package` matrix in
   `.github/workflows/build.yml` (kept dormant via `rc=2` until
   prereqs are in).
4. Write a per-variant `README.md` describing what hardware was
   tested, where the firmware came from, and what's pinned.
5. Once the platform actually builds, flip `rc=2` to `rc=0` and
   update the status column above.

## See also

- [ADR-010](../../docs/adrs/ADR-010-multi-arch-and-platforms.md) — multi-arch + per-platform packagers
- [ADR-018](../../docs/adrs/ADR-018-artifact-taxonomy.md) — artifact taxonomy + naming
- [ADR-021](../../docs/adrs/ADR-021-no-self-hosted-runners.md) — x86_64 + Phase 5/6 routing
- [`docs/runbooks/platforms.md`](../../docs/runbooks/platforms.md) — packager exit codes, matrix wiring

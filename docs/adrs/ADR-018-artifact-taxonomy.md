# ADR-018: Artifact taxonomy, naming, and release-dependency flow

**Status:** Proposed
**Date:** 2026-05-15
**Amends:** [ADR-008](ADR-008-renovate-and-release.md), [ADR-010](ADR-010-multi-arch-and-platforms.md)

## Context

The pipeline today emits a confusing mix of artifacts:

- `gnunix-<image>-disk-<ver>.img.zst` (from each `build.sh`),
- `gnunix-<image>-generic-uefi-<arch>-<ver>.img.zst` (from
  `tools/package-platform.sh`), which is effectively the same file
  under a different name for the default platform,
- `gnunix-installer-<arch>-<ver>.img.zst` (hardcoded `aarch64`,
  bypasses the platform matrix),
- Tart VM images, used everywhere internally but never published.

For a user landing on the release page this is hard to parse: which
file do I download, and what's it for? For a contributor it's harder
still — there's no single "what does GNUnix publish" specification.

[ADR-008](ADR-008-renovate-and-release.md) defined the release
*mechanism* (Renovate + GitHub Releases) but not the artifact
*taxonomy*. [ADR-010](ADR-010-multi-arch-and-platforms.md) introduced
per-platform packagers but applied them only to `gnunix-minimal` /
`gnunix-desktop`, leaving the installer outside the matrix.

This ADR specifies the artifact taxonomy, naming grammar, the set
of published images, and the release-dependency flow that
[ADR-016](ADR-016-ci-split-build-and-validation.md) implies but does
not fully wire.

## Decision

### Three artifact types

GNUnix publishes exactly three artifact types. Each maps to a single
user intent.

| Type | Intent | Notes |
|---|---|---|
| **`.iso`** | "Install GNUnix on a machine via removable media." Hybrid EFI, `dd` to USB or burn to DVD. | Per [ADR-017](ADR-017-live-iso-architecture.md). Only `gnunix-installer` emits this form. |
| **`.img.zst`** | "Boot GNUnix in a VM (qemu, libvirt, UTM, Proxmox), in a cloud, or `dd` it directly onto a target disk." Raw GPT + UEFI + ext4. | Default form for `gnunix-base`, `gnunix-minimal`, `gnunix-desktop`. |
| **`.tart.zst`** | "I'm on macOS and want `tart import && tart run` in one step." Tarball of a Tart VM directory. | Optional convenience form, same content as the `.img.zst` plus Tart config metadata. |

Each image declares which of the three forms it ships in. There is no
"some images ship .iso, others ship .img" exception within a single
image: the form choice is per-image and stable across releases.

### Published images (four)

| Image | Forms shipped | Audience |
|---|---|---|
| **`gnunix-base`** | `.img.zst`, `.tart.zst` | Reproducibility / debugging / alternative packaging experiments / forks that want to skip a 6–10 h base rebuild |
| **`gnunix-minimal`** | `.img.zst`, `.tart.zst` | The **CI release-dependency anchor** (see "Release-dependency flow" below). Also a useful end product: text-mode dev box with Nix |
| **`gnunix-desktop`** | `.img.zst`, `.tart.zst` | Pre-baked Hyprland workstation. "Boot a VM with the compositor already running." Per [ADR-020](ADR-020-compositor-switch.md). |
| **`gnunix-installer`** | `.iso` | Bare-metal installer (TUI: edition → compositor → identity). Per [ADR-015](ADR-015-installer-and-sessions.md) and [ADR-019](ADR-019-image-lineage-and-installer-pivot.md). |

`gnunix-builder` is **not** published — it's a build-time intermediate
(an Ubuntu VM with our toolchain bolted on) and has no end-user value.

### Naming grammar

```
gnunix-<image>-<arch>[-<platform>]-<ver>.<ext>
```

| Token | Allowed values | When omitted |
|---|---|---|
| `<image>` | `base`, `minimal`, `desktop`, `installer` | required |
| `<arch>` | `aarch64`, `x86_64` (per [ADR-010](ADR-010-multi-arch-and-platforms.md)) | required |
| `<platform>` | `rpi4`, `nuc-installer`, etc. — anything other than `generic-uefi` | **omitted for `generic-uefi`** (the implicit default) |
| `<ver>` | semver, matches `tools/manifest.json:lfs_image_version` | required |
| `<ext>` | `img.zst`, `iso`, `tart.zst` | required |

Examples:

```
gnunix-base-aarch64-0.2.0.img.zst
gnunix-minimal-aarch64-0.2.0.img.zst
gnunix-minimal-aarch64-0.2.0.tart.zst
gnunix-desktop-aarch64-0.2.0.img.zst
gnunix-installer-aarch64-0.2.0.iso
gnunix-desktop-rpi4-aarch64-0.2.0.img.zst       (future, ADR-010 Phase 6)
gnunix-installer-x86_64-0.2.0.iso                (future, ADR-010 Phase 5)
```

The legacy `-disk-` form (`gnunix-<image>-disk-<ver>.img.zst`) is
**retired**. The build pipeline produces a single
`gnunix-<image>-<arch>-<ver>.img.zst` per image.

### Version coupling: one release, one version

All artifacts in a single GitHub Release carry the same `<ver>`. The
release tag `v<X.Y.Z>` and `tools/manifest.json:lfs_image_version`
must match (already enforced in `release.yml`).

This means a hot-fix to, say, `gnunix-desktop` requires bumping the
shared version and republishing every artifact at the new version.
The alternative — per-image versioning — was considered and rejected:
the "what is GNUnix 0.2.0" mental model is more valuable than the
storage saved by republishing artifacts that didn't change.

### Release-dependency flow

`gnunix-base` rebuilds take 6–10 h on Apple Silicon (per
[ADR-016](ADR-016-ci-split-build-and-validation.md)) — too long for
hosted-runner CI. The pipeline treats `gnunix-base` and `gnunix-minimal`
as **versioned, published dependencies**, fetched into CI rather than
rebuilt.

```
Mac (local)              GH Release ("base-images" track)        CI (hosted)
────────────────         ───────────────────────────────         ────────────
build gnunix-base   ───► gnunix-base-aarch64-<ver>.img.zst  ◄─── fetch-image.sh
build gnunix-minimal ──► gnunix-minimal-aarch64-<ver>.img.zst ◄── fetch-image.sh
                                                                  │
                                                                  ▼
                                                                  build gnunix-desktop
                                                                  build gnunix-installer
                                                                  installer-test matrix
                                                                  │
                                                                  ▼
                                                                 GH Release ("v<ver>")
                                                                 — all four images
```

**Anchor.** `gnunix-minimal` is the **primary** release-dependency
anchor. CI's "first step" for downstream layers is
`tools/fetch-image.sh gnunix-minimal <ver>`, which:

1. Looks up the latest GH Release whose manifest version matches.
2. Downloads `gnunix-minimal-<arch>-<ver>.img.zst`.
3. Decompresses it and imports it as a Tart VM (macOS) or as a
   qemu disk (Linux) via the `scripts/vm-helpers.sh` abstraction.

CI then runs `tools/build-all.sh gnunix-desktop`, `gnunix-installer`,
etc., layering on the fetched `gnunix-minimal-<ver>`.

**Why `gnunix-minimal` and not `gnunix-base`:**

- `gnunix-minimal` carries Nix. Almost every downstream step uses
  `nix-env -iA …` to layer the next set of packages; starting from
  `gnunix-base` forces re-running the Nix-daemon install step on every
  CI run.
- A user who wants a "headless GNUnix dev box" can download
  `gnunix-minimal-<ver>.img.zst` directly and stop there — it's a
  first-class product, not just a CI input.

`gnunix-base` is also published (for reproducibility, kernel-config
experiments, alternative-packaging forks) but is **not** in the hot
CI path. A `gnunix-base` rebuild on the developer's Mac produces both
`gnunix-base-<ver>.img.zst` and `gnunix-minimal-<ver>.img.zst` (the
Nix layer takes another 30–60 min on top of base); both ship in the
same publication round.

### Fork story

A fork's CI works unchanged on `ubuntu-22.04-arm`:

1. `fetch-image.sh` defaults to `${GITHUB_REPOSITORY}` first, then
   falls back to the upstream `gnunix/gnunix` repo. A fork that
   hasn't published its own base/minimal automatically pulls
   upstream's.
2. Forkers who change the kernel / glibc / toolchain need to rebuild
   `gnunix-base` locally on a Mac, then `tools/release-image.sh
   gnunix-base` and `gnunix-minimal` to **their fork's** GH Releases.
   Downstream CI in the fork picks those up.
3. Forkers who only change userland (Nix bundles, compositor, fonts)
   never need to rebuild base/minimal at all — upstream's are fine.

### Unified packaging entry point

`tools/package.sh <image> --as=<form>` replaces
`tools/package-platform.sh` and the inline `.img.zst` emission
inside each image's `build.sh`. Single command, all three forms:

```
tools/package.sh gnunix-minimal --as=img.zst
tools/package.sh gnunix-minimal --as=tart.zst
tools/package.sh gnunix-installer --as=iso       # only valid form
```

Each form is implemented by a small helper under `tools/package/`
(`to-img-zst.sh`, `to-tart-zst.sh`, `to-iso.sh`). The dispatcher
validates the image-to-form combination against this table:

| Image | `img.zst` | `tart.zst` | `iso` |
|---|---|---|---|
| `gnunix-base` | ✓ | ✓ | ✗ |
| `gnunix-minimal` | ✓ | ✓ | ✗ |
| `gnunix-desktop` | ✓ | ✓ | ✗ |
| `gnunix-installer` | ✗ | ✗ | ✓ |

Per-platform variants (`rpi4`, `nuc-installer`) are a future
extension: `tools/package.sh gnunix-desktop --as=img.zst
--platform=rpi4`. The `--platform=` flag defaults to `generic-uefi`
(omitted from filenames per the naming grammar).

## Consequences

### Build pipeline

Each image's `build.sh` produces a raw VM disk image in a known path
(`cache/artifacts/gnunix-<image>-<arch>-<ver>.img`, uncompressed)
and stops. Packaging is `tools/package.sh`'s job. This separation
means a single build can fan out into multiple published forms
without rebuilding.

### Release page

`release.yml`'s release-body generator emits a table indexed by
image × form:

```
| Image            | .iso | .img.zst | .tart.zst |
|------------------|------|----------|-----------|
| gnunix-base      |  —   |   ✓      |    ✓      |
| gnunix-minimal   |  —   |   ✓      |    ✓      |
| gnunix-desktop   |  —   |   ✓      |    ✓      |
| gnunix-installer |  ✓   |   —      |    —      |
```

Each `✓` is a hyperlink to the release asset. Users pick the row
matching their image and the column matching their tool.

### CI workflow changes

`build.yml`:

- New job `fetch-deps` runs first on `ubuntu-22.04-arm`,
  invokes `tools/fetch-image.sh gnunix-minimal <ver>` and
  publishes the imported VM as a workflow-scoped artifact (or
  registers it in the runner's local Tart/qemu state).
- Existing `gnunix-base`, `gnunix-minimal` (renamed to `gnunix-minimal`
  per ADR-019) jobs become **conditional**: skipped on PRs/pushes
  whose changes don't touch `images/gnunix-base/` or
  `images/gnunix-minimal/`. They run unconditionally on the release
  tag path.
- `gnunix-desktop`, `gnunix-installer`, `installer-test` jobs depend
  on `fetch-deps` (or on `gnunix-base`/`gnunix-minimal` when those
  ran).
- Artifact uploads use the new naming grammar.

`release.yml`:

- Asset globs become `gnunix-*-{img.zst,iso,tart.zst}` (drops
  `-disk-`).
- Release-body generator switches to the image × form table.

### Local-dev parity

A developer runs the same `tools/build-all.sh` and `tools/package.sh`
locally. Driver autodetect (Tart on macOS, qemu+KVM on Linux) lives
in `scripts/vm-helpers.sh` ([ADR-016](ADR-016-ci-split-build-and-validation.md));
nothing in the build/package layer cares which is active.

### Migration notes

- The `-disk-` legacy form is gone in the version that lands this
  ADR (0.2.0). Users still referencing 0.1.0 artifacts continue to
  download `gnunix-<image>-disk-0.1.0.img.zst`; nothing is renamed
  retroactively.
- `tools/package-platform.sh` is deleted; its responsibilities split
  into `tools/package.sh` (form) + `--platform=` flag (variant).

## Out of scope

- **Per-image versioning.** Considered and rejected (see "Version
  coupling" above).
- **A "rolling" release channel.** GNUnix releases are tagged
  snapshots only. Users who want bleeding edge can `git pull` and
  rebuild.
- **Signed artifacts.** Cryptographic signing of release assets is
  separate work, tracked in `docs/TODO.md` under "Verified release
  path."
- **A `.qcow2` or `.vmdk` form.** Users running qemu/libvirt/Proxmox
  can `qemu-img convert` the `.img.zst` themselves; we don't ship
  every possible VM format.

## Open questions

1. **`.tart.zst` for `gnunix-installer`?** The installer is a live
   ISO, but a Tart-importable bootable installer VM might be useful
   for Mac contributors testing the install flow without flashing a
   USB. Possible follow-up; v1 ships `.iso` only.
2. **Asset checksums.** `release.yml` already emits `SHA256SUMS`
   for `*.img.zst *.iso`; will need to add `*.tart.zst` to the glob.
   Trivial.
3. **CI cache for fetched dependencies.** Currently `fetch-image.sh`
   pulls from GH Releases each run. A workflow-level cache keyed on
   `(image, ver)` would speed up forks' CI noticeably. Implement
   alongside PR-3 if cheap.

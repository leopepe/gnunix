# ADR-013: Rename the distribution to GNUnix

**Status:** Accepted (extended by [ADR-019](ADR-019-image-lineage-and-installer-pivot.md))
**Date:** 2026-05-14
**Extended:** 2026-05-15 — ADR-019 finishes a second rename within the GNUnix lineage: `gnunix-nix` → `gnunix-minimal`. Same pattern as the original rename — historical ADRs 001–012 keep the pre-rename names; new code/docs use the new name.

## Context

The project has been working under the descriptive but bland name
`lfs-nix-distro`. It accurately captures the two-layer model (LFS base +
Nix userland) but is unbrandable, unmemorable, and reads as a placeholder.

Naming a distribution matters because the name is what ends up in the
boot menu, in `/etc/os-release`, in conversation, in support requests, in
the URL of the repo, and on the page that explains what the thing is.

## Decision

The distribution is renamed to **GNUnix**.

Rationale:

- **Pun**: GNU = "GNU's Not Unix"; the distro is a from-source LFS base
  built almost entirely from the GNU toolchain. With "Nix" appended, the
  name reads either as **GNUnix** (GNU + Nix, our two layers) or as
  **GN Unix** (i.e., "Nix as the package layer on top of *GNU*'s
  not-Unix"). The double reading is the joke.
- **Single word**, mixed case, easy to pronounce ("gee-en-you-nix" or
  "gnu-niks", we don't insist).
- **Distinct**: no existing distro shipped under this name as of search
  time. Old projects in the same area used names like `gnu/linux`,
  `Guix`, `nixos`, `nix-darwin` — all distinct.

### Image lineage (renamed)

| Old name           | New name        | Description |
|---|---|---|
| `lfs-core`         | `gnunix-base`    | Minimal LFS base (sysvinit + sshd + DHCP + kernel) |
| `lfs-nix`          | `gnunix-nix`     | Base + multi-user Nix daemon + nixpkgs |
| `lfs-wayland`      | `gnunix-desktop` | Base + Nix + dbus/elogind/greetd/sway/waybar |
| `lfs-builder`      | `gnunix-builder` | The Ubuntu-arm64 Tart VM that compiles GNUnix images |

Disk artifacts follow the same pattern:

```
cache/artifacts/lfs-core-disk-0.1.0.img         → gnunix-base-disk-0.1.0.img
cache/artifacts/lfs-nix-disk-0.1.0.img          → gnunix-nix-disk-0.1.0.img
cache/artifacts/lfs-wayland-disk-0.1.0.img      → gnunix-desktop-disk-0.1.0.img
```

Platform-packaged variants (ADR-010) follow:
```
lfs-{nix,wayland}-generic-uefi-aarch64-<ver>.img → gnunix-{nix,desktop}-generic-uefi-aarch64-<ver>.img
lfs-{nix,wayland}-rpi-native-aarch64-<ver>.img   → gnunix-{nix,desktop}-rpi-native-aarch64-<ver>.img
lfs-{nix,wayland}-nuc-installer-x86_64-<ver>.iso → gnunix-{nix,desktop}-nuc-installer-x86_64-<ver>.iso
```

### Repository directory layout (renamed)

| Old path                       | New path                          |
|---|---|
| `images/lfs-core/`             | `images/gnunix-base/`             |
| `images/lfs-nix/`              | `images/gnunix-nix/`              |
| `images/lfs-wayland/`          | `images/gnunix-desktop/`          |
| `images/lfs-builder/`          | `images/gnunix-builder/`          |
| `images/variants/*` (unchanged) | `images/variants/*`               |
| `tools/build-all.sh lfs-core`  | `tools/build-all.sh gnunix-base`  |
| `tools/build-all.sh lfs-nix`   | `tools/build-all.sh gnunix-nix`   |
| `tools/build-all.sh lfs-wayland` | `tools/build-all.sh gnunix-desktop` |

### What stays unchanged

- All ADRs 001–012 keep their locked decisions; their CONTENT doesn't
  change. Only forward-looking documents reference the new name.
- The repo directory at the filesystem level (`lfs-nix-distro/`) keeps
  its name for as long as the user's local clone exists; only a
  GitHub-side rename is needed when the repo is published.
- Internal technical accuracy: still "LFS base + Nix". The phrase
  "Linux From Scratch" stays in the architecture doc and stage scripts.
  The "lfs" *prefix on image names* is what changes, because that's what
  end users see.
- Kernel source, glibc, nixpkgs — no upstream renames; we're not forking
  any of those.

### What about `/etc/os-release`?

Add a proper `/etc/os-release` to the base image (currently absent):

```
NAME="GNUnix"
PRETTY_NAME="GNUnix 0.1.0 (gnunix-base)"
ID=gnunix
VERSION_ID="0.1.0"
HOME_URL="https://gnunix.invalid/"
```

The `ID=gnunix` is what application code keys on; the human label is the
PRETTY_NAME. Apps that care about distro identity (Nix, some hardening
detectors, NetworkManager profile assignment) read this file.

## Consequences

### One-time migration

Renames are scripted in a single migration commit. The work is:

1. `git mv images/lfs-core images/gnunix-base` (and the three siblings).
2. `tools/build-all.sh` `case "$PHASE"` arms rewritten to the new names.
3. `tools/manifest.json` — the schema is unchanged; only the comments
   that mention "lfs-core" etc. get the new names.
4. CI workflow (`.github/workflows/build.yml`) job names and matrix
   values renamed: `lfs-core` → `gnunix-base`, etc.
5. All documentation prose updated: `docs/`, `runbook.md`, `README.md`.
6. The hostname-writing logic in `install-*.sh` updated to write the
   new image identifier into `/etc/hostname` and `/etc/os-release`.
7. ADR documents kept as-is for historical fidelity, except ADR-013
   (this one) and a new entry in `docs/architecture.md`.

### What about the in-flight build?

The build that's running while this ADR is being written is using the
old names. We don't interrupt it. The migration commit lands AFTER
the build completes; the next build run uses the new names.

The image being produced right now (`lfs-wayland-disk-0.1.0.img`) keeps
its old name on disk — we don't rename existing artifacts retroactively.
Future builds emit the renamed files; consumers (CI release uploader,
documentation) point at the new names.

### Two-phase rollout in source

- **Phase A** (during the in-flight build): write ADR-013, update text
  references in `docs/`, `README.md`, `runbook.md`. No directory renames,
  no executable script renames. Safe to do now.
- **Phase B** (after build completes): the `git mv` migration of
  `images/lfs-*` → `images/gnunix-*`, plus all script and CI edits that
  follow. This is one big atomic commit.

## Out of scope

- **Trademark / legal** — "GNUnix" appears unused by other projects but we
  haven't asked the GNU project whether they consider the name a
  trademark infringement. As long as the project is a hobby / community
  distribution and stays away from claiming GNU endorsement, this is
  fine. Revisit if the project ever ships commercially.
- **Logo, font, color palette** — design work, separate from naming.
- **A web site at `gnunix.invalid` (or similar)** — not chosen yet.
- **Pronunciation guide / phonetic spelling** — both readings work;
  we don't insist on either.

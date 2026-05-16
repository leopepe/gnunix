# Scope of the GNUnix LICENSE

The [`LICENSE`](LICENSE) at the repository root is BSD 2-Clause
(SPDX: `BSD-2-Clause`). This file explains **what it covers and what
it does not**.

## What the LICENSE covers

The BSD-2-Clause terms apply to the GNUnix-authored content in this
repository — i.e. the glue that turns upstream software into a
distribution:

- Build scripts under `tools/`, `scripts/`, `images/*/build.sh`,
  `images/*/stages/`, `images/*/packaging/`.
- Configuration scaffolding under `images/*/etc/` (init scripts,
  greetd config, hyprland starter config, fstab templates, etc.).
- Nix expressions under `bundles/`.
- The manifest, the package dispatcher, the release tooling
  (`tools/manifest.json`, `tools/package.sh`, `tools/release-image.sh`,
  `tools/fetch-image.sh`, `tools/promote.sh`).
- Tests under `tests/` and `scripts/validate-*.sh`,
  `scripts/run-installer-test.sh`.
- Documentation: `README.md`, `CLAUDE.md`, `CONTRIBUTING.md`,
  `docs/architecture.md`, `docs/adrs/`, `docs/runbooks/`.
- ADRs themselves and the runbooks.

## What the LICENSE does NOT cover

The LICENSE does not apply to the upstream software GNUnix builds
and packages. Each upstream component retains its own license and
is distributed under those terms:

- **Linux kernel** — GPL-2.0-only.
- **GNU userland** (glibc, GCC, binutils, coreutils, bash, …) —
  GPL-3.0-or-later / LGPL-3.0-or-later as upstream.
- **`sysvinit`** — GPL-2.0-or-later.
- **`eudev`** — GPL-2.0-or-later / LGPL-2.1-or-later.
- **`dbus`** — AFL-2.1 / GPL-2.0-or-later (dual).
- **`elogind`** — LGPL-2.1-or-later.
- **GRUB** — GPL-3.0-or-later.
- **`openssh`** — BSD-style (mixed).
- **Nix** — LGPL-2.1.
- **`nixpkgs`** and the packages installed from it (Wayland
  compositors, portals, fonts, apps, dev tools, COSMIC, etc.) —
  individual upstream licenses; see each package's `meta.license`.
- All `/nix/store` content in a produced image.

GNUnix takes no position on, and grants no rights to, any of these
upstream licenses. Consult the source of each component for its
terms.

## Produced images

When the GNUnix pipeline produces a Tart VM image, raw `.img.zst`,
or hybrid `.iso`, the resulting artifact is a **collection of
separately-licensed software**, just like any Linux distribution.
Each binary in `/usr`, `/bin`, `/lib`, and under `/nix/store` retains
its upstream license; the BSD-2-Clause terms in `LICENSE` cover only
the GNUnix-authored glue (init scripts, build pipeline, manifest,
documentation, etc.) — not the software the pipeline builds.

Redistribution of a produced GNUnix image must comply with each
included component's license. The most common practical
consequence: a published image that bundles GPL-licensed binaries
must provide (or offer to provide) the corresponding source. The
`tools/manifest.json` file plus the pinned upstream source URLs are
sufficient to satisfy this obligation for the LFS base layer; the
Nix layer is sourced reproducibly from `cache.nixos.org` and is
trivially re-derivable from the pinned `nixpkgs` revision.

## Contributions

By submitting a contribution (pull request, patch, issue, etc.) to
this repository, you agree that your contribution is licensed under
the BSD 2-Clause terms in [`LICENSE`](LICENSE). See
[`CONTRIBUTING.md`](CONTRIBUTING.md) for the contribution process.

## History

GNUnix previously used a BSD 1-Clause license (the same one that
ships with Slackware's SlackBuild scripts). The switch to BSD 2-Clause
on 2026-05-16 was a simplification — the actual permissive grant is
nearly identical, but BSD 2-Clause is the canonical, OSI-recognised,
SPDX-listed text, which makes the license correctly auto-detected
by GitHub's Licensee tool and unambiguously identifiable by
downstream packagers. No copyright holder or contributor's rights
changed in the transition.

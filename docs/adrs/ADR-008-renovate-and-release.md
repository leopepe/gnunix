# ADR-008: Dependency updates with Renovate, image release via GitHub

**Status:** Accepted
**Date:** 2026-05-10

## Context

The architectural premise of this distro is "static base, dynamic userland." That premise only delivers value if the dynamic userland actually stays current — kernel CVEs patched, nixpkgs bumped weekly, Wayland compositor on a recent release. Doing this by hand on a single workstation drifts within months.

The base is also versioned (kernel, glibc, binutils, gcc, sysvinit, eudev, dbus, elogind, GRUB) and needs occasional bumps for security.

Two adjacent problems:

1. **Detect** that a pin is out of date (or has a security advisory).
2. **Apply** the bump, rebuild affected images, and publish them.

## Decision

- **Renovate** runs on the GitHub repo, opens PRs to bump pinned versions in `tools/manifest.json`, `bundles/*.nix`, `images/*/build.sh`, and `flake.lock` (if/when introduced).
- **GitHub Actions** runs the image build pipeline on PR and on merge to `main`. On merge of a release-tagged commit, built Tart images are published as GitHub Releases (artifact attachments) and optionally pushed to a private OCI registry.

## Rationale

- Renovate handles Nix (`flake.lock`, nixpkgs revs), shell pins (custom regex managers for `kernel.config` etc.), Dockerfile-style version tags, and GitHub Actions versions — one tool covers all our pin sites.
- GitHub Releases is the simplest "publish a versioned binary artifact" mechanism that doesn't require us to run a registry.
- Tart images export as compressed disk images; they fit GitHub Releases' artifact model fine for our scale (single-developer audience, ADR-005).
- Aligns with the philosophy: the base rarely changes (so PRs are rare and worth manual review), but the userland gets a steady drip of bumps that Renovate auto-creates and CI auto-validates.

## Pipeline shape

```
Renovate PR  →  GH Actions: build affected images on macOS arm64 runner
              →  run boot-smoke + wayland-session tests inside Tart
              →  on green, auto-merge nixpkgs/userland bumps;
                 hold base bumps for human review
              →  on merge to main with release tag:
                   tools/promote.sh tags images, uploads to GH Releases
```

- macOS arm64 runners are required (Tart + Virtualization.framework). GitHub-hosted macOS runners are arm64 by default since 2024; otherwise self-hosted Mac mini.
- Test gating is non-negotiable: an image that fails `boot-smoke.sh` does not get released.

## Renovate config principles

- **Group nixpkgs bumps** into one PR per week (otherwise it floods).
- **Auto-merge** userland bumps that pass CI; never auto-merge base bumps (kernel, glibc, init, bootloader, GRUB).
- **Pin everything.** Floating refs (`master`, `latest`) defeat the point.
- **Custom regex managers** for the few non-package pins (kernel version in `kernel.config`, GRUB version in `build.sh`).
- Renovate config lives at `.github/renovate.json5` (or `renovate.json`).

## Release artifacts

Per release tag, GitHub Release contains:

- `lfs-core-<ver>.tart.tar.zst`
- `lfs-nix-<ver>.tart.tar.zst`
- `lfs-wayland-<ver>.tart.tar.zst`
- Each variant image
- `manifest.json` — exact versions of every pinned component

## Consequences

- Adds: `.github/workflows/build.yml`, `.github/workflows/release.yml`, `.github/renovate.json5`.
- Adds: `tools/promote.sh` (already planned) extended to upload to GH Releases via `gh release create`.
- Repo must be on GitHub (or a Renovate-supported host).
- Self-hosted macOS arm64 runner is the most reliable path; revisit when GH-hosted arm64 runtime + Tart compatibility matures.

## Out of scope

- Dependabot: weaker custom-pin support than Renovate; doesn't cover Nix as well.
- Pushing to Docker Hub / GHCR by default: revisit per ADR-005 ("this Mac first") — registry push is opt-in.
- Continuous-deploy to user machines: out of scope for a single-user dev workstation.

## Revisit when

- The audience expands beyond one machine (then registry push becomes default).
- A base bump (kernel/glibc) needs a faster path than weekly human review (then introduce a security-only auto-merge lane).

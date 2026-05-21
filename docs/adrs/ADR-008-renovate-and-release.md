# ADR-008: Dependency updates with Renovate, image release via GitHub

**Status:** Accepted (amended by [ADR-016](ADR-016-ci-split-build-and-validation.md), [ADR-018](ADR-018-artifact-taxonomy.md), [ADR-021](ADR-021-hosted-runners-only.md))
**Date:** 2026-05-10
**Amended:** 2026-05-15 — runner topology revised by ADR-016; artifact taxonomy, naming grammar, and release-dependency flow specified by ADR-018. 2026-05-19 — ADR-021 collapses the "local Mac / hosted Linux" split: the LFS build runs in CI on `ubuntu-22.04-arm` via chroot, split into four cacheable stages.

## Decision

- **Renovate** runs on the GitHub repo, opens PRs to bump pinned versions in `tools/manifest.json`, `bundles/*.nix`, `images/*/build.sh`, and `flake.lock` (if/when introduced).
- **GitHub Actions** runs the image build pipeline on PR and on merge to `main`. On merge of a release-tagged commit, built images are published as GitHub Releases (artifact attachments) and optionally pushed to a private OCI registry.

## Pipeline shape

```
Renovate PR   →  GH Actions: build affected images on ubuntu-22.04-arm
                  (stage-split: cross-toolchain → temp-tools → chroot → finalize)
                →  run boot-smoke + wayland-session tests inside qemu+KVM
                →  on green, auto-merge nixpkgs/userland bumps;
                   hold base bumps for human review
                →  on merge to main with release tag:
                    tools/promote.sh tags images, uploads to GH Releases
```

- The `gnunix-base` build is split into four cacheable stages (ADR-021):
  cross-toolchain (~2–3 h), temp-tools (~1–2 h), chroot (~1–2 h),
  finalize (30–60 min). Each stage caches its LFS tree; a cancelled
  or timed-out job resumes from the last completed stage.
- Downstream images (minimal, desktop, installer) build in CI by
  layering Nix closures on the base image. No fetch-from-release
  indirection (ADR-021 collapses ADR-016's split).
- Tests run via qemu+KVM on `ubuntu-22.04-arm` through
  `scripts/vm-helpers.sh`. The same scripts that drive Tart locally
  drive qemu in CI.

## Release artifacts

Per release tag, GitHub Release contains:

- `gnunix-base-<arch>-<ver>.img.zst`
- `gnunix-minimal-<arch>-<ver>.img.zst`
- `gnunix-desktop-<arch>-<ver>.img.zst`
- `gnunix-installer-<arch>-<ver>.iso`
- Each variant image
- `manifest.json` — exact versions of every pinned component

## Consequences

- Adds: `.github/workflows/build.yml`, `.github/workflows/release.yml`, `.github/renovate.json5`.
- Adds: `tools/promote.sh` (already planned) extended to upload to GH Releases via `gh release create`.
- Repo must be on GitHub (or a Renovate-supported host).
- The stage-split pipeline (ADR-021) means the `build.yml` workflow is more complex but produces the same artifacts.

## Out of scope

- Dependabot: weaker custom-pin support than Renovate; doesn't cover Nix as well.
- Pushing to Docker Hub / GHCR by default: revisit per ADR-005 ("this Mac first") — registry push is opt-in.
- Continuous-deploy to user machines: out of scope for a single-user dev workstation.

# ADR-016: CI runs everything on hosted `ubuntu-22.04-arm`

**Status:** Superseded by [ADR-021](ADR-021-hosted-runners-only.md)
**Date:** 2026-05-15
**Amends:** [ADR-008](ADR-008-renovate-and-release.md)
**Superseded:** 2026-05-19 — ADR-021 collapses the "local Mac / hosted Linux" split. The LFS build runs in CI on `ubuntu-22.04-arm` via chroot (no Tart needed). ADR-016's split was based on the mistaken assumption that the LFS build required Tart.

## Context (historical)

ADR-008 set the CI runner to "macOS arm64 runner under
`.github/workflows/build.yml`" with the implicit assumption that
GitHub-hosted Mac runners would be usable for Tart at some point. They
are not, and won't be soon:

- GitHub-hosted macOS runners (`macos-14`, `macos-15`, `macos-26`, …)
  **do not expose Apple Virtualization.framework** to user workflows
  ([runner-images#9261](https://github.com/actions/runner-images/issues/9261)).
- Tart requires Virtualization.framework. So Tart on hosted runners is
  not possible.
- The remaining path — a self-hosted Mac — is unfunded for this
  project. PR #1 (the branch-protection bootstrap) demonstrates the
  failure mode: every job pinned to
  `runs-on: [self-hosted, macOS, arm64, tart]` queues forever, blocking
  every PR merge.

This ADR was written when the LFS build was assumed to require Tart.
ADR-021 later demonstrated that the LFS build is a chroot process and
does not need Virtualization.framework. The hosted `ubuntu-22.04-arm`
runner (a Graviton instance with native arm64 Linux) can chroot, compile,
and produce the same artifacts.

## Hard constraints (from ADR-016's original intent)

- **Full `gnunix-base` build ≈ 6–10 h** on Apple Silicon w/ native
  virtualization. The hosted-runner free-tier job timeout is 6 h. A
  from-scratch base build does not fit in a single hosted-job run.
- Downstream layering work (gnunix-minimal, gnunix-desktop, gnunix-installer,
  installer-test, package matrix, release assembly) is filesystem
  operations + `nix-env` pulls from `cache.nixos.org` + booting an
  already-built rootfs. These complete in 10–25 min each, and qemu
  with KVM accel on hosted arm64 Linux hosts is near-native.
- GitHub-hosted **arm64 Linux runners** (`ubuntu-22.04-arm`,
  `ubuntu-24.04-arm`) are **free for public repos** as of 2024–2025.

## Decision (as superseded by ADR-021)

ADR-016 originally split CI into two streams. ADR-021 collapsed that
split into one:

> Free GitHub-hosted runners do everything. The LFS base build runs on
> `ubuntu-22.04-arm` via chroot, split into four cacheable stages
> (cross-toolchain, temp-tools, chroot, finalize) so the 6–10 hour
> total doesn't hit the 6-hour per-job timeout.

The implementation details are in [ADR-021](ADR-021-hosted-runners-only.md).

## What was preserved from ADR-016

- The **stage-split** concept (splitting the LFS build into cacheable
  stages to avoid the 6-hour timeout). ADR-021 adopted this and made
  it the core of the pipeline.
- The **qemu+KVM for tests** approach. ADR-021 kept this unchanged.
- The **free for public repos** model. ADR-021 kept this unchanged.
- The **one scripts API** (same `tools/`, `tests/`, `scripts/` commands
  work in both environments). ADR-021 simplified this: there is now
  only one environment (hosted CI), and the local Mac path is a
  development convenience, not a CI requirement.

## Why ADR-016 is superseded

ADR-016's split ("local Mac for base, hosted Linux for validation") was
based on the assumption that the LFS build required Tart. ADR-021
demonstrated that assumption was wrong: the LFS build is a chroot
process and runs on any arm64 Linux, including the hosted
`ubuntu-22.04-arm` runner. The split was a workaround for a misread
constraint, not an architectural necessity.

## Remediation for the stuck branch-protection PR (historical)

The bootstrap PR for the `main-protection` ruleset (PR #1) was
blocked by the very rules it sets up. The path described below
(bypass-merge PR #1 → merge this ADR → land the migration PRs) was
part of ADR-016's original plan. ADR-021 inherits the same
remediation path but with a simpler pipeline to wire up (one runner,
one model).

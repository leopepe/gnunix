# ADR-021: Hosted runners only — LFS build runs in CI

**Status:** Accepted
**Date:** 2026-05-19
**Amends:** [ADR-008](ADR-008-renovate-and-release.md), [ADR-010](ADR-010-multi-arch-and-platforms.md), [ADR-016](ADR-016-ci-split-build-and-validation.md)

## Context

ADR-016 split CI into "local Mac (Tart) for `gnunix-base`" and "hosted Linux (qemu) for everything else." ADR-021 (originally titled "No self-hosted CI runners") took that split as the final word: the LFS build was assumed to need Tart, so the local Mac was the only option.

That assumption was wrong. The LFS build is a chroot process — it needs an arm64 rootfs and a shell, not Virtualization.framework. The hosted `ubuntu-22.04-arm` runner is a Graviton instance with native arm64 Linux and KVM support. It can chroot, compile, and produce the same artifacts as the local Mac path.

The cumulative effect of the old model was a CI architecture that required a labour investment (provisioning, patching, hardware) the project doesn't have and has no plans to make. The "local Mac" path was a workaround for a misread constraint, not an architectural necessity.

## Decision

**Free GitHub-hosted runners do everything.** Every workflow in this repository runs on hosted `ubuntu-22.04-arm` (arm64) or `ubuntu-latest` (x86_64 / lint).

Concretely:

1. **The LFS base build runs in CI on `ubuntu-22.04-arm`.** The build is split into four cacheable stages (cross-toolchain, temp-tools, chroot, finalize) so the 6–10 hour total doesn't hit the 6-hour per-job timeout. Each stage caches its LFS tree; a cancelled or timed-out job can resume from the last completed stage on the next run.
2. **Downstream images (minimal, desktop, installer) build in CI** by layering Nix closures on top of the base image. No fetch-from-release indirection.
3. **Tests run in CI via qemu+KVM** through `scripts/vm-helpers.sh`. The same scripts that drive Tart locally drive qemu in CI.
4. **Self-hosted runners are forbidden.** Not now, not later. Per ADR-005 (solo maintainership) and ADR-018 (free for public repos), there is no justification for self-hosted infrastructure.

### Stage-split pipeline

The `gnunix-base` build is split into four stages, each a separate GitHub Actions job with its own cache:

| Stage | What | ~Time | Cache key |
|-------|------|-------|-----------|
| `cross-toolchain` | binutils-pass1, gcc-pass1, linux headers, glibc, libstdc++ into `$LFS` | 2–3 h | `lfs-cross-<ver>-<script-hash>` |
| `temp-tools` | Temporary tools (bash, coreutils, grep, sed, …) into `$LFS` | 1–2 h | `lfs-temp-<ver>-<script-hash>` |
| `chroot` | Chroot into `$LFS`, build final system (binutils-pass2, gcc-pass2, all base packages) | 1–2 h | `lfs-chroot-<ver>-<script-hash>` |
| `finalize` | Install configs, build kernel, GRUB, pack rootfs → `.img.zst` | 30–60 min | N/A (produces artifact) |

Each stage's cache key incorporates the version from `manifest.json` and a hash of the stage script. When a script changes, its cache key changes, forcing a rebuild. When nothing changes, the cache is restored and the stage is a no-op.

A `restore-keys` prefix (`lfs-cross-`, `lfs-temp-`, `lfs-chroot-`) allows partial cache hits if the exact key has drifted.

A `CANCELLED` trigger (ADR-008) restarts the pipeline from the last completed stage, not from scratch.

## Rationale

- **Solo maintainership** (per [ADR-005](ADR-005-audience.md)). A self-hosted runner is another *thing to operate*: it needs OS patches, the actions/runner binary updated, secret management, an always-on machine, a network reachable from GitHub, monitoring for drift. One maintainer who already invests overnight builds for the distro itself can't justify another always-on responsibility.
- **Free for public repos.** GitHub-hosted `ubuntu-22.04-arm` and `ubuntu-latest` are free for public repositories as of 2024–2025. The project doesn't generate revenue and isn't going to commit to a recurring spend.
- **Reproducibility for forks.** The audience is forks. A hosted runner is a runner every fork already has. No local Tart requirement means any fork can rebuild the entire distro from source.
- **The LFS build doesn't need Tart.** Tart is a VM hypervisor for macOS. The LFS build is a chroot process — it needs an arm64 rootfs and a shell. `ubuntu-22.04-arm` provides both natively.
- **Stage-split solves the timeout problem.** A single 6–10 hour job would exceed the 6-hour hosted runner timeout. Splitting into 2–3 hour stages with cache resumption means a cancelled job picks up where it left off, not from zero.

## Consequences

### The split is gone

ADR-016's "local Mac / hosted Linux" split no longer exists. There is one CI model:

| Component | Runner | Driver |
|---|---|---|
| LFS base build (4 stages) | `ubuntu-22.04-arm` | chroot on Graviton |
| Downstream images | `ubuntu-22.04-arm` | Nix layering |
| Smoke tests | `ubuntu-22.04-arm` | qemu+KVM via `vm-helpers.sh` |
| Lint / PR checks | `ubuntu-latest` | native |
| Release assembly | `ubuntu-latest` | native |

### Local dev still uses Tart

The local Mac path is unchanged for development iteration: `tools/build-all.sh gnunix-base` still uses Tart for fast local rebuilds. The CI path and the local path produce the same artifacts; they just differ in how the LFS stages are orchestrated (chroot vs Tart VM).

### ADR-010's Phase 5/6 revised

ADR-010's Phase 5/6 plans that previously called for a self-hosted Linux x86_64 runner are now: the x86_64 path uses a hosted `ubuntu-22.04` runner and qemu+KVM for virtualization. The `gnunix-base` x86_64 build runs in the same stage-split pipeline, targeting `x86` via the cross-toolchain.

### Validation hygiene

`actionlint`'s `self-hosted-runner:` block is removed. If any workflow re-introduces a `self-hosted` label by accident, actionlint will flag it as an unknown runner and CI will fail — a built-in tripwire that prevents reintroduction.

## Out of scope

- **Paid GitHub-hosted macOS runners.** Considered and rejected on cost grounds. The relevant pricing tier is "macOS XL" which is ~10× the cost of Linux on the metered tier. Not viable for a hobby distro.
- **Renting from a third party** (CircleCI macOS, BuildJet, etc.). Same cost objection plus the operational complexity of integrating another vendor.
- **Cross-compiled aarch64 → x86_64 builds on a single runner.** Possible in principle (the LFS toolchain already supports cross compilation), but a meaningful re-architecture of the build pipeline. Tracked as a separate future ADR if/when it becomes necessary.

## Open questions

1. **If `ubuntu-22.04-arm` becomes paid for public repos.** GitHub announced free arm64 hosted Linux runners for public repos in 2024–2025. If that policy changes, ADR-021 needs revisiting. As of May 2026 the free tier is in effect.
2. **First-boot smoke tests on bare metal.** `gnunix-installer` eventually needs to be verified booting on real hardware (rpi-native, NUC). That validation has never been planned as part of CI — it's a maintainer-on-a-laptop activity. Reaffirmed here: never a CI concern.
3. **Cache storage budget.** The LFS tree grows to ~20–30GB across stages. GitHub's repository cache limit is 10GB per repo. With four stages, the total cache footprint could exceed the budget. Mitigations: (a) prune the LFS tree between stages (keep only `$LFS/{bin,sbin,lib,usr,etc,boot,root,home,var}`), (b) use `actions/cache` with `compression-level: 0` for speed (the LFS tree is mostly text and compresses well), (c) accept that the cache budget may need to be increased via a GitHub support request.

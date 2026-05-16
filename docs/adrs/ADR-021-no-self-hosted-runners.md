# ADR-021: No self-hosted CI runners — hosted-only policy

**Status:** Accepted
**Date:** 2026-05-16
**Amends:** [ADR-008](ADR-008-renovate-and-release.md), [ADR-010](ADR-010-multi-arch-and-platforms.md), [ADR-016](ADR-016-ci-split-build-and-validation.md)

## Context

The CI plumbing inherited from ADR-008 + ADR-016 + ADR-010 all
references self-hosted runners in one form or another:

- [ADR-008](ADR-008-renovate-and-release.md) originally specified the
  release-publishing path as a "macOS arm64 runner under
  `.github/workflows/build.yml`" with the implicit assumption that the
  maintainer would stand up a self-hosted Mac.
- [ADR-016](ADR-016-ci-split-build-and-validation.md) amended that to a
  hybrid: routine validation on free hosted `ubuntu-22.04-arm`, with
  `gnunix-base` rebuilds happening on a maintainer's Mac (an *unmanaged*
  local machine, not a runner) and shipping as GH Release artifacts.
  ADR-016 stopped short of saying "no self-hosted ever" — it left the
  door open.
- [ADR-010](ADR-010-multi-arch-and-platforms.md) Phase 5/6 plan
  explicitly **requires** a self-hosted Linux x86_64 runner labelled
  `[self-hosted, linux, x64]` for `nuc-installer` and follow-on
  cross-arch work.
- `.github/workflows/build.yml` pins every job to `runs-on:
  [self-hosted, macOS, arm64, tart]`. PR #12 disabled the workflow's
  PR / push / merge_group triggers because no such runner is
  provisioned on this repo and jobs were queueing forever.
- `.github/workflows/publish.yml` (PR #16) was a brand-new
  workflow_dispatch publish path explicitly designed for that same
  self-hosted Mac runner.

The cumulative effect was a CI architecture that requires a labour
investment (provisioning, patching, hardware) the project doesn't have
the resources to make and has no plans to make.

## Decision

**No self-hosted runners — not now, not later.** Every workflow in
this repository runs exclusively on **free GitHub-hosted runners**.

Concretely:

1. `.github/workflows/build.yml` jobs are re-labelled to
   `runs-on: ubuntu-22.04-arm` (or `ubuntu-latest` for lint-only jobs).
   The workflow's triggers remain reduced (per PR #12) until the
   downstream-job logic actually runs end-to-end on hosted runners
   (PR-3b's work — qemu+KVM driver in `scripts/vm-helpers.sh` +
   `tools/fetch-image.sh` wire-up).
2. `.github/workflows/publish.yml` is **deleted**. It existed only to
   wrap `tools/release-image.sh` on a self-hosted Mac runner. With no
   such runner permitted, the workflow has no surface to run on.
3. `.github/actionlint.yaml`'s `self-hosted-runner:` declaration is
   removed.
4. `tools/manifest.json`'s `archs.<arch>.runner_labels` arrays — used
   purely for actionlint guidance per ADR-010 — are simplified to the
   hosted-runner equivalents (`ubuntu-22.04-arm` for aarch64,
   `ubuntu-22.04` for x86_64).
5. ADR-010's Phase 5/6 plans that previously called for a self-hosted
   Linux x86_64 runner are revised in this ADR's Consequences: the
   x86_64 path must use a hosted runner (`ubuntu-22.04` or
   `ubuntu-latest`) and qemu+KVM where virtualization is needed, or
   it ships as a strictly developer-machine build (same shape as
   `gnunix-base` today — local rebuild, fetched via
   `tools/fetch-image.sh` from a GH Release).
6. `docs/TODO.md`'s "Provision a self-hosted Linux x86_64 runner" task
   is struck.

The release path until PR-3b lands is the **manual** one used to ship
`v0.1.0-prototype` on 2026-05-15: developer builds locally on a Mac,
runs `tools/release-image.sh` from the Mac terminal. CI publishes
zero releases until the qemu+KVM migration completes.

## Rationale

- **Solo maintainership** (per [ADR-005](ADR-005-audience.md)). A
  self-hosted runner is another *thing to operate*: it needs OS
  patches, the actions/runner binary updated, secret management, an
  always-on machine, a network reachable from GitHub, monitoring for
  drift. One maintainer who already invests overnight builds for the
  distro itself can't justify another always-on responsibility.
- **Reproducibility for forks.** The audience is forks. A free
  hosted runner is a runner every fork already has. A self-hosted
  Mac is a private resource that no fork can match — gating the
  build/release pipeline on it kneecaps the fork story.
- **Cost.** Even a paid self-hosted Mac runner is single-tenant; the
  project doesn't generate revenue and isn't going to commit to a
  recurring spend.
- **The work was already moving this direction.** ADR-016 partly
  acknowledged the constraint by splitting "build" (developer's
  local Mac, unmanaged) from "validation" (hosted Linux). ADR-021
  finishes the move: there is no third tier.

## Consequences

### Workflows in this repo after ADR-021

| Workflow | Status after ADR-021 |
|---|---|
| `pr-lint.yml` | Unchanged. Already hosted. |
| `ai-review.yml` | Unchanged. Hosted; talks to remote LLM provider. |
| `labels-sync.yml` | Unchanged. Hosted. |
| `pr-labeler.yml` | Unchanged. Hosted. |
| `tag-on-version-bump.yml` | Unchanged. Hosted. |
| `release.yml` | Unchanged trigger / runner; **stays gated on `build.yml` producing artifacts** — so effectively dormant until PR-3b. |
| `build.yml` | All jobs re-labelled to hosted runners (`ubuntu-22.04-arm`); triggers stay disabled (PR #12) until PR-3b fills in the qemu+KVM logic. |
| `publish.yml` | **Deleted.** |

### Release flow until PR-3b

Releases are **manual from the maintainer's Mac**:

```sh
tools/build-all.sh gnunix-base       # ~6–10h, infrequent
tools/build-all.sh gnunix-minimal    # ~10 min
tools/build-all.sh gnunix-desktop    # ~20 min
tools/package.sh   <image> --as=<form>
tools/release-image.sh <image>       # creates / updates the GH Release
```

This is exactly the path that produced `base-images-0.1.0` and
`v0.1.0-prototype` on 2026-05-15/16. Documented in
`docs/runbooks/release-deps.md`.

### PR-3b becomes load-bearing

PR-3b (qemu+KVM driver in `scripts/vm-helpers.sh` + downstream-job
migration in `build.yml`) was a "nice to have" under ADR-016 — with a
self-hosted Mac it was just an optimization. After ADR-021 it is the
**only** path to a CI-driven release. The deferred work in PR-3b's
scope is therefore promoted to the next milestone after the installer
ISO (v0.1.2 timeframe).

### Phase 5/6 of ADR-010 revised

ADR-010 named a self-hosted Linux x86_64 runner as the prerequisite
for shipping `nuc-installer` and the x86_64 generic-uefi image. Under
ADR-021 that runner can't exist. Two acceptable paths remain:

1. **Hosted x86_64 via qemu+KVM**: `ubuntu-22.04` (or `-latest`)
   hosted runners can run qemu+KVM for x86_64 guests at near-native
   speed. The `scripts/vm-helpers.sh` qemu driver (PR-3b) extends to
   handle both arm64 and x86_64 guests; the gnunix-base x86_64 build
   would run there.
2. **Local-developer build only**: same shape as `gnunix-base`
   today. The developer builds x86_64 on their own machine, runs
   `tools/release-image.sh` to publish, and CI consumes the artifact
   via `tools/fetch-image.sh`. No CI rebuild capability for x86_64.

Path (1) is the long-term goal. Path (2) is the interim. Either way,
no self-hosted runners.

### Validation hygiene

`actionlint` previously had a `self-hosted-runner:` block listing
custom labels so it didn't complain about `runs-on: [self-hosted,
macOS, arm64, tart]`. That block is removed; if any workflow re-
introduces a `self-hosted` label by accident, actionlint will flag it
as an unknown runner and CI will fail — a built-in tripwire that
prevents reintroduction.

## Out of scope

- **Paid GitHub-hosted macOS runners.** Considered and rejected on
  cost grounds. The relevant pricing tier is "macOS XL" which is
  ~10× the cost of Linux on the metered tier. Not viable for a
  hobby distro.
- **Renting from a third party** (CircleCI macOS, BuildJet, etc.).
  Same cost objection plus the operational complexity of integrating
  another vendor.
- **Cross-compiled aarch64 → x86_64 builds on a single runner.**
  Possible in principle (the LFS toolchain already supports cross
  compilation), but a meaningful re-architecture of the build
  pipeline. Tracked as a separate future ADR if/when it becomes
  necessary.

## Open questions

1. **If `ubuntu-22.04-arm` becomes paid for public repos.** GitHub
   announced free arm64 hosted Linux runners for public repos in
   2024–2025. If that policy changes, ADR-021 needs revisiting. As
   of May 2026 the free tier is in effect.
2. **First-boot smoke tests on bare metal.** `gnunix-installer`
   eventually needs to be verified booting on real hardware (rpi-
   native, NUC). That validation has never been planned as part of
   CI — it's a maintainer-on-a-laptop activity. Reaffirmed here:
   never a CI concern.

## Implementation checklist

- [x] Add `docs/adrs/ADR-021-no-self-hosted-runners.md` (this file).
- [ ] Header-amend `docs/adrs/ADR-008`, `ADR-010`, `ADR-016`.
- [ ] Re-label all jobs in `.github/workflows/build.yml`:
  `[self-hosted, macOS, arm64, tart]` → `ubuntu-22.04-arm`.
- [ ] Update build.yml's header comment + the now-stale "runner
  requirement" / "runner labels" sections.
- [ ] Delete `.github/workflows/publish.yml`.
- [ ] Strip `self-hosted-runner:` block from `.github/actionlint.yaml`.
- [ ] Update `tools/manifest.json`'s `archs.<arch>.runner_labels`.
- [ ] Strike the "Provision a self-hosted Linux x86_64 runner" task
  in `docs/TODO.md`.
- [ ] Add ADR-021 to CLAUDE.md's locked-decisions table.
- [ ] Add ADR-021 to `docs/architecture.md` and rewrite Phase 5/6
  language to remove the self-hosted-runner prerequisite.

Architecture impact: see architecture.md § Locked decisions.

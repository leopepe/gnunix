# ADR-016: CI strategy — split build (local Tart) and validation/release (GitHub-hosted Linux)

**Status:** Proposed
**Date:** 2026-05-15
**Amends:** [ADR-008](ADR-008-renovate-and-release.md)

## Context

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

We need a CI strategy that works on **free** GitHub-hosted runners
while still producing the same artifacts (raw `.img.zst` pendrive
images, hybrid `.iso` for x86_64 NUCs, signed GitHub Releases) the
project needs.

## Hard constraints

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

## Decision

Split CI into two streams that share the **same entrypoint scripts**:

### Local dev (developer's Mac)

- Driver: **Tart** (Apple Virtualization.framework, native arm64).
- Used for: full `gnunix-base` build (when toolchain pins change),
  fast dev iteration on downstream layers.
- Default: `tools/build-all.sh <image>` autodetects macOS and uses
  Tart. No env var needed.

### GitHub-hosted CI

- Runner: `ubuntu-22.04-arm` (or newer arm64 hosted variant).
- Driver: **qemu-system-aarch64 + KVM accel**.
- Used for: lint, layering (nix/desktop/installer), boot smokes,
  installer-test matrix, package matrix, release assembly.
- `gnunix-base` is treated as a **vendored input**: the maintainer
  publishes a `gnunix-base-disk-<ver>.img.zst` to GitHub Releases
  when toolchain pins change (kernel, glibc, binutils, gcc, sysvinit,
  eudev, dbus, elogind, GRUB — the "human review required" list
  in [ADR-008](ADR-008-renovate-and-release.md)). CI consumes it via
  `gh release download`.

## Implementation

### VM-driver abstraction

A new shim lets the same scripts drive Tart locally and qemu in CI:

```
scripts/vm-helpers.sh        # autodetects driver; exports vm_* API
  ├── if uname=Darwin  or VM_DRIVER=tart:  source scripts/tart-helpers.sh
  └── else (Linux)     or VM_DRIVER=qemu:  source scripts/qemu-helpers.sh
```

API surface (mirrors what `tart-helpers.sh` already provides):

```
vm_exists <name>
vm_clone <src> <dst>
vm_delete <name>
vm_run_detached <name> [--disk <path>:<opts>...]
vm_wait_ssh <name> <user>
vm_ssh <name> <user> [-- <cmd>...]
vm_ip <name>
vm_stop <name>
vm_export_raw_img <name> <out.img>
```

### Existing entrypoints UNCHANGED

- `tools/build-all.sh <image>`
- `tools/package-platform.sh <image> <arch> <platform>`
- `tools/promote.sh`
- `tests/boot-smoke.sh`, `tests/minimal-smoke.sh`, `tests/wayland-session.sh`
- `tests/installer/profile-*.sh`, `tests/installer/run-all.sh`
- `scripts/run-installer-test.sh`, `scripts/validate-installed.sh`

Internal call sites migrate `tart_*` → `vm_*`. Driver autodetect picks
the right backend at source time.

### Three-PR migration plan

1. **PR: `vm-helpers` abstraction.** Introduce `scripts/vm-helpers.sh`.
   Rename internal call sites (`tart_clone` → `vm_clone`, etc.). Pure
   refactor; CI behavior identical. Adds a path filter to `build.yml`
   so docs-only PRs don't trigger the heavy build jobs.
2. **PR: qemu driver.** Add `scripts/qemu-helpers.sh` implementing the
   `vm_*` API via `qemu-system-aarch64 -machine virt -accel kvm`. Add
   `VM_DRIVER=qemu` env override. Local Mac users still default to
   Tart. Add `tools/get-base-image.sh` to fetch a published
   `gnunix-base` artifact (or use a local Tart VM if present).
3. **PR: migrate CI jobs.** Move `gnunix-minimal`, `gnunix-desktop`,
   `gnunix-installer`, `installer-test`, `package`, and `release.yml`
   off `[self-hosted, macOS, arm64, tart]` and onto
   `ubuntu-22.04-arm`. Mark `gnunix-base` job as
   `workflow_dispatch`-only (manual toolchain-bump rebuild), drop it
   from the required-status-checks ruleset. Self-hosted Mac runner
   becomes optional, used only when the maintainer manually triggers
   a full base rebuild.

## What changes from ADR-008

ADR-008's pipeline shape line "GH Actions: build affected images on
macOS arm64 runner → run boot-smoke + wayland-session tests inside
Tart" is **superseded for routine CI**. The new shape is:

```
PR / push:
  Renovate or developer PR
    → ubuntu-latest:    lint (shellcheck, actionlint, gitleaks, manifest-schema)
    → ubuntu-22.04-arm: layer images (nix, desktop, installer) under qemu+KVM
                        run boot-smoke + minimal-smoke + wayland-session
                        run installer-test matrix
                        run package matrix
    → on green: auto-merge userland bumps (ADR-008 unchanged here)
  push tag v*:
    → ubuntu-latest: release.yml assembles + publishes (ADR-008 unchanged)

Toolchain-pin bump (kernel/glibc/gcc/binutils/sysvinit/eudev/dbus/
                    elogind/GRUB — the "human review required" set):
  Maintainer (locally on Mac):
    → tools/build-all.sh gnunix-base   (~6–10 h with Tart)
    → tools/promote-base.sh            (uploads .img.zst to GH Release)
  PR validation then proceeds normally.
```

The rest of ADR-008 stands: Renovate as the bump source, auto-merge
userland but human-review base, GitHub Releases as the artifact host,
`tools/manifest.json` as the pin map.

**ADR-008 is amended, not superseded** — the runner topology and the
treatment of `gnunix-base` change; the dependency-update and release
model do not. A back-pointer is added to ADR-008.

## Consequences

- **PR feedback loop unblocks**: lint + layering + tests all run on
  free hosted runners. Wall clock ~30 min per PR vs. ~7 h for a
  from-scratch base build.
- **Base rebuilds become explicit release events**: when Renovate
  proposes a kernel/glibc/gcc/etc. bump, the maintainer runs
  `tools/build-all.sh gnunix-base` locally, runs `tools/promote-base.sh`
  (new), and the new base lands as a GH Release that downstream CI
  consumes.
- **Cross-OS dev story improves**: a Linux contributor can
  `VM_DRIVER=qemu tools/build-all.sh gnunix-minimal` locally without
  needing a Mac. Tart stops being a hard requirement for development;
  it's just the fastest local backend on Apple Silicon.
- **No paid infra**. Free public-repo arm64 hosted runners cover
  routine CI; the maintainer's Mac covers base builds.
- **One scripts API** keeps cognitive load low: same `tools/`,
  `tests/`, `scripts/` commands work in both environments.
- **Hybrid still possible**: if a self-hosted Mac runner gets
  provisioned later, the `gnunix-base` job can re-enable on PR. The
  abstraction doesn't preclude that.

## Out of scope

- Funding a self-hosted Mac runner. If the project audience grows
  and full-on-every-PR base rebuild becomes valuable, revisit
  (e.g., MacStadium ~$60/month per M2 mini, or hosted self-hosted
  M2 runners on GitHub at ~$0.16/min).
- Cross-arch CI (x86_64). The hosted arm64 runners are arm64-only.
  When `nuc-installer` x86_64 path comes online per
  [ADR-010](ADR-010-multi-arch-and-platforms.md) Phase 5, a separate
  Linux x86_64 runner is needed (also free for public repos).
- **Visual smoke** (capture a rendered Wayland frame). Same
  out-of-scope status as in [ADR-009](ADR-009-wayland-stack.md).
  Tracked in `docs/TODO.md`.

## Revisit when

- A self-hosted Mac runner becomes available (re-enable
  `gnunix-base` as a PR-gated job).
- `qemu-system-aarch64 -accel kvm` ceases to be available on
  GitHub-hosted arm64 runners (unlikely; documented for the future
  reader).
- x86_64 path goes live and needs its own runner story.

## Remediation for the stuck branch-protection PR

The bootstrap PR for the `main-protection` ruleset (PR #1) is
blocked by the very rules it sets up. Two paths to unblock:

1. **One-time admin bypass** to merge PR #1
   (`current_user_can_bypass: pull_requests_only` in the ruleset).
2. **After this ADR is merged**, update the ruleset's
   `required_status_checks` to drop `gnunix-base`, `gnunix-minimal`,
   `gnunix-desktop`, `gnunix-installer` (none of which have a
   working runner) and add the new hosted-runner checks once the
   migration PRs land:
   - `installer-test (minimal)`
   - `installer-test (desktop-sway)`
   - `package (gnunix-minimal / aarch64 / generic-uefi)`
   - `package (gnunix-desktop / aarch64 / generic-uefi)`

Order of operations: bypass-merge PR #1 → merge this ADR → land the
three migration PRs → tighten the ruleset with the new check names.

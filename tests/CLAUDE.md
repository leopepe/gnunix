# CLAUDE.md — `tests/`

Guidance for Claude Code sessions working **inside `tests/`** or
when the user asks to create, run, modify, or wire up image
acceptance / smoke tests.

Load this file when the user's request touches:

- Anything under `tests/` (top-level `*-smoke.sh`, `wayland-session.sh`,
  the `installer/` subtree, or any new test set added beside them).
- The shell-based image validators they delegate to — `scripts/validate-*.sh`,
  `scripts/run-installer-test.sh` — when the change is *test-shaped*
  rather than orchestration-shaped.
- Adding a new image acceptance test for a new image, profile, or
  variant.

If the task is about *how images are built* (not how they're tested),
load [`images/CLAUDE.md`](../images/CLAUDE.md) instead. If it's about
CI wiring, load [`.github/CLAUDE.md`](../.github/CLAUDE.md).

## Authority and precedence

This file documents **how tests are shaped, written, and triggered.**
It does not redefine **what** is tested or **why**. Rationale lives
in the ADRs, and they win on every conflict:

1. **Root [`CLAUDE.md`](../CLAUDE.md)** — guiding philosophy and
   `What NOT to do`. Still applies inside `tests/`.
2. **[`images/CLAUDE.md`](../images/CLAUDE.md)** — defines *which*
   tests gate *which* images (boot-smoke for base, minimal-smoke
   for minimal, wayland-session for desktop, installer profiles
   for the installer ISO).
3. **`docs/adrs/`** — load-bearing decisions. The ADRs most relevant
   to this directory:

   | ADR | Why it governs tests here |
   |---|---|
   | [ADR-009](../docs/adrs/ADR-009-wayland-stack.md) | Wayland-only display; "render a frame in CI" is explicitly out of scope. Tests assert *substrate*, not pixels. |
   | [ADR-015](../docs/adrs/ADR-015-installer-and-sessions.md) | Defines the four installer profiles (`minimal`, `desktop-sway`, `desktop-hyprland`, `desktop-labwc`) and mandates one test per profile under `tests/installer/`. |
   | [ADR-016](../docs/adrs/ADR-016-ci-split-build-and-validation.md) | Routine CI runs on free `ubuntu-22.04-arm` + qemu+KVM; `scripts/vm-helpers.sh` is the driver abstraction. Tests must work under both Tart (local Mac) and qemu (CI). |
   | [ADR-017](../docs/adrs/ADR-017-live-iso-architecture.md) | Live ISO is squashfs + overlayfs + custom initramfs. A future `tests/installer/iso-boot.sh` asserts the TUI auto-launches on tty1. |
   | [ADR-019](../docs/adrs/ADR-019-image-lineage-and-installer-pivot.md) | Installer layers on `gnunix-minimal`, not `gnunix-desktop`. Live env is text-only — there is no greetd session menu to test. PR-gate runs `minimal` + `desktop-hyprland`; `desktop-sway` and `desktop-labwc` are nightly / tag-build. |
   | [ADR-020](../docs/adrs/ADR-020-compositor-switch-hyprland.md) | Hyprland is the reference compositor. `desktop-hyprland` is the default PR-gate desktop profile. |
   | [ADR-021](../docs/adrs/ADR-021-no-self-hosted-runners.md) | No self-hosted runners — ever. Tests cannot assume Tart in CI; the macOS host runs them locally, CI runs them via qemu+KVM. |

Whenever you touch this layer, re-read the relevant ADR rather than
paraphrasing from memory. If a proposed change would require
testing something an ADR has placed out of scope (e.g. driving an
actual Wayland frame, X11 fallback, RAID/LUKS install), **stop and
surface the conflict** — open an `adr_proposal.yml` issue instead of
silently extending the test surface.

## What lives here

```
tests/
├── CLAUDE.md
├── base/                       # gnunix-base   acceptance gate (Phase 2)
│   └── boot-smoke.sh
├── minimal/                    # gnunix-minimal acceptance gate (Phase 3)
│   └── minimal-smoke.sh
├── desktop/                    # gnunix-desktop acceptance gate (Phase 4)
│   └── wayland-session.sh
├── installer/                  # gnunix-installer per-profile gate (Phase 5)
│   ├── README.md               # detailed flow + per-profile assertion table
│   ├── run-all.sh              # all four profiles, summary at end
│   ├── profile-minimal.sh
│   ├── profile-sway.sh
│   ├── profile-hyprland.sh
│   └── profile-labwc.sh
│
├── boot-smoke.sh        ──▶ base/boot-smoke.sh           (compat symlink)
├── minimal-smoke.sh     ──▶ minimal/minimal-smoke.sh     (compat symlink)
└── wayland-session.sh   ──▶ desktop/wayland-session.sh   (compat symlink)
```

**Conventions captured in the layout:**

- **One directory per test set.** Each image (`base`, `minimal`,
  `desktop`, `installer`) gets its own subdirectory under `tests/`,
  *even when it currently holds a single scenario*. A new image,
  variant, or top-level concern (e.g. a future `iso/` set for the
  live-ISO TUI tests per ADR-017) gets a new sibling directory —
  never an inline `.sh` at the top level.
- **Entry points are thin wrappers.** Each `tests/<set>/<scenario>.sh`
  resolves `REPO_ROOT` and `exec`s into a `scripts/validate-*.sh` (or
  `scripts/run-installer-test.sh`) that does the real work. Keep them
  thin. Heavy logic (VM lifecycle, SSH waits, chrooted asserts) lives
  under `scripts/`; the entry-point's job is to be the *stable name*
  a reviewer or a workflow file references.
- **Compat symlinks at the old top-level paths** keep `tests/boot-smoke.sh`,
  `tests/minimal-smoke.sh`, and `tests/wayland-session.sh` working for
  the many ADRs, runbooks, build-script echo lines, PR/issue
  templates, and `docs/architecture.md` references that still point
  at the pre-refactor names. **These symlinks are transitional**;
  they exist purely to keep the rename's blast radius small. Tracked
  for removal in the follow-up GitHub issue (see
  *Transitional compat symlinks* below).
- **A `README.md` inside a test-set directory is optional.** Add one
  only when the per-set workflow needs it — see
  [*Per-set `README.md` — when and what*](#per-set-readmemd--when-and-what).

## Language and shell conventions

**Shell scripts are the predominant language here. Do not introduce
Python, Go, or a new test framework unless an ADR sanctions it.**
The base layer is sysvinit + GNU coreutils on purpose (root
`CLAUDE.md` → *Guiding philosophy*); the test layer mirrors that
attitude.

Rules (in addition to the project-wide shell conventions in the root
`CLAUDE.md`):

- **`#!/bin/sh`** by default. `bash` only when actually using bash
  features (arrays, `[[ ]]`, `set -o pipefail`); say so on the
  shebang line. The current `tests/*.sh` and `tests/installer/*.sh`
  are all `/bin/sh`.
- **`set -eu`** at the top of every script. Add `set -o pipefail`
  only after switching the shebang to `bash`. Entry-point scripts
  that intentionally tolerate partial failures (e.g. `run-all.sh`,
  which continues past a failing profile to print a summary) use
  `set -u` only and document why in a header comment.
- **No silent `cd`.** Compute paths from `REPO_ROOT`. With the
  one-dir-per-set layout, every test entry point sits at
  `tests/<set>/<scenario>.sh`, so the standard form is:

  ```sh
  REPO_ROOT=${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
  ```

  Existing scripts under `installer/` follow this. The three
  per-image scripts (`base/`, `minimal/`, `desktop/`) also need a
  POSIX symlink-resolving preamble so they keep working when invoked
  through the transitional compat symlinks at the old top-level
  paths — see [*Transitional compat symlinks*](#transitional-compat-symlinks) below for the canonical snippet.
- **Exit non-zero with a one-line reason on failure.** The image
  validators echo `FAIL: <reason>` and exit; reviewers and CI logs
  rely on that single line. The root `CLAUDE.md` makes this an
  explicit `tests/` rule.
- **`expect`-driven tests are allowed** for terminal/TTY harnessing
  (e.g. driving the whiptail TUI when unattended mode isn't enough,
  or retrofitting an SSH key into a snapshot — see
  `tools/install-builder-key.sh` for the pattern). Use `expect`
  only when stdin/stdout scripting genuinely can't express the
  flow; prefer env-var unattended mode (`GNUNIX_INSTALL_UNATTENDED=1`
  etc.) whenever the underlying program supports it.
- **VM driver abstraction.** Per ADR-016, tests must not assume
  Tart. Source `scripts/vm-helpers.sh` (or `scripts/tart-helpers.sh`
  when the script is local-Mac-only by design) and use its
  abstractions for create / boot / ssh / stop. Hard-coding `tart`
  in a new test path is a bug — surface it.
- **Shellcheck clean.** The repo has `.shellcheckrc`; the
  pre-commit hook runs shellcheck on changed shell files. New
  tests must pass shellcheck without inline disables, or document
  any disable inline with the reason.

## Where logic goes (test vs. validator vs. orchestrator)

Three layers, with a clear write scope each:

| Layer | Path | Role |
|---|---|---|
| **Entry point** | `tests/<image>-<concern>.sh` or `tests/<set>/<scenario>.sh` | Stable name. Sets `REPO_ROOT`. `exec`s the validator/orchestrator with the right args. Almost no logic. |
| **Validator** | `scripts/validate-<image>.sh`, `scripts/validate-installed.sh` | The actual *assertions*. SSH into the VM and run sanity checks; print `FAIL: …` and exit non-zero on the first broken invariant. |
| **Orchestrator** | `scripts/run-installer-test.sh`, `scripts/tart-helpers.sh`, `scripts/vm-helpers.sh` | Multi-phase lifecycle (clone → boot → install → reboot → validate), VM helpers, idempotency / cleanup. |

Rules:

- A new top-level test under `tests/` is **a name and a one-line
  `exec`** unless the flow is genuinely simple (one SSH, one check).
  Resist embedding assertion logic in the entry point — that's
  what the validator is for.
- A new validator under `scripts/` is reusable across entry points
  (e.g. `validate-installed.sh` is shared by all four installer
  profile tests, parameterised by profile name).
- A new orchestrator under `scripts/` graduates a one-shot helper
  to a reused one (root `CLAUDE.md` → *Where things go*).
- If a new test starts as one script but you can already see a
  validator + orchestrator split coming (e.g. "I'll inline this
  for now and refactor later"), do the split up front. It's cheap
  early, expensive once two callers exist.

## Per-set `README.md` — when and what

A `README.md` is **optional** inside a test-set directory; the
default is "no README — the script's header comment is enough".

Add one when **any** of the following is true:

- Multi-phase flow (e.g. `installer/`: install → reboot → assert)
  whose ordering isn't obvious from reading one script.
- Per-scenario assertion tables that don't fit in a script header
  (e.g. the universal-vs-per-profile checks in
  [`installer/README.md`](installer/README.md)).
- Preserved-on-failure artifacts the maintainer needs to reproduce
  (locations, how to re-enter the VM, when they get cleaned up).
- A real divergence from the standard "thin entry point → validator"
  pattern that future authors need to be warned about.
- CI integration that's load-bearing for the test set (which jobs
  run which scripts, why some are nightly, etc.).

Keep the README scoped to the test set. Do not restate the locked
decisions, the shell conventions, or the validator contract — link
back to this file or the relevant ADR.

If the only thing a README would say is "this script tests X",
delete the README and put that line in the script's header
comment instead.

## Authoring new tests: Given-When-Then scenarios

**All new tests are written as Given-When-Then scenarios.** The
scenario is captured in the **header comment block** of the entry
point script, immediately under the shebang and the one-line
purpose. The body of the script is the executable realisation of
that scenario.

This is the documented contract for a test, in plain English, for
future reviewers and for the ADR → architecture sync workflow.
*One scenario per entry-point script.* If you have N scenarios,
write N scripts (and put them in a test-set directory if N > 1).

### Template

```sh
#!/bin/sh
# tests/<set>/<scenario>.sh <args…>
# <one-line purpose>
#
# Scenario: <imperative one-liner naming what is verified>
#
# Given:
#   - <precondition 1, e.g. a built VM artifact, env var, or fixture>
#   - <precondition 2>
#   - …
# When:
#   - <action 1, the trigger under test>
#   - <action 2>
# Then:
#   - <observable outcome 1 — must be assertable via shell + ssh>
#   - <observable outcome 2>
#   - <…>
#
# Exit codes:
#   0  scenario passed
#   1  scenario failed (a `Then` clause did not hold)
#   2  test harness error (missing VM, bad arg, etc.)

set -eu
REPO_ROOT=${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
exec "$REPO_ROOT/scripts/<validator>.sh" "<args>"
```

If the entry point is *also* reachable through a transitional compat
symlink at an older path, insert the symlink-resolving preamble
shown under [*Transitional compat symlinks*](#transitional-compat-symlinks).
New tests added after this refactor do **not** need the preamble —
they have no legacy callers to keep working.

### Rules for the GWT block

1. **Given** lists only preconditions the *test runner* must
   ensure before the script runs (built image, env vars, network).
   Do not list "user has a working LFS toolchain" — that's
   architecture, not a test precondition.
2. **When** is the *single* action the scenario is exercising
   (boot the VM, run the installer in unattended mode, switch a
   profile). If you find yourself listing four independent `When`
   actions, you have four scenarios and you should split.
3. **Then** clauses are observable and assertable via shell on the
   VM (a file exists, a process is running, `nix --version`
   succeeds, a binary is in the system profile). "Renders correctly"
   is not a Then clause — it's not assertable from CI and ADR-009
   places it out of scope.
4. The implementation **must match the GWT block.** If the
   validator skips one of the listed Then assertions, either fix
   the validator or remove the clause; don't lie to reviewers by
   listing assertions you don't actually run.
5. Worked example: every script under `tests/installer/profile-*.sh`
   already follows this shape (purpose line + one-liner +
   `exec scripts/run-installer-test.sh <profile>`). When you add a
   new test, expand the header to a full GWT block; existing
   scripts may be retrofitted opportunistically when they're edited
   for another reason — don't open a churn PR just for GWT
   headers.

### What goes in the matching validator

The validator (`scripts/validate-*.sh`) implements the **Then**
clauses as a sequence of shell asserts inside an SSH-into-VM block.
One assert per Then clause, in the same order, with a one-line
`FAIL: …` message on the first miss. See
[`scripts/validate-boot.sh`](../scripts/validate-boot.sh) for the
canonical shape.

## Triggering tests

### Locally (developer Mac, Tart)

Tests are designed to be runnable by hand against locally-built
Tart VMs. The prerequisite is that the VM the test targets has
been built or fetched — see [`images/CLAUDE.md`](../images/CLAUDE.md).

```sh
# Built locally via tools/build-all.sh, or fetched via tools/fetch-image.sh.
# Canonical paths (post-refactor):
tests/base/boot-smoke.sh           gnunix-base-0.1.0
tests/minimal/minimal-smoke.sh     gnunix-minimal-0.2.0
tests/desktop/wayland-session.sh   gnunix-desktop-0.2.0

# The compat symlinks still work (used by older docs and ADRs):
tests/boot-smoke.sh                gnunix-base-0.1.0
tests/minimal-smoke.sh             gnunix-minimal-0.2.0
tests/wayland-session.sh           gnunix-desktop-0.2.0

# Installer: single profile, then all profiles:
tests/installer/profile-minimal.sh
tests/installer/run-all.sh
```

Things to know:

- All tests honour `REPO_ROOT` if set; otherwise they compute it
  from the script's own location. CI sets it explicitly; you don't
  need to.
- Installer tests preserve their artifacts on failure under
  `cache/installer-test/<profile>-target.img` and leave the
  installed VM (`gnunix-installed-<profile>`) on disk for inspection.
  Successful runs clean up. See
  [`installer/README.md`](installer/README.md) for re-entry.
- Boot tests start the VM in headless mode (`tart run
  --no-graphics`) and SSH in. The trap kills the VM on exit; don't
  add a second `tart stop` in the test body.

### In CI (ADR-016 + ADR-021)

Per ADR-021, there are **no self-hosted runners ever.** Tests run on:

- Free `ubuntu-22.04-arm` for arm64 image validation under qemu+KVM,
  via `scripts/vm-helpers.sh` (ADR-016).
- The maintainer's local Mac for the rare `gnunix-base` rebuild,
  whose artifacts ship as a GH Release and are fetched by CI.

The PR-gate vs nightly split per ADR-019:

| Test | Runs on |
|---|---|
| `tests/base/boot-smoke.sh` | Every PR that touches `images/gnunix-base/` or anything it depends on |
| `tests/minimal/minimal-smoke.sh` | Every PR that touches `images/gnunix-minimal/` or `bundles/` consumed by it |
| `tests/desktop/wayland-session.sh` | Every PR that touches `images/gnunix-desktop/` |
| `tests/installer/profile-minimal.sh` | Every PR that touches `images/installer/` |
| `tests/installer/profile-hyprland.sh` | Every PR that touches `images/installer/` (default desktop profile per ADR-020) |
| `tests/installer/profile-sway.sh` | Nightly + tag builds |
| `tests/installer/profile-labwc.sh` | Nightly + tag builds |

If you add a new test, document its CI trigger in the test set's
README (or in this table, if it's a top-level test) and wire it up
in `.github/workflows/build.yml` in the same PR — don't ship a
test that nothing invokes.

### Validation evidence in PR bodies

The PR template asks which smoke tests ran. Tick only what you
actually ran (root `CLAUDE.md` → *Content rules*). If a test was
skipped because it requires hardware you don't have (e.g. a
specific platform variant), note that under *Reviewer notes* rather
than ticking falsely.

## What is intentionally NOT tested here

Test scope is constrained by the same ADRs that constrain image
scope. Do not extend the test surface across these lines without a
new ADR:

- **Pixel-level Wayland rendering.** ADR-009 places "render a frame
  in CI" out of scope. Wayland tests assert *components present and
  supervised* (greetd up, dbus + elogind running, compositor binary
  in the system profile, user in the right groups). They do not
  drive a compositor to paint pixels.
- **Whiptail TUI interactions.** ADR-015 + ADR-019 keep the
  unattended path (`GNUNIX_INSTALL_UNATTENDED=1` + env vars) as the
  test interface. Testing the TUI's radiolist, password prompts,
  and edition→compositor→identity flow needs a tty harness
  (`expect`) and is deferred.
- **Reinstall / upgrade-in-place.** v1 installer is single-shot
  per ADR-015. Don't test what the system doesn't support.
- **Encrypted root, multi-disk, RAID, LVM.** Out of scope per
  ADR-015.
- **X11 / XWayland.** Wayland-only per ADR-009. There is nothing
  to assert about X11 here because there is no X11 in the base.
- **Self-hosted CI behaviour.** Per ADR-021 there is no
  self-hosted runner; a test that requires one is, by definition,
  not landable.

If a task seems to require testing one of the above, stop and open
an `adr_proposal.yml` issue (root `CLAUDE.md` → *Opening issues and
pull requests*).

## Transitional compat symlinks

The three pre-refactor top-level entry points are kept as **relative
symbolic links** so existing references in ADRs, runbooks, the PR
template, `docs/architecture.md`, and the per-image `build.sh` echo
lines continue to resolve:

```
tests/boot-smoke.sh        ─▶  base/boot-smoke.sh
tests/minimal-smoke.sh     ─▶  minimal/minimal-smoke.sh
tests/wayland-session.sh   ─▶  desktop/wayland-session.sh
```

These exist to **reduce the blast radius** of the rename. They are
not a load-bearing feature; once every caller has been migrated to
the canonical `tests/<set>/<scenario>.sh` form, the symlinks come
out. This is tracked in a follow-up GitHub issue linked from the PR
that introduced the refactor — search the issue tracker for *compat
symlinks* if you need the live link.

Because POSIX shells leave `$0` as the *invocation* path (symlinks
are not resolved automatically), the canonical scripts behind a
compat symlink **must** resolve `$0` before computing `REPO_ROOT`,
or they'll mis-locate the repo root when called through the old
name. The canonical snippet (copy verbatim):

```sh
set -eu

# Resolve $0 through the compat symlink at the old path so REPO_ROOT
# computes correctly whether we were invoked as tests/<scenario>.sh
# or as tests/<set>/<scenario>.sh. POSIX-safe; `readlink` without `-f`
# works on both macOS and Linux.
SCRIPT=$0
while [ -L "$SCRIPT" ]; do
  TARGET=$(readlink "$SCRIPT")
  case "$TARGET" in
    /*) SCRIPT=$TARGET ;;
    *)  SCRIPT=$(dirname "$SCRIPT")/$TARGET ;;
  esac
done
REPO_ROOT=${REPO_ROOT:-$(cd "$(dirname "$SCRIPT")/../.." && pwd)}
```

Rules:

- **Do not add new compat symlinks** for tests created after this
  refactor. They exist only to bridge the rename of the three
  pre-existing top-level scripts.
- **Do not promote a canonical test path to a symlink.** The
  canonical entry point is the real file at `tests/<set>/<scenario>.sh`.
  The symlinks at the top level point *at* it, not the other way
  around.
- **Removing the symlinks** is a separate PR. The conditions are:
  every reference in `docs/`, `.github/`, `runbook.md`, and the
  `images/*/build.sh` echo lines has been switched to the canonical
  path; the follow-up issue is the gate.
- **Until removed**, the symlink-resolving preamble stays on the
  three migrated scripts. Once the symlinks are gone, the preamble
  collapses back to the standard one-liner shown in the GWT
  template.

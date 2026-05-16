# CLAUDE.md

Guidance for Claude Code sessions working in this repo.

## What this project is

**GNUnix** — a custom Linux distribution for **developer workstations**, shipped
as **Tart VM images** on Apple Silicon. The name is a pun: GNU + Nix, also
reads as "GN[U] Unix". Two layers:

1. **LFS base** (built from source, arm64). Slackware-inspired: `sysvinit` + BSD `/etc/rc.d/` scripts. Minimal, hand-curated, changes rarely.
2. **Nix layer** (multi-user nixpkgs daemon + home-manager). Owns everything user-visible: Wayland compositor, portals, fonts, apps, dev tools. Changes constantly.

Strategy doc: `~/Documents/hyground/analysis/gnunix-nix-wayland-distro-strategy.md`.

> **Project was renamed `lfs-nix-distro` → GNUnix** per
> [ADR-013](docs/adrs/ADR-013-rename-to-gnunix.md), with a second
> internal rename `gnunix-nix` → `gnunix-minimal` per
> [ADR-019](docs/adrs/ADR-019-image-lineage-and-installer-pivot.md).
> The image lineage is now `lfs-{core,nix,wayland,builder}` →
> `gnunix-{base,minimal,desktop,builder}` plus the new
> `gnunix-installer` (live ISO). Historical ADRs 001–012 keep
> pre-rename names; everything else uses the current names.

## Guiding philosophy (load-bearing)

GNUnix is a deliberate sandwich: a GNU coreutils + `sysvinit` base from
the 1990s, a Wayland + Nix userland from the 2020s, and nothing in
between pretending to be middleware. It is *not* a general-purpose
distro; it's a developer workstation that took strong opinions and wrote
them down as ADRs so nobody has to argue about them twice.

The base layer is **Slackware-lineage on purpose.** Patrick Volkerding
named his distro after the SubGenius pursuit of *Slack* and proved that
an init system you can read in an afternoon is the most Slack-maximizing
thing on the disk. We inherit those priorities directly: BSD-style
`/etc/rc.d/`, `chmod +x` toggling, `sysvinit` as PID 1, GNU coreutils
everywhere, no policy daemons in the boot path. The Nix and Wayland
layers are new; the *attitude* is 1993. Praise "Bob."

The load-bearing rules:

- **Static base, dynamic userland.** The LFS layer is boring on purpose.
  Anything that evolves week-to-week belongs in Nix, not in `/etc`. If
  you find yourself patching `/etc/` to ship a feature, you're in the
  wrong layer.
- **No policy in PID 1.** Init does init. No service supervisor, no
  D-Bus-coupled init, no "declarative dependency graph." `sysvinit`
  starts `rc.S`, `rc.S` runs scripts, scripts exit. End of story.
- **Boring base, declarative top.** System config lives in shell scripts
  and a few text files. User config lives in `home-manager`. There is
  no third layer; resist the urge to invent one.
- **GNU userland, unapologetically.** `coreutils`, glibc, GCC, bash —
  the GNU stack, compiled from source. No `busybox`, no `musl`, no
  drop-in replacements "for size." If a tool exists in coreutils, use
  it; don't reach for a third-party rewrite because it has a logo.
- **Wayland-only display, compositor-agnostic.** We ship the substrate
  (`elogind`, `dbus`, portals, `seatd` where relevant). We do not ship
  X11 or XWayland in the base. We do not pick the compositor for the
  user — `sway` is the *reference* session, not the *only* session.
- **No desktop environment in the base image.** GNOME and KDE are
  excellent and explicitly out of scope. GNUnix gives the user a TTY,
  a working Nix, and a Wayland-capable kernel; what they build on top
  is their problem and Nix's strength.
- **Old where it works, new where it helps.** `sysvinit` because it
  still boots in under a second and you can read it. Nix because it
  solved dependency hell. Wayland because X11 didn't age well. We are
  not nostalgic *or* trend-chasing — we picked each layer on merit and
  wrote an ADR explaining why.
- **Simple, direct, objective.** One concern per script, one decision
  per ADR, one reason per commit. If something feels clever, it is
  probably wrong for this codebase. Clever costs Slack; Slack is the
  point.

When proposing changes, ask in order:

1. *Does this belong in the static base or the dynamic userland?* If
   unsure, default to userland (Nix).
2. *Is this something the user should choose, not us?* If yes, ship the
   substrate, not the choice. (Compositors, editors, shells, fonts,
   browsers — all user choice.)
3. *Does an ADR already answer this?* Check the locked-decisions table
   below before designing around it.

## Locked decisions — do not relitigate without an ADR update

See `docs/adrs/` for full rationale. Summary:

| # | Decision | Out-of-scope alternatives |
|---|---|---|
| 001 | `sysvinit` + BSD `/etc/rc.d/` | systemd, OpenRC, s6, dinit, runit |
| 002 | `elogind` for seat management | systemd-logind, seatd |
| 003 | Multi-user Nix daemon | Single-user, no Nix |
| 004 | Plain Nix profiles + home-manager | NixOS modules, flakes-as-system |
| 005 | Developer workstation, this Mac first | Server, multi-machine fleet |
| 006 | GRUB EFI bootloader | systemd-boot, rEFInd |
| 007 | LFS-ARM (arm64) | x86_64 LFS, NixOS base |
| 008 | Renovate PRs + GitHub Releases for image publishing | Dependabot, ad-hoc bumps, registry-only delivery |
| 009 | Sway compositor + greetd; dbus/elogind/sway from nixpkgs into `/nix/var/nix/profiles/system` | GNOME (systemd-bound), gnome-session, X11-only WMs |
| 010 | Multi-arch + per-platform packagers (`generic-uefi`, `rpi-native`, `nuc-installer`); i686 out of scope | One-image-fits-all, per-arch fork |
| 011 | Compile-time hardening: `_FORTIFY_SOURCE=3`, SSP, stack-clash, PIE, RELRO+BIND_NOW, `-mbranch-protection=standard` | Defaults-only, blanket `-Werror`, `-fstack-protector-all` |
| 012 | Module-first kernel: boot-critical drivers `=y`, rest `=m`, auto-loaded by eudev MODALIAS | Monolithic `=y` everywhere, initramfs |
| 013 | Project renamed to GNUnix | Keep placeholder `gnunix` |
| 014 | AI PR review: blocking `pr-lint.yml` + opt-in advisory `ai-review.yml` (provider-agnostic, OpenAI-compatible API; OpenRouter free-tier default) driven by `.claude/skills/pr-review/` | Always-on AI review, blocking AI review, vendor-locked review (Anthropic-only / OpenAI-only) |
| 015 | Live installer (`gnunix-installer`) + 5 Wayland-only profiles (`minimal`, `desktop-sway`, `desktop-hyprland`, `desktop-labwc`, `desktop-cosmic`); whiptail TUI; pull compositor closures at install time. *(Amended by ADR-022 — added `desktop-cosmic`.)* | Bundle-every-compositor, X11/Xorg profiles, GUI installer |
| 016 | CI split: routine CI on free `ubuntu-22.04-arm` + qemu+KVM; `gnunix-base` rebuilds happen locally on Mac with Tart and ship as GH Release artifacts; `scripts/vm-helpers.sh` abstraction keeps entrypoints stable across drivers (amends ADR-008) | Paid self-hosted Mac runner, always-build-from-scratch CI, separate scripts for local vs CI |
| 017 | Live-ISO architecture for `gnunix-installer`: squashfs + overlayfs + custom minimal initramfs (busybox-static), packaged as hybrid EFI ISO via `xorriso`. Adds `CONFIG_SQUASHFS=m`, `CONFIG_OVERLAY_FS=m`, `CONFIG_ISO9660_FS=m`, `CONFIG_BLK_DEV_LOOP=m` to the module-first kernel (per ADR-012). | Raw-disk live image, dracut/mkinitcpio, BIOS-hybrid, copy-to-RAM |
| 018 | Three artifact types — `.iso` / `.img.zst` / `.tart.zst` — and a flat naming grammar `gnunix-<image>-<arch>[-<platform>]-<ver>.<ext>`. Four published images: `gnunix-base`, `gnunix-minimal`, `gnunix-desktop`, `gnunix-installer`. `gnunix-minimal` is the CI release-dependency anchor (downstream layers fetch it, not rebuild). Unified `tools/package.sh` replaces `tools/package-platform.sh`. (Amends ADR-008, ADR-010) | Per-image versioning, single-form-per-image, retained `-disk-` legacy form |
| 019 | Image lineage roles: installer pivots to layer on `gnunix-minimal` (text-only live env, all desktop installs pull-at-install). `gnunix-desktop` and `gnunix-installer` are siblings of `gnunix-minimal`, not chained. TUI flow: edition → compositor → identity. Live image has no greetd session menu (getty on tty1 auto-launches installer; tty2 = root shell). Finishes the `gnunix-nix → gnunix-minimal` rename. (Extends ADR-013, ADR-015) | Installer-on-desktop, flat 4-radio profile selection, offline desktop installs |
| 020 | Reference compositor switched from Sway to **Hyprland**. `gnunix-desktop` ships Hyprland pre-baked (with `xdg-desktop-portal-hyprland`, hyprpaper). Sway demoted to one of four optional installer profiles (sway / hyprland / labwc / cosmic), pulled at install time. (Amends ADR-009; amended by ADR-022 — added `desktop-cosmic`.) | Sway as default, Hyprland-as-variant-only, drop Sway entirely |
| 021 | **No self-hosted CI runners — ever.** Every workflow runs on free GitHub-hosted runners only (`ubuntu-22.04-arm` for arm64 jobs, `ubuntu-22.04` / `ubuntu-latest` for the rest). The `gnunix-base` rebuild (6–10 h) stays on the maintainer's *unmanaged* Mac and ships as a GH Release artifact; CI fetches it via `tools/fetch-image.sh`. `publish.yml` is retired. (Amends ADR-008, ADR-010, ADR-016) | Self-hosted Mac runner, paid GitHub-hosted macOS, third-party rented runners |
| 022 | Add **`desktop-cosmic`** as a fourth optional installer compositor — System76 COSMIC (init-agnostic, uses `dbus-run-session` not `systemd --user`, integrates with elogind per ADR-002). Pulled at install time per ADR-015/019; **not** pre-baked into `gnunix-desktop`. Hyprland remains the reference. (Amends ADR-015, ADR-020) | Pre-bake COSMIC, add GNOME/KDE, defer adoption, generic "fifth slot" plugin mechanism |

If a task seems to require violating a locked decision, **stop and surface the conflict** — don't silently work around it.

## Repo layout (monorepo)

```
docs/         — architecture, ADRs, runbooks
images/       — one subdir per Tart image, in build order
  gnunix-builder → gnunix-base → gnunix-minimal
                                      ├─> gnunix-desktop
                                      ├─> gnunix-installer
                                      └─> variants/
bundles/      — reusable Nix expressions
tools/        — pipeline programs (build-all, package, release)
scripts/      — small auxiliary helpers
tests/        — image acceptance / smoke tests, one directory per image:
              —   tests/base/     gnunix-base   (Phase 2: boot smoke)
              —   tests/minimal/  gnunix-minimal (Phase 3: nix daemon)
              —   tests/desktop/  gnunix-desktop (Phase 4: wayland session)
              —   tests/installer/ gnunix-installer (Phase 5: profiles)
              — See `tests/CLAUDE.md` for layout rules, GWT scenario
              — format, and the transitional compat symlinks at the old
              — top-level paths.
runbook.md    — index of other runbooks in `docs/runbooks/`
```

After [ADR-019](docs/adrs/ADR-019-image-lineage-and-installer-pivot.md),
`gnunix-desktop`, `gnunix-installer`, and `variants/` are siblings
layered on `gnunix-minimal` — not a single linear chain.

**Where things go:**

- Image-specific config (rc scripts, kernel config, session.nix) → `images/<name>/`. Never outside.
- Reusable Nix bundles (consumed by ≥2 images) → `bundles/`.
- Multi-image orchestration → `tools/`.
- One-shot helpers → `scripts/`. Graduate to `tools/` when reused.
- "Why we chose X" → `docs/adrs/ADR-NNN.md`. Code comments reference the ADR number; they do not re-explain.

## Conventions

### Shell scripts

- `#!/bin/sh` for portability where possible; `bash` only when actually using bash features.
- `set -eu` at the top. `set -o pipefail` if bash.
- No silent `cd`. Use absolute paths.
- Validation scripts in `tests/` exit non-zero on failure with a one-line reason.

### Nix

- Pin `nixpkgs` rev in `tools/manifest.json`. Bumps are explicit commits.
- `bundles/*.nix` are pure functions of `pkgs`; no side effects.
- Per-image `session.nix` composes bundles, doesn't redefine them.

### rc.d scripts (Phase 2 deliverable)

- One concern per script. `rc.<service>` enables/disables a single service.
- Enabled by `chmod +x` (Slackware convention). Disabled by `chmod -x`.
- `rc.M` calls per-service scripts in order; doesn't inline service logic.

### Tart images

- Image lineage is linear: each image forks from the previous tagged image.
- Tags follow `<name>:<semver>` (e.g. `gnunix-base:0.1.0`).
- A new image variant gets a new directory under `images/variants/`, never an inline branch in an existing image's build script.

## How to validate work

Boot tests are the real gate; type-checking and shell linting are
nice but not sufficient. Each image has a dedicated test set under
`tests/<image>/`:

- **`gnunix-base` change** → `tests/base/boot-smoke.sh <vm>` must pass (boot, DHCP, TTY login, dbus running, nix-daemon responsive).
- **`gnunix-minimal` / Nix-layer change** → `tests/minimal/minimal-smoke.sh <vm>` must pass (nix installed, multi-user daemon running, store query works).
- **`gnunix-desktop` / Wayland change** → `tests/desktop/wayland-session.sh <vm>` must pass (greetd → session → compositor on virtio-gpu → terminal opens).
- **`gnunix-installer` change** → `tests/installer/profile-<name>.sh` must pass for the affected profile(s); `tests/installer/run-all.sh` runs all four.

The three older entry points `tests/boot-smoke.sh`,
`tests/minimal-smoke.sh`, and `tests/wayland-session.sh` still work as
**transitional compat symlinks** pointing at the canonical paths
above. New work should call the canonical paths; the symlinks are
slated for removal once every reference (ADRs, runbooks, PR/issue
templates, `build.sh` echo lines) has migrated.

### Authoring or modifying tests

Whenever the task involves creating, deleting, restructuring, or
non-trivially editing anything under `tests/` — including adding a
brand-new test set for a new image or variant — **read
[`tests/CLAUDE.md`](tests/CLAUDE.md) first**. It is the
authoritative guide for:

- The one-directory-per-test-set rule (a new image gets a new
  sibling subdirectory; never an inline `.sh` at the top level).
- The shell-script language constraint (`#!/bin/sh` + `set -eu`,
  `bash` only when actually needed; no Python/Go/new framework
  unless an ADR sanctions it).
- The thin-entry-point / `scripts/validate-*.sh` validator /
  orchestrator split, including where each layer's logic belongs.
- The mandatory **Given-When-Then** header block on every new
  test entry-point script.
- When to add a per-set `README.md` (only for non-obvious flows
  like multi-phase install → reboot → assert, or per-scenario
  assertion tables that don't fit in a script header).
- The compat-symlink contract and its symlink-resolving preamble.
- Which tests gate which PRs (PR-gate vs nightly / tag-build per
  ADR-019 / ADR-020).
- The explicit out-of-scope list (no pixel-level Wayland
  rendering, no whiptail TUI interaction tests, no
  reinstall/upgrade/RAID/LUKS, no X11) — extending the test
  surface across those lines requires a new ADR, not just code.

If a task seems to require testing something `tests/CLAUDE.md`
places out of scope, stop and surface the conflict (open an
`adr_proposal.yml` issue) instead of silently extending the test
surface.

## What NOT to do

- Don't introduce systemd, even "just for one service." Adding it breaks ADR-001 and pulls in the entire systemd ecosystem (logind, networkd, resolved, journald) — the architecture explicitly rejects this.
- Don't add NixOS modules. If you find yourself wanting `configuration.nix`, the answer is home-manager or rc.d, not NixOS.
- Don't put service logic in `rc.S` or `rc.M`. Those are dispatchers.
- Don't add "fallback" or "compatibility" layers for hypothetical future requirements (per global guidance).
- Don't write README/CLAUDE/docs files unless asked or the task is explicitly documentation.
- Don't bump pinned versions opportunistically. Version bumps are their own commits with their own validation.

## Phase status

Track in `docs/architecture.md`. Current: **end of Phase 2 spec — `gnunix-base` build pipeline is complete and ready to be invoked.** The actual build and first Tart-test are the next human action; see `runbook.md` and `docs/runbooks/build.md`.

## Build pipeline (Phase 2 commands)

When the user asks to build, resume, or test `gnunix-base`, use these entry points (full details in `docs/runbooks/build.md`):

- `tools/phase2.sh` — gated end-to-end orchestrator: pre-fetch → bootstrap-builder → build-all → smoke-test, with `[y/N]` prompts between stages. `AUTO=1` skips prompts.
- `tools/build-all.sh gnunix-base` — the build step alone. Re-clones `gnunix-builder-build` from `gnunix-builder:base` (destructive).
- `REUSE_BUILDER=1 tools/build-all.sh gnunix-base` — **resume** mode. Keeps the existing `gnunix-builder-build` so completed in-VM stages (e.g. cross, ~3h) are not redone.
- `tools/install-builder-key.sh [vm]` — retrofit SSH key into an existing snapshot. Unattended via `expect` + documented `admin/admin`.
- `tools/fetch-sources.sh` — host-side pre-fetch with mirror fallback. Stage 0 of `phase2.sh`.

**Persistence gotcha to remember:** the cirruslabs Ubuntu rootfs is ext4 `commit=30`. Any script that writes state and then `tart stop`s must `ssh admin@vm 'sudo sync; sync'` first, or writes vanish on next boot. All current scripts do this; new ones must too.

## Updates and release flow (ADR-008)

- Pinned versions live in `tools/manifest.json`, `bundles/*.nix`, and image build scripts. **Don't** bump pins ad hoc.
- Renovate opens version-bump PRs. CI (macOS arm64 runner under `.github/workflows/build.yml`) rebuilds affected images and runs `tests/base/boot-smoke.sh` + `tests/desktop/wayland-session.sh` (the legacy `tests/boot-smoke.sh` / `tests/wayland-session.sh` compat symlinks still resolve — see `tests/CLAUDE.md`).
- **Auto-merge:** userland bumps (nixpkgs, bundles) that pass CI.
- **Human review required:** kernel, glibc, binutils, gcc, sysvinit, eudev, dbus, elogind, GRUB.
- Releases publish Tart images (`*.tart.tar.zst`) + `manifest.json` as GitHub Release artifacts via `tools/promote.sh`.

## Opening issues and pull requests

**Before you create an issue or open a PR — including any time the user asks
you to do so — read [`CONTRIBUTING.md`](CONTRIBUTING.md) first.** It is the
authoritative guide for contribution flow; this section only adds Claude-
specific instructions on top of it. If guidance here ever drifts from
`CONTRIBUTING.md`, `CONTRIBUTING.md` wins.

Mandatory reading triggers:

- The user asks you to **open, draft, file, or create** an issue or PR
  (via `gh`, the GitHub MCP, a web URL, or by writing the body to a file).
- The user asks you to **edit** an existing issue or PR body / title.
- You are about to suggest issue or PR text the user will paste themselves.

In all of those cases, re-read `CONTRIBUTING.md` in the same session — do
not rely on memory from a previous turn. Pay particular attention to
*Before you start*, *Submitting a pull request*, and *What we don't accept*.

### Always use the repository templates

GitHub stores templates under `.github/`. **Never** invent your own
structure; populate the existing template fields and delete the inline
HTML comments / placeholders you have actually filled in.

Pull requests:

- Template: [`.github/PULL_REQUEST_TEMPLATE.md`](.github/PULL_REQUEST_TEMPLATE.md).
- When using `gh pr create`, pass `--body-file` pointing at a body you
  generated from this template (or `--template PULL_REQUEST_TEMPLATE.md`).
  Do not use `--body "..."` with a hand-written summary that skips the
  template sections.
- Fill in: Summary, Why (link the issue / ADR), How validated (tick the
  smoke-test boxes that actually ran; don't tick what you didn't run),
  Locked-decisions check, Checklist.

Issues:

- Templates live in [`.github/ISSUE_TEMPLATE/`](.github/ISSUE_TEMPLATE/).
  Pick the one that matches the intent:
  - `bug_report.yml` — something is broken or behaves wrong.
  - `feature_request.yml` — new capability or enhancement.
  - `documentation.yml` — docs are missing, wrong, or unclear.
  - `adr_proposal.yml` — proposing a load-bearing decision (new ADR, or
    amendment to an existing one). Use this whenever a task seems to
    require violating a locked decision — surface the conflict here
    instead of working around it.
  - `question.yml` — architecture / usage question with no concrete bug.
- When using `gh issue create`, pass `--template <file>.yml` (e.g.
  `--template bug_report.yml`) and answer each form field. Do not bypass
  the form with a free-form `--body`.
- If no template fits, stop and ask the user which one to use rather than
  filing a template-less issue.

### Content rules (in addition to the templates)

- Reference the relevant ADR number(s) by ID — e.g. "per ADR-001" — for
  any claim about a locked decision. Don't paraphrase the rationale; link
  to it.
- Validation evidence must be real. If you didn't run
  `tests/base/boot-smoke.sh` (or the legacy compat symlink
  `tests/boot-smoke.sh`), don't tick its box. Note what you ran
  instead under *Other* or *Reviewer notes*.
- Don't open meta-PRs that rewrite `README.md`, `CLAUDE.md`, or
  `CONTRIBUTING.md` for style. Fix factual errors only, per *What NOT to
  do* above.
- Don't bundle a version bump with an unrelated change (ADR-008).

## External tooling on the host (macOS)

- `tart` — VM lifecycle.
- `nix` (host install, optional) — for cross-builds and local Nix experimentation.
- `qemu` (optional) — fallback for non-arm64 emulation.

The host Mac is for orchestration. Real builds happen inside `gnunix-builder` or downstream VMs.

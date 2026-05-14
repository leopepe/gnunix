# CLAUDE.md

Guidance for Claude Code sessions working in this repo.

## What this project is

**GNUnix** — a custom Linux distribution for **developer workstations**, shipped
as **Tart VM images** on Apple Silicon. The name is a pun: GNU + Nix, also
reads as "GN[U] Unix". Two layers:

1. **LFS base** (built from source, arm64). Slackware-inspired: `sysvinit` + BSD `/etc/rc.d/` scripts. Minimal, hand-curated, changes rarely.
2. **Nix layer** (multi-user nixpkgs daemon + home-manager). Owns everything user-visible: Wayland compositor, portals, fonts, apps, dev tools. Changes constantly.

Strategy doc: `~/Documents/hyground/analysis/gnunix-nix-wayland-distro-strategy.md`.

> **Project was renamed `gnunix` → GNUnix** per
> [ADR-013](docs/adrs/ADR-013-rename-to-gnunix.md). The image lineage
> rename `lfs-{core,nix,wayland,builder}` → `gnunix-{base,nix,desktop,builder}`
> is gated on the in-flight build; commands below still use `lfs-*` until
> the migration commit lands.

## Guiding philosophy (load-bearing)

- **Static base, dynamic userland.** The LFS layer is boring on purpose. Anything that evolves week-to-week belongs in Nix, not in `/etc`.
- **No policy in PID 1.** Init does init. No service supervisor, no D-Bus-coupled init.
- **Boring base, declarative top.** System config lives in shell scripts and a few text files. User config lives in `home-manager`.

When proposing changes, ask: *does this belong in the static base or the dynamic userland?* If unsure, default to userland (Nix).

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

If a task seems to require violating a locked decision, **stop and surface the conflict** — don't silently work around it.

## Repo layout (monorepo)

```
docs/         — architecture, ADRs, runbooks
images/       — one subdir per Tart image, in build order
  gnunix-builder → gnunix-base → gnunix-nix → gnunix-desktop → variants/
bundles/      — reusable Nix expressions
tools/        — pipeline programs (build-all, promote)
scripts/      — small auxiliary helpers
tests/        — boot smoke tests, session tests
runbook.md    — index of other runbooks in `docs/runbooks/`
```

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

- **Base image change** → `tests/boot-smoke.sh <image>` must pass (boot, DHCP, TTY login, dbus running, nix-daemon responsive).
- **Wayland change** → `tests/wayland-session.sh` must pass (greetd → session → compositor on virtio-gpu → terminal opens).
- Type-checking and shell linting are nice but not sufficient — boot tests are the real gate.

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
- Renovate opens version-bump PRs. CI (macOS arm64 runner under `.github/workflows/build.yml`) rebuilds affected images and runs `tests/boot-smoke.sh` + `tests/wayland-session.sh`.
- **Auto-merge:** userland bumps (nixpkgs, bundles) that pass CI.
- **Human review required:** kernel, glibc, binutils, gcc, sysvinit, eudev, dbus, elogind, GRUB.
- Releases publish Tart images (`*.tart.tar.zst`) + `manifest.json` as GitHub Release artifacts via `tools/promote.sh`.

## External tooling on the host (macOS)

- `tart` — VM lifecycle.
- `nix` (host install, optional) — for cross-builds and local Nix experimentation.
- `qemu` (optional) — fallback for non-arm64 emulation.

The host Mac is for orchestration. Real builds happen inside `gnunix-builder` or downstream VMs.

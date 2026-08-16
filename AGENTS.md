# AGENTS.md

Guidance for coding-agent sessions working in this repository.

## What this project is

**GNUnix** — a custom Linux distribution for **developer workstations**, shipped
as **Tart VM images** on Apple Silicon. Two layers:

1. **LFS base** (built from source, arm64). Slackware-inspired: `sysvinit` + BSD `/etc/rc.d/` scripts. Minimal, hand-curated, changes rarely.
2. **Nix layer** (multi-user nixpkgs daemon + home-manager). Owns everything user-visible: Wayland compositor, portals, fonts, apps, dev tools. Changes constantly.

## Guiding philosophy

- **Static base, dynamic userland.** Anything that evolves week-to-week belongs in Nix, not in `/etc`. If you find yourself patching `/etc/` to ship a feature, you're in the wrong layer.
- **No policy in PID 1.** Init does init. No service supervisor, no D-Bus-coupled init, no declarative dependency graph. `sysvinit` starts `rc.S`, `rc.S` runs scripts, scripts exit.
- **Boring base, declarative top.** System config lives in shell scripts and a few text files. User config lives in `home-manager`. There is no third layer; resist the urge to invent one.
- **GNU userland.** `coreutils`, glibc, GCC, bash — compiled from source. No `busybox`, no `musl`, no drop-in replacements "for size." If a tool exists in coreutils, use it.
- **Wayland-only display, compositor-agnostic.** We ship the substrate (`elogind`, `dbus`, portals). No X11 or XWayland in the base. The user picks the compositor; Hyprland is the *reference* session, not the *only* session.
- **No desktop environment in the base image.** GNOME and KDE are out of scope. GNUnix gives the user a TTY, a working Nix, and a Wayland-capable kernel; what they build on top is their problem and Nix's strength.
- **Simple, direct, objective.** One concern per script, one decision per ADR, one reason per commit. If something feels clever, it is probably wrong for this codebase.

When proposing changes, ask in order:

1. *Does this belong in the static base or the dynamic userland?* If unsure, default to userland (Nix).
2. *Is this something the user should choose, not us?* If yes, ship the substrate, not the choice (compositors, editors, shells, fonts, browsers).
3. *Does an ADR already answer this?* Check `docs/adrs/` before designing around a locked decision.

## Locked decisions

Load-bearing decisions are recorded as ADRs under `docs/adrs/`. Accepted ADRs
are binding: do not relitigate one without proposing an amendment or a
superseding ADR. If a task seems to require violating a locked decision,
**stop and surface the conflict** (via an `adr_proposal` issue) — don't
silently work around it.

## Repository layout

| Path | Purpose |
|---|---|
| `docs/` | All project documentation: architecture, ADRs (`docs/adrs/`), runbooks (`docs/runbooks/`), guidelines. See `docs/AGENTS.md` for navigation and authoring rules. |
| `images/` | One subdirectory per Tart image (builder, base, minimal, desktop, installer), plus `images/variants/` for per-platform packaging. See `images/AGENTS.md`. |
| `bundles/` | Reusable Nix expressions shared by two or more images. |
| `tools/` | Pipeline programs: build orchestration, packaging, release. |
| `scripts/` | Small auxiliary helpers (VM entry, validation wrappers). Graduate to `tools/` when reused. |
| `tests/` | Image acceptance / smoke tests, one directory per image. See `tests/AGENTS.md`. |
| `.github/` | CI workflows, issue and PR templates, Renovate config. See `.github/AGENTS.md`. |
| `assets/` | Logo and branding artwork. |

The top-level `runbook.md` indexes the runbooks under `docs/runbooks/`.

**Where things go:**

- Image-specific config (rc scripts, kernel config, session definition) → `images/<name>/`. Never outside.
- Reusable Nix bundles (consumed by ≥2 images) → `bundles/`.
- Multi-image orchestration → `tools/`.
- "Why we chose X" → an ADR under `docs/adrs/`. Code comments reference the ADR ID; they do not re-explain it.

## Conventions

### Shell scripts

- `#!/bin/sh` for portability where possible; `bash` only when actually using bash features.
- `set -eu` at the top; add `set -o pipefail` if bash.
- No silent `cd`. Use absolute paths.
- Validation scripts exit non-zero on failure with a one-line reason.

### Nix

- The `nixpkgs` rev is pinned in `tools/manifest.json`. Bumps are explicit commits.
- `bundles/*.nix` are pure functions of `pkgs`; no side effects.
- Per-image session expressions compose bundles, don't redefine them.

### rc.d scripts

- One concern per script. `rc.<service>` enables/disables a single service.
- Enabled by `chmod +x` (Slackware convention). Disabled by `chmod -x`.
- `rc.M` calls per-service scripts in order; doesn't inline service logic.

### Tart images

- Each image forks from the previous tagged image; tags follow `<name>:<semver>` (e.g. `gnunix-base:0.1.0`).
- A new image variant gets a new directory under `images/variants/`, never an inline branch in an existing image's build script.
- **Persistence gotcha:** VM root filesystems delay writes. Any script that writes state inside a VM and then stops it must sync first (`ssh admin@vm 'sudo sync; sync'`), or writes can be lost on next boot.

## How to validate work

Boot tests are the real gate; linting and type-checking are not sufficient.
Each image has a dedicated test set under `tests/<image>/`, and changes to an
image must pass that image's set:

- `gnunix-base` → `tests/base/` (boot, DHCP, TTY login, dbus, nix-daemon responsive)
- `gnunix-minimal` → `tests/minimal/` (Nix installed, multi-user daemon running, store query works)
- `gnunix-desktop` → `tests/desktop/` (greetd → session → compositor → terminal opens)
- `gnunix-installer` → `tests/installer/` (per-profile install scenarios)

See `tests/AGENTS.md` for entry points, layout rules, and scope limits. If a
task seems to require testing something that file places out of scope, stop
and surface the conflict instead of silently extending the test surface.

## What NOT to do

- Don't introduce systemd, even "just for one service." It breaks ADR-001 and pulls in the entire systemd ecosystem (logind, networkd, resolved, journald).
- Don't add NixOS modules. If you find yourself wanting `configuration.nix`, the answer is home-manager or rc.d, not NixOS.
- Don't put service logic in `rc.S` or `rc.M`. Those are dispatchers.
- Don't add "fallback" or "compatibility" layers for hypothetical future requirements.
- Don't write README/docs files unless asked or the task is explicitly documentation.
- Don't bump pinned versions opportunistically. Version bumps are their own commits with their own validation.

## Build and release

- Build entry points and orchestrator commands are documented in `docs/runbooks/build.md`; the programs live in `tools/`.
- Pinned versions live in `tools/manifest.json`, `bundles/*.nix`, and image build scripts. Don't bump pins ad hoc; Renovate opens version-bump PRs, and bumps are never bundled with unrelated changes.
- Userland bumps (nixpkgs, bundles) may auto-merge when CI passes. Kernel, glibc, binutils, gcc, sysvinit, eudev, dbus, elogind, and GRUB require human review.
- Releases publish Tart images and `manifest.json` as GitHub Release artifacts.

## Opening issues and pull requests

Read `CONTRIBUTING.md` before creating or editing any issue or PR; it is
authoritative for the contribution flow. In short:

- Always use the templates under `.github/` (`PULL_REQUEST_TEMPLATE.md`, `ISSUE_TEMPLATE/`); never bypass them with free-form bodies.
- Reference locked decisions by ADR ID; link rather than paraphrase.
- Validation evidence must be real: only tick the smoke-test boxes that actually ran.

## External tooling on the host (macOS)

- `tart` — VM lifecycle.
- `nix` (optional) — cross-builds and local Nix experimentation.
- `qemu` (optional) — fallback for non-arm64 emulation.

The host Mac is for orchestration; real builds happen inside the builder or downstream VMs.

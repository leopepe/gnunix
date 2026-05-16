# CLAUDE.md — `images/`

Guidance for Claude Code sessions working **inside `images/`** or
running any image-build / image-release tooling under `tools/` and
`scripts/`. Load this file when the user's request touches:

- Anything under `images/` (`gnunix-builder`, `gnunix-base`,
  `gnunix-minimal`, `gnunix-desktop`, `installer`, `variants/…`).
- The build pipeline (`tools/phase2.sh`, `tools/build-all.sh`,
  `tools/bootstrap-builder.sh`, `tools/fetch-sources.sh`,
  `tools/install-builder-key.sh`).
- Packaging and release (`tools/package.sh`, `tools/release-image.sh`,
  `tools/promote.sh`, `tools/manifest.json`).
- Smoke tests under `tests/` that boot an image.
- rc.d scripts (`images/<name>/rc.d/`) and per-image `session.nix`.
- Host VM tooling (`tart`, `qemu`).

If the task is only about generic shell/Nix style or project-wide
policy, the root [`CLAUDE.md`](../CLAUDE.md) is enough.

## Authority and precedence

This file documents **how** images are built, validated, and released.
It does not redefine **why** any of this is shaped the way it is.
Rationale lives in the architecture docs and ADRs, and they win on
every conflict:

1. **`docs/architecture.md`** — the compiled view of the current
   system. Read it before designing or restructuring any image.
2. **`docs/adrs/`** — load-bearing decisions. The Locked decisions
   table in the root [`CLAUDE.md`](../CLAUDE.md#locked-decisions--do-not-relitigate-without-an-adr-update)
   indexes them; the per-ADR file holds the full rationale.
3. **Root [`CLAUDE.md`](../CLAUDE.md)** — Guiding philosophy,
   `What NOT to do`, contribution flow. Still applies inside `images/`.
4. **This file** — refines the above with image-specific workflow.

If something in this file appears to contradict an ADR or
`docs/architecture.md`, treat it as a bug here and surface the
conflict instead of working around it. When in doubt about whether a
proposed change is allowed:

- *Does it belong in the static base or the dynamic Nix userland?*
  Default to userland — see ADR-003, ADR-004, ADR-009.
- *Does it require violating a locked decision?* Stop and open an
  `adr_proposal.yml` issue (see root CLAUDE.md → *Opening issues and
  pull requests*). Do not silently work around an ADR.
- *Is the user choosing this, or are we?* Ship substrate, not
  policy — ADR-009, ADR-015, ADR-020.

Whenever you touch this layer, re-read the relevant ADR rather than
paraphrasing it from memory. ADRs that govern image content,
lineage, packaging, and release:

| ADR | Topic |
|---|---|
| [ADR-001](../docs/adrs/ADR-001-sysvinit-base.md) | `sysvinit` + BSD `/etc/rc.d/` |
| [ADR-002](../docs/adrs/) | `elogind` for seat management |
| [ADR-003](../docs/adrs/) | Multi-user Nix daemon |
| [ADR-004](../docs/adrs/) | Plain Nix profiles + home-manager |
| [ADR-006](../docs/adrs/) | GRUB EFI bootloader |
| [ADR-007](../docs/adrs/) | LFS-ARM (arm64) base |
| [ADR-008](../docs/adrs/) | Renovate PRs + GitHub Releases for image publishing |
| [ADR-009](../docs/adrs/) | Sway/greetd substrate, dbus/elogind into `/nix/var/nix/profiles/system` |
| [ADR-010](../docs/adrs/) | Multi-arch + per-platform packagers |
| [ADR-011](../docs/adrs/) | Compile-time hardening flags |
| [ADR-012](../docs/adrs/) | Module-first kernel |
| [ADR-015](../docs/adrs/) | Live installer + 4 Wayland profiles |
| [ADR-016](../docs/adrs/) | CI split (ubuntu-22.04-arm + local Mac) |
| [ADR-017](../docs/adrs/) | Live-ISO architecture (squashfs + overlayfs + initramfs) |
| [ADR-018](../docs/adrs/) | Artifact types + naming grammar; `gnunix-minimal` as CI anchor |
| [ADR-019](../docs/adrs/) | Image lineage roles + installer pivot |
| [ADR-020](../docs/adrs/) | Hyprland as reference compositor |
| [ADR-021](../docs/adrs/) | No self-hosted CI runners |

(Confirm the exact filename in `docs/adrs/` before linking from a PR
body; the list above is the authoritative index of *which* ADRs apply
here.)

## Image lineage (build order)

The image graph is **not linear** — `gnunix-minimal` is the fan-out
anchor (ADR-018, ADR-019). Always build upstream parents before
their descendants:

```
gnunix-builder          (Ubuntu-based cross-build harness; ADR-007)
        │
        ▼
gnunix-base             (LFS-ARM, sysvinit, hand-curated; rebuilt rarely)
        │
        ▼
gnunix-minimal          (adds multi-user Nix + home-manager; CI release anchor)
        │
        ├──▶ gnunix-desktop     (Hyprland pre-baked; ADR-020)
        ├──▶ gnunix-installer   (live ISO; squashfs+overlayfs; ADR-017)
        └──▶ variants/<name>    (one subdir per derivative; never inlined)
```

Per-directory roles:

- `images/gnunix-builder/` — cross-compile harness. Built once,
  snapshotted, reused. Source of `gnunix-builder:base` tag.
- `images/gnunix-base/` — LFS-ARM root with `sysvinit` + GNU userland
  + GRUB. Boring on purpose; do not put policy here. **Rebuild cost:
  6–10 h on a Mac.** Per ADR-021, this rebuild runs on the
  maintainer's local Mac (not CI) and ships as a GH Release artifact;
  downstream layers fetch it via `tools/fetch-image.sh`.
- `images/gnunix-minimal/` — adds the multi-user Nix daemon and
  home-manager scaffolding on top of `gnunix-base`. This is the
  **release-dependency anchor** (ADR-018): downstream layers fetch it,
  they do not rebuild it.
- `images/gnunix-desktop/` — layers Hyprland + portals + greetd onto
  `gnunix-minimal`. Reference compositor per ADR-020.
- `images/installer/` — live ISO. Layers a minimal text-only live
  environment on `gnunix-minimal` and pulls compositors at install
  time. Per ADR-019, this is a *sibling* of `gnunix-desktop`, not a
  superset.
- `images/variants/<name>/` — any derivative gets its own subdir.
  **Never** inline a variant as a branch inside an existing image's
  build script.

## Build pipeline (Phase 2 commands)

When the user asks to build, resume, or test `gnunix-base`, use these
entry points. Full details live in
[`docs/runbooks/build.md`](../docs/runbooks/build.md) — read it
before driving a real build.

- `tools/phase2.sh` — gated end-to-end orchestrator:
  pre-fetch → bootstrap-builder → build-all → smoke-test, with
  `[y/N]` prompts between stages. `AUTO=1` skips prompts.
- `tools/build-all.sh gnunix-base` — the build step alone.
  Re-clones `gnunix-builder-build` from `gnunix-builder:base`
  (destructive).
- `REUSE_BUILDER=1 tools/build-all.sh gnunix-base` — **resume** mode.
  Keeps the existing `gnunix-builder-build` so completed in-VM stages
  (e.g. cross, ~3 h) are not redone.
- `tools/install-builder-key.sh [vm]` — retrofit SSH key into an
  existing snapshot. Unattended via `expect` + documented
  `admin/admin`.
- `tools/fetch-sources.sh` — host-side pre-fetch with mirror fallback.
  Stage 0 of `phase2.sh`.
- `tools/fetch-image.sh` — pull a published `gnunix-*` artifact from
  the GH Release instead of rebuilding it (ADR-016, ADR-021).

**Persistence gotcha (do not forget):** the cirruslabs Ubuntu rootfs
that backs `gnunix-builder` is ext4 mounted `commit=30`. Any script
that writes state and then `tart stop`s **must** first run
`ssh admin@vm 'sudo sync; sync'`, or the writes vanish on next boot.
All current scripts do this; new ones must too.

## Per-image conventions

### Tart images (lineage and tagging)

- Image lineage is captured by the graph above. Each image is built
  on top of its parent's last good tagged snapshot; do not build a
  child off an ad-hoc working copy.
- Tags follow `<name>:<semver>` (e.g. `gnunix-base:0.1.0`).
- Artifact naming follows ADR-018:
  `gnunix-<image>-<arch>[-<platform>]-<ver>.<ext>`, where `<ext>` is
  one of `.iso` / `.img.zst` / `.tart.zst`. Do not invent new forms.
- A new image variant gets a new directory under `images/variants/`,
  never an inline branch in an existing image's build script.
- Image-specific config (rc scripts, kernel config, `session.nix`)
  lives under `images/<name>/`. Never outside.

### rc.d scripts (inside `images/<name>/rc.d/`)

- One concern per script. `rc.<service>` enables/disables a single
  service.
- Enabled by `chmod +x` (Slackware convention). Disabled by
  `chmod -x`.
- `rc.M` calls per-service scripts in order; it does **not** inline
  service logic. `rc.S` is the same way for single-user boot.
- Never put policy or service logic in `rc.S` / `rc.M`. They are
  dispatchers. (Root `CLAUDE.md` → *What NOT to do*.)
- No systemd, no OpenRC, no s6/dinit/runit — see ADR-001. If a
  proposed change feels like it wants a supervisor, it belongs in
  the Nix userland, not the base.

### Per-image `session.nix` and bundles

- `bundles/*.nix` are pure functions of `pkgs` consumed by **≥2**
  images. Per-image `session.nix` *composes* bundles; it does not
  redefine them.
- Pin `nixpkgs` rev in `tools/manifest.json`. Bumps are explicit
  commits (ADR-008) — not opportunistic.
- Do not introduce NixOS modules. If you find yourself wanting a
  `configuration.nix`, the answer is home-manager or `rc.d`, not
  NixOS (root `CLAUDE.md` → *What NOT to do*).

## How to validate image work

Boot tests are the gate. Type-checking and shell linting are nice
but not sufficient.

- **Base / minimal image change** → `tests/boot-smoke.sh <image>`
  must pass: boot, DHCP, TTY login, `dbus` running, `nix-daemon`
  responsive.
- **Wayland / desktop change** → `tests/wayland-session.sh` must
  pass: `greetd` → session → compositor on `virtio-gpu` → terminal
  opens.
- **Installer change** → boot the ISO, run the whiptail TUI to
  completion against a scratch disk image, then boot the installed
  system and re-run `tests/boot-smoke.sh` against it (ADR-015,
  ADR-017, ADR-019).

PR bodies must only tick the smoke-test boxes that actually ran.
Don't tick what you didn't run (root `CLAUDE.md` → *Content rules*).

## Updates and release flow (ADR-008, amended by ADR-016, ADR-021)

- Pinned versions live in `tools/manifest.json`, `bundles/*.nix`, and
  image build scripts. **Do not** bump pins ad hoc.
- Renovate opens version-bump PRs. CI rebuilds affected images on
  free GitHub-hosted runners (`ubuntu-22.04-arm` for arm64 jobs) and
  runs `tests/boot-smoke.sh` + `tests/wayland-session.sh`.
- **Auto-merge:** userland bumps (nixpkgs, bundles) that pass CI.
- **Human review required:** kernel, glibc, binutils, gcc,
  `sysvinit`, `eudev`, `dbus`, `elogind`, GRUB.
- `gnunix-base` rebuilds (6–10 h) happen on the maintainer's local
  Mac with Tart and ship as GH Release artifacts; CI fetches them via
  `tools/fetch-image.sh` rather than rebuilding (ADR-016, ADR-021).
  There is **no** self-hosted runner — ever.
- Releases publish images (`.iso` / `.img.zst` / `.tart.zst`) +
  `manifest.json` as GitHub Release artifacts via
  `tools/promote.sh` / `tools/release-image.sh`.
- Don't bundle a version bump with an unrelated change (ADR-008).

## Phase status

Track in [`docs/architecture.md`](../docs/architecture.md). Current:
**end of Phase 2 spec — `gnunix-base` build pipeline is complete and
ready to be invoked.** The actual build and first Tart-test are the
next human action; see [`../runbook.md`](../runbook.md) and
[`docs/runbooks/build.md`](../docs/runbooks/build.md).

## External tooling on the host (macOS)

These are required on the maintainer's Mac (or any local builder).
CI uses a different stack — see ADR-016 / ADR-021.

- `tart` — VM lifecycle. Mandatory for the local `gnunix-base`
  rebuild and for any local boot smoke test.
- `nix` (host install, optional) — for cross-builds and local Nix
  experimentation.
- `qemu` (optional) — fallback for non-arm64 emulation, and the
  driver used by CI under `scripts/vm-helpers.sh` (ADR-016).

The host Mac is for orchestration. Real builds happen inside
`gnunix-builder` or downstream VMs — never directly on the host.

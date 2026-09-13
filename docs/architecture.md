# Architecture — GNUnix

This is the in-repo expansion of the project strategy. The canonical strategy
lives at `~/Documents/hyground/analysis/gnunix-nix-wayland-distro-strategy.md`.

> **Naming.** The project was renamed from the placeholder `lfs-nix-distro`
> to **GNUnix** per [ADR-013](adrs/ADR-013-rename-to-gnunix.md), and a
> second internal rename `gnunix-nix → gnunix-minimal` per
> [ADR-019](adrs/ADR-019-image-lineage-and-installer-pivot.md). Source tree
> and image lineage now use `gnunix-{base,minimal,desktop,builder,installer}`.
> Older ADRs (001–012) keep the pre-rename names (`lfs-core`, `lfs-nix`,
> `lfs-wayland`, `lfs-builder`) for historical fidelity; ADR-013 + ADR-019
> record the mappings.

## Two-layer model

```
┌─────────────────────────────────────────────────────┐
│  Nix layer                                           │
│                                                      │
│   system profile — /nix/var/nix/profiles/system      │
│     Wayland compositor, portals, dbus + elogind,     │
│     greetd (ADR-009, ADR-020). Declared in           │
│     flake.nix + nix/*.nix, pinned by flake.lock,     │
│     installed with `nix-env --set` (ADR-025).        │
│     Ships with the release.                          │
│                                                      │
│   per-user — ~/.nix-profile, home-manager (ADR-025)  │
│     the user's own apps and dotfiles. Not the        │
│     release; the repo's flake never touches $HOME.   │
├─────────────────────────────────────────────────────┤
│  LFS base (built from source, arm64)                 │
│   kernel, glibc, coreutils,                          │
│   sysvinit + BSD /etc/rc.d/,                         │
│   eudev, network, nix daemon                         │
│   pinned in tools/manifest.json (ADR-007, ADR-011)   │
├─────────────────────────────────────────────────────┤
│  qemu / Tart (arm64 VM for testing / distribution)    │
└─────────────────────────────────────────────────────┘
```

The Nix layer has two tiers and ADR-025 governs both, differently: the system
profile is declarative and reproducible from one commit; the per-user profile
is imperative and the user's business. The repo's flake never reaches into
`$HOME`, and a user's profile never edits the release.

*Legend: ADR-001 (init), ADR-003 (multi-user Nix), ADR-007 (aarch64 LFS),
ADR-009 + ADR-020 (Wayland substrate), ADR-011 (hardening), ADR-025
(declarative system profile + per-user config style).*

## How the system profile is built

```
repo (one commit)                 runner (ubuntu-22.04-arm)        image
─────────────────                 ─────────────────────────        ─────
flake.nix + nix/*.nix   ──┐
tools/manifest.json       │──►  nix build .#<name>Profile  ──►  nix copy --to $MNT
  .nix.channel            │       (resolves via flake.lock)         │
flake.lock (exact rev)  ──┘                                          ▼
                                                        chroot $MNT nix-env \
                                                          --profile /nix/var/nix/…/system \
                                                          --set $OUT
```

Nothing builds Nix packages inside the chroot: the only in-chroot command is
the atomic profile swap (ADR-025). Renovate bumps `flake.lock` as a single-pin
PR (ADR-023).

**Known gap (ADR-025).** The profile itself is boot-persistent — it is a
symlink on the ext4 root pointing into `/nix/store` on the same filesystem —
but nothing puts `/nix/var/nix/profiles/system/bin` on an interactive `PATH`.
`/etc/profile.d/nix-daemon.sh` sources only the *default* profile. The system
profile is reached today through explicit exports in session wrappers and
absolute paths in `rc.d`, `greetd` and `hyprland.conf`. The named remedy is an
`/etc/profile.d/nix-system-profile.sh` drop-in, scoped as its own change.

*Legend: ADR-021 (hosted `ubuntu-22.04-arm`), ADR-023 (Renovate single-pin),
ADR-025 (flake-declared profiles, build-on-runner, `--set` install).*

## Image lineage

```
gnunix-builder              (Ubuntu arm64, builds GNUnix from source — not published)
    │
    ▼
gnunix-base                 (was lfs-core)      published: .img.zst, .tart.zst
    │
    ▼
gnunix-minimal              (was lfs-nix)       published: .img.zst, .tart.zst
    │                         ← CI release-dependency anchor (ADR-018)
    │
    ├──────────────────┬──────────────────────┐
    ▼                   ▼                       ▼
gnunix-desktop    gnunix-installer       variants/<platform>/   (scaffolded, ADR-010)
published:        published: .iso         ├── generic-uefi    (shipping, aarch64)
.img.zst,          (live ISO,            ├── rpi-native      (Phase 6)
.tart.zst         ADR-017 + ADR-019)     └── nuc-installer   (Phase 5, x86_64)
(Hyprland         live env = text-only
 pre-baked,       gnunix-minimal + TUI;
 ADR-020)         picks edition→compositor→identity
                  at install time
```

After [ADR-019](adrs/ADR-019-image-lineage-and-installer-pivot.md),
`gnunix-desktop` and `gnunix-installer` are **siblings** of
`gnunix-minimal`, not chained. Each downstream image is forked from
the previous tag of its parent, never re-built from scratch. This
keeps the lineage reproducible.

## Phase status

| Phase | Image | Status |
|---|---|---|
| 0 | workspace bootstrap | done |
| 1 | `gnunix-builder` | done — `tools/bootstrap-builder.sh` produces `gnunix-builder:base` |
| 2 | `gnunix-base` | done — `gnunix-base-0.1.0` boots, passes `tests/base/boot-smoke.sh` (sshd + DHCP). Built with ADR-011 compile-time hardening and ADR-012 module-first kernel. |
| 3 | `gnunix-minimal` | done — `gnunix-minimal-0.1.0` boots, passes `tests/minimal/minimal-smoke.sh` (multi-user Nix daemon + nixbld users). |
| 4 | `gnunix-desktop` | done — `gnunix-desktop-0.1.0` boots, passes `tests/desktop/wayland-session.sh` (dbus + elogind + greetd running, user provisioned, sway+waybar render). |
| 5 | multi-arch + per-platform packaging | scaffolded (ADR-010) — `tools/package-platform.sh` emits `gnunix-{minimal,desktop}-generic-uefi-aarch64-<ver>.img(.zst)`. `rpi-native` and `nuc-installer` packagers exist but exit 2 until Phase 6 / Phase 5 builder land. |
| 6 | `rpi-native` + `nuc-installer` go live | tracked in `docs/TODO.md` |
| 4.5 | `gnunix-installer` (ADR-015) | scaffolded — `tools/build-all.sh gnunix-installer` produces a live image with a whiptail TUI that lets the user pick `minimal` / `desktop-sway` / `desktop-hyprland` / `desktop-labwc` / `desktop-cosmic` (ADR-022). Acceptance tests under `tests/installer/profile-*.sh` drive the installer unattended against an empty target disk, boot the installed system, and assert universal + per-profile state. TUI interactions are covered by `tests/installer/tui-interactions.sh` (expect-driven, host-side). CI: `gnunix-installer` + `installer-test` jobs in `build.yml`. |
| 7 | CI/Renovate/Releases | done — three-workflow pipeline (ADR-008). `build.yml` runs gnunix-base (stage-split: cross-toolchain → temp-tools → chroot → finalize) → gnunix-minimal → gnunix-desktop → gnunix-installer → installer-test (matrix) → package matrix and always uploads artifacts (tiered retention by event). `tag-on-version-bump.yml` auto-tags `v<X.Y.Z>` when `tools/manifest.json:lfs_image_version` changes on `main`. `release.yml` triggers on tag push, downloads artifacts from the corresponding `build.yml` run, and drafts a GitHub Release. See `docs/runbooks/release.md`. |

## Locked decisions

See `docs/adrs/` for full ADRs. Headlines:

- **ADR-001:** sysvinit + BSD `/etc/rc.d/`
- **ADR-002:** elogind for seat management
- **ADR-003:** multi-user Nix daemon
- **ADR-004:** plain Nix profiles + home-manager (no NixOS modules) *(Superseded by ADR-025; see ADR-025 for the current model. Its home-manager, hand-curated-`/etc` and NixOS-module decisions are absorbed there unchanged; its rejection of flakes-as-system-config is what ADR-025 corrects.)*
- **ADR-005:** developer workstation, this Mac first
- **ADR-006:** GRUB EFI bootloader
- **ADR-007:** LFS-ARM (aarch64)
- **ADR-008:** Renovate + GitHub Releases for image publishing
- **ADR-009:** Sway + greetd; dbus/elogind/greetd/sway sourced from nixpkgs into `/nix/var/nix/profiles/system` *(Amended by ADR-020 + ADR-025: Hyprland is the reference session, and the profile is now flake-declared rather than installed with `nix-env -iA`.)*
- **ADR-010:** Multi-arch axis + per-platform packagers (generic-uefi, rpi-native, nuc-installer); i686 out of scope
- **ADR-011:** Compile-time hardening flags for `gnunix-base` — `_FORTIFY_SOURCE=3`, `-fstack-protector-strong`, `-fstack-clash-protection`, PIE, full RELRO + BIND_NOW, `-mbranch-protection=standard` (aarch64); delivered via `manifest.json:hardening` + `lib/hardening.sh` helper
- **ADR-012:** Module-first kernel — only boot-critical drivers stay `=y` in `kernel.config`; everything else becomes `=m` in `kernel.modules.config` and auto-loads via eudev MODALIAS coldplug; `/etc/modules-load.d/*.conf` + `rc.modules` for explicit overlays
- **ADR-013:** Distribution renamed to **GNUnix** (was `lfs-nix-distro`); image lineage renamed `lfs-{core,nix,wayland,builder}` → `gnunix-{base,nix,desktop,builder}`
- **ADR-014:** AI-assisted PR review — deterministic checks (`pr-lint.yml`) block; LLM-driven architectural review (`ai-review.yml` + `.claude/skills/pr-review/`) is opt-in advisory. Provider-agnostic over any OpenAI-compatible API; defaults to OpenRouter free tier.
- **ADR-015:** Live installer (`gnunix-installer`) + multiple installable compositor profiles, whiptail TUI. *(Amended by ADR-017 + ADR-019 + ADR-022.)*
- **ADR-016:** Hosted runners only. The LFS base build runs on `ubuntu-22.04-arm` via chroot, split into four cacheable stages (cross-toolchain, temp-tools, chroot, finalize). Tests run via qemu+KVM. *(Superseded by ADR-021; see ADR-021 for the current model.)*
- **ADR-017:** Live-ISO architecture for `gnunix-installer` — squashfs + overlayfs + custom minimal initramfs (busybox-static), hybrid EFI ISO via `xorriso`. Adds 4 `=m` modules to the module-first kernel (per ADR-012).
- **ADR-018:** Artifact taxonomy + naming + release flow — three forms (`.iso` / `.img.zst` / `.tart.zst`), flat grammar `gnunix-<image>-<arch>[-<platform>]-<ver>.<ext>`, four published images, `gnunix-minimal` as CI release-dep anchor. Unified `tools/package.sh`. *(Amends ADR-008, ADR-010.)*
- **ADR-019:** Image lineage roles + installer pivot — installer layered on `gnunix-minimal` (text-only live env, network-required desktop installs). TUI flow: edition → compositor → identity. Finishes `gnunix-nix → gnunix-minimal` rename. *(Extends ADR-013, ADR-015.)*
- **ADR-020:** Reference compositor switched Sway → **Hyprland**; Sway demoted to optional install profile. *(Amends ADR-009. Amended by ADR-022.)*
- **ADR-021:** Hosted runners only — LFS build runs in CI on `ubuntu-22.04-arm` via chroot, split into four cacheable stages (cross-toolchain, temp-tools, chroot, finalize). Self-hosted runners forbidden. *(Amends ADR-008, ADR-010, ADR-016.)*
- **ADR-022:** Add **`desktop-cosmic`** as a fourth optional installer compositor — System76 COSMIC, init-agnostic (uses `dbus-run-session`, not `systemd --user`), integrates with elogind per ADR-002. Pulled at install time per ADR-015/019; not pre-baked into `gnunix-desktop` — Hyprland remains the reference. *(Amends ADR-015, ADR-020.)*
- **ADR-024:** Declarative Nix profiles — system package sets live in a flake. *(Superseded by ADR-025, which absorbs it in full; see ADR-025 for the current model.)*
- **[ADR-025](adrs/ADR-025-declarative-system-flakes.md):** The flake is the source of truth for system package sets. `flake.nix` + `nix/*.nix` declare one `buildEnv` per image, `flake.lock` pins nixpkgs to a revision, the closure is built on the runner and installed by replacing `/nix/var/nix/profiles/system` atomically with `nix-env --profile … --set`. `nix-env -iA` and `nix-channel` establish no system state; no Nix build runs in a chroot. Per-user config stays home-manager + `~/.nix-profile`. *(Supersedes ADR-004, ADR-024. Amends ADR-009, ADR-017.)*

## Key invariants

- **No systemd, anywhere in the base.** Adding it pulls in logind/networkd/journald and breaks ADR-001/002/006.
- **No NixOS modules.** The system package set is a `buildEnv` declared in
  `flake.nix`; per-user config is home-manager only (both ADR-025). Neither is
  a `configuration.nix`, and adding one breaks ADR-001. A `nixosConfigurations`
  output in the flake needs a new ADR, not a review.
- **The flake is the declaration.** What a released image contains is readable
  from `flake.nix` + `nix/*.nix` and reproducible from one commit via
  `flake.lock` (ADR-025). `nix-env -iA` and `nix-channel` establish no system
  state.
- **No Nix build inside a chroot.** Profiles are built on the runner and copied
  in; the only in-chroot Nix command is `nix-env --profile … --set` (ADR-025).
  `nix-env -iA` / `nix-channel` in an image `build.sh` is a regression.
- **Linear image lineage.** A new variant gets a new directory under `images/variants/`, not an inline branch in an existing image.
- **Pinned everything.** Every external version lives in `tools/manifest.json`, and the Nix layer's nixpkgs revision in `flake.lock` (ADR-025); Renovate is the only path that changes those pins (ADR-023).
- **Static base, dynamic userland.** When in doubt, the change goes in Nix, not in `/etc`.
- **No self-hosted CI runners.** Per ADR-021. Workflows that pin self-hosted labels are a regression.

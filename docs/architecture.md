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
│  Nix layer (managed by nixpkgs / home-manager)     │
│   Wayland compositor, portals, fonts, apps         │
├─────────────────────────────────────────────────────┤
│  LFS base (built from source, arm64)                │
│   kernel, glibc, coreutils,                         │
│   sysvinit + BSD /etc/rc.d/,                        │
│   eudev, network, nix daemon                        │
│   (dbus + elogind sourced from nixpkgs              │
│    into /nix/var/nix/profiles/system, ADR-009)      │
├─────────────────────────────────────────────────────┤
│  Tart VM (Apple Virtualization.framework, arm64)    │
└─────────────────────────────────────────────────────┘
```

## Image lineage

```
gnunix-builder              (Ubuntu arm64, builds GNUnix from source — not published)
   │
   ▼
gnunix-base                 (was lfs-core)      published: .img.zst, .tart.zst
   │
   ▼
gnunix-minimal              (was lfs-nix)       published: .img.zst, .tart.zst
   │                        ← CI release-dependency anchor (ADR-018)
   │
   ├──────────────────┬──────────────────────┐
   ▼                  ▼                      ▼
gnunix-desktop    gnunix-installer       variants/<platform>/   (scaffolded, ADR-010)
published:        published: .iso        ├── generic-uefi   (shipping, aarch64)
.img.zst,         (live ISO,             ├── rpi-native     (Phase 6)
.tart.zst         ADR-017 + ADR-019)     └── nuc-installer  (Phase 5, x86_64)
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
| 2 | `gnunix-base` | done — `gnunix-base-0.1.0` boots, passes `tests/boot-smoke.sh` (sshd + DHCP). Built with ADR-011 compile-time hardening and ADR-012 module-first kernel. |
| 3 | `gnunix-minimal` | done — `gnunix-minimal-0.1.0` boots, passes `tests/minimal-smoke.sh` (multi-user Nix daemon + nixbld users). |
| 4 | `gnunix-desktop` | done — `gnunix-desktop-0.1.0` boots, passes `tests/wayland-session.sh` (dbus + elogind + greetd running, user provisioned, sway+waybar render). |
| 5 | multi-arch + per-platform packaging | scaffolded (ADR-010) — `tools/package-platform.sh` emits `gnunix-{minimal,desktop}-generic-uefi-aarch64-<ver>.img(.zst)`. `rpi-native` and `nuc-installer` packagers exist but exit 2 until Phase 6 / Phase 5 builder land. |
| 6 | `rpi-native` + `nuc-installer` go live | tracked in `docs/TODO.md` |
| 4.5 | `gnunix-installer` (ADR-015) | scaffolded — `tools/build-all.sh gnunix-installer` produces a live image with a whiptail TUI that lets the user pick `minimal` / `desktop-sway` / `desktop-hyprland` / `desktop-labwc` / `desktop-cosmic` (ADR-022). Acceptance tests under `tests/installer/profile-*.sh` drive the installer unattended against an empty target disk, boot the installed system, and assert universal + per-profile state. TUI interactions are covered by `tests/installer/tui-interactions.sh` (expect-driven, host-side). CI: `gnunix-installer` + `installer-test` jobs in `build.yml`. |
| 7 | CI/Renovate/Releases | done — three-workflow pipeline (ADR-008). `build.yml` runs gnunix-base → gnunix-minimal → gnunix-desktop → gnunix-installer → installer-test (matrix) → package matrix and always uploads artifacts (tiered retention by event). `tag-on-version-bump.yml` auto-tags `v<X.Y.Z>` when `tools/manifest.json:lfs_image_version` changes on `main`. `release.yml` triggers on tag push, downloads artifacts from the corresponding `build.yml` run, and drafts a GitHub Release. See `docs/runbooks/release.md`. |

## Locked decisions

See `docs/adrs/` for full ADRs. Headlines:

- **ADR-001:** sysvinit + BSD `/etc/rc.d/`
- **ADR-002:** elogind for seat management
- **ADR-003:** multi-user Nix daemon
- **ADR-004:** plain Nix profiles + home-manager (no NixOS modules)
- **ADR-005:** developer workstation, this Mac first
- **ADR-006:** GRUB EFI bootloader
- **ADR-007:** LFS-ARM (aarch64)
- **ADR-008:** Renovate + GitHub Releases for image publishing
- **ADR-009:** Sway + greetd; dbus/elogind/greetd/sway sourced from nixpkgs into `/nix/var/nix/profiles/system`
- **ADR-010:** Multi-arch axis + per-platform packagers (generic-uefi, rpi-native, nuc-installer); i686 out of scope
- **ADR-011:** Compile-time hardening flags for `gnunix-base` — `_FORTIFY_SOURCE=3`, `-fstack-protector-strong`, `-fstack-clash-protection`, PIE, full RELRO + BIND_NOW, `-mbranch-protection=standard` (aarch64); delivered via `manifest.json:hardening` + `lib/hardening.sh` helper
- **ADR-012:** Module-first kernel — only boot-critical drivers stay `=y` in `kernel.config`; everything else becomes `=m` in `kernel.modules.config` and auto-loads via eudev MODALIAS coldplug; `/etc/modules-load.d/*.conf` + `rc.modules` for explicit overlays
- **ADR-013:** Distribution renamed to **GNUnix** (was `lfs-nix-distro`); image lineage renamed `lfs-{core,nix,wayland,builder}` → `gnunix-{base,nix,desktop,builder}`
- **ADR-014:** AI-assisted PR review — deterministic checks (`pr-lint.yml`) block; LLM-driven architectural review (`ai-review.yml` + `.claude/skills/pr-review/`) is opt-in advisory. Provider-agnostic over any OpenAI-compatible API; defaults to OpenRouter free tier.
- **ADR-015:** Live installer (`gnunix-installer`) + multiple installable compositor profiles, whiptail TUI. *(Amended by ADR-017 + ADR-019 + ADR-022.)*
- **ADR-016:** CI split — routine validation on hosted `ubuntu-22.04-arm` + qemu+KVM; `gnunix-base` rebuilds happen locally on Mac and ship as GH Release artifacts. *(Amends ADR-008. Amended by ADR-021.)*
- **ADR-017:** Live-ISO architecture for `gnunix-installer` — squashfs + overlayfs + custom minimal initramfs (busybox-static), hybrid EFI ISO via `xorriso`. Adds 4 `=m` modules to the module-first kernel (per ADR-012).
- **ADR-018:** Artifact taxonomy + naming + release flow — three forms (`.iso` / `.img.zst` / `.tart.zst`), flat grammar `gnunix-<image>-<arch>[-<platform>]-<ver>.<ext>`, four published images, `gnunix-minimal` as CI release-dep anchor. Unified `tools/package.sh`. *(Amends ADR-008, ADR-010.)*
- **ADR-019:** Image lineage roles + installer pivot — installer layered on `gnunix-minimal` (text-only live env, network-required desktop installs). TUI flow: edition → compositor → identity. Finishes `gnunix-nix → gnunix-minimal` rename. *(Extends ADR-013, ADR-015.)*
- **ADR-020:** Reference compositor switched Sway → **Hyprland**; Sway demoted to optional install profile. *(Amends ADR-009. Amended by ADR-022.)*
- **ADR-021:** **No self-hosted CI runners — ever.** Every workflow runs on free GitHub-hosted runners only. The `gnunix-base` rebuild (6–10 h) stays on the maintainer's *unmanaged* Mac and ships as a GH Release artifact; CI fetches via `tools/fetch-image.sh`. Phase 5/6 of ADR-010 must use hosted runners (qemu+KVM on `ubuntu-22.04`) or stay as local-developer builds. *(Amends ADR-008, ADR-010, ADR-016.)*
- **ADR-022:** Add **`desktop-cosmic`** as a fourth optional installer compositor — System76 COSMIC, init-agnostic (uses `dbus-run-session`, not `systemd --user`), integrates with elogind per ADR-002. Pulled at install time per ADR-015/019; not pre-baked into `gnunix-desktop` — Hyprland remains the reference. *(Amends ADR-015, ADR-020.)*

## Key invariants

- **No systemd, anywhere in the base.** Adding it pulls in logind/networkd/journald and breaks ADR-001/002/006.
- **No NixOS modules.** Userland config is via home-manager only (ADR-004).
- **Linear image lineage.** A new variant gets a new directory under `images/variants/`, not an inline branch in an existing image.
- **Pinned everything.** Every external version lives in `tools/manifest.json`; Renovate is the only path that changes those pins.
- **Static base, dynamic userland.** When in doubt, the change goes in Nix, not in `/etc`.
- **No self-hosted CI runners.** Per ADR-021. Workflows that pin self-hosted labels are a regression.

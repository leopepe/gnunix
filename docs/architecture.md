# Architecture — GNUnix

This is the in-repo expansion of the project strategy. The canonical strategy
lives at `~/Documents/hyground/analysis/gnunix-nix-wayland-distro-strategy.md`.

> **Naming.** The project was renamed from the placeholder `lfs-nix-distro`
> to **GNUnix** per [ADR-013](adrs/ADR-013-rename-to-gnunix.md). Source tree
> and image lineage now use `gnunix-{base,nix,desktop,builder}`. Older ADRs
> (001–012) keep the pre-rename names (`lfs-core`, `lfs-nix`, `lfs-wayland`,
> `lfs-builder`) for historical fidelity; ADR-013 records the mapping.

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
gnunix-builder       (Ubuntu arm64, builds GNUnix from source)
   │
   ├─> gnunix-base     (was lfs-core)         (done)
   │
   ├─> gnunix-nix      (was lfs-nix)          (done)
   │
   ├─> gnunix-desktop  (was lfs-wayland)      (done)
   │       │
   │       └─> gnunix-installer (live image, ADR-015) (scaffolded)
   │               picks { minimal | desktop-sway | desktop-hyprland | desktop-labwc }
   │               and installs to bare metal
   │
   └─> variants/                              (scaffolded, ADR-010)
       ├── generic-uefi   (shipping for aarch64)
       ├── rpi-native     (kernel additions + firmware pin needed)
       └── nuc-installer  (needs x86_64 builder)
```

Each downstream image is **forked from the previous tag**, never re-built from
scratch. This keeps the lineage linear and reproducible.

## Phase status

| Phase | Image | Status |
|---|---|---|
| 0 | workspace bootstrap | done |
| 1 | `gnunix-builder` | done — `tools/bootstrap-builder.sh` produces `gnunix-builder:base` |
| 2 | `gnunix-base` | done — `gnunix-base-0.1.0` boots, passes `tests/boot-smoke.sh` (sshd + DHCP). Built with ADR-011 compile-time hardening and ADR-012 module-first kernel. |
| 3 | `gnunix-nix` | done — `gnunix-nix-0.1.0` boots, passes `tests/nix-smoke.sh` (multi-user Nix daemon + nixbld users). |
| 4 | `gnunix-desktop` | done — `gnunix-desktop-0.1.0` boots, passes `tests/wayland-session.sh` (dbus + elogind + greetd running, user provisioned, sway+waybar render). |
| 5 | multi-arch + per-platform packaging | scaffolded (ADR-010) — `tools/package-platform.sh` emits `gnunix-{nix,desktop}-generic-uefi-aarch64-<ver>.img(.zst)`. `rpi-native` and `nuc-installer` packagers exist but exit 2 until Phase 6 / Phase 5 builder land. |
| 6 | `rpi-native` + `nuc-installer` go live | tracked in `docs/TODO.md` |
| 4.5 | `gnunix-installer` (ADR-015) | scaffolded — `tools/build-all.sh gnunix-installer` produces a live image with a whiptail TUI that lets the user pick `minimal` / `desktop-sway` / `desktop-hyprland` / `desktop-labwc`. Acceptance tests under `tests/installer/profile-*.sh` drive the installer unattended against an empty target disk, boot the installed system, and assert universal + per-profile state. CI: `gnunix-installer` + `installer-test` jobs in `build.yml`. |
| 7 | CI/Renovate/Releases | done — three-workflow pipeline (ADR-008). `build.yml` runs gnunix-base → gnunix-nix → gnunix-desktop → gnunix-installer → installer-test (matrix) → package matrix and always uploads artifacts (tiered retention by event). `tag-on-version-bump.yml` auto-tags `v<X.Y.Z>` when `tools/manifest.json:lfs_image_version` changes on `main`. `release.yml` triggers on tag push, downloads artifacts from the corresponding `build.yml` run, and drafts a GitHub Release. See `docs/runbooks/release.md`. |

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

## Key invariants

- **No systemd, anywhere in the base.** Adding it pulls in logind/networkd/journald and breaks ADR-001/002/006.
- **No NixOS modules.** Userland config is via home-manager only (ADR-004).
- **Linear image lineage.** A new variant gets a new directory under `images/variants/`, not an inline branch in an existing image.
- **Pinned everything.** Every external version lives in `tools/manifest.json`; Renovate is the only path that changes those pins.
- **Static base, dynamic userland.** When in doubt, the change goes in Nix, not in `/etc`.

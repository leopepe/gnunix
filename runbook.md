# RUNBOOK

This runbook indexes the in-depth runbooks under `docs/runbooks/`.

> **Project name.** The distribution is **GNUnix** (renamed from
> `lfs-nix-distro` per [ADR-013](docs/adrs/ADR-013-rename-to-gnunix.md)).
> Image lineage: `gnunix-base` → `gnunix-nix` → `gnunix-desktop`,
> built by `gnunix-builder`. Older ADRs (001–012) still mention the
> pre-rename names; see ADR-013 for the rename mapping.

## Phase 2 — building and testing `gnunix-base` ✓ complete

| Procedure | Runbook |
|---|---|
| Bootstrap `gnunix-builder`, fetch sources, build `gnunix-base`, package as Tart image | [`docs/runbooks/build.md`](docs/runbooks/build.md) |
| Smoke-test a built `gnunix-base-<ver>` Tart image | [`docs/runbooks/test-image.md`](docs/runbooks/test-image.md) |

The pipeline produces a bootable `gnunix-base-0.1.0` Tart VM that passes `tests/boot-smoke.sh` (SSH + default route). `dbus`/`elogind` are deferred to a later phase.

## Phase 3 — adding the Nix layer ✓ complete

| Procedure | Runbook |
|---|---|
| Layer multi-user Nix on `gnunix-base-<ver>` → `gnunix-nix-<ver>` | [`docs/runbooks/build-nix.md`](docs/runbooks/build-nix.md) |
| Smoke-test `gnunix-nix-<ver>` | [`docs/runbooks/build-nix.md`](docs/runbooks/build-nix.md#smoke-test) |

```sh
tools/build-all.sh gnunix-nix             # ~5-15 min; clones gnunix-base, scp+install Nix
tests/nix-smoke.sh gnunix-nix-0.1.0       # verifies nix + daemon + nixbld users
```

## Phase 4 — Wayland session bring-up ✓ scaffolded

| Procedure | Runbook |
|---|---|
| Layer dbus/elogind/greetd/sway on `gnunix-nix-<ver>` → `gnunix-desktop-<ver>` | [`docs/runbooks/build-wayland.md`](docs/runbooks/build-wayland.md) |
| Smoke-test `gnunix-desktop-<ver>` | [`docs/runbooks/build-wayland.md`](docs/runbooks/build-wayland.md#smoke-test) |
| Decisions: compositor + greeter + system-service sourcing | [`docs/adrs/ADR-009`](docs/adrs/ADR-009-wayland-stack.md) |

```sh
tools/build-all.sh gnunix-desktop             # ~10-25 min; clones gnunix-nix, installs system Nix profile
tests/wayland-session.sh gnunix-desktop-0.1.0 # verifies dbus + elogind + greetd + user
```

The Phase 4 v1 smoke test asserts components are installed and supervised.
Actually rendering a Wayland frame from CI is deferred (ADR-009 "Out of scope").

## Phase 5 — multi-arch + per-platform packaging ✓ scaffolded

| Procedure | Runbook |
|---|---|
| Repackage a base image for a target platform | [`docs/runbooks/platforms.md`](docs/runbooks/platforms.md) |
| Add a new platform | [`docs/runbooks/platforms.md#adding-a-new-platform`](docs/runbooks/platforms.md#adding-a-new-platform) |
| Decisions: arch axes, platforms, image formats | [`docs/adrs/ADR-010`](docs/adrs/ADR-010-multi-arch-and-platforms.md) |

```sh
tools/build-all.sh gnunix-desktop                                # base image
tools/package-platform.sh gnunix-desktop aarch64 generic-uefi    # → gnunix-desktop-generic-uefi-aarch64-0.1.0.img(.zst)
tools/package-platform.sh gnunix-desktop aarch64 rpi-native      # scaffolded; rc=2 until Phase 6
tools/package-platform.sh gnunix-desktop x86_64  nuc-installer   # scaffolded; rc=2 until x86_64 builder lands
```

CI matrix (`.github/workflows/build.yml` `package` job) runs the supported
triples on every build and uploads them as workflow artifacts. On a `v*`
tag push, [`release.yml`](.github/workflows/release.yml) collects those
artifacts and drafts a GitHub Release — see Phase 7 below.

## Phase 7 — CI / Releases ✓ done (operator-facing)

| Procedure | Runbook |
|---|---|
| Cut a release (bump → auto-tag → draft GH Release) | [`docs/runbooks/release.md`](docs/runbooks/release.md) |
| Decisions: dependency updates + release flow | [`docs/adrs/ADR-008`](docs/adrs/ADR-008-renovate-and-release.md) |
| Decisions: AI-assisted PR review | [`docs/adrs/ADR-014`](docs/adrs/ADR-014-ai-pr-review.md) |

Three workflows participate (one responsibility each):

- [`.github/workflows/build.yml`](.github/workflows/build.yml) — builds + smoke-tests + uploads disk and platform artifacts.
- [`.github/workflows/tag-on-version-bump.yml`](.github/workflows/tag-on-version-bump.yml) — auto-tags `v<X.Y.Z>` when `tools/manifest.json:lfs_image_version` changes on `main`.
- [`.github/workflows/release.yml`](.github/workflows/release.yml) — on tag push, drafts the GitHub Release from the corresponding `build.yml` artifacts.

PR-time gates ([ADR-014](docs/adrs/ADR-014-ai-pr-review.md)):

- [`.github/workflows/pr-lint.yml`](.github/workflows/pr-lint.yml) — shellcheck + actionlint + gitleaks + manifest schema. **Blocks** merge.
- [`.github/workflows/pr-labeler.yml`](.github/workflows/pr-labeler.yml) — applies `area/*` labels from path globs.
- [`.github/workflows/ai-review.yml`](.github/workflows/ai-review.yml) — opt-in via `@ai review` / `@claude review` comment or `ai-review` / `claude-review` label; **advisory**. Provider-agnostic (OpenAI-compatible API); defaults to OpenRouter free tier.

## Phase 6+ (planned)

| Procedure | Status |
|---|---|
| Bring `rpi-native` online — kernel additions + firmware pinning | tracked in [`docs/TODO.md`](docs/TODO.md) |
| Bring `nuc-installer` online — x86_64 builder + installer scripts | tracked in [`docs/TODO.md`](docs/TODO.md) |
| xdg-desktop-portal (Phase 4.1 follow-up) | not yet written |
| home-manager bootstrap (per ADR-004) | not yet written |
| Security hardening (compile-time + system config) | tracked in [`docs/TODO.md`](docs/TODO.md) |

## Quick reference

```sh
# End-to-end Phase 2 (gated; AUTO=1 to skip prompts):
tools/phase2.sh

# Individual stages:
tools/bootstrap-builder.sh                   # one-time: produce gnunix-builder:base (auto-installs SSH key)
tools/fetch-sources.sh                       # pre-fetch tarballs to cache/sources/ (host network)
tools/build-all.sh gnunix-base                  # build + mkimage + tart-import → gnunix-base-<ver>
tests/boot-smoke.sh gnunix-base-0.1.0           # acceptance test

# Resume a failed Phase 2 build, preserving completed in-VM stages (cross, etc.):
REUSE_BUILDER=1 tools/build-all.sh gnunix-base

# Phase 3: layer Nix on top of the Phase 2 image.
tools/build-all.sh gnunix-nix                   # → gnunix-nix-<ver>
tests/nix-smoke.sh gnunix-nix-0.1.0

# Phase 4: layer dbus/elogind/greetd/sway on top of the Phase 3 image.
tools/build-all.sh gnunix-desktop               # → gnunix-desktop-<ver>
tests/wayland-session.sh gnunix-desktop-0.1.0

# Retrofit SSH key into a bootstrapped-but-keyless builder snapshot:
tools/install-builder-key.sh

# Open an interactive shell on a running VM:
scripts/enter-vm.sh <vm-name>
```

## Build artifacts

Each phase emits a portable raw disk image under `cache/artifacts/`:

- `cache/artifacts/gnunix-base-disk-<ver>.img`                              — Phase 2 base
- `cache/artifacts/gnunix-nix-disk-<ver>.img`                               — Phase 3 (gnunix-base + Nix)
- `cache/artifacts/gnunix-desktop-disk-<ver>.img`                           — Phase 4 (gnunix-nix + Wayland stack)
- `cache/artifacts/gnunix-{nix,desktop}-generic-uefi-aarch64-<ver>.img`     — Phase 5: platform-packaged for any UEFI host (~9 GB raw / ~750 MB zstd)
- `cache/artifacts/gnunix-{nix,desktop}-rpi-native-aarch64-<ver>.img`       — Phase 6 (planned): Raspberry Pi SD-card image
- `cache/artifacts/gnunix-{nix,desktop}-nuc-installer-x86_64-<ver>.iso`     — Phase 5 (planned): NUC live ISO + installer

They're generic GPT/UEFI/ext4 images — Tart is one consumer, but they also boot under QEMU/KVM, libvirt, UTM, Proxmox, or Apple Silicon bare metal. See [`docs/runbooks/build-nix.md` § Consumers](docs/runbooks/build-nix.md#consumers-of-the-produced-image).

## Prerequisites on the macOS host

```sh
brew install cirruslabs/cli/tart jq rsync
[ -f ~/.ssh/id_ed25519.pub ] || ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519
```

The SSH key is required — `bootstrap-builder.sh` installs it into the builder VM, and `build-all.sh` installs it into `/root/.ssh/authorized_keys` in the built image so the smoke test can ssh in.

## Gotchas worth knowing

- **`ext4 commit=30` + `tart stop`**: the cirruslabs Ubuntu rootfs's journal flushes every 30s; writes within ~30s of `tart stop` can vanish. Always `sync` before stopping the VM. All shipped scripts do this; new ones must too. See [`docs/runbooks/build.md`](docs/runbooks/build.md#persistence-gotcha-ext4-commit30--tart-stop) for the full story.
- **`tart ip` may return empty** even with a working VM. Apple's `bootpd` doesn't always recognize dhcpcd's lease exchange. `scripts/tart-helpers.sh:tart_ip` has an ARP fallback that handles this; if you write a new script, use the helper rather than calling `tart ip` directly.
- **Don't bump pins ad hoc.** Every package version in `tools/manifest.json` was chosen for a specific compatibility reason (m4 1.4.20 not 1.4.19; perl 5.38.2 not 5.40). Use Renovate (ADR-008) to manage bumps.

Architecture and decisions: [`docs/architecture.md`](docs/architecture.md) · [`docs/adrs/`](docs/adrs/)

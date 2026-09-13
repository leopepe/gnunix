# ADR-024: Declarative Nix profiles — system package sets live in a flake

**Status:** Proposed
**Date:** 2026-09-13
**Amends:** [ADR-004](ADR-004-config-style.md), [ADR-009](ADR-009-wayland-stack.md), [ADR-017](ADR-017-live-iso-architecture.md)

Architecture impact: see architecture.md §Two-layer model, §How the system
profile is built, §Locked decisions, §Key invariants.

## Context

Every GNUnix image above `gnunix-base` gets its userland from Nix. Until this
ADR, it got it imperatively: each image's `build.sh` subscribed the chroot to a
nixpkgs channel and ran a sequence of `nix-env -iA` commands. Three concrete
problems follow from that, all observed rather than anticipated.

### The channel is a moving target

`images/gnunix-desktop/build.sh:123` and `images/installer/build.sh:146` both
run

```sh
nix-channel --add "https://nixos.org/channels/nixos-25.11" nixpkgs
nix-channel --update
```

`nixos-25.11` is a branch, not a revision. The same git commit built a week
apart resolves to two different nixpkgs trees and produces two different
images. `tools/manifest.json` pins every LFS component down to a sha256
(ADR-011, ADR-023) and then hands the entire Nix layer to a channel that moves
underneath us. Its `.nix.nixpkgs_rev_pin` field exists and is the empty string.

A distribution that ships tagged releases (ADR-018, ADR-023) has to be able to
rebuild a user's reported version. With a channel it cannot: "0.1.1" names an
LFS base exactly and a userland only approximately.

### The package set is undeclared

There is no file that states what `gnunix-desktop` contains. The answer is the
union of the `-iA` arguments spread across `images/gnunix-desktop/build.sh`,
`images/gnunix-desktop/install-gnunix-desktop.sh`, `images/installer/build.sh`
and `images/installer/install-installer.sh` — several of which are inside
quoted heredocs, so they are shell text inside shell text. Nothing states the
intent, so nothing can check the result: the desktop and installer sets drifted
apart silently, and five tools the installed system needs (`sgdisk`,
`partprobe`, `rsync`, `mkfs.vfat`, `whiptail`) were found missing only at build
time, one error message at a time.

### Running Nix inside a chroot is a failure class, not a bug

The provisioning model — chroot into the mounted image, then run Nix in there —
generated a series of failures that were each fixed individually over a single
day:

| Symptom | Cause | Fixed in |
|---|---|---|
| `cannot pivot old root directory onto '…/real-root': Invalid argument` | Nix's build sandbox sets each derivation up with `pivot_root(2)`, which returns `EINVAL` inside a chroot | [#147](https://github.com/leopepe/gnunix/pull/147) (user-environment), [#152](https://github.com/leopepe/gnunix/pull/152) (channel unpack) |
| `cannot connect to socket at '/nix/var/nix/daemon-socket/socket'` | `NIX_REMOTE=daemon` is inherited, but no `nix-daemon` runs inside the chroot | [#150](https://github.com/leopepe/gnunix/pull/150) |
| `attribute 'nixpkgs' in selection path 'nixpkgs.xorriso' not found` | `-iA nixpkgs.…` resolves against a channel the base image never subscribed to | [#150](https://github.com/leopepe/gnunix/pull/150) |
| `read_symlink: Invalid argument [/nix/var/nix/profiles/system]` | the profile path was pre-created with `mkdir -p`; `nix-env -p` needs to make it a symlink | [#153](https://github.com/leopepe/gnunix/pull/153) |

Every one of those fixes was correct and none of them addressed the cause. The
cause is that a chroot is not a machine: it has no daemon, no channel
subscription, no working `pivot_root`, and no `/proc` unless we bind one in.
`ubuntu-22.04-arm` (ADR-021) is a native aarch64 Linux host that has all four.
The packages we install are built for `aarch64-linux` either way, so nothing
about the artifact requires the chroot — only the habit of installing from
inside it does.

## Decision

**GNUnix's system-wide package sets are declared in the repository's flake and
installed by replacing a Nix profile atomically. No image build runs `nix-env
-iA`, `nix-channel`, or `nix build` inside a chroot.**

### The flake is the declaration

`flake.nix` at the repository root exports one `pkgs.buildEnv` per system
package set, for `aarch64-linux`:

| Output | Contents | Consumer |
|---|---|---|
| `packages.aarch64-linux.desktopProfile` | `nix/desktop.nix` — dbus, elogind, greetd, tuigreet, Hyprland, xdg-desktop-portal-hyprland, hyprpaper, foot, wayland-utils, xkeyboard_config, procps, kmod, mesa, waybar | `gnunix-desktop` system profile |
| `packages.aarch64-linux.installerProfile` | `nix/installer.nix` — the live installer's runtime (whiptail, sgdisk, partprobe, rsync, mkfs.vfat) | `gnunix-installer` system profile |
| `packages.aarch64-linux.installerBuildTools` | `nix/installer-build.nix` — the ISO assembly toolchain (xorriso, squashfsTools, cpio, mtools, dosfstools, busybox, grub2) | build host only; never shipped |
| `packages.aarch64-linux.minimalProfile` | `nix/minimal.nix` — empty today; `gnunix-minimal` is the LFS base plus Nix itself (ADR-003) | `gnunix-minimal` |

Each is built with `pathsToLink = [ "/bin" "/lib" "/share" "/etc" "/libexec" ]`,
so a single store path carries everything the existing `PATH`,
`LD_LIBRARY_PATH`, `LIBGL_DRIVERS_PATH` and `__EGL_VENDOR_LIBRARY_DIRS`
exports already point at.

The distinction between a *runtime* profile and a *build tool* set is now
structural rather than a comment: `installerBuildTools` is a separate output
that is built on the runner and never copied into an image. This replaces
ADR-017's step of `nix-env`-ing xorriso, squashfs-tools, cpio, mtools,
dosfstools and grub-mkimage into a build VM's system profile; the ISO recipe
itself (squashfs + overlayfs + hybrid EFI) is unchanged.

### The install mechanism

Build on the runner, move the closure into the mounted image, then swap the
profile:

```sh
OUT=$(nix build --no-link --print-out-paths .#desktopProfile)
nix copy --no-check-sigs --to "$MNT" "$OUT"
chroot "$MNT" nix-env --profile /nix/var/nix/profiles/system --set "$OUT"
```

`nix copy --to <dir>` writes a local store rooted at that directory, which is
exactly the mounted image. The only command that runs inside the chroot is
`nix-env --set`, which registers a new generation and relinks a symlink — it
builds nothing, so it needs no sandbox, no daemon, and no channel.

### Pinning

`flake.lock` pins nixpkgs to an exact revision. The flake *input* tracks the
branch named by `tools/manifest.json` `.nix.channel` (`nixos-25.11`); the lock
file fixes the revision that branch resolved to. A given commit of this
repository therefore names one nixpkgs tree forever, which is what
`.nix.nixpkgs_rev_pin` was reserving space for and never delivered.

### What this is not

This is flakes as a *package-set declaration*, not flakes as system config.
There is no `configuration.nix`, no NixOS module, no systemd unit, and no
service definition anywhere in `flake.nix` or `nix/`. The boot sequence remains
sysvinit + BSD `/etc/rc.d/` (ADR-001) and the seat manager remains elogind
(ADR-002). ADR-004 rejected "flakes-as-system-config" on the grounds that it
drags NixOS modules back in; that objection does not reach a `buildEnv` whose
entire output is a symlink tree of binaries. ADR-004's ban on NixOS modules
stands unchanged and is restated in architecture.md §Key invariants.

## Consequences

### `--set` is atomic and keeps rollback

`nix-env --profile P --set <path>` points `P` at exactly that derivation in one
`rename(2)`, instead of computing a new user-environment from the union of what
is already installed. A build either produces the declared profile or leaves
the previous one in place; there is no half-installed state. Generations are
still recorded under `/nix/var/nix/profiles/`, so
`nix-env --profile P --rollback` and `--list-generations` work as they always
have. Compared to accumulating `-iA` calls, the profile is now a pure function
of the flake and the lock file rather than of the order in which commands ran.

### Renovate keeps the pin fresh

`flake.lock` joins `tools/manifest.json` and `bundles/*.nix` as a Renovate
target under the single-pin convention of
[ADR-023](ADR-023-cve-hotfix-batch-and-ci-rebuild.md) (which absorbed
[ADR-008](ADR-008-renovate-and-release.md)'s Renovate policy). A nixpkgs bump
becomes a reviewable diff of one revision hash with a CI run attached, which is
what the channel made impossible: there was no artifact to bump and no diff to
review.

### Boot persistence is unchanged

The profile is still `/nix/var/nix/profiles/system`, a symlink on the image's
root partition pointing into `/nix/store` on that same partition. Nothing about
how the running system finds it changes: session wrappers and installer
profile scripts export
`PATH=/nix/var/nix/profiles/system/bin:…` before `exec`ing the compositor,
`images/gnunix-desktop/etc/hypr/hyprland.conf` references binaries under it by
absolute path, and `/etc/profile.d/nix-daemon.sh` (written by
`images/gnunix-minimal/install-gnunix-minimal.sh`) continues to source the Nix
daemon environment at login. Only the writer of the symlink changes.

### ADR-003's multi-user model is unchanged

The image keeps `/nix` root-owned, `nixbld1..32`, `sandbox = true` in its own
`/etc/nix/nix.conf`, and `rc.nix-daemon` supervising the daemon for the running
system. What goes away is the attempt to *use* that model during image
assembly: the build-time work is now root on the runner, against the runner's
own store, and the image's Nix configuration is never overridden at build time.
The `NIX_CONFIG=sandbox=false` workaround from #152 and the
`--option sandbox false` flags from #147 are no longer needed in the desktop and
installer paths.

### Two layers of customization, deliberately

The flake governs the *system* profile — what the distribution ships. Users are
untouched: `~/.nix-profile` still works, `nix-env`/`nix profile` still work per
user, and home-manager remains the supported route for per-user declarative
configuration (ADR-004). A user customizing their machine after install does
not edit this repository's flake, and this repository's flake does not reach
into `$HOME`. The split is the point: the release is reproducible, the user's
machine is theirs.

Installer compositor profiles under `images/installer/installer/profiles/`
still install at install time, on the target machine, against the running
system's daemon (ADR-015, ADR-019, ADR-022). That is a legitimate imperative
use of Nix — it happens on a real booted system, not in a chroot on a build
host — and this ADR does not change it.

### Flakes are still an experimental Nix feature

Nix marks `nix-command` and `flakes` experimental, and has for years. Two
reasons that is acceptable here rather than merely tolerable:

1. The image already enables them.
   `images/gnunix-minimal/install-gnunix-minimal.sh:99` writes
   `extra-experimental-features = nix-command flakes` into `/etc/nix/nix.conf`.
   This ADR adds no new experimental surface to the shipped system; it starts
   using a feature the distribution already turned on.
2. The exposure is bounded. Flake evaluation happens on the build runner. What
   lands in the image is a store closure and a profile symlink — artifacts of
   the stable, pre-flake Nix data model. If the flake schema changed
   incompatibly tomorrow, the repair would be confined to `flake.nix` and
   `nix/*.nix`; no shipped image would need rebuilding to stay bootable.

### Build surface

- Adds: `flake.nix`, `flake.lock`, `nix/profile.nix`, `nix/desktop.nix`,
  `nix/installer.nix`, `nix/installer-build.nix`, `nix/minimal.nix`.
- Removes from `images/gnunix-desktop/build.sh` and `images/installer/build.sh`:
  the `nix-channel --add/--update` pair, every chroot-side `nix-env -iA`, the
  `NIX_CONFIG`/`--option sandbox false` workarounds, and the `/proc`, `/dev/null`
  and pty binds that existed only so `nix-env` could run in there.
- CI (`.github/workflows/build.yml`) needs Nix on the runner with
  `nix-command flakes` enabled, and a flake-aware cache key.
- Forks get a rebuild of the exact userland from the exact commit, which is the
  fork story ADR-021 argues for and the channel silently broke.

## Out of scope

- **NixOS modules.** Forbidden by ADR-004 and incompatible with ADR-001: this
  is not a NixOS system, it has no systemd, and a module set would expect one.
  A flake that exports `buildEnv` derivations is not a step toward
  `nixosConfigurations`.
- **x86_64.** The flake exports `aarch64-linux` only. Adding a second system is
  ADR-010 Phase 5 work and gets written into `flake.nix` when that phase lands,
  not abstracted for in advance.
- **Per-user declarative configuration.** home-manager and `~/.nix-profile`
  stay exactly as ADR-004 defines them. This ADR draws no conclusion about how
  users manage their own environments.
- **Binary cache / substituter changes.** The build continues to substitute
  from `cache.nixos.org`. Whether GNUnix publishes its own cache is separate
  work.
- **Declaring the LFS base in Nix.** The base is built from source per ADR-007
  and pinned in `tools/manifest.json` per ADR-011/ADR-023. Nothing here touches
  it.

## Open questions

1. **Renovate's nix manager.** `.github/renovate.json5` carries the stale
   comment "Don't update lock files (we have none yet; Phase 3 may add
   flake.lock)". Renovate's `nix` manager is enabled by default and should pick
   `flake.lock` up, but this has not been observed on a real PR yet. Verify on
   the first nixpkgs bump after this lands.
2. **Does `minimalProfile` earn its existence?** It is reserved and may be an
   empty `buildEnv` today. If `gnunix-minimal` never needs a system profile,
   the output should be dropped rather than shipped empty.
3. **Closure size in the image.** `nix copy` moves the full closure, including
   paths that `nix-env -iA` would also have pulled. No measurement has been
   taken of whether the image grows or shrinks relative to the channel-based
   builds. Measure once a green run exists.

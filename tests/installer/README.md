# Installer acceptance tests

End-to-end tests that drive `gnunix-installer` in unattended mode against
a fresh target disk, then **boot the installed system** and assert that
the chosen profile produced the expected configuration.

These complement the upstream image tests:

| Image | Test |
|---|---|
| `gnunix-base` | `tests/boot-smoke.sh` (boots, ssh, dbus, nix-daemon) |
| `gnunix-nix` (a.k.a. `gnunix-minimal`) | `tests/nix-smoke.sh` |
| `gnunix-desktop` | `tests/wayland-session.sh` |
| `gnunix-installer` *output for each profile* | **`tests/installer/profile-*.sh`** |

## How it works

Per profile, two phases:

```
Phase 1  Install
  1. fresh raw .img (10 GB) on the host        cache/installer-test/<profile>-target.img
  2. clone gnunix-installer-<ver> → gnunix-installer-test
  3. tart run --disk=<target>:sync=none, ssh in
  4. GNUNIX_INSTALL_UNATTENDED=1 GNUNIX_TARGET_DISK=/dev/vdb \
       GNUNIX_PROFILE=<p> GNUNIX_USER=tester GNUNIX_PASSWORD=test1234 \
       /usr/local/sbin/gnunix-installer
  5. sync, stop the installer VM

Phase 2  Boot the installed disk
  6. tart create gnunix-installed-<profile> from the target .img
  7. boot it, ssh in as root
  8. run universal asserts + per-profile asserts
  9. PASS / FAIL  (single line, like boot-smoke.sh / validate-wayland.sh)
```

The driver is `scripts/run-installer-test.sh <profile>`; the assertions
are in `scripts/validate-installed.sh <profile> <vm>`.

## What gets checked

### Universal (every profile)

| Check | Why it matters |
|---|---|
| `/etc/hostname` == `GNUNIX_HOSTNAME` | confirms the installer wrote target /etc, not the live one |
| `/etc/os-release` has `ID=gnunix` + `VARIANT_ID=<profile>` | identifies which profile produced this rootfs |
| user account exists, has hashed password, shell `/bin/bash` | sanity for login |
| user is in `wheel` + `nixbld` | sudo + nix-build groups |
| `/etc/fstab` has root and ESP/boot | the installer wrote a working mount map |
| `/boot/efi/EFI/BOOT/BOOT*.EFI` exists | GRUB EFI binary actually installed |
| `/boot/grub/grub.cfg` references `/boot/vmlinuz*` | bootloader has a kernel entry |
| `nix --version` works | nix daemon profile linked correctly |
| `nix-daemon` running | rc.nix-daemon enabled and started |
| `sshd` running | we got *here* via ssh, but assert anyway |

### `minimal`

| Check | Why |
|---|---|
| `rc.greetd` **not** executable | minimal must not bring up a display manager |
| `/etc/inittab` has tty1 agetty enabled | so the user can actually log in |
| no compositor binary in system profile | no Sway/Hyprland/labwc on the minimal path |

### `desktop-sway`

| Check | Why |
|---|---|
| `rc.greetd` executable, tty1 agetty disabled | greetd owns vt1 |
| `$SP/bin/{sway,waybar,foot,tuigreet}` | shipped in the desktop rootfs |
| `/usr/local/bin/start-wayland-session.sh` execs `sway` | session wrapper points at the right WM |
| `~/.config/sway/config` seeded for the user | user has a starter config |
| user in `video input render seat` groups | needed by libinput / DRM / logind |

### `desktop-hyprland`

| Check | Why |
|---|---|
| `$SP/bin/Hyprland` exists | profile script pulled `nixpkgs.hyprland` successfully |
| `start-wayland-session.sh` execs `Hyprland` | wrapper rewritten by the profile script |
| `~/.config/hypr/hyprland.conf` seeded | starter config |
| user in Wayland groups | same as sway |

### `desktop-labwc`

| Check | Why |
|---|---|
| `$SP/bin/labwc` exists | profile script pulled `nixpkgs.labwc` |
| `start-wayland-session.sh` execs `labwc` | wrapper rewritten |
| `~/.config/labwc/rc.xml` seeded | starter compositor config |
| `~/.config/labwc/autostart` executable + launches waybar | status bar autostart |
| user in Wayland groups | same as sway |

## Running

Prereqs: `gnunix-installer-<ver>` Tart VM exists (build it first).

```sh
# Single profile:
tests/installer/profile-minimal.sh

# All profiles, summary at end:
tests/installer/run-all.sh
```

## Diagnostics on failure

On a failure, `run-installer-test.sh` **preserves** the artifacts so you
can rerun by hand:

- Target disk:  `cache/installer-test/<profile>-target.img`
- Installed VM: `gnunix-installed-<profile>` (not deleted)

To reproduce:

```sh
tart run --no-graphics gnunix-installed-<profile>
ssh -i ~/.ssh/<key> root@$(tart ip gnunix-installed-<profile>)
```

On success, both are removed automatically.

## What's *not* tested here

- **Actual graphical session**. We assert binaries + configs + groups
  are correct, but don't drive Sway/Hyprland/labwc to render a frame.
  That's a separate testing problem (see ADR-009 "Out of scope" and
  `docs/TODO.md` "Wayland framebuffer capture in CI").
- **GUI flow of the TUI itself** (radiolist, password prompts).
  Unattended mode bypasses the TUI; testing whiptail interactions
  needs a tty harness (`expect`) which is deferred.
- **Reinstall / upgrade-in-place**. The installer is single-shot for
  v1; reinstall-over-existing is an open question in ADR-015.
- **Multi-disk / RAID / LUKS**. Out of scope for v1 per ADR-015.

## CI integration

These tests are slow (full install + reboot, ~10–20 min per profile on
the macOS-arm64 runner). The expectation per ADR-015:

- `profile-minimal` and `profile-sway` run on every PR that touches
  `images/installer/` or `images/gnunix-desktop/`.
- `profile-hyprland` and `profile-labwc` run nightly (network-dependent
  closures from `cache.nixos.org` are flakier).

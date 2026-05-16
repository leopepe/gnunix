# TODO

Open work, tracked by topic. Each item is a placeholder until elaborated into an ADR or a runbook.

## Security hardening

Two surfaces to harden: **compile-time** (how packages are built) and **system configuration** (how the running system is locked down). Phase 2/3 prioritized "make it work"; this list is the "make it safe" follow-up.

### Compile-time hardening — **proposal locked in [ADR-011](adrs/ADR-011-compile-time-hardening.md)**

The specific flag set, per-stage exclusions, per-package exceptions, and
delivery mechanism (manifest.json + `lib/hardening.sh` helper) are now
recorded in ADR-011. Items below are implementation steps:

- [ ] **Land manifest schema + helper** — add `hardening: { ... }` block to `tools/manifest.json` per ADR-011 § 4. Write `images/gnunix-base/lib/hardening.sh` exposing `hardening_export <pkg>`. Dead code until stages call it; no rebuild yet.
- [ ] **Wire stage 01-cross-toolchain.sh** — source the helper, call `hardening_export binutils-pass1` / `gcc-pass1` / `glibc` etc. before each `./configure`. Rebuild + boot-smoke. Expand `exclude` block on breakage.
- [ ] **Wire stage 02-temp-tools.sh** — same pattern, native-set flags.
- [ ] **Wire stage 03b-chroot-inner.sh** — final native build, full native flag set with per-package exclusions.
- [ ] **Reproducible builds** — `SOURCE_DATE_EPOCH`, sorted file lists in archives, strip-nondeterminism over the rootfs before mkimage. Side benefit: a sha256 of the produced disk image becomes meaningful. (Out of scope for ADR-011; needs its own ADR.)
- [ ] **Kernel hardening** — review `images/gnunix-base/kernel.config` against KSPP recommendations: `CONFIG_INIT_STACK_ALL_ZERO`, `CONFIG_INIT_ON_ALLOC_DEFAULT_ON`, `CONFIG_INIT_ON_FREE_DEFAULT_ON`, `CONFIG_RANDOM_KMALLOC_CACHES`, `CONFIG_RANDOMIZE_KSTACK_OFFSET_DEFAULT`, `CONFIG_STRICT_KERNEL_RWX`, `CONFIG_STRICT_MODULE_RWX`, `CONFIG_BUG_ON_DATA_CORRUPTION`, `CONFIG_LOCKDOWN_LSM` (with `lockdown=integrity` on cmdline). (Out of scope for ADR-011; needs its own ADR.)

### Module-first kernel (ADR-012)

- [x] **Manifest schema + helper + stage wiring** — done; `kernel.config` (built-in set) + `kernel.modules.config` (`=m` overrides) + `rc.modules` (reads `/etc/modules-load.d/*.conf`) all in place. Stage 04 concatenates both fragments before `olddefconfig`; `rc.S` invokes `rc.modules` after the `udevadm trigger` line.
- [ ] **Kernel rebuild** — `REUSE_BUILDER=1 tools/build-all.sh gnunix-base` re-runs stage 04 only (~10–20 min). Verify with `tests/boot-smoke.sh` (DHCP up means VIRTIO_NET module auto-loaded by eudev MODALIAS) and `ssh root@vm 'lsmod | head'` (modules actually loaded, vs everything `=y`).
- [ ] **Per-platform module overlays** — Phase 6: `images/variants/rpi-native/etc/modules-load.d/rpi.conf` listing BCM2835/2712-specific modules. `images/variants/nuc-installer/etc/modules-load.d/intel.conf` for `intel_pstate`, etc.
- [ ] **Compressed modules** — optional follow-up. `CONFIG_MODULE_COMPRESS_ZSTD=y` shrinks `/lib/modules/<ver>/` substantially; needs `kmod` built with `--with-zstd` (re-check our `kmod` build).

### System configuration hardening

Apply at finalize-time (image build) and/or via sysvinit `rc.d` scripts at boot. Keep these declarative — the static base shouldn't drift, per CLAUDE.md philosophy.

- [ ] **`/etc/sysctl.d/`** with hardened defaults — `kernel.dmesg_restrict=1`, `kernel.kptr_restrict=2`, `kernel.unprivileged_userns_clone=1` (Nix needs this), `fs.protected_*`, `net.ipv4.tcp_syncookies=1`, etc. Source: KSPP / CIS Linux Benchmark.
- [ ] **Filesystem permissions audit** — `/etc/shadow`, `/etc/sudoers.d/`, `/var/log/btmp`, `/var/log/wtmp` modes; pruning suid bits we don't need (we ship far fewer suid binaries than a typical distro, but audit).
- [ ] **SSH server hardening** — already prohibit-password; add `MaxAuthTries 3`, `PermitEmptyPasswords no` (default), `AllowAgentForwarding no`, `AllowTcpForwarding local`, modern cipher/MAC/KexAlgo list. Restrict to ssh key auth only once we have a stable workflow.
- [ ] **PAM module hardening** — pwquality, faillock, account/session restrictions. We ship pam but don't currently use it for sshd (we configured `--without-libpam` in shadow); revisit when dbus/elogind come back.
- [ ] **Mount hardening** — `nosuid,nodev` on `/tmp`, `/var/tmp`, `/dev/shm` (already), `/home` (when we have users). Consider `/var` and `/usr` with `ro` after boot via a remount in `rc.M`.
- [ ] **Network defaults** — firewall posture. Nothing listens externally except sshd, but should we enable an iptables/nftables baseline? Probably yes for the variants/ images that ship to users.
- [ ] **No root SSH login long-term** — current image has the host's pubkey in `/root/.ssh/authorized_keys` to make the smoke test work. For shipping images, replace with a non-root user + `wheel` group + sudo, and disable root SSH.
- [ ] **Verified boot path** — GRUB → kernel → init currently has no signature verification. UEFI Secure Boot + a signed kernel + signed GRUB modules is the eventual target.
- [ ] **AppArmor / SELinux** — out of scope per current architecture (static base, dynamic userland), but worth a decision ADR before Phase 4. Likely: ship without an MAC framework for the dev workstation audience (ADR-005), revisit if/when we target shared multi-user.

### Supply chain

- [ ] **Pin everything by sha256** — done for tarballs in `tools/manifest.json`; extend to the cirruslabs Ubuntu base image (currently floating `latest`), the Nix binary tarball (done), and GitHub Actions versions (Renovate handles these).
- [ ] **Reproducible image hashes** — once the build is bit-reproducible, publish the expected sha256 alongside the GitHub Release so a downloader can verify they got the same bytes the CI produced.
- [ ] **SBOM** — produce a Software Bill of Materials per release. `tools/manifest.json` is close; turn it into a proper SPDX or CycloneDX document.

---

To pick this up: open a new ADR for each major decision (e.g. `ADR-010-compile-time-hardening`, `ADR-011-mac-framework-choice`), then translate the chosen approach into stage-script edits and finalize.sh sysctls. (ADR-009 is the Wayland-stack ADR.)

## Phase 5 / 6 — bring scaffolded platforms online (ADR-010)

The CI matrix and `tools/package-platform.sh` dispatcher are in place; what's left is wiring the real platform packagers and (for x86_64) a separate builder.

### `rpi-native` (Raspberry Pi 4 / 5) — Phase 6

- [ ] **Kernel additions in `images/gnunix-base/kernel.config`**: `CONFIG_ARCH_BCM2835`, `CONFIG_BCM2835_MMC`, `CONFIG_DRM_VC4`, `CONFIG_BCMGENET`, `CONFIG_USB_XHCI_PCI`, `CONFIG_PINCTRL_BCM2835`, `CONFIG_BROADCOM_PHY`. Pi 5 needs rpi-6.6+ tree for full BCM2712 coverage — bump `manifest.json:kernel.version` accordingly.
- [ ] **Pin Pi firmware blobs in `manifest.json:platforms["rpi-native"].firmware`** (`{version, url, sha256}`) — typically a tag from `https://github.com/raspberrypi/firmware`. Extend `tools/fetch-sources.sh` to pull them into `cache/sources/`.
- [ ] **Flip `manifest.json:platforms["rpi-native"].kernel_has_bcm_drivers` to `true`** once the kernel config has been validated.
- [ ] **Implement `images/variants/rpi-native/package.sh`**: losetup the source aarch64 disk image, build an MBR-partitioned output (FAT32 256 MiB `/boot` + ext4 root), rsync the rootfs, drop firmware blobs + DTB + `config.txt` + `cmdline.txt` into `/boot`. Compress with zstd.
- [ ] **Remove the `- platform: rpi-native` exclude** from the CI matrix in `.github/workflows/build.yml`.
- [ ] **First-boot resize**: write a `rc.firstboot` that detects the rootfs is smaller than the medium and grows it via `parted` + `resize2fs`. Disable itself after the first run.
- [ ] **On-device test**: at minimum boot the produced image on a real Pi 4 + Pi 5 once before declaring done; CI can't do this.

### `nuc-installer` (Intel NUC + generic x86_64 UEFI) — Phase 5

- ~~**Provision a self-hosted Linux x86_64 runner**~~ — **superseded by [ADR-021](adrs/ADR-021-no-self-hosted-runners.md)**. No self-hosted runners. Phase 5 x86_64 builds either use hosted `ubuntu-22.04` + qemu+KVM (via the `scripts/vm-helpers.sh` qemu driver — PR-3b's scope), or stay as a local-developer build that ships via `tools/release-image.sh`.
- [ ] **Cross-build gnunix-base for x86_64**: thread `manifest.json:archs.x86_64.*` through the ~12 files audited in ADR-010 § discussion — `images/gnunix-base/build.sh` (`LFS_TGT`), the stages (kernel ARCH, GRUB target, lib64 handling), `images/gnunix-base/packaging/mkimage.sh` (GRUB target + EFI loader name), `images/gnunix-builder/provision.sh` (GRUB package name).
- [ ] **Split `images/gnunix-base/kernel.config`** into per-arch files or use conditional fragments — x86_64 needs `CONFIG_MICROCODE_INTEL`, `CONFIG_DRM_I915`, `CONFIG_E1000E`, `CONFIG_IWLWIFI`, `CONFIG_BLK_DEV_NVME`, `CONFIG_ATA_AHCI`, `CONFIG_MMC_REALTEK_PCI`.
- [ ] **Ship microcode + linux-firmware in the static base** (x86_64 only): `intel-ucode` loaded via `EFI_EARLY_LOAD_MICROCODE` from a prepended initrd cpio.
- [ ] **Set `manifest.json:archs.x86_64.nix_binary_sha256`** (pin Nix's x86_64-linux tarball). Today's value is empty — `tools/fetch-sources.sh` will refuse to use it until populated.
- [ ] **Implement `images/variants/nuc-installer/package.sh`**: losetup the source x86_64 disk image; squashfs the rootfs; build an ISO tree (`iso-root/live/filesystem.squashfs`, `iso-root/boot/grub/grub.cfg`); `grub-mkrescue -o $OUT iso-root` for a hybrid ISO.
- [ ] **Installer scripts under `images/variants/nuc-installer/installer/`**: a small bash flow that wraps `parted` + `rsync` + `grub-install --target=x86_64-efi` + first-boot hook for user creation. Surfaced via greetd as an `installer` session.
- [ ] **Add `arch: x86_64` to the CI matrix** in `.github/workflows/build.yml` once the runner exists.

### Cross-cutting (both platforms)

- [ ] **Per-arch base image naming**. Today `cache/artifacts/<image>-disk-<ver>.img` is arch-less and `tools/package-platform.sh` refuses any request where `arch != manifest.active_arch` (rc=5). Once we want both `aarch64` and `x86_64` base images on disk at once (e.g. a single CI run packaging both), rename to `<image>-disk-<arch>-<ver>.img` and update the dispatcher + build.sh outputs.
- [ ] **Sha256-verify firmware blobs and microcode** at fetch time (today only the LFS tarballs and the Nix binary are verified).
- [ ] **Define a per-platform smoke test** beyond what CI can do: for `rpi-native`, that's "boots on real Pi"; for `nuc-installer`, that's "live ISO boots in QEMU x86_64 → installer completes → installed system boots". The QEMU test is reachable from CI once the Linux runner exists.

## Phase 4 follow-ups

`gnunix-desktop-<ver>` is scaffolded per ADR-009 — components installed and supervised. The remaining work to make it a credible developer desktop:

- [ ] **xdg-desktop-portal** — screen-sharing, file-pickers, etc. Pick a backend (`xdg-desktop-portal-wlr` is the natural fit for sway). Add to `install-wayland.sh` system-profile install set, drop a `/etc/xdg/xdg-desktop-portal/portals.conf`.
- [ ] **home-manager bootstrap** — per ADR-004, user-visible config lives in home-manager. Add a runbook for `nix run home-manager/master -- init` for the `user` account and a starter `home.nix` pinning sway/foot/hyprland/whatever the user actually picks. Move `images/gnunix-desktop/etc/sway/config` to a home-manager managed file once that's in place.
- [ ] **PAM auth hardening** — current greetd PAM stack uses `pam_permit.so` so the smoke test can log in unattended. For shipping: enforce `pam_unix.so` (with a real password) or `pam_ssh_agent_auth.so` (key-only). Also see "SSH server hardening" above.
- [ ] **Visual smoke test** — `tests/wayland-session.sh` validates components, not frames. A real visual test would: start the VM with `--graphics`, drive tuigreet via expect or simulated keypresses, then `wlr-randr --screenshot` and diff against a golden PNG.
- [ ] **Audio + bluetooth** — pipewire (Nix-installed, user-session-scoped) + bluez. Out of scope for Phase 4 v1; needed before "credible developer desktop".
- [ ] **Pin `nix.nixpkgs_rev_pin` in `tools/manifest.json`** — currently empty; the system profile is built against whatever the `nixos-25.11` channel resolves to at install time. Pinning the rev makes Phase 4 builds bit-reproducible for a given manifest.json.
- [ ] **Variants** — `images/variants/` for alternative compositors (river, niri, Hyprland) once the baseline sway path is stable.

## Installer (ADR-015) follow-ups

The live `gnunix-installer` image and the four-profile picker (minimal / desktop-sway / desktop-hyprland / desktop-labwc) are scaffolded. Build via `tools/build-all.sh gnunix-installer`. CI: `gnunix-installer` + `installer-test` jobs in `.github/workflows/build.yml`.

- [ ] **First real install on a real disk** — produce the `.img.zst`, write to USB, boot on bare metal (the Mac Studio test box or an Intel NUC for x86_64 once that builder exists), step through the TUI, install minimal + desktop-sway end-to-end. Everything to here has been Tart-only.
- [ ] **Network warning on profile-selection** — the desktop-hyprland and desktop-labwc paths pull closures from `cache.nixos.org` at install time; the TUI currently does NOT warn. Add an `if [ "$PROFILE" = desktop-hyprland ] || [ "$PROFILE" = desktop-labwc ]` whiptail --yesno after profile selection that explicitly says "this profile requires internet at install time; continue?".
- [ ] **Pre-flight network check** — before partitioning, if the chosen profile needs network, `curl -fsSI https://cache.nixos.org/ >/dev/null` and bail with a clear error if it fails. Saves the user from finding out after the rootfs is written.
- [ ] **xdg-desktop-portal-* per profile** — the per-profile scripts install the right backend but we haven't validated screen-share or file-pickers actually work on hyprland/labwc. Until they do, those profiles are "supported with caveats".
- [ ] **Reproducible installer image** — currently `gnunix-installer-<ver>.img` is timestamped via the rootfs `/etc/os-release` build-time stamp. For reproducible builds, plumb `SOURCE_DATE_EPOCH` from `tools/manifest.json` through `install-installer.sh`.
- [ ] **Unattended install via kernel cmdline** — same env-var contract that drives `tests/installer/profile-*.sh` (`GNUNIX_INSTALL_UNATTENDED=1` + `GNUNIX_TARGET_DISK=...`) could be lifted to `/proc/cmdline` for fully unattended PXE installs. Probably not v1; tracked for ADR-010 Phase 6 (`rpi-native` factory provisioning).
- [ ] **Boot the installed system in CI (visual)** — `tests/installer/profile-sway.sh` asserts files + groups + binaries are right; it does NOT assert that greetd actually shows a login prompt and accepts the password. That's the visual-smoke gap shared with `tests/wayland-session.sh`.
- [ ] **Qemu fallback for tests** — `scripts/run-installer-test.sh` calls `tart` directly. PR-3b abstracts the VM driver behind `scripts/vm-helpers.sh` so tests can target Tart-on-macOS-arm64 or qemu-on-Linux (hosted runners per ADR-021) from one entry point.
- [ ] **More compositors over time** — once profile-hyprland and profile-labwc bake stable, consider river / niri / Wayfire as additional `desktop-*` profiles. Each is a small `~/.config/<wm>/...` skeleton + a `nix-env -iA` line; the test scaffold extends by appending a `profile-<name>.sh` and a case branch in `validate-installed.sh`.

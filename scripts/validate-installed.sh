#!/bin/sh
# validate-installed.sh <profile> <vm> [user] [hostname]
#
# Boots an already-installed GNUnix VM (output of run-installer-test.sh)
# and asserts that the chosen profile produced the expected on-disk
# state. Same shape as validate-boot.sh / validate-wayland.sh: one
# `sh -c` heredoc with set -e, exit codes are reasons.

set -eu
REPO_ROOT=${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
. "$REPO_ROOT/scripts/tart-helpers.sh"

PROFILE=${1:-}
VM=${2:-}
USER=${3:-tester}
HOSTNAME=${4:-gnunix-${PROFILE}}

[ -z "$PROFILE" ] || [ -z "$VM" ] && {
  echo "usage: $0 <profile> <vm> [user] [hostname]" >&2; exit 2
}

echo "[validate-installed] booting $VM"
tart run --no-graphics "$VM" >/dev/null 2>&1 &
TART_PID=$!
trap 'tart stop "$VM" >/dev/null 2>&1 || true; kill $TART_PID 2>/dev/null || true' EXIT

if ! tart_wait_ssh "$VM" root; then
  echo "FAIL: installed system did not boot to ssh within 120s"
  exit 1
fi

echo "[validate-installed] running universal asserts (profile=$PROFILE user=$USER host=$HOSTNAME)"
# -------- UNIVERSAL: must hold for every profile --------
tart_ssh "$VM" root env \
    EXP_USER="$USER" EXP_HOST="$HOSTNAME" EXP_PROFILE="$PROFILE" \
    sh -c '
  set -e

  # 1. Hostname matches what the installer set.
  got=$(cat /etc/hostname)
  [ "$got" = "$EXP_HOST" ] \
    || { echo "FAIL: hostname is $got, expected $EXP_HOST"; exit 10; }

  # 2. os-release identifies as the chosen profile.
  grep -q "^VARIANT_ID=\"\\?$EXP_PROFILE\"\\?\$" /etc/os-release \
    || { echo "FAIL: /etc/os-release missing VARIANT_ID=$EXP_PROFILE"; exit 11; }
  grep -q "^ID=gnunix" /etc/os-release \
    || { echo "FAIL: /etc/os-release missing ID=gnunix"; exit 11; }

  # 3. User exists with a shell and a hashed password.
  getent passwd "$EXP_USER" >/dev/null \
    || { echo "FAIL: user $EXP_USER not provisioned"; exit 12; }
  pwhash=$(getent shadow "$EXP_USER" | cut -d: -f2)
  case "$pwhash" in
    ""|"!"|"!!"|"*") echo "FAIL: user $EXP_USER has no password set"; exit 13 ;;
  esac
  shell=$(getent passwd "$EXP_USER" | cut -d: -f7)
  [ "$shell" = "/bin/bash" ] \
    || { echo "FAIL: user shell is $shell, expected /bin/bash"; exit 13; }

  # 4. User in `wheel` (sudo policy) and `nixbld` (Nix build).
  groups=$(id -nG "$EXP_USER")
  for g in wheel nixbld; do
    echo "$groups" | tr " " "\n" | grep -qx "$g" \
      || { echo "FAIL: $EXP_USER not in group $g (have: $groups)"; exit 14; }
  done

  # 5. /etc/fstab has root + ESP.
  grep -qE "^[^#].*[[:space:]]/[[:space:]]" /etc/fstab \
    || { echo "FAIL: /etc/fstab missing root mount"; exit 15; }
  grep -qE "^[^#].*[[:space:]]/boot/efi[[:space:]]" /etc/fstab \
    || grep -qE "^[^#].*[[:space:]]/boot[[:space:]]" /etc/fstab \
    || { echo "FAIL: /etc/fstab missing ESP/boot mount"; exit 15; }

  # 6. GRUB EFI binary present, grub.cfg points at a real kernel.
  ls /boot/efi/EFI/BOOT/BOOT*.EFI >/dev/null 2>&1 \
    || ls /boot/EFI/BOOT/BOOT*.EFI >/dev/null 2>&1 \
    || { echo "FAIL: no BOOT*.EFI under /boot/efi/EFI/BOOT or /boot/EFI/BOOT"; exit 16; }
  test -f /boot/grub/grub.cfg \
    || { echo "FAIL: /boot/grub/grub.cfg missing"; exit 17; }
  grep -q "linux .*/boot/vmlinuz" /boot/grub/grub.cfg \
    || { echo "FAIL: grub.cfg has no linux entry pointing at /boot/vmlinuz"; exit 17; }

  # 7. Nix daemon installed and able to answer queries.
  command -v nix >/dev/null \
    || [ -x /nix/var/nix/profiles/default/bin/nix ] \
    || { echo "FAIL: nix not on PATH and not in default profile"; exit 18; }
  pidof nix-daemon >/dev/null \
    || { echo "FAIL: nix-daemon not running"; exit 19; }

  # 8. sshd is up (only way we got here, but assert anyway so the test
  #    fails cleanly if it crashed between login and assertions).
  pidof sshd >/dev/null \
    || { echo "FAIL: sshd not running"; exit 20; }

  echo "[validate-installed] universal asserts PASS"
'

# -------- PROFILE-SPECIFIC --------
case "$PROFILE" in
  minimal)
    echo "[validate-installed] running minimal-specific asserts"
    tart_ssh "$VM" root sh -c '
      set -e
      # greetd should be DISABLED on minimal (no GUI).
      if [ -x /etc/rc.d/rc.greetd ]; then
        echo "FAIL: rc.greetd is executable on minimal profile (should be disabled)"
        exit 30
      fi
      # tty1 getty should be re-enabled in /etc/inittab.
      grep -qE "^[^#].*agetty.*tty1" /etc/inittab \
        || { echo "FAIL: /etc/inittab has no enabled getty on tty1"; exit 31; }
      # No compositor in the system profile.
      SP=/nix/var/nix/profiles/system
      if [ -x "$SP/bin/sway" ] || [ -x "$SP/bin/Hyprland" ] || [ -x "$SP/bin/labwc" ]; then
        echo "FAIL: minimal profile has a compositor binary in the system profile"
        exit 32
      fi
      echo "[validate-installed] minimal PASS"
    '
    ;;
  desktop-sway)
    echo "[validate-installed] running desktop-sway-specific asserts"
    tart_ssh "$VM" root env EXP_USER="$USER" sh -c '
      set -e
      SP=/nix/var/nix/profiles/system
      # greetd ENABLED, agetty on tty1 DISABLED (greetd owns the vt).
      [ -x /etc/rc.d/rc.greetd ] \
        || { echo "FAIL: rc.greetd not enabled"; exit 30; }
      grep -qE "^[^#].*agetty.*tty1" /etc/inittab \
        && { echo "FAIL: tty1 agetty still enabled — conflicts with greetd"; exit 31; }
      # Sway + waybar + foot in the system profile.
      for b in sway waybar foot tuigreet; do
        [ -x "$SP/bin/$b" ] \
          || { echo "FAIL: $SP/bin/$b missing"; exit 32; }
      done
      # start-wayland-session.sh ends with sway exec.
      test -x /usr/local/bin/start-wayland-session.sh \
        || { echo "FAIL: /usr/local/bin/start-wayland-session.sh missing"; exit 33; }
      grep -q "exec .*sway" /usr/local/bin/start-wayland-session.sh \
        || { echo "FAIL: start-wayland-session.sh does not exec sway"; exit 34; }
      # User has the Wayland groups.
      groups=$(id -nG "$EXP_USER")
      for g in video input render seat; do
        echo "$groups" | tr " " "\n" | grep -qx "$g" \
          || { echo "FAIL: $EXP_USER not in $g group (have: $groups)"; exit 35; }
      done
      # User-level sway config seeded.
      test -f "/home/$EXP_USER/.config/sway/config" \
        || { echo "FAIL: /home/$EXP_USER/.config/sway/config missing"; exit 36; }
      echo "[validate-installed] desktop-sway PASS"
    '
    ;;
  desktop-hyprland)
    echo "[validate-installed] running desktop-hyprland-specific asserts"
    tart_ssh "$VM" root env EXP_USER="$USER" sh -c '
      set -e
      SP=/nix/var/nix/profiles/system
      [ -x /etc/rc.d/rc.greetd ] \
        || { echo "FAIL: rc.greetd not enabled"; exit 30; }
      # Hyprland binary present (capital H is the actual binary name).
      [ -x "$SP/bin/Hyprland" ] \
        || { echo "FAIL: $SP/bin/Hyprland missing — nix-env install failed?"; exit 31; }
      # xdg-desktop-portal-hyprland pulled.
      ls "$SP/libexec/" 2>/dev/null | grep -qi hyprland \
        || ls "$SP/bin/" 2>/dev/null | grep -qi hyprland-portal \
        || echo "WARN: xdg-desktop-portal-hyprland not detected"
      # start-wayland-session.sh execs Hyprland.
      grep -q "exec .*Hyprland" /usr/local/bin/start-wayland-session.sh \
        || { echo "FAIL: start-wayland-session.sh does not exec Hyprland"; exit 32; }
      # Hyprland user config seeded.
      test -f "/home/$EXP_USER/.config/hypr/hyprland.conf" \
        || { echo "FAIL: hyprland.conf not seeded"; exit 33; }
      # Wayland groups.
      groups=$(id -nG "$EXP_USER")
      for g in video input render seat; do
        echo "$groups" | tr " " "\n" | grep -qx "$g" \
          || { echo "FAIL: $EXP_USER not in $g group (have: $groups)"; exit 34; }
      done
      echo "[validate-installed] desktop-hyprland PASS"
    '
    ;;
  desktop-labwc)
    echo "[validate-installed] running desktop-labwc-specific asserts"
    tart_ssh "$VM" root env EXP_USER="$USER" sh -c '
      set -e
      SP=/nix/var/nix/profiles/system
      [ -x /etc/rc.d/rc.greetd ] \
        || { echo "FAIL: rc.greetd not enabled"; exit 30; }
      [ -x "$SP/bin/labwc" ] \
        || { echo "FAIL: $SP/bin/labwc missing — nix-env install failed?"; exit 31; }
      grep -q "exec .*labwc" /usr/local/bin/start-wayland-session.sh \
        || { echo "FAIL: start-wayland-session.sh does not exec labwc"; exit 32; }
      test -f "/home/$EXP_USER/.config/labwc/rc.xml" \
        || { echo "FAIL: labwc rc.xml not seeded"; exit 33; }
      test -x "/home/$EXP_USER/.config/labwc/autostart" \
        || { echo "FAIL: labwc autostart missing or not executable"; exit 34; }
      grep -q waybar "/home/$EXP_USER/.config/labwc/autostart" \
        || { echo "FAIL: labwc autostart does not launch waybar"; exit 35; }
      groups=$(id -nG "$EXP_USER")
      for g in video input render seat; do
        echo "$groups" | tr " " "\n" | grep -qx "$g" \
          || { echo "FAIL: $EXP_USER not in $g group (have: $groups)"; exit 36; }
      done
      echo "[validate-installed] desktop-labwc PASS"
    '
    ;;
  desktop-cosmic)
    echo "[validate-installed] running desktop-cosmic-specific asserts (ADR-022)"
    tart_ssh "$VM" root env EXP_USER="$USER" sh -c '
      set -e
      SP=/nix/var/nix/profiles/system
      [ -x /etc/rc.d/rc.greetd ] \
        || { echo "FAIL: rc.greetd not enabled"; exit 30; }
      # COSMIC core: cosmic-comp is the compositor, start-cosmic is the
      # launcher cosmic-session ships in nixpkgs (it execs dbus-run-session
      # + cosmic-session — see ADR-022 § Context).
      [ -x "$SP/bin/cosmic-comp" ] \
        || { echo "FAIL: $SP/bin/cosmic-comp missing — nix-env install failed?"; exit 31; }
      [ -x "$SP/bin/start-cosmic" ] \
        || { echo "FAIL: $SP/bin/start-cosmic missing — cosmic-session install failed?"; exit 32; }
      # Wrapper execs start-cosmic, not cosmic-comp directly.
      grep -q "exec .*start-cosmic" /usr/local/bin/start-wayland-session.sh \
        || { echo "FAIL: start-wayland-session.sh does not exec start-cosmic"; exit 33; }
      # Session file installed where tuigreet picks it up.
      test -f /usr/local/share/wayland-sessions/cosmic.desktop \
        || { echo "FAIL: /usr/local/share/wayland-sessions/cosmic.desktop missing"; exit 34; }
      # xdg-desktop-portal-cosmic pulled (screen-sharing, file-pickers).
      [ -x "$SP/libexec/xdg-desktop-portal-cosmic" ] \
        || [ -x "$SP/bin/xdg-desktop-portal-cosmic" ] \
        || echo "WARN: xdg-desktop-portal-cosmic not detected"
      # Per-user config seeded.
      test -d "/home/$EXP_USER/.config/cosmic" \
        || { echo "FAIL: /home/$EXP_USER/.config/cosmic skeleton not seeded"; exit 35; }
      groups=$(id -nG "$EXP_USER")
      for g in video input render seat; do
        echo "$groups" | tr " " "\n" | grep -qx "$g" \
          || { echo "FAIL: $EXP_USER not in $g group (have: $groups)"; exit 36; }
      done
      # ADR-022 § "Why exclude cosmic-greeter": tuigreet is greeter.
      [ ! -x "$SP/bin/cosmic-greeter" ] \
        || { echo "FAIL: cosmic-greeter installed — ADR-022 keeps tuigreet"; exit 37; }
      echo "[validate-installed] desktop-cosmic PASS"
    '
    ;;
  *)
    echo "FAIL: unknown profile $PROFILE"
    exit 2
    ;;
esac

echo "[validate-installed] PASS ($PROFILE on $VM)"

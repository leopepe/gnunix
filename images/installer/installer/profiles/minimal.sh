#!/bin/bash
# Profile: minimal — CLI base + Nix package manager. No graphical session.
# $1 = username, $2 = password (passed by gnunix-installer after chroot).

set -euo pipefail

USERNAME=$1
PASSWORD=$2

echo "[profile/minimal] creating user $USERNAME"
if ! getent passwd "$USERNAME" >/dev/null; then
  useradd -m -s /bin/bash -G wheel,nixbld "$USERNAME"
fi
echo "$USERNAME:$PASSWORD" | chpasswd

echo "[profile/minimal] disabling graphical greetd session (no compositor)"
chmod -x /etc/rc.d/rc.greetd 2>/dev/null || true

echo "[profile/minimal] enabling agetty on tty1 so there's a login on first boot"
# We disabled tty1 agetty in lfs-wayland's inittab override so greetd could
# own it. For a minimal install with no greetd, we need a real getty.
sed -i 's|^# \(2:.*agetty.*tty1.*\)|\1|' /etc/inittab

echo "[profile/minimal] done"

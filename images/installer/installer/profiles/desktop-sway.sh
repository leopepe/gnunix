#!/bin/bash
# Profile: desktop-sway — what gnunix-desktop already ships. No extra
# packages needed; just create the user with the right groups and let
# greetd → sway take over.

set -euo pipefail

USERNAME=$1
PASSWORD=$2

echo "[profile/desktop-sway] creating user $USERNAME (wheel/video/input/render/audio/seat/nixbld)"
for g in wheel video input render audio seat; do
  getent group "$g" >/dev/null || groupadd -r "$g"
done
if ! getent passwd "$USERNAME" >/dev/null; then
  useradd -m -s /bin/bash -G wheel,video,input,render,audio,seat,nixbld "$USERNAME"
fi
echo "$USERNAME:$PASSWORD" | chpasswd

# greetd's config.toml from the installer points at the legacy "user"
# account. Rewrite it to use the actual chosen username.
SP=/nix/var/nix/profiles/system
if [ -f /etc/greetd/config.toml ]; then
  sed -i "s|--cmd /usr/local/bin/start-wayland-session.sh|--cmd /usr/local/bin/start-wayland-session.sh --user $USERNAME|" \
    /etc/greetd/config.toml 2>/dev/null || true
fi

# Make sure greetd's rc script is enabled
chmod +x /etc/rc.d/rc.greetd 2>/dev/null || true

# Seed a per-user sway config (idempotent — leave it if user already has one)
if [ ! -f "/home/$USERNAME/.config/sway/config" ] && [ -f /etc/sway/config ]; then
  install -d -m 0755 -o "$USERNAME" -g "$USERNAME" "/home/$USERNAME/.config/sway"
  install -m 0644 -o "$USERNAME" -g "$USERNAME" /etc/sway/config "/home/$USERNAME/.config/sway/config"
fi

echo "[profile/desktop-sway] done"

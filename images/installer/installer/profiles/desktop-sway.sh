#!/bin/bash
# Profile: desktop-sway — Wayland tiling, i3-style.
#
# After ADR-019 (installer pivot to gnunix-minimal) and ADR-020 (Sway
# demoted to optional), Sway is no longer pre-installed in the parent.
# This profile pulls it at install time, same shape as
# desktop-hyprland.sh and desktop-labwc.sh.

set -euo pipefail

USERNAME=$1
PASSWORD=$2

SP=/nix/var/nix/profiles/system
export PATH=/nix/var/nix/profiles/default/bin:$PATH
export NIX_SSL_CERT_FILE=/nix/var/nix/profiles/default/etc/ssl/certs/ca-bundle.crt
export HOME=/root

echo "[profile/desktop-sway] creating user $USERNAME (wheel/video/input/render/audio/seat/nixbld)"
for g in wheel video input render audio seat; do
  getent group "$g" >/dev/null || groupadd -r "$g"
done
if ! getent passwd "$USERNAME" >/dev/null; then
  useradd -m -s /bin/bash -G wheel,video,input,render,audio,seat,nixbld "$USERNAME"
fi
echo "$USERNAME:$PASSWORD" | chpasswd

echo "[profile/desktop-sway] starting nix-daemon"
pidof nix-daemon >/dev/null || /etc/rc.d/rc.nix-daemon start
sleep 2

echo "[profile/desktop-sway] installing sway into system profile"
nix-env -p "$SP" -iA nixpkgs.sway nixpkgs.xdg-desktop-portal-wlr nixpkgs.swaybg 2>&1 | tail -5

echo "[profile/desktop-sway] writing /usr/local/bin/start-wayland-session.sh"
cat > /usr/local/bin/start-wayland-session.sh <<'WRAP'
#!/bin/sh
LOGFILE=/var/log/wayland-session.log
exec >>"$LOGFILE" 2>&1
echo "[$(date -Iseconds)] start-wayland-session.sh USER=$(id -un) UID=$(id -u)"
set -x
export XDG_RUNTIME_DIR=/run/user/$(id -u)
mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null || true
chmod 0700 "$XDG_RUNTIME_DIR" 2>/dev/null || true
export PATH="/nix/var/nix/profiles/system/bin:/nix/var/nix/profiles/default/bin:$PATH"
export XKB_DEFAULT_LAYOUT=us
export __EGL_VENDOR_LIBRARY_DIRS=/nix/var/nix/profiles/system/share/glvnd/egl_vendor.d
export LIBGL_DRIVERS_PATH=/nix/var/nix/profiles/system/lib/dri
export LD_LIBRARY_PATH=/nix/var/nix/profiles/system/lib:${LD_LIBRARY_PATH:-}
exec /nix/var/nix/profiles/system/bin/sway
WRAP
chmod 0755 /usr/local/bin/start-wayland-session.sh

echo "[profile/desktop-sway] seeding ~/.config/sway/ skeleton"
install -d -m 0755 -o "$USERNAME" -g "$USERNAME" "/home/$USERNAME/.config/sway"
cat > "/home/$USERNAME/.config/sway/config" <<'EOF'
# Minimal sway config — replace with your own.
set $mod Mod4
set $term /nix/var/nix/profiles/system/bin/foot

bindsym $mod+Return exec $term
bindsym $mod+Shift+q kill
bindsym $mod+Shift+c reload

bindsym $mod+h focus left
bindsym $mod+j focus down
bindsym $mod+k focus up
bindsym $mod+l focus right

bindsym $mod+1 workspace 1
bindsym $mod+2 workspace 2
bindsym $mod+3 workspace 3
bindsym $mod+4 workspace 4
bindsym $mod+5 workspace 5

input "*" {
    xkb_layout us
}

exec /nix/var/nix/profiles/system/bin/waybar
EOF
chown "$USERNAME:$USERNAME" "/home/$USERNAME/.config/sway/config"

chmod +x /etc/rc.d/rc.greetd 2>/dev/null || true
echo "[profile/desktop-sway] done"

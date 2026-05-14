#!/bin/bash
# Profile: desktop-hyprland — Wayland dynamic tiling with animations.
# Like sway but with eye-candy (blur, animations, rounded corners).
#
# Pulls nixpkgs.hyprland into the target's system Nix profile and
# wires up greetd → hyprland.

set -euo pipefail

USERNAME=$1
PASSWORD=$2

SP=/nix/var/nix/profiles/system
export PATH=/nix/var/nix/profiles/default/bin:$PATH
export NIX_SSL_CERT_FILE=/nix/var/nix/profiles/default/etc/ssl/certs/ca-bundle.crt
export HOME=/root

echo "[profile/desktop-hyprland] creating user $USERNAME (wheel/video/input/render/audio/seat/nixbld)"
for g in wheel video input render audio seat; do
  getent group "$g" >/dev/null || groupadd -r "$g"
done
if ! getent passwd "$USERNAME" >/dev/null; then
  useradd -m -s /bin/bash -G wheel,video,input,render,audio,seat,nixbld "$USERNAME"
fi
echo "$USERNAME:$PASSWORD" | chpasswd

echo "[profile/desktop-hyprland] starting nix-daemon (needed for nix-env)"
pidof nix-daemon >/dev/null || /etc/rc.d/rc.nix-daemon start
sleep 2

echo "[profile/desktop-hyprland] installing hyprland into system profile"
nix-env -p "$SP" -iA nixpkgs.hyprland nixpkgs.xdg-desktop-portal-hyprland 2>&1 | tail -5

echo "[profile/desktop-hyprland] writing /usr/local/bin/start-wayland-session.sh"
# Replace the stock sway wrapper with one that launches hyprland.
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
exec /nix/var/nix/profiles/system/bin/Hyprland
WRAP
chmod 0755 /usr/local/bin/start-wayland-session.sh

echo "[profile/desktop-hyprland] seeding ~/.config/hypr/ skeleton"
install -d -m 0755 -o "$USERNAME" -g "$USERNAME" "/home/$USERNAME/.config/hypr"
cat > "/home/$USERNAME/.config/hypr/hyprland.conf" <<'EOF'
# Minimal Hyprland config — replace with your own.
monitor = , preferred, auto, 1
$mod = SUPER
$term = /nix/var/nix/profiles/system/bin/foot

bind = $mod, Return, exec, $term
bind = $mod SHIFT, Q, killactive
bind = $mod SHIFT, C, exec, hyprctl reload
bind = $mod, H, movefocus, l
bind = $mod, J, movefocus, d
bind = $mod, K, movefocus, u
bind = $mod, L, movefocus, r
bind = $mod, 1, workspace, 1
bind = $mod, 2, workspace, 2
bind = $mod, 3, workspace, 3
bind = $mod, 4, workspace, 4
bind = $mod, 5, workspace, 5

input {
    kb_layout = us
}

# Status bar: waybar (shipped already in the desktop layer).
exec-once = pkill -x waybar; waybar
EOF
chown "$USERNAME:$USERNAME" "/home/$USERNAME/.config/hypr/hyprland.conf"

chmod +x /etc/rc.d/rc.greetd 2>/dev/null || true
echo "[profile/desktop-hyprland] done"

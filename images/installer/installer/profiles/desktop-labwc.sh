#!/bin/bash
# Profile: desktop-labwc — Wayland stacking compositor (Openbox-style).
# Closest "traditional desktop" feel on Wayland; the most amenable to
# BeOS-inspired theming via waybar CSS + a custom decoration scheme.

set -euo pipefail

USERNAME=$1
PASSWORD=$2

SP=/nix/var/nix/profiles/system
export PATH=/nix/var/nix/profiles/default/bin:$PATH
export NIX_SSL_CERT_FILE=/nix/var/nix/profiles/default/etc/ssl/certs/ca-bundle.crt
export HOME=/root

echo "[profile/desktop-labwc] creating user $USERNAME (wheel/video/input/render/audio/seat/nixbld)"
for g in wheel video input render audio seat; do
  getent group "$g" >/dev/null || groupadd -r "$g"
done
if ! getent passwd "$USERNAME" >/dev/null; then
  useradd -m -s /bin/bash -G wheel,video,input,render,audio,seat,nixbld "$USERNAME"
fi
echo "$USERNAME:$PASSWORD" | chpasswd

echo "[profile/desktop-labwc] starting nix-daemon"
pidof nix-daemon >/dev/null || /etc/rc.d/rc.nix-daemon start
sleep 2

echo "[profile/desktop-labwc] installing labwc into system profile"
nix-env -p "$SP" -iA nixpkgs.labwc nixpkgs.xdg-desktop-portal-wlr 2>&1 | tail -5

echo "[profile/desktop-labwc] writing /usr/local/bin/start-wayland-session.sh"
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
exec /nix/var/nix/profiles/system/bin/labwc
WRAP
chmod 0755 /usr/local/bin/start-wayland-session.sh

echo "[profile/desktop-labwc] seeding ~/.config/labwc/ skeleton"
install -d -m 0755 -o "$USERNAME" -g "$USERNAME" "/home/$USERNAME/.config/labwc"
cat > "/home/$USERNAME/.config/labwc/rc.xml" <<'EOF'
<?xml version="1.0"?>
<labwc_config>
  <core>
    <decoration>server</decoration>
    <gap>4</gap>
  </core>
  <theme>
    <name>Default</name>
    <font place="ActiveWindow"><name>monospace</name><size>10</size></font>
  </theme>
  <keyboard>
    <default />
    <keybind key="W-Return"><action name="Execute"><command>foot</command></action></keybind>
    <keybind key="W-S-Q"><action name="Close"/></keybind>
    <keybind key="W-S-C"><action name="Reconfigure"/></keybind>
  </keyboard>
  <mouse><default /></mouse>
</labwc_config>
EOF
chown "$USERNAME:$USERNAME" "/home/$USERNAME/.config/labwc/rc.xml"

# A minimal autostart for waybar (labwc reads ~/.config/labwc/autostart).
cat > "/home/$USERNAME/.config/labwc/autostart" <<'EOF'
# labwc autostart — runs after the compositor comes up.
pkill -x waybar; /nix/var/nix/profiles/system/bin/waybar >/tmp/waybar.log 2>&1 &
EOF
chmod +x "/home/$USERNAME/.config/labwc/autostart"
chown "$USERNAME:$USERNAME" "/home/$USERNAME/.config/labwc/autostart"

chmod +x /etc/rc.d/rc.greetd 2>/dev/null || true
echo "[profile/desktop-labwc] done"

#!/bin/bash
# Profile: desktop-labwc-nextspace — Wayland stacking compositor with a
# NeXTSTEP-inspired theme.
#
# Authentic GNUstep/WindowMaker / Nextspace are X11-only and out of
# scope per ADR-009 § Wayland-only and ADR-015 § "Why no X11". This
# profile is the Wayland-native compromise: labwc (Openbox-style
# stacking, closest analogue to WindowMaker on Wayland) with a
# curated theme and waybar styling approximating the NeXTSTEP look —
# dark titlebars, square buttons, monospace title text, light gray
# window background, cyan accents.

set -euo pipefail

USERNAME=$1
PASSWORD=$2

SP=/nix/var/nix/profiles/system
export PATH=/nix/var/nix/profiles/default/bin:$PATH
export NIX_SSL_CERT_FILE=/nix/var/nix/profiles/default/etc/ssl/certs/ca-bundle.crt
export HOME=/root

echo "[profile/desktop-labwc-nextspace] creating user $USERNAME"
for g in wheel video input render audio seat; do
  getent group "$g" >/dev/null || groupadd -r "$g"
done
if ! getent passwd "$USERNAME" >/dev/null; then
  useradd -m -s /bin/bash -G wheel,video,input,render,audio,seat,nixbld "$USERNAME"
fi
echo "$USERNAME:$PASSWORD" | chpasswd

echo "[profile/desktop-labwc-nextspace] starting nix-daemon"
pidof nix-daemon >/dev/null || /etc/rc.d/rc.nix-daemon start
sleep 2

echo "[profile/desktop-labwc-nextspace] installing labwc + theme deps into system profile"
# Same closure as plain desktop-labwc; the difference is config + theme
# files we drop into the user's home below.
nix-env -p "$SP" -iA \
  nixpkgs.labwc \
  nixpkgs.xdg-desktop-portal-wlr \
  nixpkgs.dejavu_fonts \
  2>&1 | tail -5

echo "[profile/desktop-labwc-nextspace] writing /usr/local/bin/start-wayland-session.sh"
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

USER_HOME="/home/$USERNAME"

echo "[profile/desktop-labwc-nextspace] seeding NeXTSTEP-inspired theme"
install -d -m 0755 -o "$USERNAME" -g "$USERNAME" "$USER_HOME/.config/labwc"
install -d -m 0755 -o "$USERNAME" -g "$USERNAME" "$USER_HOME/.themes/NeXTSpace/openbox-3"
install -d -m 0755 -o "$USERNAME" -g "$USERNAME" "$USER_HOME/.config/waybar"

# labwc rc.xml — references the theme by name; minimal keybinds matching
# WindowMaker conventions where they don't clash with labwc's defaults.
cat > "$USER_HOME/.config/labwc/rc.xml" <<'EOF'
<?xml version="1.0"?>
<labwc_config>
  <core>
    <decoration>server</decoration>
    <gap>2</gap>
    <reconfigureOnConfigChange>yes</reconfigureOnConfigChange>
  </core>
  <theme>
    <name>NeXTSpace</name>
    <cornerRadius>0</cornerRadius>
    <font place="ActiveWindow"><name>DejaVu Sans</name><size>10</size><weight>bold</weight></font>
    <font place="InactiveWindow"><name>DejaVu Sans</name><size>10</size></font>
    <font place="MenuItem"><name>DejaVu Sans</name><size>10</size></font>
  </theme>
  <keyboard>
    <default />
    <keybind key="W-Return"><action name="Execute"><command>foot</command></action></keybind>
    <keybind key="W-S-Q"><action name="Close"/></keybind>
    <keybind key="W-S-C"><action name="Reconfigure"/></keybind>
    <keybind key="W-Tab"><action name="NextWindow"/></keybind>
  </keyboard>
  <mouse><default /></mouse>
</labwc_config>
EOF

# Openbox-compatible themerc — NeXTSTEP grays + Cyan accents.
# Color palette:
#   Dark titlebar:   #2b2b2b   (NeXT classic)
#   Light gray bg:   #d6d6d6
#   Border/shadow:   #1a1a1a
#   Cyan accent:     #4d7da8   (close to NeXT's "blue")
#   White text:      #f0f0f0
cat > "$USER_HOME/.themes/NeXTSpace/openbox-3/themerc" <<'EOF'
# NeXTSpace — a NeXTSTEP-inspired theme for labwc / Openbox.
# Wayland-native; no X11 anywhere.

# Border
border.width: 1
border.color: #1a1a1a

# Padding inside titlebar
padding.width: 4
padding.height: 4

# Window title
window.active.title.bg: flat solid
window.active.title.bg.color: #2b2b2b
window.active.label.text.font: shadow=n
window.active.label.text.color: #f0f0f0
window.active.title.separator.color: #1a1a1a

window.inactive.title.bg: flat solid
window.inactive.title.bg.color: #555555
window.inactive.label.text.color: #c0c0c0

# Buttons — square, raised
window.active.button.unpressed.bg: flat solid
window.active.button.unpressed.bg.color: #d6d6d6
window.active.button.unpressed.image.color: #1a1a1a
window.active.button.pressed.bg.color: #4d7da8
window.active.button.pressed.image.color: #f0f0f0
window.active.button.hover.bg.color: #c0c0c0
window.active.button.hover.image.color: #1a1a1a
window.inactive.button.unpressed.bg.color: #888888
window.inactive.button.unpressed.image.color: #555555

# Window handle (resize grip at the bottom)
window.active.handle.bg: flat solid
window.active.handle.bg.color: #2b2b2b
window.inactive.handle.bg.color: #555555

# Menu (the root menu / window menu)
menu.items.bg: flat solid
menu.items.bg.color: #d6d6d6
menu.items.text.color: #1a1a1a
menu.items.active.bg: flat solid
menu.items.active.bg.color: #4d7da8
menu.items.active.text.color: #f0f0f0
menu.border.color: #1a1a1a
menu.border.width: 1

menu.title.bg: flat solid
menu.title.bg.color: #2b2b2b
menu.title.text.color: #f0f0f0

# Window list (workspace switcher overlay)
osd.bg: flat solid
osd.bg.color: #2b2b2b
osd.border.color: #1a1a1a
osd.label.text.color: #f0f0f0
EOF

# waybar config — same modules as plain desktop-labwc, NeXT-themed CSS.
cat > "$USER_HOME/.config/waybar/config" <<'EOF'
{
  "layer": "top",
  "position": "top",
  "height": 22,
  "modules-left":   ["clock"],
  "modules-center": ["wlr/taskbar"],
  "modules-right":  ["cpu", "memory", "tray"],
  "clock": { "format": "{:%a %b %d   %H:%M}", "interval": 1 },
  "cpu":   { "format": "CPU {usage:>3}%", "interval": 5 },
  "memory":{ "format": "MEM {used:0.1f}G", "interval": 5 },
  "wlr/taskbar": { "format": "{title}" }
}
EOF

cat > "$USER_HOME/.config/waybar/style.css" <<'EOF'
/* NeXTSpace waybar — black bar, DejaVu Sans, square corners. */
* {
    font-family: "DejaVu Sans Mono", monospace;
    font-size: 11px;
    border-radius: 0;
}
window#waybar {
    background: #2b2b2b;
    color: #f0f0f0;
    border-bottom: 1px solid #1a1a1a;
}
#clock, #cpu, #memory, #tray, #taskbar {
    padding: 0 8px;
}
#clock {
    color: #f0f0f0;
    font-weight: bold;
}
#taskbar button {
    background: transparent;
    color: #c0c0c0;
    padding: 0 6px;
    border: none;
}
#taskbar button.active {
    background: #4d7da8;
    color: #f0f0f0;
}
EOF

# autostart — labwc reads ~/.config/labwc/autostart on session start.
cat > "$USER_HOME/.config/labwc/autostart" <<'EOF'
# NeXTSpace autostart.
pkill -x waybar; /nix/var/nix/profiles/system/bin/waybar >/tmp/waybar.log 2>&1 &
EOF
chmod +x "$USER_HOME/.config/labwc/autostart"

# Fix ownership of every seeded file/dir.
chown -R "$USERNAME:$USERNAME" \
  "$USER_HOME/.config/labwc" \
  "$USER_HOME/.config/waybar" \
  "$USER_HOME/.themes"

chmod +x /etc/rc.d/rc.greetd 2>/dev/null || true
echo "[profile/desktop-labwc-nextspace] done"

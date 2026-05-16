#!/bin/bash
# Profile: desktop-cosmic — System76 COSMIC desktop environment.
#
# COSMIC is a full Wayland DE (cosmic-comp compositor + cosmic-session
# session manager + cosmic-panel + cosmic-settings + the COSMIC apps).
# Architecturally it fits GNUnix because cosmic-session uses
# `dbus-run-session` to bring up its own D-Bus user bus rather than
# delegating to `systemd --user` — meaning it works on our sysvinit +
# elogind substrate without porting work. See ADR-022 for the full
# rationale and the verification against the nixos-25.11 channel.
#
# Greeter stays greetd + tuigreet per ADR-009 (cosmic-greeter is
# explicitly NOT installed here).

set -euo pipefail

USERNAME=$1
PASSWORD=$2

SP=/nix/var/nix/profiles/system
export PATH=/nix/var/nix/profiles/default/bin:$PATH
export NIX_SSL_CERT_FILE=/nix/var/nix/profiles/default/etc/ssl/certs/ca-bundle.crt
export HOME=/root

echo "[profile/desktop-cosmic] creating user $USERNAME (wheel/video/input/render/audio/seat/nixbld)"
for g in wheel video input render audio seat; do
  getent group "$g" >/dev/null || groupadd -r "$g"
done
if ! getent passwd "$USERNAME" >/dev/null; then
  useradd -m -s /bin/bash -G wheel,video,input,render,audio,seat,nixbld "$USERNAME"
fi
echo "$USERNAME:$PASSWORD" | chpasswd

echo "[profile/desktop-cosmic] starting nix-daemon (needed for nix-env)"
pidof nix-daemon >/dev/null || /etc/rc.d/rc.nix-daemon start
sleep 2

echo "[profile/desktop-cosmic] installing COSMIC closure into system profile"
# Full COSMIC DE stack per ADR-022 § Bundle. Inlined here rather than
# pulled from bundles/ because no other image consumes COSMIC today
# (CLAUDE.md § "Reusable Nix bundles (consumed by ≥2 images)").
nix-env -p "$SP" -iA \
  nixpkgs.cosmic-comp \
  nixpkgs.cosmic-session \
  nixpkgs.cosmic-settings \
  nixpkgs.cosmic-settings-daemon \
  nixpkgs.cosmic-panel \
  nixpkgs.cosmic-launcher \
  nixpkgs.cosmic-applets \
  nixpkgs.cosmic-bg \
  nixpkgs.cosmic-osd \
  nixpkgs.cosmic-workspaces-epoch \
  nixpkgs.cosmic-randr \
  nixpkgs.cosmic-icons \
  nixpkgs.cosmic-term \
  nixpkgs.cosmic-files \
  nixpkgs.cosmic-edit \
  nixpkgs.xdg-desktop-portal-cosmic \
  2>&1 | tail -5

echo "[profile/desktop-cosmic] installing wayland-sessions/cosmic.desktop"
# tuigreet (per ADR-009) reads /usr/local/share/wayland-sessions/*.desktop
# for the session list. cosmic-session ships its own .desktop file in
# the nixpkgs output; copy it to the standard search path so tuigreet
# picks "cosmic" as a session.
install -d -m 0755 /usr/local/share/wayland-sessions
COSMIC_DESKTOP=$(find "$SP/share/wayland-sessions/" -name 'cosmic*.desktop' 2>/dev/null | head -1)
if [ -n "$COSMIC_DESKTOP" ]; then
  install -m 0644 "$COSMIC_DESKTOP" /usr/local/share/wayland-sessions/cosmic.desktop
else
  echo "[profile/desktop-cosmic] WARN: cosmic.desktop not found in system profile; writing fallback"
  cat > /usr/local/share/wayland-sessions/cosmic.desktop <<EOF
[Desktop Entry]
Name=COSMIC
Comment=System76 COSMIC desktop
Exec=$SP/bin/start-cosmic
Type=Application
EOF
fi

echo "[profile/desktop-cosmic] writing /usr/local/bin/start-wayland-session.sh"
# COSMIC's launcher is start-cosmic, which internally does
# `dbus-run-session cosmic-session`. The wrapper sets up XDG_RUNTIME_DIR
# and the same library/EGL paths the other compositor profiles use.
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
# COSMIC needs Wayland for cosmic-comp (no XWayland in our base).
export XDG_SESSION_TYPE=wayland
exec /nix/var/nix/profiles/system/bin/start-cosmic
WRAP
chmod 0755 /usr/local/bin/start-wayland-session.sh

echo "[profile/desktop-cosmic] seeding ~/.config/cosmic/ skeleton"
# COSMIC reads per-user config from ~/.config/cosmic/<component>/v1.
# The defaults are sensible; we only override what's needed to survive
# virtio-gpu / typical first-boot quirks (output scaling at 1.0 even
# if the EDID lies). Per ADR-022 § Open questions #2 a more elaborate
# starter is a follow-up.
install -d -m 0755 -o "$USERNAME" -g "$USERNAME" \
  "/home/$USERNAME/.config/cosmic/com.system76.CosmicComp/v1"
cat > "/home/$USERNAME/.config/cosmic/com.system76.CosmicComp/v1/output_scale" <<'EOF'
1.0
EOF
chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/.config/cosmic"

chmod +x /etc/rc.d/rc.greetd 2>/dev/null || true
echo "[profile/desktop-cosmic] done"

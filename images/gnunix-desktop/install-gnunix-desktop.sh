#!/bin/bash
# images/gnunix-desktop/install-gnunix-desktop.sh — runs INSIDE the gnunix-desktop-build
# VM as root (called by images/gnunix-desktop/build.sh).
#
# Phase 4 (ADR-009 amended by ADR-020): pulls dbus, elogind, greetd,
# Hyprland, and a small set of compositor utilities from nixpkgs into
# the system profile, sets up the rc.d wiring to supervise them under
# sysvinit (ADR-001), and creates an unprivileged login user.
#
# Idempotent: re-running on an already-installed system updates packages
# (nix-env handles dedupe), rewrites configs, recreates users only if missing.

set -euo pipefail

CHANNEL=${NIXPKGS_CHANNEL:-nixos-25.11}
PAYLOAD_DIR=${PAYLOAD_DIR:-/root/wayland-payload}
SYSTEM_PROFILE=/nix/var/nix/profiles/system
LOGIN_USER=${LOGIN_USER:-user}
LOGIN_UID=1000

[ -d "$PAYLOAD_DIR/etc" ] || { echo "[install-wayland] payload etc/ missing at $PAYLOAD_DIR" >&2; exit 1; }

# 0. Make the Nix tools available to root in this non-login shell.
export PATH="/nix/var/nix/profiles/default/bin:$PATH"
export NIX_SSL_CERT_FILE=${NIX_SSL_CERT_FILE:-/nix/var/nix/profiles/default/etc/ssl/certs/ca-bundle.crt}
export HOME=/root
export USER=root

# Ensure nix-daemon is running. install-gnunix-minimal.sh deliberately doesn't start it
# (rc.M does, on the next boot). Phase 4 lands on an image that has already
# rebooted at least once via the test step, so the daemon should be up.
# Belt-and-braces: if it's missing, start it now in the background.
if ! pidof nix-daemon >/dev/null; then
  echo "[install-wayland] starting nix-daemon (rc script will own it after reboot)"
  /etc/rc.d/rc.nix-daemon start || true
  sleep 2
fi

# 1. Subscribe to a pinned nixpkgs channel.
echo "[install-wayland] configuring nixpkgs channel: $CHANNEL"
nix-channel --add "https://nixos.org/channels/$CHANNEL" nixpkgs
nix-channel --update

# 2. Install system-level packages into the system profile.
#    The system profile is treated as essentially-static per ADR-009: changed
#    only by deliberate Phase 4 rebuilds, never by interactive nix-env on the
#    running system. rc.d scripts reference $SYSTEM_PROFILE/bin/... explicitly.
echo "[install-wayland] installing system packages → $SYSTEM_PROFILE"
mkdir -p "$(dirname "$SYSTEM_PROFILE")"
nix-env -p "$SYSTEM_PROFILE" -iA \
  nixpkgs.dbus \
  nixpkgs.elogind \
  nixpkgs.greetd \
  nixpkgs.tuigreet \
  nixpkgs.hyprland \
  nixpkgs.xdg-desktop-portal-hyprland \
  nixpkgs.hyprpaper \
  nixpkgs.foot \
  nixpkgs.wayland-utils \
  nixpkgs.xkeyboard_config \
  nixpkgs.procps \
  nixpkgs.kmod \
  nixpkgs.mesa \
  nixpkgs.waybar

# 2a. Wire kmod into /sbin so the kernel's hardcoded modprobe path
#     (/proc/sys/kernel/modprobe = /sbin/modprobe) finds it, and so
#     /etc/rc.d/rc.modules can load the explicit lists below.
#
#     The base eudev was built without the `kmod` builtin (verified at
#     runtime: `udevadm test-builtin kmod` returns "unknown command 'kmod'").
#     That means MODALIAS coldplug never autoloads anything from sysfs —
#     ADR-012's "auto-loaded by eudev MODALIAS coldplug" is effectively
#     dead until eudev is rebuilt with --enable-kmod. Until then, we
#     fall back to the explicit modules-load.d list + rc.modules + a
#     working /sbin/modprobe.
install -d -m 0755 /sbin
for tool in modprobe insmod rmmod lsmod depmod kmod; do
  if [ -x "$SYSTEM_PROFILE/bin/$tool" ]; then
    ln -sfn "$SYSTEM_PROFILE/bin/$tool" "/sbin/$tool"
  fi
done

# 2b. Drop the explicit module list for virtio-* devices. rc.S calls
#     rc.modules which iterates over /etc/modules-load.d/*.conf. virtio-gpu
#     is the critical one — without it /dev/dri/card0 doesn't exist and
#     every Wayland compositor refuses to start.
install -d -m 0755 /etc/modules-load.d
cat > /etc/modules-load.d/virtio.conf <<'EOF'
# Virtualization drivers. The base eudev doesn't autoload from MODALIAS;
# list them here so rc.modules loads them at every boot.
#
# Most important for the Wayland session: virtio-gpu — without it,
# /dev/dri/card0 is missing and Hyprland / Sway / labwc all bail at
# the wlroots DRM backend init.
virtio-gpu
virtio_pci
virtio_blk
virtio_net
virtio_console
EOF

# Convenience symlinks so rc.M's PATH search still resolves dbus-uuidgen etc.
# (rc.dbus calls dbus-uuidgen by basename for the first-boot machine-id step.)
install -d -m 0755 /usr/local/bin
for tool in dbus-daemon dbus-uuidgen dbus-send loginctl; do
  if [ -x "$SYSTEM_PROFILE/bin/$tool" ]; then
    ln -sfn "$SYSTEM_PROFILE/bin/$tool" "/usr/local/bin/$tool"
  fi
done

# 3. Create the messagebus user/group expected by dbus (if Phase 2 didn't).
#    Phase 2's chroot-inner.sh already adds 'messagebus:x:18:18:...' to passwd,
#    so this is usually a no-op; covers the case where someone repaved /etc.
if ! getent group messagebus >/dev/null; then
  groupadd -r -g 18 messagebus
fi
if ! getent passwd messagebus >/dev/null; then
  useradd -r -M -N -g 18 -u 18 -d /run/dbus -s /usr/bin/false messagebus
fi

# 3b. Create the 'greeter' user that greetd runs the greeter session as.
#     greetd's config.toml has 'user = "greeter"'; without this user it
#     refuses to start. No home, no login shell.
if ! getent group greeter >/dev/null; then
  groupadd -r greeter
fi
if ! getent passwd greeter >/dev/null; then
  useradd -r -M -N -g greeter -d /var/empty -s /usr/bin/false \
    -G video,input greeter
fi

# 4. Create the unprivileged login user.
echo "[install-wayland] creating $LOGIN_USER (uid $LOGIN_UID)"
for g in wheel video input render audio seat; do
  getent group "$g" >/dev/null || groupadd -r "$g"
done
if ! getent passwd "$LOGIN_USER" >/dev/null; then
  useradd -m -u "$LOGIN_UID" -s /bin/bash \
    -G wheel,video,input,render,audio,seat,nixbld \
    "$LOGIN_USER"
  # Locked password — login is via greetd's PAM stack (no password by default;
  # operator can set one with `passwd $LOGIN_USER` after first boot, or replace
  # the PAM stack with key auth — see docs/runbooks/build-wayland.md).
  passwd -d "$LOGIN_USER"
fi
install -d -m 0755 -o "$LOGIN_USER" -g "$LOGIN_USER" "/home/$LOGIN_USER/.config/hypr"

# 5. Install configs from the payload.
echo "[install-wayland] installing /etc configs"
install -d -m 0755 /etc/dbus-1/system.d
install -d -m 0755 /etc/elogind
install -d -m 0755 /etc/greetd
install -d -m 0755 /etc/hypr
install -d -m 0755 /etc/pam.d
install -d -m 0755 /etc/rc.d

install -m 0644 "$PAYLOAD_DIR/etc/greetd/config.toml"     /etc/greetd/config.toml
install -m 0644 "$PAYLOAD_DIR/etc/hypr/hyprland.conf"     /etc/hypr/hyprland.conf
install -m 0644 "$PAYLOAD_DIR/etc/pam.d/greetd"           /etc/pam.d/greetd
install -d -m 0755                                         /etc/xdg/waybar
install -m 0644 "$PAYLOAD_DIR/etc/xdg/waybar/config"      /etc/xdg/waybar/config
install -m 0644 "$PAYLOAD_DIR/etc/xdg/waybar/style.css"   /etc/xdg/waybar/style.css

# 5a. Set the image hostname. gnunix-base's chroot-inner.sh writes "gnunix-base" to
#     /etc/hostname; carrying that forward into gnunix-desktop is misleading
#     (`uname -n` reports gnunix-base on what's clearly a different image). Each
#     image overrides on its way through.
echo "gnunix-desktop" > /etc/hostname
hostname gnunix-desktop 2>/dev/null || true

# 5a-0. Stop agetty from fighting greetd for tty1. gnunix-base's /etc/inittab
#       runs `agetty --noclear tty1` (respawn), and greetd is configured to
#       claim vt=1. Whichever opens /dev/tty1 first wins; if agetty wins,
#       greetd dies and inittab respawns agetty, leaving the user at a plain
#       login(1) prompt that doesn't go through pam_elogind — so /run/user/1000
#       is never created and Hyprland can't claim a seat.
#
#       Comment out the tty1 line (keep hvc0 so `tart run --no-graphics`
#       still gives a serial console). Users who lose Hyprland can still
#       Ctrl-Alt-F<n> elsewhere if we ever add fallbacks later.
sed -i 's|^\(2:.*agetty.*tty1.*\)$|# \1   # disabled by gnunix-desktop (greetd owns tty1)|' /etc/inittab
# Tell init to reload its config without a reboot — telinit q rescans inittab.
telinit q 2>/dev/null || true

# 5a-2. Generate /etc/machine-id. GLib (waybar's GUI library) and other
#       dbus-aware components look for /etc/machine-id at startup; if it's
#       absent they error with "Cannot spawn a message bus without a
#       machine-id" and refuse to initialize. dbus-uuidgen creates
#       /var/lib/dbus/machine-id; mirror it at /etc/machine-id.
if [ -x "$SYSTEM_PROFILE/bin/dbus-uuidgen" ]; then
  # Ensure parent dir exists — fresh images don't have /var/lib/dbus/
  # because Phase 2's stages never wrote into it; dbus-uuidgen errors out
  # with "Could not create /var/lib/dbus/machine-id.XXXXXX: No such file"
  # if we skip this.
  install -d -m 0755 /var/lib/dbus
  "$SYSTEM_PROFILE/bin/dbus-uuidgen" --ensure=/var/lib/dbus/machine-id
  # /etc/machine-id is the systemd-era canonical path; symlink to the dbus
  # location so they stay in sync.
  ln -sfn /var/lib/dbus/machine-id /etc/machine-id
fi

# 5a-1. Ship /etc/nsswitch.conf. Phase 2 didn't write one — `getent` works
#       because glibc has a built-in default for missing nsswitch.conf, but
#       stricter NSS consumers (greetd's Rust getpwnam, polkit, etc.) fail
#       with "unable to get user info" when the file is absent. The "files"
#       backend everywhere is the right default for a static base; DNS for
#       hosts is the only network lookup we need.
cat > /etc/nsswitch.conf <<'NSEOF'
# /etc/nsswitch.conf — Name Service Switch.
# Static base lookups go to /etc/* files; only host resolution uses DNS.
passwd:     files
group:      files
shadow:     files
hosts:      files dns
networks:   files
protocols:  files
services:   files
ethers:     files
rpc:        files
netgroup:   files
NSEOF
chmod 0644 /etc/nsswitch.conf

# 5b. Ship /etc/dbus-1/{system,session}.conf as patched copies of the nixpkgs
#     configs. Two rewrites are needed:
#       (a) STRIP the self-include line that nixpkgs adds for legacy local
#           overrides — it references the file itself and produces
#           "Circular inclusion of file /etc/dbus-1/<bus>.conf" once we
#           install the copy at the legacy path.
#       (b) REWRITE the relative <includedir>system.d</includedir> /
#           <includedir>session.d</includedir> to absolute paths into the
#           nixpkgs share dir. Relative includedir resolves against the
#           config's own directory; when the file lives at /etc/dbus-1/,
#           "system.d" → /etc/dbus-1/system.d (empty), which loses elogind's
#           org.freedesktop.login1 policy file and prevents elogind from
#           claiming the bus name (it exits silently right after "New seat seat0").
SP_SHARE="$SYSTEM_PROFILE/share/dbus-1"
sed -E "
  s|<include[^>]*>/etc/dbus-1/system\\.conf</include>||
  s|<includedir>system\\.d</includedir>|<includedir>${SP_SHARE}/system.d</includedir>|
" "$SP_SHARE/system.conf" > /etc/dbus-1/system.conf
sed -E "
  s|<include[^>]*>/etc/dbus-1/session\\.conf</include>||
  s|<includedir>session\\.d</includedir>|<includedir>${SP_SHARE}/session.d</includedir>|
" "$SP_SHARE/session.conf" > /etc/dbus-1/session.conf
chmod 0644 /etc/dbus-1/system.conf /etc/dbus-1/session.conf

# Clear any stale greetd log from earlier failed boots — the message
# "configured default session user 'greeter' not found" persists across
# clones and is misleading once the user has been created.
: > /var/log/greetd.log 2>/dev/null || true

# 6. Overlay the Phase 4 rc.d scripts (rc.dbus, rc.elogind, rc.greetd, rc.M).
#    rc.dbus and rc.elogind from Phase 2 referenced /usr/bin/dbus-daemon and
#    /usr/lib/elogind/elogind respectively — paths that don't exist because
#    Phase 2 never built those packages. The Phase 4 versions point at
#    $SYSTEM_PROFILE/bin/... .
for rc in rc.dbus rc.elogind rc.greetd rc.M; do
  install -m 0755 "$PAYLOAD_DIR/etc/rc.d/$rc" "/etc/rc.d/$rc"
done

# 7. Drop a default per-user Hyprland config so the user has a working keybind set.
if [ ! -f "/home/$LOGIN_USER/.config/hypr/hyprland.conf" ]; then
  install -m 0644 -o "$LOGIN_USER" -g "$LOGIN_USER" \
    "$PAYLOAD_DIR/etc/hypr/hyprland.conf" "/home/$LOGIN_USER/.config/hypr/hyprland.conf"
fi

# 8. Provide a wrapper that greetd can exec to start the Wayland session with
#    the right env (XDG_RUNTIME_DIR, dbus socket discovery, etc.). Keeps
#    greetd's config.toml command line short.
#
#    The wrapper redirects all output to /var/log/wayland-session.log so
#    failures during Hyprland startup are recoverable via SSH (otherwise
#    Hyprland's stderr only goes to greetd's controlling pty and is lost
#    when greetd respawns tuigreet).
cat > /usr/local/bin/start-wayland-session.sh <<EOF
#!/bin/sh
# Launches Hyprland as the logged-in user. Invoked by greetd.
# All output captured to /var/log/wayland-session.log (world-readable so
# the operator can tail it via SSH without sudo).

LOGFILE=/var/log/wayland-session.log
exec >>"\$LOGFILE" 2>&1

echo "============================================="
echo "[\$(date -Iseconds)] start-wayland-session.sh PID=\$\$ USER=\$(id -un) UID=\$(id -u)"
set -x

export XDG_RUNTIME_DIR=/run/user/\$(id -u)
# pam_elogind created XDG_RUNTIME_DIR for us; the mkdir/chmod are defensive
# (no-ops if pam_elogind ran) and harmless if it didn't.
mkdir -p "\$XDG_RUNTIME_DIR" 2>/dev/null || true
chmod 0700 "\$XDG_RUNTIME_DIR" 2>/dev/null || true
ls -la "\$XDG_RUNTIME_DIR" || true

export PATH="$SYSTEM_PROFILE/bin:/nix/var/nix/profiles/default/bin:\$PATH"
export XKB_DEFAULT_LAYOUT=us

# Mesa ICD discovery for libEGL/libGLES2 via GLVND. nixpkgs ships the
# Mesa ICD descriptor at \$SYSTEM_PROFILE/share/glvnd/egl_vendor.d/50_mesa.json
# and the EGL/GLES libs under \$SYSTEM_PROFILE/lib/. Point GLVND and the
# dynamic linker at them so wlroots's EGL backend can find a vendor driver.
export __EGL_VENDOR_LIBRARY_DIRS="$SYSTEM_PROFILE/share/glvnd/egl_vendor.d"
export LIBGL_DRIVERS_PATH="$SYSTEM_PROFILE/lib/dri"
export LD_LIBRARY_PATH="$SYSTEM_PROFILE/lib:\${LD_LIBRARY_PATH:-}"

# Fallback: if EGL still fails, set WLR_RENDERER=pixman as an env override
# at login time. The default path tries hardware acceleration first.

# Show what elogind sees for this session
$SYSTEM_PROFILE/bin/loginctl 2>&1 | head -10 || true

# Hyprland on virtio-gpu (Tart/qemu) needs the WLR cursor workaround.
# Real hardware ignores this; only the virtio-gpu cursor path requires it.
export WLR_NO_HARDWARE_CURSORS=1

exec $SYSTEM_PROFILE/bin/Hyprland
EOF
chmod 0755 /usr/local/bin/start-wayland-session.sh
# Make the log world-readable + pre-create it with permissive perms so the
# unprivileged user can write to it on session start.
touch /var/log/wayland-session.log
chmod 0666 /var/log/wayland-session.log

# 9. PAM stack for greetd references pam_elogind.so. The .so is under
#    \$SYSTEM_PROFILE/lib/security/; symlink into /lib/security/ so the
#    PAM config can use the bare name pam_elogind.so portably.
install -d -m 0755 /lib/security
if [ -f "$SYSTEM_PROFILE/lib/security/pam_elogind.so" ]; then
  ln -sfn "$SYSTEM_PROFILE/lib/security/pam_elogind.so" /lib/security/pam_elogind.so
fi

# 9b. Install elogind's udev rules into /etc/udev/rules.d/.
#     elogind ships 71-seat.rules (tags input/sound/graphics/DRM devices with
#     `seat` + `master-of-seat`), 70-uaccess.rules (uaccess tag for active
#     sessions), and 73-seat-late.rules (final per-seat tagging pass) under
#     its OWN nixpkgs store dir. eudev only reads /lib/udev/rules.d/ and
#     /etc/udev/rules.d/, so without copying these in, `loginctl seat-status
#     seat0` lists Devices: n/a — and Hyprland's libseat→logind backend gets
#     "Could not take device: No such device" when trying to claim /dev/dri/card0.
install -d -m 0755 /etc/udev/rules.d
for r in "$SYSTEM_PROFILE"/lib/udev/rules.d/7?-*.rules; do
  [ -f "$r" ] && install -m 0644 "$r" "/etc/udev/rules.d/$(basename "$r")"
done

# 10. Re-enable the rc scripts that Phase 2 deferred + the new greetd one.
chmod +x /etc/rc.d/rc.dbus /etc/rc.d/rc.elogind /etc/rc.d/rc.greetd /etc/rc.d/rc.M

# 11. Verify (best-effort; daemons are NOT started here — rc.M handles that on
#     next boot, same rationale as install-gnunix-minimal.sh).
echo "[install-wayland] sanity checks"
# elogind on nixpkgs lives at libexec/elogind (a single file, not a subdir);
# bin/ holds elogind-inhibit but not the daemon. Older builds shipped it under
# bin/elogind — keep that as a fallback in case the layout shifts again.
elogind_bin="$SYSTEM_PROFILE/libexec/elogind"
[ -x "$elogind_bin" ] || elogind_bin="$SYSTEM_PROFILE/bin/elogind"
[ -x "$elogind_bin" ] || { echo "[install-wayland] FAIL: elogind binary not found under $SYSTEM_PROFILE"; exit 1; }
for bin in \
  "$SYSTEM_PROFILE/bin/dbus-daemon" \
  "$SYSTEM_PROFILE/bin/greetd" \
  "$SYSTEM_PROFILE/bin/tuigreet" \
  "$SYSTEM_PROFILE/bin/Hyprland"
do
  [ -x "$bin" ] || { echo "[install-wayland] FAIL: missing $bin"; exit 1; }
done
echo "[install-wayland] DONE — reboot to bring dbus/elogind/greetd up via rc.M"

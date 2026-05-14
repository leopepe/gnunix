#!/bin/bash
# images/installer/install-installer.sh — runs INSIDE the
# gnunix-installer-build VM (called by images/installer/build.sh).
#
# Takes the existing gnunix-desktop rootfs and converts it into a
# bootable LIVE image with a TUI installer behind the greetd prompt.
# Per ADR-015.

set -euo pipefail

PAYLOAD_DIR=${PAYLOAD_DIR:-/root/installer-payload}
SP=/nix/var/nix/profiles/system
INSTALL_SHARE=/usr/local/share/gnunix-installer
INSTALL_BIN=/usr/local/sbin/gnunix-installer

[ -d "$PAYLOAD_DIR/installer" ] || { echo "[install-installer] payload missing at $PAYLOAD_DIR" >&2; exit 1; }

# 1. Stage the TUI + profile scripts. (Wayland-only — no theme assets;
#    see ADR-015 § "Why no X11".)
echo "[install-installer] staging installer payload under $INSTALL_SHARE"
install -d -m 0755 "$INSTALL_SHARE"
cp -a "$PAYLOAD_DIR/installer/profiles" "$INSTALL_SHARE/profiles"
install -m 0755 "$PAYLOAD_DIR/installer/gnunix-installer" "$INSTALL_BIN"

# 2. Pull whiptail into the system profile so the TUI can run.
#    whiptail comes from the `newt` package in nixpkgs.
echo "[install-installer] installing whiptail (newt) into system profile"
export PATH=/nix/var/nix/profiles/default/bin:$PATH
export HOME=/root
nix-env -p "$SP" -iA nixpkgs.newt 2>&1 | tail -5 || true

# 3. Stage tools the partitioner needs that aren't in our LFS base.
#    sgdisk and rsync are already in the LFS base. partprobe, blkid,
#    findmnt are in util-linux (in the base). mkfs.vfat is in dosfstools.
#    grub-install is already in the base. Confirm:
for t in sgdisk partprobe rsync blkid findmnt mkfs.vfat mkfs.ext4 grub-install whiptail; do
  if ! command -v "$t" >/dev/null && ! [ -x "$SP/bin/$t" ]; then
    echo "[install-installer] WARN: $t not found — the installer will fail at runtime"
  fi
done

# 4. Greetd: replace the auto-login wrapper with a multi-session menu.
echo "[install-installer] writing /etc/greetd/sessions and switching config.toml"
install -d -m 0755 /etc/greetd/sessions

cat > /etc/greetd/sessions/install-gnunix.desktop <<EOF
[Desktop Entry]
Name=Install GNUnix
Exec=$INSTALL_BIN
Type=Application
EOF

cat > /etc/greetd/sessions/try-live.desktop <<'EOF'
[Desktop Entry]
Name=Try live (Sway)
Exec=/usr/local/bin/start-wayland-session.sh
Type=Application
EOF

cat > /etc/greetd/sessions/shell.desktop <<'EOF'
[Desktop Entry]
Name=Shell (advanced)
Exec=/bin/bash --login
Type=Application
EOF

# Rewrite config.toml — keep vt=1, but offer the sessions menu.
cat > /etc/greetd/config.toml <<EOF
[terminal]
vt = 1

[default_session]
command = "$SP/bin/tuigreet --time --asterisks --sessions /etc/greetd/sessions"
user = "greeter"
EOF

# 5. Live-image identity (so the booted live system identifies itself
#    distinctly from an installed system).
echo "gnunix-installer" > /etc/hostname
cat > /etc/os-release <<'EOF'
NAME="GNUnix"
PRETTY_NAME="GNUnix 0.1.0 (installer/live)"
ID=gnunix
ID_LIKE=gnunix
VERSION_ID="0.1.0"
VARIANT_ID="installer"
HOME_URL="https://gnunix.invalid/"
EOF

# 6. Sanity log line for the human running this.
echo "[install-installer] DONE — boot the image, pick 'Install GNUnix' at the menu."

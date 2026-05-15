#!/bin/bash
# images/installer/install-installer.sh — runs INSIDE the
# gnunix-installer-build VM (called by images/installer/build.sh).
#
# Per ADR-019: pivots the installer to layer on gnunix-minimal. The
# live environment is text-only (no Wayland, no greetd) — getty on tty1
# auto-launches the TUI installer; tty2 is a plain root shell for
# advanced users.
#
# Also stages the ISO build toolchain (xorriso, squashfs-tools, etc.)
# into a SEPARATE Nix profile so mkiso.sh can find them while keeping
# the system profile small. (Trade-off acknowledged: nix-store paths
# they pull in still appear in the squashfs since they're referenced
# from the build profile. ~10 MB of build tools end up on the live
# image and, if the user installs, on disk. Acceptable.)

set -euo pipefail

PAYLOAD_DIR=${PAYLOAD_DIR:-/root/installer-payload}
SP=/nix/var/nix/profiles/system
BUILD_PROFILE=/nix/var/nix/profiles/installer-build
INSTALL_SHARE=/usr/local/share/gnunix-installer
INSTALL_BIN=/usr/local/sbin/gnunix-installer
GETTY_WRAPPER=/usr/local/sbin/gnunix-installer-getty

[ -d "$PAYLOAD_DIR/installer" ] || { echo "[install-installer] payload missing at $PAYLOAD_DIR" >&2; exit 1; }

# 1. Stage the TUI + profile scripts.
echo "[install-installer] staging installer payload under $INSTALL_SHARE"
install -d -m 0755 "$INSTALL_SHARE"
cp -a "$PAYLOAD_DIR/installer/profiles" "$INSTALL_SHARE/profiles"
install -m 0755 "$PAYLOAD_DIR/installer/gnunix-installer" "$INSTALL_BIN"

# 2. Install whiptail (newt) into the system profile (the TUI needs it
#    at runtime in the live env).
echo "[install-installer] installing whiptail (newt) into system profile"
export PATH=/nix/var/nix/profiles/default/bin:$PATH
export HOME=/root
nix-env -p "$SP" -iA nixpkgs.newt 2>&1 | tail -3 || true

# 3. Install ISO build tools into the *build* profile (separate from
#    system, so they're conceptually segregated from the live env).
echo "[install-installer] installing ISO build tools into $BUILD_PROFILE"
nix-env -p "$BUILD_PROFILE" \
  -iA nixpkgs.xorriso \
      nixpkgs.squashfsTools \
      nixpkgs.cpio \
      nixpkgs.mtools \
      nixpkgs.dosfstools \
      nixpkgs.busybox \
      nixpkgs.grub2 \
      2>&1 | tail -5 || true

# 4. Sanity-check the tools the installer / mkiso need at runtime.
for t in sgdisk partprobe rsync blkid findmnt mkfs.vfat mkfs.ext4 \
         grub-install whiptail; do
  if ! command -v "$t" >/dev/null && \
     ! [ -x "$SP/bin/$t" ] && \
     ! [ -x "$BUILD_PROFILE/bin/$t" ]; then
    echo "[install-installer] WARN: $t not found in any profile" >&2
  fi
done

# 5. Auto-launch the installer on tty1, shell on tty2.
#    Per ADR-019: no greetd in the live env.
echo "[install-installer] writing $GETTY_WRAPPER"
install -m 0755 /dev/stdin "$GETTY_WRAPPER" <<'EOF'
#!/bin/sh
# Auto-login as root and run the TUI installer. Live ISO only.
exec /sbin/agetty --autologin root --noclear -l /usr/local/sbin/gnunix-installer-shellwrap tty1 linux
EOF

install -m 0755 /dev/stdin /usr/local/sbin/gnunix-installer-shellwrap <<EOF
#!/bin/sh
# Wrapper exec'd after agetty's auto-login. Runs the installer; on
# clean exit, drops to a login shell (rather than respawning agetty,
# which would re-run the installer immediately).
$INSTALL_BIN
exec /bin/bash --login
EOF

echo "[install-installer] patching /etc/inittab to launch installer on tty1"
# gnunix-minimal's inittab has a tty1 getty by default. Replace just that line.
# The second tty (tty2) keeps the standard agetty for advanced users.
sed -i.bak \
  -e 's|^[0-9]:.*agetty.*tty1.*|1:2345:respawn:/usr/local/sbin/gnunix-installer-getty|' \
  /etc/inittab
# Make sure tty2 has a plain getty.
grep -q '^2:.*agetty.*tty2' /etc/inittab \
  || echo '2:2345:respawn:/sbin/agetty 38400 tty2 linux' >> /etc/inittab

# 6. If greetd is enabled (was running on a gnunix-desktop parent), disable
#    it on the live image. We're text-only here.
if [ -x /etc/rc.d/rc.greetd ]; then
  echo "[install-installer] disabling rc.greetd (live env is text-only)"
  chmod -x /etc/rc.d/rc.greetd
fi

# 7. Live-image identity.
echo "gnunix-installer" > /etc/hostname
VER=$(grep -E '^VERSION_ID=' /etc/os-release 2>/dev/null | sed 's/^VERSION_ID="\?\([^"]*\)"\?$/\1/' || echo 0.2.0)
cat > /etc/os-release <<EOF
NAME="GNUnix"
PRETTY_NAME="GNUnix $VER (installer/live)"
ID=gnunix
ID_LIKE=gnunix
VERSION_ID="$VER"
VARIANT_ID="installer"
HOME_URL="https://github.com/leopepe/gnunix"
EOF

echo "[install-installer] DONE — image is ready for mkiso.sh."

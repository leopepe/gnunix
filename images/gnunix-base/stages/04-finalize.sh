#!/bin/bash
# Stage 4: Finalize. Install bespoke configs, build the kernel, install GRUB,
# and prepare the rootfs for image packaging.

set -euo pipefail

REPO_ROOT=${REPO_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}
SOURCES=${LFS}/sources
JOBS=${JOBS:-$(nproc)}
MANIFEST="$REPO_ROOT/tools/manifest.json"

require_root() { [ "$(id -u)" = 0 ] || { echo "needs root" >&2; exit 1; }; }
require_root

echo "[finalize] install /etc/inittab and /etc/rc.d/"
install -Dm 0644 "$REPO_ROOT/images/gnunix-base/etc/inittab"        "$LFS/etc/inittab"
install -Dm 0644 "$REPO_ROOT/images/gnunix-base/etc/fstab.template" "$LFS/etc/fstab"
install -Dm 0644 "$REPO_ROOT/images/gnunix-base/etc/hostname"       "$LFS/etc/hostname"
install -Dm 0644 "$REPO_ROOT/images/gnunix-base/etc/resolv.conf.tpl" "$LFS/etc/resolv.conf"
install -Dm 0644 "$REPO_ROOT/images/gnunix-base/etc/profile"        "$LFS/etc/profile"
install -Dm 0644 "$REPO_ROOT/images/gnunix-base/etc/syslog.conf"    "$LFS/etc/syslog.conf"

mkdir -p "$LFS/etc/rc.d"
for f in rc.S rc.M rc.K rc.6 rc.local rc.dbus rc.elogind rc.sshd rc.nix-daemon rc.network rc.modules rc.syslogd; do
  install -Dm 0755 "$REPO_ROOT/images/gnunix-base/etc/rc.d/$f" "$LFS/etc/rc.d/$f"
done

# Module-first kernel overlay directory (ADR-012). Empty in gnunix-base;
# per-platform variants drop their own .conf files at packaging time.
install -d -m 0755 "$LFS/etc/modules-load.d"

echo "[finalize] build kernel"
KV=$(jq -r .kernel.version "$MANIFEST")
KSRC=$(mktemp -d)
tar -xf "$SOURCES/linux-$KV.tar.xz" -C "$KSRC"
cd "$KSRC/linux-$KV"
make ARCH=arm64 defconfig
# Apply our config fragments on top of defconfig (ADR-012 module-first).
#   kernel.config         — boot-critical =y overrides
#   kernel.modules.config — non-essential drivers flipped to =m
# Later wins for any duplicate keys; olddefconfig reconciles.
cat "$REPO_ROOT/images/gnunix-base/kernel.config" \
    "$REPO_ROOT/images/gnunix-base/kernel.modules.config" >> .config
make ARCH=arm64 olddefconfig
make -j$JOBS ARCH=arm64 Image modules
make ARCH=arm64 INSTALL_MOD_PATH="$LFS" modules_install
install -Dm 0644 arch/arm64/boot/Image "$LFS/boot/vmlinuz-$KV"
cp .config "$LFS/boot/config-$KV"
cp System.map "$LFS/boot/System.map-$KV"
cd / && rm -rf "$KSRC"

echo "[finalize] install GRUB EFI"
install -Dm 0644 "$REPO_ROOT/images/gnunix-base/grub.cfg" "$LFS/boot/grub/grub.cfg"
# Render the actual EFI binary at image-pack time inside a loop-mounted EFI partition
# (see packaging/mkimage.sh). Here we only stage the config + grub modules.

echo "[finalize] enable services (chmod +x BSD-style)"
# dbus + elogind are deferred (need Python/meson we don't bootstrap yet) so
# leave their rc scripts non-executable — otherwise rc.M wastes time and
# spams errors trying to start nonexistent binaries.
chmod +x "$LFS/etc/rc.d/rc.sshd" \
         "$LFS/etc/rc.d/rc.nix-daemon" \
         "$LFS/etc/rc.d/rc.network" \
         "$LFS/etc/rc.d/rc.syslogd"
chmod -x "$LFS/etc/rc.d/rc.dbus" "$LFS/etc/rc.d/rc.elogind" 2>/dev/null || true

# dhcpcd drops privs to its own user (seeded in /etc/passwd) and chdirs to
# its home. Make the home dir, owned by the dhcpcd uid/gid.
install -d -m 0750 -o 52 -g 52 "$LFS/var/lib/dhcpcd"

echo "[finalize] generate locale + ld.so cache"
chroot "$LFS" /usr/bin/env -i HOME=/root TERM=$TERM PATH=/usr/bin:/usr/sbin /bin/bash <<'CHROOT'
mkdir -p /usr/lib/locale
localedef -i C -f UTF-8 C.UTF-8 || true
ldconfig
CHROOT

echo "[finalize] set root password (locked; set on first boot via console)"
sed -i 's|^root:[^:]*:|root:*:|' "$LFS/etc/shadow" 2>/dev/null || true

echo "[finalize] strip"
find "$LFS/usr"/{bin,lib,sbin} -type f \
  \( -executable -o -name '*.so*' \) -print0 2>/dev/null | xargs -0r strip --strip-unneeded 2>/dev/null || true

echo "[finalize] cleanup build artifacts"
rm -rf "$LFS/tools" "$LFS/repo"

echo "[finalize] done. Rootfs ready at $LFS"

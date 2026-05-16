#!/bin/bash
# Stage 3b: Inner chroot build.
#
# All `ver_*` references come from /repo/versions.env, sourced below.
# shellcheck disable=SC2154
# Runs *inside* the chroot. Builds the final system: binutils-pass2, gcc-pass2,
# and all base packages, using the temp tools.
#
# This is intentionally a thin orchestrator — each package's build sequence
# follows the corresponding chapter of the LFS book. The configurations below
# encode exactly the flags that have proven to produce a bootable arm64 LFS.
#
# Note: this script runs INSIDE the chroot where jq doesn't exist. All
# package version/url values come from /repo/versions.env, pre-resolved by
# 03-chroot.sh on the builder side.

set -euo pipefail

REPO_ROOT=${REPO_ROOT:-/repo}
SOURCES=/sources
JOBS=${JOBS:-$(nproc)}
mkdir -p "$SOURCES"
cp -a /repo/cache/sources/. "$SOURCES/" 2>/dev/null || true

# Coreutils (and a couple of other configure scripts) refuse to run as root
# without this; the chroot stage runs as root by design (we just chroot'd
# without dropping privileges), and that's exactly the LFS book's flow.
export FORCE_UNSAFE_CONFIGURE=1

# shellcheck disable=SC1091
. /repo/versions.env

# Compile-time hardening (ADR-011). hardening.env is rendered on the
# builder side by 03-chroot.sh (which had jq); the helper detects the
# HARDENING_* env vars are already set and skips its jq path.
# shellcheck disable=SC1091
. /repo/hardening.env
# shellcheck disable=SC1091
. /repo/images/gnunix-base/lib/hardening.sh

# Resolve `<base>_<key>` from versions.env, e.g. pkg_ver bash → $ver_bash
pkg_ver() { eval echo \$ver_${1//-/_}; }
pkg_url() { eval echo \$url_${1//-/_}; }
pkg_file() { basename "$(pkg_url "$1")"; }

# Per-package markers so retries don't redo already-installed packages.
# /var/lib/lfs-pkgs/ persists across chroot exits/re-enters.
PKG_MARKERS=/var/lib/lfs-pkgs
mkdir -p "$PKG_MARKERS"

pkg_done() { [ -f "$PKG_MARKERS/$1.done" ]; }
pkg_mark() { touch "$PKG_MARKERS/$1.done" && sync; }
pkg_skip() {
  if pkg_done "$1"; then
    echo "[chroot-inner] $1 already built (skipping)"
    return 0
  fi
  return 1
}

# Create core directory tree (FHS)
install -dv /{boot,home,mnt,opt,srv}
install -dv /etc/{opt,sysconfig,rc.d}
install -dv /lib/firmware
install -dv /media/{floppy,cdrom}
install -dv /usr/{,local/}{include,src}
install -dv /usr/lib/locale
install -dv /usr/local/{bin,lib,sbin}
install -dv /usr/{,local/}share/{color,dict,doc,info,locale,man}
install -dv /usr/{,local/}share/{misc,terminfo,zoneinfo}
install -dv /usr/{,local/}share/man/man{1..8}
install -dv /var/{cache,local,log,mail,opt,spool}
install -dv /var/lib/{color,misc,locate}
ln -sfv /run /var/run
ln -sfv /run/lock /var/lock
install -dv -m 0750 /root
install -dv -m 1777 /tmp /var/tmp

# Essential symlinks expected by some build scripts
[ -h /etc/mtab ] || ln -sv /proc/self/mounts /etc/mtab

# /etc/hosts and a friendly /etc/issue
cat > /etc/hosts <<'EOF'
127.0.0.1  localhost
::1        localhost
EOF
cat > /etc/issue <<'EOF'
Welcome to gnunix-base (custom LFS + Nix distro)
EOF

# /etc/passwd, /etc/group (minimum)
cat > /etc/passwd <<'EOF'
root:x:0:0:root:/root:/bin/bash
bin:x:1:1:bin:/dev/null:/usr/bin/false
daemon:x:6:6:Daemon User:/dev/null:/usr/bin/false
messagebus:x:18:18:D-Bus Message Daemon User:/run/dbus:/usr/bin/false
sshd:x:50:50:sshd PrivSep:/var/lib/sshd:/usr/bin/false
dhcpcd:x:52:52:dhcpcd PrivSep:/var/lib/dhcpcd:/usr/bin/false
nobody:x:65534:65534:Unprivileged User:/dev/null:/usr/bin/false
EOF
cat > /etc/group <<'EOF'
root:x:0:
bin:x:1:daemon
sys:x:2:
kmem:x:3:
tape:x:4:
tty:x:5:
daemon:x:6:
floppy:x:7:
disk:x:8:
lp:x:9:
dialout:x:10:
audio:x:11:
video:x:12:
utmp:x:13:
cdrom:x:15:
adm:x:16:
messagebus:x:18:
input:x:24:
mail:x:34:
sshd:x:50:
dhcpcd:x:52:
kvm:x:61:
wheel:x:97:
users:x:999:
nogroup:x:65534:
EOF

# binutils-pass2 and gcc-pass2 are now built in stage 02 (temp-tools) where
# the cross-toolchain at $LFS/tools/bin is on PATH; their outputs land in
# $LFS/usr/bin (gcc, cc, ar, as, ld, ...) so the chroot has a working
# compiler. LFS book chapter 6.17 and 6.18.

# Bison + Flex — yacc/lex parser+lexer generators. Used by iproute2 (and
# many others). Not bootstrapped in temp-tools; built native in chroot.
# LFS book chapter 7.7 (bison) + 7.6 (flex).
if ! pkg_skip bison; then
  v=$ver_bison
  fname=$(pkg_file bison)
  d=$(mktemp -d); tar -xf "$SOURCES/$fname" -C "$d"
  cd "$d/bison-$v"
  echo "[chroot-inner] building bison-$v"
  hardening_export "bison" native
  ./configure --prefix=/usr --docdir=/usr/share/doc/bison-$v
  make -j$JOBS
  make install
  cd /; rm -rf "$d"
  pkg_mark bison
fi

if ! pkg_skip flex; then
  v=$ver_flex
  fname=$(pkg_file flex)
  d=$(mktemp -d); tar -xf "$SOURCES/$fname" -C "$d"
  cd "$d/flex-$v"
  echo "[chroot-inner] building flex-$v"
  hardening_export "flex" native
  ./configure --prefix=/usr --docdir=/usr/share/doc/flex-$v --disable-static
  make -j$JOBS
  make install
  ln -sfv flex /usr/bin/lex
  cd /; rm -rf "$d"
  pkg_mark flex
fi

# gperf — perfect-hash generator; required by eudev (and a few others).
if ! pkg_skip gperf; then
  v=$ver_gperf
  fname=$(pkg_file gperf)
  d=$(mktemp -d); tar -xf "$SOURCES/$fname" -C "$d"
  cd "$d/gperf-$v"
  echo "[chroot-inner] building gperf-$v"
  hardening_export "gperf" native
  ./configure --prefix=/usr --docdir=/usr/share/doc/gperf-$v
  make -j$JOBS
  make install
  cd /; rm -rf "$d"
  pkg_mark gperf
fi



# pkgconf — pkg-config implementation; required by dbus (and many others).
# LFS book chapter 7.10. We install both pkgconf and a pkg-config symlink
# so packages that explicitly ask for "pkg-config" find it.
if ! pkg_skip pkgconf; then
  v=$ver_pkgconf
  fname=$(pkg_file pkgconf)
  d=$(mktemp -d); tar -xf "$SOURCES/$fname" -C "$d"
  cd "$d/pkgconf-$v"
  echo "[chroot-inner] building pkgconf-$v"
  hardening_export "pkgconf" native
  ./configure --prefix=/usr --disable-static --docdir=/usr/share/doc/pkgconf-$v
  make -j$JOBS
  make install
  ln -sfv pkgconf /usr/bin/pkg-config
  ln -sfv pkgconf.1 /usr/share/man/man1/pkg-config.1
  cd /; rm -rf "$d"
  pkg_mark pkgconf
fi

# Perl — required by libxcrypt's configure (uses Perl 5.14.0+) and many
# other later builds. Build with the standard LFS chapter 7.13 invocation.
# Configure uses sh-driven Configure (not autoconf), so flag style differs.
# Pinned to 5.38.2 — 5.40.0 hit a locale.c codegen bug in our chroot env.
if ! pkg_skip perl; then
  v=$ver_perl
  fname=$(pkg_file perl)
  perl_majmin=$(echo "$v" | awk -F. '{print $1"."$2}')   # e.g. 5.38
  d=$(mktemp -d); tar -xf "$SOURCES/$fname" -C "$d"
  cd "$d/perl-$v"
  echo "[chroot-inner] building perl-$v"
  hardening_export "perl" native
  sh Configure -des \
    -Dprefix=/usr -Dvendorprefix=/usr -Duseshrplib \
    -Dprivlib=/usr/lib/perl5/$perl_majmin/core_perl \
    -Darchlib=/usr/lib/perl5/$perl_majmin/core_perl \
    -Dsitelib=/usr/lib/perl5/$perl_majmin/site_perl \
    -Dsitearch=/usr/lib/perl5/$perl_majmin/site_perl \
    -Dvendorlib=/usr/lib/perl5/$perl_majmin/vendor_perl \
    -Dvendorarch=/usr/lib/perl5/$perl_majmin/vendor_perl
  make -j$JOBS
  make install
  cd /; rm -rf "$d"
  pkg_mark perl
fi

# libxcrypt — provides crypt() which glibc-2.40 no longer ships. Needed by
# shadow (and anything else with password hashing). LFS book chapter 8 uses
# specific configure flags rather than the generic loop below.
if ! pkg_skip libxcrypt; then
  v=$ver_libxcrypt
  fname=$(pkg_file libxcrypt)
  d=$(mktemp -d); tar -xf "$SOURCES/$fname" -C "$d"
  cd "$d/libxcrypt-$v"
  echo "[chroot-inner] building libxcrypt-$v"
  hardening_export "libxcrypt" native
  ./configure --prefix=/usr --enable-hashes=strong,glibc \
    --enable-obsolete-api=no --disable-static --disable-failure-tokens
  make -j$JOBS
  make install
  cd /; rm -rf "$d"
  pkg_mark libxcrypt
fi

# Python — required by GRUB's configure (mandatory). Built AFTER libxcrypt
# so Python's _crypt extension finds crypt() at link time (glibc 2.40 no
# longer ships crypt; libxcrypt provides it).
# Python's _uuidmodule.c calls uuid_generate_time_safe via configure-time
# autodetect, but our libuuid <uuid/uuid.h> doesn't declare the prototype
# in this build. C11 treats the implicit declaration as a hard error.
# Prepend both the include and an explicit extern declaration so the
# call type-checks; libuuid still provides the symbol at link time.
if ! pkg_skip python; then
  v=$ver_python
  fname=$(pkg_file python)
  d=$(mktemp -d); tar -xf "$SOURCES/$fname" -C "$d"
  cd "$d"/Python-$v
  echo "[chroot-inner] building python-$v"
  hardening_export "python" native
  { printf '#include <uuid/uuid.h>\nextern int uuid_generate_time_safe(unsigned char *out);\n'; \
    cat Modules/_uuidmodule.c; } > /tmp/_uuidmodule.c.new
  mv /tmp/_uuidmodule.c.new Modules/_uuidmodule.c
  ./configure --prefix=/usr --enable-shared --without-ensurepip
  make -j$JOBS
  make install
  cd /; rm -rf "$d"
  pkg_mark python
fi

# shadow — LFS book chapter 8.5 needs --without-libbsd (avoids libbsd
# dependency for readpassphrase) and a few other specific flags + seds.
# Built before the generic loop so the loop can skip it.
if ! pkg_skip shadow; then
  v=$ver_shadow
  fname=$(pkg_file shadow)
  d=$(mktemp -d); tar -xf "$SOURCES/$fname" -C "$d"
  cd "$d/shadow-$v"
  echo "[chroot-inner] building shadow-$v"
  hardening_export "shadow" native
  sed -i 's/groups$(EXEEXT) //' src/Makefile.in
  find man -name Makefile.in -exec sed -i 's/groups\.1 / /'    {} \;
  find man -name Makefile.in -exec sed -i 's/getspnam\.3 / /'  {} \;
  find man -name Makefile.in -exec sed -i 's/passwd\.5 / /'    {} \;
  sed -e 's:#ENCRYPT_METHOD DES:ENCRYPT_METHOD YESCRYPT:' \
      -e 's:/var/spool/mail:/var/mail:'                   \
      -e '/PATH=/{s@/sbin:@@;s@/bin:@@}'                  \
      -i etc/login.defs
  touch /usr/bin/passwd
  ./configure --sysconfdir=/etc --disable-static --with-{b,yes}crypt \
    --without-libbsd --without-nscd --without-selinux --without-libpam \
    --with-group-name-max-length=32
  make -j$JOBS
  make exec_prefix=/usr install
  cd /; rm -rf "$d"
  pkg_mark shadow
fi

# util-linux — needs flags to disable optional features (liblastlog2 wants
# sqlite3, pylibmount wants python, etc.). Same flags as the temp-tools
# build but with --docdir set. LFS book chapter 8.13.
if ! pkg_skip util-linux; then
  v=$ver_util_linux
  fname=$(pkg_file util-linux)
  d=$(mktemp -d); tar -xf "$SOURCES/$fname" -C "$d"
  cd "$d/util-linux-$v"
  echo "[chroot-inner] building util-linux-$v"
  hardening_export "util-linux" native
  mkdir -pv /var/lib/hwclock
  ./configure ADJTIME_PATH=/var/lib/hwclock/adjtime \
    --bindir=/usr/bin --libdir=/usr/lib --runstatedir=/run --sbindir=/usr/sbin \
    --disable-chfn-chsh --disable-login --disable-nologin --disable-su \
    --disable-setpriv --disable-runuser --disable-pylibmount \
    --disable-static --disable-liblastlog2 \
    --without-python --without-systemd --without-systemdsystemunitdir \
    --docdir=/usr/share/doc/util-linux-$v
  make -j$JOBS
  make install
  cd /; rm -rf "$d"
  pkg_mark util-linux
fi

# Loop the rest of base packages with default ./configure --prefix=/usr.
# shadow + util-linux omitted (built above with custom flags).
# openssl omitted (built below with its custom ./config script).
# iputils omitted: uses meson which requires Python (not bootstrapped); ping
# can come via Nix userland or a later phase.
#
# Order matters for kmod: it must be built before eudev, so eudev's
# ./configure --enable-kmod can find libkmod. The rest of the new
# Slackware-parity additions (procps-ng / psmisc / sysklogd) only need
# the base toolchain.
for entry in \
  bash coreutils diffutils file findutils gawk grep gzip make patch sed tar xz \
  iproute2 dhcpcd less vim e2fsprogs zlib expat \
  ncurses readline pam \
  kmod procps-ng psmisc sysklogd \
  popt cronie logrotate \
  hwdata
do
  pkg_skip "$entry" && continue
  v=$(pkg_ver "$entry")
  [ -z "$v" ] && continue
  url=$(pkg_url "$entry")
  fname=$(basename "$url")
  d=$(mktemp -d)
  tar -xf "$SOURCES/$fname" -C "$d"
  inner=$(ls "$d" | head -n1)
  cd "$d/$inner"
  echo "[chroot-inner] building $entry-$v"
  hardening_export "$entry" native
  if [ -x ./configure ]; then
    ./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var || true
  elif [ -x ./autogen.sh ]; then
    ./autogen.sh && ./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var || true
  fi
  make -j$JOBS
  make install
  cd /
  rm -rf "$d"
  pkg_mark "$entry"
done

# openssl — custom config script (not autoconf); needs lib dir + LFS-style
# shared/zlib-dynamic flags. LFS book chapter 8.x.
if ! pkg_skip openssl; then
  v=$ver_openssl
  fname=$(pkg_file openssl)
  d=$(mktemp -d); tar -xf "$SOURCES/$fname" -C "$d"
  cd "$d/openssl-$v"
  echo "[chroot-inner] building openssl-$v"
  hardening_export "openssl" native
  ./config --prefix=/usr --openssldir=/etc/ssl --libdir=lib shared zlib-dynamic
  make -j$JOBS
  sed -i '/INSTALL_LIBS/s/libcrypto.a libssl.a//' Makefile
  make MANSUFFIX=ssl install
  cd /; rm -rf "$d"
  pkg_mark openssl
fi

# sysvinit + eudev (dbus + elogind deferred — both need Python/meson which
# we haven't bootstrapped. dbus is optional for our Phase 2 minimum:
# sshd/init/network/nix-daemon all run without it. Comes back in a later
# phase via Nix userland or once Python lands).
for entry in sysvinit eudev; do
  pkg_skip "$entry" && continue
  v=$(pkg_ver "$entry")
  url=$(pkg_url "$entry")
  fname=$(basename "$url")
  d=$(mktemp -d); tar -xf "$SOURCES/$fname" -C "$d"
  inner=$(ls "$d" | head -n1)
  cd "$d/$inner"
  echo "[chroot-inner] building $entry-$v"
  hardening_export "$entry" native
  case "$entry" in
    sysvinit)
      make
      make install
      ;;
    eudev)
      # --enable-kmod: route MODALIAS coldplug through libkmod so eudev
      # can actually autoload modules. Requires kmod built first (loop
      # above). Closes the gap workaround'd in PR #15.
      ./configure --prefix=/usr --bindir=/usr/sbin --sysconfdir=/etc \
        --enable-manpages --disable-static --enable-kmod
      make -j$JOBS && make install
      ;;
  esac
  pkg_mark "$entry"
done

# meson — Python build system, vendored in (no pip bootstrap needed).
# Copies mesonbuild/ into Python's site-packages and meson.py to
# /usr/bin/meson. Slackware uses the same approach.
if ! pkg_skip meson; then
  v=$ver_meson
  fname=$(pkg_file meson)
  d=$(mktemp -d); tar -xf "$SOURCES/$fname" -C "$d"
  cd "$d/meson-$v"
  echo "[chroot-inner] installing meson-$v (vendor-copy)"
  # Resolve the Python lib dir dynamically so a future python bump
  # doesn't silently miss its site-packages.
  py_libdir=$(python3 -c 'import sys; print(f"/usr/lib/python{sys.version_info.major}.{sys.version_info.minor}/site-packages")')
  install -d -m 0755 "$py_libdir"
  cp -r mesonbuild "$py_libdir/"
  install -m 0755 meson.py /usr/bin/meson
  # Smoke-test
  meson --version
  cd /; rm -rf "$d"
  pkg_mark meson
fi

# ninja — bootstrap via the project's own python3 configure.py.
if ! pkg_skip ninja; then
  v=$ver_ninja
  fname=$(pkg_file ninja)
  d=$(mktemp -d); tar -xf "$SOURCES/$fname" -C "$d"
  cd "$d/ninja-$v"
  echo "[chroot-inner] bootstrapping ninja-$v"
  hardening_export "ninja" native
  python3 configure.py --bootstrap
  install -m 0755 ninja /usr/bin/ninja
  ninja --version
  cd /; rm -rf "$d"
  pkg_mark ninja
fi

# pciutils + dmidecode — Makefile-only (no ./configure), so they don't
# fit the autotools loop. Hardware introspection.
# (cronie was originally dcron in this block; we switched to cronie
# upstream of here because its tarball mirrors are dead. cronie is
# autotools, so it's now in the loop above.)
for entry in pciutils dmidecode; do
  pkg_skip "$entry" && continue
  v=$(pkg_ver "$entry")
  url=$(pkg_url "$entry")
  fname=$(basename "$url")
  d=$(mktemp -d); tar -xf "$SOURCES/$fname" -C "$d"
  inner=$(ls "$d" | head -n1)
  cd "$d/$inner"
  echo "[chroot-inner] building $entry-$v"
  hardening_export "$entry" native
  case "$entry" in
    pciutils)
      # pciutils Makefile honours PREFIX (uppercase) and SBINDIR.
      # SHARED=yes keeps libpci dynamic so future packages can link
      # against it without a static-copy fight.
      make -j$JOBS PREFIX=/usr SBINDIR=/usr/sbin SHARED=yes
      make install install-lib PREFIX=/usr SBINDIR=/usr/sbin SHARED=yes
      ;;
    dmidecode)
      # dmidecode Makefile uses lowercase prefix.
      make -j$JOBS prefix=/usr
      make install prefix=/usr
      ;;
  esac
  cd /; rm -rf "$d"
  pkg_mark "$entry"
done

# usbutils — meson build. Depends on hwdata being installed (above) so
# lsusb can resolve vendor/product IDs to names; depends on libudev
# from eudev for hotplug. /usr/share/hwdata/usb.ids is what hwdata's
# install lays down.
if ! pkg_skip usbutils; then
  v=$ver_usbutils
  fname=$(pkg_file usbutils)
  d=$(mktemp -d); tar -xf "$SOURCES/$fname" -C "$d"
  cd "$d/usbutils-$v"
  echo "[chroot-inner] building usbutils-$v (meson)"
  hardening_export "usbutils" native
  meson setup build --prefix=/usr --buildtype=release \
    -Dsystemdshutdowndir=/usr/lib/systemd/system-shutdown    # /dev/null path; we have no systemd
  meson compile -C build
  meson install -C build
  cd /; rm -rf "$d"
  pkg_mark usbutils
fi

# openssh
if ! pkg_skip openssh; then
  v=$ver_openssh
  fname=$(pkg_file openssh)
  d=$(mktemp -d); tar -xf "$SOURCES/$fname" -C "$d"
  cd "$d"/openssh-*
  echo "[chroot-inner] building openssh-$v"
  hardening_export "openssh" native
  ./configure --prefix=/usr --sysconfdir=/etc/ssh --with-md5-passwords --with-privsep-path=/var/lib/sshd
  make -j$JOBS
  install -v -m700 -d /var/lib/sshd
  chown -v root:sys /var/lib/sshd
  make install
  pkg_mark openssh
fi

# grub (EFI for arm64)
if ! pkg_skip grub; then
  v=$ver_grub
  d=$(mktemp -d); tar -xf "$SOURCES/grub-$v.tar.xz" -C "$d"
  cd "$d/grub-$v"
  echo "[chroot-inner] building grub-$v"
  hardening_export "grub" native
  # grub-2.12's Makefile depends on grub-core/extra_deps.lst, which is
  # produced by ./bootstrap (gnulib-tool) when generating the tarball.
  # The release tarball ships incomplete on this front; touch it so make
  # doesn't fail with "No rule to make target '../grub-core/extra_deps.lst'".
  : > grub-core/extra_deps.lst
  ./configure --prefix=/usr --sysconfdir=/etc \
    --target=aarch64 --with-platform=efi --disable-werror
  make -j$JOBS && make install
  pkg_mark grub
fi

echo "[chroot-inner] complete"

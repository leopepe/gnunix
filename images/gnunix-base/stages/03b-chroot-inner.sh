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

# Build-only tools, built here rather than borrowed from the host.
#
# These four were skipped on the claim that 03-chroot.sh bind-mounts them
# from apt into /usr/bin/lfs-tools. That never worked, for two
# independent reasons: the chroot's PATH is /usr/bin:/usr/sbin, which
# does not include /usr/bin/lfs-tools, and the entries there are symlinks
# to absolute paths like /usr/bin/pkgconf that resolve INSIDE the chroot,
# where nothing is installed. Both runs that reached this stage reported
# `checking for pkg-config... no`.
#
# Ordered deliberately: bison and flex need m4 (now built in temp-tools),
# and everything after this point may need any of the four.
# LFS book ch. 7.6, 7.7 and ch. 8.
for entry in bison flex gperf pkgconf; do
  pkg_skip "$entry" && continue
  v=$(pkg_ver "$entry")
  [ -z "$v" ] && continue
  fname=$(pkg_file "$entry")
  d=$(mktemp -d); tar -xf "$SOURCES/$fname" -C "$d"
  inner=$(ls "$d" | head -n1)
  cd "$d/$inner"
  echo "[chroot-inner] building $entry-$v"
  hardening_export "$entry" native
  extra=""
  case "$entry" in
    bison)  extra="--docdir=/usr/share/doc/bison-$v" ;;
    pkgconf) extra="--disable-static" ;;
  esac
  # shellcheck disable=SC2086  # extra is a deliberate flag list
  ./configure --prefix=/usr $extra
  make -j$JOBS
  make install
  # Everything probing for a pkg-config implementation calls it by that
  # name, not `pkgconf`. LFS book ch. 8.4.
  [ "$entry" = pkgconf ] && ln -sfv pkgconf /usr/bin/pkg-config
  cd /; rm -rf "$d"
  pkg_mark "$entry"
done

# Perl — required by libxcrypt's configure (>= 5.14) and by several
# later packages' build machinery.
#
# Perl was previously skipped here on the claim that it came from the
# host via /usr/bin/lfs-tools (5bf0eae). It never did — perl was never
# even in that symlink list, and as of the commit that removed the whole
# mechanism from 03-chroot.sh, there is no such list to be in. libxcrypt
# stopped at "configure: error: Perl version 5.14.0 or later is
# required".
#
# Perl could not have been borrowed that way regardless: it is not one
# binary but an interpreter plus its module tree (@INC under
# /usr/lib/perl5/...), and a symlinked /usr/bin/perl finds none of it.
# Building it is also what the manifest implies — perl is pinned in
# base_packages at a version chosen for a specific reason (5.40 has a
# locale.c codegen bug, per docs/runbooks/build.md), which is not
# something you pin for a package you borrow from the host's apt.
#
# Not autotools, so it gets its own block. Flags per LFS book ch. 7.
if ! pkg_skip perl; then
  v=$ver_perl
  fname=$(pkg_file perl)
  d=$(mktemp -d); tar -xf "$SOURCES/$fname" -C "$d"
  cd "$d/perl-$v"
  echo "[chroot-inner] building perl-$v"
  hardening_export "perl" native
  # @INC paths are versioned by major.minor only: 5.38.2 -> 5.38.
  perl_mm=${v%.*}
  sh Configure -des                                            \
    -Dprefix=/usr                                              \
    -Dvendorprefix=/usr                                        \
    -Duseshrplib                                               \
    -Dprivlib="/usr/lib/perl5/$perl_mm/core_perl"              \
    -Darchlib="/usr/lib/perl5/$perl_mm/core_perl"              \
    -Dsitelib="/usr/lib/perl5/$perl_mm/site_perl"              \
    -Dsitearch="/usr/lib/perl5/$perl_mm/site_perl"             \
    -Dvendorlib="/usr/lib/perl5/$perl_mm/vendor_perl"          \
    -Dvendorarch="/usr/lib/perl5/$perl_mm/vendor_perl"
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

# Python is built further down, next to ninja and meson, because that is
# where it is first needed (usbutils is a meson project). It is not a
# GRUB dependency, despite an earlier comment here saying so: GRUB 2.12
# configures from the release tarball without python — that requirement
# applies to a git checkout's autogen.sh.

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
# bzip2 — block-sorting compression utility + libbz2. Built before the
# main autotools loop because (a) the temp-tools tar was configured
# with lbzip2 on PATH and hardcodes it as the bz2 decompressor, so any
# .tar.bz2 extraction inside the chroot fails with `lbzip2: Cannot
# exec` until bzip2 is on the rootfs PATH; (b) the loop below extracts
# libusb (.tar.bz2) and passes --use-compress-program=bzip2, which
# requires bzip2 to be live by the time that iteration runs.
# bzip2 is Makefile-only (no ./configure), so it gets its own block
# rather than slotting into the autotools loop.
if ! pkg_skip bzip2; then
  v=$ver_bzip2
  fname=$(pkg_file bzip2)
  d=$(mktemp -d); tar -xf "$SOURCES/$fname" -C "$d"
  cd "$d/bzip2-$v"
  echo "[chroot-inner] building bzip2-$v"
  hardening_export "bzip2" native
  # Patch the shared-library Makefile to honour the hardening LDFLAGS
  # we just exported. Upstream's Makefile-libbz2_so hardcodes the link
  # line; sed in -Wl,--as-needed -Wl,-z,relro etc. so libbz2.so ships
  # with the same RELRO+BIND_NOW posture as the rest of the base.
  sed -i 's|^all: \(.*\)|LDFLAGS += '"$LDFLAGS"'\nall: \1|' Makefile-libbz2_so
  make -f Makefile-libbz2_so
  make clean
  make -j$JOBS
  make PREFIX=/usr install
  install -Dm 0755 libbz2.so.1.0.8 /usr/lib/libbz2.so.1.0.8
  ln -sf libbz2.so.1.0.8 /usr/lib/libbz2.so.1.0
  ln -sf libbz2.so.1.0   /usr/lib/libbz2.so.1
  ln -sf libbz2.so.1     /usr/lib/libbz2.so
  cd /; rm -rf "$d"
  pkg_mark bzip2
fi

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
  bash coreutils diffutils file findutils gawk grep gzip sed tar xz \
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
  # tar in the rootfs was built with lbzip2 autodetected on the
  # builder host's PATH and hardcodes it as the .bz2 decompressor —
  # but lbzip2 isn't in the final rootfs. For any *.tar.bz2 source,
  # force bzip2 (built in its own block above) via
  # --use-compress-program. Other formats use tar's native path.
  # No package in this loop ships as .tar.bz2 today — libusb, which
  # did, now builds after eudev for libudev — so this arm is kept for
  # the next one rather than removed.
  case "$fname" in
    *.tar.bz2) tar --use-compress-program=bzip2 -xf "$SOURCES/$fname" -C "$d" ;;
    *)         tar -xf "$SOURCES/$fname" -C "$d" ;;
  esac
  inner=$(ls "$d" | head -n1)
  cd "$d/$inner"
  echo "[chroot-inner] building $entry-$v"
  hardening_export "$entry" native
  # Per-package configure flag overrides. Keep the list small — the
  # default `./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var`
  # is right for the vast majority. Add a case here only when a package
  # genuinely needs a different invocation.
  extra_flags=""
  case "$entry" in
    procps-ng|psmisc)
      # The base ncurses install in this rootfs predates `--enable-pc-files`
      # so anything that probes for ncurses via pkg-config fails to find
      # `ncursesw.pc` / `ncurses.pc`. procps-ng (`top`) and psmisc
      # (`pstree --color`) both go through that path. `--without-ncurses`
      # builds the non-TUI subset (`ps`, `free`, `uptime`, `pstree`
      # without color/cursor). Real TUI tools come back via Nix
      # (`nix-env -iA nixpkgs.htop`). Proper fix is to rebuild ncurses
      # with --enable-pc-files; tracked as follow-up.
      extra_flags="--without-ncurses"
      ;;
  esac
  if [ -x ./configure ]; then
    # shellcheck disable=SC2086
    ./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var $extra_flags || true
  elif [ -x ./autogen.sh ]; then
    # shellcheck disable=SC2086
    ./autogen.sh && ./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var $extra_flags || true
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

# libusb — must come AFTER eudev, which provides libudev.
#
# It used to sit at the end of the main autotools loop, which runs before
# eudev is built, so its configure found no libudev header and stopped:
#   configure: error: udev support requested but libudev header not installed
# libusb enables udev support by default and uses it to enumerate devices
# via /dev/bus/usb; usbutils below links against the result, and its own
# comment already notes the eudev dependency.
#
# Own block rather than the loop: the loop runs before eudev, and the
# source ships only as .tar.bz2 (see the tar note in that loop).
if ! pkg_skip libusb; then
  v=$ver_libusb
  fname=$(pkg_file libusb)
  d=$(mktemp -d)
  tar --use-compress-program=bzip2 -xf "$SOURCES/$fname" -C "$d"
  cd "$d/libusb-$v"
  echo "[chroot-inner] building libusb-$v"
  hardening_export "libusb" native
  ./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var \
    --disable-static
  make -j$JOBS
  make install
  cd /; rm -rf "$d"
  pkg_mark libusb
fi

# Python + ninja + meson — the build stack usbutils needs.
#
# All three carried the same "bind-mounted from apt" claim as perl and
# pkgconf, and it was just as false. usbutils is a meson project, so the
# stage stopped at `meson: command not found` (run 34714821005) the
# moment libusb stopped failing ahead of it.
#
# Order is forced: meson is Python, and ninja bootstraps with Python.
# Each is installed the way tools/manifest.json documents for it.
if ! pkg_skip python; then
  v=$ver_python
  fname=$(pkg_file python)
  d=$(mktemp -d); tar -xf "$SOURCES/$fname" -C "$d"
  # The tarball unpacks to Python-<v>, capitalised, so resolve it rather
  # than assuming <name>-<version>.
  inner=$(ls "$d" | head -n1)
  cd "$d/$inner"
  echo "[chroot-inner] building python-$v"
  hardening_export "python" native
  # --with-system-expat: expat is already built in the loop above, so
  # don't compile the bundled copy. --without-ensurepip: meson arrives
  # by vendor-copy below, and nothing here wants pip in the image.
  # --enable-optimizations is deliberately NOT set: PGO roughly doubles
  # an already ~10 min build for a interpreter used only at build time.
  ./configure --prefix=/usr --enable-shared \
    --with-system-expat --without-ensurepip
  make -j$JOBS
  make install
  cd /; rm -rf "$d"
  pkg_mark python
fi

# python<major>.<minor>, e.g. 3.12 — meson's vendor-copy target below.
py_mm=$(echo "$ver_python" | cut -d. -f1,2)

if ! pkg_skip ninja; then
  v=$ver_ninja
  fname=$(pkg_file ninja)
  d=$(mktemp -d); tar -xf "$SOURCES/$fname" -C "$d"
  cd "$d/ninja-$v"
  echo "[chroot-inner] building ninja-$v"
  hardening_export "ninja" native
  # No autotools: bootstrap with the interpreter just installed, then
  # drop the single binary in place (per the manifest note).
  python3 configure.py --bootstrap
  install -v -m755 ninja /usr/bin/ninja
  cd /; rm -rf "$d"
  pkg_mark ninja
fi

if ! pkg_skip meson; then
  v=$ver_meson
  fname=$(pkg_file meson)
  d=$(mktemp -d); tar -xf "$SOURCES/$fname" -C "$d"
  cd "$d/meson-$v"
  echo "[chroot-inner] installing meson-$v (vendor-copy)"
  # Vendor-copy per the manifest note: meson is pure Python, and copying
  # meson.py plus its package onto sys.path avoids bootstrapping pip or
  # setuptools into the image for a build-time-only tool.
  install -v -m755 meson.py /usr/bin/meson
  install -v -d "/usr/lib/python${py_mm}/site-packages"
  cp -a mesonbuild "/usr/lib/python${py_mm}/site-packages/"
  meson --version
  cd /; rm -rf "$d"
  pkg_mark meson
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
  # usbutils v018 dropped all project options — there is no
  # meson_options.txt and `meson.build` declares no `option(...)`. The
  # earlier `-Dsystemdshutdowndir=...` flag now triggers
  # `ERROR: Unknown options: "systemdshutdowndir"`. Vanilla `meson
  # setup` is sufficient; v018 builds lsusb/lsusb.py/usbhid-dump
  # without any systemd-shutdown integration.
  meson setup build --prefix=/usr --buildtype=release
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

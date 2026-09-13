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
# iputils omitted: meson build, and meson left the base with issue #161
# (python stayed — GRUB needs it; meson and ninja did not survive).
# ping comes from the Nix userland.
#
# sysklogd, cronie, logrotate, popt, procps-ng and psmisc are not here
# either: issue #161 moved that userland to nix/minimal.nix, where a CVE
# in any of them is a flake.lock bump instead of an LFS chroot rebuild
# and a new base release. rc.syslogd and rc.crond exec them out of
# /nix/var/nix/profiles/system.
#
# Order matters for kmod: it must be built before eudev, so eudev's
# ./configure --enable-kmod can find libkmod.
for entry in \
  bash coreutils diffutils file findutils gawk grep gzip sed tar xz \
  iproute2 dhcpcd less vim e2fsprogs zlib expat \
  ncurses readline kmod
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

# sysvinit + eudev.
#
# dbus and elogind are NOT built here and are not "deferred": per ADR-025
# they are declared in nix/desktop.nix and installed into the system
# profile, and issue #161 dropped their (never-built) manifest entries.
# The base's own boot path — sshd, init, network, nix-daemon — runs
# without either.
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

# Python — a build dependency of GRUB, and of nothing else in this stage.
#
# This block sat further down the file until issue #161, removed on the
# strength of a comment claiming "GRUB 2.12 configures from the release
# tarball without python — that requirement applies to a git checkout's
# autogen.sh". That is false. grub-2.12's configure calls AM_PATH_PYTHON
# unconditionally and aborts on a release tarball just the same:
#
#   checking target system type... aarch64-unknown-none
#   checking for a Python interpreter with version >= 2.6... none
#   configure: error: no suitable Python interpreter found
#
# (run 34765691034, the chroot stage, 15:44:57 — grub is the only package
# in this script configured with --target, so the trace is unambiguous.)
#
# The claim looked true only because python was built earlier in the same
# stage for usbutils, so GRUB always found one. Removing usbutils removed
# GRUB's interpreter with it. Built here rather than further up so the
# ordering states the dependency: python exists for the block below it.
#
# --with-system-expat: expat is built in the loop above, so don't compile
# the bundled copy. --without-ensurepip: nothing here wants pip in the
# image. --enable-optimizations is deliberately NOT set — PGO roughly
# doubles the build of an interpreter used only at build time.
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
  ./configure --prefix=/usr --enable-shared \
    --with-system-expat --without-ensurepip
  make -j$JOBS
  make install
  cd /; rm -rf "$d"
  pkg_mark python
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

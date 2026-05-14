#!/bin/bash
# Stage 1: Cross-toolchain.
#
# Builds binutils-pass1, gcc-pass1, linux api headers, glibc, and libstdc++
# into $LFS/tools/. After this stage, $LFS/tools/bin contains a working
# cross-compiler targeting $LFS_TGT.
#
# This stage runs as the unprivileged 'lfs' user, with PATH=$LFS/tools/bin:/usr/bin:/bin
# and a clean environment. Follows LFS book chapter 5 (cross-compiling).

set -euo pipefail

REPO_ROOT=${REPO_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}
SOURCES=${LFS}/sources
TOOLS=${LFS}/tools
JOBS=${JOBS:-$(nproc)}

require_var() { [ -n "${!1:-}" ] || { echo "$1 not set" >&2; exit 1; }; }
require_var LFS
require_var LFS_TGT

# Compile-time hardening helper (ADR-011). We're still in the cross-toolchain
# phase here; hardening_export <pkg> cross emits the small "safe" flag set
# (no PIE, no FORTIFY, no SSP — those break bootstrap).
. "$REPO_ROOT/images/gnunix-base/lib/hardening.sh"

mkdir -p "$TOOLS"
[ -L /tools ] || ln -sfn "$TOOLS" /tools

extract() {
  local tarball=$1 destdir=$2
  mkdir -p "$destdir"
  tar -xf "$tarball" -C "$destdir" --strip-components=0
}

build_binutils_pass1() {
  local v; v=$(jq -r .toolchain.binutils.version "$REPO_ROOT/tools/manifest.json")
  local src="$SOURCES/binutils-$v.tar.xz"
  local work; work=$(mktemp -d)
  extract "$src" "$work"
  cd "$work/binutils-$v"
  mkdir build && cd build
  hardening_export binutils cross
  ../configure \
    --prefix="$TOOLS" \
    --with-sysroot="$LFS" \
    --target="$LFS_TGT" \
    --disable-nls \
    --enable-gprofng=no \
    --disable-werror \
    --enable-default-hash-style=gnu
  make -j"$JOBS"
  make install
  rm -rf "$work"
}

build_gcc_pass1() {
  local v; v=$(jq -r .toolchain.gcc.version "$REPO_ROOT/tools/manifest.json")
  local gv mv mc iv
  gv=$(jq -r .toolchain.gcc_prereqs.gmp.version "$REPO_ROOT/tools/manifest.json")
  mv=$(jq -r .toolchain.gcc_prereqs.mpfr.version "$REPO_ROOT/tools/manifest.json")
  mc=$(jq -r .toolchain.gcc_prereqs.mpc.version "$REPO_ROOT/tools/manifest.json")
  iv=$(jq -r .toolchain.gcc_prereqs.isl.version "$REPO_ROOT/tools/manifest.json")

  local work; work=$(mktemp -d)
  tar -xf "$SOURCES/gcc-$v.tar.xz"  -C "$work"
  cd "$work/gcc-$v"
  tar -xf "$SOURCES/gmp-$gv.tar.xz" && mv "gmp-$gv"  gmp
  tar -xf "$SOURCES/mpfr-$mv.tar.xz" && mv "mpfr-$mv" mpfr
  tar -xf "$SOURCES/mpc-$mc.tar.gz"  && mv "mpc-$mc"  mpc
  tar -xf "$SOURCES/isl-$iv.tar.xz"  && mv "isl-$iv"  isl
  mkdir build && cd build
  hardening_export gcc cross
  ../configure \
    --target="$LFS_TGT" \
    --prefix="$TOOLS" \
    --with-glibc-version="$(jq -r .toolchain.glibc.version "$REPO_ROOT/tools/manifest.json")" \
    --with-sysroot="$LFS" \
    --with-newlib --without-headers \
    --enable-default-pie --enable-default-ssp \
    --disable-nls --disable-shared --disable-multilib \
    --disable-threads --disable-libatomic --disable-libgomp \
    --disable-libquadmath --disable-libssp --disable-libvtv \
    --disable-libstdcxx \
    --enable-languages=c,c++
  make -j"$JOBS"
  make install
  rm -rf "$work"
}

# Cross-toolchain header chain fix: GCC pass1 built --without-headers ships a
# bootstrap include/limits.h with placeholder values (MB_LEN_MAX=1, no PATH_MAX,
# no POSIX symbols at all). Because fixincludes/mkheaders didn't run, the chain
# from <limits.h> through syslimits.h to glibc's limits.h is broken — any caller
# that includes <limits.h> (gnulib-using packages: m4, sed, coreutils, gawk, ...)
# only sees GCC's bootstrap, missing PATH_MAX and tripping glibc's fortified
# <stdlib.h> check `#if defined(MB_LEN_MAX) && MB_LEN_MAX != 16`.
#
# Fix in two parts, applied after gcc-pass1 *and* glibc are both installed:
#   1. Prepend `#define _GCC_LIMITS_H_; #include_next <limits.h>` to GCC's
#      bootstrap include/limits.h. The define stops glibc's limits.h from
#      include_next-ing back to us (which would loop); include_next reaches
#      the chain'd limits.h below.
#   2. Drop a copy of glibc's <limits.h> into include-fixed/. This is what
#      `fixincludes` would have produced and is the next file include_next
#      finds after GCC's include/, giving a clean path into glibc's POSIX
#      and Linux-specific limits (PATH_MAX from bits/posix1_lim.h, etc.).
fix_gcc_limits_chain() {
  local gcc_v; gcc_v=$(jq -r .toolchain.gcc.version "$REPO_ROOT/tools/manifest.json")
  local gcc_inc="$TOOLS/lib/gcc/$LFS_TGT/$gcc_v/include/limits.h"
  local gcc_fixed_dir="$TOOLS/lib/gcc/$LFS_TGT/$gcc_v/include-fixed"
  local glibc_inc="$LFS/usr/include/limits.h"

  [ -f "$gcc_inc" ] || { echo "[cross] WARN: $gcc_inc missing, skip header chain fix"; return 0; }
  [ -f "$glibc_inc" ] || { echo "[cross] WARN: $glibc_inc missing, skip header chain fix"; return 0; }

  if ! grep -q 'gnunix: cross-toolchain header chain fix' "$gcc_inc"; then
    local tmp; tmp=$(mktemp)
    cat > "$tmp" <<'EOF'
/* gnunix: cross-toolchain header chain fix.
   GCC pass1 was --without-headers, so fixincludes never wired this file to
   glibc. Force a single chain hop: define _GCC_LIMITS_H_ (so glibc will not
   include_next back to us) and pull the next limits.h directly. */
#ifndef _GCC_LIMITS_H_
#define _GCC_LIMITS_H_
#include_next <limits.h>
#endif

EOF
    cat "$tmp" "$gcc_inc" > "$gcc_inc.new"
    mv "$gcc_inc.new" "$gcc_inc"
    rm "$tmp"
  fi

  mkdir -p "$gcc_fixed_dir"
  cp "$glibc_inc" "$gcc_fixed_dir/limits.h"
}

install_linux_headers() {
  local v; v=$(jq -r .toolchain.linux_headers.version "$REPO_ROOT/tools/manifest.json")
  local work; work=$(mktemp -d)
  tar -xf "$SOURCES/linux-$v.tar.xz" -C "$work"
  cd "$work/linux-$v"
  make mrproper
  make ARCH=arm64 headers
  find usr/include -name '.*' -delete
  rm usr/include/Makefile
  mkdir -p "$LFS/usr"
  cp -rv usr/include "$LFS/usr"
  rm -rf "$work"
}

build_glibc() {
  local v; v=$(jq -r .toolchain.glibc.version "$REPO_ROOT/tools/manifest.json")
  local work; work=$(mktemp -d)
  tar -xf "$SOURCES/glibc-$v.tar.xz" -C "$work"
  cd "$work/glibc-$v"
  patch -Np1 -i "$REPO_ROOT/images/gnunix-base/patches/glibc-fhs.patch" || true
  mkdir build && cd build
  echo "rootsbindir=/usr/sbin" > configparms
  hardening_export glibc cross
  ../configure \
    --prefix=/usr \
    --host="$LFS_TGT" \
    --build="$(../scripts/config.guess)" \
    --enable-kernel=5.4 \
    --with-headers="$LFS/usr/include" \
    libc_cv_slibdir=/usr/lib
  make -j"$JOBS"
  make DESTDIR="$LFS" install
  rm -rf "$work"
}

build_libstdcxx() {
  local v; v=$(jq -r .toolchain.gcc.version "$REPO_ROOT/tools/manifest.json")
  local work; work=$(mktemp -d)
  tar -xf "$SOURCES/gcc-$v.tar.xz" -C "$work"
  cd "$work/gcc-$v"
  mkdir build && cd build
  hardening_export gcc cross
  ../libstdc++-v3/configure \
    --host="$LFS_TGT" \
    --build="$(../config.guess)" \
    --prefix=/usr \
    --disable-multilib \
    --disable-nls \
    --disable-libstdcxx-pch \
    --with-gxx-include-dir=/tools/$LFS_TGT/include/c++/$v
  make -j"$JOBS"
  make DESTDIR="$LFS" install
  # libstdc++ lands in /usr/lib64 on aarch64. Cleanup is best-effort —
  # newer libstdc++ versions don't generate all .la files.
  rm -fv "$LFS"/usr/lib64/lib{stdc++{,exp,fs},supc++}.la 2>/dev/null || true
  rm -fv "$LFS"/usr/lib/lib{stdc++{,exp,fs},supc++}.la   2>/dev/null || true
  rm -rf "$work"
}

echo "[cross] binutils pass 1";        build_binutils_pass1
echo "[cross] gcc pass 1";             build_gcc_pass1
echo "[cross] linux headers";          install_linux_headers
echo "[cross] glibc";                  build_glibc
echo "[cross] fix gcc limits chain";   fix_gcc_limits_chain
echo "[cross] libstdc++";              build_libstdcxx
echo "[cross] done"

#!/bin/bash
# Stage 2: Temporary tools (cross-compiled, installed into $LFS).
#
# Builds a minimum viable userspace using the cross-toolchain from Stage 1.
# Output goes into $LFS (the future rootfs), not /tools.
# After this stage, $LFS has enough tools to chroot into.
#
# Follows LFS book chapter 6.

set -euo pipefail

REPO_ROOT=${REPO_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}
SOURCES=${LFS}/sources
JOBS=${JOBS:-$(nproc)}
MANIFEST="$REPO_ROOT/tools/manifest.json"

# Compile-time hardening helper (ADR-011). Stage 02 is still cross-compiling
# (toolchain in /tools/bin targets $LFS_TGT), so every package gets the
# "cross" flag set — small/safe; the toolchain has the runtime symbols for
# the full set, but we keep the bootstrap conservative until stage 03b.
. "$REPO_ROOT/images/gnunix-base/lib/hardening.sh"

PKG_VER() { jq -r ".base_packages.\"$1\".version" "$MANIFEST"; }

build_pkg() {
  local name=$1 ver=$2 ext=$3
  shift 3
  local work; work=$(mktemp -d)
  local tarball="$SOURCES/$name-$ver.$ext"
  tar -xf "$tarball" -C "$work"
  cd "$work/$name-$ver"
  # Export CFLAGS/CXXFLAGS/LDFLAGS for this package's build, with per-package
  # exclusions applied (manifest.json:hardening.exclude). Subsequent `bash -c`
  # invocations inherit them as exported env.
  hardening_export "$name" cross
  "$@"
  rm -rf "$work"
}

# usr-merged rootfs layout: create /bin /lib /sbin as symlinks to /usr/...
# BEFORE any package installs. util-linux specifically writes mount/umount/agetty
# into /bin and /sbin (legacy-init-friendly), and if those exist as real dirs
# the install would create files outside the eventual /usr/ tree — and the
# late ln -sv would create a nested /bin/bin symlink instead of the merge.
mkdir -pv "$LFS"/{dev,proc,sys,run,etc,var,usr/{bin,lib,sbin}}
for d in bin lib sbin; do
  [ -L "$LFS/$d" ] || ln -sv "usr/$d" "$LFS/$d"
done
case $(uname -m) in
  aarch64) [ -d "$LFS/lib64" ] || mkdir -v "$LFS/lib64" ;;
esac

# m4
build_pkg m4 "$(PKG_VER m4)" tar.xz \
  bash -c "./configure --prefix=/usr --host=$LFS_TGT --build=\$(build-aux/config.guess) && \
           make -j$JOBS && make DESTDIR=$LFS install"

# ncurses
# Two compat tweaks vs the upstream LFS book recipe:
#
# 1. etip.h.in fix: c++/etip.h.in unconditionally references
#    std::cerr/std::endl/exit/EXIT_FAILURE at lines 368-369 but only
#    includes <iostream>/<iostream.h> behind a HAVE_IOSTREAM gate the
#    configure leaves unset on our toolchain. Newer GCC (14) also dropped
#    the transitive header inclusion older code relied on. Prepend the
#    missing includes to etip.h.in so the generated etip.h has them.
#
# 2. Compat linker scripts for non-widec library names:
#    With --enable-widec --without-normal --with-shared, we only get
#    libfoo*w.so* (libncursesw, libformw, libmenuw, libpanelw). libtinfo
#    is merged into libncursesw because we don't pass --with-termlib.
#    Later packages (util-linux's `ul`, etc.) ask for -ltinfo / -lncurses /
#    -lform / ..., so write GNU ld linker scripts that redirect the
#    unsuffixed names to the widec libraries. libtinfo redirects to
#    -lncursesw since tinfo functions live there.
build_pkg ncurses "$(PKG_VER ncurses)" tar.gz \
  bash -c "{ printf '#include <iostream>\n#include <cstdlib>\n'; cat c++/etip.h.in; } > /tmp/etip.h.in.new && mv /tmp/etip.h.in.new c++/etip.h.in && \
           mkdir build && pushd build && ../configure AWK=gawk && make -C include && make -C progs tic && popd && \
           ./configure --prefix=/usr --host=$LFS_TGT --build=\$(./config.guess) \
             --mandir=/usr/share/man --with-manpage-format=normal --with-shared --without-normal --with-cxx-shared \
             --without-debug --without-ada --disable-stripping --enable-widec AWK=gawk && \
           make -j$JOBS && make DESTDIR=$LFS TIC_PATH=\$(pwd)/build/progs/tic install && \
           for lib in ncurses form panel menu; do \
             rm -f $LFS/usr/lib/lib\$lib.so; \
             echo \"INPUT(-l\${lib}w)\" > $LFS/usr/lib/lib\$lib.so; \
           done && \
           echo 'INPUT(-lncursesw)' > $LFS/usr/lib/libtinfo.so"

# bash
# -sfv (force) lets us re-run the stage cleanly: the sh symlink may already
# exist from a prior pass through temp-tools.
build_pkg bash "$(PKG_VER bash)" tar.gz \
  bash -c "./configure --prefix=/usr --build=\$(sh support/config.guess) --host=$LFS_TGT \
             --without-bash-malloc && make -j$JOBS && make DESTDIR=$LFS install && \
           ln -sfv bash $LFS/usr/bin/sh"

# coreutils
# mv -f / rm on chroot man page same idempotency story: 'make install' puts
# chroot back in /usr/bin and chroot.1 in man1/ each time, and we move them
# again. The man8 page may already exist from a prior pass, hence the rm.
build_pkg coreutils "$(PKG_VER coreutils)" tar.xz \
  bash -c "./configure --prefix=/usr --host=$LFS_TGT --build=\$(build-aux/config.guess) \
             --enable-install-program=hostname --enable-no-install-program=kill,uptime && \
           make -j$JOBS && make DESTDIR=$LFS install && \
           mv -fv $LFS/usr/bin/chroot $LFS/usr/sbin/ && \
           mkdir -pv $LFS/usr/share/man/man8 && \
           rm -f $LFS/usr/share/man/man8/chroot.8 && \
           mv -fv $LFS/usr/share/man/man1/chroot.1 $LFS/usr/share/man/man8/chroot.8 && \
           sed -i 's/\"1\"/\"8\"/' $LFS/usr/share/man/man8/chroot.8"

# diffutils, file, findutils, gawk, grep, gzip, make, patch, sed, tar, xz
for p in diffutils file findutils gawk grep gzip make patch sed tar xz; do
  v=$(jq -r ".base_packages.\"$p\".version // empty" "$MANIFEST")
  [ -z "$v" ] && continue
  ext=$(jq -r ".base_packages.\"$p\".url" "$MANIFEST" | sed 's/.*\.\(tar\.[a-z]*\)$/\1/')
  build_pkg "$p" "$v" "$ext" \
    bash -c "./configure --prefix=/usr --host=$LFS_TGT --build=\$(./build-aux/config.guess 2>/dev/null || ./config.guess) && \
             make -j$JOBS && make DESTDIR=$LFS install"
done

# Strip .la files: libtool archives hard-code absolute paths like
# /usr/lib/libmagic.la, /usr/lib/liblzma.la — correct for the eventual
# rootfs but wrong during cross-compile where everything lives under
# /mnt/lfs/usr/lib. Without removing them, util-linux's libtool link of
# `more`/`logger` errors with "library was moved" or "cannot find ...la".
# Most modern userspace doesn't need .la files for runtime linking anyway.
find "$LFS/usr/lib" -name '*.la' -delete 2>/dev/null || true

# util-linux
build_pkg util-linux "$(PKG_VER util-linux)" tar.xz \
  bash -c "mkdir -pv $LFS/var/lib/hwclock && \
           ./configure ADJTIME_PATH=/var/lib/hwclock/adjtime --libdir=/usr/lib --runstatedir=/run \
             --prefix=/usr --host=$LFS_TGT --build=\$(./config.guess) \
             --without-python --disable-makeinstall-chown --disable-login --disable-nologin \
             --disable-su --disable-setpriv --disable-runuser --disable-pylibmount \
             --disable-static --disable-liblastlog2 --without-systemd --without-systemdsystemunitdir && \
           make -j$JOBS && make DESTDIR=$LFS install"

# binutils-pass2 — LFS book chapter 6.17. Installs native-named tools
# (ar/as/ld/...) into $LFS/usr/bin so the chroot has a working binutils.
# Without this, the chroot only has the cross-prefixed ones in /tools/bin
# and configure can't find `cc`/`as`/`ld`.
# binutils lives in .toolchain.* (not .base_packages.*); PKG_VER would resolve
# to jq's literal "null" string and the tar extraction would look for
# binutils-null.tar.xz. Read directly from .toolchain.
BINUTILS_V=$(jq -r .toolchain.binutils.version "$MANIFEST")
build_pkg binutils "$BINUTILS_V" tar.xz \
  bash -c "sed '6009s/\$add_dir//' -i ltmain.sh && \
           mkdir build && cd build && \
           ../configure --prefix=/usr --build=\$(../config.guess) --host=$LFS_TGT \
             --disable-nls --enable-shared --enable-gprofng=no --disable-werror \
             --enable-64-bit-bfd --enable-new-dtags --enable-default-hash-style=gnu && \
           make -j$JOBS && make DESTDIR=$LFS install && \
           rm -fv $LFS/usr/lib/lib{bfd,ctf,ctf-nobfd,gprofng,opcodes,sframe}.{a,la} 2>/dev/null || true"

# gcc-pass2 — LFS book chapter 6.18. Bundles gcc prereqs (gmp/mpfr/mpc/isl)
# into the gcc tree and cross-compiles a native-targeting gcc into $LFS/usr.
GCC_V=$(jq -r .toolchain.gcc.version "$MANIFEST")
GMP_V=$(jq -r .toolchain.gcc_prereqs.gmp.version "$MANIFEST")
MPFR_V=$(jq -r .toolchain.gcc_prereqs.mpfr.version "$MANIFEST")
MPC_V=$(jq -r .toolchain.gcc_prereqs.mpc.version "$MANIFEST")
ISL_V=$(jq -r .toolchain.gcc_prereqs.isl.version "$MANIFEST")
build_pkg gcc "$GCC_V" tar.xz \
  bash -c "tar -xf $SOURCES/mpfr-$MPFR_V.tar.xz && mv mpfr-$MPFR_V mpfr && \
           tar -xf $SOURCES/gmp-$GMP_V.tar.xz  && mv gmp-$GMP_V  gmp && \
           tar -xf $SOURCES/mpc-$MPC_V.tar.gz  && mv mpc-$MPC_V  mpc && \
           tar -xf $SOURCES/isl-$ISL_V.tar.xz  && mv isl-$ISL_V  isl && \
           case \$(uname -m) in aarch64) sed -e '/lp64=/s@lib64@lib@' -i.orig gcc/config/aarch64/t-aarch64-linux ;; esac && \
           mkdir build && cd build && \
           ../configure --build=\$(../config.guess) --host=$LFS_TGT --target=$LFS_TGT \
             LDFLAGS_FOR_TARGET=-L\$PWD/$LFS_TGT/libgcc \
             --prefix=/usr --with-build-sysroot=$LFS \
             --enable-default-pie --enable-default-ssp \
             --disable-nls --disable-multilib --disable-libatomic --disable-libgomp \
             --disable-libquadmath --disable-libsanitizer --disable-libssp --disable-libvtv \
             --enable-languages=c,c++ && \
           make -j$JOBS && make DESTDIR=$LFS install && \
           ln -sfv gcc $LFS/usr/bin/cc"

echo "[temp-tools] complete; preparing chroot environment"

# rootfs layout was already set up at the top of this stage (so util-linux's
# install lands inside the usr-merged tree). Just create the chroot-only bits.

# Minimal /etc files for chroot
[ -f "$LFS/etc/passwd" ] || cat > "$LFS/etc/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/bash
EOF
[ -f "$LFS/etc/group" ] || cat > "$LFS/etc/group" <<'EOF'
root:x:0:
EOF
mkdir -pv $LFS/{var/log,root}
touch $LFS/var/log/{btmp,lastlog,faillog,wtmp}
chmod -v 664 $LFS/var/log/lastlog
chmod -v 600 $LFS/var/log/btmp

echo "[temp-tools] done"

# The one shape every GNUnix system profile has.
#
# `nix-env --profile <p> --set <drv>` points a profile at a single derivation,
# so each profile must be one closure that already looks like a /usr tree.
# pathsToLink is shared here because the image's PATH, LD_LIBRARY_PATH and
# dbus/xkb data lookups (images/*/build.sh) assume every profile links the
# same subtrees.
#
# "/sbin" joined the list with issue #161. nixpkgs does not normalise
# sbin into bin, and plain-autotools daemons honour the GNU default of
# $prefix/sbin: sysklogd and cronie (nix/minimal.nix) both build with
# nothing but --sysconfdir and --localstatedir set, so syslogd, klogd and
# crond install to $out/sbin. Without this entry buildEnv silently drops
# them and the profile looks fine while containing no daemon at all.
pkgs: name: paths:

pkgs.buildEnv {
  inherit name paths;
  pathsToLink = [ "/bin" "/sbin" "/lib" "/share" "/etc" "/libexec" ];
}

# The one shape every GNUnix system profile has.
#
# `nix-env --profile <p> --set <drv>` points a profile at a single derivation,
# so each profile must be one closure that already looks like a /usr tree.
# pathsToLink is shared here because the image's PATH, LD_LIBRARY_PATH and
# dbus/xkb data lookups (images/*/build.sh) assume every profile links the
# same five subtrees.
pkgs: name: paths:

pkgs.buildEnv {
  inherit name paths;
  pathsToLink = [ "/bin" "/lib" "/share" "/etc" "/libexec" ];
}

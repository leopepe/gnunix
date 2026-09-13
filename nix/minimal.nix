# gnunix-minimal system packages.
#
# ADR-003 gives this image a working multi-user Nix on top of the LFS base.
# ADR-025 makes this file the declaration of what else it ships, and issue
# #161 is why the list is no longer empty: these packages were compiled into
# gnunix-base, where a CVE in any of them means rebuilding the LFS chroot
# stage and re-cutting a base release. Declared here, the same CVE is a
# flake.lock bump and one profile rebuild.
#
# The rule for what belongs here: userland the RUNNING system wants, that
# nothing in the boot path needs before /nix exists. Everything the base
# must keep — shadow and libxcrypt (login/su/passwd, and the groupadd and
# useradd that create nixbld1..32 before Nix is installed), openssh, eudev,
# kmod, sysvinit, util-linux, e2fsprogs, grub, iproute2, dhcpcd — stays
# compiled from source in tools/manifest.json per ADR-007.
#
# No systemd unit and no NixOS module reaches this list: ADR-001. The
# services below are still started by BSD /etc/rc.d scripts, which exec
# them by absolute path out of the system profile.
pkgs:

with pkgs; [
  # Logging and scheduling. rc.syslogd and rc.crond resolve these out of
  # /nix/var/nix/profiles/system; see images/gnunix-base/etc/rc.d/.
  # logrotate's popt build-dep is nixpkgs' problem now, not the manifest's.
  sysklogd
  cronie
  logrotate

  # Process inspection. procps is already in nix/desktop.nix, so before
  # this change the desktop image carried two builds of it — one compiled
  # into the base and one from the store.
  procps
  psmisc

  # Hardware introspection. Removed from the base in #162 precisely so
  # they could land here instead.
  pciutils
  usbutils
  dmidecode
]

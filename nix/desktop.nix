# gnunix-desktop system packages — the Wayland substrate, nothing above it.
# ADR-002 (elogind), ADR-009 (compositor + greeter + system services),
# ADR-020 (Hyprland is the reference session, not the only one).
#
# No systemd and no NixOS modules reach this list: ADR-001.
pkgs:

with pkgs; [
  dbus
  elogind
  greetd
  tuigreet
  hyprland
  xdg-desktop-portal-hyprland
  hyprpaper
  foot
  wayland-utils
  xkeyboard_config
  procps
  kmod
  mesa
  waybar
]

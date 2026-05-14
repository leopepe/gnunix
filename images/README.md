# IMAGES

The images are generated in phases, from the builder -> base -> minimal -> desktop.

- **Builder:** The builder is the base image from which all other images are built.
- **Base:** The base image is a Linux From Scratch (LFS) base image.
- **Minimal:** The minimal image is a lightweight image with the Nix package manager installed.
- **Desktop:** A Wayland-based desktop image.

## Platforms

- **aarch64:** A 64-bit ARM platform.
- **x86_64:** A 64-bit x86 platform.

## Desktop Environments

GNUnix supports only Wayland-based desktop environments.

- **Sway:**
- **Hyprland:**
- **labwc:**

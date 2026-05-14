# `/etc/modules-load.d/` overlays

Per ADR-012, the kernel is module-first: most non-boot-critical drivers
are `=m` and eudev's MODALIAS autoload covers everything that surfaces
under `/sys` at boot.

This directory holds the explicit-load fallbacks for cases eudev can't see:

- Modules with **no MODALIAS** (most network tunnel / `dummy` / `nf_*`
  modules).
- Modules needed **before a corresponding device exists** in `/sys`
  (rare on us; common on dynamic-hotplug setups).
- **Per-platform overlays** for variants under `images/variants/<name>/`
  — e.g., a Raspberry Pi `rpi-native` variant ships its own
  `rpi-firmware.conf` here to load `bcm2835_dma` early.

## File format

One module name per line. Lines starting with `#` and blank lines are
ignored. `rc.modules` runs `modprobe -ab <name>` for each entry — `-a`
keeps going across the list, `-b` obeys the blacklist.

```
# /etc/modules-load.d/nf-tunnels.conf
ipip
gre
```

## Default

Empty in `lfs-core`. Variants add their own files at packaging time.

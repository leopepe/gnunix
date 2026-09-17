# Extend security scan to flake profiles

Extend `tools/security-scan.sh` to include packages declared in the flake's profiles (`nix/minimal.nix`, `nix/desktop.nix`, `nix/installer.nix`) rather than only `tools/manifest.json`. Derive `(name, version)` from store paths; keep the manifest path intact; teach unmapped names to warn with `skip` instead of hard-failing so the scan can report partial coverage to durable issue #151.

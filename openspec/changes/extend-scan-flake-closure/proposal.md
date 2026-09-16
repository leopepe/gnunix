# Propose: extend-scan-flake-closure (revised after Phase 3 contrarian — CONTESTED -> revised)

## Change
Extend security-scan to flake profile closures via `nix path-info --recursive --json` over declared profile output paths. Scope = full recursive store-path closure of the profile output (operational; nix has no native build-vs-runtime filter). Unmapped paths restore original hard-fail contract; skip+warning reserved for explicit `skip` entries. Durable issue #151 retained for CPE-mapped CVE findings only.

## Key design decisions (revised)
1. Scan flake closures via `nix path-info --recursive --json` on profile output paths.
2. Scope = profile output paths + their full store-path recursive closure (operational definition; build-only inputs unreferenced by profile output are naturally excluded).
3. Unmapped paths (no CPE, no explicit skip) = hard-fail with non-zero exit + stderr reason (original spec contract). Skip + warning only for explicit skip entries.
4. #151 retained for CVE findings only; profile-closure unmapped/skipped paths emit warnings, not issues.

## Scope
Profile paths declared in the flake (desktopProfile, installerProfile, minimalProfile, installerBuildTools). Operational scope defined by profile-output references.

## Non-goals
No change to NVD query / CPE mapping logic. No split of durable reporting mechanism.

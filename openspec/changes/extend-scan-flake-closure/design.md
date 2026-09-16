# Design: extend-scan-flake-closure (revised after Phase 3 contrarian)

## Approach
- Use `nix path-info --recursive --json` over each profile's declared store paths. Nix has no native `--runtime-only` filter at store-path level; the operational scope is the full recursive store-path closure of the declared profile output (i.e., everything the profile output references). The previous "runtime only, not build-time" claim is withdrawn: the filter is the profile's declared paths, not a build-vs-runtime distinction.
- Unmapped store-path names (no CPE mapping, no explicit `skip` entry): restore original spec contract — hard-fail with non-zero exit and one-line stderr reason. Skip + warning applies ONLY to paths with an explicit `skip` entry (original spec already supports this).
- Profile-closure findings are detection outputs; they feed #151 ONLY when they resolve to CPE-mapped CVE findings. Unmapped or skipped paths emit warnings and do not create issues.

## Scope boundary
Declared profile output paths + their full `nix path-info --recursive --json` store closure (operational definition; no separate build-time exclusion mechanism exists). Build-only derivation inputs that are not referenced by the profile output are naturally excluded by `nix path-info --recursive` over the profile output.

## Issue tracking
Durable CVE reporting (#151) is unchanged. This change extends the scan surface; it does not alter the durable-issue mechanism. Profile-closure results that resolve to mapped CVEs feed #151; unmapped/skipped paths do not.

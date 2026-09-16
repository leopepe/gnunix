# security-scan Specification (delta for extend-scan-flake-closure)

## Delta changes

### Closure scanning extension
The scan SHALL also evaluate declared profile paths using `nix path-info --recursive --json`. The evaluated closure SHALL be the full `nix path-info --recursive --json` store-path closure of each declared profile output path. Nix provides no native build-time exclusion filter at store-path level; the profile output's references define the operational boundary.

### Unmapped store-path behavior
Store-path names with an explicit `skip` entry SHALL be skipped with a warning emitted to stderr; the scan SHALL continue. Store-path names with no CPE mapping and no explicit `skip` entry SHALL fail the scan with a non-zero exit code and a one-line reason on stderr (restoring the original spec contract).

### Issue durability
Only single durable issue #151 SHALL be retained. No duplicate issues SHALL be created for this change.

All other requirements (threshold, rate limits, retry, dedup, manifest-change trigger, clean-run behavior, failure behavior) remain unchanged.

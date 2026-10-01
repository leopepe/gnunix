## Why

Issue #168 identifies a detection gap: `tools/security-scan.sh` queries manifest pins but not the locked Nix outputs consumed by image assembly. Zero reported CVEs currently conceals missing identity/CPE coverage, and the durable report's CVE-ID-only fingerprint conceals package/version changes.

## What Changes

- Extend, rather than replace, the existing manifest/CPE/NVD scanner with recursive output-reference inventory for `minimalProfile`, `desktopProfile`, `installerProfile` (system runtime), `installerBuildTools` (actually copied installer-image build payload), and `initramfsBusybox` (separately staged initramfs binary).
- Resolve declared package identities from evaluated output associations or verified deriver metadata; retain unresolved paths as unknown instead of parsing store basenames. Keep runtime references separate from derivation build inputs.
- Emit validated findings and per-root enumeration/identity/CPE coverage through an exact v1 wire grammar. Scanner and report independently compare manifest rows with trusted checkout manifest/map side inputs and consume one exclusively owned future shared valid/negative corpus. Incomplete zero-findings runs remain visibly incomplete, not clean.
- Preserve stable-title durable report #151, refreshing meaningful identity/version/inventory/coverage changes without heartbeat writes. Reject invalid NVD responses and malformed report input before issue mutation.
- Bound hosted arm64 CI acquisition/query work using existing manifest-pinned Nix setup, locked evaluation and substitution-only acquisition; expand declaration/scanner/map push triggers. Offline fixtures and mocked report APIs provide the implementation validation seam.
- Preserve manifest-map hard failure, explicit skips, effective-version-before-version-map semantics (ADR-023), CVSS >= 7 with v3.1 → v3.0 → v4 precedence, retries/pacing and detection-only behavior.

## Capabilities

### New Capabilities

None; this extends the existing scanner.

### Modified Capabilities

- `security-scan`: add scoped Nix inventory and incomplete coverage, strengthen input validity, expand triggers and reconcile the main spec's per-CVE reporting with actual durable-report behavior.

## Impact

Implementation targets are `tools/security-scan.sh`, focused scanner helpers under `tools/`, a read-only metadata projection under `nix/`, `.github/workflows/security-scan.yml`, and offline validators/fixtures under `scripts/` and `tests/security-scan/`. Reuse `tools/cpe-map.json` without inventing mappings; missing Nix mappings remain explicit incomplete coverage. No new dependency, pin bump, image/init edits, remediation, SBOM pipeline, user-package scan, ADR amendment or unrelated active-change edit is authorized.

The five roots describe locked-flake CI declarations and actual copy/stage surfaces, not every installed target, non-CI channel path, or arbitrary user package. ADR-025's never-copied build-tools statement conflicts with actual `OUT_TOOLS` copying; design records the discrepancy without changing either. The active `cve-hotfix-pipeline` timestamped-report delta is left unchanged and its competing policy is recorded. Nix is absent locally; runtime CLI compatibility, substitution cost and completeness are residual owner gates, not performed validation. F2 remains an explicit unproven operational-usefulness risk: custom wrappers may be unavailable and the unchanged map misses the named declaration identities noted in design.md; durable coverage honesty does not demonstrate that the Nix detection gap is closed. F3's planned offline validation must force real inert-process/watchdog cleanup and shared/clipped deadline and retry/pacing exhaustion, without raising frozen budgets; 200 queries is a ceiling, not an attainable-runtime guarantee.

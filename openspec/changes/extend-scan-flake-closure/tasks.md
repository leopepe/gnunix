# Tasks: extend-scan-flake-closure (revised)

## 1. Add flake-closure scanner
      depends-on: none
      touches: tools/security-scan.sh, openspec/changes/extend-scan-flake-closure/design.md
      - Use `nix path-info --recursive --json` on declared profile output paths; scope = full store-path recursive closure.

## 2. Restore hard-fail for unmapped paths
      depends-on: 1
      touches: openspec/changes/extend-scan-flake-closure/specs/security-scan/spec.md, openspec/changes/extend-scan-flake-closure/proposal.md
      - Explicit `skip` entries -> skip + warning (continue). Unmapped (no CPE, no skip) -> hard-fail, non-zero, stderr reason.

## 3. Clarify durable-issue scope
      depends-on: 2
      touches: openspec/changes/extend-scan-flake-closure/proposal.md
      - #151 retained for CPE-mapped CVE findings only; profile-closure unmapped/skipped paths emit warnings, not issues.

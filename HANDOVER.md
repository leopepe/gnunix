# Handover

> Last updated: 2026-09-04T17:35:00Z
> Session summary: CVE-scan pipeline for GNUnix image rebuilds — OSV.dev prototype proven wrong, NVD validated as replacement; conductor takes over from here.

## Decisions

- **NVD API 2.0 is the primary CVE source (not OSV.dev)**: OSV `/v1/query` with upstream versions returns only distro-tracker records (UBUNTU-CVE-*, DEBIAN-CVE-*, ALPINE-*, RHSA-* ...) whose version ranges use distro schemes — 364 false hits for patched openssh 9.9p1, 144 for glibc 2.40. Canonical CVE records on OSV carry CPE/GIT ranges that version queries never match. NVD `virtualMatchString=cpe:2.3:a:<vendor>:<product>:<version>` does authoritative server-side version-range matching: openssh 9.9p1 → 2 real CVEs (regreSSHion correctly excluded), openssl 3.3.2 → 17 CVEs with proper CVSS data.
- **CVSS >= 7.0 (HIGH/CRITICAL) is the trigger threshold**: LOW/MEDIUM excluded to avoid alert fatigue on a distro that rebuilds in hours.
- **Curated package→CPE map (`tools/cpe-map.json`)**: NVD CPE naming is vendor-specific and cannot be derived mechanically. ~66 manifest packages map to `vendor:product` (+ optional version-format quirks like openssh `9.9p1` → `9.9:p1`). Packages with no sensible CPE are skipped with a warning. First batch of 24 validated against NVD (glibc, perl, python, vim, binutils, gcc, coreutils, tar, xz, zlib, expat, util-linux, dhcpcd, iputils-adjacent...).
- **Rate limiting**: unauthenticated NVD = 5 req/30s → sequential queries with ~7s sleep (66 packages ≈ 8 min, fine for a daily cron). Optional `NVD_API_KEY` secret raises to 50 req/30s → 1s sleep. Script must handle 503s with retry/backoff (NVD is flaky).
- **Trigger chain**: findings → deduplicated GitHub issue (labels `security`, `auto-triggered`; title-based dedup) → `gh workflow run build.yml -f images=gnunix-base,gnunix-minimal,gnunix-desktop`. Both already wired in `.github/workflows/security-scan.yml` (needs NVD tweaks: timeout 15min, permissions). **Superseded by `add-cve-scan-pipeline`**: the rebuild dispatch was removed (a rebuild from unchanged pins emits a bit-identical vulnerable image); the scan is detection + alerting only, runs additionally on pushes that modify `tools/manifest.json`, and remediation flows through Renovate pin bump → merge → v* tag → build.yml.
- **`tools/cvss3-score.py` is deleted**: NVD returns official `baseScore`/`baseSeverity` directly — no local CVSS vector math needed.
- **Kernel CVE coverage gap is a documented limitation**: NVD kernel CVE ingestion is incomplete; kernel updates keep flowing through Renovate + `kernel.org` releases. A kernel.org-specific feed is future work, out of scope here.
- **Shell code follows the kwb shell style guide** (`~/Workspace/kwb/wiki/shell-style-guide/guidelines.md`): bash, functions + `main "$@"`, `[[ ]]`, quoted `"${var}"`, 80-col, errors to stderr, ShellCheck-clean, PIPESTATUS/pipefail for pipelines.

## Open Questions

- **Remaining CPE validation (low risk)**: ~40 packages not yet validated against NVD. Some legitimately have no CVE history (grep, sed, gawk at recent versions); others may need vendor/product correction (shadow, file, less, sysvinit, eudev, cronie...). Validate during implementation; unmapped packages are skipped with a warning, never silently dropped.
- **Scan failure policy (assumed, confirm in review)**: transient NVD failures after retries → CI job fails loudly (visible in Actions), no issue spam. Persistent failures are a human problem.
- **openssh version format**: confirm `9.9:p1` split form matches (validated: yes, returned 2 CVEs).

## Tasks Completed

- OSV.dev prototype working end-to-end (package extraction from `tools/manifest.json`, per-package query, CVSS filtering, `GITHUB_OUTPUT`/`GITHUB_ENV` wiring) — to be replaced, but the manifest-extraction jq and the workflow/issue wiring are reusable.
- `.github/workflows/security-scan.yml` created (daily 06:00 UTC cron + workflow_dispatch; issue dedup; build trigger). Validated with actionlint.
- `auto-triggered` label added to `.github/labels.yml`.
- NVD approach validated: endpoint, response shape (`.metrics.cvssMetricV31[].cvssData`, `.configurations[].nodes[].cpeMatch[]`), rate limits, CPE batch validation (24 packages).
- Root cause of OSV false positives identified and documented (distro-tracker records, empty ecosystem matching).

## Tasks Remaining

1. Create `tools/cpe-map.json`: manifest package name → CPE vendor:product (+ version-format overrides); validate remaining packages against NVD.
2. Rewrite `tools/security-scan.sh` for NVD: CPE map lookup, per-package `virtualMatchString` query with retry/backoff + rate-limit sleep, severity filter >= 7.0, dedup, stdout summary, `GITHUB_OUTPUT`/`GITHUB_ENV` wiring, kwb shell-style compliance.
3. Delete `tools/cvss3-score.py` (superseded).
4. Update `.github/workflows/security-scan.yml`: timeout 10→15 min, optional `NVD_API_KEY` env passthrough, header comments.
5. Local end-to-end test: clean run (current pins) + forced-finding run (temporarily pin a vulnerable version, e.g. openssl 1.1.0) proving issue-body generation.
6. Verify workflow with actionlint; run ShellCheck on the script.

## Outcome (2026-09-04T20:05Z — lifecycle COMPLETE)

Change add-cve-scan-pipeline archived to openspec/changes/archive/2026-09-04-add-cve-scan-pipeline/; capability spec synced to openspec/specs/security-scan/spec.md (6 requirements, 15 scenarios). Shipped (all untracked/uncommitted): tools/security-scan.sh (NVD 2.0, FINDINGS_TSV contract, per-CVE issues, state:'all' dedup, 429/503/000 retry, V31→V30→V40 fallback, drift hard-fail, version_map staleness warning), tools/cpe-map.json (64 entries + kernel/linux_headers audit skips), .github/workflows/security-scan.yml (daily 06:00 + push on tools/manifest.json + dispatch; NO rebuild trigger), .github/labels.yml (+auto-triggered); tools/cvss3-score.py deleted. Gates green: shellcheck, actionlint, jq, openspec validate --strict, live NVD scans. OPERATIONAL ALERT: current pins carry 63 CVSS>=7 findings (glibc 2.40 CVE-2026-5450 9.8, openssl 3.3.2 CVE-2026-31789 9.8, perl 5.38.2 x2 @9.8, nix 2.24.10 9.0, vim x14, python 3.12.5 x9...) — first CI run will open them as issues; remediate via Renovate bump → v* tag → build.yml. Next: commit the files, add NVD_API_KEY repo secret (free, ~6x faster scans).

## MODIFIED Requirements

### Requirement: Scheduled scan runs

The system SHALL retain daily scanning at 06:00 UTC and manual dispatch. The manifest scan set SHALL comprise version-carrying entries of `.toolchain` (including `gcc_prereqs`: gmp, mpfr, mpc, isl), `.base_packages`, `.init_and_session`, `.bootloader`, and `.nix.binary_version`, filtering `$`-prefixed metadata keys. Kernel and linux_headers SHALL retain their explicit documented exclusions and CPE-map skip reasons. Manifest queries SHALL use `effective_version` when present, otherwise the pinned version, before applying the curated CPE map's version conversion. A manifest package lacking a mapping or explicit reasoned skip SHALL fail the scan. Explicit skips SHALL warn and SHALL NOT be queried. Version-map misses SHALL preserve the existing raw-version warning behavior.

In addition, each run SHALL attempt the five locked `aarch64-linux` output-reference roots: minimalProfile, desktopProfile, installerProfile (system runtime), installerBuildTools (copied installer-image build payload), and initramfsBusybox (separately staged initramfs binary). This inventory SHALL NOT be described as every installed target, local channel-based build, or user-installed package. Enumeration, identity and CPE gaps SHALL be reported as incomplete coverage rather than silently omitted. Queries SHALL preserve sequential pacing (approximately 7 seconds without an API key, 1 second keyed), and HTTP 000/429/503 retry/backoff with at most three attempts. Exact repeated CPE/version queries SHALL be deduplicated while retaining affected identity and provenance associations.

#### Scenario: Daily run scans all mapped packages
- **WHEN** a scheduled run has valid mapped manifest packages and Nix inventory
- **THEN** manifest packages are queried, repeated exact CPE/version queries are shared, and the five Nix roots have explicit coverage records

#### Scenario: Unmapped package fails the scan
- **WHEN** a manifest scan-set package has neither a CPE mapping nor an explicit skip
- **THEN** the scan exits non-zero naming the package and performs no report mutation

#### Scenario: Skipped package warns and continues
- **WHEN** a manifest package has an explicit skip with a reason
- **THEN** its warning and exclusion appear in the scan summary and it is not queried

#### Scenario: Effective version precedes conversion
- **WHEN** a manifest entry has an effective version and a matching curated version conversion
- **THEN** the query uses the converted effective version instead of the upstream pinned version

#### Scenario: Legacy display versions remain compatible
- **WHEN** trusted OpenSSH declared/display version 9.9p1 converts to queried version 9.9:p1
- **THEN** JSON finding version is 9.9:p1, legacy six-column TSV keeps pre-conversion display version 9.9p1 and existing manifest ordering/deduplication, and compatibility assertions reject deriving the TSV version from JSON finding version

#### Scenario: Transient NVD outage is retried
- **WHEN** an NVD query returns HTTP 503
- **THEN** it is retried with bounded backoff and the existing pacing is retained

### Requirement: Issue creation with deduplication

The system SHALL maintain one durable report identified by the stable title `CVE Report — open HIGH/CRITICAL findings` and labels `security` and `auto-triggered`, preserving the existing #151 rather than switching to per-CVE or timestamped issues. The report SHALL contain findings with CVE, package, queried version, official score/severity, reference, source/root provenance, and an independent coverage section. It SHALL distinguish declared-output inventory from whole-image assurance and identify unknown paths, missing roots, unmapped identities, explicit skips and unqueried budget-limited entries.

When findings exist or coverage is incomplete, the system SHALL create the durable report if absent, update it if meaningful state changes, or reopen the same closed report. Issue discovery SHALL consider open and closed history with pagination and SHALL fail without mutations when duplicate stable-title candidates are ambiguous. A canonical fingerprint SHALL include inventory paths, package/version/output and provenance associations, coverage/reasons, and finding data; run timestamps and ordering SHALL NOT cause heartbeat updates. Identical meaningful state SHALL cause no issue writes. Changes with unchanged CVE IDs but changed versions, inventory, scores or coverage SHALL refresh the report. Remediation guidance SHALL distinguish manifest changes from locked Nix package-set changes without changing pins itself.

#### Scenario: New finding opens an issue
- **WHEN** a validated run has findings and no stable-title durable issue exists in open or closed history
- **THEN** one labeled durable issue is created with finding and coverage data instead of per-CVE or timestamped reports

#### Scenario: Duplicate finding does not create a second issue
- **WHEN** a validated run has findings and #151 already matches the stable title/labels
- **THEN** #151 is updated as needed and no duplicate, per-CVE or timestamped report is created

#### Scenario: Closed report is reused
- **WHEN** findings or incomplete coverage recur and the durable report is closed
- **THEN** the same issue is reopened instead of creating a duplicate

#### Scenario: Unchanged state is quiet
- **WHEN** the canonical finding/inventory/coverage state matches the durable report
- **THEN** no update, comment, creation or closure API is called

#### Scenario: Version-only delta is visible
- **WHEN** affected versions change while CVE IDs remain identical
- **THEN** the report body and fingerprint change and the delta is described

#### Scenario: Incomplete zero findings reaches the report
- **WHEN** a valid run has zero HIGH/CRITICAL findings but an unmapped Nix identity or missing root
- **THEN** the durable issue remains open or is created/reopened with explicit incomplete coverage and no clean/closing message

### Requirement: Manifest-change trigger

The existing workflow SHALL retain daily/manual entrypoints and trigger on pushes modifying tools/manifest.json, flake.nix, flake.lock, the nix/ declarations/projection, scanner/report helper implementation, tools/cpe-map.json, or the security-scan workflow. The triggered scan SHALL use the same coverage, threshold and durable-report contract and SHALL NOT trigger an image rebuild. Unrelated pushes SHALL NOT trigger the path-filtered scan.

#### Scenario: Pin bump triggers a scan
- **WHEN** a push modifies tools/manifest.json, flake.lock or a profile declaration
- **THEN** the security scan runs against that checkout without starting an image build

#### Scenario: Scanner policy changes trigger a scan
- **WHEN** a push modifies the CPE map, scanner/report helper or security-scan workflow
- **THEN** the same scan/report contract runs

#### Scenario: Non-manifest push does not trigger a scan
- **WHEN** a push does not modify tools/manifest.json or any additional declared scan input/implementation path
- **THEN** neither the manifest-change trigger nor another configured path trigger runs the security scan

### Requirement: Silent no-op when clean

A zero-findings run SHALL be called clean only for the configured scope when each required Nix root is enumerated and each runtime entry is resolved and queried or positively identified as a supported generated profile wrapper. Known manifest exclusions SHALL remain stated; a clean result SHALL NOT imply whole-image or arbitrary-user coverage. A complete zero-findings run SHALL exit successfully, create no issue, and close an existing open durable report with a scope-qualified summary. An incomplete zero-findings run SHALL publish incomplete coverage, exit non-zero after report synchronization, and SHALL NOT close a report or emit a clean claim.

#### Scenario: Complete zero findings closes an existing report
- **WHEN** a validated complete run returns no findings and an open durable report exists
- **THEN** the report is closed with a configured-scope summary and no new issue is created

#### Scenario: Clean run produces no side effects
- **WHEN** a validated complete zero-findings run has no open durable report
- **THEN** no issue is created or commented on and the run exits successfully

#### Scenario: Missing metadata is not clean
- **WHEN** zero CVEs are found but a runtime path lacks trusted name/version metadata
- **THEN** coverage is incomplete, the job exits non-zero after publishing coverage, and no close or clean message is emitted

### Requirement: Failure behavior

Fatal errors (invalid manifest/map configuration, unrecoverable manifest query failure, malformed NVD response, unexpected script error, or invalid report input) SHALL produce non-zero failure and SHALL NOT create, update, reopen, close or comment on the durable report. The system SHALL validate NVD response shape, pagination and vulnerability records rather than accepting syntactically valid JSON as proof of zero results. Unsupported/truncated pagination SHALL fail. Scoreless valid CVEs SHALL retain the existing dropped-count behavior; malformed scored records SHALL NOT be silently dropped into a zero-findings result. Scanner and report boundaries SHALL independently enforce the exact v1 grammar and invariants in design.md §3 using separately loaded trusted checkout manifest/CPE-map side inputs. They SHALL reject missing/extra/duplicate expected manifest rows even if supplied counts/outcome match surviving rows, duplicate roots/paths, missing nested fields, orphan finding associations, declared-versus-converted query/finding version mismatch, missing/invalid coverage, contradictory counts/states, malformed finding rows and unrecognized schema versions before mutation. Missing/invalid trusted side inputs SHALL fail closed. Producer-supplied expected counts/booleans SHALL NOT replace independently derived expected-set equality.

Recoverable Nix acquisition/enumeration/identity/mapping/query-budget gaps SHALL instead produce a validated incomplete result eligible for durable coverage synchronization, followed by a non-zero job result. NVD transport/schema failures SHALL remain fatal even when Nix coverage is already incomplete.

#### Scenario: Persistent NVD failure fails the job loudly
- **WHEN** an NVD query exhausts the retry budget
- **THEN** the job fails with an error and no issue mutation occurs

#### Scenario: Script error fails the job
- **WHEN** the scanner encounters an unexpected script error
- **THEN** it exits non-zero without a publishable result and no issue mutation occurs

#### Scenario: HTTP 200 empty object is invalid
- **WHEN** an NVD HTTP 200 body is `{}` instead of the required response schema
- **THEN** it fails validation and is not interpreted as zero CVEs

#### Scenario: Malformed finding cannot close a report
- **WHEN** report input contains an invalid finding row, absent coverage, or inconsistent declared counts
- **THEN** synchronization fails before any GitHub write and no clean closure occurs

#### Scenario: Omitted manifest row cannot validate complete
- **WHEN** a result omits an independently expected manifest row and adjusts every supplied count and outcome to match the surviving records
- **THEN** both actual validators reject it and no create, update, reopen, close or comment API is called

#### Scenario: Converted query versions bind findings
- **WHEN** trusted OpenSSH declaration 9.9p1 maps to queried version 9.9:p1 but result query/finding version uses 9.9p1
- **THEN** both actual validators reject the version mismatch before any GitHub write

#### Scenario: Nix coverage loss remains publishable
- **WHEN** Nix enumeration fails for one root but manifest/NVD processing completes validly
- **THEN** the valid incomplete coverage result is synchronized and the job subsequently fails visibly

## ADDED Requirements

### Requirement: Trusted runtime identity and normalization

Inventory SHALL follow recursive references from selected output paths, not derivation inputDrvs/inputSrcs. Full store paths SHALL be retained through strict keyed-object normalization, including failed/null records and missing references. Unsupported shapes SHALL NOT become empty inventories. Names and versions SHALL be obtained from explicit evaluated output associations or verified derivation metadata associated with the runtime output. Missing, null, conflicting or unavailable metadata SHALL remain unknown; store basenames and derivation names SHALL NOT be authoritative package identity. Generated profile wrapper classification SHALL require a selected root association, not a name heuristic. Exact identity/version query deduplication SHALL preserve distinct versions, output paths and root memberships, including static versus dynamic BusyBox.

#### Scenario: Keyed pinned-family response preserves paths
- **WHEN** path-info returns a full-path-keyed object with references and a null record
- **THEN** the keys identify paths, the null record is retained as an enumeration gap, and coverage is incomplete

#### Scenario: Deriver absence stays unknown
- **WHEN** a referenced runtime path has a null or unavailable deriver and no evaluated identity association
- **THEN** it remains in inventory as unknown and its basename is not used to construct a CPE query

#### Scenario: Build inputs do not expand runtime scope
- **WHEN** derivation metadata lists an input-only compiler/source not present in recursive output references
- **THEN** that input is absent from runtime inventory and receives no NVD query solely because of that build edge

#### Scenario: Versions and staged surfaces are retained
- **WHEN** fixtures contain a shared same-version package, a second version, dynamic build-tool BusyBox and static initramfs BusyBox
- **THEN** shared queries are deduplicated without losing provenance, versions stay distinct, and both BusyBox output surfaces remain represented

### Requirement: Bounded acquisition and offline validation

Production inventory acquisition SHALL use the repository's manifest-pinned Nix binary version/URL/checksum and hosted arm64 setup norm without floating installers, lock changes or local source builds. Evaluation, substitution-only acquisition and queries SHALL preserve the shared 600-second acquisition and 1200-second NVD deadlines, subprocess/request maxima of 120/60 seconds clipped to remaining time, 200 unique Nix-query ceiling and 35-minute job limit; 200 SHALL NOT be represented as attainable-runtime capacity. Pacing/backoff/retries SHALL count toward the shared NVD deadline, and no next operation SHALL start after exhaustion. These explicit shared time/query budgets SHALL NOT reset per root/query; unavailable outputs and exhausted Nix budgets SHALL produce per-root/entry incomplete coverage. Operational inability to acquire inventory SHALL NOT silently disable Nix scanning. Offline fixture-backed scanner and mocked report tests SHALL run without installing Nix, realizing outputs, contacting NVD/GitHub, booting images, or introducing a test framework.

#### Scenario: Missing substitutions are bounded
- **WHEN** an output cannot be acquired from available substitutions within the configured acquisition budget
- **THEN** the root is recorded incomplete without initiating a source build or changing pins

#### Scenario: Query budget exhaustion is visible
- **WHEN** the bounded query budget is reached before mapped Nix queries complete
- **THEN** unqueried identities are recorded incomplete and a zero-findings run does not close the report

#### Scenario: Deadline enforcement interrupts a blocked process
- **WHEN** a bounded local inert parent/child blocks through the production watchdog and its test-controlled deadline expires
- **THEN** the full process tree is terminated and reaped before publication, no later operation starts, and no child or watchdog is left behind

#### Scenario: Shared deadlines and retry pacing are exhausted
- **WHEN** deterministic scenarios exhaust the shared acquisition/NVD deadlines, clip the remaining allowance below subprocess/request maxima, or cannot fit the next pacing/backoff/retry operation
- **THEN** no later command/request starts, remaining Nix work is recorded incomplete and synchronized before final failure, while exhausted mandatory manifest work is fatal with no result/normal outputs or GitHub writes

#### Scenario: Offline contracts are reproducible
- **WHEN** the security-scan fixture scenarios run with mocked command/API boundaries
- **THEN** assertions cover inventory, threshold compatibility, both actual production validators consuming the same exclusively owned valid/mutated result bytes and independent side inputs, all specified mutation rejection, and zero GitHub writes on invalid input without live external calls

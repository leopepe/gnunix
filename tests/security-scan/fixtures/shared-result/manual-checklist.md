# Manual wire audit — task0.1

Contract: [design §3](../../../../../openspec/changes/scan-nix-profile-closures/design.md). This is a construction review, NOT an executable schema/production validator pass. Source commit: `7aa0dc370cb7199c6dd4098c9035a2212dca7b71`.

## Shapes and invariants reviewed

- [x] UTF-8 JSON object; numeric schemaVersion1; exact scope/outcome; required keys including nullable keys. All positive nested shapes reviewed: Result, Root, Gap, Inventory, Identity, Reason, Manifest, Finding, Source, Coverage, RootCounts, Counts, ManifestCounts, Limitation, Unscored. No extra keys or duplicate object keys. Types remain JSON-native, finite and safe. String/path/CVE/CPE syntax checked.
- [x] Independently copied raw manifest/map, not a producer expected-set declaration. All selected entries mapped; 48 pointers = 8 toolchain/prereqs + 35 base + 2 init + 1 boot + 1 nix + 1 kernel. Exactly46 queried,2 excluded,0 explicit manifest skips. Map entire197-line configuration checked, including unused entries; unchanged curated conversion/reasons. Metadata-prefixed base key excluded; prereqs enumerated separately.
- [x] Manifest package, pinned/effective versions, pointers and query conversions match snapshot. Actual snapshot has no nonnull effective_version and no non-exclusion manifest skip: these branches cannot be invented with these side inputs and are left to consumer-specific independently supplied configurations. Pointer escaping has no matching special-name key in this real snapshot.
- [x] All five roots exactly once with fixed surfaces, exactly five perRoot count records. Complete base selected roots: four exact generated wrapper associations, one synthetic static package output (OpenSSL, deliberately NOT an actual BusyBox claim).
- [x] Base graph has8 unique paths:4 wrappers + shared OpenSSH + static OpenSSL + two distinct Bash versions. References remain inventory-only (no build inputs). Each wrapper reaches SSH and both Bash paths; initramfs reaches OpenSSL and SSH. Base memberships:4 paths in each buildEnv root;2 in initramfs. References inherit referring memberships; roots.paths equals reachability including output.
- [x] Global counts: inventory8, identified4, queried4, wrappers4; other disposition counts0. Per buildEnv:4/3/3/1 (inventory/identified/queried/wrappers); initramfs2/2/2/0. Disposition partition and overlapping identified count reviewed for every positive.
- [x] All three metadataSource enums represented with explicit output names and .drv association; wrappers have nullable identity/query/reason fields. Declared Identity.version never converted. Metadata trust here is synthetic association, not authenticated acquisition.
- [x] Complete and zero-finding positives plus manifest-only, Nix-only, combined sources, repeated CVE across distinct queried versions, HIGH7 and8.9, CRITICAL9, UNKNOWN10 represented. Source sets, exact packages/converted versions/CPE associations, URLs, path and root unions checked.
- [x] Every enumeration gap code represented (six root-level nullable-output cases plus two retained-path placeholders); every unknown identity reason represented; unmapped BusyBox, exact reasoned Nix kernel skip, retained mapped budget query, zero-findings incomplete and all-five-unavailable states represented. Each incomplete result retains explicit root/inventory evidence and cannot be clean.
- [x] Coverage limitations are exact root-gap + per-membership inventory-reason + manifest-exclusion union. Curated detail only for skips/exclusions, otherwise null. Complete enumeration may coexist with identity/map/query gaps. Unknown placeholder records retained.
- [x] Scoreless diagnostic pair uses actually queried Bash CPE, no overlap with findings, counted once. Finding-association positive also covers empty unscored. Diagnostics do not change complete predicate.
- [x] Complete predicate and outcome reviewed for each positive; all-roots-unavailable retains no fabricated inventory. Array permutation accepted explicitly despite producer lexical-order norm. Version-map-miss positive retains raw10.0, not an alias.
- [x] OpenSSH manifest/identity9.9p1 -> query/CPE/finding9.9:p1. Six-column legacy file displays9.9p1; compatibility expectation must compare source display against this independently frozen file, never copy JSON version. Only one unique CVE legacy row, avoiding unspecified Nix extension ordering; existing manifest order/dedup remains consumer testing obligation.
- [x] Every negative compared to named positive base with stated single logical mutation. Omitted kmod row deliberately decrements expected48->47 and queried46->45, retains complete outcome and all other surviving-row consistency; only independent E equality catches it. Duplicate-key and nonfinite-token negatives require raw-byte parsing, never JSON.parse + reserialization by callers.

## Per-file acceptance/mutation record

All paths are relative to this directory; expectations.json is the machine-readable authority. Review below records expected behavior, not production success.

| Result bytes | Expected | Single mutation | Invalid invariant / review |
|---|---|---|---|
| `positive/complete-findings.json` | ACCEPT complete | Synthetic valid wire; no mutation | All checklist rows below checked |
| `positive/complete-zero.json` | ACCEPT complete | Synthetic valid wire; no mutation | All checklist rows below checked |
| `positive/complete-finding-associations.json` | ACCEPT complete | Synthetic valid wire; no mutation | All checklist rows below checked |
| `positive/incomplete-setup-unavailable.json` | ACCEPT incomplete | Synthetic valid wire; no mutation | All checklist rows below checked |
| `positive/incomplete-evaluation-failed.json` | ACCEPT incomplete | Synthetic valid wire; no mutation | All checklist rows below checked |
| `positive/incomplete-acquisition-unavailable.json` | ACCEPT incomplete | Synthetic valid wire; no mutation | All checklist rows below checked |
| `positive/incomplete-acquisition-budget.json` | ACCEPT incomplete | Synthetic valid wire; no mutation | All checklist rows below checked |
| `positive/incomplete-path-info-invalid.json` | ACCEPT incomplete | Synthetic valid wire; no mutation | All checklist rows below checked |
| `positive/incomplete-root-missing.json` | ACCEPT incomplete | Synthetic valid wire; no mutation | All checklist rows below checked |
| `positive/incomplete-path-info-null.json` | ACCEPT incomplete | Synthetic valid wire; no mutation | All checklist rows below checked |
| `positive/incomplete-reference-missing.json` | ACCEPT incomplete | Synthetic valid wire; no mutation | All checklist rows below checked |
| `positive/incomplete-deriver-unavailable.json` | ACCEPT incomplete | Synthetic valid wire; no mutation | All checklist rows below checked |
| `positive/incomplete-metadata-missing.json` | ACCEPT incomplete | Synthetic valid wire; no mutation | All checklist rows below checked |
| `positive/incomplete-metadata-conflict.json` | ACCEPT incomplete | Synthetic valid wire; no mutation | All checklist rows below checked |
| `positive/incomplete-unmapped-cpe.json` | ACCEPT incomplete | Synthetic valid wire; no mutation | All checklist rows below checked |
| `positive/incomplete-explicit-skip.json` | ACCEPT incomplete | Synthetic valid wire; no mutation | All checklist rows below checked |
| `positive/incomplete-not-queried-budget.json` | ACCEPT incomplete | Synthetic valid wire; no mutation | All checklist rows below checked |
| `positive/incomplete-zero.json` | ACCEPT incomplete | Synthetic valid wire; no mutation | All checklist rows below checked |
| `positive/incomplete-all-roots-unavailable.json` | ACCEPT incomplete | Synthetic valid wire; no mutation | All checklist rows below checked |
| `positive/complete-permuted.json` | ACCEPT complete | Synthetic valid wire; no mutation | All checklist rows below checked |
| `negative/omitted-manifest-self-consistent.json` | REJECT | Remove /base_packages/kmod and recompute surviving manifest expected/queried counts; outcome remains complete. One logical row-omission mutation with dependent recount. | Independent trusted expected-set equality (not supplied counts) |
| `negative/duplicate-root.json` | REJECT | Append identical first root | roots unique by id and exactly five |
| `negative/duplicate-inventory-path.json` | REJECT | Append identical inventory record | inventory unique by full path |
| `negative/duplicate-membership.json` | REJECT | Repeat inventory roots member | inventory.roots is a set |
| `negative/wrong-global-count.json` | REJECT | Increment coverage.global.inventory | recomputed global counts |
| `negative/wrong-root-count.json` | REJECT | Increment first perRoot queried | recomputed membership counts |
| `negative/wrong-manifest-count.json` | REJECT | Increment coverage.manifest.expected | independent cardinality of E and disposition counts |
| `negative/wrong-outcome.json` | REJECT | Set outcome incomplete | outcome iff complete predicate |
| `negative/wrong-coverage-complete.json` | REJECT | Set coverage.complete false | coverage.complete iff complete predicate |
| `negative/missing-nested-field.json` | REJECT | Delete inventory identity.output | Identity exact required keys |
| `negative/orphan-finding.json` | REJECT | Replace manifest source id with absent pointer | each source links known queried row |
| `negative/openssh-finding-declared-version.json` | REJECT | Replace finding.version with 9.9p1 | finding.version equals converted actual query 9.9:p1 |
| `negative/openssh-manifest-declared-query.json` | REJECT | Replace manifest queriedVersion with 9.9p1 | trusted exact version conversion |
| `negative/openssh-inventory-declared-query.json` | REJECT | Replace inventory queriedVersion with 9.9p1 | Nix map converts identity.version |
| `negative/wrong-cpe.json` | REJECT | Replace OpenSSH CPE with unconverted CPE | exact virtualMatchString |
| `negative/extra-manifest.json` | REJECT | Append extra independently unexpected manifest id | exact E equality |
| `negative/duplicate-manifest.json` | REJECT | Append identical manifest row | manifest unique by id |
| `negative/wrong-pinned-version.json` | REJECT | Replace trusted OpenSSH pinned version | independent pinned version equality |
| `negative/wrong-effective-version.json` | REJECT | Inject manifest effectiveVersion | independent effective version equality |
| `negative/wrong-manifest-package.json` | REJECT | Rename manifest package | independently derived package |
| `negative/missing-root.json` | REJECT | Remove root | exact five RootIds |
| `negative/duplicate-per-root.json` | REJECT | Append identical perRoot record | perRoot unique by id and exact five |
| `negative/missing-per-root.json` | REJECT | Remove perRoot record | exact five coverage RootIds |
| `negative/wrong-surface.json` | REJECT | Set desktop surface initramfs | fixed surface for each RootId |
| `negative/empty-memberships.json` | REJECT | Clear inventory.roots | nonempty memberships |
| `negative/root-membership-mismatch.json` | REJECT | Remove root.paths member only | bidirectional membership equivalence |
| `negative/orphan-reference.json` | REJECT | Add reference with no inventory record | every reference retains record |
| `negative/reference-membership-loss.json` | REJECT | Add desktop-only wrapper reference to installer wrapper | references inherit memberships |
| `negative/unreachable-path.json` | REJECT | Remove sole edge to bash2 from desktop wrapper | root.paths equals graph reachability |
| `negative/null-complete-output.json` | REJECT | Set complete root outputPath null | null output requires empty paths/incomplete |
| `negative/gap-in-complete-root.json` | REJECT | Add enumeration gap to complete root | complete enumeration has no gaps |
| `negative/incomplete-root-no-gap.json` | REJECT | Set root enumeration incomplete | incomplete enumeration requires gap |
| `negative/invalid-gap-code.json` | REJECT | Add metadata code as enumeration gap | Gap code restricted to enumeration codes |
| `negative/gap-path-outside-root.json` | REJECT | Add gap path not in root.paths | nonnull Gap path is affected membership |
| `negative/package-without-identity.json` | REJECT | Set package identity null | package requires Identity |
| `negative/wrapper-with-identity.json` | REJECT | Give wrapper package Identity | wrapper fields nullable exact classification |
| `negative/wrapper-not-selected.json` | REJECT | Change selected wrapper root.outputPath to ssh | wrapper exact selected buildEnv association |
| `negative/initramfs-wrapper.json` | REJECT | Classify initramfs package as wrapper | initramfs is never supported generated wrapper |
| `negative/query-with-reason.json` | REJECT | Add reason to queried package | queried reason null |
| `negative/unknown-with-identity.json` | REJECT | Give unknown Identity | unknown identity null |
| `negative/unmapped-but-map-exists.json` | REJECT | Rename unmapped busybox to bash | unmapped requires absent map |
| `negative/skip-wrong-detail.json` | REJECT | Change skip detail | exact unchanged curated skip reason |
| `negative/budget-with-null-cpe.json` | REJECT | Set pending query cpe null | budget retains mapped query/cpe |
| `negative/missing-limitation.json` | REJECT | Remove manifest exclusion limitation | exact deduplicated limitation union |
| `negative/extra-limitation.json` | REJECT | Append unrelated limitation | exact limitation union no extras |
| `negative/duplicate-limitation.json` | REJECT | Repeat limitation | limitations is keyed set |
| `negative/wrong-unscored-count.json` | REJECT | Increment unscoredCveCount | unscored count length |
| `negative/unscored-unqueried-cpe.json` | REJECT | Replace unscored CPE with absent query | unscored only actually queried cpes |
| `negative/unscored-finding-overlap.json` | REJECT | Append finding cpe/CVE as unscored | no finding/unscored pair overlap |
| `negative/duplicate-unscored.json` | REJECT | Repeat unscored pair | unscored keyed set |
| `negative/finding-no-source.json` | REJECT | Clear sources | finding at least one source |
| `negative/finding-unqueried-source.json` | REJECT | Point nix source at wrapper | source must link queried inventory |
| `negative/finding-wrong-package.json` | REJECT | Rename finding package bash | all source package/cpe agreement |
| `negative/finding-wrong-paths.json` | REJECT | Clear finding paths | exact nix-source paths |
| `negative/finding-wrong-roots.json` | REJECT | Clear finding roots | exact source membership union |
| `negative/duplicate-finding.json` | REJECT | Repeat finding record | finding composite-key uniqueness |
| `negative/duplicate-source.json` | REJECT | Repeat source | sources keyed set |
| `negative/manifest-source-has-path.json` | REJECT | Set manifest source path | manifest Source.path null |
| `negative/nix-source-has-manifest-id.json` | REJECT | Set nix source manifestId | nix Source.manifestId null |
| `negative/wrong-finding-url.json` | REJECT | Change URL host | exact NVD detail URL |
| `negative/bad-cve-id.json` | REJECT | Use invalid CVE ID | V syntax |
| `negative/score-below-threshold.json` | REJECT | Set score6.9 | number score[7,10] |
| `negative/score-above-ten.json` | REJECT | Set score10.1 | number score[7,10] |
| `negative/score-coerced-string.json` | REJECT | Set score string7 | no coerced types |
| `negative/severity-score-mismatch.json` | REJECT | Set HIGH score9 | HIGH [7,9) |
| `negative/critical-score-mismatch.json` | REJECT | Set CRITICAL for score7 | CRITICAL [9,10] |
| `negative/unknown-schema.json` | REJECT | Set schemaVersion2 | schemaVersion exactly numeric1 |
| `negative/schema-string.json` | REJECT | Set schemaVersion string1 | no coerced types |
| `negative/wrong-scope.json` | REJECT | Change scope | exact locked scope |
| `negative/extra-field.json` | REJECT | Add top-level timestamp | no extra keys |
| `negative/missing-coverage.json` | REJECT | Delete coverage | all Result keys required |
| `negative/missing-nullable-key.json` | REJECT | Delete inventory.deriver | nullable never omitted |
| `negative/invalid-store-path.json` | REJECT | Replace inventory.path with invalid hash | P exact store-path syntax |
| `negative/invalid-deriver.json` | REJECT | Use non-drv store path for deriver | derivers end .drv |
| `negative/control-string.json` | REJECT | Inject control into Identity.pname | S excludes controls |
| `negative/empty-string.json` | REJECT | Set Identity.output empty | S nonempty |
| `negative/noninteger-count.json` | REJECT | Set global.inventory8.5 | N integer |
| `negative/negative-count.json` | REJECT | Set global.unknown -1 | N nonnegative |
| `negative/unsafe-count.json` | REJECT | Set inventory count9007199254740992 | N <=9007199254740991 |
| `negative/invalid-enum.json` | REJECT | Set metadataSource basename | enum no unrecognized values |
| `negative/array-shape.json` | REJECT | Set manifest object instead of array | arrays must be arrays |
| `negative/duplicate-reference.json` | REJECT | Repeat reference | references set |
| `negative/duplicate-root-path.json` | REJECT | Repeat root.paths member | root.paths set |
| `negative/duplicate-json-key.json` | REJECT | Repeat schemaVersion object key | duplicate JSON keys forbidden |
| `negative/nonfinite-number.json` | REJECT | Replace score token with1e999 | non-finite numbers forbidden |
| `positive/complete-version-map-miss.json` | ACCEPT complete | Synthetic valid wire; no mutation | All checklist rows below checked |

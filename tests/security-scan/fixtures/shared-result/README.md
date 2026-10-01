# Frozen shared result corpus

Task0.1 owns this directory exclusively. Scanner (1.1) and report (2.1)
consume these files **read-only**, using the exact same raw result bytes and
independently loaded side inputs. Repairs return to the corpus owner.

Contract: [design §3](../../../../../openspec/changes/scan-nix-profile-closures/design.md).
Construction review: [manual-checklist.md](manual-checklist.md).
No fixture-only schema validator or acquisition code is included.

## Index contract

`expectations.json` is an index, **not** scanner result input or a substitute
for independent expected-set derivation. All file paths resolve relative to
this directory, regardless of caller working directory.

- `indexVersion: 1`, `contract`, `sourceCommit`, `pathBase`, `consumerPolicy`:
  corpus metadata, not result schema fields.
- `inputs[]`: `file`, original checkout `source`, and raw-byte `sha256`.
- `cases[]`: `id`, `result`, `manifest`, `cpeMap`, `accept` for every case.
- Accepted cases additionally specify `outcome` and `expectedScannerExit`
  (0 complete, 2 incomplete); rejection has no publishable result or normal
  outputs. Report rejection must cause zero create/update/reopen/close/comment
  writes. This is an expectation, not evidence those consumers passed.
- Rejected cases specify positive `base`, `mutation`, `invalidInvariant`.
  Each is one logical mutation; row-omission deliberately also recounts its
  dependent surviving-row totals, leaving a self-consistent false-complete
  result that independent trusted manifest equality must reject.
- Optional positive `legacy` specifies frozen TSV `file`, compatibility
  `mode`, `cveId`, `package`, `declaredVersion`, `jsonFindingVersion`,
  `tsvDisplayVersion`, `columns`. This file contains six columns and one unique
  OpenSSH CVE association. Assert JSON9.9:p1 **and** TSV9.9p1; deriving the TSV
  version from JSON must break this expectation. Existing manifest ordering
  and CVE deduplication remain consumer-specific test obligations.

Load `manifest` and `cpeMap` directly as separately supplied trusted inputs;
never use `coverage.manifest.expected`, the index hash, or a result-supplied
expected set instead. Both snapshots are byte-for-byte copies of the source
checkout at `7aa0dc370cb7199c6dd4098c9035a2212dca7b71`, not normalized JSON.
The unchanged real map is used for all cases; no speculative aliases exist.

Read raw result bytes before parsing: `negative/duplicate-json-key.json`
intentionally contains repeated object keys and `negative/nonfinite-number.json`
contains `1e999`. Do not parse/reserialize them before production validation.
Neither is a broken corpus file to repair or omit from consumers.

`SHA256SUMS` records every corpus file except itself, with paths relative to
this directory. Verify without rewriting any file:

```sh
(cd tests/security-scan/fixtures/shared-result && shasum -a 256 -c SHA256SUMS)
```

## Provenance and limitations

21 synthetic publishable wires and 85 single-mutation rejection wires cover
complete/incomplete states, all enumeration gap codes and inventory
identity/map/skip/query-budget dispositions, retained unknown placeholders,
source associations, converted versions, counts and raw-byte hazards. An
explicit permutation positive proves ordering is not validation identity.

Store paths, identities, findings, metadata associations and graphs are
**synthetic**. In particular the mapped OpenSSL static root is deliberately
associated with the required `initramfsBusybox` id for wire-contract coverage:
it does **not** claim actual BusyBox is OpenSSL or mapped, nor any actual root
contents, substitutions/cache availability, NVD finding or Nix compatibility.
The separate unmapped-BusyBox positive remains incomplete.

This real manifest has null/absent effective versions and no non-exclusion
manifest skips. Those variants and special-character pointer escaping require
consumer-specific side-input configurations, not alterations to these frozen
real snapshots. Manual review and byte checks are construction evidence only;
actual scanner/report validators and API write-absence tests are pending their
exclusive implementation owners. No live external calls, Nix installation,
realization, image work or GitHub mutation occurred.

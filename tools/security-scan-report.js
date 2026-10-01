'use strict';
// Independent consumer of design.md §3; no scanner validator or schema dependency.
// validateResult(resultBytes, {manifest, cpeMap}) accepts raw UTF-8 result bytes;
// trusted side inputs may be raw UTF-8 bytes or independently loaded objects.
// synchronize({resultBytes, manifest, cpeMap, github, core, context, now?})
// validates before discovery/writes and returns {outcome, fingerprint, actions}.
// Caller loads SCAN_RESULT_FILE and its checkout MANIFEST/CPE map separately,
// handles file/API failures, and fails the job AFTER syncing outcome=incomplete.
const { createHash } = require('node:crypto');
const { TextDecoder } = require('node:util');

const TITLE = 'CVE Report — open HIGH/CRITICAL findings';
const LABELS = ['security', 'auto-triggered'];
const ROOTS = ['minimalProfile', 'desktopProfile', 'installerProfile',
  'installerBuildTools', 'initramfsBusybox'];
const GAP_CODES = ['setup-unavailable', 'evaluation-failed', 'acquisition-unavailable',
  'acquisition-budget', 'path-info-invalid', 'path-info-null', 'root-missing', 'reference-missing'];
const CODES = [...GAP_CODES, 'deriver-unavailable', 'metadata-missing', 'metadata-conflict',
  'unmapped-cpe', 'explicit-skip', 'query-budget', 'manifest-exclusion'];
const MARKER = /<!-- security-scan-fingerprint:v1:([a-f0-9]{64}) -->/;
const fail = message => { throw new Error(`Invalid security scan: ${message}`); };
const check = (condition, message) => { if (!condition) fail(message); };
const object = x => x !== null && typeof x === 'object' && !Array.isArray(x);
const string = x => typeof x === 'string' && x.length > 0 && !/[\x00-\x1f\x7f]/.test(x);
const number = x => typeof x === 'number' && Number.isFinite(x);
const count = x => Number.isSafeInteger(x) && x >= 0;
const path = x => string(x) && /^\/nix\/store\/[0-9abcdfghijklmnpqrsvwxyz]{32}-[A-Za-z0-9+._?=-]+$/.test(x);
const cve = x => string(x) && /^CVE-[0-9]{4}-[0-9]{4,}$/.test(x);
const cpe = x => string(x) && x.startsWith('cpe:2.3:a:');
const enumOf = values => x => values.includes(x);
const nullable = test => x => x === null || test(x);

// Recursive JSON reader checks decoded duplicate keys and number finiteness
// BEFORE an ordinary parse could discard them. UTF-8 decode is fatal, not lossy.
function parseBytes(raw) {
  check(typeof raw === 'string' || Buffer.isBuffer(raw), 'raw UTF-8 bytes required');
  const text = Buffer.isBuffer(raw) ? new TextDecoder('utf-8', { fatal: true }).decode(raw) : raw;
  let at = 0;
  const ws = () => { while (/[\x20\x09\x0a\x0d]/.test(text[at] || '') && at < text.length) at++; };
  function quoted() {
    check(text[at] === '"', `string at ${at}`);
    const start = at++;
    while (at < text.length) {
      const char = text[at++];
      if (char === '\\') at++;
      else if (char === '"') return JSON.parse(text.slice(start, at));
    }
    fail('unterminated string');
  }
  function value() {
    ws();
    if (text[at] === '"') return quoted();
    if (text[at] === '{') {
      at++; ws();
      const result = Object.create(null), keys = new Set();
      if (text[at] === '}') { at++; return result; }
      for (;;) {
        ws(); const key = quoted();
        check(!keys.has(key), `duplicate JSON key ${key}`); keys.add(key);
        ws(); check(text[at++] === ':', 'object colon');
        result[key] = value(); ws();
        if (text[at] === '}') { at++; return result; }
        check(text[at++] === ',', 'object separator');
      }
    }
    if (text[at] === '[') {
      at++; ws(); const result = [];
      if (text[at] === ']') { at++; return result; }
      for (;;) {
        result.push(value()); ws();
        if (text[at] === ']') { at++; return result; }
        check(text[at++] === ',', 'array separator');
      }
    }
    for (const [token, result] of [['true', true], ['false', false], ['null', null]]) {
      if (text.startsWith(token, at)) { at += token.length; return result; }
    }
    const match = text.slice(at).match(/^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?/);
    check(match, `JSON value at ${at}`); at += match[0].length;
    const result = Number(match[0]); check(Number.isFinite(result), 'non-finite number');
    return result;
  }
  const result = value(); ws(); check(at === text.length, 'trailing JSON');
  return result;
}

function stable(value) {
  if (Array.isArray(value)) return value.map(stable).sort((a, b) =>
    JSON.stringify(a) < JSON.stringify(b) ? -1 : JSON.stringify(a) > JSON.stringify(b) ? 1 : 0);
  if (object(value)) return Object.fromEntries(Object.keys(value).sort().map(k => [k, stable(value[k])]));
  return value;
}
const canonicalize = result => JSON.stringify(stable(result));
const same = (a, b) => canonicalize(a) === canonicalize(b);
const fingerprint = result => createHash('sha256').update(canonicalize(result)).digest('hex');
function shape(value, schema, label) {
  check(object(value), `${label} object`);
  check(same(Object.keys(value), Object.keys(schema)), `${label} exact fields`);
  for (const [key, test] of Object.entries(schema)) check(test(value[key]), `${label}.${key}`);
  return value;
}
function arrayOf(test, unique = false) {
  return value => Array.isArray(value) && value.every(test) && (!unique ||
    new Set(value.map(v => JSON.stringify(stable(v)))).size === value.length);
}
function record(schema, label) { return value => { shape(value, schema, label); return true; }; }
const rootId = enumOf(ROOTS);
const reason = record({ code: enumOf(CODES), detail: nullable(string) }, 'Reason');
const gap = record({ code: enumOf(GAP_CODES), path: nullable(path) }, 'Gap');
const identity = record({ pname: string, version: string, output: string,
  metadataSource: enumOf(['evaluated', 'deriver', 'structured-deriver']) }, 'Identity');
const source = record({ type: enumOf(['manifest', 'nix']), manifestId: nullable(string), path: nullable(path) }, 'Source');
const countsSchema = Object.fromEntries(['inventory', 'identified', 'queried', 'wrappers',
  'unknown', 'unmapped', 'skipped', 'unqueried'].map(k => [k, count]));
const counts = record(countsSchema, 'Counts');
const manifestCounts = record({ expected: count, queried: count, skipped: count, excluded: count }, 'ManifestCounts');
const limitation = record({ code: enumOf(CODES), root: nullable(rootId), path: nullable(path),
  manifestId: nullable(string), detail: nullable(string) }, 'Limitation');
const unscored = record({ cpe, cveId: cve }, 'Unscored');
const rootRecord = record({ id: rootId, surface: enumOf(['system-runtime', 'installer-image-build-payload', 'initramfs']),
  outputPath: nullable(path), enumeration: enumOf(['complete', 'incomplete']),
  paths: arrayOf(path, true), gaps: arrayOf(gap, true) }, 'Root');
const inventoryRecord = record({ path, roots: arrayOf(rootId, true), references: arrayOf(path, true),
  deriver: nullable(x => path(x) && x.endsWith('.drv')), kind: enumOf(['package', 'profile-wrapper', 'unknown']),
  identity: nullable(identity), disposition: enumOf(['queried', 'profile-wrapper', 'unknown-identity',
    'unmapped-cpe', 'explicit-skip', 'not-queried-budget']), cpe: nullable(cpe),
  queriedVersion: nullable(string), reason: nullable(reason) }, 'Inventory');
const manifestRecord = record({ id: string, package: string, pinnedVersion: string, effectiveVersion: nullable(string),
  queriedVersion: nullable(string), cpe: nullable(cpe), disposition: enumOf(['queried', 'explicit-skip', 'excluded']),
  reason: nullable(reason) }, 'Manifest');
const findingRecord = record({ cveId: cve, package: string, version: string,
  score: x => number(x) && x >= 7 && x <= 10, severity: enumOf(['HIGH', 'CRITICAL', 'UNKNOWN']), url: string,
  sources: arrayOf(source, true), roots: arrayOf(rootId, true), paths: arrayOf(path, true) }, 'Finding');
const coverageRecord = record({ complete: x => typeof x === 'boolean',
  perRoot: arrayOf(record({ id: rootId, counts }, 'RootCounts')), global: counts, manifest: manifestCounts,
  limitations: arrayOf(limitation, true), unscored: arrayOf(unscored, true), unscoredCveCount: count }, 'Coverage');

function trusted(value, label) {
  const result = typeof value === 'string' || Buffer.isBuffer(value) ? parseBytes(value) : value;
  check(object(result), `${label} side input required`); return result;
}
function validateMap(map) {
  for (const [pkg, entry] of Object.entries(map)) {
    check(string(pkg) && object(entry), 'map entry');
    if (Object.hasOwn(entry, 'skip')) shape(entry, { skip: x => x === true, reason: string }, `map ${pkg}`);
    else {
      const schema = { vendor: x => string(x) && /^[A-Za-z0-9._-]+$/.test(x),
        product: x => string(x) && /^[A-Za-z0-9._-]+$/.test(x) };
      if (Object.hasOwn(entry, 'version_map')) schema.version_map = versions => object(versions) &&
        Object.entries(versions).every(([key, val]) => string(key) && string(val));
      shape(entry, schema, `map ${pkg}`);
    }
  }
}
function queryFor(map, pkg, version) {
  if (!Object.hasOwn(map, pkg)) return null;
  const entry = map[pkg]; if (entry.skip) return { skip: entry.reason };
  const queriedVersion = entry.version_map && Object.hasOwn(entry.version_map, version)
    ? entry.version_map[version] : version;
  return { queriedVersion, cpe: `cpe:2.3:a:${entry.vendor}:${entry.product}:${queriedVersion}` };
}
function deriveManifest(manifest, map) {
  for (const key of ['toolchain', 'base_packages', 'init_and_session', 'bootloader', 'nix', 'kernel'])
    check(object(manifest[key]), `manifest ${key}`);
  check(object(manifest.toolchain.gcc_prereqs), 'manifest gcc_prereqs');
  const rows = [], escape = key => key.replace(/~/g, '~0').replace(/\//g, '~1');
  function add(id, pkg, entry, versionKey = 'version') {
    check(object(entry) && string(entry[versionKey]), `manifest entry ${id}`);
    const effective = entry.effective_version === undefined ? null : entry.effective_version;
    check(nullable(string)(effective), `effective version ${id}`);
    const query = queryFor(map, pkg, effective === null ? entry[versionKey] : effective);
    check(query !== null, `missing manifest map ${pkg}`);
    const excluded = id === '/kernel' || id === '/toolchain/linux_headers';
    check(!excluded || query.skip, `reasoned exclusion ${id}`);
    rows.push({ id, package: pkg, pinnedVersion: entry[versionKey], effectiveVersion: effective,
      queriedVersion: query.skip ? null : query.queriedVersion, cpe: query.skip ? null : query.cpe,
      disposition: excluded ? 'excluded' : query.skip ? 'explicit-skip' : 'queried',
      reason: query.skip ? { code: excluded ? 'manifest-exclusion' : 'explicit-skip', detail: query.skip } : null });
  }
  for (const [section, entries] of [['toolchain', manifest.toolchain],
    ['toolchain/gcc_prereqs', manifest.toolchain.gcc_prereqs], ['base_packages', manifest.base_packages],
    ['init_and_session', manifest.init_and_session], ['bootloader', manifest.bootloader]]) {
    for (const [key, entry] of Object.entries(entries)) {
      if (key.startsWith('$') || (section === 'toolchain' && key === 'gcc_prereqs')) continue;
      add(`/${section}/${escape(key)}`, key, entry);
    }
  }
  add('/nix/binary_version', 'nix', manifest.nix, 'binary_version');
  add('/kernel', 'kernel', manifest.kernel);
  return rows;
}
function keyed(rows, key, label) {
  const result = new Map();
  for (const row of rows) { check(!result.has(row[key]), `duplicate ${label}`); result.set(row[key], row); }
  return result;
}
function recount(rows) {
  const result = Object.fromEntries(Object.keys(countsSchema).map(k => [k, 0]));
  const names = { queried: 'queried', 'profile-wrapper': 'wrappers', 'unknown-identity': 'unknown',
    'unmapped-cpe': 'unmapped', 'explicit-skip': 'skipped', 'not-queried-budget': 'unqueried' };
  for (const row of rows) { result.inventory++; if (row.kind === 'package') result.identified++;
    result[names[row.disposition]]++; }
  return result;
}

function validateResult(resultBytes, { manifest, cpeMap } = {}) {
  const result = parseBytes(resultBytes);
  const map = trusted(cpeMap, 'CPE map'); validateMap(map);
  const expected = deriveManifest(trusted(manifest, 'manifest'), map);
  shape(result, { schemaVersion: x => x === 1, outcome: enumOf(['complete', 'incomplete']),
    scope: x => x === 'locked-aarch64-output-references', roots: arrayOf(rootRecord),
    inventory: arrayOf(inventoryRecord), manifest: arrayOf(manifestRecord),
    findings: arrayOf(findingRecord), coverage: coverageRecord }, 'Result');
  const roots = keyed(result.roots, 'id', 'root'), inventory = keyed(result.inventory, 'path', 'inventory path');
  const manifests = keyed(result.manifest, 'id', 'manifest');
  check(same([...roots.keys()], ROOTS), 'exact five roots');
  check(same(result.manifest, expected), 'independent expected manifest equality');
  for (const root of result.roots) {
    const surface = root.id === 'initramfsBusybox' ? 'initramfs'
      : root.id === 'installerBuildTools' ? 'installer-image-build-payload' : 'system-runtime';
    check(root.surface === surface, 'root surface');
    check(root.enumeration === 'complete' ? root.outputPath !== null && root.gaps.length === 0
      : root.gaps.length > 0, 'root enumeration/gaps');
    check(root.outputPath !== null || (root.paths.length === 0 && root.enumeration === 'incomplete'), 'null root');
    for (const g of root.gaps) check(g.path === null || root.paths.includes(g.path), 'gap membership');
    const reached = new Set();
    function visit(p) {
      if (reached.has(p)) return;
      check(inventory.has(p), 'missing path/reference'); reached.add(p);
      for (const ref of inventory.get(p).references) visit(ref);
    }
    if (root.outputPath !== null) visit(root.outputPath);
    check(same([...reached], root.paths), 'graph reachability');
    for (const row of result.inventory)
      check(root.paths.includes(row.path) === row.roots.includes(root.id), 'bidirectional membership');
  }
  for (const row of result.inventory) {
    check(row.roots.length > 0, 'nonempty memberships');
    for (const ref of row.references) {
      check(inventory.has(ref), 'orphan reference');
      check(row.roots.every(id => inventory.get(ref).roots.includes(id)), 'reference membership inheritance');
    }
    const noQuery = row.cpe === null && row.queriedVersion === null;
    if (row.kind === 'profile-wrapper') {
      check(row.identity === null && noQuery && row.reason === null && row.disposition === 'profile-wrapper', 'wrapper fields');
      check(result.roots.some(r => r.id !== 'initramfsBusybox' && r.outputPath === row.path), 'selected wrapper association');
    } else if (row.kind === 'unknown') {
      check(row.identity === null && noQuery && row.disposition === 'unknown-identity' && row.reason !== null &&
        ['deriver-unavailable', 'metadata-missing', 'metadata-conflict'].includes(row.reason.code) &&
        row.reason.detail === null, 'unknown fields');
    } else {
      check(row.identity !== null, 'package identity');
      const query = queryFor(map, row.identity.pname, row.identity.version);
      if (query === null) check(noQuery && row.disposition === 'unmapped-cpe' &&
        same(row.reason, { code: 'unmapped-cpe', detail: null }), 'unmapped fields');
      else if (query.skip) check(noQuery && row.disposition === 'explicit-skip' &&
        same(row.reason, { code: 'explicit-skip', detail: query.skip }), 'skip fields');
      else check(row.cpe === query.cpe && row.queriedVersion === query.queriedVersion &&
        ((row.disposition === 'queried' && row.reason === null) ||
          (row.disposition === 'not-queried-budget' && same(row.reason, { code: 'query-budget', detail: null }))), 'mapped fields');
    }
  }
  const findingKeys = new Set(), findingPairs = new Set();
  for (const finding of result.findings) {
    check(finding.sources.length > 0, 'finding source required');
    check(finding.version !== '*', 'wildcard finding version');
    check(finding.url === `https://nvd.nist.gov/vuln/detail/${finding.cveId}`, 'official URL');
    check(finding.severity === 'UNKNOWN' || (finding.severity === 'HIGH' ? finding.score < 9 : finding.score >= 9), 'score/severity');
    const paths = [], memberships = new Set(); let associatedCpe;
    for (const src of finding.sources) {
      let row, pkg;
      if (src.type === 'manifest') {
        check(src.path === null && manifests.has(src.manifestId), 'manifest source');
        row = manifests.get(src.manifestId); pkg = row.package;
      } else {
        check(src.manifestId === null && inventory.has(src.path), 'Nix source');
        row = inventory.get(src.path); pkg = row.identity && row.identity.pname;
        paths.push(src.path); for (const id of row.roots) memberships.add(id);
      }
      check(row.disposition === 'queried' && pkg === finding.package && row.queriedVersion === finding.version, 'queried source agreement');
      if (associatedCpe === undefined) associatedCpe = row.cpe;
      check(row.cpe === associatedCpe, 'source CPE agreement');
    }
    check(same(paths, finding.paths) && same([...memberships], finding.roots), 'finding provenance sets');
    const key = JSON.stringify([finding.cveId, finding.package, finding.version, associatedCpe]);
    check(!findingKeys.has(key), 'duplicate finding'); findingKeys.add(key);
    findingPairs.add(JSON.stringify([associatedCpe, finding.cveId]));
  }
  const coverage = result.coverage, perRoot = keyed(coverage.perRoot, 'id', 'perRoot');
  check(same([...perRoot.keys()], ROOTS), 'exact five perRoot counts');
  check(same(recount(result.inventory), coverage.global), 'global counts');
  for (const id of ROOTS) check(same(recount(result.inventory.filter(r => r.roots.includes(id))), perRoot.get(id).counts), 'root counts');
  check(same(coverage.manifest, { expected: expected.length, queried: expected.filter(r => r.disposition === 'queried').length,
    skipped: expected.filter(r => r.disposition === 'explicit-skip').length, excluded: expected.filter(r => r.disposition === 'excluded').length }), 'manifest counts');
  const limitations = [];
  const add = (why, root, path, manifestId) => limitations.push({ code: why.code, root, path, manifestId, detail: why.detail ?? null });
  for (const root of result.roots) for (const g of root.gaps) add(g, root.id, g.path, null);
  for (const row of result.inventory) if (row.reason) for (const id of row.roots) add(row.reason, id, row.path, null);
  for (const row of result.manifest) if (row.reason) add(row.reason, null, null, row.id);
  const deduped = [...new Map(limitations.map(x => [canonicalize(x), x])).values()];
  check(same(coverage.limitations, deduped), 'exact limitation union');
  const queriedCpes = new Set([...result.manifest, ...result.inventory].filter(r => r.disposition === 'queried').map(r => r.cpe));
  for (const row of coverage.unscored) check(queriedCpes.has(row.cpe) &&
    !findingPairs.has(JSON.stringify([row.cpe, row.cveId])), 'unscored association');
  check(coverage.unscoredCveCount === coverage.unscored.length, 'unscored count');
  const complete = result.roots.every(r => r.enumeration === 'complete') &&
    result.inventory.every(r => r.disposition === 'queried' || r.disposition === 'profile-wrapper');
  check(coverage.complete === complete && result.outcome === (complete ? 'complete' : 'incomplete'), 'recomputed completeness/outcome');
  return result;
}

function escapeMarkdown(value) {
  return String(value).replace(/[\x00-\x1f\x7f]/g, ' ')
    .replace(/[\\`*_{}\[\]()#!~]/g, '\\$&')
    .replace(/&/g, '&amp;').replace(/</g, '&lt;')
    .replace(/>/g, '&gt;').replace(/\|/g, '&#124;');
}
function deltaState(result) {
  return {
    associations: result.findings.map(f => canonicalize({ cveId: f.cveId, package: f.package,
      version: f.version, score: f.score, severity: f.severity, sources: f.sources,
      roots: f.roots, paths: f.paths })).sort(),
    inventory: fingerprint(result.inventory), coverage: fingerprint(result.coverage),
    manifest: fingerprint(result.manifest)
  };
}
function deltaComment(result, previousBody) {
  let previous;
  const marker = (previousBody || '').match(/<!-- security-scan-state:v1:([A-Za-z0-9+/=]+) -->/);
  if (marker) {
    try { previous = parseBytes(Buffer.from(marker[1], 'base64')); } catch { /* Untrusted historical marker: migration refresh. */ }
  }
  const current = deltaState(result);
  const lines = [`Substantive scan state refreshed: ${result.outcome}; ${result.findings.length} HIGH/CRITICAL findings.`];
  if (previous && Array.isArray(previous.associations) && previous.associations.every(string)) {
    for (const item of current.associations.filter(a => !previous.associations.includes(a)))
      lines.push(`Added/changed association: ${escapeMarkdown(item)}`);
    for (const item of previous.associations.filter(a => !current.associations.includes(a)))
      lines.push(`No longer reported association: ${escapeMarkdown(item)}`);
    for (const key of ['inventory', 'coverage', 'manifest'])
      if (current[key] !== previous[key]) lines.push(`${key} changed; see refreshed scope, versions and limitations.`);
  } else lines.push('Migrated historical report to versioned identity/version/provenance and coverage state.');
  return lines.join('\n\n');
}
function render(result, hash, now) {
  const lines = ['## CVE Scan Report', '', `Changed scan: ${escapeMarkdown(now)}`,
    `Coverage: **${result.outcome}** — locked aarch64 output-reference scope only.`,
    'Not whole-image, installed-target, or arbitrary-user software assurance.',
    `HIGH/CRITICAL findings: ${result.findings.length}`, '',
    '| CVE | Package | Queried version | CVSS | Severity | Reference |',
    '|---|---|---|---|---|---|'];
  const manifests = new Map(result.manifest.map(r => [r.id, r]));
  const inventory = new Map(result.inventory.map(r => [r.path, r]));
  const sorted = value => stable(value);
  for (const f of sorted(result.findings)) {
    lines.push(`| ${[f.cveId, f.package, f.version, f.score, f.severity].map(escapeMarkdown).join(' | ')} | [NVD](${f.url}) |`);
    for (const src of sorted(f.sources)) {
      const row = src.type === 'manifest' ? manifests.get(src.manifestId) : inventory.get(src.path);
      const declared = src.type === 'manifest' ? row.pinnedVersion : row.identity.version;
      const effective = src.type === 'manifest' && row.effectiveVersion !== null ? `; effective ${row.effectiveVersion}` : '';
      lines.push(`- ${escapeMarkdown(f.cveId)} / ${escapeMarkdown(f.package)} / ${escapeMarkdown(f.version)}: ${escapeMarkdown(src.type)} ${escapeMarkdown(src.manifestId || src.path)}; declared ${escapeMarkdown(declared + effective)}; CPE ${escapeMarkdown(row.cpe)}`);
    }
    lines.push(`- Associated roots: ${f.roots.map(escapeMarkdown).join(', ') || 'manifest only'}`);
  }
  lines.push('', '## Coverage', '', `Manifest: ${escapeMarkdown(JSON.stringify(result.coverage.manifest))}`,
    `Unique inventory: ${escapeMarkdown(JSON.stringify(result.coverage.global))}`,
    `Unscored CVEs (not HIGH/CRITICAL findings): ${result.coverage.unscoredCveCount}`);
  for (const root of sorted(result.roots)) {
    const tally = result.coverage.perRoot.find(r => r.id === root.id).counts;
    lines.push(`- ${escapeMarkdown(root.id)} / ${escapeMarkdown(root.surface)}: ${root.enumeration}; output ${escapeMarkdown(root.outputPath || 'unavailable')}; ${escapeMarkdown(JSON.stringify(tally))}`);
  }
  for (const row of sorted(result.inventory)) lines.push(`- Inventory ${escapeMarkdown(row.path)}: ${escapeMarkdown(row.disposition)}; roots ${row.roots.slice().sort().map(escapeMarkdown).join(', ')}; ${row.identity ? escapeMarkdown(`${row.identity.pname} ${row.identity.version} output ${row.identity.output} metadata ${row.identity.metadataSource}`) : 'identity unavailable or selected wrapper'}`);
  for (const why of sorted(result.coverage.limitations)) lines.push(`- Limitation ${escapeMarkdown(why.code)}: ${escapeMarkdown(why.root || why.manifestId || '')} ${escapeMarkdown(why.path || '')}${why.detail ? ` — ${escapeMarkdown(why.detail)}` : ''}`);
  lines.push('', 'Remediation: manifest sources require reviewed pins/effective versions in tools/manifest.json (ADR-023); Nix sources require reviewed locked package-set changes in flake.lock/nix declarations (ADR-025). This report changes no pins.', '',
    `<!-- security-scan-fingerprint:v1:${hash} -->`,
    `<!-- security-scan-state:v1:${Buffer.from(JSON.stringify(deltaState(result))).toString('base64')} -->`);
  return lines.join('\n');
}

// Pure planning includes validation, so callers cannot bypass the mutation guard.
function planReport(resultBytes, sideInputs, existing = null, now = new Date().toISOString()) {
  const result = validateResult(resultBytes, sideInputs), hash = fingerprint(result);
  const actions = [], body = render(result, hash, now);
  if (result.outcome === 'complete' && result.findings.length === 0) {
    if (existing && existing.state === 'open') {
      actions.push({ method: 'update', params: { issue_number: existing.number, body, state: 'closed' } });
      actions.push({ method: 'createComment', params: { issue_number: existing.number,
        body: 'Configured locked-aarch64 output-reference scope is complete with zero HIGH/CRITICAL findings. Known manifest exclusions remain; this is not whole-image assurance. Closing this scoped report.' } });
    }
  } else if (!existing) {
    actions.push({ method: 'create', params: { title: TITLE, labels: LABELS.slice(), body } });
  } else {
    const match = (existing.body || '').match(MARKER), changed = !match || match[1] !== hash;
    if (changed || existing.state === 'closed') {
      const params = { issue_number: existing.number };
      if (changed) params.body = body;
      if (existing.state === 'closed') params.state = 'open';
      actions.push({ method: 'update', params });
      if (changed) actions.push({ method: 'createComment', params: { issue_number: existing.number,
        body: deltaComment(result, existing.body) } });
    }
  }
  return { outcome: result.outcome, fingerprint: hash, actions };
}

async function synchronize({ resultBytes, manifest, cpeMap, github, core, context, now }) {
  // Complete validation precedes even discovery; API errors propagate to caller.
  validateResult(resultBytes, { manifest, cpeMap });
  const candidates = [], numbers = new Set();
  for (let page = 1; ; page++) {
    const response = await github.rest.issues.listForRepo({ ...context.repo,
      state: 'all', labels: LABELS.join(','), per_page: 100, page });
    check(response && Array.isArray(response.data), 'issue discovery response');
    for (const issue of response.data) {
      if (issue.pull_request || issue.title !== TITLE) continue;
      const labels = (issue.labels || []).map(l => typeof l === 'string' ? l : l.name);
      if (!LABELS.every(l => labels.includes(l))) continue;
      check(Number.isSafeInteger(issue.number) && issue.number > 0 &&
        ['open', 'closed'].includes(issue.state), 'issue candidate');
      check(!numbers.has(issue.number), 'repeated discovery candidate'); numbers.add(issue.number);
      candidates.push(issue);
    }
    if (response.data.length < 100) break;
  }
  check(candidates.length <= 1, 'ambiguous durable reports');
  const plan = planReport(resultBytes, { manifest, cpeMap }, candidates[0] || null, now);
  for (const action of plan.actions) await github.rest.issues[action.method]({ ...context.repo, ...action.params });
  if (core) core.info(`Security scan ${plan.outcome}: ${plan.actions.length} durable report actions`);
  return plan;
}

module.exports = { TITLE, LABELS, parseBytes, deriveManifest, validateResult,
  canonicalize, fingerprint, escapeMarkdown, planReport, synchronize };

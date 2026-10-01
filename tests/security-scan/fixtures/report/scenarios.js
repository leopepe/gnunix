'use strict';
// Offline behavioral tests; every mock method records an API trace, never calls GitHub.
// The four thin GWT entrypoints select one concern. Each assertion below names
// the producer/consumer mutation it detects; shared expectation mutations are
// taken unchanged from the read-only index and passed as RAW bytes.
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const { createHash } = require('node:crypto');
const root = path.resolve(__dirname, '../../../..');
const report = require(path.join(root, 'tools/security-scan-report.js'));
const corpus = path.join(root, 'tests/security-scan/fixtures/shared-result');
const read = relative => fs.readFileSync(path.join(corpus, relative));
const index = JSON.parse(read('expectations.json'));
const inputs = { manifest: read('inputs/manifest.json'), cpeMap: read('inputs/cpe-map.json') };
const bytes = name => read(`positive/${name}.json`);
const copy = value => JSON.parse(JSON.stringify(value));
const encode = value => Buffer.from(JSON.stringify(value));
const sum = raw => createHash('sha256').update(raw).digest('hex');
const mutations = trace => trace.filter(call => call.method !== 'listForRepo');
const context = { repo: { owner: 'offline', repo: 'fixture' } };
const clock = '2026-10-01T00:00:00Z';
function issue(body = '', state = 'open', number = 151) {
  return { number, title: report.TITLE, labels: report.LABELS.map(name => ({ name })), state, body };
}
function mock(pages = [[]], failMethod) {
  const trace = [], issues = {};
  issues.listForRepo = async args => {
    trace.push({ method: 'listForRepo', args });
    if (failMethod === 'listForRepo') throw new Error('offline discovery failure');
    return { data: pages[args.page - 1] || [] };
  };
  for (const method of ['create', 'update', 'createComment']) issues[method] = async args => {
    trace.push({ method, args });
    if (method === failMethod) throw new Error(`offline ${method} failure`);
    return { data: { number: 151 } };
  };
  return { github: { rest: { issues } }, trace };
}
async function sync(raw, pages = [[]], side = inputs, options = {}) {
  const api = mock(pages, options.failMethod);
  const plan = await report.synchronize({ resultBytes: raw, ...side,
    github: api.github, core: { info() {} }, context, now: options.now || clock });
  console.log('API TRACE', JSON.stringify({ scenario: options.name || process.argv[2], calls: api.trace }));
  return { plan, trace: api.trace };
}
async function invalid(raw, side = inputs, name = 'invalid') {
  const api = mock([[issue()]]);
  await assert.rejects(report.synchronize({ resultBytes: raw, ...side,
    github: api.github, core: { info() {} }, context, now: clock }), undefined, name);
  assert.deepEqual(mutations(api.trace), [], `${name}: no create/update/reopen/close/comment`);
  assert.deepEqual(api.trace, [], `${name}: validation precedes discovery too`);
  console.log('API TRACE', JSON.stringify({ scenario: name, calls: api.trace }));
}
function bodyFor(raw, side = inputs) {
  const plan = report.planReport(raw, side, null, clock);
  return plan.actions[0].params.body;
}
function hashes() {
  const snapshot = new Map();
  function walk(dir) {
    for (const ent of fs.readdirSync(dir, { withFileTypes: true })) {
      const f = path.join(dir, ent.name);
      if (ent.isDirectory()) walk(f); else snapshot.set(f, sum(fs.readFileSync(f)));
    }
  }
  walk(corpus); return snapshot;
}

async function invalidReport() {
  const before = hashes();
  assert.equal(index.cases.length, 106, 'frozen index: no hidden skipped case');
  assert.equal(index.cases.filter(c => c.accept).length, 21);
  assert.equal(index.cases.filter(c => !c.accept).length, 85);
  for (const input of index.inputs) assert.equal(sum(read(input.file)), input.sha256, 'raw trusted snapshot digest');
  for (const c of index.cases) {
    const raw = read(c.result), side = { manifest: read(c.manifest), cpeMap: read(c.cpeMap) };
    if (c.accept) {
      const result = report.validateResult(raw, side);
      assert.equal(result.outcome, c.outcome, c.id);
      await sync(raw, [[issue()]], side, { name: c.id });
      if (c.legacy) {
        // Copying JSON query version to legacy TSV MUST break this independent assertion.
        const row = result.manifest.find(r => r.id === '/base_packages/openssh');
        const finding = result.findings.find(f => f.cveId === c.legacy.cveId && f.package === 'openssh');
        const tsv = read(c.legacy.file).toString('utf8').trimEnd().split('\t');
        assert.equal(tsv.length, 6); assert.equal(tsv[2], '9.9p1');
        assert.equal(row.pinnedVersion, '9.9p1'); assert.equal(row.queriedVersion, '9.9:p1');
        assert.equal(finding.version, '9.9:p1'); assert.notEqual(tsv[2], finding.version);
      }
    } else await invalid(raw, side, `${c.id}: ${c.mutation}`);
  }
  // TDD green equivalent: malformed TSV may no longer masquerade as empty JSON.
  await invalid(Buffer.from('malformed\trow'), inputs, 'baseline malformed TSV cannot close');
  for (const raw of [Buffer.from([0xff]), Buffer.from('{"schemaVersion":1,"schema\\u0056ersion":1}'),
    Buffer.from('{"number":1e999}'), Buffer.from('{"number":NaN}')]) await invalid(raw);
  // Invalid independently loaded side inputs fail even when result was valid.
  await invalid(bytes('complete-findings'), { ...inputs, manifest: undefined }, 'missing manifest');
  await invalid(bytes('complete-findings'), { ...inputs, cpeMap: undefined }, 'missing map');
  const map = JSON.parse(inputs.cpeMap); map.unusedInvalid = { vendor: 'bad:vendor', product: 'unused' };
  await invalid(bytes('complete-findings'), { ...inputs, cpeMap: encode(map) }, 'validate UNUSED map entries');
  const manifest = JSON.parse(inputs.manifest); manifest.base_packages.unexpected = {};
  await invalid(bytes('complete-findings'), { ...inputs, manifest: encode(manifest) }, 'unversioned nonmetadata entry fatal');
  await sideInputCases();
  assert.deepEqual(hashes(), before, 'ALL corpus raw files unchanged after consumer validation/API traces');
}

async function sideInputCases() {
  const configs = JSON.parse(fs.readFileSync(path.join(__dirname, 'side-input-cases.json')));
  for (const cfg of configs) {
    // Only consumer-specific variants use modified independent side inputs.
    // Shared cases above always consume identical full RAW corpus bytes.
    const manifest = JSON.parse(inputs.manifest), map = JSON.parse(inputs.cpeMap);
    const result = JSON.parse(bytes('complete-zero'));
    if (cfg.id === 'effective-before-conversion') {
      manifest.base_packages.openssh.effective_version = cfg.effectiveVersion;
      map.openssh.version_map[cfg.effectiveVersion] = cfg.queriedVersion;
      const row = result.manifest.find(r => r.package === cfg.package);
      row.effectiveVersion = cfg.effectiveVersion; row.queriedVersion = cfg.queriedVersion;
      row.cpe = `cpe:2.3:a:openbsd:openssh:${cfg.queriedVersion}`;
      // Nix identity.version remains declared 9.9p1, not inherited effective version.
      assert.equal(result.inventory.find(r => r.identity?.pname === 'openssh').queriedVersion, '9.9:p1');
    } else if (cfg.id === 'reasoned-manifest-skip') {
      map.less = { skip: true, reason: cfg.reason };
      const row = result.manifest.find(r => r.package === cfg.package);
      row.cpe = null; row.queriedVersion = null; row.disposition = 'explicit-skip';
      row.reason = { code: 'explicit-skip', detail: cfg.reason };
      result.coverage.manifest.queried--; result.coverage.manifest.skipped++;
      result.coverage.limitations.push({ code: 'explicit-skip', root: null, path: null,
        manifestId: row.id, detail: cfg.reason });
    } else {
      manifest.base_packages[cfg.package] = { version: cfg.pinnedVersion };
      map[cfg.package] = { vendor: cfg.vendor, product: cfg.product };
      result.manifest.push({ id: cfg.pointer, package: cfg.package, pinnedVersion: cfg.pinnedVersion,
        effectiveVersion: null, queriedVersion: cfg.pinnedVersion,
        cpe: `cpe:2.3:a:${cfg.vendor}:${cfg.product}:${cfg.pinnedVersion}`, disposition: 'queried', reason: null });
      result.coverage.manifest.expected++; result.coverage.manifest.queried++;
    }
    const side = { manifest: encode(manifest), cpeMap: encode(map) };
    assert.equal(report.validateResult(encode(result), side).outcome, 'complete', cfg.mutation);
    await sync(encode(result), [[issue()]], side, { name: cfg.id });
    const broken = copy(result);
    if (cfg.id === 'effective-before-conversion') broken.manifest.find(r => r.package === cfg.package).queriedVersion = '9.9:p1';
    else if (cfg.id === 'reasoned-manifest-skip') broken.manifest.find(r => r.package === cfg.package).reason.detail = 'wrong reason';
    else broken.manifest.find(r => r.package === cfg.package).id = '/base_packages/fixture~/pkg';
    await invalid(encode(broken), side, cfg.mutation);
  }
}

async function reportDelta() {
  const raw = bytes('complete-findings'), existingBody = bodyFor(raw);
  const unchanged = await sync(raw, [[issue(existingBody)]], inputs, { now: '2030-01-01T00:00:00Z' });
  assert.deepEqual(mutations(unchanged.trace), [], 'timestamps alone must not heartbeat');
  const permuted = await sync(bytes('complete-permuted'), [[issue(existingBody)]]);
  assert.deepEqual(mutations(permuted.trace), [], 'wire order/key order do not fingerprint');
  const oldHash = report.fingerprint(report.validateResult(raw, inputs));
  // Independent effective/version change with SAME CVE, no invented raw manifest.
  const manifest = JSON.parse(inputs.manifest), map = JSON.parse(inputs.cpeMap), result = JSON.parse(raw);
  manifest.base_packages.openssh.version = '9.10p1'; map.openssh.version_map['9.10p1'] = '9.10:p1';
  const row = result.manifest.find(r => r.package === 'openssh');
  row.pinnedVersion = '9.10p1'; row.queriedVersion = '9.10:p1'; row.cpe = 'cpe:2.3:a:openbsd:openssh:9.10:p1';
  const inv = result.inventory.find(r => r.identity?.pname === 'openssh');
  inv.identity.version = '9.10p1'; inv.queriedVersion = '9.10:p1'; inv.cpe = row.cpe;
  result.findings[0].version = '9.10:p1';
  const side = { manifest: encode(manifest), cpeMap: encode(map) };
  const changed = await sync(encode(result), [[issue(existingBody)]], side, { name: 'same-CVE-version-only' });
  assert.deepEqual(result.findings.map(f => f.cveId), JSON.parse(raw).findings.map(f => f.cveId));
  assert.notEqual(changed.plan.fingerprint, oldHash, 'IDs-only fingerprint fails');
  assert.deepEqual(mutations(changed.trace).map(c => c.method), ['update', 'createComment']);
  assert.match(mutations(changed.trace)[0].args.body, /9\.10:p1/);
  assert.match(mutations(changed.trace)[1].args.body, /Added\/changed association/);
  assert.match(mutations(changed.trace)[1].args.body, /No longer reported association/);
  const covered = await sync(bytes('incomplete-setup-unavailable'), [[issue(existingBody)]], inputs, { name: 'same-CVE-coverage-only' });
  assert.deepEqual(JSON.parse(bytes('incomplete-setup-unavailable')).findings.map(f => f.cveId), JSON.parse(raw).findings.map(f => f.cveId));
  assert.notEqual(covered.plan.fingerprint, oldHash, 'coverage omitted from fingerprint fails');
  assert.deepEqual(mutations(covered.trace).map(c => c.method), ['update', 'createComment']);
  assert.match(mutations(covered.trace)[1].args.body, /coverage changed/);
  // Score, output identity and retained references independently belong to substantive state.
  for (const [name, change] of [
    ['score', r => { r.findings[0].score = 7.5; }],
    ['metadata-output', r => { r.inventory.find(i => i.identity?.pname === 'openssh').identity.output = 'alternate'; }],
    ['references', r => { const wrapper = r.inventory.find(i => i.kind === 'profile-wrapper'); wrapper.references.reverse(); }]
  ]) {
    const r = JSON.parse(raw); change(r); const delta = await sync(encode(r), [[issue(existingBody)]], inputs, { name });
    if (name === 'references') assert.deepEqual(mutations(delta.trace), [], 'set order quiet');
    else assert.notEqual(delta.plan.fingerprint, oldHash, `${name} omitted fingerprint`);
  }
  const associations = bytes('complete-finding-associations');
  const associationBody = bodyFor(associations), assoc = JSON.parse(associations);
  for (const f of assoc.findings) {
    assert.ok(associationBody.includes(f.url));
    for (const src of f.sources) assert.ok(associationBody.includes(report.escapeMarkdown(src.manifestId || src.path)), 'every source retained');
    for (const id of f.roots) assert.ok(associationBody.includes(report.escapeMarkdown(id)));
  }
  assert.match(associationBody, /declared 9\.9p1/); assert.match(associationBody, /9\.9:p1/);
  assert.equal(report.escapeMarkdown('a|b\n[c](d)<x>`'), 'a&#124;b \\[c\\]\\(d\\)&lt;x&gt;\\`');
  assert.ok(!/[\x00-\x1f\x7f]/.test(report.escapeMarkdown('a\x00\x7fb')));
  const escapeResult = JSON.parse(raw), escapeManifest = JSON.parse(inputs.manifest), escapeMap = JSON.parse(inputs.cpeMap);
  escapeMap.kernel.reason = '|[inject](https://evil.invalid)<script>`';
  escapeResult.manifest.find(r => r.package === 'kernel').reason.detail = escapeMap.kernel.reason;
  escapeResult.coverage.limitations.find(r => r.manifestId === '/kernel').detail = escapeMap.kernel.reason;
  const escapedBody = bodyFor(encode(escapeResult), { manifest: encode(escapeManifest), cpeMap: encode(escapeMap) });
  assert.ok(!escapedBody.includes('<script>')); assert.ok(!escapedBody.includes('[inject](https://evil.invalid)'));
  assert.ok(escapedBody.includes('&#124;')); assert.ok(escapedBody.includes('&lt;script&gt;'));
}

async function reportHistory() {
  const raw = bytes('complete-findings'), body = bodyFor(raw);
  const filler = Array.from({ length: 100 }, (_, i) => ({ number: i + 1000, title: 'unrelated', state: 'open', labels: [] }));
  const closed = issue(body, 'closed');
  const reused = await sync(raw, [filler, [closed]], inputs, { name: 'closed-page-two-reopen-unchanged' });
  assert.deepEqual(reused.trace.filter(c => c.method === 'listForRepo').map(c => c.args.page), [1, 2]);
  for (const call of reused.trace.filter(c => c.method === 'listForRepo')) {
    assert.equal(call.args.state, 'all'); assert.equal(call.args.labels, 'security,auto-triggered');
  }
  assert.deepEqual(mutations(reused.trace).map(c => c.method), ['update']);
  assert.deepEqual(mutations(reused.trace)[0].args, { ...context.repo, issue_number: 151, state: 'open' });
  const differentNumber = await sync(raw, [[issue(body, 'closed', 777)]]);
  assert.equal(mutations(differentNumber.trace)[0].args.issue_number, 777, 'no hardcoded 151');
  const changedClosed = await sync(raw, [[issue('old', 'closed')]]);
  assert.equal(mutations(changedClosed.trace)[0].args.state, 'open');
  assert.ok(mutations(changedClosed.trace)[0].args.body);
  const api = mock([filler, [issue(body), issue(body, 'closed', 152)]]);
  await assert.rejects(report.synchronize({ resultBytes: raw, ...inputs, github: api.github, context }), /ambiguous/);
  assert.deepEqual(mutations(api.trace), [], 'ambiguous history NEVER cleanup/merge/close');
  console.log('API TRACE', JSON.stringify({ scenario: 'ambiguous-page-two', calls: api.trace }));
  const pr = { ...issue(), pull_request: { url: 'offline' } };
  const wrongLabels = { ...issue(), labels: [{ name: 'security' }] };
  const excluded = await sync(raw, [[pr, wrongLabels, { ...issue(), title: 'CVE Report - old timestamp' }]]);
  assert.deepEqual(mutations(excluded.trace).map(c => c.method), ['create'], 'PRs/title-only/partial-label matches excluded');
  const migrated = await sync(raw, [[issue('<!-- cve-fingerprint: CVE-2026-10001 -->')]]);
  assert.deepEqual(mutations(migrated.trace).map(c => c.method), ['update', 'createComment']);
  assert.match(mutations(migrated.trace)[0].args.body, /security-scan-fingerprint:v1:/);
  for (const method of ['listForRepo', 'update']) {
    const failing = mock([[issue('old')]], method);
    await assert.rejects(report.synchronize({ resultBytes: raw, ...inputs, github: failing.github, context }), /offline/);
    if (method === 'listForRepo') assert.deepEqual(mutations(failing.trace), []);
    else assert.deepEqual(mutations(failing.trace).map(c => c.method), ['update'], 'no comment after failed update');
    console.log('API TRACE', JSON.stringify({ scenario: `failed-${method}`, calls: failing.trace }));
  }
}

async function zeroFindings() {
  const complete = bytes('complete-zero'), incomplete = bytes('incomplete-zero');
  const closed = await sync(complete, [[issue('old')]], inputs, { name: 'complete-zero-close' });
  assert.deepEqual(mutations(closed.trace).map(c => c.method), ['update', 'createComment']);
  assert.equal(mutations(closed.trace)[0].args.state, 'closed');
  assert.match(mutations(closed.trace)[0].args.body, /Coverage: \*\*complete\*\*/);
  assert.match(mutations(closed.trace)[1].args.body, /scope is complete/);
  assert.match(mutations(closed.trace)[1].args.body, /not whole-image assurance/);
  for (const pages of [[[]], [[issue('old', 'closed')]]]) {
    const quiet = await sync(complete, pages);
    assert.deepEqual(mutations(quiet.trace), [], 'complete-zero absent/closed no creation or heartbeat');
  }
  for (const state of ['absent', 'open', 'closed']) {
    const pages = state === 'absent' ? [[]] : [[issue('old', state)]];
    const result = await sync(incomplete, pages, inputs, { name: `incomplete-zero-${state}` });
    assert.equal(result.plan.outcome, 'incomplete');
    assert.ok(mutations(result.trace).length > 0);
    assert.ok(!mutations(result.trace).some(c => c.args.state === 'closed'), 'incomplete NEVER closes');
    assert.ok(!mutations(result.trace).some(c => /\bclean\b|Closing/.test(c.args.body || '')), 'no clean/closing message');
    assert.match(mutations(result.trace)[0].args.body, /Coverage: \*\*incomplete\*\*/);
    if (state === 'closed') assert.equal(mutations(result.trace)[0].args.state, 'open');
  }
  const unchangedBody = bodyFor(incomplete);
  const quiet = await sync(incomplete, [[issue(unchangedBody)]]);
  assert.deepEqual(mutations(quiet.trace), [], 'unchanged incomplete also quiet');
  const reopen = await sync(incomplete, [[issue(unchangedBody, 'closed')]]);
  assert.deepEqual(mutations(reopen.trace).map(c => c.method), ['update']);
  assert.equal(mutations(reopen.trace)[0].args.state, 'open', 'closed unchanged incomplete reopens');
}
const scenarios = { 'invalid-report': invalidReport, 'report-delta': reportDelta,
  'report-history': reportHistory, 'zero-findings': zeroFindings };
(async () => {
  assert.ok(scenarios[process.argv[2]], 'known report scenario');
  await scenarios[process.argv[2]]();
  console.log(`PASS: ${process.argv[2]}`);
})().catch(error => { console.error(`FAIL: ${process.argv[2]}: ${error.stack}`); process.exitCode = 1; });

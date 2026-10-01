'use strict';
// Deliberate pre-implementation reds: execute the unchanged inline policy.
// Mutations: skip malformed rows into clean closure; fingerprint only CVE IDs.
const fs = require('node:fs');
const assert = require('node:assert/strict');
const path = require('node:path');
const root = path.resolve(__dirname, '../../../..');
const yaml = fs.readFileSync(path.join(root, '.github/workflows/security-scan.yml'), 'utf8');
const script = yaml.split('          script: |\n')[1]
  .split('\n').map(line => line.replace(/^            /, '')).join('\n');
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
const writes = [];
const mode = process.argv[2];
const existing = { number: 151, title: 'CVE Report — open HIGH/CRITICAL findings',
  body: '<!-- cve-fingerprint: CVE-2026-10001 -->', state: 'open' };
const issues = { listForRepo: async () => ({ data: [existing] }) };
for (const name of ['create', 'update', 'createComment']) {
  issues[name] = async args => { writes.push({ name, args }); return { data: { number: 151 } }; };
}
process.env.FINDINGS_TSV = mode === 'malformed' ? 'malformed\trow'
  : 'CVE-2026-10001\topenssh\t9.10p1\t7\tHIGH\thttps://nvd.nist.gov/vuln/detail/CVE-2026-10001';
new AsyncFunction('github', 'core', 'context', script)(
  { rest: { issues } }, { info() {}, warning() {} }, { repo: { owner: 'offline', repo: 'fixture' } }
).then(() => {
  console.log(JSON.stringify({ mode, input: process.env.FINDINGS_TSV, writes }, null, 2));
  if (mode === 'malformed') assert.equal(writes.length, 0, 'malformed TSV must cause ZERO writes');
  else assert.ok(writes.some(w => w.name === 'update'), 'same CVE changed version must refresh');
}).catch(error => { console.error(error); process.exitCode = 1; });

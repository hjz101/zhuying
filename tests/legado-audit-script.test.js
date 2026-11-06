import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { auditPackage, compareEvidence, publicSmoke, tokenize } from '../ios/scripts/audit-legado-source.mjs';

const script = fileURLToPath(new URL('../ios/scripts/audit-legado-source.mjs', import.meta.url));
const packageFixture = (overrides = {}) => ({
  bookSourceUrl: 'opaque-identity', searchUrl: '<js>java.ajax("https://example.test/search?token=secret-query")</js>',
  ruleSearch: { bookList: '$.data', name: '$.name', bookUrl: '$.url' },
  ruleBookInfo: { intro: '<js>book.setUseReplaceRule(false); result</js>' },
  ruleToc: { chapterList: '$.data', chapterName: '$.name', chapterUrl: '$.url' },
  ruleContent: { content: '$.content' }, ...overrides
});
const capability = { methods: new Set(['java.ajax']), workerSHA256: 'a'.repeat(64), bridgeSHA256: 'b'.repeat(64) };
const audit = source => auditPackage(Buffer.from(JSON.stringify(source)), source, capability);

test('audit reports required shape and missing direct hosts without printing source or sensitive values', () => {
  const report = audit(packageFixture({ unknownSecretField: 'secret-unknown', loginUi: '[{"name":"secret-login"}]', jsLib: 'source.putLoginInfo("secret-body"); java.secretAccountKey("secret-key");' }));
  assert.equal(report.execution, 'not-performed');
  assert.equal(report.sources[0].requiredShape, true);
  assert.equal(report.sources[0].identityKind, 'opaque-or-missing');
  assert.ok(report.sources[0].directCalls.some(row => row.method === 'book.setUseReplaceRule' && row.coverage === 'missing-native-dispatch'));
  assert.ok(report.sources[0].directCalls.some(row => row.method === 'java.ajax' && row.coverage === 'native-dispatch-present'));
  const output = JSON.stringify(report);
  for (const value of ['secret-query', 'secret-body', 'secret-key', 'secretAccountKey', 'secret-unknown', 'secret-login', 'opaque-identity', '<js>']) assert.ok(!output.includes(value), value);
});

test('comments, quoted mentions and regex literals cannot masquerade as executed direct calls', () => {
  const report = audit(packageFixture({ searchUrl: '<js>/* java.toast("no") */ const a=/java.log\("no"\)/; if (a) /java.post\("no"\)/.test("x"); const b="java.get(\"no\")"; // java.head("no")\n java["ajax"]("https://example.test/");</js>' }));
  assert.deepEqual(report.sources[0].directCalls.filter(row => row.field === 'searchUrl').map(row => row.method), ['java.ajax']);
  assert.deepEqual(report.sources[0].scanErrors, []);
});

test('template substitutions and embedded page scripts have different coverage', () => {
  const report = audit(packageFixture({ jsLib: 'const a=`text ${source.getVariable()} end`; const html=`<script>source.setVariable("secret"); java.toast("private");</script>`;' }));
  const calls = report.sources[0].directCalls;
  assert.ok(calls.some(row => row.method === 'source.getVariable' && row.context === 'rule-or-library'));
  assert.ok(calls.some(row => row.method === 'source.setVariable' && row.context === 'embedded-page' && row.coverage === 'page-bridge-not-proven'));
  assert.equal(report.sources[0].embeddedScripts, 1);
  assert.ok(!JSON.stringify(report).includes('private'));
});

test('dynamic members and incomplete lexical scans remain explicit rather than implying compatibility', () => {
  const report = audit(packageFixture({ jsLib: 'java[computed](1);', loginUrl: 'const value="unterminated' }));
  assert.equal(report.sources[0].dynamicMemberSites, 1);
  assert.deepEqual(report.sources[0].scanErrors, [{ field: 'loginUrl', code: 'unterminated-string' }]);
  assert.equal(audit(packageFixture({ ruleToc: { chapterList: '$.data' } })).sources[0].requiredShape, false);
  assert.throws(() => tokenize('x'.repeat(2 * 1024 * 1024 + 1)), /text-limit/);
});

test('literal URL candidates preserve only origins and keep HTTP visibly unsupported', () => {
  const report = audit(packageFixture({ jsLib: 'const urls=["https://example.test/path?api_key=hidden#secret","http://plain.test/auth?token=hidden","https://name:private@credential.test/"];' }));
  assert.deepEqual(report.sources[0].literalOriginCandidates, [{ origin: 'http://plain.test', policy: 'http-unsupported' }, { origin: 'https://example.test', policy: 'requires-source-origin-policy' }]);
  for (const secret of ['api_key', 'hidden', 'secret', 'private', 'credential.test']) assert.ok(!JSON.stringify(report).includes(secret));
});

test('malformed source files and argument errors are redacted and fail closed', () => {
  const root = mkdtempSync(join(tmpdir(), 'legado-audit-test-'));
  try {
    const path = join(root, 'private-token-path.json');
    writeFileSync(path, '{secret-body');
    for (const args of [['audit', path], ['audit', '/missing/private-key.json'], ['public-smoke', 'https://evil.test/?secret=1'], []]) {
      const result = spawnSync(process.execPath, [script, ...args], { encoding: 'utf8' });
      assert.equal(result.status, 1);
      assert.ok(!result.stderr.includes('private-'));
      assert.ok(!result.stderr.includes('secret-body'));
      assert.ok(!result.stderr.includes('evil.test'));
    }
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test('CLI audits local files without requiring their code to be valid or evaluating code', () => {
  const root = mkdtempSync(join(tmpdir(), 'legado-audit-test-'));
  try {
    const path = join(root, 'source.json');
    writeFileSync(path, JSON.stringify(packageFixture({ jsLib: 'throw new Error("must-not-run");' })));
    const result = spawnSync(process.execPath, [script, 'audit', path], { encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr);
    const report = JSON.parse(result.stdout);
    assert.equal(report.sources[0].requiredShape, true);
    assert.ok(!result.stdout.includes('must-not-run'));
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test('anonymous smoke can only request the two fixed HTTPS root paths with no credentials or redirects', async () => {
  const requests = []; let canceled = 0;
  const report = await publicSmoke(async (url, options) => {
    requests.push({ url, options });
    return { status: 302, body: { async cancel() { canceled++; } }, headers: { get() { return 'https://evil.test/?secret-key'; } } };
  });
  assert.deepEqual(requests.map(row => row.url), ['https://v5.langge.uk/', 'https://v4.langge.uk/']);
  for (const { options } of requests) {
    assert.equal(options.method, 'GET'); assert.equal(options.redirect, 'manual'); assert.equal(options.credentials, 'omit');
    assert.deepEqual(Object.keys(options.headers), ['User-Agent']); assert.equal(options.body, undefined);
  }
  assert.equal(canceled, 2);
  assert.equal(report.authentication, 'not-attempted');
  assert.ok(!JSON.stringify(report).includes('secret-key'));
});

test('anonymous smoke errors never echo native fetch error URLs, headers or bodies', async () => {
  const report = await publicSmoke(async () => { throw new Error('https://private.test/?secret=token'); });
  assert.ok(report.results.every(row => row.error === 'connection-failed'));
  assert.ok(!JSON.stringify(report).includes('private.test'));
});

const evidence = implementation => ({ schemaVersion: 1, implementation, sourceSHA256: 'a'.repeat(64), referenceRevision: 'fd026e0', binarySHA256: 'b'.repeat(64), fixtureSHA256: 'c'.repeat(64), captureMode: 'offline-fixture', capturedAt: '2026-11-06T00:00:00Z', scenarios: ['search', 'details', 'catalog', 'content'].map(stage => ({ fixtureID: 'fixed-response', stage, outputSHA256: 'd'.repeat(64), itemCount: 1, utf16Count: 200 })) });

test('comparison checks four-stage fixture hashes while explicitly declining to attest APK or live execution', () => {
  const result = compareEvidence(evidence('legado-android'), evidence('zhuying-ios'));
  assert.equal(result.consistency, 'matched');
  assert.equal(result.runtimeVerification, 'not-performed-by-this-tool');
  assert.equal(result.liveVerification, 'not-performed');
  assert.equal(result.provenance, 'caller-supplied-not-attested');
  const changed = evidence('zhuying-ios'); changed.scenarios[3].outputSHA256 = 'e'.repeat(64);
  const difference = compareEvidence(evidence('legado-android'), changed);
  assert.equal(difference.consistency, 'different');
  assert.deepEqual(difference.mismatches, [{ scenarioIndex: 3, stage: 'content' }]);
});

test('comparison rejects claims of live/cache success, missing APK provenance, partial stages or unredacted fields', () => {
  for (const mutate of [value => { value.binarySHA256 = ''; }, value => { value.captureMode = 'live'; }, value => { value.scenarios.pop(); }, value => { value.status = 'passed'; }, value => { value.scenarios[0].requestURL = 'https://example.test/?token=private'; }, value => { value.sourceSHA256 = 'e'.repeat(64); }]) {
    const value = evidence('zhuying-ios'); mutate(value);
    assert.throws(() => compareEvidence(evidence('legado-android'), value), /invalid-evidence|mismatched-evidence/);
  }
});

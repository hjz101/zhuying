import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';

test('candidate metadata rejects platform confusion and retains its unapproved status', () => {
  const script = `
import importlib.util, pathlib, plistlib, tempfile
spec=importlib.util.spec_from_file_location('candidate','ios/scripts/package-candidate.py')
module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
with tempfile.TemporaryDirectory() as root:
 app=pathlib.Path(root)/'Yueshan.app'; app.mkdir()
 info={'CFBundleIdentifier':'test.reader','CFBundleShortVersionString':'0.4.0','CFBundleVersion':'2','CFBundleSupportedPlatforms':['iPhoneSimulator'],'MinimumOSVersion':'17.0','YueshanSourceRevision':'a'*40}
 (app/'Info.plist').write_bytes(plistlib.dumps(info))
 record=module.metadata(app,'a'*40,'simulator')
 assert record['releaseGate']=='not-approved' and record['uploaded'] is False
 assert record['version']=='0.4.0' and record['commit']=='a'*40
 for commit,kind in [('a'*40,'unsigned-device'),('short','simulator'),('b'*40,'simulator')]:
  try: module.metadata(app,commit,kind)
  except ValueError: pass
  else: raise AssertionError('Invalid candidate metadata was accepted')
`;
  assert.doesNotThrow(() => execFileSync('python3', ['-c', script], { stdio: 'pipe' }));
});

test('historical release evidence remains unapproved while current physical and performance gates stay open', () => {
  const read = path => readFileSync(new URL(path, import.meta.url), 'utf8');
  const plan = read('../docs/DEVELOPMENT-PLAN.md');
  for (const id of ['T035', 'T036', 'T037', 'T038']) {
    assert.ok(plan.includes(`| [ ] ${id} |`), `${id} still needs real acceptance`);
  }
  const probe = JSON.parse(read('../docs/verification/2026-11-06/source-feasibility-unavailable.json'));
  assert.equal(probe.status, 'failed'); assert.equal(probe.works.length, 0);
  assert.equal(probe.requests.length, 30);
  assert.ok(probe.requests.some(request => request.httpStatus === 201));
  assert.ok(probe.requests.some(request => request.httpStatus === 503));
  function inspect(value) {
    if (!value || typeof value !== 'object') return;
    for (const [key, child] of Object.entries(value)) {
      assert.doesNotMatch(key, /^(password|apiKey|email|nickname|deviceID|authenticationHeader|headers|httpBody|rawResponse|content)$/i);
      inspect(child);
    }
  }
  inspect(probe);
  const classics = JSON.parse(read('../docs/verification/2026-11-06/source-classics-unavailable.json'));
  assert.equal(classics.status, 'failed'); assert.equal(classics.works.length, 0);
  assert.equal(classics.requests.length, 34);
  assert.deepEqual(classics.events.filter(event => event.stage === 'search').map(event => event.query), ['西游记', '红楼梦']);
  inspect(classics);
  const rawBudget = read('../ios/YueshanTestSupport/performance-budget.json');
  const budget = JSON.parse(rawBudget);
  const performance = JSON.parse(read('../docs/verification/2026-11-06/stage-four-performance.json'));
  const launch = JSON.parse(read('../docs/verification/2026-11-06/stage-four-launch.json'));
  assert.equal(performance.budgetSHA256, createHash('sha256').update(rawBudget).digest('hex'));
  assert.deepEqual(performance.scales, budget.scales);
  for (const metric of [...performance.measurements, launch]) {
    assert.equal(metric.maximum, Math.max(...metric.samples));
    assert.equal(metric.limit, budget.limits[metric.id]);
    assert.equal(metric.withinTarget, metric.maximum <= metric.limit);
  }
  assert.equal(launch.withinTarget, false);
  assert.equal(performance.measurements.find(metric => metric.id === 'process.peak-rss.mib').withinTarget, false);
  const validation = JSON.parse(read('../docs/verification/2026-11-06/stage-three-four-validation.json'));
  assert.equal(validation.functionalValidation.iosUnitTests, 239);
  assert.equal(validation.functionalValidation.uniqueIOSUIFlows, 67);
  assert.equal(validation.uiFlows.length, 67);
  assert.deepEqual(validation.functionalValidation.unresolvedFunctionalFailures, []);
  assert.equal(validation.releaseGate, 'not-approved');
  const native = JSON.parse(read('../docs/verification/2026-11-06/native-app-performance.json'));
  assert.equal(native.contentPreserved, true);
  assert.ok(native.utf16Units >= 100_000 && native.pages > 1 && native.peakRSSMiB > 0);
  assert.match(native.method, /without XCTest injection/);
  assert.match(native.method, /excludes dyld/);
  assert.match(native.method, /does not replace frozen XCTest criteria/);
  assert.match(read('../docs/release/2026-11-06-candidate.md'), /尚未达到 G3/);
});

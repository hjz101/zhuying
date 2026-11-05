import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';

const read = path => readFileSync(new URL(path, import.meta.url));
const raw = read('../ios/YueshanTestSupport/performance-budget.json');
const budget = JSON.parse(raw);
const baseline = JSON.parse(read('../docs/verification/2026-11-05/performance-baseline-v1.json'));
const launch = JSON.parse(read('../docs/verification/2026-11-05/launch-baseline-v1.json'));
const source = JSON.parse(read('../docs/verification/2026-11-05/source-feasibility-unavailable.json'));

test('step-zero evidence uses the exact frozen budget and records every required metric', () => {
  assert.equal(baseline.budgetSHA256, createHash('sha256').update(raw).digest('hex'));
  assert.equal(baseline.profile, budget.profile);
  assert.equal(launch.profile, budget.profile);
  assert.deepEqual(baseline.scales, budget.scales);
  assert.ok(Date.parse(budget.frozenAt) < Date.parse(baseline.measuredAt));
  const metrics = [...baseline.measurements, launch];
  assert.deepEqual(metrics.map(x => x.id).sort(), Object.keys(budget.limits).sort());
  assert.equal(new Set(metrics.map(x => x.id)).size, metrics.length);
});

test('recorded raw samples determine all maxima, medians and target results, including misses', () => {
  for (const metric of [...baseline.measurements, launch]) {
    assert.ok(metric.samples.every(x => Number.isFinite(x) && x > 0), metric.id);
    let count = budget.samples;
    if (metric.id.startsWith('library.')) count = budget.storageSamples;
    if (metric.id === 'shelf.sort.ms') count *= 3;
    if (metric.id === 'process.peak-rss.mib') count = 1;
    assert.equal(metric.samples.length, count, metric.id);
    assert.equal(metric.maximum, Math.max(...metric.samples), metric.id);
    if ('median' in metric) assert.equal(metric.median, [...metric.samples].sort((a, b) => a - b)[Math.floor(count / 2)], metric.id);
    assert.equal(metric.limit, budget.limits[metric.id], metric.id);
    assert.equal(metric.withinTarget, metric.maximum <= metric.limit, metric.id);
  }
});

test('unavailable real sources remain a failed gate after both requested works were attempted', () => {
  assert.equal(source.sourceID, 'shushan');
  assert.equal(source.status, 'failed');
  assert.equal(source.works.length, 0);
  assert.deepEqual(source.events.filter(x => x.stage === 'search').map(x => x.query), ['我在精神病院学斩神', '诡秘之主']);
  assert.equal(source.events.filter(x => x.stage === 'work-unavailable').length, 2);
  assert.ok(source.requests.some(x => x.endpoint === 'content' && x.httpStatus === 201));
  assert.ok(source.requests.some(x => x.endpoint === 'content' && x.httpStatus === 503));
  const plan = read('../docs/DEVELOPMENT-PLAN.md').toString('utf8');
  assert.match(plan, /\| \[ \] T003 \|/, 'A failed real probe must not mark T003 complete');
});

test('source evidence contains only approved metadata and no credential or raw prose fields', () => {
  const origin = new URL(source.host);
  assert.equal(origin.protocol, 'https:');
  assert.equal(origin.username + origin.password + origin.search + origin.hash, '');
  const requestKeys = new Set(['endpoint', 'method', 'httpStatus', 'responseBytes', 'milliseconds', 'shape', 'businessResult']);
  for (const record of source.requests) {
    Object.keys(record).forEach(key => assert.ok(requestKeys.has(key), key));
    assert.ok(['search', 'details', 'catalog', 'content'].includes(record.endpoint));
    assert.ok(Number.isFinite(record.milliseconds) && record.milliseconds >= 0);
  }
  function inspect(value) {
    if (!value || typeof value !== 'object') return;
    for (const [key, child] of Object.entries(value)) {
      assert.doesNotMatch(key, /^(password|apiKey|email|nickname|deviceID|authenticationHeader|headers|httpBody|rawResponse|content)$/i);
      inspect(child);
    }
  }
  inspect(source);
});

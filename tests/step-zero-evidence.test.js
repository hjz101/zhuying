import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';

const read = path => readFileSync(new URL(path, import.meta.url));
const raw = read('../ios/YueshanTestSupport/performance-budget.json');
const budget = JSON.parse(raw);
const baseline = JSON.parse(read('../docs/verification/2026-11-05/performance-baseline-v1.json'));
const launch = JSON.parse(read('../docs/verification/2026-11-05/launch-baseline-v1.json'));

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

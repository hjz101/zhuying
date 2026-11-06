import test from 'node:test';
import assert from 'node:assert/strict';
import { createGateway, sourceConfiguration } from '../backend/reader-gateway.mjs';
const token = 'original-test-token-at-least-16';
const sources = { original: { origin: 'https://source.example', paths: ['/search', '/chapters/'] } };
const value = { sourceID: 'original', sourceOrigin: 'https://source.example', path: '/search?q=中文', method: 'GET', headers: { Authorization: 'source-test-key' } };
async function setup(t, options = {}) {
  const server = createGateway({ token, sources, ...options }); await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => { server.closeAllConnections(); server.close(resolve); }));
  return async (input = value, auth = token, path = '/v1/forward') => fetch(`http://127.0.0.1:${server.address().port}${path}`, { method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${auth}` }, body: JSON.stringify(input) });
}
test('gateway authenticates and forwards only a configured source, preserving upstream errors', async t => {
  let called = 0;
  const send = await setup(t, { fetchImpl: async (url, options) => {
    called++; assert.equal(url.origin, 'https://source.example'); assert.equal(options.redirect, 'manual'); assert.equal(options.headers.authorization, 'source-test-key');
    return new Response('源站限流', { status: 429, headers: { 'retry-after': '5', 'set-cookie': 'never-forward' } });
  } });
  assert.equal((await send(value, 'incorrect')).status, 401); assert.equal(called, 0);
  const response = await send(), result = await response.json(); assert.equal(response.status, 200); assert.equal(result.status, 429); assert.equal(Buffer.from(result.bodyBase64, 'base64').toString(), '源站限流'); assert.equal(result.headers['set-cookie'], undefined);
});
test('gateway rejects unselected hosts, forbidden paths, credential redirection and oversized responses', async t => {
  let called = 0; const send = await setup(t, { fetchImpl: async () => { called++; return new Response(null, { status: 302, headers: { location: 'https://other.example' } }); } });
  for (const input of [{ ...value, sourceID: 'other' }, { ...value, sourceOrigin: 'https://different.example' }, { ...value, path: '//evil.example/search' }, { ...value, path: '/chapters/../private' }, { ...value, path: '/private' }, { ...value, headers: { Host: 'evil.example' } }]) assert.ok((await send(input)).status >= 400);
  assert.equal(called, 0); assert.equal((await send()).status, 502); assert.equal(called, 1);
  const tooLarge = await setup(t, { fetchImpl: async () => new Response('x', { headers: { 'content-length': String(5 * 1024 * 1024) } }) });
  assert.equal((await tooLarge()).status, 502);
});
test('gateway bounds actual streams and maps timeouts without exposing credentials', async t => {
  const send = await setup(t, { fetchImpl: async () => new Response(new Uint8Array(4 * 1024 * 1024 + 1)) }); assert.equal((await send()).status, 502);
  const timed = await setup(t, { timeoutMS: 20, fetchImpl: async (_, { signal }) => new Promise((resolve, reject) => signal.addEventListener('abort', () => reject(new Error('secret source key')), { once: true })) });
  const response = await timed(); assert.equal(response.status, 504); assert.deepEqual(await response.json(), { error: 'upstream_timeout' });
});
test('gateway configuration excludes embedded credentials and implicit all-path forwarding', () => {
  for (const config of [{ a: { origin: 'http://source.example', paths: ['/'] } }, { a: { origin: 'https://user:secret@source.example', paths: ['/'] } }, { a: { origin: 'https://source.example', paths: [] } }]) assert.throws(() => sourceConfiguration(config));
});

test('gateway returns a bounded request error without forwarding an oversized or invalid POST', async t => {
  let calls = 0; const send = await setup(t, { fetchImpl: async () => { calls++; return new Response('should not run'); } });
  const tooLarge = await send({ ...value, padding: 'x'.repeat(1024 * 1024 + 1) });
  assert.equal(tooLarge.status, 413); assert.deepEqual(await tooLarge.json(), { error: 'request_too_large' });
  const invalid = await send({ ...value, method: 'POST', bodyBase64: '!invalid!' }); assert.equal(invalid.status, 400);
  assert.equal(calls, 0);
});

test('gateway connection probe verifies authentication and source binding without forwarding a root path', async t => {
  let calls = 0; const send = await setup(t, { fetchImpl: async () => { calls++; return new Response('unused'); } });
  const probe = { sourceID: 'original', sourceOrigin: 'https://source.example' };
  const response = await send(probe, token, '/v1/status'); assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { version: 1, ready: true, sourceID: 'original', sourceOrigin: 'https://source.example' });
  assert.equal((await send(probe, 'wrong', '/v1/status')).status, 401);
  assert.equal((await send({ ...probe, sourceOrigin: 'https://other.example' }, token, '/v1/status')).status, 403);
  assert.equal(calls, 0);
});

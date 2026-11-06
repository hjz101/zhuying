import http from 'node:http';
import { timingSafeEqual } from 'node:crypto';
import { pathToFileURL } from 'node:url';

const MAX_REQUEST = 1024 * 1024;
const MAX_RESPONSE = 4 * 1024 * 1024;
const allowedHeaders = new Set(['accept', 'content-type', 'authorization', 'cookie', 'x-api-key', 'x-device-id', 'x-novel-token', 'x-device-type', 'user-agent']);
const responseHeaders = new Set(['content-type', 'retry-after']);
class GatewayError extends Error { constructor(status, code) { super(code); this.status = status; } }
const invalid = () => { throw new GatewayError(400, 'invalid_request'); };
export function sourceConfiguration(input) {
  if (!input || typeof input !== 'object' || Array.isArray(input) || Object.keys(input).length > 100) invalid();
  return new Map(Object.entries(input).map(([id, value]) => {
    if (!/^[\w.-]{1,120}$/.test(id) || !value || typeof value !== 'object') invalid();
    const url = new URL(value.origin);
    if (url.protocol !== 'https:' || url.username || url.password || url.search || url.hash || url.pathname !== '/') invalid();
    if (!Array.isArray(value.paths) || !value.paths.length || value.paths.length > 100 || value.paths.some(p => typeof p !== 'string' || !/^\/[A-Za-z0-9_/-]*$/.test(p))) invalid();
    // A trailing slash explicitly authorizes a subtree; otherwise this is an exact path.
    return [id, { origin: url.origin, paths: value.paths }];
  }));
}
async function body(request) {
  let total = 0; const chunks = [];
  for await (const chunk of request.iterator({ destroyOnReturn: false })) { total += chunk.length; if (total > MAX_REQUEST) { request.resume(); throw new GatewayError(413, 'request_too_large'); } chunks.push(chunk); }
  try { return JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch { invalid(); }
}
function authorize(actual, expected) {
  const first = Buffer.from(actual || ''), second = Buffer.from(`Bearer ${expected}`);
  return first.length === second.length && timingSafeEqual(first, second);
}
export function createGateway({ token, sources, fetchImpl = fetch, timeoutMS = 15000 }) {
  if (typeof token !== 'string' || token.length < 16 || token.length > 8192 || /[\r\n]/.test(token)) throw new Error('Configure a gateway token of at least 16 characters.');
  const configured = sourceConfiguration(sources);
  let inFlight = 0;
  return http.createServer({ maxHeaderSize: 16 * 1024, requestTimeout: 20000, headersTimeout: 10000 }, async (request, response) => {
    const reply = (status, value) => { if (!response.destroyed) response.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' }).end(JSON.stringify(value)); };
    if (inFlight >= 8) { request.resume(); reply(503, { error: 'busy' }); return; }
    inFlight++;
    const controller = new AbortController(); let timedOut = false;
    const timer = setTimeout(() => { timedOut = true; controller.abort(); if (!request.complete) request.destroy(); }, timeoutMS);
    response.on('close', () => { if (!response.writableFinished) controller.abort(); });
    try {
      if (request.method !== 'POST' || !['/v1/forward', '/v1/status'].includes(request.url)) throw new GatewayError(404, 'not_found');
      if (!authorize(request.headers.authorization, token)) throw new GatewayError(401, 'unauthorized');
      if (!/^application\/json(?:;|$)/i.test(request.headers['content-type'] || '')) invalid();
      const value = await body(request), source = configured.get(value.sourceID);
      if (!source) throw new GatewayError(403, 'source_not_allowed');
      let requestedOrigin; try { requestedOrigin = new URL(value.sourceOrigin); } catch { invalid(); }
      if (requestedOrigin.origin !== source.origin || requestedOrigin.username || requestedOrigin.password || requestedOrigin.pathname !== '/' || requestedOrigin.search || requestedOrigin.hash) throw new GatewayError(403, 'source_origin_mismatch');
      if (request.url === '/v1/status') { reply(200, { version: 1, ready: true, sourceID: value.sourceID, sourceOrigin: source.origin }); return; }
      if (typeof value.path !== 'string' || value.path.length > 8192 || !value.path.startsWith('/') || value.path.startsWith('//') || /[\\\r\n#]/.test(value.path)) invalid();
      const target = new URL(value.path, source.origin);
      if (target.origin !== source.origin || !source.paths.some(p => p.endsWith('/') ? target.pathname.startsWith(p) : target.pathname === p)) throw new GatewayError(403, 'path_not_allowed');
      if (!['GET', 'POST'].includes(value.method) || !value.headers || typeof value.headers !== 'object' || Array.isArray(value.headers) || Object.keys(value.headers).length > 12) invalid();
      const headers = {};
      for (const [key, field] of Object.entries(value.headers)) {
        if (!allowedHeaders.has(key.toLowerCase()) || typeof field !== 'string' || field.length > 16384 || /[\r\n]/.test(field)) invalid();
        headers[key.toLowerCase()] = field;
      }
      let payload;
      if (value.bodyBase64 !== undefined && value.bodyBase64 !== null) {
        if (value.method !== 'POST' || typeof value.bodyBase64 !== 'string' || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value.bodyBase64)) invalid();
        payload = Buffer.from(value.bodyBase64, 'base64'); if (payload.length > 512 * 1024) throw new GatewayError(413, 'request_too_large');
      }
      const upstream = await fetchImpl(target, { method: value.method, headers, body: payload, redirect: 'manual', signal: controller.signal });
      // Never follow redirects carrying source credentials, including same-origin redirects.
      if (upstream.status >= 300 && upstream.status < 400) { await upstream.body?.cancel(); throw new GatewayError(502, 'upstream_redirect'); }
      const contentLength = upstream.headers.get('content-length');
      if (contentLength !== null && (!/^\d+$/.test(contentLength) || Number(contentLength) > MAX_RESPONSE)) { await upstream.body?.cancel(); throw new GatewayError(502, 'upstream_too_large'); }
      let length = 0; const chunks = [];
      for await (const chunk of upstream.body || []) { length += chunk.length; if (length > MAX_RESPONSE) throw new GatewayError(502, 'upstream_too_large'); chunks.push(chunk); }
      const filtered = {}; upstream.headers.forEach((v, k) => { if (responseHeaders.has(k) && v.length <= 8192) filtered[k] = v; });
      reply(200, { version: 1, status: upstream.status, headers: filtered, bodyBase64: Buffer.concat(chunks).toString('base64') });
    } catch (error) { reply(error instanceof GatewayError ? error.status : timedOut ? 504 : 502, { error: error instanceof GatewayError ? error.message : timedOut ? 'upstream_timeout' : 'upstream_unavailable' }); }
    finally { inFlight--; clearTimeout(timer); controller.abort(); }
  });
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const server = createGateway({ token: process.env.ZHUYING_GATEWAY_TOKEN, sources: JSON.parse(process.env.ZHUYING_GATEWAY_SOURCES || '{}') });
  const port = Number(process.env.PORT || 8787), host = process.env.ZHUYING_GATEWAY_HOST || '127.0.0.1';
  server.listen(port, host, () => console.log(`Reader gateway listening on ${host}:${port}; use an HTTPS reverse proxy.`));
}

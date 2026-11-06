#!/usr/bin/env node
// Read-only diagnostics. No source program is evaluated, imported or logged.
import { readFileSync, statSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { dirname, resolve, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const project = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const roots = new Set(['java', 'source', 'book', 'chapter', 'cookie', 'cache']);
const knownMembers = new Set(('ajax get post head connect put getString getStringList getElements getCookie getWebViewUA timeFormat timeFormatUTC base64Encode base64Decode encodeURI decodeURI md5Encode hexDecodeToString startBrowserAwait showBrowser startBrowser showReadingBrowser startBrowserDp toast longToast log createSymmetricCrypto deviceID androidId qread reLoginView refreshExplore getVariable setVariable putVariable getKey getBookSourceUrl getBookSourceName getUrl getName getTitle getAuthor getTocUrl getBookUrl getChapterUrl getChapterIndex getIndex getLoginInfo getLoginInfoMap putLoginInfo getLoginHeader putLoginHeader setLoginHeader getHeaderMap deleteLoginInfo setUseReplaceRule getUseReplaceRule setReSegment getReSegment getFromMemory putMemory delete remove getKey setCookie removeCookie').split(' '));
const sections = {
  ruleSearch: ['bookList', 'name', 'author', 'bookUrl', 'coverUrl', 'intro', 'kind', 'lastChapter', 'wordCount', 'checkKeyWord'],
  ruleBookInfo: ['init', 'name', 'author', 'intro', 'kind', 'lastChapter', 'wordCount', 'coverUrl', 'tocUrl', 'canReName', 'downloadUrls'],
  ruleToc: ['preUpdateJs', 'chapterList', 'chapterName', 'chapterUrl', 'isVolume', 'isVip', 'isPay', 'updateTime', 'nextTocUrl'],
  ruleContent: ['content', 'nextContentUrl', 'webJs', 'sourceRegex', 'replaceRegex', 'payAction', 'imageStyle'],
  ruleExplore: ['bookList', 'name', 'author', 'bookUrl', 'coverUrl', 'intro', 'kind', 'lastChapter', 'wordCount']
};
const topStrings = ['bookSourceUrl', 'searchUrl', 'header', 'jsLib', 'loginUrl', 'loginUi', 'exploreUrl', 'eventListener', 'customButton'];
const required = ['searchUrl', 'ruleSearch.bookList', 'ruleSearch.name', 'ruleSearch.bookUrl', 'ruleToc.chapterList', 'ruleToc.chapterName', 'ruleToc.chapterUrl', 'ruleContent.content'];
const limits = { packageBytes: 5 * 1024 * 1024, sources: 1000, textBytes: 2 * 1024 * 1024, tokens: 200000, nesting: 64 };
const sha256 = data => createHash('sha256').update(data).digest('hex');
const fail = code => { throw new Error(code); };

function boundedJSON(path, maximum = limits.packageBytes) {
  if (!path || !statSync(path).isFile() || statSync(path).size > maximum) fail('input-limit-or-type');
  const bytes = readFileSync(path);
  try { return { bytes, value: JSON.parse(bytes.toString('utf8')) }; }
  catch { fail('invalid-json'); }
}

// This scanner distinguishes comments, quoted strings, template substitutions,
// and regular expressions. It is an inventory, not a JavaScript parser or a
// reachability proof. Only direct member calls can be classified statically.
export function tokenize(text) {
  if (Buffer.byteLength(text) > limits.textBytes) fail('text-limit');
  const tokens = [], literals = [];
  let at = 0, line = 1;
  const emit = (value, type = 'punctuation', startLine = line) => {
    if (tokens.length >= limits.tokens) fail('token-limit');
    tokens.push({ value, type, line: startLine });
  };
  const step = () => { const char = text[at++]; if (char === '\n') line++; return char; };
  const escape = () => {
    const char = step();
    if (char === 'n') return '\n'; if (char === 'r') return '\r'; if (char === 't') return '\t';
    if (char === '\n') return '';
    if ((char === 'u' || char === 'x') && new RegExp(`^[0-9a-f]{${char === 'u' ? 4 : 2}}$`, 'i').test(text.slice(at, at + (char === 'u' ? 4 : 2)))) {
      const length = char === 'u' ? 4 : 2, value = String.fromCharCode(parseInt(text.slice(at, at + length), 16)); at += length; return value;
    }
    return char ?? '';
  };
  function code(stopAtBrace = false, depth = 0) {
    if (depth > limits.nesting) fail('nesting-limit');
    let braces = 0, regexAllowed = true, previous = '', parens = [];
    while (at < text.length) {
      const char = text[at], next = text[at + 1], startLine = line;
      if (/\s/.test(char)) { step(); continue; }
      // Legado script markers belong to the rule container, not JS regexes.
      const marker = text.slice(at, at + 5).toLowerCase();
      if (marker === '</js>' || marker.slice(0, 4) === '<js>') {
        at += marker === '</js>' ? 5 : 4; emit(';'); regexAllowed = true; previous = ''; continue;
      }
      if (char === '/' && next === '/') { while (at < text.length && step() !== '\n') {} continue; }
      if (char === '/' && next === '*') {
        at += 2; let closed = false;
        while (at < text.length) { if (text[at] === '*' && text[at + 1] === '/') { at += 2; closed = true; break; } step(); }
        if (!closed) fail('unterminated-comment'); continue;
      }
      if (char === '"' || char === "'") {
        at++; let value = '', closed = false;
        while (at < text.length) {
          const current = step();
          if (current === char) { closed = true; break; }
          if (current === '\\') value += escape(); else value += current;
        }
        if (!closed) fail('unterminated-string');
        emit(value, 'string', startLine); literals.push({ value, line: startLine }); regexAllowed = false; previous = 'value'; continue;
      }
      if (char === '`') {
        at++; emit(';'); let value = '', literalLine = startLine, closed = false;
        while (at < text.length) {
          const current = step();
          if (current === '`') { closed = true; break; }
          if (current === '\\') { value += escape(); continue; }
          if (current === '$' && text[at] === '{') {
            at++; literals.push({ value, line: literalLine }); value = ''; emit(';'); code(true, depth + 1); emit(';'); literalLine = line;
          } else value += current;
        }
        if (!closed) fail('unterminated-template');
        literals.push({ value, line: literalLine }); emit(';'); regexAllowed = false; previous = 'value'; continue;
      }
      if (char === '/' && regexAllowed && next !== '=') {
        at++; let inClass = false, closed = false;
        while (at < text.length) {
          const current = step();
          if (current === '\\') { if (at < text.length) step(); continue; }
          if (current === '[') inClass = true; else if (current === ']') inClass = false;
          else if (current === '/' && !inClass) { closed = true; break; }
          if (current === '\n') fail('unterminated-regex');
        }
        if (!closed) fail('unterminated-regex');
        while (/[a-z]/i.test(text[at] ?? '') && at < text.length) at++;
        emit('regexp', 'regexp', startLine); regexAllowed = false; previous = 'value'; continue;
      }
      if (/[A-Za-z_$]/.test(char)) {
        const start = at++; while (at < text.length && /[A-Za-z0-9_$]/.test(text[at])) at++;
        const value = text.slice(start, at); emit(value, 'identifier', startLine);
        regexAllowed = ['return', 'throw', 'case', 'delete', 'typeof', 'void', 'new', 'in', 'of', 'yield', 'await', 'else', 'do', 'instanceof'].includes(value);
        previous = value; continue;
      }
      if (/[0-9]/.test(char)) {
        const start = at++; while (at < text.length && /[A-Za-z0-9_.]/.test(text[at])) at++;
        emit(text.slice(start, at), 'number', startLine); regexAllowed = false; previous = 'value'; continue;
      }
      if (char === '}' && stopAtBrace && braces === 0) { at++; return; }
      step(); emit(char, 'punctuation', startLine);
      if (char === '{') braces++;
      if (char === '}') braces--;
      if (char === '(') parens.push(['if', 'while', 'for', 'with', 'switch', 'catch'].includes(previous));
      regexAllowed = char === ')' ? Boolean(parens.pop()) : /[=([{,;:!?&|+*%^~<>-]/.test(char);
      previous = char;
    }
    if (stopAtBrace) fail('unterminated-template-substitution');
  }
  code(); return { tokens, literals };
}

function directCalls(tokens) {
  const calls = []; let dynamic = 0;
  for (let at = 0; at < tokens.length; at++) {
    const root = tokens[at];
    if (root.type !== 'identifier' || !roots.has(root.value) || tokens[at - 1]?.value === '.') continue;
    let member, end;
    if (tokens[at + 1]?.value === '.' && tokens[at + 2]?.type === 'identifier') { member = tokens[at + 2].value; end = at + 3; }
    else if (tokens[at + 1]?.value === '[' && tokens[at + 2]?.type === 'string' && tokens[at + 3]?.value === ']') { member = tokens[at + 2].value; end = at + 4; }
    else if (tokens[at + 1]?.value === '[') { dynamic++; continue; }
    if (member && tokens[end]?.value === '(') calls.push({ method: `${root.value}.${member}`, line: root.line });
  }
  return { calls, dynamic };
}

function capabilities() {
  const worker = readFileSync(join(project, 'Zhuying/Models/LegadoBookSource.swift'), 'utf8');
  const bridge = readFileSync(join(project, 'ZhuyingScriptCore/QuickJSScriptBridge.c'), 'utf8');
  const methods = new Set();
  for (const row of worker.matchAll(/case\s+((?:"[^"]+"\s*,?\s*)+):/g)) {
    for (const method of row[1].matchAll(/"((?:java|source|book|chapter|cache|cookie)\.[A-Za-z][A-Za-z0-9]*)"/g)) methods.add(method[1]);
  }
  // These are real shim adapters, rather than identically named native cases.
  if (bridge.includes("key==='createSymmetricCrypto'")) methods.add('java.createSymmetricCrypto');
  return { methods, workerSHA256: sha256(worker), bridgeSHA256: sha256(bridge) };
}

export function auditPackage(bytes, raw, capability = capabilities()) {
  const sources = Array.isArray(raw) ? raw : [raw];
  if (!sources.length || sources.length > limits.sources || sources.some(source => !source || typeof source !== 'object' || Array.isArray(source))) fail('source-shape');
  return {
    schemaVersion: 1, mode: 'static-audit', execution: 'not-performed',
    package: { bytes: bytes.length, sha256: sha256(bytes), sourceCount: sources.length },
    implementation: { workerSHA256: capability.workerSHA256, bridgeSHA256: capability.bridgeSHA256 },
    limits: 'direct-call lexical inventory; aliases, dynamic properties and runtime reachability are not resolved',
    sources: sources.map((source, index) => {
      const fields = [], calls = [], originCandidates = new Set(); let unknownRuleFields = 0, dynamicMemberSites = 0, embeddedScripts = 0, embeddedPageFragments = 0;
      const texts = [];
      for (const field of topStrings) if (Object.hasOwn(source, field)) {
        fields.push({ field, type: typeof source[field], bytes: typeof source[field] === 'string' ? Buffer.byteLength(source[field]) : 0 });
        if (typeof source[field] === 'string' && !['bookSourceUrl', 'loginUi'].includes(field)) texts.push([field, source[field]]);
      }
      for (const [section, allowed] of Object.entries(sections)) {
        const value = source[section];
        if (value === undefined) continue;
        if (!value || typeof value !== 'object' || Array.isArray(value)) { fields.push({ field: section, type: 'invalid' }); continue; }
        unknownRuleFields += Object.keys(value).filter(field => !allowed.includes(field)).length;
        for (const field of allowed) if (Object.hasOwn(value, field)) {
          const name = `${section}.${field}`;
          fields.push({ field: name, type: typeof value[field], bytes: typeof value[field] === 'string' ? Buffer.byteLength(value[field]) : 0 });
          if (typeof value[field] === 'string') texts.push([name, value[field]]);
        }
      }
      const errors = [];
      for (const [field, text] of texts) {
        try {
          const parsed = tokenize(text), direct = directCalls(parsed.tokens);
          dynamicMemberSites += direct.dynamic;
          calls.push(...direct.calls.map(call => ({ ...call, field, context: 'rule-or-library' })));
          for (const literal of parsed.literals) {
            if (/<script\b/i.test(literal.value)) embeddedPageFragments++;
            for (const address of literal.value.matchAll(/https?:\/\/[^\s<>"'`]+/gi)) {
              try {
                const url = new URL(address[0]);
                if (!url.username && !url.password && /^[a-z0-9.-]+$/i.test(url.hostname) && originCandidates.size < 128) originCandidates.add(url.origin);
              } catch { /* A dynamic template is not an explicit origin. */ }
            }
            for (const script of literal.value.matchAll(/<script\b[^>]*>([\s\S]*?)<\/script\s*>/gi)) {
              embeddedScripts++; const nested = directCalls(tokenize(script[1]).tokens); dynamicMemberSites += nested.dynamic;
              calls.push(...nested.calls.map(call => ({ ...call, line: literal.line, field, context: 'embedded-page' })));
            }
          }
        } catch (error) { errors.push({ field, code: safeError(error) }); }
      }
      const grouped = new Map();
      for (const call of calls) {
        const [root, member] = call.method.split('.'), known = knownMembers.has(member);
        const method = known ? call.method : `${root}.unclassified`;
        const coverage = call.context === 'embedded-page' ? 'page-bridge-not-proven' : capability.methods.has(call.method) ? 'native-dispatch-present' : call.method === 'java.qread' ? 'environment-probe-not-implemented' : 'missing-native-dispatch';
        const key = `${call.field}:${call.context}:${method}:${coverage}`;
        if (!grouped.has(key)) grouped.set(key, { field: call.field, context: call.context, method, coverage, count: 0, lines: [] });
        const group = grouped.get(key); group.count++; if (group.lines.length < 12 && !group.lines.includes(call.line)) group.lines.push(call.line);
      }
      return { index, requiredShape: required.every(field => fields.some(row => row.field === field && row.type === 'string' && row.bytes > 0)),
        identityKind: typeof source.bookSourceUrl === 'string' && /^https:\/\//i.test(source.bookSourceUrl) ? 'https-url' : 'opaque-or-missing',
        fields, unknownRuleFields, directCalls: [...grouped.values()], dynamicMemberSites, embeddedScripts, embeddedPageFragments,
        literalOriginCandidates: [...originCandidates].sort().map(origin => ({ origin, policy: 'requires-source-origin-policy' })), scanErrors: errors };
    })
  };
}

const errorCodes = new Set(['input-limit-or-type', 'invalid-json', 'source-shape', 'text-limit', 'token-limit', 'nesting-limit', 'unterminated-comment', 'unterminated-string', 'unterminated-template', 'unterminated-regex', 'unterminated-template-substitution', 'invalid-evidence', 'mismatched-evidence', 'usage']);
function safeError(error) { return errorCodes.has(error?.message) ? error.message : 'diagnostic-failed'; }

export function androidEnvironment() {
  const result = spawnSync('adb', ['devices', '-l'], { encoding: 'utf8', timeout: 5000, maxBuffer: 64 * 1024 });
  const states = {};
  for (const line of (result.stdout ?? '').split('\n')) {
    const state = line.trim().split(/\s+/)[1];
    if (['device', 'offline', 'unauthorized', 'recovery', 'sideload'].includes(state)) states[state] = (states[state] ?? 0) + 1;
  }
  const command = name => spawnSync('/usr/bin/which', [name], { encoding: 'utf8', timeout: 2000 }).status === 0;
  return { adbAvailable: !result.error, deviceStates: states, emulatorAvailable: command('emulator'), sdkManagerAvailable: command('sdkmanager'), avdManagerAvailable: command('avdmanager'), runtimeDifferential: 'not-performed' };
}

// Deliberately cannot accept user-supplied URLs or load a source/state file.
export async function publicSmoke(fetcher = fetch) {
  const origins = ['https://v5.langge.uk', 'https://v4.langge.uk'];
  const results = await Promise.all(origins.map(async origin => {
    const started = performance.now();
    try {
      const response = await fetcher(`${origin}/`, { method: 'GET', headers: { 'User-Agent': 'Zhuying-Anonymous-Connectivity/1' }, redirect: 'manual', credentials: 'omit', signal: AbortSignal.timeout(10000) });
      await response.body?.cancel();
      return { origin, path: '/', status: response.status, redirectReceived: response.status >= 300 && response.status < 400, elapsedMilliseconds: Math.round(performance.now() - started) };
    } catch { return { origin, path: '/', error: 'connection-failed', elapsedMilliseconds: Math.round(performance.now() - started) }; }
  }));
  return { schemaVersion: 1, mode: 'anonymous-connectivity', checkedAt: new Date().toISOString(), sourceExecution: 'not-performed', authentication: 'not-attempted', results };
}

const stages = ['search', 'details', 'catalog', 'content'];
function validHash(value) { return typeof value === 'string' && /^[a-f0-9]{64}$/.test(value); }
function validateEvidence(value) {
  const keys = ['schemaVersion', 'implementation', 'sourceSHA256', 'referenceRevision', 'binarySHA256', 'fixtureSHA256', 'captureMode', 'capturedAt', 'scenarios'];
  if (!value || typeof value !== 'object' || Object.keys(value).some(key => !keys.includes(key)) || value.schemaVersion !== 1 || !['legado-android', 'zhuying-ios'].includes(value.implementation) || !validHash(value.sourceSHA256) || !validHash(value.binarySHA256) || !validHash(value.fixtureSHA256) || value.referenceRevision !== 'fd026e0' || value.captureMode !== 'offline-fixture' || !Number.isFinite(Date.parse(value.capturedAt)) || !Array.isArray(value.scenarios) || !value.scenarios.length || value.scenarios.length > 128) fail('invalid-evidence');
  const ids = new Set();
  for (const scenario of value.scenarios) {
    if (!scenario || typeof scenario !== 'object' || Object.keys(scenario).some(key => !['fixtureID', 'stage', 'outputSHA256', 'itemCount', 'utf16Count'].includes(key)) || !/^[a-z0-9][a-z0-9-]{0,63}$/.test(scenario.fixtureID ?? '') || !stages.includes(scenario.stage) || !validHash(scenario.outputSHA256) || !Number.isSafeInteger(scenario.itemCount) || scenario.itemCount < 0 || scenario.itemCount > 100000 || !Number.isSafeInteger(scenario.utf16Count) || scenario.utf16Count < 0 || scenario.utf16Count > 8 * 1024 * 1024) fail('invalid-evidence');
    const id = `${scenario.fixtureID}:${scenario.stage}`; if (ids.has(id)) fail('invalid-evidence'); ids.add(id);
  }
  if (!stages.every(stage => value.scenarios.some(row => row.stage === stage))) fail('invalid-evidence');
  return value;
}

export function compareEvidence(first, second) {
  const a = validateEvidence(first), b = validateEvidence(second);
  if (a.implementation === b.implementation || a.sourceSHA256 !== b.sourceSHA256 || a.fixtureSHA256 !== b.fixtureSHA256 || a.scenarios.length !== b.scenarios.length) fail('mismatched-evidence');
  const mismatches = [];
  for (const left of a.scenarios) {
    const right = b.scenarios.find(row => row.fixtureID === left.fixtureID && row.stage === left.stage);
    if (!right || ['outputSHA256', 'itemCount', 'utf16Count'].some(key => right[key] !== left[key])) mismatches.push({ scenarioIndex: a.scenarios.indexOf(left), stage: left.stage });
  }
  return { schemaVersion: 1, mode: 'offline-record-comparison', consistency: mismatches.length ? 'different' : 'matched', provenance: 'caller-supplied-not-attested', runtimeVerification: 'not-performed-by-this-tool', liveVerification: 'not-performed', comparedScenarios: a.scenarios.length, mismatches };
}

async function main(args) {
  const [mode, ...options] = args;
  if (mode === 'audit' && options.length >= 1 && options.length <= 2 && (!options[1] || options[1] === '--android-environment')) {
    const { bytes, value } = boundedJSON(options[0]), report = auditPackage(bytes, value);
    if (options[1]) report.android = androidEnvironment();
    return report;
  }
  if (mode === 'public-smoke' && !options.length) return publicSmoke();
  if (mode === 'compare' && options.length === 2) return compareEvidence(boundedJSON(options[0], 256 * 1024).value, boundedJSON(options[1], 256 * 1024).value);
  fail('usage');
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const result = await main(process.argv.slice(2));
    console.log(JSON.stringify(result, null, 2));
    if (result.consistency === 'different') process.exitCode = 2;
  } catch (error) { console.error(JSON.stringify({ error: safeError(error) })); process.exitCode = 1; }
}

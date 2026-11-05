import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const script = fileURLToPath(new URL('../ios/scripts/validate-source.mjs', import.meta.url));
const device = '4038B360-1687-474F-BEC3-D5B1A898BC11';
function invoke(status) {
  const root = mkdtempSync(join(tmpdir(), 'source validation '));
  try {
    const records = join(root, 'Documents', 'DevelopmentValidation');
    mkdirSync(records, { recursive: true });
    writeFileSync(join(records, 'source-feasibility.json'), JSON.stringify({ schemaVersion: 1, sourceID: 'shushan', startedAt: '2000-01-01T00:00:00Z', status: 'passed', works: [], requests: [] }));
    writeFileSync(join(root, 'xcrun'), `#!/usr/bin/env node
import fs from 'node:fs';
const args = process.argv.slice(2);
fs.appendFileSync(process.env.SOURCE_COMMANDS, JSON.stringify(args) + '\\n');
if (args[1] === 'get_app_container') console.log(process.env.SOURCE_CONTAINER);
if (args[1] === 'launch') {
  const result = process.env.SOURCE_RESULT;
  const works = result === 'passed' ? [0,1].map(i => ({id:'work-'+i,title:'作品'+i,chapters:[0,1,2].map(j => ({id:i+'-'+j,utf16Count:300,paragraphCount:2,contentHash:(i*3+j+1).toString(16).padStart(64,'0')}))})) : [];
  fs.writeFileSync(process.env.SOURCE_REPORT, JSON.stringify({schemaVersion:1, sourceID:'shushan', startedAt:new Date().toISOString(), status:result === 'invalid-success' ? 'passed' : result, works, requests:[]}));
}
`, { mode: 0o755 });
    writeFileSync(join(root, 'package.json'), '{"type":"module"}');
    const output = join(root, 'output', 'fresh report.json');
    const commands = join(root, 'commands');
    const result = spawnSync(process.execPath, [script, device, output, '作品甲|作品乙'], { encoding: 'utf8', timeout: 10000, env: {
      ...process.env, PATH: `${root}:${process.env.PATH}`, SOURCE_COMMANDS: commands,
      SOURCE_CONTAINER: root, SOURCE_REPORT: join(records, 'source-feasibility.json'), SOURCE_RESULT: status
    } });
    return { ...result, report: existsSync(output) ? JSON.parse(readFileSync(output, 'utf8')) : null, commands: readFileSync(commands, 'utf8').trim().split('\n').map(JSON.parse) };
  } finally { rmSync(root, { recursive: true, force: true }); }
}

test('source validation restarts the app, preserves the requested books and copies only a fresh report', () => {
  const result = invoke('passed');
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.report.status, 'passed');
  assert.notEqual(result.report.startedAt, '2000-01-01T00:00:00Z');
  assert.deepEqual(result.commands.map(x => x[1]), ['get_app_container', 'terminate', 'launch']);
  assert.equal(result.commands.at(-1).at(-1), '作品甲|作品乙');
  assert.ok(result.commands.at(-1).includes('--production'));
  assert.ok(!result.commands.at(-1).includes('--ui-testing'));
});

test('source failure and absent login are nonzero results even when a previous report passed', () => {
  assert.equal(invoke('failed').status, 2);
  assert.equal(invoke('authentication-required').status, 3);
});

test('a successful label without two real three-chapter runs cannot pass the source gate', () => {
  const result = invoke('invalid-success');
  assert.equal(result.status, 1);
  assert.equal(result.report, null);
  assert.match(result.stderr, /two real three-chapter runs/);
});

test('source validation rejects missing destinations and invalid simulator IDs before launching', () => {
  for (const args of [[], ['invalid', 'output.json'], [device, 'output.json', 'one|one']]) {
    const result = spawnSync(process.execPath, [script, ...args], { encoding: 'utf8' });
    assert.equal(result.status, 1);
    assert.match(result.stderr, /Usage:|two distinct book names/);
  }
});

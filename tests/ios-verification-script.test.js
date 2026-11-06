import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const script = fileURLToPath(new URL('../ios/scripts/verify.sh', import.meta.url));

function invoke(mode) {
  const directory = mkdtempSync(join(tmpdir(), 'zhuying-verification-'));
  const output = join(directory, 'xcode-arguments');
  writeFileSync(join(directory, 'npm'), '#!/bin/sh\nexit 0\n', { mode: 0o755 });
  writeFileSync(join(directory, 'xcodebuild'), '#!/bin/sh\nprintf \'%s\\n\' "$@" > "$ZHUYING_TEST_ARGS"\n', { mode: 0o755 });
  const destination = 'platform=iOS Simulator,id=test-device';
  const derivedData = join(directory, 'Derived Data');
  const result = spawnSync('bash', [script, mode], { encoding: 'utf8', env: {
    ...process.env, PATH: `${directory}:${process.env.PATH}`,
    ZHUYING_TEST_ARGS: output, ZHUYING_TEST_DESTINATION: destination,
    ZHUYING_DERIVED_DATA: derivedData
  } });
  const args = existsSync(output) ? readFileSync(output, 'utf8').trim().split('\n') : [];
  rmSync(directory, { recursive: true, force: true });
  return { ...result, args, destination, derivedData };
}

test('iOS unit verification selects model tests and uses simulator signing required by Keychain', () => {
  const result = invoke('unit');
  assert.equal(result.status, 0, result.stderr);
  assert.ok(result.args.includes('-only-testing:ZhuyingTests'));
  assert.ok(result.args.includes('CODE_SIGNING_ALLOWED=YES'));
  assert.ok(result.args.includes('CODE_SIGN_IDENTITY=-'));
  assert.equal(result.args[result.args.indexOf('-destination') + 1], result.destination);
  assert.equal(result.args[result.args.indexOf('-derivedDataPath') + 1], result.derivedData);
});

test('iOS UI and full verification modes pass valid targets including an empty full-suite filter', () => {
  const ui = invoke('ui');
  assert.equal(ui.status, 0, ui.stderr);
  assert.ok(ui.args.includes('-only-testing:ZhuyingUITests'));
  const all = invoke('all');
  assert.equal(all.status, 0, all.stderr);
  assert.ok(!all.args.some(arg => arg.startsWith('-only-testing:')));
  assert.equal(all.args.at(-1), 'test');
});

test('invalid iOS verification mode stops before running any build', () => {
  const result = invoke('invalid');
  assert.equal(result.status, 2);
  assert.deepEqual(result.args, []);
  assert.match(result.stderr, /Usage:/);
});

test('performance verification selects its independent scheme without filtering out baseline targets', () => {
  const result = invoke('performance');
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.args[result.args.indexOf('-scheme') + 1], 'Zhuying Performance');
  assert.ok(!result.args.some(arg => arg.startsWith('-only-testing:')));
  assert.equal(result.args.at(-1), 'test');
});

test('npm test only discovers the active project tests and excludes saved Demo copies', () => {
  const directory = mkdtempSync(join(tmpdir(), 'zhuying-test-discovery-'));
  try {
    const configuration = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8'));
    mkdirSync(join(directory, 'tests'));
    mkdirSync(join(directory, 'Saved-Demo', 'tests'), { recursive: true });
    writeFileSync(join(directory, 'package.json'), JSON.stringify({ type: 'module', scripts: { test: configuration.scripts.test } }));
    writeFileSync(join(directory, 'tests', 'smoke.test.js'), 'import test from "node:test"; import { writeFileSync } from "node:fs"; test("active-project-probe", () => writeFileSync(new URL("../active.txt", import.meta.url), "passed"));');
    writeFileSync(join(directory, 'Saved-Demo', 'tests', 'unexpected.test.js'), 'throw new Error("Saved Demo must not run");');
    const environment = { ...process.env };
    delete environment.NODE_TEST_CONTEXT;
    const result = spawnSync('npm', ['test'], { cwd: directory, env: environment, encoding: 'utf8', timeout: 15000 });
    assert.equal(result.status, 0, result.stdout + result.stderr);
    assert.equal(readFileSync(join(directory, 'active.txt'), 'utf8'), 'passed');
    assert.doesNotMatch(result.stdout, /Saved Demo must not run/);
  } finally { rmSync(directory, { recursive: true, force: true }); }
});

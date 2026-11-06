import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const path = '竹影Demo-2026-11-05';
const commit = 'ea3b91c9b6cfcdbc411567ac4c7a7c0ae70a70e4';
const git = args => execFileSync('git', args, { cwd: root, encoding: 'utf8' });

test('the saved Demo is a pinned submodule with a retrievable GitHub repository and branch', () => {
  const get = key => git(['config', '-f', '.gitmodules', '--get', `submodule.${path}.${key}`]).trim();
  assert.equal(get('path'), path);
  assert.equal(get('url'), 'https://github.com/hjz101/zhuying.git');
  assert.equal(get('branch'), 'codex/saved-demo-2026-11-05');
  assert.equal(git(['ls-files', '--stage', '-z', '--', path]), `160000 ${commit} 0\t${path}\0`);
});

test('the main README identifies the frozen Demo and explains how a fresh clone retrieves it', () => {
  const readme = readFileSync(new URL('../README.md', import.meta.url), 'utf8');
  assert.ok(readme.includes(commit));
  assert.ok(readme.includes('https://github.com/hjz101/zhuying/tree/codex/saved-demo-2026-11-05'));
  assert.ok(readme.includes('git clone --recurse-submodules'));
  assert.ok(readme.includes('git submodule update --init --recursive'));
});

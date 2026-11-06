import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';

const read = path => readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');

test('current native and browser surfaces consistently present the Zhuying brand', () => {
  for (const directory of ['ios/Zhuying/Views/', 'ios/Zhuying/Demo/']) {
    for (const file of readdirSync(new URL(`../${directory}`, import.meta.url)).filter(name => name.endsWith('.swift'))) {
      assert.doesNotMatch(read(directory + file), /阅山|Yueshan|YUESHAN|yueshan/, file);
    }
  }
  for (const file of ['src/app.js', 'index.html', 'package.json']) {
    assert.doesNotMatch(read(file), /阅山|Yueshan|YUESHAN|yueshan/, file);
  }
  assert.match(read('src/app.js'), /竹影/);
  const project = read('ios/project.yml');
  assert.match(project, /INFOPLIST_KEY_CFBundleDisplayName: 竹影/);
  assert.match(project, /PRODUCT_BUNDLE_IDENTIFIER: com\.zhuying\.reader\.demo/);
  assert.match(read('ios/Zhuying/ZhuyingApp.swift'), /struct ZhuyingApp: App/);
});

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';

const html = readFileSync(new URL('../docs/design/reading-preferences-layouts.html', import.meta.url), 'utf8');
const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];

function fixture(saved) {
  const savedSnapshots = [];
  const globals = {};
  const phones = ['grouped', 'workbench', 'overview'].map(id => {
    const elements = new Map();
    const make = () => ({ hidden: false, style: { setProperty() {} }, dataset: {}, textContent: '', setAttribute(k,v) { this[k] = v; } });
    const prose = make(), title = make();
    const preview = { ...make(), querySelector: s => s === '.ys-prose' ? prose : title };
    elements.set('.ys-preview', [preview]);
    elements.set('[data-font-value]', [make()]);
    elements.set('[data-paging-effects]', [make()]);
    elements.set('[data-mode-value]', [make()]);
    const home = make(), details = make(), panel = make();
    const handlers = {};
    return {
      dataset: { reader: id }, handlers, elements, prose, title, home, details, panel,
      querySelectorAll: s => elements.get(s) || [],
      querySelector: s => s === '[data-home]' ? home : s === '[data-details]' ? details : panel,
      addEventListener: (name,fn) => { handlers[name] = fn; },
      contains: () => true,
      click(data) { const b = { dataset: data, hasAttribute: name => Object.hasOwn(data, name.replace(/^data-/, '').replace(/-([a-z])/g, (_,c)=>c.toUpperCase())) }; handlers.click({ target: { closest: () => b } }); },
      input(data,value,checked) { handlers.input({ target: { dataset: data, value, checked } }); }
    };
  });
  runInNewContext(script, {
    document: { getElementById: () => ({ querySelectorAll: () => phones }) },
    openai: { widgetState: saved, setWidgetState: s => { savedSnapshots.push(JSON.parse(JSON.stringify(s))); return Promise.resolve(); } },
    window: { addEventListener: (name,fn) => { globals[name] = fn; } }, setTimeout: () => {}
  });
  return { phones, savedSnapshots, globals };
}

test('layout prototypes provide three distinct, initially isolated alternatives', () => {
  assert.deepEqual([...html.matchAll(/<section data-variant="([^"]+)"[^>]*>/g)].map(m => m[1]), ['分区设置', '预览工作台', '偏好总览']);
  assert.equal([...html.matchAll(/<section data-variant="[^"]+"[^>]* hidden>/g)].length, 2);
  assert.ok(!/<html|<body|<iframe|\bfetch\(/.test(html));
});

test('font limits and theme edits update preview and preserve other alternatives', () => {
  const { phones: [p, other], savedSnapshots } = fixture();
  for (let i = 0; i < 12; i++) p.click({ step: '1' });
  assert.equal(p.prose.style.fontSize, '26px');
  for (let i = 0; i < 15; i++) p.click({ step: '-1' });
  assert.equal(p.prose.style.fontSize, '16px');
  p.click({ themeChoice: '夜读' });
  assert.equal(p.elements.get('.ys-preview')[0].dataset.theme, '夜读');
  assert.equal(other.elements.get('.ys-preview')[0].dataset.theme, '暖纸');
  assert.equal(savedSnapshots.at(-1).privateContent.readingLayoutPreviews.grouped.theme, '夜读');
  p.click({ reset: '' });
  assert.equal(p.prose.style.fontSize, '20px');
  assert.equal(p.elements.get('.ys-preview')[0].dataset.theme, '暖纸');
});

test('paging effects depend on reading mode and detail navigation preserves edits', () => {
  const { phones: [p] } = fixture();
  const effects = p.elements.get('[data-paging-effects]')[0];
  assert.equal(effects.hidden, true);
  p.click({ detail: 'operation' });
  assert.equal(p.home.hidden, true);
  p.click({ choice: 'mode', value: '左右分页' });
  assert.equal(effects.hidden, false);
  p.click({ detailBack: '' });
  assert.equal(p.home.hidden, false);
  assert.equal(p.elements.get('[data-mode-value]')[0].textContent, '左右分页');
  p.click({ choice: 'mode', value: '上下滚动' });
  assert.equal(effects.hidden, true);
});

test('advanced typography updates preview and restored state does not trigger saves', () => {
  const { phones: [p], savedSnapshots, globals } = fixture({ privateContent: { readingLayoutPreviews: { grouped: { font: 24, theme: '夜读' } } } });
  assert.equal(p.prose.style.fontSize, '24px');
  assert.equal(savedSnapshots.length, 0);
  p.input({ range: 'line' }, '18');
  assert.equal(p.prose.style.lineHeight, (1.35 + 18 / 28).toFixed(2));
  p.input({ setting: 'indent' }, undefined, false);
  assert.equal(p.prose.style.textIndent, '0');
  p.click({ choice: 'title', value: '细线分隔' });
  assert.equal(p.title.style.borderBottom, '1px solid currentColor');
  p.click({ choice: 'scope', value: '当前书籍' });
  assert.equal(savedSnapshots.at(-1).privateContent.readingLayoutPreviews.grouped.scope, '当前书籍');
  const before = savedSnapshots.length;
  globals['openai:set_globals']({ detail: { globals: { widgetState: { privateContent: { readingLayoutPreviews: { grouped: { font: 18, theme: '明亮' } } } } } } });
  assert.equal(p.prose.style.fontSize, '18px');
  assert.equal(p.elements.get('.ys-preview')[0].dataset.theme, '明亮');
  assert.equal(savedSnapshots.length, before);
});

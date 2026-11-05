import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';

const html = readFileSync(new URL('../docs/design/reading-preferences-overview-v2.html', import.meta.url), 'utf8');
const originalScript = html.match(/<script>([\s\S]*?)<\/script>/)[1];
const script = originalScript.replace(/\}\)\(\);\s*$/, `
 globalThis.layoutTestAPI = { paper, css, cssDeclarations, themes, theme, defaults,
   constrainPageElement: typeof constrainPageElement === 'function' ? constrainPageElement : undefined,
   titleControlsFromCSS: typeof titleControlsFromCSS === 'function' ? titleControlsFromCSS : undefined,
   getState: () => s };
})();`);

function fixture(options = {}) {
  const handlers = new Map();
  const saves = [];
  const nodes = new Map([
    ['[data-content]', { innerHTML: '' }],
    ['[data-file]', { dataset: {}, files: [], value: '', addEventListener() {}, click() {} }],
    ['[data-nav-title]', { textContent: '' }],
    ['[data-message]', { textContent: '' }]
  ]);
  const titleStyles = new Map();
  const title = { style: { setProperty: (key, value) => titleStyles.set(key, value) } };
  const preview = { innerHTML: '', classList: { contains: name => name === 'preview-wrap' } };
  const root = {
    querySelector: selector => nodes.get(selector) || null,
    querySelectorAll: selector => selector === '[data-title]' ? [title] : selector === '[data-preview]' ? [preview] : [],
    contains: () => true,
    addEventListener: (name, callback) => handlers.set(name, callback)
  };
  const context = {
    document: { getElementById: () => root, fonts: { add() {} } },
    window: { addEventListener() {} },
    openai: { widgetState: options.saved, setWidgetState(snapshot) { saves.push(JSON.parse(JSON.stringify(snapshot))); return Promise.resolve(); } }
  };
  runInNewContext(script, context);
  return {
    ...context.layoutTestAPI, nodes, saves, titleStyles, preview,
    click(dataset) {
      const button = { dataset, hasAttribute(name) { return Object.hasOwn(dataset, dataKey(name)); } };
      handlers.get('click')({ target: { closest: () => button } });
    },
    pointer(type, { id, x = 0, y = 0, width = 200, height = 64 } = {}) {
      const region = { getBoundingClientRect: () => ({ width, height }) };
      const item = { dataset: { pageElement: id }, closest: selector => selector === '[data-page-region]' ? region : null, setPointerCapture() {} };
      const target = { closest: selector => selector === '[data-page-element]' && id ? item : null };
      handlers.get(type)({ target, clientX: x, clientY: y, pointerId: 1, preventDefault() {} });
    },
    input(dataset, value, type = 'range', checked) {
      const target = { dataset, value, type, checked, hasAttribute(name) { return Object.hasOwn(dataset, dataKey(name)); } };
      handlers.get('input')({ target });
    }
  };
}

function dataKey(name) { return name.replace(/^data-/, '').replace(/-([a-z])/g, (_, c) => c.toUpperCase()); }
function plain(value) { return JSON.parse(JSON.stringify(value)); }
function numericCSS(styles, property) {
  const values = Object.fromEntries(styles.split(';').filter(Boolean).map(declaration => {
    const separator = declaration.indexOf(':');
    return [declaration.slice(0, separator).trim(), declaration.slice(separator + 1).trim()];
  }));
  if (values[property] !== undefined) return Number.parseFloat(values[property]);
  if (property.startsWith('padding-') && values.padding) {
    const sides = values.padding.split(/\s+/).map(Number.parseFloat);
    const expanded = sides.length === 4 ? sides : sides.length === 3 ? [sides[0], sides[1], sides[2], sides[1]] : sides.length === 2 ? [sides[0], sides[1], sides[0], sides[1]] : [sides[0], sides[0], sides[0], sides[0]];
    return expanded[['top', 'right', 'bottom', 'left'].indexOf(property.slice(8))];
  }
  return undefined;
}
function elementStyles(markup, selector) {
  const tag = [...markup.matchAll(/<[^>]+>/g)].find(([tag]) => selector(tag));
  assert.ok(tag, 'Expected element is missing from the rendered reading preview');
  return tag[0].match(/\bstyle="([^"]*)"/)?.[1] || '';
}

// These assertions exercise the proposal's real input handlers and rendered preview,
// without implementing a second copy of the preference or positioning logic.
test('font size, line spacing, paragraph spacing and four margins adjust independently in the live page preview', () => {
  const api = fixture();
  const state = api.getState();
  const before = plain(state);
  api.click({ open: 'margins' });
  for (const [key, value] of Object.entries({ fontSize: 24, lineSpacing: 18, paragraphSpacing: 26, top: 30, bottom: 22, left: 40, right: 12 })) {
    api.input({ bind: key }, String(value));
    assert.equal(state[key], value, `${key} did not update`);
  }
  assert.equal(state.linked, before.linked);
  assert.equal(state.font, before.font);
  assert.equal(state.css, before.css);
  const rendered = api.paper(true);
  const page = elementStyles(rendered, tag => /\bdata-paper\b/.test(tag));
  assert.equal(numericCSS(page, 'padding-left'), 40);
  assert.equal(numericCSS(page, 'padding-right'), 12);
  assert.equal(numericCSS(page, 'padding-top'), 30);
  assert.equal(numericCSS(page, 'padding-bottom'), 22);
  const body = elementStyles(rendered, tag => /class="body-text"/.test(tag));
  assert.equal(numericCSS(body, 'font-size'), 24);
  assert.equal(numericCSS(body, 'line-height'), 42);
  assert.equal(numericCSS(body, '--paragraph-gap'), 26);
  assert.match(api.preview.innerHTML, /line-height:42px/);
  assert.match(api.preview.innerHTML, /--paragraph-gap:26px/);
});

test('page elements can be added and removed without editing other header or footer elements', () => {
  const api = fixture();
  const state = api.getState();
  const original = plain(state.pageElements);
  api.click({ open: 'headers' });
  api.click({ addPageElement: 'header' });
  assert.equal(state.pageElements.length, original.length + 1);
  const addition = state.pageElements.find(item => !original.some(old => old.id === item.id));
  assert.ok(addition);
  api.click({ pageElement: addition.id });
  api.input({ elementField: 'type' }, '自定义文字', 'select-one');
  api.input({ elementField: 'text' }, '我的阅读页眉', 'text');
  api.input({ elementField: 'zone' }, 'footer', 'select-one');
  api.input({ elementField: 'size' }, '16');
  api.input({ elementField: 'color' }, '#654321', 'color');
  assert.equal(addition.type, '自定义文字');
  assert.equal(addition.text, '我的阅读页眉');
  assert.equal(addition.zone, 'footer');
  assert.equal(addition.size, 16);
  assert.equal(addition.color, '#654321');
  assert.deepEqual(plain(state.pageElements.filter(item => item.id !== addition.id)), original);
  assert.match(api.paper(true), /我的阅读页眉/);
  api.click({ removePageElement: '' });
  assert.deepEqual(plain(state.pageElements), original);
  assert.doesNotMatch(api.paper(true), /我的阅读页眉/);
});

test('position controls clamp the selected page element within its zone while preserving independent elements', () => {
  const api = fixture();
  const state = api.getState();
  assert.equal(typeof api.constrainPageElement, 'function');
  const first = state.pageElements[0];
  const originalOthers = plain(state.pageElements.slice(1));
  const limited = api.constrainPageElement(first, -100, 1000);
  assert.ok(limited.x >= first.width / 2 && limited.x <= 100 - first.width / 2);
  assert.ok(limited.y >= 0 && limited.y <= 100);
  const opposite = api.constrainPageElement(first, 1000, -100);
  assert.ok(opposite.x >= first.width / 2 && opposite.x <= 100 - first.width / 2);
  assert.ok(opposite.y >= 0 && opposite.y <= 100);
  api.click({ open: 'headers' });
  api.click({ pageElement: first.id });
  api.input({ elementField: 'x' }, '-100');
  api.input({ elementField: 'y' }, '1000');
  assert.ok(first.x >= 0 && first.x <= 100);
  assert.ok(first.y >= 0 && first.y <= 100);
  api.input({ elementField: 'x' }, '55');
  api.input({ elementField: 'y' }, '75');
  assert.equal(first.x, 55);
  assert.equal(first.y, 75);
  api.input({ elementField: 'width' }, '70');
  const clamped = api.constrainPageElement(first, first.x, first.y);
  assert.equal(first.x, clamped.x);
  assert.equal(first.y, clamped.y);
  assert.deepEqual(plain(state.pageElements.slice(1)), originalOthers);
});

test('chapter title exposes a custom mode with live controls and preserves it when changing reading themes', () => {
  const api = fixture();
  const state = api.getState();
  assert.equal(state.css, null);
  const inherited = api.css();
  api.click({ open: 'title' });
  api.click({ titleSource: 'custom' });
  assert.equal(state.css, inherited);
  api.input({ titleField: 'font-size' }, '28');
  api.input({ titleField: 'text-align' }, 'left', 'select-one');
  api.input({ titleField: 'color' }, '#7c4a2f', 'color');
  api.input({ titleField: 'letter-spacing' }, '4');
  api.input({ titleField: 'padding-bottom' }, '18');
  const styles = plain(api.cssDeclarations(api.css()));
  assert.equal(styles['font-size'], '28px');
  assert.equal(styles['text-align'], 'left');
  assert.equal(styles.color, '#7c4a2f');
  assert.equal(styles['letter-spacing'], '4px');
  assert.equal(styles['padding-bottom'], '18px');
  assert.equal(api.titleStyles.get('font-size'), '28px');
  assert.equal(api.titleStyles.get('text-align'), 'left');
  assert.equal(api.titleStyles.get('color'), '#7c4a2f');
  assert.equal(api.titleStyles.get('letter-spacing'), '4px');
  assert.equal(api.titleStyles.get('padding-bottom'), '18px');
  const custom = state.css;
  api.click({ applyTheme: 'mountain' });
  assert.equal(state.css, custom);
  assert.equal(api.css(), custom);
  api.click({ titleSource: 'theme' });
  assert.equal(state.css, null);
  assert.equal(api.css(), api.theme().css);
});


test('restored page elements receive unique identities when adding new elements', () => {
  const original = fixture();
  original.click({ open: 'headers' });
  original.click({ addPageElement: 'header' });
  original.click({ addPageElement: 'footer' });
  const saved = original.saves.at(-1);
  assert.ok(saved?.privateContent?.preferencesV2?.pageElements.length);
  const restored = fixture({ saved });
  const before = plain(restored.getState().pageElements);
  restored.click({ open: 'headers' });
  restored.click({ addPageElement: 'header' });
  const items = restored.getState().pageElements;
  assert.equal(items.length, before.length + 1);
  assert.equal(new Set(items.map(item => item.id)).size, items.length);
  const added = items.find(item => !before.some(old => old.id === item.id));
  assert.ok(added);
  restored.click({ pageElement: added.id });
  restored.click({ removePageElement: '' });
  assert.deepEqual(plain(restored.getState().pageElements), before);
});

test('dragging a page element converts pointer distance to local coordinates and saves on release', () => {
  const api = fixture();
  const state = api.getState();
  api.click({ open: 'headers' });
  const book = state.pageElements.find(item => item.id === 'book');
  const before = plain(state.pageElements.filter(item => item.id !== book.id));
  const start = { x: book.x, y: book.y };
  const beforeSaves = api.saves.length;
  api.pointer('pointerdown', { id: book.id, x: 100, y: 100 });
  api.pointer('pointermove', { x: 120, y: 110 });
  const expected = api.constrainPageElement(book, start.x + 10, start.y + 10 / 64 * 100);
  assert.equal(book.x, expected.x);
  assert.equal(book.y, expected.y);
  assert.deepEqual(plain(state.pageElements.filter(item => item.id !== book.id)), before);
  assert.equal(api.saves.length, beforeSaves);
  api.pointer('pointerup');
  assert.equal(api.saves.length, beforeSaves + 1);
  const savedBook = api.saves.at(-1).privateContent.preferencesV2.pageElements.find(item => item.id === book.id);
  assert.equal(savedBook.x, book.x);
  assert.equal(savedBook.y, book.y);
});

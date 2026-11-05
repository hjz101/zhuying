import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';

const repositorySource = new URL('../docs/design/reading-preferences-overview-v2.html', import.meta.url);
const html = readFileSync(repositorySource, 'utf8');
const originalScript = html.match(/<script>([\s\S]*?)<\/script>/)[1];
const script = originalScript.replace(/\}\)\(\);\s*$/, `
 globalThis.testAPI = { cssDeclarations, effectiveMargins, styledText, regexFor,
   themes, fonts, defaults, theme, bubble, god, css, paper, rulePreview, getState: () => s };
})();`);

function fixture(options = {}) {
  const fileHandlers = new Map();
  const fontFaces = [];
  const loadedFonts = [];
  const handlers = new Map();
  const saves = [];
  const nodes = new Map([
    ['[data-content]', { innerHTML: '' }],
    ['[data-file]', { dataset: {}, value: '', files: [], addEventListener: (name, fn) => fileHandlers.set(name, fn), click() {} }],
    ['[data-nav-title]', { textContent: '' }],
    ['[data-message]', { textContent: '' }]
  ]);
  const root = {
    querySelector: key => nodes.get(key) || null,
    querySelectorAll: () => [],
    contains: () => true,
    addEventListener: (name, fn) => handlers.set(name, fn)
  };
  const context = {
    document: { getElementById: () => root, fonts: { add: face => loadedFonts.push(face) } },
    FontFace: class {
      constructor(family, source) { this.family = family; this.source = source; fontFaces.push(this); }
      load() { return options.fontLoad ? options.fontLoad(this) : Promise.resolve(this); }
    },
    window: { addEventListener() {} },
    openai: {
      setWidgetState(snapshot) {
        saves.push(JSON.parse(JSON.stringify(snapshot)));
        return Promise.resolve();
      }
    }
  };
  runInNewContext(script, context);
  return {
    ...context.testAPI,
    saves,
    nodes,
    fontFaces,
    loadedFonts,
    click(dataset) {
      const button = {
        dataset,
        hasAttribute(name) {
          const key = name.replace(/^data-/, '').replace(/-([a-z])/g, (_, c) => c.toUpperCase());
          return Object.hasOwn(dataset, key);
        }
      };
      handlers.get('click')({ target: { closest: () => button } });
    },
    importFile(kind, { name = 'styles.json', content = '', bytes = new ArrayBuffer(0), size } = {}) {
      this.click({ import: kind });
      const file = nodes.get('[data-file]');
      file.files = [{ name, size: size ?? Math.max(Buffer.byteLength(content), bytes.byteLength),
        text: async () => content, arrayBuffer: async () => bytes }];
      return fileHandlers.get('change')();
    },
    input(dataset, value, type = 'range', checked) {
      const target = { dataset, value, type, checked, hasAttribute: () => false };
      handlers.get('input')({ target });
    }
  };
}

function plain(value) { return JSON.parse(JSON.stringify(value)); }

// Exercise the same closed-over helpers and event handlers that drive the prototype.
// The minimal DOM records rendering, but does not substitute its own preference logic.
test('chapter CSS accepts scoped typography and rejects selectors or resource loading outside the title', () => {
  const api = fixture();
  assert.deepEqual(plain(api.cssDeclarations(`/* custom heading */
    .chapter-title { color: var(--reader-accent); text-align: left;
      border-left: 3px solid currentColor; padding-left: 12px; font-size: 24px; }`)), {
    color: 'var(--reader-accent)', 'text-align': 'left',
    'border-left': '3px solid currentColor', 'padding-left': '12px', 'font-size': '24px'
  });
  for (const input of [
    'body { color: red; }',
    '.chapter-title, .body-text { color: red; }',
    '.chapter-title { color: red; } .body-text { color: blue; }',
    '@import "https://example.com/style.css";',
    '.chapter-title { position: fixed; }',
    '.chapter-title { background: url(https://example.com/paper.png); }',
    '.chapter-title { color: expression(alert(1)); }',
    '.chapter-title { color: red !important; }',
    '.chapter-title { color red; }',
    '.chapter-title { color: ; }',
    '.chapter-title { color: <script>; }',
    '.chapter-title { color: red;'.repeat(1000)
  ]) {
    assert.throws(() => api.cssDeclarations(input), `Accepted unsupported chapter CSS: ${input.slice(0, 100)}`);
  }
});

test('independent margins preserve the opposite side and linked margins move together within limits', () => {
  const api = fixture();
  const state = api.getState();
  Object.assign(state, { left: 28, right: 16, linked: false });
  assert.deepEqual(plain(api.effectiveMargins('left', 40)), { left: 40, right: 16 });
  assert.deepEqual(plain(api.effectiveMargins('right', 12)), { left: 28, right: 12 });
  assert.deepEqual(plain(api.effectiveMargins('left', -10)), { left: 8, right: 16 });
  assert.deepEqual(plain(api.effectiveMargins('right', 100)), { left: 28, right: 56 });
  api.input({ bind: 'left' }, '32');
  assert.equal(state.left, 32);
  assert.equal(state.right, 16);
  api.input({ bind: 'linked' }, undefined, 'checkbox', true);
  assert.equal(state.linked, true);
  assert.equal(state.right, 32);
  api.input({ bind: 'right' }, '12');
  assert.equal(state.left, 12);
  assert.equal(state.right, 12);
  api.input({ bind: 'linked' }, undefined, 'checkbox', false);
  api.input({ bind: 'left' }, '44');
  assert.equal(state.left, 44);
  assert.equal(state.right, 12);
  api.click({ asymmetric: '' });
  assert.deepEqual({ left: state.left, right: state.right, linked: state.linked }, { left: 32, right: 12, linked: false });
});

test('text rules match Chinese dialogue and custom regular expressions without injecting source markup', () => {
  const api = fixture();
  const state = api.getState();
  state.rules = [{ match: '对话引号', kind: '文字高亮', color: '#123456', enabled: true }];
  assert.equal(api.styledText('他说：「你好。」 她说：“再见。”'), '他说：<span style="color:#123456">「你好。」</span> 她说：<span style="color:#123456">“再见。”</span>');
  state.rules = [{ match: '正则表达式', pattern: '山海|长风', kind: '文字高亮', color: '#654321', enabled: true }];
  assert.equal(api.styledText('<山海> & 长风'), '&lt;<span style="color:#654321">山海</span>&gt; &amp; <span style="color:#654321">长风</span>');
  state.rules[0].enabled = false;
  assert.equal(api.styledText('<山海> & 长风'), '&lt;山海&gt; &amp; 长风');
  state.rules = [{ match: '正则表达式', pattern: '[', kind: '文字高亮', color: '#123456', enabled: true }];
  assert.equal(api.styledText('规则损坏也保留正文'), '规则损坏也保留正文');
});

test('earlier text rules win overlaps while later rules can still style unclaimed text', () => {
  const api = fixture();
  api.getState().rules = [
    { match: '正则表达式', pattern: '山海', kind: '文字高亮', color: '#111111', enabled: true },
    { match: '正则表达式', pattern: '山海|长风', kind: '文字高亮', color: '#222222', enabled: true },
    { match: '章节首段', kind: '首字下沉', color: '#333333', enabled: true }
  ];
  assert.equal(api.styledText('山海与长风'), '<span style="color:#111111">山海</span>与<span style="color:#222222">长风</span>');
  api.getState().rules.reverse();
  assert.equal(api.styledText('山海与长风'), '<span style="color:#222222">山海</span>与<span style="color:#222222">长风</span>');
});

test('applying a complete theme follows inherited components and preserves individual overrides', () => {
  const api = fixture();
  const state = api.getState();
  const imported = api.themes.find(theme => theme.id === 'mountain');
  api.click({ applyTheme: imported.id });
  assert.equal(state.theme, imported.id);
  assert.equal(api.css(), imported.css);
  assert.equal(api.bubble(), imported.bubble);
  assert.equal(api.god(), imported.god);
  const personalCSS = '.chapter-title { text-align: right; }';
  Object.assign(state, { css: personalCSS, bubble: '圆角方形', god: '画框' });
  api.click({ applyTheme: 'warm' });
  assert.equal(state.theme, 'warm');
  assert.equal(api.css(), personalCSS);
  assert.equal(api.bubble(), '圆角方形');
  assert.equal(api.god(), '画框');
  api.click({ follow: 'css' });
  assert.equal(state.css, null);
  assert.equal(api.css(), api.themes[0].css);
  assert.equal(api.bubble(), '圆角方形');
  assert.equal(api.god(), '画框');
  assert.equal(api.saves.at(-1).privateContent.preferencesV2.theme, 'warm');
});

test('applying only theme colors keeps current chapter and comment styles even when inherited', () => {
  const api = fixture();
  const state = api.getState();
  const inherited = { css: api.css(), bubble: api.bubble(), god: api.god() };
  api.click({ colorsTheme: 'mountain' });
  assert.equal(state.theme, 'mountain');
  assert.equal(api.theme().paper, api.themes[1].paper);
  assert.equal(api.theme().ink, api.themes[1].ink);
  assert.equal(api.theme().accent, api.themes[1].accent);
  assert.deepEqual({ css: api.css(), bubble: api.bubble(), god: api.god() }, inherited);
  Object.assign(state, { css: '.chapter-title { padding-left: 20px; }', bubble: '描边', god: '液态玻璃' });
  const personal = { css: api.css(), bubble: api.bubble(), god: api.god() };
  api.click({ colorsTheme: 'frame' });
  assert.equal(state.theme, 'frame');
  assert.deepEqual({ css: api.css(), bubble: api.bubble(), god: api.god() }, personal);
});


test('page progress switches between scrolling and pagination without reloading the prototype', () => {
  const api = fixture();
  assert.match(api.paper(), /章进度 36%/);
  assert.doesNotMatch(api.paper(), /12 \/ 180/);
  api.input({ bind: 'mode' }, '左右分页', 'select-one');
  assert.equal(api.getState().mode, '左右分页');
  assert.match(api.paper(), /12 \/ 180/);
  assert.doesNotMatch(api.paper(), /章进度 36%/);
  api.input({ bind: 'mode' }, '上下滚动', 'select-one');
  assert.match(api.paper(), /章进度 36%/);
  assert.doesNotMatch(api.paper(), /12 \/ 180/);
});

test('new and edited rule previews do not mutate or persist saved rules before confirmation', () => {
  const api = fixture();
  const state = api.getState();
  const rules = state.rules;
  const first = rules[0];
  const savedRules = plain(rules);
  api.click({ newRule: '' });
  api.input({ draft: 'name' }, '未保存的对话规则', 'text');
  api.input({ draft: 'color' }, '#012345', 'color');
  // Existing rules win earlier matches, so inspect a new regular expression on plain text.
  api.input({ draft: 'match' }, '正则表达式', 'select-one');
  api.input({ draft: 'pattern' }, '雨是在午后停的', 'text');
  assert.match(api.rulePreview(), /color:#012345/);
  assert.strictEqual(state.rules, rules);
  assert.strictEqual(state.rules[0], first);
  assert.deepEqual(plain(state.rules), savedRules);
  assert.equal(api.saves.length, 0);
  api.click({ back: '' });
  assert.deepEqual(plain(state.rules), savedRules);

  api.click({ rule: '0' });
  api.input({ draft: 'color' }, '#543210', 'color');
  assert.match(api.rulePreview(), /color:#543210/);
  assert.strictEqual(state.rules, rules);
  assert.strictEqual(state.rules[0], first);
  assert.deepEqual(plain(state.rules), savedRules);
  assert.equal(api.saves.length, 0);
  api.click({ saveRule: '' });
  assert.equal(state.rules[0].color, '#543210');
  assert.equal(api.saves.at(-1).privateContent.preferencesV2.rules[0].color, '#543210');
  assert.equal(state.rules.length, savedRules.length);
});


test('theme file import previews the added theme before applying it', async () => {
  const api = fixture();
  const before = plain(api.getState());
  const count = api.themes.length;
  const imported = { name: '我的水墨主题', paper: '#edf2ee', ink: '#344538', accent: '#7d6451',
    css: '.chapter-title { text-align: left; }', bubble: '描边', god: '液态玻璃' };
  await api.importFile('theme', { name: 'ink-theme.json', content: JSON.stringify(imported) });
  assert.equal(api.themes.length, count + 1);
  const theme = api.themes.at(-1);
  assert.equal(theme.name, imported.name);
  assert.equal(theme.source, '我的导入');
  assert.equal(theme.paper, imported.paper);
  assert.equal(theme.css, imported.css);
  assert.deepEqual(plain(api.getState()), before);
  assert.equal(api.nodes.get('[data-nav-title]').textContent, '主题详情');
  assert.match(api.nodes.get('[data-content]').innerHTML, /我的水墨主题/);
  assert.match(api.nodes.get('[data-message]').textContent, /确认应用后切换/);
  api.click({ applyTheme: theme.id });
  assert.equal(api.getState().theme, theme.id);
  assert.equal(api.css(), imported.css);
});

test('malformed or invalid theme imports do not change theme library or current preferences', async () => {
  const api = fixture();
  const beforeThemes = plain(api.themes);
  const beforeState = plain(api.getState());
  const valid = { name: '测试主题', paper: '#edf2ee', ink: '#344538', accent: '#7d6451' };
  for (const content of [
    '{broken json',
    JSON.stringify({ ...valid, name: '   ' }),
    JSON.stringify({ ...valid, paper: 'red' }),
    JSON.stringify({ ...valid, accent: '#12' }),
    JSON.stringify({ ...valid, css: 'body { color: red; }' })
  ]) {
    await api.importFile('theme', { content });
    assert.deepEqual(plain(api.themes), beforeThemes);
    assert.deepEqual(plain(api.getState()), beforeState);
    assert.match(api.nodes.get('[data-message]').textContent, /导入失败/);
  }
  await api.importFile('theme', { content: JSON.stringify(valid), size: 128 * 1024 + 1 });
  assert.deepEqual(plain(api.themes), beforeThemes);
  assert.deepEqual(plain(api.getState()), beforeState);
  assert.match(api.nodes.get('[data-message]').textContent, /文件过大/);
  assert.equal(api.saves.length, 0);
});

test('CSS files only update the chapter style and unsupported imports preserve the existing style', async () => {
  const api = fixture();
  const before = plain(api.getState());
  const beforeThemes = plain(api.themes);
  const css = '.chapter-title { color: #654321; text-align: right; border-bottom: 1px solid currentColor; }';
  await api.importFile('css', { name: 'chapter.css', content: css });
  assert.equal(api.getState().css, css);
  assert.deepEqual(plain(api.getState()), { ...before, css });
  assert.deepEqual(plain(api.themes), beforeThemes);
  assert.match(api.nodes.get('[data-message]').textContent, /章节 CSS 已导入/);
  const saves = api.saves.length;
  for (const content of ['.body-text { color: red; }', '.chapter-title { background: url(external.png); }']) {
    await api.importFile('css', { name: 'bad.css', content });
    assert.equal(api.getState().css, css);
    assert.deepEqual(plain(api.getState()), { ...before, css });
    assert.match(api.nodes.get('[data-message]').textContent, /导入失败/);
  }
  assert.equal(api.saves.length, saves);
});

test('font file becomes selectable and active only after FontFace finishes loading', async () => {
  let finishLoading, signalLoading;
  const loadingStarted = new Promise(resolve => { signalLoading = resolve; });
  const api = fixture({ fontLoad: face => new Promise(resolve => { finishLoading = () => resolve(face); signalLoading(); }) });
  const before = plain(api.fonts);
  const activeFont = api.getState().font;
  const bytes = Uint8Array.from([0, 1, 2, 3]).buffer;
  const pending = api.importFile('font', { name: '我的试读字体.ttf', bytes });
  await loadingStarted;
  assert.equal(api.fontFaces.length, 1);
  assert.deepEqual(plain(api.fonts), before);
  assert.equal(api.getState().font, activeFont);
  assert.equal(api.loadedFonts.length, 0);
  finishLoading();
  await pending;
  assert.equal(api.fonts.length, before.length + 1);
  const added = api.fonts.at(-1);
  assert.equal(added.name, '我的试读字体.ttf');
  assert.equal(added.source, '我的导入');
  assert.equal(added.family, api.fontFaces[0].family);
  assert.equal(api.getState().font, added.id);
  assert.strictEqual(api.loadedFonts[0], api.fontFaces[0]);
  assert.strictEqual(api.fontFaces[0].source, bytes);
  assert.match(api.nodes.get('[data-message]').textContent, /字体已加载/);
});

test('failed or oversized font imports leave available fonts and active font unchanged', async () => {
  const api = fixture({ fontLoad: () => Promise.reject(new Error('字体格式无效')) });
  const fonts = plain(api.fonts);
  const state = plain(api.getState());
  await api.importFile('font', { name: 'broken.otf', bytes: new ArrayBuffer(4) });
  assert.deepEqual(plain(api.fonts), fonts);
  assert.deepEqual(plain(api.getState()), state);
  assert.equal(api.loadedFonts.length, 0);
  assert.match(api.nodes.get('[data-message]').textContent, /导入失败：字体格式无效/);
  await api.importFile('font', { name: 'huge.ttf', size: 20 * 1024 * 1024 + 1 });
  assert.equal(api.fontFaces.length, 1);
  assert.deepEqual(plain(api.fonts), fonts);
  assert.deepEqual(plain(api.getState()), state);
  assert.match(api.nodes.get('[data-message]').textContent, /文件过大/);
  assert.equal(api.saves.length, 0);
});

test('opening paragraph comments through a styled bubble does not create appearance overrides', () => {
  const api = fixture();
  const state = api.getState();
  assert.equal(state.bubble, null);
  assert.equal(state.god, null);
  assert.equal(state.css, null);
  const inherited = { bubble: api.bubble(), god: api.god(), css: api.css() };
  api.click({ open: 'comments', skin: '轻量胶囊' });
  assert.equal(api.nodes.get('[data-nav-title]').textContent, '段评与神人评论');
  assert.equal(state.bubble, null);
  assert.equal(state.god, null);
  assert.equal(state.css, null);
  assert.deepEqual({ bubble: api.bubble(), god: api.god(), css: api.css() }, inherited);
  assert.equal(api.saves.length, 0);
});

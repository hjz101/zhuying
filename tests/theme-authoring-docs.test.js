import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { execFileSync, spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const read = path => readFileSync(new URL(path, import.meta.url), 'utf8');
const example = JSON.parse(read('../docs/design/theme-examples/竹影-青竹阅读.json'));
const spec = read('../docs/design/ZHUYING-THEME-PACKAGE.md');
const prompt = read('../docs/design/ZHUYING-THEME-AI-PROMPT.md');

function promptExample() {
  const current = prompt.split('## A.')[1].split('## B.')[0];
  const start = current.indexOf('{\n  "themes"');
  const end = current.indexOf('\n\n三、精确约束', start);
  assert.ok(start >= 0 && end > start, 'standalone prompt needs a complete JSON example');
  return JSON.parse(current.slice(start, end));
}

test('standalone AI prompt and downloadable fixture use the actual legacy reading format', () => {
  for (const object of [example, promptExample()]) {
    assert.deepEqual(Object.keys(object), ['themes']);
    assert.ok(Buffer.byteLength(JSON.stringify(object)) <= 3 * 1024 * 1024);
    for (const theme of object.themes) {
      for (const key of ['background', 'ink', 'accent']) assert.match(theme[key], /^#[0-9a-f]{6}$/i);
      assert.ok(['light', 'dark'].includes(theme.mode));
      assert.ok(['纯色', '液态玻璃', '画框'].includes(theme.godStyle));
      assert.match(theme.name, /^竹影/);
      assert.equal(new Set(theme.chapterTitles.map(x => x.id)).size, theme.chapterTitles.length);
      assert.equal(new Set(theme.commentBubbles.map(x => x.id)).size, theme.commentBubbles.length);
      assert.doesNotMatch(JSON.stringify(theme), /fontResourceHash|bubbleImageData|https?:\/\/(?!www\.w3\.org\/2000\/svg)|TODO/);
    }
  }
});

test('proposed reader projection covers portable preference fields and excludes local branches', () => {
  const blocks = [...spec.matchAll(/```json\n([\s\S]*?)\n```/g)].map(m => JSON.parse(m[1]));
  const projection = blocks.find(b => b.preferences);
  assert.ok(projection);
  const native = read('../ios/Zhuying/Models/ReaderPreferences.swift');
  const names = [...native.split('    var effectiveTitleCSS')[0].matchAll(/^    var (\w+)/gm)].map(m => m[1]);
  const portable = names.filter(name => ![
    'fontName', 'fontResourceHash', 'titleCSS', 'themeTitleCSS',
    'bubbleFollowsTheme', 'godFollowsTheme', 'themeGodStyle',
    'bubbleSVG', 'bubbleImageData', 'customBubbleSVG', 'customBubbleImageData'
  ].includes(name));
  assert.deepEqual(Object.keys(projection.preferences).sort(), portable.sort());
  assert.deepEqual(Object.keys(projection).sort(), ['fontSize', 'lineSpacing', 'preferences']);
  assert.equal(projection.preferences.pageElements.length, 4);
  assert.equal(new Set(projection.preferences.pageElements.map(e => e.id)).size, 4);
  for (const element of projection.preferences.pageElements) {
    assert.ok(['header', 'footer'].includes(element.zone));
    assert.ok(element.x >= element.width / 2 && element.x <= 100 - element.width / 2);
  }
});

test('both AI examples pass the production native CSS and passive SVG validators', { timeout: 120_000 }, t => {
  if (process.platform !== 'darwin' || spawnSync('xcrun', ['--find', 'swift']).status !== 0) {
    t.skip('Native validator verification requires the macOS Swift toolchain');
    return;
  }
  const nativePreferences = read('../ios/Zhuying/Models/ReaderPreferences.swift');
  const nativeAssets = read('../ios/Zhuying/Models/ThemeAssets.swift');
  const start = nativeAssets.indexOf('enum ThemeAssetValidator {');
  const end = nativeAssets.indexOf('enum ThemeStyleSamples {', start);
  assert.ok(start >= 0 && end > start);
  const fixtures = [example, promptExample()].flatMap(x => x.themes);
  const directory = mkdtempSync(join(tmpdir(), 'zhuying-theme-docs-'));
  try {
    const fixturePath = join(directory, 'themes.json');
    writeFileSync(fixturePath, JSON.stringify(fixtures));
    const source = `
import Foundation
enum ReadingMode { case scroll, paged, verticalPaged }
enum ThemeAssetKind { case title, bubble }
${nativePreferences}
${nativeAssets.slice(start, end)}
let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [[String: Any]]
for row in rows {
    let accent = UInt32(String((row["accent"] as! String).dropFirst()), radix: 16)!
    for title in row["chapterTitles"] as! [[String: Any]] {
        let css = title["css"] as! String
        precondition(ThemeAssetValidator.isValid(css, kind: .title))
        let style = try ReaderTitleStyle.parse(css: css, accent: accent)
        precondition(style.fontSize == 26 && style.alignment == "center")
        do { _ = try ReaderTitleStyle.parse(css: css + " .other { color:#000000; }", accent: accent); fatalError("unsupported CSS accepted") }
        catch is ReaderPreferenceError { }
    }
    for bubble in row["commentBubbles"] as! [[String: Any]] {
        let svg = bubble["svg"] as! String
        precondition(ThemeAssetValidator.isValid(svg, kind: .bubble))
        for count in ["0", "9", "99", "999+"] {
            let resolved = svg.replacingOccurrences(of:"{{count}}", with:count)
            precondition(ThemeAssetValidator.isValid(resolved, kind: .bubble))
        }
        precondition(!ThemeAssetValidator.isValid(svg.replacingOccurrences(of:"<path ", with:"<path onclick='run()' "), kind: .bubble))
    }
}
print("Production native validators passed")
`;
    const sourcePath = join(directory, 'main.swift');
    writeFileSync(sourcePath, source);
    assert.match(execFileSync('xcrun', ['swift', sourcePath, fixturePath], { encoding: 'utf8', timeout: 110_000 }), /Production native validators passed/);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

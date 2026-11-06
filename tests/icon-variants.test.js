import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { assertOpaqueRGBPNG } from './helpers/png.js';

const directory = new URL('../docs/design/icon-variants/', import.meta.url);

test('the icon variant manifest resolves to three distinct opaque 1024-pixel PNG designs', () => {
  const manifest = JSON.parse(readFileSync(new URL('variants.json', directory), 'utf8'));
  assert.equal(manifest.generator, 'built-in ImageGen');
  assert.equal(manifest.variants.length, 3);
  assert.deepEqual(manifest.variants.map(variant => variant.id).sort(), ['geometric', 'ink', 'papercut']);
  const hashes = new Set();
  for (const variant of manifest.variants) {
    assert.ok(variant.name.trim(), `${variant.id} needs a display name`);
    assert.ok(variant.prompt.trim(), `${variant.id} needs its generation prompt`);
    assert.equal(variant.file, `zhuying-icon-${variant.id}.png`, 'brand filename must resolve inside the variant directory');
    const png = readFileSync(new URL(variant.file, directory));
    assertOpaqueRGBPNG(png);
    hashes.add(createHash('sha256').update(png).digest('hex'));
  }
  assert.equal(hashes.size, 3, 'each style must contain a different image');
});

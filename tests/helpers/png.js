import assert from 'node:assert/strict';
import { inflateSync } from 'node:zlib';

export function assertOpaqueRGBPNG(png, width = 1024, height = 1024) {
  assert.deepEqual(png.subarray(0, 8), Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]));
  const chunks = [];
  let offset = 8;
  while (offset < png.length) {
    assert.ok(offset + 12 <= png.length, 'PNG chunk header must be complete');
    const length = png.readUInt32BE(offset);
    assert.ok(offset + length + 12 <= png.length, 'PNG chunk data must be complete');
    chunks.push({ type: png.toString('ascii', offset + 4, offset + 8), data: png.subarray(offset + 8, offset + 8 + length) });
    offset += length + 12;
  }
  assert.equal(chunks[0].type, 'IHDR');
  assert.equal(chunks.at(-1).type, 'IEND');
  const header = chunks[0].data;
  assert.equal(header.length, 13);
  assert.equal(header.readUInt32BE(0), width);
  assert.equal(header.readUInt32BE(4), height);
  assert.equal(header[8], 8, 'icon uses 8-bit color');
  assert.equal(header[9], 2, 'RGB avoids an alpha channel');
  assert.ok(!chunks.some(chunk => chunk.type === 'tRNS'), 'icon must not declare transparent RGB pixels');
  assert.deepEqual([...header.subarray(10)], [0, 0, 0], 'standard compression, filtering and no interlacing');
  const pixels = inflateSync(Buffer.concat(chunks.filter(chunk => chunk.type === 'IDAT').map(chunk => chunk.data)));
  const stride = width * 3 + 1;
  assert.equal(pixels.length, height * stride, 'all RGB scanlines must decode');
  for (let row = 0; row < height; row++) assert.ok(pixels[row * stride] <= 4, `valid PNG filter on row ${row}`);
}

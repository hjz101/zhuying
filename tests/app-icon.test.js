import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { inflateSync } from 'node:zlib';

const read = path => readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');
const assetPath = 'ios/Zhuying/Assets.xcassets/AppIcon.appiconset/';

test('the universal iOS app icon resolves to a valid opaque 1024-pixel RGB PNG', () => {
  const catalog = JSON.parse(read('ios/Zhuying/Assets.xcassets/Contents.json'));
  const manifest = JSON.parse(read(`${assetPath}Contents.json`));
  assert.equal(catalog.info.version, 1);
  assert.equal(manifest.info.version, 1);
  assert.equal(manifest.images.length, 1, 'one universal source supplies all iOS icon sizes');
  const [icon] = manifest.images;
  assert.equal(icon.idiom, 'universal');
  assert.equal(icon.platform, 'ios');
  assert.equal(icon.size, '1024x1024');
  assert.match(icon.filename, /^zhuying-[a-z-]+\.png$/);
  const png = readFileSync(new URL(`../${assetPath}${icon.filename}`, import.meta.url));
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
  assert.equal(header.readUInt32BE(0), 1024);
  assert.equal(header.readUInt32BE(4), 1024);
  assert.equal(header[8], 8, 'icon uses 8-bit color');
  assert.equal(header[9], 2, 'RGB avoids an alpha channel in the App Store icon');
  assert.ok(!chunks.some(chunk => chunk.type === 'tRNS'), 'icon must not declare transparent RGB pixels');
  assert.deepEqual([...header.subarray(10)], [0, 0, 0], 'standard compression, filtering and no interlacing');
  const pixels = inflateSync(Buffer.concat(chunks.filter(chunk => chunk.type === 'IDAT').map(chunk => chunk.data)));
  const stride = 1024 * 3 + 1;
  assert.equal(pixels.length, 1024 * stride, 'all RGB scanlines must decode');
  for (let row = 0; row < 1024; row++) assert.ok(pixels[row * stride] <= 4, `valid PNG filter on row ${row}`);
});

test('Demo and Production archive the same target with the AppIcon catalog in its resources', () => {
  const project = read('ios/Zhuying.xcodeproj/project.pbxproj');
  const projectSource = read('ios/project.yml');
  assert.match(projectSource, /ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon/);
  const objects = new Map([...project.matchAll(/^\t\t([A-F0-9]{24}) \/\* [^*\n]+ \*\/ = \{\n([\s\S]*?)^\t\t\};/gm)]
    .map(([, id, body]) => [id, body]));
  const targetIDs = ['Zhuying', 'Zhuying Production'].map(name => {
    const scheme = read(`ios/Zhuying.xcodeproj/xcshareddata/xcschemes/${name}.xcscheme`);
    const build = scheme.match(/<BuildActionEntry\b[\s\S]*?<\/BuildActionEntry>/)?.[0];
    assert.ok(build, `${name} needs a build action`);
    assert.match(build, /buildForArchiving = "YES"/);
    assert.match(build, /BlueprintName = "Zhuying"/);
    return build.match(/BlueprintIdentifier = "([A-F0-9]{24})"/)[1];
  });
  assert.equal(targetIDs[0], targetIDs[1]);
  const target = objects.get(targetIDs[0]);
  assert.match(target, /isa = PBXNativeTarget;/);
  assert.match(target, /productType = "com.apple.product-type.application";/);
  const phases = target.match(/buildPhases = \(([\s\S]*?)\);/)[1];
  const resources = [...phases.matchAll(/([A-F0-9]{24}) \/\*/g)]
    .map(([, id]) => objects.get(id)).find(body => /isa = PBXResourcesBuildPhase;/.test(body));
  assert.ok(resources, 'application needs a resources build phase');
  const buildFileID = resources.match(/([A-F0-9]{24}) \/\* Assets.xcassets in Resources \*\//)?.[1];
  assert.ok(buildFileID, 'the app must compile the asset catalog');
  const fileRefID = project.match(new RegExp(`${buildFileID} /\\* Assets\\.xcassets in Resources \\*/ = \\{isa = PBXBuildFile; fileRef = ([A-F0-9]{24})`))?.[1];
  assert.ok(fileRefID, 'resource entry must resolve to a real catalog');
  assert.match(project, new RegExp(`${fileRefID} /\\* Assets\\.xcassets \\*/ = \\{isa = PBXFileReference; lastKnownFileType = folder\\.assetcatalog; path = Assets\\.xcassets;`));
  assert.ok([...objects.values()].some(body => body.includes(`${fileRefID} /* Assets.xcassets */`) && /path = Zhuying;/.test(body)),
    'asset catalog must resolve inside the current Zhuying source directory');
  const configurationListID = target.match(/buildConfigurationList = ([A-F0-9]{24})/)[1];
  const configurationIDs = [...objects.get(configurationListID).matchAll(/([A-F0-9]{24}) \/\* (?:Debug|Release) \*\//g)].map(([, id]) => id);
  assert.equal(configurationIDs.length, 2, 'Debug and Release both need the icon');
  for (const id of configurationIDs) assert.match(objects.get(id), /ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;/);
});

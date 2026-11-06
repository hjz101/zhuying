import { execFileSync, spawnSync } from 'node:child_process';
import { mkdirSync, readFileSync, writeFileSync, renameSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';

const [device, destination, queries] = process.argv.slice(2);
if (!/^[0-9a-f-]{36}$/i.test(device ?? '') || !destination) {
  console.error('Usage: node ios/scripts/validate-source.mjs <simulator-UUID> <report.json> [book-one|book-two]');
  process.exit(1);
}
if (queries !== undefined) {
  const values = queries.split('|').map(x => x.trim());
  if (values.length !== 2 || new Set(values).size !== 2 || values.some(x => !x || [...x].length > 80)) {
    console.error('Source validation requires two distinct book names, each at most 80 characters.');
    process.exit(1);
  }
}
const app = 'com.zhuying.reader.demo';
try {
  const container = execFileSync('xcrun', ['simctl', 'get_app_container', device, app, 'data'], { encoding: 'utf8' }).trim();
  const source = join(container, 'Documents', 'DevelopmentValidation', 'source-feasibility.json');
  let previous = '';
  try { previous = readFileSync(source, 'utf8'); } catch {}
  const started = Date.now();
  // simctl launch otherwise reuses an existing process and ignores new arguments.
  spawnSync('xcrun', ['simctl', 'terminate', device, app], { stdio: 'ignore' });
  const args = ['simctl', 'launch', device, app, '--production', '--validate-step-zero-source'];
  if (queries) args.push('--source-validation-queries', queries);
  execFileSync('xcrun', args, { stdio: 'ignore' });
  let report, raw;
  while (Date.now() - started < 240_000) {
    try {
      const current = readFileSync(source, 'utf8');
      const parsed = JSON.parse(current);
      if (current !== previous && Date.parse(parsed.startedAt) >= started - 1000 && parsed.status !== 'running') {
        if (parsed.schemaVersion !== 1 || parsed.sourceID !== 'shushan' || !Array.isArray(parsed.works) || !Array.isArray(parsed.requests)) throw new Error('Unexpected source report');
        raw = current; report = parsed; break;
      }
    } catch (error) {
      if (error.message === 'Unexpected source report') throw error;
    }
    await new Promise(resolve => setTimeout(resolve, 1000));
  }
  if (!report) throw new Error('Source validation timed out; no fresh completed report was produced');
  if (report.status === 'passed') {
    const works = report.works;
    const valid = works.length === 2 && new Set(works.map(x => x.id)).size === 2 && new Set(works.map(x => x.title)).size === 2 &&
      works.every(x => Array.isArray(x.chapters) && x.chapters.length === 3 && new Set(x.chapters.map(c => c.id)).size === 3 &&
        new Set(x.chapters.map(c => c.contentHash)).size === 3 && x.chapters.every(c => c.utf16Count >= 200 && c.paragraphCount > 0 && /^[a-f0-9]{64}$/.test(c.contentHash))) &&
      JSON.stringify(works[0].chapters.map(c => c.contentHash)) !== JSON.stringify(works[1].chapters.map(c => c.contentHash));
    if (!valid) throw new Error('Invalid successful source report: two real three-chapter runs are required');
  }
  const output = resolve(destination);
  mkdirSync(dirname(output), { recursive: true });
  const staging = output + '.tmp';
  writeFileSync(staging, raw); renameSync(staging, output);
  console.log(`Source validation: ${report.status}; works=${report.works.length}; requests=${report.requests.length}`);
  console.log(`Redacted report: ${output}`);
  process.exitCode = report.status === 'passed' ? 0 : report.status === 'authentication-required' ? 3 : 2;
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}

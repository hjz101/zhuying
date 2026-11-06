#!/usr/bin/env python3
"""Read local acceptance evidence and candidate hashes; never sign or publish."""
from __future__ import annotations
import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import subprocess

FROZEN_BUDGET_SHA256 = '269f789b9de7889d7f56fc76caabe0775752727ba105475b60871af67dffc28e'

PHYSICAL_CASES = {
    'ios17', 'current-ios', 'small-screen', 'large-screen', 'large-text',
    'landscape', 'voiceover', 'font-import', 'third-party-files', 'offline',
    'force-quit-resume', 'background-resume', 'backup-restore', 'upgrade-data',
}


def source_digest(root: Path) -> str:
    paths = [root / 'ios/project.yml']
    for name in ['ios/Yueshan.xcodeproj/project.pbxproj', 'ios/Yueshan.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved']:
        path = root / name
        if path.is_file(): paths.append(path)
    for folder in ['Yueshan', 'YueshanTests', 'YueshanUITests', 'YueshanPerformanceTests', 'YueshanPerformanceUITests', 'YueshanTestSupport']:
        paths += [p for p in (root / 'ios' / folder).rglob('*') if p.is_file() and p.suffix in {'.swift', '.json', '.plist', '.ttf', '.epub'}]
    digest = hashlib.sha256()
    for path in sorted(paths):
        for value in [path.relative_to(root).as_posix().encode(), path.read_bytes()]:
            digest.update(len(value).to_bytes(8, 'big')); digest.update(value)
    return digest.hexdigest()


def inventory(root: Path) -> dict:
    def count(folder):
        return sum(len(re.findall(r'func\s+test\w+\s*\(', p.read_text())) for p in (root / 'ios' / folder).rglob('*.swift'))
    return {'unitTests': count('YueshanTests'), 'uiFlows': count('YueshanUITests')}


def evaluate(evidence: dict, performance: dict, launch: dict, budget: dict,
             budget_digest: str, current_digest: str, required: dict,
             candidate: dict | None = None, artifact_valid: bool = False) -> dict:
    checks = []
    def check(task, errors):
        checks.append({'task': task, 'status': 'blocked' if errors else 'passed', 'reasons': errors})

    live = evidence.get('liveApp', {})
    books = live.get('books', [])
    fresh = evidence.get('sourceDigest') == current_digest
    live_ok = fresh and live.get('status') == 'passed' and live.get('sampleKind') == 'live-app' and len(books) >= 2
    live_ok = live_ok and all(b.get('id') and b.get('title') for b in books)
    live_ok = live_ok and len({b.get('id') for b in books}) == len(books) and len({b.get('title') for b in books}) == len(books)
    chapter_runs = []
    for book in books:
        chapters = book.get('chapters', [])
        live_ok = live_ok and book.get('restartResumed') is True and len(chapters) >= 3
        live_ok = live_ok and all(book.get(k) is True for k in ['searched', 'detailsShown', 'catalogShown'])
        live_ok = live_ok and len({c.get('id') for c in chapters}) == len(chapters)
        live_ok = live_ok and len({c.get('contentHash') for c in chapters}) == len(chapters)
        live_ok = live_ok and all(c.get('utf16Count', 0) >= 200 for c in chapters)
        live_ok = live_ok and all(re.fullmatch(r'[a-f0-9]{64}', c.get('contentHash', '')) for c in chapters)
        orders = [c.get('order', -1) for c in chapters]
        live_ok = live_ok and all(b == a + 1 for a, b in zip(orders, orders[1:]))
        chapter_runs.append(tuple(c.get('contentHash') for c in chapters))
    live_ok = live_ok and len(set(chapter_runs)) == len(chapter_runs)
    check('T030', [] if live_ok else ['Real App two-book / three-chapter / restart acceptance is missing; adapter and fixture reports do not satisfy it.'])

    errors = []
    if not fresh: errors.append('Acceptance evidence does not match the current source and tests.')
    functional = evidence.get('functional', {})
    if functional.get('status') != 'passed' or functional.get('failedTests') != 0:
        errors.append('Functional regression has not passed.')
    for key in ['unitTests', 'uiFlows']:
        if functional.get(key, 0) < required[key]: errors.append(f'Incomplete {key} coverage: requires {required[key]}.')
    metrics = performance.get('measurements', []) + [launch]
    ids = [m.get('id') for m in metrics]
    if len(ids) != len(set(ids)) or set(ids) != set(budget['limits']): errors.append('Performance metrics are missing or duplicated.')
    if (performance.get('budgetSHA256') != budget_digest or budget_digest != FROZEN_BUDGET_SHA256
            or performance.get('scales') != budget['scales'] or performance.get('profile') != budget['profile']
            or launch.get('profile') != budget['profile']):
        errors.append('Performance budget or sample scales were changed.')
    for metric in metrics:
        key = metric.get('id'); limit = budget['limits'].get(key); samples = metric.get('samples', [])
        count = budget['storageSamples'] if str(key).startswith('library.') else budget['samples']
        if key == 'shelf.sort.ms': count *= 3
        if key == 'process.peak-rss.mib': count = 1
        if len(samples) != count or not all(type(x) in (int, float) and math.isfinite(x) and x > 0 for x in samples):
            errors.append(f'Invalid raw samples: {key}.'); continue
        maximum = max(samples)
        if metric.get('maximum') != maximum or metric.get('limit') != limit or metric.get('withinTarget') is not (maximum <= limit if limit else False):
            errors.append(f'Inconsistent measurement: {key}.')
        if limit is not None and maximum > limit: errors.append(f'{key}: {maximum:.2f} exceeds {limit}.')
    if not live_ok: errors.append('Final online regression depends on T030.')
    check('T035', errors)

    matrix = evidence.get('deviceMatrix', {})
    passed_cases = {case.get('id') for case in matrix.get('cases', []) if case.get('status') == 'passed'}
    errors = []
    if not fresh: errors.append('Device evidence is stale.')
    if matrix.get('status') != 'passed' or matrix.get('sampleKind') != 'physical-device':
        errors.append('Physical-device acceptance has not run; simulator results cannot replace it.')
    missing = PHYSICAL_CASES - passed_cases
    if missing: errors.append('Missing physical cases: ' + ', '.join(sorted(missing)))
    check('T036', errors)

    signed = evidence.get('signedInternalTest', {})
    candidate = candidate or {}
    errors = []
    if not fresh: errors.append('Signing evidence is stale.')
    if not (candidate.get('kind') == 'development-device' and 'iPhoneOS' in candidate.get('platforms', []) and candidate.get('signatureVerified') is True):
        errors.append('A verified signed iPhone candidate is missing.')
    if not (signed.get('status') == 'passed' and all(signed.get(k) is True for k in ['installed', 'upgradedWithData', 'feedbackReviewed']) and signed.get('openBlockingIssues') == 0):
        errors.append('Signed installation, upgrade and internal feedback acceptance are incomplete.')
    check('T037', errors)
    errors = []
    if not artifact_valid: errors.append('Candidate artifact hash, size or source commit is missing or invalid.')
    blocked = [item['task'] for item in checks if item['status'] != 'passed']
    if blocked: errors.append('Prerequisites remain: ' + ', '.join(blocked))
    check('T038', errors)
    return {'schemaVersion': 1, 'readyForReleaseCandidate': all(x['status'] == 'passed' for x in checks), 'checks': checks, 'signsOrUploads': False}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--candidate', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    evidence = json.loads(args.evidence.read_text())
    base = args.evidence.parent
    performance = json.loads((base / evidence['performanceReport']).read_text())
    launch = json.loads((base / evidence['launchReport']).read_text())
    raw_budget = (root / 'ios/YueshanTestSupport/performance-budget.json').read_bytes()
    candidate = json.loads(args.candidate.read_text()) if args.candidate else None
    valid = False
    if candidate:
        name = candidate.get('artifact', '')
        artifact = args.candidate.parent / name
        if name and Path(name).name == name and artifact.is_file():
            commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()
            valid = (candidate.get('commit') == commit and candidate.get('bytes') == artifact.stat().st_size
                     and candidate.get('sha256') == hashlib.sha256(artifact.read_bytes()).hexdigest())
    result = evaluate(evidence, performance, launch, json.loads(raw_budget), hashlib.sha256(raw_budget).hexdigest(), source_digest(root), inventory(root), candidate, valid)
    data = json.dumps(result, indent=2, ensure_ascii=False) + '\n'
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True); args.output.write_text(data)
    print(data, end='')
    return 0 if result['readyForReleaseCandidate'] else 2


if __name__ == '__main__':
    raise SystemExit(main())

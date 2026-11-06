#!/usr/bin/env python3
"""Package an already-built local candidate without signing or uploading it."""
import argparse
import hashlib
import json
import plistlib
from pathlib import Path
import subprocess


def metadata(app: Path, commit: str, kind: str) -> dict:
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    platforms = info.get('CFBundleSupportedPlatforms', [])
    expected = 'iPhoneSimulator' if kind == 'simulator' else 'iPhoneOS'
    if expected not in platforms:
        raise ValueError(f'{kind} requires {expected}, found {platforms}')
    if len(commit) != 40 or any(c not in '0123456789abcdef' for c in commit):
        raise ValueError('A full Git commit is required')
    if info.get('YueshanSourceRevision') != commit:
        raise ValueError('Built App source revision does not match the current committed checkout')
    return {
        'schemaVersion': 1, 'kind': kind, 'commit': commit,
        'bundleIdentifier': info['CFBundleIdentifier'],
        'version': info['CFBundleShortVersionString'], 'build': info['CFBundleVersion'],
        'minimumOS': info.get('MinimumOSVersion'), 'platforms': platforms,
        'releaseGate': 'not-approved', 'uploaded': False,
        'installation': 'Simulator only' if kind == 'simulator' else 'Unsigned device archive; signing and device acceptance required',
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--kind', choices=['simulator', 'unsigned-device'], required=True)
    args = parser.parse_args()
    repository = Path(__file__).resolve().parents[2]
    if subprocess.check_output(['git', 'status', '--porcelain'], cwd=repository).strip():
        raise SystemExit('Commit source changes before packaging a traceable candidate')
    commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=repository, text=True).strip()
    result = metadata(args.app, commit, args.kind)
    args.output.mkdir(parents=True, exist_ok=True)
    archive = args.output / f'yueshan-{args.kind}-{commit[:8]}.zip'
    if archive.exists():
        raise SystemExit(f'Refusing to overwrite {archive}')
    subprocess.run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(args.app), str(archive)], check=True)
    result['artifact'] = archive.name
    result['sha256'] = hashlib.sha256(archive.read_bytes()).hexdigest()
    result['bytes'] = archive.stat().st_size
    (args.output / f'{archive.stem}.json').write_text(json.dumps(result, indent=2, ensure_ascii=False) + '\n')
    print(archive)


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""Read a built Zhuying App or IPA and report bundled source definitions."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import stat
import sys
import tempfile
import zipfile
from xml.parsers.expat import ExpatError


POLICY_KEY = 'ZhuyingBundledSources'
PRESET_MARKERS = (
    'v1.vossc.com', '书山聚合', '固定原生书源', '山海书库', '云间小说', '纸上漫游', '远山书屋',
    'books.example', 'yunjian.example', 'paper.example', 'yuanshan.example', 'sources.example',
)
ENCODINGS = ('utf-8', 'utf-16-le', 'utf-16-be')
MAX_FILES = 50_000
MAX_PACKAGE_BYTES = 512 * 1024 * 1024
MAX_JSON_BYTES = 16 * 1024 * 1024
MAX_EXECUTABLE_BYTES = 256 * 1024 * 1024


class VerificationFailure(Exception):
    def __init__(self, code, path=''):
        self.code, self.path = code, path


def empty_report(kind):
    return {
        'schemaVersion': 1, 'verification': 'zhuying-source-free-package',
        'inputKind': kind, 'passed': False,
        'bundle': {'identifier': None, 'version': None, 'build': None, 'sourceRevision': None},
        'policy': {'key': POLICY_KEY, 'declaredValue': None},
        'resources': {'jsonFilesScanned': 0, 'sourceDefinitionsFound': 0},
        'executable': {'bytesScanned': 0, 'checkedEncodings': list(ENCODINGS), 'presetMarkersFound': []},
        'violations': [],
    }


def violation(report, code, path=''):
    report['violations'].append({'code': code, 'path': path})


def source_definition_count(value):
    """Recognize concrete values, never JSON Schema property declarations."""
    count, visited, pending = 0, 0, [value]
    while pending:
        node = pending.pop()
        visited += 1
        if visited > 1_000_000:
            raise VerificationFailure('json-structure-limit')
        if isinstance(node, dict):
            address = node.get('bookSourceUrl')
            name = node.get('bookSourceName')
            if isinstance(address, str) and address.strip() and (
                isinstance(name, str) and name.strip()
                or any(isinstance(node.get(k), (str, dict)) and bool(node[k])
                       for k in ('ruleSearch', 'ruleContent', 'jsLib'))
            ):
                count += 1
            sources = node.get('sources')
            if isinstance(sources, list):
                count += sum(1 for row in sources if isinstance(row, dict)
                             and isinstance(row.get('url'), str) and row['url'].strip()
                             and isinstance(row.get('name'), str) and row['name'].strip())
            pending.extend(node.values())
        elif isinstance(node, list):
            pending.extend(node)
    return count


def read_bounded(opener, name, limit):
    with opener(name) as stream:
        data = stream.read(limit + 1)
    if len(data) > limit:
        raise VerificationFailure('file-size-limit', name)
    return data


def inspect_members(names, opener, report):
    if 'Info.plist' not in names:
        raise VerificationFailure('missing-info-plist', 'Info.plist')
    try:
        info = plistlib.loads(read_bounded(opener, 'Info.plist', 4 * 1024 * 1024))
    except (ValueError, plistlib.InvalidFileException, ExpatError):
        raise VerificationFailure('invalid-info-plist', 'Info.plist') from None
    if not isinstance(info, dict):
        raise VerificationFailure('invalid-info-plist', 'Info.plist')
    for target, key in (('identifier', 'CFBundleIdentifier'), ('version', 'CFBundleShortVersionString'),
                        ('build', 'CFBundleVersion'), ('sourceRevision', 'ZhuyingSourceRevision')):
        report['bundle'][target] = info.get(key) if isinstance(info.get(key), str) else None
    policy = info.get(POLICY_KEY)
    report['policy']['declaredValue'] = policy if isinstance(policy, bool) else None
    if policy is not False:
        violation(report, 'bundled-sources-policy-must-be-false', 'Info.plist')
    for name in sorted(n for n in names if n.lower().endswith('.json')):
        report['resources']['jsonFilesScanned'] += 1
        try:
            value = json.loads(read_bounded(opener, name, MAX_JSON_BYTES))
            count = source_definition_count(value)
        except (ValueError, UnicodeError, RecursionError):
            violation(report, 'unreadable-json-resource', name)
            continue
        report['resources']['sourceDefinitionsFound'] += count
        if count:
            violation(report, 'bundled-source-definition', name)
    executable = info.get('CFBundleExecutable')
    if not isinstance(executable, str) or not executable or executable in ('.', '..') or '/' in executable or '\\' in executable:
        raise VerificationFailure('invalid-executable-name', 'Info.plist')
    if executable not in names:
        raise VerificationFailure('missing-executable', executable)
    patterns = [(marker, marker.encode(encoding)) for marker in PRESET_MARKERS for encoding in ENCODINGS]
    overlap = max(len(pattern) for _, pattern in patterns) - 1
    found, carry, length = set(), b'', 0
    with opener(executable) as stream:
        while True:
            chunk = stream.read(1024 * 1024)
            if not chunk:
                break
            if length == 0 and chunk[:4] not in (
                b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xce',
                b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca', b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca',
            ):
                raise VerificationFailure('invalid-mach-o-executable', executable)
            length += len(chunk)
            if length > MAX_EXECUTABLE_BYTES:
                raise VerificationFailure('executable-size-limit', executable)
            window = carry + chunk
            found.update(marker for marker, pattern in patterns if pattern in window)
            carry = window[-overlap:]
    if length < 28:
        raise VerificationFailure('invalid-mach-o-executable', executable)
    report['executable']['bytesScanned'] = length
    report['executable']['presetMarkersFound'] = sorted(found)
    if found:
        violation(report, 'preset-marker-in-executable', executable)


def inspect_directory(app, report):
    if not app.is_dir() or app.suffix != '.app':
        raise VerificationFailure('expected-app-bundle')
    paths = list(app.rglob('*'))
    if len(paths) > MAX_FILES:
        raise VerificationFailure('package-entry-limit')
    if any(path.is_symlink() for path in paths):
        raise VerificationFailure('symlink-in-app-bundle')
    files = {path.relative_to(app).as_posix(): path for path in paths if path.is_file()}
    if sum(path.stat().st_size for path in files.values()) > MAX_PACKAGE_BYTES:
        raise VerificationFailure('package-size-limit')
    inspect_members(files, lambda name: files[name].open('rb'), report)


def inspect_ipa(ipa, report):
    # Inspect ZIP members directly: no archive entry is ever extracted to disk.
    with zipfile.ZipFile(ipa) as archive:
        entries = archive.infolist()
        if len(entries) > MAX_FILES:
            raise VerificationFailure('package-entry-limit')
        if sum(entry.file_size for entry in entries) > MAX_PACKAGE_BYTES:
            raise VerificationFailure('package-size-limit')
        seen, apps = set(), set()
        for entry in entries:
            name = entry.filename
            parts = name.rstrip('/').split('/')
            if (name.startswith('/') or ':' in parts[0] or '\\' in name or '\x00' in name
                    or any(part in ('', '.', '..') for part in parts)
                    or stat.S_ISLNK(entry.external_attr >> 16) or entry.flag_bits & 1):
                raise VerificationFailure('unsafe-zip-member')
            normalized = '/'.join(parts)
            if normalized in seen:
                raise VerificationFailure('duplicate-zip-member')
            seen.add(normalized)
            if len(parts) >= 2 and parts[0] == 'Payload' and parts[1].endswith('.app'):
                apps.add(parts[1])
        if len(apps) != 1:
            raise VerificationFailure('expected-one-payload-app')
        prefix = 'Payload/' + next(iter(apps)) + '/'
        members = {entry.filename[len(prefix):]: entry for entry in entries
                   if entry.filename.startswith(prefix) and not entry.is_dir()}
        inspect_members(members, lambda name: archive.open(members[name]), report)


def verify(*, app=None, ipa=None):
    if (app is None) == (ipa is None):
        raise ValueError('Choose exactly one application bundle or IPA')
    report = empty_report('app' if app is not None else 'ipa')
    try:
        if app is not None:
            inspect_directory(Path(app), report)
        else:
            inspect_ipa(Path(ipa), report)
    except VerificationFailure as failure:
        violation(report, failure.code, failure.path)
    except (OSError, ValueError, RuntimeError, zipfile.BadZipFile):
        # File contents, underlying exception messages and credentials stay out of reports.
        violation(report, 'unreadable-package')
    report['passed'] = not report['violations']
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument('--app', type=Path)
    source.add_argument('--ipa', type=Path)
    parser.add_argument('--output', type=Path, help='Write the same JSON report outside the input package')
    args = parser.parse_args()
    if args.output:
        output = args.output.resolve()
        if (args.app and output.is_relative_to(args.app.resolve())) or (args.ipa and output == args.ipa.resolve()):
            parser.error('The report must not modify the input package')
    report = verify(app=args.app, ipa=args.ipa)
    text = json.dumps(report, indent=2, ensure_ascii=False) + '\n'
    if args.output:
        # Replacing the output entry avoids following a symlink/hardlink into an input file.
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=args.output.parent,
                                             prefix='.zhuying-source-free-', delete=False) as stream:
                temporary = Path(stream.name)
                stream.write(text)
            os.replace(temporary, args.output)
        finally:
            if temporary is not None:
                temporary.unlink(missing_ok=True)
    sys.stdout.write(text)
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())

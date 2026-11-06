#!/usr/bin/env python3
"""Export an unsigned device IPA or sign with private local certificate files."""
import argparse
import datetime as dt
import fnmatch
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import secrets
import shlex
import shutil
import stat
import struct
import subprocess
import tempfile
import urllib.parse
import urllib.request
import zipfile
from xml.parsers.expat import ExpatError


def invoke(args, *, data=None, label='Signing operation'):
    result = subprocess.run(args, input=data, capture_output=True)
    if result.returncode:
        # Do not format argv: security import receives private passwords.
        raise RuntimeError(f'{label} failed (exit {result.returncode}).')
    return result.stdout


def choose_identifier(original, profile):
    pattern = profile['Entitlements']['application-identifier']
    prefix, separator, allowed = pattern.partition('.')
    if not separator or not allowed or prefix not in profile.get('ApplicationIdentifierPrefix', []):
        raise ValueError('Invalid provisioning application prefix')
    selected = original if fnmatch.fnmatchcase(original, allowed) else allowed
    if '*' in selected or not re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+', selected):
        raise ValueError('Profile cannot provide a concrete compatible bundle identifier')
    return selected


def entitlements(profile, bundle_id, certificate_der, now=None):
    now = now or dt.datetime.now(dt.timezone.utc)
    def utc(value):
        return value.replace(tzinfo=dt.timezone.utc) if value.tzinfo is None else value
    if not utc(profile['CreationDate']) <= now < utc(profile['ExpirationDate']):
        raise ValueError('Provisioning profile is expired or not yet valid')
    if certificate_der not in profile.get('DeveloperCertificates', []):
        raise ValueError('Signing certificate is not authorized by this profile')
    if not profile.get('ProvisionedDevices') and not profile.get('ProvisionsAllDevices'):
        raise ValueError('A device provisioning profile is required')
    team = profile.get('TeamIdentifier', [])
    if len(team) != 1:
        raise ValueError('Expected one signing team')
    allowed = profile['Entitlements']
    prefix = profile['ApplicationIdentifierPrefix'][0]
    app_id = prefix + '.' + bundle_id
    if not fnmatch.fnmatchcase(app_id, allowed['application-identifier']):
        raise ValueError('Bundle identifier is outside the provisioning scope')
    group = app_id
    if not any(fnmatch.fnmatchcase(group, p) for p in allowed.get('keychain-access-groups', [])):
        raise ValueError('No compatible application keychain group')
    return {'application-identifier':app_id,
            'com.apple.developer.team-identifier':team[0],
            'get-task-allow':bool(allowed.get('get-task-allow', False)),
            'keychain-access-groups':[group]}

def signed_entitlements(app):
    result = plistlib.loads(invoke(['codesign','--display','--entitlements','-','--xml',str(app)],label='Signed entitlements'))
    if not isinstance(result,dict):raise ValueError('Invalid signed entitlements')
    return result


def application_brand(info):
    if (info.get('CFBundleDisplayName') != '竹影' or info.get('CFBundleName') != 'Zhuying'
            or info.get('CFBundleExecutable') != 'Zhuying'):
        raise ValueError('Rebuild the Zhuying application before exporting its IPA')
    return {'displayName': info['CFBundleDisplayName'], 'productName': info['CFBundleName'],
            'executable': info['CFBundleExecutable']}


def device_info_bytes(info):
    # Keep the same binary plist representation as an Xcode device build.
    return plistlib.dumps(info, fmt=plistlib.FMT_BINARY)


def validate_ipa(output, *, require_signature=True):
    with zipfile.ZipFile(output) as archive:
        entries = archive.infolist()
        names = [entry.filename for entry in entries]
        if len(names) != len(set(names)):
            raise ValueError('Duplicate IPA archive paths')
        for entry in entries:
            parts = PurePosixPath(entry.filename).parts
            if (not parts or parts[0] != 'Payload' or '..' in parts or '\\' in entry.filename
                    or any(p.startswith('._') or p in ('.DS_Store', '__MACOSX') for p in parts)):
                raise ValueError('Unexpected path or macOS metadata in IPA')
            if stat.S_ISLNK(entry.external_attr >> 16) or entry.flag_bits & 9:
                raise ValueError('IPA must use regular, unencrypted ZIP entries with complete local headers')
        apps = {PurePosixPath(n).parts[1] for n in names if len(PurePosixPath(n).parts) > 1}
        if len(apps) != 1 or not next(iter(apps)).endswith('.app'):
            raise ValueError('IPA must contain exactly one Payload/App.app')
        app = 'Payload/' + next(iter(apps)) + '/'
        info_path = app + 'Info.plist'
        if info_path not in names or archive.getinfo(info_path).file_size > 4 * 1024 * 1024:
            raise ValueError('Missing or oversized primary application Info.plist')
        try:
            raw = archive.read(info_path)
            info = plistlib.loads(raw)
        except (ValueError, plistlib.InvalidFileException, ExpatError) as error:
            raise ValueError('Primary application Info.plist cannot be parsed') from error
        required = ['CFBundleIdentifier', 'CFBundleExecutable', 'CFBundleName',
                    'CFBundleShortVersionString', 'CFBundleVersion', 'MinimumOSVersion']
        if (not isinstance(info, dict) or any(not isinstance(info.get(k), str) or not info[k] for k in required)
                or info.get('CFBundlePackageType') != 'APPL'
                or info.get('CFBundleSupportedPlatforms') != ['iPhoneOS']):
            raise ValueError('Primary application Info.plist has incomplete device metadata')
        executable = info['CFBundleExecutable']
        if '/' in executable or '\\' in executable or executable in ('.', '..'):
            raise ValueError('Invalid application executable name')
        required_paths = [app + executable]
        if require_signature:
            required_paths += [app + 'embedded.mobileprovision', app + '_CodeSignature/CodeResources']
        elif any('_CodeSignature' in PurePosixPath(n).parts or PurePosixPath(n).name == 'embedded.mobileprovision' for n in names):
            raise ValueError('Unsigned IPA must not contain signature resources or provisioning profiles')
        for path in required_paths:
            if path not in names or archive.getinfo(path).file_size == 0:
                raise ValueError('Missing application executable, provisioning profile or signature resources')
        with archive.open(app + executable) as executable_file:
            header = executable_file.read(32)
        if (len(header) != 32 or header[:4] != b'\xcf\xfa\xed\xfe'
                or struct.unpack_from('<I', header, 4)[0] != 0x0100000c
                or struct.unpack_from('<I', header, 12)[0] != 2):
            raise ValueError('IPA requires an arm64 device Mach-O executable')
        if not ((archive.getinfo(app + executable).external_attr >> 16) & stat.S_IXUSR):
            raise ValueError('Application executable permission is missing')
        if not require_signature:
            command_count, command_bytes = struct.unpack_from('<II', header, 16)
            if command_count > 4096 or command_bytes > 16 * 1024 * 1024:
                raise ValueError('Invalid Mach-O load commands')
            with archive.open(app + executable) as stream:
                stream.read(32)
                commands = stream.read(command_bytes)
            offset = 0
            for _ in range(command_count):
                if offset + 8 > len(commands):
                    raise ValueError('Incomplete Mach-O load command')
                command, size = struct.unpack_from('<II', commands, offset)
                if command == 0x1d:
                    raise ValueError('Unsigned IPA executable still contains a code signature')
                if size < 8 or offset + size > len(commands):
                    raise ValueError('Invalid Mach-O load command size')
                offset += size
            if offset != command_bytes or len(commands) != command_bytes:
                raise ValueError('Incomplete Mach-O load commands')
        # Check the local headers too: lightweight importers may read them directly.
        with output.open('rb') as stream:
            for entry in entries:
                stream.seek(entry.header_offset)
                header = struct.unpack('<4s5H3I2H', stream.read(30))
                if (header[0] != b'PK\x03\x04' or header[2] != entry.flag_bits
                        or header[6:9] != (entry.CRC, entry.compress_size, entry.file_size)):
                    raise ValueError('Incomplete or inconsistent IPA local ZIP header')
        if archive.testzip() is not None:
            raise ValueError('IPA archive CRC check failed')
        return {'primaryInfoPlist': info_path, 'infoPlistFormat': 'binary' if raw.startswith(b'bplist00') else 'xml',
                'entryCount': len(names), 'macOSMetadataEntries': 0, 'completeLocalHeaders': True,
                'arm64Executable': True, 'zipCRCVerified': True,
                'signatureRequired': require_signature}


def archive_payload(payload, output, *, require_signature=True):
    if output.exists():
        raise ValueError('Refusing to overwrite an existing IPA')
    apps = [p for p in payload.iterdir() if p.is_dir() and p.suffix == '.app']
    if payload.name != 'Payload' or len(apps) != 1:
        raise ValueError('Expected one application in the Payload directory')
    app = apps[0]
    primary = app / 'Info.plist'
    paths = sorted(payload.rglob('*'), key=lambda p: (0 if p == app else 1 if p == primary else 2,
                                                    len(p.parts), p.as_posix()))
    try:
        # A seekable, standard ZIP has complete local headers and no AppleDouble
        # resource forks. Put the primary plist before dependency bundle plists.
        with zipfile.ZipFile(output, 'x', compression=zipfile.ZIP_DEFLATED, compresslevel=9, allowZip64=False) as archive:
            archive.write(payload, 'Payload/')
            for path in paths:
                if any(p.startswith('._') or p in ('.DS_Store', '__MACOSX') for p in path.relative_to(payload).parts):
                    continue
                if path.is_symlink():
                    raise ValueError('Device application archive cannot contain symbolic links')
                archive.write(path, path.relative_to(payload.parent).as_posix())
        return validate_ipa(output, require_signature=require_signature)
    except Exception:
        output.unlink(missing_ok=True)
        raise


def mac_compatible_p12(material, work, openssl, temporary_password):
    """Re-encode a P12 through anonymous pipes; never write a plaintext key."""
    password = (material/'password').read_bytes()
    pem = invoke([openssl,'pkcs12','-in',str(material/'identity.p12'),'-passin','stdin','-nodes'],data=password+bytes([10]),label='Private identity decode')
    key = re.search(b'-----BEGIN PRIVATE KEY-----.*?-----END PRIVATE KEY-----',pem,re.S)
    certificates = re.findall(b'-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----',pem,re.S)
    if key is None or not certificates: raise ValueError('Incomplete private identity')
    secret = work/'import-password';secret.write_text(temporary_password);secret.chmod(0o600)
    read_fd,write_fd = os.pipe()
    try:
        key_bytes = key.group(0)+bytes([10])
        if len(key_bytes)>8192:raise ValueError('Private key exceeds supported size')
        os.write(write_fd,key_bytes);os.close(write_fd);write_fd = None
        args = [openssl,'pkcs12','-export','-in','/dev/stdin','-inkey','/dev/fd/'+str(read_fd),'-passout','file:'+str(secret),'-keypbe','PBE-SHA1-3DES','-certpbe','PBE-SHA1-3DES','-macalg','sha1']
        result = subprocess.run(args,input=bytes([10]).join(certificates)+bytes([10]),pass_fds=(read_fd,),capture_output=True)
        if result.returncode:raise RuntimeError('Compatible identity encoding failed')
        output = work/'compatible.p12';output.write_bytes(result.stdout);output.chmod(0o600)
        return output
    finally:
        os.close(read_fd)
        if write_fd is not None:os.close(write_fd)

def issuer_download_url(aia):
    url = urllib.parse.urlsplit(aia)
    if url.hostname != 'certs.apple.com' or url.username or url.password:
        raise ValueError('Unexpected certificate issuer URL')
    generation = re.fullmatch(r'/wwdrg([2-6])[.]der',url.path,re.I)
    if generation:
        return 'https://www.apple.com/certificateauthority/AppleWWDRCAG'+generation.group(1)+'.cer'
    return urllib.parse.urlunsplit(('https',url.netloc,url.path,url.query,''))


def export_unsigned(app, output, info, brand, exporter_revision):
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='zhuying-unsigned-ipa-') as temporary:
        payload = Path(temporary) / 'Payload'; payload.mkdir()
        shutil.copytree(app, payload / app.name, symlinks=True)
        validation = archive_payload(payload, output, require_signature=False)
    result = {**brand, 'schemaVersion': 1, 'kind': 'unsigned-device',
              'version': info['CFBundleShortVersionString'], 'build': info['CFBundleVersion'],
              'appSourceRevision': info['ZhuyingSourceRevision'], 'exporterRevision': exporter_revision,
              'bundleIdentifier': info['CFBundleIdentifier'], 'codeSigned': False,
              'provisioningProfileIncluded': False, 'archiveValidation': validation,
              'artifact': output.name, 'bytes': output.stat().st_size,
              'sha256': hashlib.sha256(output.read_bytes()).hexdigest()}
    output.with_suffix('.json').write_text(json.dumps(result, indent=2, ensure_ascii=False) + '\n')
    print(output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app',type=Path,required=True)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--material',type=Path,
                        help='Private directory containing identity.p12, profile.mobileprovision and password')
    mode.add_argument('--unsigned', action='store_true', help='Package an unsigned iPhoneOS build without signing material')
    parser.add_argument('--output',type=Path,required=True)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    if invoke(['git','-C',str(repo),'status','--porcelain'],label='Repository status').strip():
        raise ValueError('Commit source and tests before export')
    exporter_revision = invoke(['git','-C',str(repo),'rev-parse','HEAD'],label='Exporter revision').decode().strip()
    original_info = plistlib.loads((args.app/'Info.plist').read_bytes())
    brand = application_brand(original_info)
    if original_info.get('CFBundleSupportedPlatforms') != ['iPhoneOS']:
        raise ValueError('IPA export requires an iPhoneOS build, never a Simulator App')
    if not re.fullmatch('[a-f0-9]{40}',original_info.get('ZhuyingSourceRevision','')):
        raise ValueError('Device App source revision is missing')
    if args.unsigned:
        export_unsigned(args.app, args.output, original_info, brand, exporter_revision)
        return
    password = (args.material/'password').read_bytes()
    keychain_password = secrets.token_hex(32)
    with tempfile.TemporaryDirectory(prefix='zhuying-ipa-') as temporary:
        work = Path(temporary);work.chmod(0o700)
        openssl = shutil.which('openssl')
        profile_path = args.material/'profile.mobileprovision'
        decoded = invoke([openssl,'cms','-verify','-inform','DER','-in',str(profile_path),'-noverify'],label='Profile CMS signature')
        profile = plistlib.loads(decoded)
        cert_args = [openssl,'pkcs12','-in',str(args.material/'identity.p12'),'-passin','stdin','-clcerts','-nokeys']
        pem = invoke(cert_args,data=password+b'\n',label='P12 unlock')
        certificate = invoke([openssl,'x509','-outform','DER'],data=pem,label='Certificate decode')
        cert_dates = invoke([openssl,'x509','-noout','-dates'],data=pem,label='Certificate validity').decode()
        dates = dict(line.split('=',1) for line in cert_dates.splitlines())
        parse = lambda value: dt.datetime.strptime(value,'%b %d %H:%M:%S %Y %Z').replace(tzinfo=dt.timezone.utc)
        now = dt.datetime.now(dt.timezone.utc)
        if not parse(dates['notBefore']) <= now < parse(dates['notAfter']):
            raise ValueError('Signing certificate is expired or not yet valid')
        bundle_id = choose_identifier(original_info['CFBundleIdentifier'],profile)
        entitlement = entitlements(profile,bundle_id,certificate,now)
        payload = work/'Payload';payload.mkdir()
        app = payload/args.app.name;shutil.copytree(args.app,app,symlinks=True)
        if list(app.rglob('*.appex')) or list(app.rglob('*.app')):
            raise ValueError('Nested applications/extensions require their own provisioning profiles')
        info = dict(original_info);info['CFBundleIdentifier'] = bundle_id
        (app/'Info.plist').write_bytes(device_info_bytes(info))
        shutil.copy2(profile_path,app/'embedded.mobileprovision')
        entitlement_file = work/'entitlements.plist';entitlement_file.write_bytes(plistlib.dumps(entitlement))
        keychain = work/'signing.keychain-db'
        try:
            invoke(['security','create-keychain','-p',keychain_password,str(keychain)],label='Temporary keychain creation')
            # Trust evaluation searches the user list for intermediate certificates.
            # The temporary keychain is removed again in finally; the default is unchanged.
            listed = shlex.split(invoke(['security','list-keychains','-d','user'],label='Keychain search list').decode())
            if str(keychain) not in listed:
                invoke(['security','list-keychains','-d','user','-s',*listed,str(keychain)],label='Temporary signing search path')
            invoke(['security','unlock-keychain','-p',keychain_password,str(keychain)],label='Temporary keychain unlock')
            compatible = mac_compatible_p12(args.material,work,openssl,keychain_password)
            invoke(['security','import',str(compatible),'-k',str(keychain),'-P',keychain_password,'-T','/usr/bin/codesign'],label='P12 keychain import')
            fingerprint = hashlib.sha1(certificate).hexdigest().upper()
            trusted = invoke(['security','find-identity','-v','-p','codesigning',str(keychain)],label='Initial signing trust').decode()
            # Import an issuer only when the local trusted chain is unavailable.
            detail = invoke([openssl,'x509','-noout','-text'],data=pem,label='Certificate issuer metadata').decode()
            match = re.search(r'CA Issuers - URI:(https?://[^\s]+)',detail)
            if match and fingerprint not in trusted:
                url = issuer_download_url(match.group(1))
                with urllib.request.urlopen(url,timeout=20) as response:
                    issuer = response.read(128 * 1024 + 1)
                if len(issuer) > 128 * 1024:
                    raise ValueError('Issuer certificate is oversized')
                issuer_file = work/'issuer.cer';issuer_file.write_bytes(issuer)
                invoke(['security','import',str(issuer_file),'-k',str(keychain)],label='Apple issuer import')
            invoke(['security','set-key-partition-list','-S','apple-tool:,apple:,codesign:','-s','-k',keychain_password,str(keychain)],label='Signing key access')
            fingerprint = hashlib.sha1(certificate).hexdigest().upper()
            identities = invoke(['security','find-identity','-v','-p','codesigning',str(keychain)],label='Signing trust validation').decode()
            if fingerprint not in identities:
                raise ValueError('No trusted valid signing identity was found')
            nested = sorted([*app.rglob('*.framework'),*app.rglob('*.dylib')],key=lambda p:len(p.parts),reverse=True)
            for target in nested:
                invoke(['codesign','--force','--sign',fingerprint,'--keychain',str(keychain),'--timestamp=none',str(target)],label='Nested code signing')
            invoke(['codesign','--force','--sign',fingerprint,'--keychain',str(keychain),'--timestamp=none','--entitlements',str(entitlement_file),'--generate-entitlement-der',str(app)],label='Application signing')
            invoke(['codesign','--verify','--deep','--strict',str(app)],label='Application signature verification')
            signed = signed_entitlements(app)
            if signed != entitlement:
                raise ValueError('Signed entitlements do not match the verified profile')
            args.output.parent.mkdir(parents=True,exist_ok=True)
            archive_validation = archive_payload(payload,args.output)
            try:
                extracted = work/'ArchiveVerification'
                invoke(['/usr/bin/ditto','-x','-k',str(args.output),str(extracted)],label='IPA extraction verification')
                extracted_app = extracted/'Payload'/app.name
                invoke(['codesign','--verify','--deep','--strict',str(extracted_app)],label='Extracted IPA signature verification')
                if (plistlib.loads((extracted_app/'Info.plist').read_bytes()) != info
                        or signed_entitlements(extracted_app) != entitlement):
                    raise ValueError('Extracted IPA metadata or entitlements changed')
            except Exception:
                args.output.unlink(missing_ok=True)
                raise
            result = {**brand,'schemaVersion':1,'kind':'adhoc-device','version':info['CFBundleShortVersionString'],
                      'build':info['CFBundleVersion'],'appSourceRevision':info['ZhuyingSourceRevision'],
                      'exporterRevision':exporter_revision,'originalBundleIdentifier':original_info['CFBundleIdentifier'],
                      'bundleIdentifier':bundle_id,'signatureVerified':True,'profileCMSVerified':True,
                      'archiveValidation':archive_validation,'extractedSignatureVerified':True,
                      'certificateExpires':parse(dates['notAfter']).isoformat(),
                      'profileExpires':profile['ExpirationDate'].isoformat(),'registeredDeviceCount':len(profile.get('ProvisionedDevices',[])),
                      'iCloudEnabled':False,'releaseGate':'not-approved','uploaded':False,
                      'artifact':args.output.name,'bytes':args.output.stat().st_size,
                      'sha256':hashlib.sha256(args.output.read_bytes()).hexdigest()}
            args.output.with_suffix('.json').write_text(json.dumps(result,indent=2)+'\n')
            print(args.output)
        finally:
            subprocess.run(['security','delete-keychain',str(keychain)],capture_output=True)


if __name__ == '__main__':
    main()

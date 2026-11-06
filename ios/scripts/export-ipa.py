#!/usr/bin/env python3
"""Export a device App using local P12/profile/password files; never publish keys."""
import argparse
import datetime as dt
import fnmatch
import hashlib
import json
from pathlib import Path
import plistlib
import re
import secrets
import shlex
import shutil
import subprocess
import tempfile
import urllib.parse
import urllib.request
import zipfile


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


def archive_payload(payload, output):
    if output.exists():
        raise ValueError('Refusing to overwrite an existing IPA')
    invoke(['/usr/bin/ditto','-c','-k','--keepParent',str(payload),str(output)],label='IPA archive')
    with zipfile.ZipFile(output) as archive:
        if archive.testzip() is not None:
            raise ValueError('IPA archive CRC check failed')
        names = archive.namelist()
        if not any(n.startswith('Payload/') and n.endswith('.app/Info.plist') for n in names):
            raise ValueError('IPA must contain Payload/App.app')


def mac_compatible_p12(material, work, openssl, temporary_password):
    """Normalize legacy P12 MAC/PBE compatibility without a plaintext key file."""
    password = (material/'password').read_bytes()
    private_pem = invoke([openssl,'pkcs12','-in',str(material/'identity.p12'),'-passin','stdin','-nodes'],data=password+b'\n',label='Private identity decode')
    secret_file = work/'import-password';secret_file.write_text(temporary_password);secret_file.chmod(0o600)
    encoded = invoke([openssl,'pkcs12','-export','-in','/dev/stdin','-passout','file:'+str(secret_file),'-keypbe','PBE-SHA1-3DES','-certpbe','PBE-SHA1-3DES','-macalg','sha1'],data=private_pem,label='Compatible identity encoding')
    output = work/'compatible.p12';output.write_bytes(encoded);output.chmod(0o600)
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app',type=Path,required=True)
    parser.add_argument('--material',type=Path,required=True,
                        help='Private directory containing identity.p12, profile.mobileprovision and password')
    parser.add_argument('--output',type=Path,required=True)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    if invoke(['git','-C',str(repo),'status','--porcelain'],label='Repository status').strip():
        raise ValueError('Commit source and tests before export')
    exporter_revision = invoke(['git','-C',str(repo),'rev-parse','HEAD'],label='Exporter revision').decode().strip()
    original_info = plistlib.loads((args.app/'Info.plist').read_bytes())
    if original_info.get('CFBundleSupportedPlatforms') != ['iPhoneOS']:
        raise ValueError('IPA export requires an iPhoneOS build, never a Simulator App')
    if not re.fullmatch('[a-f0-9]{40}',original_info.get('YueshanSourceRevision','')):
        raise ValueError('Device App source revision is missing')
    password = (args.material/'password').read_bytes()
    keychain_password = secrets.token_hex(32)
    with tempfile.TemporaryDirectory(prefix='yueshan-ipa-') as temporary:
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
        (app/'Info.plist').write_bytes(plistlib.dumps(info))
        shutil.copy2(profile_path,app/'embedded.mobileprovision')
        entitlement_file = work/'entitlements.plist';entitlement_file.write_bytes(plistlib.dumps(entitlement))
        keychain = work/'signing.keychain-db'
        try:
            invoke(['security','create-keychain','-p',keychain_password,str(keychain)],label='Temporary keychain creation')
            # Use this keychain explicitly; preserve other search-list changes.
            listed = shlex.split(invoke(['security','list-keychains','-d','user'],label='Keychain search list').decode())
            filtered = [p for p in listed if Path(p) != keychain]
            if filtered != listed:
                invoke(['security','list-keychains','-d','user','-s',*filtered],label='Keep signing keychain isolated')
            invoke(['security','unlock-keychain','-p',keychain_password,str(keychain)],label='Temporary keychain unlock')
            compatible = mac_compatible_p12(args.material,work,openssl,keychain_password)
            invoke(['security','import',str(compatible),'-k',str(keychain),'-P',keychain_password,'-T','/usr/bin/codesign'],label='P12 keychain import')
            # Import the official issuing certificate only into the temporary keychain.
            detail = invoke([openssl,'x509','-noout','-text'],data=pem,label='Certificate issuer metadata').decode()
            match = re.search(r'CA Issuers - URI:(https?://[^\s]+)',detail)
            if match:
                url = urllib.parse.urlsplit(match.group(1))
                if url.hostname != 'certs.apple.com' or url.username or url.password:
                    raise ValueError('Unexpected certificate issuer URL')
                url = urllib.parse.urlunsplit(('https',url.netloc,url.path,url.query,''))
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
            signed = plistlib.loads(invoke(['codesign','--display','--entitlements','-',str(app)],label='Signed entitlements'))
            if signed != entitlement:
                raise ValueError('Signed entitlements do not match the verified profile')
            args.output.parent.mkdir(parents=True,exist_ok=True)
            archive_payload(payload,args.output)
            result = {'schemaVersion':1,'kind':'adhoc-device','version':info['CFBundleShortVersionString'],
                      'build':info['CFBundleVersion'],'appSourceRevision':info['YueshanSourceRevision'],
                      'exporterRevision':exporter_revision,'originalBundleIdentifier':original_info['CFBundleIdentifier'],
                      'bundleIdentifier':bundle_id,'signatureVerified':True,'profileCMSVerified':True,
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

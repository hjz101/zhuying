import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';

test('IPA export validates profile scope, expiry, certificate binding and actual Payload layout', () => {
  const code = String.raw`
import importlib.util,datetime as d,tempfile,pathlib,plistlib,zipfile
s=importlib.util.spec_from_file_location('ipa','ios/scripts/export-ipa.py');m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
now=d.datetime(2026,11,6,tzinfo=d.timezone.utc)
brand={'CFBundleDisplayName':'竹影','CFBundleName':'Zhuying','CFBundleExecutable':'Zhuying'}
assert m.application_brand(brand)['displayName']=='竹影'
for field in brand:
 broken=dict(brand);broken[field]='Yueshan'
 try:m.application_brand(broken)
 except ValueError:pass
 else:raise AssertionError('Old application branding was accepted for IPA export')
assert isinstance(m.signed_entitlements('/System/Applications/Calculator.app'),dict)
assert m.issuer_download_url('http://certs.apple.com/wwdrg3.der')=='https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer'
try:m.issuer_download_url('https://other.invalid/issuer')
except ValueError:pass
else:raise AssertionError('Unknown issuer host accepted')
p={'CreationDate':now-d.timedelta(days=1),'ExpirationDate':now+d.timedelta(days=30),'ApplicationIdentifierPrefix':['TESTTEAM'],'TeamIdentifier':['TESTTEAM'],'ProvisionedDevices':['synthetic-device'],'DeveloperCertificates':[b'original-cert'],'Entitlements':{'application-identifier':'TESTTEAM.app.original.test','keychain-access-groups':['TESTTEAM.*'],'get-task-allow':False}}
assert m.choose_identifier('com.reader.original',p)=='app.original.test'
e=m.entitlements(p,'app.original.test',b'original-cert',now);assert e['application-identifier']=='TESTTEAM.app.original.test' and e['get-task-allow'] is False
for cert,clock,identifier in [(b'wrong',now,'app.original.test'),(b'original-cert',now+d.timedelta(days=60),'app.original.test'),(b'original-cert',now,'com.wrong.app')]:
 try:m.entitlements(p,identifier,cert,clock)
 except ValueError:pass
 else:raise AssertionError('Invalid signing material accepted')
p['Entitlements']['application-identifier']='TESTTEAM.*';assert m.choose_identifier('com.reader.original',p)=='com.reader.original'
with tempfile.TemporaryDirectory() as tmp:
 root=pathlib.Path(tmp);payload=root/'Payload';app=payload/'Reader.app';app.mkdir(parents=True);(app/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'app.original.test'}));(app/'Reader').write_bytes(b'original executable')
 out=root/'reader.ipa';m.archive_payload(payload,out)
 with zipfile.ZipFile(out) as z:assert z.read('Payload/Reader.app/Reader')==b'original executable' and z.testzip() is None
 try:m.archive_payload(payload,out)
 except ValueError:pass
 else:raise AssertionError('Existing IPA overwritten')
`;
  assert.doesNotThrow(() => execFileSync('python3', ['-c', code], { stdio: 'pipe' }));
});

test('P12 compatibility conversion retains the certificate and leaves no plaintext private-key file', () => {
  const code = String.raw`
import importlib.util,tempfile,pathlib,subprocess,shutil
s=importlib.util.spec_from_file_location('ipa','ios/scripts/export-ipa.py');m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
def synthetic_invoke(args,**kw):
 r=subprocess.run(args,input=kw.get('data'),capture_output=True)
 if r.returncode:raise RuntimeError('synthetic: '+r.stderr.decode())
 return r.stdout
m.invoke=synthetic_invoke
openssl=shutil.which('openssl')
with tempfile.TemporaryDirectory() as tmp:
 root=pathlib.Path(tmp);source=root/'source';source.mkdir();work=root/'converted';work.mkdir()
 key=root/'synthetic.key';cert=root/'synthetic.crt'
 m.invoke([openssl,'req','-x509','-newkey','rsa:2048','-nodes','-keyout',str(key),'-out',str(cert),'-subj','/CN=Original Export Test','-days','1'])
 secret=source/'password';secret.write_text('synthetic-password')
 m.invoke([openssl,'pkcs12','-export','-inkey',str(key),'-in',str(cert),'-out',str(source/'identity.p12'),'-passout','file:'+str(secret)])
 converted=m.mac_compatible_p12(source,work,openssl,'temporary-synthetic-password')
 decoded=m.invoke([openssl,'pkcs12','-in',str(converted),'-passin','stdin','-clcerts','-nokeys'],data=b'temporary-synthetic-password\n')
 assert m.invoke([openssl,'x509','-outform','DER'],data=decoded)==m.invoke([openssl,'x509','-in',str(cert),'-outform','DER'])
 assert sorted(p.name for p in work.iterdir())==['compatible.p12','import-password']
 assert converted.stat().st_mode & 0o077==0
`;
  assert.doesNotThrow(() => execFileSync('python3', ['-c', code], { stdio: 'pipe' }));
});

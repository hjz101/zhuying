import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';

test('Unsigned IPA keeps device metadata and rejects residual profiles, signature resources and Mach-O signatures', () => {
  const code = String.raw`
import importlib.util, tempfile, pathlib, plistlib, zipfile, struct, json
s=importlib.util.spec_from_file_location('ipa','ios/scripts/export-ipa.py');m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
with tempfile.TemporaryDirectory() as tmp:
 root=pathlib.Path(tmp);app=root/'Zhuying.app';app.mkdir()
 info={'CFBundleIdentifier':'com.zhuying.reader.demo','CFBundleName':'Zhuying','CFBundleDisplayName':'竹影','CFBundleExecutable':'Zhuying','CFBundlePackageType':'APPL','CFBundleSupportedPlatforms':['iPhoneOS'],'CFBundleShortVersionString':'0.8.0','CFBundleVersion':'10','MinimumOSVersion':'17.0','ZhuyingSourceRevision':'a'*40}
 (app/'Info.plist').write_bytes(m.device_info_bytes(info))
 executable=struct.pack('<8I',0xfeedfacf,0x0100000c,0,2,0,0,0,0)
 (app/'Zhuying').write_bytes(executable);(app/'Zhuying').chmod(0o755)
 output=root/'竹影-unsigned.ipa'
 m.export_unsigned(app,output,info,m.application_brand(info),'b'*40)
 report=json.loads(output.with_suffix('.json').read_text())
 assert report['kind']=='unsigned-device' and report['codeSigned'] is False and report['provisioningProfileIncluded'] is False
 assert report['appSourceRevision']=='a'*40 and report['exporterRevision']=='b'*40
 assert report['archiveValidation']['signatureRequired'] is False
 assert m.validate_ipa(output,require_signature=False)['zipCRCVerified']
 try:m.validate_ipa(output)
 except ValueError:pass
 else:raise AssertionError('Unsigned archive reported as signed')
 with zipfile.ZipFile(output) as z:
  assert plistlib.loads(z.read('Payload/Zhuying.app/Info.plist'))==info
  assert not any('embedded.mobileprovision' in n or '_CodeSignature' in n for n in z.namelist())
 payload=root/'Payload';payload.mkdir();app.rename(payload/'Zhuying.app');app=payload/'Zhuying.app'
 def reject(name):
  target=root/(name+'.ipa')
  try:m.archive_payload(payload,target,require_signature=False)
  except ValueError:pass
  else:raise AssertionError('Residual signature or invalid bundle accepted: '+name)
  assert not target.exists()
 profile=app/'embedded.mobileprovision';profile.write_bytes(b'profile');reject('profile');profile.unlink()
 signature=app/'_CodeSignature';signature.mkdir();(signature/'CodeResources').write_bytes(b'signature');reject('resources');(signature/'CodeResources').unlink();signature.rmdir()
 (app/'Zhuying').write_bytes(struct.pack('<8I',0xfeedfacf,0x0100000c,0,2,1,16,0,0)+struct.pack('<4I',0x1d,16,48,0));reject('macho-signature')
 (app/'Zhuying').write_bytes(executable)
 simulator=dict(info);simulator['CFBundleSupportedPlatforms']=['iPhoneSimulator'];(app/'Info.plist').write_bytes(m.device_info_bytes(simulator));reject('simulator')
 (app/'Info.plist').unlink();reject('missing-plist')
`;
  assert.doesNotThrow(() => execFileSync('python3', ['-c', code], { stdio: 'pipe' }));
});

test('IPA export validates application branding, profile scope, expiry and certificate binding', () => {
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

`;
  assert.doesNotThrow(() => execFileSync('python3', ['-c', code], { stdio: 'pipe' }));
});

test('IPA packaging removes macOS metadata and validates the primary plist and complete ZIP headers', () => {
  const code = String.raw`
import importlib.util, tempfile, pathlib, plistlib, zipfile, struct, io, warnings
s=importlib.util.spec_from_file_location('ipa','ios/scripts/export-ipa.py');m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
with tempfile.TemporaryDirectory() as tmp:
 root=pathlib.Path(tmp);payload=root/'Payload';app=payload/'Reader.app';app.mkdir(parents=True)
 info={'CFBundleIdentifier':'app.original.test','CFBundleName':'Reader','CFBundleDisplayName':'竹影','CFBundleExecutable':'Reader','CFBundlePackageType':'APPL','CFBundleSupportedPlatforms':['iPhoneOS'],'CFBundleShortVersionString':'1.0','CFBundleVersion':'9','MinimumOSVersion':'17.0'}
 (app/'Info.plist').write_bytes(m.device_info_bytes(info))
 executable=struct.pack('<8I',0xfeedfacf,0x0100000c,0,2,0,0,0,0)
 (app/'Reader').write_bytes(executable);(app/'Reader').chmod(0o755)
 (app/'embedded.mobileprovision').write_bytes(b'synthetic provision')
 signature=app/'_CodeSignature';signature.mkdir();(signature/'CodeResources').write_bytes(b'synthetic signature')
 dependency=app/'Dependency.bundle';dependency.mkdir();(dependency/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'dependency.resources'}))
 (app/'._Info.plist').write_bytes(b'AppleDouble is not a property list')
 (app/'._Reader').write_bytes(b'AppleDouble')
 (app/'.DS_Store').write_bytes(b'Finder metadata')
 metadata=app/'__MACOSX';metadata.mkdir();(metadata/'._Info.plist').write_bytes(b'AppleDouble')
 output=root/'Reader.ipa';report=m.archive_payload(payload,output)
 assert report['primaryInfoPlist']=='Payload/Reader.app/Info.plist' and report['infoPlistFormat']=='binary'
 assert report['completeLocalHeaders'] and report['arm64Executable'] and report['macOSMetadataEntries']==0
 with zipfile.ZipFile(output) as z:
  names=z.namelist();primary='Payload/Reader.app/Info.plist'
  assert names.index(primary)<names.index('Payload/Reader.app/Dependency.bundle/Info.plist')
  assert z.read(primary).startswith(b'bplist00') and plistlib.loads(z.read(primary))==info
  assert z.read('Payload/Reader.app/Reader')==executable and z.testzip() is None
  assert not any('._' in n or '__MACOSX' in n or '.DS_Store' in n for n in names)
  assert all(not i.flag_bits & 8 for i in z.infolist())
  m.invoke(['plutil','-lint','-'],data=z.read(primary),label='Apple plist validation')
 try:m.archive_payload(payload,output)
 except ValueError:pass
 else:raise AssertionError('Existing IPA overwritten')
 def rejected(label,replacements=None,exclude=(),extra=()):
  target=root/(label+'.ipa')
  with zipfile.ZipFile(output) as source,zipfile.ZipFile(target,'w',compression=zipfile.ZIP_DEFLATED) as dest:
   for item in source.infolist():
    if item.filename not in exclude:dest.writestr(item,(replacements or {}).get(item.filename,source.read(item)))
   for name,data in extra:dest.writestr(name,data)
  try:m.validate_ipa(target)
  except ValueError:pass
  else:raise AssertionError('Accepted malformed IPA: '+label)
 rejected('corrupt-primary',{primary:b'not a plist'})
 rejected('malformed-xml-primary',{primary:b'<?xml version="1.0"?><plist><dict>'})
 rejected('nested-plist-is-not-primary',exclude=[primary])
 for name in ['Reader','embedded.mobileprovision','_CodeSignature/CodeResources']:
  rejected('missing-'+name.replace('/','-'),exclude=['Payload/Reader.app/'+name])
 rejected('wrong-architecture',{'Payload/Reader.app/Reader':struct.pack('<8I',0xfeedfacf,0x01000007,0,2,0,0,0,0)})
 incomplete=dict(info);incomplete.pop('CFBundleExecutable')
 rejected('missing-required-metadata',{primary:m.device_info_bytes(incomplete)})
 incomplete=dict(info);incomplete['CFBundleSupportedPlatforms']=['iPhoneSimulator']
 rejected('simulator-app',{primary:m.device_info_bytes(incomplete)})
 rejected('appledouble',extra=[('Payload/Reader.app/._Info.plist',b'AppleDouble')])
 with warnings.catch_warnings():
  warnings.simplefilter('ignore',UserWarning)
  rejected('duplicate-primary',extra=[(primary,m.device_info_bytes(info))])
 class Nonseekable(io.BytesIO):
  def seek(self,*args):raise io.UnsupportedOperation('non-seekable')
 stream=Nonseekable()
 with zipfile.ZipFile(output) as source,zipfile.ZipFile(stream,'w',compression=zipfile.ZIP_DEFLATED) as dest:
  for item in source.infolist():dest.writestr(item,source.read(item))
 target=root/'descriptor.ipa';target.write_bytes(stream.getvalue())
 try:m.validate_ipa(target)
 except ValueError:pass
 else:raise AssertionError('ZIP with incomplete local headers accepted')
 (app/'Info.plist').unlink()
 try:m.archive_payload(payload,root/'invalid.ipa')
 except ValueError:pass
 else:raise AssertionError('Incomplete bundle accepted')
 assert not (root/'invalid.ipa').exists()
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

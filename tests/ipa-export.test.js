import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';

test('IPA export validates profile scope, expiry, certificate binding and actual Payload layout', () => {
  const code = `
import importlib.util,datetime as d,tempfile,pathlib,plistlib,zipfile
s=importlib.util.spec_from_file_location('ipa','ios/scripts/export-ipa.py');m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
now=d.datetime(2026,11,6,tzinfo=d.timezone.utc)
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

import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';

const setup = String.raw`
import importlib.util, json, os, pathlib, plistlib, struct, subprocess, tempfile, zipfile, stat
script=pathlib.Path('ios/scripts/verify-source-free-package.py').resolve()
spec=importlib.util.spec_from_file_location('source_free',script)
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
def fixture(root,policy=False):
 app=root/'Zhuying.app';app.mkdir()
 info={'CFBundleIdentifier':'com.zhuying.reader.demo','CFBundleExecutable':'Zhuying','CFBundleShortVersionString':'0.8.0','CFBundleVersion':'15','ZhuyingSourceRevision':'a'*40}
 if policy is not None:info['ZhuyingBundledSources']=policy
 (app/'Info.plist').write_bytes(plistlib.dumps(info))
 (app/'Zhuying').write_bytes(struct.pack('<8I',0xfeedfacf,0x0100000c,0,2,0,0,0,0))
 return app
def cli(*args):
 result=subprocess.run(['python3',str(script),*map(str,args)],capture_output=True,text=True)
 return result.returncode,json.loads(result.stdout)
def pack(app,target,extra=None):
 with zipfile.ZipFile(target,'w') as z:
  for p in app.rglob('*'):
   if p.is_file():z.write(p,'Payload/Zhuying.app/'+p.relative_to(app).as_posix())
  if extra:
   for name,data in extra:z.writestr(name,data)
 return target
`;

function run(code) {
  assert.doesNotThrow(() => execFileSync('python3', ['-c', setup + code], { stdio: 'pipe' }));
}

test('source-free App and IPA CLI preserve inputs and return the same fixed report', () => run(String.raw`
with tempfile.TemporaryDirectory() as tmp:
 root=pathlib.Path(tmp);app=fixture(root)
 before={p.relative_to(app).as_posix():p.read_bytes() for p in app.rglob('*') if p.is_file()}
 target=pack(app,root/'竹影.ipa');original=target.read_bytes()
 status,report=cli('--app',app,'--output',root/'app-report.json')
 assert status==0 and report['passed'] is True and report['inputKind']=='app'
 assert report==json.loads((root/'app-report.json').read_text())
 assert report['bundle']['build']=='15' and report['policy']['declaredValue'] is False
 assert report['executable']['bytesScanned']==32 and not report['violations']
 status,ipa_report=cli('--ipa',target)
 assert status==0 and ipa_report['passed'] is True and ipa_report['inputKind']=='ipa'
 assert set(report)==set(ipa_report) and report['bundle']==ipa_report['bundle']
 assert before=={p.relative_to(app).as_posix():p.read_bytes() for p in app.rglob('*') if p.is_file()}
 assert target.read_bytes()==original
 for args in [('--app',app,'--output',app/'report.json'),('--ipa',target,'--output',target),('--app',app,'--ipa',target)]:
  assert subprocess.run(['python3',str(script),*map(str,args)],capture_output=True).returncode==2
 assert target.read_bytes()==original and not (app/'report.json').exists()
 linked=root/'hardlinked-report.json';os.link(target,linked)
 status,report=cli('--ipa',target,'--output',linked)
 assert status==0 and target.read_bytes()==original and json.loads(linked.read_text())==report
`));

test('concrete source resources are rejected recursively without printing their values', () => run(String.raw`
fixtures=[{'bookSourceName':'private-name','bookSourceUrl':'https://private.invalid'},
 {'wrapper':[{'bookSourceUrl':'opaque-origin','ruleSearch':{'bookList':'$.books'}}]},
 {'bookSourceUrl':'origin','ruleContent':'$.text'},
 {'bookSourceUrl':'origin','jsLib':'private-script'},
 {'outer':{'sources':[{'name':'private-name','url':'https://private.invalid','configuration':{}}]}}]
for value in fixtures:
 with tempfile.TemporaryDirectory() as tmp:
  root=pathlib.Path(tmp);app=fixture(root);resources=app/'Resources'/'Nested';resources.mkdir(parents=True)
  (resources/'unrelated-name.JSON').write_text(json.dumps(value))
  status,report=cli('--app',app)
  assert status==1 and report['resources']['sourceDefinitionsFound']==1
  assert report['violations']==[{'code':'bundled-source-definition','path':'Resources/Nested/unrelated-name.JSON'}]
  assert 'private-name' not in json.dumps(report) and 'private.invalid' not in json.dumps(report) and 'private-script' not in json.dumps(report)
  status,report=cli('--ipa',pack(app,root/'竹影.ipa'))
  assert status==1 and report['resources']['sourceDefinitionsFound']==1
`));

test('generic source schemas, parser vocabulary and local demo books remain allowed', () => run(String.raw`
with tempfile.TemporaryDirectory() as tmp:
 root=pathlib.Path(tmp);app=fixture(root)
 schema={'type':'object','properties':{'bookSourceUrl':{'type':'string'},'bookSourceName':{'type':'string'},'jsLib':{'type':'string'},'ruleSearch':{'type':'object'},'sources':{'type':'array','items':{'properties':{'name':{'type':'string'},'url':{'type':'string'}}}}}}
 (app/'source.schema.json').write_text(json.dumps(schema))
 (app/'library.json').write_text(json.dumps([{'id':'local','title':'原创本地书','chapters':['第一章'],'content':[['原创正文']]}]))
 (app/'empty.json').write_text(json.dumps({'sources':[]}))
 with (app/'Zhuying').open('ab') as f:f.write(b'bookSourceUrl\0bookSourceName\0jsLib\0ruleSearch\0ruleContent\0qingtian\0adapter\0QuickJSScriptRuntime')
 for args in [('--app',app),('--ipa',pack(app,root/'竹影.ipa'))]:
  status,report=cli(*args)
  assert status==0 and report['resources']=={'jsonFilesScanned':3,'sourceDefinitionsFound':0}
`));

test('binary preset markers are rejected in UTF-8, UTF-16 and across scan chunks', () => run(String.raw`
for marker,encoding in [('v1.vossc.com','utf-8'),('书山聚合','utf-16-le'),('云间小说','utf-16-be'),('sources.example','utf-8')]:
 with tempfile.TemporaryDirectory() as tmp:
  root=pathlib.Path(tmp);app=fixture(root)
  with (app/'Zhuying').open('ab') as f:
   f.write(b'\0'*(1024*1024-32-3));f.write(marker.encode(encoding))
  for args in [('--app',app),('--ipa',pack(app,root/'竹影.ipa'))]:
   status,report=cli(*args)
   assert status==1 and report['executable']['presetMarkersFound']==[marker]
   assert report['violations']==[{'code':'preset-marker-in-executable','path':'Zhuying'}]
`));

test('missing, true and non-boolean policies fail closed; executable and JSON must be inspectable', () => run(String.raw`
for policy in [None,True,0,'false']:
 with tempfile.TemporaryDirectory() as tmp:
  root=pathlib.Path(tmp);app=fixture(root,policy)
  status,report=cli('--app',app)
  assert status==1 and report['violations'][0]['code']=='bundled-sources-policy-must-be-false'
with tempfile.TemporaryDirectory() as tmp:
 root=pathlib.Path(tmp);app=fixture(root)
 (app/'broken.json').write_bytes(b'{not-json')
 assert m.verify(app=app)['violations'][0]['code']=='unreadable-json-resource'
 (app/'broken.json').unlink();(app/'Zhuying').write_bytes(b'not-mach-o')
 assert m.verify(app=app)['violations'][0]['code']=='invalid-mach-o-executable'
 (app/'Info.plist').write_bytes(b'<?xml version="1.0"?><plist><dict>')
 status,report=cli('--app',app)
 assert status==1 and report['violations'][0]['code']=='invalid-info-plist'
`));

test('unsafe and ambiguous ZIP members and App symlinks are rejected without extracting', () => run(String.raw`
with tempfile.TemporaryDirectory() as tmp:
 root=pathlib.Path(tmp);app=fixture(root)
 for index,name in enumerate(['../escape','/absolute','C:/absolute','Payload/Zhuying.app/../../escape','Payload\\Zhuying.app\\escape','Payload//Zhuying.app/escape']):
  status,report=cli('--ipa',pack(app,root/('bad'+str(index)+'.ipa'),[(name,b'unsafe')]))
  assert status==1 and report['violations'][0]['code']=='unsafe-zip-member'
 assert not (root/'escape').exists()
 link=zipfile.ZipInfo('Payload/Zhuying.app/linked.json');link.create_system=3;link.external_attr=(stat.S_IFLNK|0o777)<<16
 status,report=cli('--ipa',pack(app,root/'symlink.ipa',[(link,b'../../outside')]))
 assert status==1 and report['violations'][0]['code']=='unsafe-zip-member'
 status,report=cli('--ipa',pack(app,root/'duplicate.ipa',[('Payload/Zhuying.app/Info.plist',b'duplicate')]))
 assert status==1 and report['violations'][0]['code']=='duplicate-zip-member'
 (app/'outside.json').symlink_to(root/'no-such-file')
 assert m.verify(app=app)['violations'][0]['code']=='symlink-in-app-bundle'
`));

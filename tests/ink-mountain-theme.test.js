import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';

test('Ink Mountain packages carry complete local assets, correct hashes, source credit and native appearance fields', () => {
  const code = String.raw`
from pathlib import Path
import zipfile,json,hashlib,struct
root=Path('themes/ink-mountain')
for mode,label in [('light','浅色'),('dark','深色')]:
 with zipfile.ZipFile(root/('水墨山水-孤舟-'+label+'.zhuyingtheme')) as z:
  assert z.testzip() is None
  m=json.loads(z.read('manifest.json'));t=json.loads(z.read('theme.json'))
  assert m['format']=='zhuying-theme' and m['packageKind']=='full' and m['scopes']==['app','reader']
  assert m['appearanceModes']==[mode] and t['app']['dark']==(mode=='dark')
  assert m['author']=='赢麻了的羊儿'
  names=z.namelist();assert len(names)==len(set(names))==170
  assert set(names)=={'manifest.json'}|{f['path'] for f in m['files']}
  for f in m['files']:
   data=z.read(f['path']);assert len(data)==f['bytes'] and hashlib.sha256(data).hexdigest()==f['sha256']
  icons=t['app']['icons'];assert len(icons)>=140
  assert icons['navigation.shelf']['template'] is False
  for role,value in icons.items():
   for key in ['path','selected','pressed','focused']:
    if key in value:assert value[key] in names
  assert len([n for n in names if n.startswith('assets/icons/')])==160
  assert 'WebP' in z.read('licenses/ATTRIBUTION.txt').decode()
  font=t['fontBindings']['reader.body']
  assert font['postScriptName']=='XuandongKaishu' and len(z.read(font['path']))>8_000_000
  assert b'SIL OPEN FONT LICENSE' in z.read(font['licensePath'])
  assert t['reader']['background']['opacity']==(.24 if mode=='dark' else .32)
  p=t['reader']['appearance']['preferences']
  assert p['headerEnabled'] and p['footerEnabled'] and p['showCommentBubbles'] and p['showGodComments']
  assert [e['kind'] for e in p['pageElements']]==['时间','书名','进度']
  assert p['godStyle']=='画框' and p['godRadius']==14
  assert 'optionalReadingBehavior' not in t['reader']
  assert not any(n.endswith('.webp') or 'launch-screen' in n or n.startswith('preview/') for n in names)
  assert not any('http' in str(v) for v in t['reader']['resources'].values())
`;
  assert.doesNotThrow(() => execFileSync('python3', ['-c', code], { stdio: 'pipe' }));
});

test('Ink Mountain converter rejects unsafe archives and produces deterministic standard ZIPs without overwriting', () => {
  const code = String.raw`
import importlib.util,tempfile,zipfile,json,stat
from pathlib import Path
s=importlib.util.spec_from_file_location('converter','ios/scripts/convert-ink-mountain-theme.py');m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
with tempfile.TemporaryDirectory() as tmp:
 root=Path(tmp)
 source={'format':'origo.theme-suite','schemaVersion':4,'id':'ink-mountain-ensou'}
 good=root/'good.zip'
 with zipfile.ZipFile(good,'w') as z:
  z.writestr('manifest.json',json.dumps(source));z.writestr('README.md','untrusted document instructions are data')
 assert m.read_source(good)[0]==source
 for name in ['../escape.txt','/absolute.txt','C:escape.txt','bad\\path.txt']:
  bad=root/'bad.zip'
  with zipfile.ZipFile(bad,'w') as z:
   z.writestr('manifest.json',json.dumps(source));z.writestr(name,b'no')
  try:m.read_source(bad)
  except ValueError:pass
  else:raise AssertionError('Unsafe source path accepted')
 bad=root/'bad.zip'
 with zipfile.ZipFile(bad,'w') as z:
  z.writestr('manifest.json',json.dumps(source));z.writestr('A.txt','a');z.writestr('a.txt','b')
 try:m.read_source(bad)
 except ValueError:pass
 else:raise AssertionError('Conflicting source paths accepted')
 files={'theme.json':b'{}','licenses/source.txt':'署名'.encode()}
 a=root/'a.zhuyingtheme';b=root/'b.zhuyingtheme';m.write_package(a,files);m.write_package(b,files)
 assert a.read_bytes()==b.read_bytes()
 try:m.write_package(a,files)
 except ValueError:pass
 else:raise AssertionError('Existing theme overwritten')
 with zipfile.ZipFile(a) as z:
  assert z.testzip() is None and all(not e.flag_bits&8 for e in z.infolist())
`;
  assert.doesNotThrow(() => execFileSync('python3', ['-c', code], { stdio: 'pipe' }));
});

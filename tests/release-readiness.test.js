import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';

test('release audit rejects missing real acceptance, stale sources, unsigned packages and altered performance results', () => {
  const script = `
import importlib.util, json, hashlib, copy, pathlib
spec=importlib.util.spec_from_file_location('readiness','ios/scripts/release-readiness.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
raw=pathlib.Path('ios/YueshanTestSupport/performance-budget.json').read_bytes();budget=json.loads(raw);digest=hashlib.sha256(raw).hexdigest()
metrics=[]
for key,limit in budget['limits'].items():
 count=budget['storageSamples'] if key.startswith('library.') else budget['samples']
 if key=='shelf.sort.ms':count*=3
 if key=='process.peak-rss.mib':count=1
 metrics.append({'id':key,'samples':[1.0]*count,'maximum':1.0,'limit':limit,'withinTarget':True,'profile':budget['profile']})
launch=next(x for x in metrics if x['id']=='app.empty-launch.ms')
perf={'budgetSHA256':digest,'profile':budget['profile'],'scales':budget['scales'],'measurements':[x for x in metrics if x is not launch]}
books=[{'id':str(i),'title':'Original '+str(i),'searched':True,'detailsShown':True,'catalogShown':True,'restartResumed':True,'chapters':[{'id':str(j),'order':j,'utf16Count':300,'contentHash':hashlib.sha256(f'{i}/{j}'.encode()).hexdigest()} for j in range(3)]} for i in range(2)]
e={'sourceDigest':'current','functional':{'status':'passed','failedTests':0,'unitTests':10,'uiFlows':10},'liveApp':{'status':'passed','sampleKind':'live-app','books':books},'deviceMatrix':{'status':'passed','sampleKind':'physical-device','cases':[{'id':case,'status':'passed'} for case in m.PHYSICAL_CASES]},'signedInternalTest':{'status':'passed','installed':True,'upgradedWithData':True,'feedbackReviewed':True,'openBlockingIssues':0}}
candidate={'kind':'development-device','platforms':['iPhoneOS'],'signatureVerified':True}
def check(e=e,p=perf,l=launch,b=budget,d=digest,c=candidate,a=True):return m.evaluate(e,p,l,b,d,'current',{'unitTests':10,'uiFlows':10},c,a)
assert check()['readyForReleaseCandidate'] is True
def blocked(result,task):assert next(x for x in result['checks'] if x['task']==task)['status']=='blocked'
for field,task in [('liveApp','T030'),('deviceMatrix','T036'),('signedInternalTest','T037')]:
 broken=copy.deepcopy(e);broken[field]={};blocked(check(e=broken),task)
stale=copy.deepcopy(e);stale['sourceDigest']='old';assert check(e=stale)['readyForReleaseCandidate'] is False
sim=copy.deepcopy(e);sim['deviceMatrix']['sampleKind']='simulator';blocked(check(e=sim),'T036')
fixture=copy.deepcopy(e);fixture['liveApp']['sampleKind']='fixture';blocked(check(e=fixture),'T030')
gap=copy.deepcopy(e);gap['liveApp']['books'][0]['chapters'][1]['order']=40;blocked(check(e=gap),'T030')
duplicate=copy.deepcopy(e);duplicate['liveApp']['books'][1]['chapters']=copy.deepcopy(duplicate['liveApp']['books'][0]['chapters']);blocked(check(e=duplicate),'T030')
blocked(check(c={'kind':'unsigned-device','platforms':['iPhoneOS']}),'T037');blocked(check(a=False),'T038')
broken=copy.deepcopy(perf);broken['measurements'][0]['samples'][0]=999999;blocked(check(p=broken),'T035')
broken=copy.deepcopy(perf);broken['measurements'][0]['samples'][0]=float('nan');blocked(check(p=broken),'T035')
broken=copy.deepcopy(perf);broken['measurements'].pop();blocked(check(p=broken),'T035')
broken=copy.deepcopy(perf);broken['measurements'].append(broken['measurements'][0]);blocked(check(p=broken),'T035')
assert check(d='changed-budget')['readyForReleaseCandidate'] is False
assert check()['signsOrUploads'] is False
`;
  assert.doesNotThrow(() => execFileSync('python3', ['-c', script], { stdio: 'pipe' }));
});

test('release evidence digest changes with application and test edits', () => {
  const script = `
import importlib.util,pathlib,tempfile
spec=importlib.util.spec_from_file_location('readiness','ios/scripts/release-readiness.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
with tempfile.TemporaryDirectory() as root:
 p=pathlib.Path(root);(p/'ios/Yueshan').mkdir(parents=True);(p/'ios/YueshanTests').mkdir();(p/'ios/project.yml').write_text('name: example')
 app=p/'ios/Yueshan/App.swift';app.write_text('struct App {}');before=m.source_digest(p);assert m.source_digest(p)==before
 app.write_text('struct Changed {}');after=m.source_digest(p);assert after!=before
 test=p/'ios/YueshanTests/Test.swift';test.write_text('func testOne() {}');assert m.source_digest(p)!=after;assert m.inventory(p)['unitTests']==1
 before=m.source_digest(p);epub=p/'ios/YueshanTests/original.epub';epub.write_bytes(b'original EPUB fixture');assert m.source_digest(p)!=before
`;
  assert.doesNotThrow(() => execFileSync('python3', ['-c', script], { stdio: 'pipe' }));
});

test('recorded follow-up preserves the passing launch and unresolved memory and physical gates', () => {
  const script = `
import importlib.util,pathlib,json,hashlib
spec=importlib.util.spec_from_file_location('readiness','ios/scripts/release-readiness.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
root=pathlib.Path('.');base=root/'docs/verification/2026-11-06/stage-four-follow-up'
e=json.loads((base/'evidence.json').read_text());p=json.loads((base/e['performanceReport']).read_text());l=json.loads((base/e['launchReport']).read_text())
raw=(root/'ios/YueshanTestSupport/performance-budget.json').read_bytes()
assert len(e['sourceDigest'])==64
assert l['withinTarget'] is True and max(l['samples'])<=3000
assert next(x for x in p['measurements'] if x['id']=='process.peak-rss.mib')['withinTarget'] is False
assert len(p['memoryPhases'])==7 and all(x['memory']['physicalFootprintMiB']>0 for x in p['memoryPhases'])
n=json.loads((base/'native-app.json').read_text());assert n['contentPreserved'] is True and len(n['memoryPhases'])==4
assert n['utf16Units']>=100000 and 'does not replace frozen XCTest criteria' in n['method']
result=m.evaluate(e,p,l,json.loads(raw),hashlib.sha256(raw).hexdigest(),e['sourceDigest'],{'unitTests':e['functional']['unitTests'],'uiFlows':e['functional']['uiFlows']})
assert result['readyForReleaseCandidate'] is False
assert all(x['status']=='blocked' for x in result['checks'])
reasons=next(x['reasons'] for x in result['checks'] if x['task']=='T035')
assert len(reasons)==2 and any('process.peak-rss.mib' in x for x in reasons) and any('T030' in x for x in reasons)
assert e['deviceMatrix']['sampleKind']=='physical-device' and e['deviceMatrix']['status']=='not-run'
assert len(e['simulatorMatrix']['cases'])==6 and all(x['status']=='passed' for x in e['simulatorMatrix']['cases'])
`;
  assert.doesNotThrow(() => execFileSync('python3', ['-c', script], { stdio: 'pipe' }));
});

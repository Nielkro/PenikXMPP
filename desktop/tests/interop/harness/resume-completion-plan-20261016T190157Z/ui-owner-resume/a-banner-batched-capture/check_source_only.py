from pathlib import Path
import ast,re,json,hashlib,time,shlex
P=Path('/media/linux/SSD128/xmppwin/local/monocles-dinox-interop-20261015/harness/resume-completion-plan-20261016T190157Z/ui-owner-resume');out=P/'a-banner-batched-capture';fixture=Path('/media/linux/SSD128/monocles-interop-runtime-20261015/pair-v2/session-public-Nora-auth-text-preflight-20261016T204821Z/actual-owner-ui-nora-b62679fe15df42049d7f19b566959044');base='actual-current-surface-capture-only';raw=(fixture/(base+'-input.txt')).read_text();wm=(fixture/(base+'-windows.txt')).read_text();png=(fixture/(base+'.png')).read_bytes()
sha=lambda f:hashlib.sha256(f.read_bytes()).hexdigest()
def pure(path):
 names={'visible_windows','input_rectangle','parse_input_dispatcher','input_ownership','combined_windows_input','binary_capture_frame'};ns={'re':re};tree=ast.parse(path.read_text());nodes=[x for x in tree.body if isinstance(x,ast.FunctionDef)and x.name in names];exec(compile(ast.Module(body=nodes,type_ignores=[]),str(path),'exec'),ns);return ns
old=pure(P/'owner_ui.py');new=pure(out/'wait_capture.py');persistent=pure(out/'owner_ui.py');groups=[]
assert old['parse_input_dispatcher'](raw)['status']=='UNKNOWN'
for ns in(new,persistent):
 assert ns['parse_input_dispatcher'](raw)['status']=='PARSED'
 v=ns['input_ownership'](raw,ns['visible_windows'](wm),[540,1059],'android',1000);assert v['tap_permitted'] and v['window']['name']=='Application Not Responding: com.android.systemui'
 assert not ns['input_ownership'](raw,ns['visible_windows'](wm),[540,200],'android',1000)['tap_permitted']
groups.append('realANRWaitOutsideKnownBannerAccepted_bannerPointRejected_oldReproducer')
for changed in(raw.replace('ownerUid=10120','ownerUid=10119'),raw.replace('touchableRegion=[42,0][1038,452]','touchableRegion=[42,0][1038,453]'),raw.replace('WATCH_OUTSIDE_TOUCH','WATCH_OUTSIDE_TOUCH | DROP_INPUT')):
 assert new['parse_input_dispatcher'](changed)['status']=='UNKNOWN'
groups.append('foreignUid_geometry_unknownFlagReject')
combined=('__OWNER_WINDOWS_BEGIN__\n'+wm+'__OWNER_INPUT_BEGIN__\n'+raw+'__OWNER_QUERY_END__\n').encode();payload=b'__OWNER_PNG_BEGIN__\n'+png+b'\n__OWNER_PNG_END__\n'+combined
for ns in(new,persistent):
 decoded=ns['binary_capture_frame'](payload);assert decoded==(png,wm,raw)
groups.append('realPNG_binaryBytes_preserved_exactWMInputFrame')
for broken in(payload[:-1],payload+b'__OWNER_PNG_BEGIN__\n',payload.replace(b'\n__OWNER_PNG_END__\n',b'\nNO_END\n'),payload.replace(b'\x89PNG\r\n\x1a\n',b'INVALIDPNG',1),payload[:-1]+b'\xff'):
 try:new['binary_capture_frame'](broken)
 except (AssertionError,UnicodeDecodeError,ValueError):pass
 else:raise AssertionError('Malformed frame accepted')
groups.append('missing_duplicate_truncated_invalidPNG_invalidUTF8Reject')
def fn(path,name):
 tree=ast.parse(path.read_text());return next(x for x in tree.body if isinstance(x,ast.FunctionDef)and x.name==name)
def method(path,name):
 tree=ast.parse(path.read_text());cls=next(x for x in tree.body if isinstance(x,ast.ClassDef)and x.name=='OwnerUI');return next(x for x in cls.body if isinstance(x,ast.FunctionDef)and x.name==name)
for target,original in((out/'wait_capture.py',P/'owner_ui.py'),(out/'owner_ui.py',P/'persistent-text/owner_ui.py')):
 assert ast.dump(fn(target,'parse_input_dispatcher'))==ast.dump(fn(P/'b-owner-public-join/owner_ui.py','parse_input_dispatcher'))
 for name in ('adb','session_now','require_touch','submit_semantic','activity','capture_target','run'):
  assert ast.dump(method(target,name))==ast.dump(method(original,name)),name
 assert ast.dump(fn(target,'capture_state_reusable'))==ast.dump(fn(original,'capture_state_reusable'))
assert sha(out/'persistent_text.py')==sha(P/'persistent-text/persistent_text.py')
groups.append('parserExactB_allLowerGuardsAndExistingRunnerASTOrBytesUnchanged')
for target in(out/'wait_capture.py',out/'owner_ui.py'):
 dump=method(target,'dump');query=next(n.value.value for n in ast.walk(dump) if isinstance(n,ast.Assign) and any(isinstance(t,ast.Name)and t.id=='query' for t in n.targets));assert shlex.split(shlex.join(['sh','-c',query]))==['sh','-c',query]
groups.append('fixedRemoteShellProgram_roundtripsAsOneQuotedArgument')
q=out/'offline-checks.json';q.write_text(json.dumps({'result':'PASS','groups':groups,'groups_count':len(groups),'source_only_no_process_or_runtime':True,'fixtures_sha256':{str(f):sha(f)for f in(fixture/(base+'-input.txt'),fixture/(base+'-windows.txt'),fixture/(base+'.png'))},'sources_sha256':{str(f):sha(f)for f in(out/'wait_capture.py',out/'owner_ui.py',out/'persistent_text.py')}},indent=2)+'\n');print(json.dumps({'result':'PASS','groups':len(groups),'receipt_sha256':sha(q)}))

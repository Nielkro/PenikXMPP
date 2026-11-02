#!/usr/bin/env python3
"""Offline pure checks only: no application import, subprocess, SDK or network."""
import ast
import copy
import json
from pathlib import Path
import re
import time
import types
import uuid
import xml.etree.ElementTree as ET

HERE = Path(__file__).resolve().parent
H = HERE.parents[1]
R = Path('/media/linux/SSD128/monocles-interop-runtime-20261015')
PACKAGE = 'de.monocles.chat.interop20261015'
checks = []

def rejected(call):
    try:
        call()
    except AssertionError:
        return
    raise AssertionError('Expected fail-closed rejection')

source = ast.parse((HERE/'owner_ui.py').read_text())
functions = {'visible_windows','input_ownership','input_rectangle','parse_input_dispatcher','combined_windows_input',
             'systemui_wait_node','capture_state_reusable','toolbar_navigation','actual_menu_choice'}
items = [n for n in source.body if isinstance(n,ast.FunctionDef) and n.name in functions]
items += [n for n in source.body if isinstance(n,ast.ClassDef) and n.name=='OwnerUI']
ui = ast.parse((H/'triple_v3/runtime_consent/ui_control.py').read_text())
select = next(n for n in ui.body if isinstance(n,ast.FunctionDef) and n.name=='select_node')
context = {'re':re,'PACKAGE':PACKAGE}
exec(compile(ast.Module(body=[select],type_ignores=[]),'frozen-select-node','exec'),context)
context['pure'] = types.SimpleNamespace(ui=types.SimpleNamespace(select_node=context['select_node']))
context['MENU_LABELS'] = {
    'join':('Join ongoing group call','Laufendem Gruppenanruf beitreten'),
    'rejoin':('Rejoin previous group call','Vorherigem Gruppenanruf erneut beitreten'),
}
exec(compile(ast.Module(body=items,type_ignores=[]),'owner-pure-definitions','exec'),context)
windows = context['visible_windows']; ownership = context['input_ownership']
fixture = R/'pair-v2/pair-PQ-video-30min-20261016T092121Z/Leon-menu-diagnosis-window.txt'
raw = fixture.read_text()
observation = windows(raw)
assert observation['status']=='OBSERVATION_ONLY' and observation['touch_ownership_proven'] is False
assert len(observation['windows'])==10
shade = [n for n in observation['windows'] if n['name']=='NotificationShade']
assert len(shade)==1 and shade[0]['visible']=='false'
checks.append('Real retained ten-window fixture parsed as observation only; no touch proof')
assert windows(raw.replace('    isVisible=false','    isVisible=false\n    isVisible=true',1))['status']=='UNKNOWN'
assert windows(raw.replace('  Window #3 Window{','  Window #3 BAD{',1))['status']=='UNKNOWN'
assert windows('topResumedActivity: expected app')['status']=='UNKNOWN'
checks.append('Ambiguous, partial and Activity-only window evidence rejected')
for candidate in ('', 'Input Dispatcher State:\n  DispatchEnabled: true\n  Windows:\n', 'arbitrary unknown actual input text'):
    result = ownership(candidate,observation,[758,152],PACKAGE)
    assert result['status']=='UNKNOWN' and result['tap_permitted'] is False
checks.append('Missing/unknown dispatcher representations remain UNKNOWN without granting input')

actual = R/'triple-v3/fresh-startup-consent-preflight-20261016T180350Z/owner-ui-adapter/actual-owner-ui-leon-250669b8bdc04ca1accc242144d727d3/actual-menu-choice.xml'
tree = ET.fromstring(actual.read_bytes())
node = context['toolbar_navigation'](tree)
assert node['content_desc']=='Navigate up' and node['bounds']==[26,79,173,226]
rejected(lambda:context['actual_menu_choice'](tree,'join'))
checks.append('Actual failed post-banner room has toolbar navigation but no JOIN popup')
changed = copy.deepcopy(tree)
bar = next(n for n in changed.iter('node') if n.get('resource-id')==PACKAGE+':id/toolbar')
nav = next(n for n in bar.iter('node') if n.get('content-desc')=='Navigate up')
bar.append(copy.deepcopy(nav))
rejected(lambda:context['toolbar_navigation'](changed))
changed = copy.deepcopy(tree)
next(n for n in changed.iter('node') if n.get('content-desc')=='Navigate up').set('content-desc','Back')
rejected(lambda:context['toolbar_navigation'](changed))
checks.append('Duplicate navigation and BACK-like alternatives rejected')
# Synthetic node checks verify only exact label matching. They never grant touch ownership.
for label in context['MENU_LABELS']['join']:
    synthetic = ET.fromstring('<hierarchy><node package="'+PACKAGE+'" resource-id="'+PACKAGE+':id/title" text="'+label+'" enabled="true" bounds="[1,1][20,20]" /></hierarchy>')
    assert context['actual_menu_choice'](synthetic,'join')['text']==label
    assert ownership('unreviewed',observation,[10,10],PACKAGE)['tap_permitted'] is False
checks.append('English/German JOIN labels exact; synthetic nodes cannot authorize a tap')
owner = context['OwnerUI'].__new__(context['OwnerUI'])
for tail in (['shell','-T','input','tap','758','152'],['shell','input','keyevent','4'],['shell','-T','input','text','token']):
    rejected(lambda:owner.adb(tail,'never-dispatched'))
checks.append('Fixed SDK input commands without an exact unused proof fail before owner lookup or dispatch')
# No historical active UI class or caller disguise may appear in executable AST.
for n in ast.walk(source):
    if isinstance(n,ast.Call) and isinstance(n.func,ast.Attribute):
        assert n.func.attr not in ('MixedUI','_old_control_settings')
    if isinstance(n,(ast.Assign,ast.AugAssign)):
        targets = n.targets if isinstance(n,ast.Assign) else [n.target]
        assert not any(isinstance(t,ast.Subscript) and isinstance(t.value,ast.Attribute) and t.value.attr=='argv' for t in targets)
checks.append('No MixedUI construction, old caller-guard access or sys.argv masquerade')
captured = []
def fake_run(argv, **kwargs):
    captured.append((argv,kwargs));return types.SimpleNamespace(returncode=0,stdout=b'{"recording":"synthetic"}')
context.update(subprocess=types.SimpleNamespace(run=fake_run,PIPE=-1),A_DIR=H/'devicefix_nora_runtime',json=json)
owner.profile='A'
owner.rec({'action':'state','role':'nora','recording':'20261016T000000Z-'+'a'*32,'tag':'source-only','wait':0})
argv,kwargs = captured[-1]
assert argv[:4]==['/usr/bin/python3','-B',str(H/'devicefix_nora_runtime/recorder.py'),'state']
assert argv[-5:]==['nora','--transport','local-android','--wait','0'] and kwargs['input'] is None
rejected(lambda:owner.rec({'action':'state','role':'leon','recording':'unused','tag':'source-only','wait':0}))
assert len(captured)==1
checks.append('A state uses actual frozen recorder CLI subprocess shape; native role rejected before dispatch')

# Reuse only existing pure fixture construction and pure validators by AST, never import MixedUI.
own = {p:p+'.owned@invalid' for p in ('nora','leon','felix')}
runtime = types.SimpleNamespace(RUN='synthetic-run',OWN=own,ROLES=('nora','leon','felix'),
                               v1=types.SimpleNamespace(write=lambda *args:None))
guard_context = {'r':runtime,'PACKAGE':PACKAGE,'TRUST':{'TRUSTED','VERIFIED'},'re':re,'ui':context['pure'].ui}
original_pure = ast.parse((H/'triple_v3/normal_consent_ui/normal_ui_consent.py').read_text())
defs = [n for n in original_pure.body if isinstance(n,ast.FunctionDef) and n.name in ('trusted_legacy_peers','nodes','conversation_ui')]
exec(compile(ast.Module(body=defs,type_ignores=[]),'original-pure-room-guards','exec'),guard_context)
pure = types.SimpleNamespace(ui=context['pure'].ui,**{name:guard_context[name] for name in ('trusted_legacy_peers','conversation_ui')})
mix_context = {'RUN':runtime.RUN,'OWN':own,'ROLES':runtime.ROLES,'PAIRS':('nora:leon','nora:felix','leon:felix'),'c':pure}
mix_source = ast.parse((H/'legacy3_mixed_consent/normal_mixed_ui_consent.py').read_text())
defs = [n for n in mix_source.body if isinstance(n,ast.FunctionDef) and n.name in ('exact','active_scope','native_receipt')]
exec(compile(ast.Module(body=defs,type_ignores=[]),'original-pure-mixed-guards','exec'),mix_context)
fixture_source = ast.parse((H/'legacy3_mixed_consent/check_mixed_consent.py').read_text())
fixture_context = {'m':types.SimpleNamespace(RUN=runtime.RUN,OWN=own,ROLES=runtime.ROLES,PAIRS=mix_context['PAIRS']),'time':time}
exec(compile(ast.Module(body=[next(n for n in fixture_source.body if isinstance(n,ast.FunctionDef) and n.name=='fixture')],type_ignores=[]),'existing-synthetic-mixed-fixture','exec'),fixture_context)
a,nora,natives = fixture_context['fixture']()
a['conversation_uuids']={'nora':a['conversation_uuid']};a['native_recording']='20261016T000000Z-'+'b'*32
context.update(r=runtime,time=time,uuid=uuid,pure=pure,Path=Path)
owner.a=a;owner.profile='A';owner.last_native=None;owner.out=Path('/synthetic')
owner.active_scope_check=mix_context['active_scope'];owner.native_receipt_check=mix_context['native_receipt']
requests=[]
def native_state(value):
    requests.append(value)
    return {'controller_exit':0,'observation':{'completed':True,'response':copy.deepcopy(natives[value['role']])}}
owner.native_recorder=types.SimpleNamespace(server=native_state)
assert owner.mixed_scope(nora)['uuid']==a['conversation_uuid']
assert [x['role'] for x in requests]==['leon','felix']
assert all(x['action']=='state' and x['local_recording'] is True and x['recording']==a['native_recording'] for x in requests)
rejected(lambda:owner.mixed_scope(nora))
for state in natives.values():
    for row in state['sessions']:row['audio_sink_samples']+=1
owner.mixed_scope(nora)
natives['leon']['own_public_identity_hex']='05'+'f'*64
rejected(lambda:owner.mixed_scope(nora))
checks.append('A actual-shape pure mixed scope binds two native read-only recorder states, identities and rising same-SID sinks')
receipt_state={'messages':[{'body':'one-token','peer':a['room']+'/Nora','direction':'received','encryption':'OMEMO','stanza_id':'sent-uuid'}]}
receipt=owner.native_receipt_check(receipt_state,'one-token',a['room'],'sent-uuid')
assert receipt['stanza_id_equals_Nora_sent_UUID'] and receipt['exact_sender_device_fingerprint_proven_by_this_snapshot'] is False
assert owner.native_receipt_check(receipt_state,'other-token',a['room'],'sent-uuid') is None
receipt_state['messages']*=2
rejected(lambda:owner.native_receipt_check(receipt_state,'one-token',a['room'],'sent-uuid'))
checks.append('Native decoded receipt preserves sender-auth limit and rejects duplicates/wrong tokens')
pins = ast.literal_eval(next(n.value for n in source.body if isinstance(n,ast.Assign)
                            and any(isinstance(t,ast.Name) and t.id=='A_PINS' for t in n.targets)))
context['A_PINS']=pins
binding={'controller_pid':100,'controller_start_ticks':1000,'adb_pid':101,'adb_start_ticks':1001,
         'emulator_pid':102,'emulator_start_ticks':1002,'adb_cgroup':'/owned.slice/nora.service','approval_sha256':'root-approval'}
groups={name:'/owned.slice/nora.service' for name in ('controller','adb','emulator')}
owner.a.update(runtime_freeze_sha256=pins['freeze.json'],batch_id='b'*32,session_binding=binding,
               process_cgroups=groups,native_bindings={'synthetic-exact-native-owner':True})
session=dict(binding,schema_version=2,state='running',ready=True,run_id=runtime.RUN,role='nora',
             batch_id='b'*32,freeze_sha256=pins['freeze.json'],apk_sha256={'main':'synthetic-apk'},
             guest_memory_mib=2048,inputs_sha256='synthetic-inputs',batch_deadline_unix=time.time()+60,
             native_readonly_bindings=owner.a['native_bindings'],adb_sha256='synthetic-adb')
runtime.ROOT=Path('/synthetic')
runtime.probe=types.SimpleNamespace(private_json=lambda path:session)
runtime.sha=lambda path:'synthetic-inputs' if str(path).endswith('runtime-inputs.json') else 'synthetic-adb'
runtime.v1.SLICE='owned.slice'
runtime.v1.start_ticks=lambda pid:{100:1000,101:1001,102:1002}[pid]
current_groups={100:groups['controller'],101:groups['adb'],102:groups['emulator']}
runtime.v1.process_cgroup=lambda pid:current_groups[pid]
owner.owner_runtime=types.SimpleNamespace(role_config=lambda role:{'state':Path('/synthetic-state')},APKS=session['apk_sha256'])
assert owner.session_now()==session
current_groups[101]='/owned.slice/other.service'
rejected(owner.session_now)
current_groups[101]=groups['adb'];session['controller_start_ticks']=999
rejected(owner.session_now)
checks.append('A exact process tick and cgroup bindings reject another owner within the same slice')
baseline=ast.parse((R/'triple-v3/fresh-startup-consent-preflight-20261016T180350Z/owner-ui-adapter/owner_ui.py').read_text())
for name in ('actual_confirmation','focused_activity'):
    old=next(n for n in baseline.body if isinstance(n,ast.FunctionDef) and n.name==name)
    new=next(n for n in source.body if isinstance(n,ast.FunctionDef) and n.name==name)
    assert ast.dump(old,include_attributes=False)==ast.dump(new,include_attributes=False)
checks.append('Accepted 65b702 empty-detail card and resumed-Activity guards preserved exactly')
capture_owner=context['OwnerUI'].__new__(context['OwnerUI'])
capture_owner.a={'action':'capture-only'};capture_owner.profile='A';capture_owner.role='nora';capture_owner.out=Path('/synthetic')
route=[]
def forbidden(*args,**kwargs):raise AssertionError('Capture must not inspect room/trust or dispatch normal UI')
def own_state(role):
    assert role=='nora';route.append('own-account-state')
    return {'conversations':[],'contacts':[],'calls':[],'conference':None}
def capture_surface(label):
    assert label=='actual-current-surface-capture-only';route.append('surface-capture')
    capture_owner.last_capture={'input':'unreviewed actual input','windows':{'status':'UNKNOWN'}}
    return ET.Element('hierarchy'),time.monotonic()
capture_owner.android_state=own_state;capture_owner.dump=capture_surface
capture_owner.state=forbidden;capture_owner.room=forbidden;capture_owner.adb=forbidden
trust=pure.trusted_legacy_peers;pure.trusted_legacy_peers=forbidden
try:result=capture_owner.run()
finally:pure.trusted_legacy_peers=trust
assert route==['own-account-state','surface-capture']
assert result['result']=='CAPTURE_ONLY_INPUT_UNKNOWN_NO_ACTION'
assert result['normal_UI_input_submitted'] is False and result['JOIN_submission_may_have_happened'] is False
checks.append('Roomless/no-other-trust initial A capture reaches observation only')
actual_dir=R/'pair-v2/core52-late-Nora-capture-preflight-20261016T192558Z/actual-owner-ui-nora-161aeda796bc486e9829bc4f9d865f2f'
actual_input=(actual_dir/'actual-current-surface-capture-only-input.txt').read_text()
actual_windows=(actual_dir/'actual-current-surface-capture-only-windows.txt').read_text()
actual_tree=ET.fromstring((actual_dir/'actual-current-surface-capture-only.xml').read_bytes())
wm=windows(actual_windows);parsed=context['parse_input_dispatcher'](actual_input)
assert parsed['status']=='PARSED' and len(parsed['windows'])==6
blocked=ownership(actual_input,wm,[758,152],PACKAGE,10150)
assert blocked['status']=='BLOCKED' and blocked['receiver']['uid']==1000 and blocked['tap_permitted'] is False
wait=context['systemui_wait_node'](actual_tree)
assert wait['point']==[540,1059]
proved=ownership(actual_input,wm,wait['point'],'android',1000)
assert proved['tap_permitted'] is True and proved['window']['name']=='Application Not Responding: com.android.systemui'
assert ownership(actual_input,wm,wait['point'],'android',1001)['tap_permitted'] is False
bad=copy.deepcopy(actual_tree)
next(n for n in bad.iter('node') if n.get('resource-id')=='android:id/aerr_wait').set('resource-id','android:id/aerr_close')
rejected(lambda:context['systemui_wait_node'](bad))
checks.append('Real six-window ANR input blocks app; only exact fresh Wait node binds android UID1000, never Close')

def synthetic_app(overlay):
    value=actual_input
    if not overlay:
        value=re.sub(r'(?m)^      2: name=389d426[^\n]*\n    transform \(ROT_0\) \(TRANSLATE\)\n(?:        [^\n]*\n){3}','',value)
        value=re.sub(r'(?m)^      (\d+): name=',lambda m:'      '+str(int(m[1])-1 if int(m[1])>2 else int(m[1]))+': name=',value)
    old='fbcbd0a com.android.launcher3/com.android.launcher3.uioverrides.QuickstepLauncher'
    new='fbcbd0a '+PACKAGE+'/eu.siacs.conversations.ui.ConversationsActivity'
    value=value.replace('389d426 Application Not Responding: com.android.systemui',old,2).replace(old,new)
    value=re.sub(r'(?m)^(      \d+: name=fbcbd0a[^\n]*)$',lambda m:m[1].replace('ownerPid=1339, ownerUid=10121','ownerPid=2207, ownerUid=10150'),value)
    w=copy.deepcopy(wm)
    app=next(n for n in w['windows'] if n['token']=='fbcbd0a');app.update(package=PACKAGE,uid='10150',name=new.split(' ',1)[1])
    if not overlay:
        anr=next(n for n in w['windows'] if n['token']=='389d426');anr.update(visible='false',surface='false')
    return value,w
free,free_wm=synthetic_app(False)
decision=ownership(free,free_wm,[758,152],PACKAGE,10150)
assert decision['tap_permitted'] is True,decision
overlay,overlay_wm=synthetic_app(True)
assert ownership(overlay,overlay_wm,[758,152],PACKAGE,10150)['tap_permitted'] is False
assert ownership(free,free_wm,[758,152],PACKAGE,10148)['tap_permitted'] is False
assert ownership(free.replace('inputConfig=NOT_FOCUSABLE','inputConfig=GUESSED_UNKNOWN_FLAG',1),free_wm,[758,152],PACKAGE,10150)['status']=='UNKNOWN'
checks.append('Synthetic app-free receiver succeeds; top overlay, old package UID and unknown flags deny input')
framed='__OWNER_WINDOWS_BEGIN__\n'+actual_windows+'__OWNER_INPUT_BEGIN__\n'+actual_input+'__OWNER_QUERY_END__\n'
assert context['combined_windows_input'](framed)==(actual_windows,actual_input)
rejected(lambda:context['combined_windows_input'](framed+'__OWNER_QUERY_END__\n'))
checks.append('Combined fixed read-only query markers reject incomplete/duplicate output')
proof_owner=context['OwnerUI'].__new__(context['OwnerUI']);proof_owner.a={'app_uid':10150,'expires_unix':time.time()+60};proof_owner.profile='B'
proof_owner.out=Path('/synthetic');proof_owner.pending_input=None
stamp=time.monotonic()
proof_owner.last_capture={'id':'actual-fixture','tree':actual_tree,'stamp':stamp,'started':stamp-5.01,'input':actual_input,'windows':wm}
rejected(lambda:proof_owner.require_touch(actual_tree,stamp,wait,'wait-age','android',1000,'Application Not Responding: com.android.systemui'))
tail=['shell','-T','input','tap','540','1059'];expiry=time.monotonic()+2
proof_owner.pending_input={'tail':tail,'expires':expiry,'capture_id':'actual-fixture'}
lookups=[]
def stop_owner_lookup():lookups.append(True);raise AssertionError('Mock stops before any SDK child')
proof_owner.session_now=stop_owner_lookup
rejected(lambda:proof_owner.adb(tail,'one-use',not_after=expiry))
assert proof_owner.pending_input is None and len(lookups)==1
rejected(lambda:proof_owner.adb(tail,'no-replay',not_after=expiry));assert len(lookups)==1
proof_owner.pending_input={'tail':tail,'expires':expiry,'capture_id':'actual-fixture'}
rejected(lambda:proof_owner.adb(['shell','-T','input','tap','1','2'],'wrong-tail',not_after=expiry))
assert proof_owner.pending_input is None and len(lookups)==1
rejected(lambda:proof_owner.submit_semantic(actual_tree,stamp,wait,['shell','-T','input','keyevent','4'],'no-keyevent'))
checks.append('Five seconds from dump start is enforced; exact input proof is consumed once, mismatched tail/raw keys denied')
reuse=context['capture_state_reusable'];now=time.time()
session={'controller_pid':100,'controller_start_ticks':1000,'batch':'same'};target={'action':'systemui-wait','role':'nora'}
tx={'id':'capture-one','session':session,'target':target,'observed_monotonic':10,'state':{'time_ms':int(now*1000)}}
assert reuse(tx,session,target,'capture-one',14.9,now+4.9)
rejected(lambda:reuse(tx,session,target,'capture-one',15.01,now+4.9))
rejected(lambda:reuse(tx,session,target,'capture-one',14,now+5.01))
rejected(lambda:reuse(tx,session,target,'capture-two',11,now+1))
rejected(lambda:reuse(tx,session,{'action':'consent','role':'nora'},'capture-one',11,now+1))
rejected(lambda:reuse(tx,dict(session,controller_start_ticks=1001),target,'capture-one',11,now+1))
checks.append('One A-state transaction reuses only exact capture/action/session within five seconds; all changed or stale contexts reject')
actual_free=R/'pair-v2/core52-late-Nora-capture-preflight-20261016T192558Z/actual-owner-ui-nora-f471b5c5314d4610b889031bddede773'
free_input=(actual_free/'actual-current-surface-capture-only-input.txt').read_text()
free_windows=windows((actual_free/'actual-current-surface-capture-only-windows.txt').read_text())
free_tree=ET.fromstring((actual_free/'actual-current-surface-capture-only.xml').read_bytes())
composer=context['select_node'](free_tree,'textinput')
assert any(n.get('resource-id')==PACKAGE+':id/toolbar_title' and n.get('text')=='Felix, Leon' for n in free_tree.iter('node'))
proved=ownership(free_input,free_windows,composer['point'],PACKAGE,10150)
assert proved['status']=='PROVEN_RECEIVER' and proved['receiver']['wm_token']=='ab9c0ed' and proved['receiver']['uid']==10150,proved
assert ownership(actual_input,wm,composer['point'],PACKAGE,10150)['tap_permitted'] is False
assert context['parse_input_dispatcher'](free_input.replace(', canOccludePresentation',', UNKNOWN_EXTRA_ATTRIBUTE'))['status']=='UNKNOWN'
assert context['parse_input_dispatcher'](free_input.replace('NOT_VISIBLE','GUESSED_FLAG',1))['status']=='UNKNOWN'
checks.append('Real free-app composer binds ab9c0ed/UID10150 with exact bool suffix and inactive sinks; ANR/unknown attributes remain denied')
print(json.dumps({'result':'SOURCE_ONLY_CHECKS_PASS','checks':checks,'checks_count':len(checks),
                  'runtime_executed':False,'input_dispatch_runtime_PASS_claimed':False,'actual_input_format_source_checked':True,
                  'A_active_mixed_consent_source_path_present':True},indent=2))

#!/usr/bin/env python3
"""Pure AST/fixture checks: no application import, command, SDK or network."""
import ast,copy,hashlib,json,re,tempfile,time,types
from pathlib import Path
import xml.etree.ElementTree as ET
HERE=Path(__file__).resolve().parent
H=HERE.parents[2]
R=Path('/media/linux/SSD128/monocles-interop-runtime-20261015')
PACKAGE='de.monocles.chat.interop20261015'
ROOM='interop-three-71115b-8df83d69736d9417@conference.dinox.im'
UUID='dae15cd3-0777-46f6-a28f-818d4854ab85'
sha=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()
checks=[]

def rejected(fn):
 try:fn()
 except (AssertionError,KeyError,ValueError):return
 raise AssertionError('Invalid fixture admitted')

def defs(path,names):
 return [n for n in ast.parse(path.read_text()).body if isinstance(n,(ast.FunctionDef,ast.ClassDef)) and n.name in names]

assert sha(HERE.parent/'owner_ui.py')=='86fdb0f031cbab3be5c231835ef4f672d2c5621e371b3d257552e846281476de'
assert sha(HERE.parent/'mixed_scenario.py')=='895aa598f4f069ad8978b352c870cb544a7b4f0c5f7310bdd5240d9c120a7f87'
base=ast.parse((HERE.parent/'owner_ui.py').read_text())
source=ast.parse((HERE/'owner_ui.py').read_text());runner=ast.parse((HERE/'persistent_text.py').read_text())
base_owner=next(n for n in base.body if isinstance(n,ast.ClassDef) and n.name=='OwnerUI')
owner_ast=next(n for n in source.body if isinstance(n,ast.ClassDef) and n.name=='OwnerUI')
for original in base.body:
 if isinstance(original,ast.FunctionDef):
  current=next(n for n in source.body if isinstance(n,ast.FunctionDef) and n.name==original.name)
  assert ast.dump(current)==ast.dump(original),original.name
changed={'__init__','persistent_scope','mixed_scope','room','android_state','state','run','finish_persistent','finish_mixed_receipts'}
for original in base_owner.body:
 if isinstance(original,ast.FunctionDef) and original.name not in changed:
  current=next(n for n in owner_ast.body if isinstance(n,ast.FunctionDef) and n.name==original.name)
  assert ast.dump(current)==ast.dump(original),original.name
checks.append('86fdb parser, capture freshness, one-use lower gate, normal input and strict 65b Done guards AST unchanged')

own={role:role+'.owned@invalid' for role in ('nora','leon','felix')}
runtime=types.SimpleNamespace(RUN='synthetic-run',OWN=own,ROLES=tuple(own))
public={'RUN':runtime.RUN,'OWN':own}
exec(compile(ast.Module(body=defs(H/'triple_v3/runtime_consent/runtime.py',{'public_identity'}),type_ignores=[]),'real-public-identity','exec'),public)
runtime.public_identity=public['public_identity']
context={'r':runtime,'re':re,'PACKAGE':PACKAGE,'time':time,'ET':ET}
exec(compile(ast.Module(body=defs(H/'triple_v3/runtime_consent/ui_control.py',{'select_node'}),type_ignores=[]),'real-node-check','exec'),context)
context['ui']=types.SimpleNamespace(select_node=context['select_node'])
context.update(TRUST={'TRUSTED','VERIFIED','VERIFIED_X509'},ENCRYPTION={'legacy':5,'omemo2':8})
pure_names={'room_state','trusted_legacy_peers','nodes','conversation_ui'}
exec(compile(ast.Module(body=defs(H/'triple_v3/normal_consent_ui/normal_ui_consent.py',pure_names),type_ignores=[]),'real-pure-room-checks','exec'),context)
pure=types.SimpleNamespace(ui=context['ui'],**{name:context[name] for name in pure_names})
context['pure']=pure
exec(compile(ast.Module(body=[owner_ast],type_ignores=[]),'new-owner-definitions','exec'),context)
fixture_context={'m':types.SimpleNamespace(RUN=runtime.RUN,OWN=own,ROLES=runtime.ROLES,PAIRS=('nora:leon','nora:felix','leon:felix')),'time':time}
exec(compile(ast.Module(body=defs(H/'legacy3_mixed_consent/check_mixed_consent.py',{'fixture'}),type_ignores=[]),'retained-mixed-fixture','exec'),fixture_context)
a,nora,native=fixture_context['fixture']()
a.update(action='persistent-consent',room=ROOM,conversation_uuids={'nora':UUID},room_title='Felix, Leon',empty_composer_hint='Send message')
nora.update(calls=[],conference=None,busy=False,pending_invites=[])
room=nora['conversations'][0];room.update(jid=ROOM,uuid=UUID)
for member in room['members']:member['occupant']=ROOM+'/'+member['occupant'].rsplit('/',1)[1]
for state in native.values():state.update(call=None,sessions=[])
owner=context['OwnerUI'].__new__(context['OwnerUI']);owner.a=a;owner.role='nora';owner.profile='A';owner.confirmed=False
assert owner.persistent_scope(nora,native)['uuid']==UUID
without_own=copy.deepcopy(nora)
without_own['conversations'][0]['members']=[m for m in without_own['conversations'][0]['members'] if m['real_jid'].split('/',1)[0]!=own['nora']]
assert len(without_own['conversations'][0]['members'])==2 and owner.persistent_scope(without_own,native)['uuid']==UUID
checks.append('Actual Bridge member contract accepts both exact peers with own member omitted or present; all three current states remain idle/bound')
for change in ('active-nora','pending-nora','active-native','wrong-fingerprint','wrong-resource','wrong-mode','missing-member','duplicate-own','foreign-member','null-member','untrusted'):
 n,p=copy.deepcopy(nora),copy.deepcopy(native)
 if change=='active-nora':n['calls']=[{'actual':'call'}]
 if change=='pending-nora':n['pending_invites']=[{'actual':'invite'}]
 if change=='active-native':p['leon']['sessions']=[{'wire_state':'ACTIVE'}]
 if change=='wrong-fingerprint':p['felix']['own_public_identity_hex']='05'+'f'*64
 if change=='wrong-resource':p['leon']['full_jid']=own['leon']+'/other'
 if change=='wrong-mode':n['conversations'][0]['encryption']=8
 if change=='missing-member':n['conversations'][0]['members'].pop()
 if change=='duplicate-own':n['conversations'][0]['members'].append(copy.deepcopy(n['conversations'][0]['members'][0]))
 if change=='foreign-member':n['conversations'][0]['members'][0]['real_jid']='foreign@invalid/resource'
 if change=='null-member':n['conversations'][0]['members'][0]['real_jid']=None
 if change=='untrusted':n['contacts'][0]['legacy_sessions'][0]['trust']='UNDECIDED'
 rejected(lambda:owner.persistent_scope(n,p))
checks.append('Active calls/invites/sessions, other identities/resources, wrong mode/members or untrusted peers fail closed')

fixture=R/'pair-v2/core52-late-Nora-capture-preflight-20261016T192558Z/actual-owner-ui-nora-f471b5c5314d4610b889031bddede773/actual-current-surface-capture-only.xml'
tree=ET.fromstring(fixture.read_bytes())
editor=pure.ui.select_node(tree,'textinput');a['empty_composer_hint']=editor['text']
context['focused_activity']=lambda raw:PACKAGE+'/eu.siacs.conversations.ui.'+raw
history=[]
owner.adb=lambda tail,label:history.append(('readonly-activity',tail)) or b'TrustKeysActivity'
owner.finish_consent=lambda token:history.append(('strict-Done-route',token)) or {'route':'strict'}
assert owner.finish_persistent('unique-token')=={'route':'strict'}
assert [x[0] for x in history]==['readonly-activity','strict-Done-route']
checks.append('Actual TrustKeys activity selects unchanged strict two-card/one-Done path once')
history.clear();a['expires_unix']=time.time()+30
token=runtime.RUN+':owner-ui-consent:nora:source'
sent=copy.deepcopy(nora);sent['conversations'][0]['test_messages']=[{'text':token,'uuid':'actual-sent-uuid','status':2,'encryption':5}]
owner.adb=lambda tail,label:history.append(('readonly-activity',tail)) or b'ConversationsActivity'
owner.state=lambda role:history.append(('readonly-state',role)) or sent
owner.room=lambda state,role:state['conversations'][0]
owner.dump=lambda label:history.append(('readonly-capture',label)) or (tree,0)
owner.finish_mixed_receipts=lambda text:history.append(('two-decoded-receipts',text,owner.confirmed)) or {'route':'already-sent'}
assert owner.finish_persistent(token)=={'route':'already-sent'}
assert [x[0] for x in history]==['readonly-activity','readonly-state','readonly-capture','two-decoded-receipts']
assert history[-1][2] is False
history.clear();sent['conversations'][0]['test_messages'][0]['status']=3
rejected(lambda:owner.finish_persistent(token))
assert not any(x[0] in ('strict-Done-route','two-decoded-receipts') for x in history)
owner.adb=lambda *args:b'UnexpectedActivity'
rejected(lambda:owner.finish_persistent(token))
checks.append('Already-sent actual mode5 row + real selected-room XML chooses receipts with Done false; failed/unexpected routes stop')

runner_context={'r':runtime,'m':types.SimpleNamespace(),'time':time}
exec(compile(ast.Module(body=defs(HERE.parent/'mixed_scenario.py',{'enum_is','idle'}),type_ignores=[]),'retained-idle-check','exec'),runner_context)
runner_context['PREFIX']={'ENDED':'DINO_ENTITIES_CALL_STATE_','ACTIVE':'DINO_PLUGINS_GOOGLE_WEBRTC_SIGNALING_STATE_'}
runner_context['m'].idle=runner_context['idle']
exec(compile(ast.Module(body=defs(HERE/'persistent_text.py',{'idle_identity'}),type_ignores=[]),'text-idle-identity','exec'),runner_context)
for role,state in [('nora',nora),*native.items()]:assert runner_context['idle_identity'](state,role,a) is state
bad=copy.deepcopy(native['leon']);bad['call']={'state':'IN_PROGRESS'}
rejected(lambda:runner_context['idle_identity'](bad,'leon',a))
bad=copy.deepcopy(nora);bad['time_ms']-=11000
rejected(lambda:runner_context['idle_identity'](bad,'nora',a))
checks.append('Actual state envelope, online identity, idle, no pending invite and Nora snapshot age required after command result')

with tempfile.TemporaryDirectory(prefix='persistent-source-check-') as directory:
 root=Path(directory);path=root/'redacted-root-readback.json'
 runtime.ROOT=root;runtime.read=lambda target:json.loads(Path(target).read_text())
 receipt={'run_id':runtime.RUN,'account':own['nora'],'allowed_rooms':[ROOM],
  'session_binding':{'synthetic-exact-session':True},'validated_write_readback_equal':True,'observed_unix':time.time()}
 admission={'session_binding':receipt['session_binding']}
 check_context={'r':runtime,'Path':Path,'sha':sha,'ROOM':ROOM,'time':time}
 exec(compile(ast.Module(body=defs(HERE/'persistent_text.py',{'fixture_authorization'}),type_ignores=[]),'root-readback-check','exec'),check_context)
 def validate(value):
  path.write_text(json.dumps(value));path.chmod(0o600)
  admission['fixture_room_authorization']={'path':str(path),'sha256':sha(path)}
  return check_context['fixture_authorization'](admission)
 assert validate(receipt)==receipt
 for key,value in (('allowed_rooms',[]),('session_binding',{'other':True}),('validated_write_readback_equal',False),('observed_unix',time.time()-121)):
  rejected(lambda key=key,value=value:validate(dict(receipt,**{key:value})))
checks.append('Pinned private Root readback must authorize only exact fixture, match actual session, be fresh and report validated equal readback')

for parsed in (source,runner):
 for node in ast.walk(parsed):
  if isinstance(node,ast.Call) and isinstance(node.func,ast.Attribute):
   assert node.func.attr not in ('MixedUI','_old_control_settings')
   if node.func.attr=='control_settings':assert parsed is source
  if isinstance(node,ast.Assign):
   assert not any(isinstance(t,ast.Subscript) and isinstance(t.value,ast.Attribute) and t.value.attr=='argv' for t in node.targets)
main=next(n for n in runner.body if isinstance(n,ast.FunctionDef) and n.name=='main')
operation=next(n for n in main.body if isinstance(n,ast.FunctionDef) and n.name=='op')
assert "role != 'nora' or payload['op'] == 'prepare_crypto'" in ast.unparse(operation)
assert "if payload:\n        return op(role, tag + '-readonly-after-command')" in ast.unparse(operation)
native_loop=next(n for n in ast.walk(main) if isinstance(n,ast.For) and ast.unparse(n.target)=='sender')
assert ast.literal_eval(native_loop.iter)==('leon','felix')
send_calls=[n for n in ast.walk(native_loop) if isinstance(n,ast.Call) and isinstance(n.func,ast.Name) and n.func.id=='op' and len(n.args)==3]
assert len(send_calls)==1
assert dict(zip((n.value for n in send_calls[0].args[2].keys),send_calls[0].args[2].values))['op'].value=='send_text'
assert 'len(tokens) == 3 and len(deliveries) == 6' in ast.unparse(main)
assert 'None if attempt[\'submission_may_have_happened\'] and (not tokens) else len(tokens)' in ast.unparse(main)
checks.append('Runner uses one owner child, only Nora prepare_crypto, two native sender iterations, no retry/argv disguise and honest unknown Nora attempt')

print(json.dumps({'scope':'SOURCE_ONLY_PURE_FIXTURES','groups':checks,'count':len(checks),
 'actual_runtime_ADB_SSH_build_or_UI_inputs':False},indent=2))

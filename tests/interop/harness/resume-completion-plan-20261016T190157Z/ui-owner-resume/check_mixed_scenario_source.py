#!/usr/bin/env python3
"""Pure AST/recording-shape fixtures only; no imports of application/runtime modules."""
import ast,copy,json,re,sys,time,types,uuid
from pathlib import Path
HERE=Path(__file__).resolve().parent
H=HERE.parents[1]
source=ast.parse((HERE/'mixed_scenario.py').read_text())
base=ast.parse((H/'devicefix_nora_runtime/scenario.py').read_text())
checks=[]
functions={n.name:n for n in source.body if isinstance(n,ast.FunctionDef)}
old={n.name:n for n in base.body if isinstance(n,ast.FunctionDef)}
for name in ('enum_is','idle','wait_for','endpoints','counters','received','public_identity','same_three'):
 assert ast.dump(functions[name],include_attributes=False)==ast.dump(old[name],include_attributes=False),name
checks.append('Eight accepted pure identity/media/RTP/PCM/lifecycle functions mechanically unchanged')

def prefix(node):
 result=[]
 for statement in node.body:
  if isinstance(statement,ast.Assign) and any(isinstance(t,ast.Tuple) and any(isinstance(n,ast.Name) and n.id=='tokens' for n in t.elts) for t in statement.targets):break
  if isinstance(statement,ast.Assert) and isinstance(statement.msg,ast.Constant) and statement.msg.value=='Surviving Nora-Leon SID changed':continue
  result.append(statement)
 return result
assert ast.dump(ast.Module(body=prefix(functions['scenario']),type_ignores=[]),include_attributes=False)==ast.dump(ast.Module(body=prefix(old['scenario']),type_ignores=[]),include_attributes=False)
assert any(isinstance(n,ast.Assert) and isinstance(n.msg,ast.Constant) and n.msg.value=='Surviving Nora-Leon SID changed' for n in functions['scenario'].body)
checks.append('Original direct promotion, six RTP/PCM edges, 65-second hold, leave and re-invite prefix preserved; surviving SID strengthened')
# Owner-scoped text orchestration with synthetic receipts and mocked normal UI only.
runtime=types.SimpleNamespace(RUN='synthetic-run',OWN={p:p+'@owned.invalid' for p in ('nora','leon','felix')})
context={'time':time,'uuid':uuid,'r':runtime,'ROLES':('nora','leon','felix'),'PAIRS':(('nora','leon'),('nora','felix'),('leon','felix')),
         'json':json,'sys':sys,'Path':Path,'re':re}
exec(compile(ast.Module(body=list(functions.values()),type_ignores=[]),'source-definitions-only','exec'),context)
room='owned@conference.invalid'

def fixture(fail=None):
 calls=[];sent={};ui_calls=[];scope={}
 def op(role,tag,payload=None):
  calls.append((role,tag,payload))
  if payload and payload['op']=='send_text':
   assert role in ('leon','felix')
   if fail=='native':raise RuntimeError('Uncertain native result')
   sent[role]=payload['text']
  if role=='nora':
   return {'conversations':[{'jid':room,'test_messages':[{'text':text,'status':0,'encryption':5} for peer,text in sent.items() if peer!=role]}]}
  return {'messages':[{'body':text,'peer':room+'/sender','direction':'received','encryption':'OMEMO'} for peer,text in sent.items() if peer!=role]}
 def consent(write,ctx,current,target):
  assert target==room;ui_calls.append(True)
  if fail=='before-ui':raise RuntimeError('Root checkpoint missing, child never dispatched')
  ctx['nora_ui_attempt']={'dispatch_intent_recorded':True,'submission_may_have_happened':True,'token':'one-normal-Nora-token','automatic_retry':False}
  if fail=='ui':raise RuntimeError('UI child result uncertain after possible Send')
  return {'token':'one-normal-Nora-token','sender':{'uuid':'actual-Nora-UUID','status':2,'encryption':5},
          'native_receipts':{p:{'body':'one-normal-Nora-token'} for p in ('leon','felix')}}
 context['normal_owner_consent']=consent
 tokens,deliveries,error=context['text_stage'](op,lambda *args:None,scope,room)
 return calls,ui_calls,tokens,deliveries,error,scope
calls,ui,tokens,deliveries,error,scope=fixture()
assert error is None and len(tokens)==3 and len(deliveries)==6 and len(ui)==1
sends=[(role,payload) for role,tag,payload in calls if payload and payload['op']=='send_text']
assert [role for role,payload in sends]==['leon','felix']
assert tokens[0]['sender']=='nora' and tokens[0]['Nora_Bridge_send_for_this_token'] is False
checks.append('Exactly one normal Nora UI token plus two native sends yields three tokens/six receipts; no Nora Bridge send')
result_write=next(n for n in functions['scenario'].body if isinstance(n,ast.Expr) and isinstance(n.value,ast.Call) and n.value.args and isinstance(n.value.args[0],ast.Constant) and n.value.args[0].value=='three-room-tokens.json').value.args[1]
metrics={k.value:v for k,v in zip(result_write.keys,result_write.values)}
count_expr=compile(ast.Expression(body=metrics['actual_new_tokens_attempted']),'actual-attempt-count','eval')
calls,ui,tokens,deliveries,error,scope=fixture('ui')
assert error and len(ui)==1 and tokens[0]['send_outcome']=='normal_UI_submission_unknown'
assert eval(count_expr,{'tokens':tokens}) is None
assert not any(payload and payload['op']=='send_text' for _,_,payload in calls)
checks.append('Uncertain normal UI submission remains UNKNOWN with an attempt reference, never zero or resent')
calls,ui,tokens,deliveries,error,scope=fixture('before-ui')
assert error and tokens[0]['send_outcome']=='normal_UI_not_submitted' and eval(count_expr,{'tokens':tokens})==0
calls,ui,tokens,deliveries,error,scope=fixture('native')
assert error and tokens[0]['send_outcome']=='normal_UI_sender_and_two_native_receipts' and len(deliveries)==2
checks.append('Undispatched checkpoint and later native failure preserve distinct truthful Nora attempt/receipt state')
# The frozen recorder process is real in production, mocked here before any subprocess.
recorded=[]
def fake_run(argv,**kwargs):recorded.append(argv);return types.SimpleNamespace(returncode=0,stdout=b'{"recording":"synthetic"}')
context.update(subprocess=types.SimpleNamespace(run=fake_run,DEVNULL=-3,PIPE=-1),A_DIR=H/'devicefix_nora_runtime',RECORDER_SHA='pinned-recorder')
runtime.sha=lambda p:'pinned-recorder'
context['android_record']({'action':'command','role':'nora','transport':'local-android','wait':30,'recording':'actual-recording','tag':'one-op',
                           'payload':{'op':'stats'}})
assert recorded[0][:4]==[sys.executable,'-B',str(H/'devicefix_nora_runtime/recorder.py'),'command']
assert json.loads(recorded[0][-1])=={'op':'stats'}
for value in ({'action':'command','role':'nora','transport':'local-android','wait':0,'recording':'r','tag':'t','payload':{'op':'stop'}},
              {'action':'state','role':'leon','transport':'local-android','wait':0,'recording':'r','tag':'t'}):
 try:context['android_record'](value)
 except AssertionError:pass
 else:raise AssertionError('Invalid recorder operation allowed')
assert len(recorded)==1
checks.append('Nora commands use only actual frozen recorder CLI; runtime-stop and native-role misuse rejected before child')
text=(HERE/'mixed_scenario.py').read_text()
assert 'r.control_settings(' not in text and 'android_rec.record' not in text and 'consent_ui.dispatch(' not in text
assert "for sender in ('leon','felix')" in text
for n in ast.walk(source):
 if isinstance(n,ast.Assign):
  assert not any(isinstance(t,ast.Subscript) and isinstance(t.value,ast.Attribute) and t.value.attr=='argv' for t in n.targets)
assert "payload.get('op')!='stop'" in text
assert "reviewed['input_dispatch_enabled'] is True" in text
assert "seconds=90" in text and "owner_ui_sha256" in text and "native_readonly_bindings" in text
checks.append('No frozen caller masquerade/old Mixed dispatch; current dynamic native binding and reviewed input pin required before media')
print(json.dumps({'result':'MIXED_SCENARIO_SOURCE_CHECKS_PASS','groups':checks,'groups_count':len(checks),
 'actual_runtime_ADB_SSH_or_build_executed':False,'interop_or_auth_PASS_claimed':False},indent=2))

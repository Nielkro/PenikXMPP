#!/usr/bin/env python3
"""Separate persistent-fixture text only; never starts calls/runtimes or sends Nora twice."""
import argparse,hashlib,importlib.util,json,os,re,signal,sys,time,uuid
from pathlib import Path
sys.dont_write_bytecode=True
assert not sys.flags.optimize
HERE=Path(__file__).resolve().parent
BASE=HERE.parent/'mixed_scenario.py'
sha=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()
assert sha(BASE)=='895aa598f4f069ad8978b352c870cb544a7b4f0c5f7310bdd5240d9c120a7f87'
spec=importlib.util.spec_from_file_location('accepted_owner_recorders',BASE);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
r=m.r
ROOM='interop-three-71115b-8df83d69736d9417@conference.dinox.im'
UUID='dae15cd3-0777-46f6-a28f-818d4854ab85'

def idle_identity(state,role,admission):
 assert state['run_id']==r.RUN and state['account']==r.OWN[role] and state['online'] is True
 assert m.idle(role,state),'All three roles must stay idle'
 identity=admission['identities'][role]
 if role=='nora':
  assert state['service_bound'] is True and not state['pending_invites']
  assert 0<=time.time()-state['time_ms']/1000<=10, 'Stale actual Nora state'
  assert state['own_device_id']==identity['device_id'] and state['own_legacy_fingerprint']==identity['legacy_fingerprint']
 else:
  assert state['full_jid']==admission['full_jids'][role] and state['profile_lock_held'] is True
  assert state['own_omemo_device_id']==identity['device_id'] and state['own_public_identity_hex']==identity['legacy_fingerprint']
 return state

def fixture_authorization(admission):
 ref=admission['fixture_room_authorization'];path=Path(ref['path'])
 assert path.is_file() and not path.is_symlink() and path.stat().st_mode&0o077==0
 assert path.resolve().is_relative_to(r.ROOT) and sha(path)==ref['sha256']
 receipt=r.read(path)
 assert receipt['run_id']==r.RUN and receipt['account']==r.OWN['nora']
 assert receipt['allowed_rooms']==[ROOM] and receipt['session_binding']==admission['session_binding']
 assert receipt['validated_write_readback_equal'] is True
 assert 0<=time.time()-receipt['observed_unix']<=120
 return receipt

def main():
 p=argparse.ArgumentParser();p.add_argument('--root-admission',type=Path,required=True);args=p.parse_args()
 assert args.root_admission.is_file() and not args.root_admission.is_symlink() and args.root_admission.stat().st_mode&0o077==0
 a=r.read(args.root_admission)
 assert a['operation']=='owner-persistent-mixed-text-sibling' and a['script_sha256']==sha(__file__)
 assert a['runtime_profile']=='A' and a['role']=='nora' and a['run_id']==r.RUN and a['accounts']==r.OWN
 assert a['room']==ROOM and a['conversation_uuids']=={'nora':UUID}
 assert sha(HERE/'owner_ui.py')==a['owner_ui_sha256']
 manifest=HERE/'source-manifest.json';assert sha(manifest)==a['owner_ui_manifest_sha256']
 reviewed=r.read(manifest)
 assert reviewed['files_sha256']['owner_ui.py']==a['owner_ui_sha256'] and reviewed['input_dispatch_enabled'] is True
 assert set(a['identities'])==set(a['full_jids'])==set(m.ROLES)
 for role in m.ROLES:
  identity=a['identities'][role]
  assert identity['account']==r.OWN[role] and type(identity['device_id']) is int and identity['device_id']>0
  assert re.fullmatch('05[0-9a-f]{64}',identity['legacy_fingerprint'])
  assert a['full_jids'][role].startswith(r.OWN[role]+'/') and a['full_jids'][role].split('/',1)[1]
 assert a['identities']['leon']['device_id']==172062497 and a['identities']['felix']['device_id']==1228426141
 target=Path(a['consent_reference_target'])
 assert target.is_absolute() and target.resolve().is_relative_to(r.ROOT) and not target.exists()
 assert 0<=time.time()-a['created_unix']<=120 and time.time()<a['expires_unix']<=a['created_unix']+240
 assert os.getpriority(os.PRIO_PROCESS,0)==19
 cfg,session=m.owner_session(a)
 assert m.FREEZE==r.frozen_files()=='131aa89a08adf3075e7ddcbc62af03b4ac14a682e3df4547099cd6bd6ef7b294'
 assert session['batch_deadline_unix']-time.time()>=120, 'Keep cleanup reserve; no late token start'
 fixture_authorization(a)  # Root's actual redacted config readback; no config edit in this sibling.
 binding=session['native_readonly_bindings'];directory=Path(binding['directory']).resolve(strict=True)
 assert directory.is_relative_to(m.HARNESS) and directory!=m.HARNESS
 assert sha(directory/'native_control.py')==binding['control_sha256'] and sha(directory/'native_recorder.py')==binding['recorder_sha256']
 spec=importlib.util.spec_from_file_location('native_control',directory/'native_control.py');control=importlib.util.module_from_spec(spec);sys.modules['native_control']=control;spec.loader.exec_module(control)
 assert control.admission(binding['admission_sha256'])==binding['owner_admission']
 spec=importlib.util.spec_from_file_location('persistent_native_recorder',directory/'native_recorder.py');native=importlib.util.module_from_spec(spec);spec.loader.exec_module(native);native.ADMISSION_SHA=binding['admission_sha256']
 assert Path(native.native_control.__file__).resolve()==directory/'native_control.py'
 out=r.ROOT/('persistent-mixed-text-'+uuid.uuid4().hex);out.mkdir(mode=0o700);write=lambda name,value:r.v1.write(out/name,value)
 rec={'nora':m.android_record({'action':'begin','label':'Persistent fixture normal Nora UI text'}),
      'native':native.server({'action':'begin','label':'Persistent fixture native text','local_recording':True})}
 def op(role,tag,payload=None):
  assert role in m.ROLES;r.v1.resources();m.owner_session(a)
  assert session['batch_deadline_unix']-time.time()>=120, 'Keep cleanup reserve; no further text operation'
  assert not payload or payload['op'] in ('authorize_room','join_room','prepare_crypto','send_text')
  assert not payload or role!='nora' or payload['op']=='prepare_crypto', 'Nora has no Bridge send/call/runtime operation here'
  q={'action':'command' if payload else 'state','role':role,'transport':'local-android' if role=='nora' else 'server',
     'wait':30 if payload else 0,'tag':tag,'recording':rec['nora' if role=='nora' else 'native']['recording']}
  if payload:q['payload']=payload
  if role=='nora':event=m.android_record(q)
  else:
   q['local_recording']=True
   if payload:q['id']=uuid.uuid4().hex
   event=native.server(q);assert event['controller_exit']==0
  z=event['observation'];assert z.get('completed'),'Uncertain operation; no resend'
  value=z['response'];assert value['run_id']==r.RUN and value['account']==r.OWN[role] and (not payload or value['ok'])
  # Command result payloads need not be complete state snapshots. Observe once;
  # never repeat a command to obtain missing state or an uncertain result.
  if payload:return op(role,tag+'-readonly-after-command')
  return idle_identity(value,role,a)
 tokens=[];deliveries=[];attempt={'submission_may_have_happened':False};result={'result':'PARTIAL','automatic_retry':False}
 try:
  for role in m.ROLES:op(role,'actual-persistent-initial-idle')
  op('nora','prepare-persistent-legacy-once',{'op':'prepare_crypto','room':ROOM,'encryption':'legacy'})
  for role in ('leon','felix'):
   op(role,'authorize-known-persistent-fixture',{'op':'authorize_room','room':ROOM})
   op(role,'join-known-persistent-fixture-once',{'op':'join_room','room':ROOM})
   op(role,'prepare-persistent-legacy-once',{'op':'prepare_crypto','room':ROOM,'encryption':'legacy'})
  states={role:op(role,'actual-persistent-before-normal-UI') for role in m.ROLES}
  scope={'room':ROOM,'states':states,'runtime_profile':'A','action':'persistent-consent','mode':'legacy',
         'conversation_uuids':{'nora':UUID},'identities':a['identities'],'full_jids':a['full_jids'],
         'native_recording':rec['native']['recording'],'native_bindings':binding,'session_binding':a['session_binding'],
         'process_cgroups':a['process_cgroups'],'owner_ui_sha256':a['owner_ui_sha256'],'owner_ui_manifest_sha256':a['owner_ui_manifest_sha256']}
  ref=m.consent_ui.owner_reference(r,write,target,'nora',scope,out,seconds=90)
  path=Path(ref['path']);assert path.is_file() and not path.is_symlink() and path.stat().st_mode&0o077==0 and sha(path)==ref['sha256']
  assert path.resolve().is_relative_to(r.ROOT)
  ui=r.read(path)
  for key in ('room','runtime_profile','action','mode','conversation_uuids','identities','full_jids','native_recording','native_bindings','session_binding','process_cgroups'):assert ui[key]==scope[key],key
  assert ui['batch_id']==a['batch_id'] and ui['adapter_sha256']==a['owner_ui_sha256']
  assert sha(HERE/'owner_ui.py')==a['owner_ui_sha256'] and sha(manifest)==a['owner_ui_manifest_sha256']
  remaining=min(ui['expires_unix']-time.time(),session['batch_deadline_unix']-time.time()-120);assert remaining>=5
  argv=[sys.executable,'-B',str(HERE/'owner_ui.py'),'--admission',str(path)]
  attempt={'submission_may_have_happened':True,'token':r.RUN+':owner-ui-consent:nora:'+ui['nonce'],'admission_path':str(path),'admission_sha256':ref['sha256']}
  write('Nora-normal-UI-submit-intent.json',attempt)
  child=m.subprocess.Popen(argv,stdin=m.subprocess.DEVNULL,stdout=m.subprocess.PIPE,stderr=m.subprocess.PIPE,start_new_session=True)
  try:
   assert r.v1.process_cgroup(child.pid)==r.v1.process_cgroup(os.getpid())
   stdout,stderr=child.communicate(timeout=remaining);write('Nora-normal-UI-child.json',{'exit':child.returncode,'stdout':stdout.decode(errors='replace'),'stderr':stderr.decode(errors='replace'),'automatic_retry':False})
   assert child.returncode==0;value=json.loads(stdout)
   assert value['result']=='OWNER_NORMAL_UI_TWO_NATIVE_DECODED_GROUP_RECEIPTS_PASS' and value['token']==attempt['token'] and value['adapter_sha256']==a['owner_ui_sha256']
   assert value['sender']['encryption']==5 and value['sender']['status'] in (2,7,8) and value['sender']['uuid']
   assert set(value['native_receipts'])=={'leon','felix'}
   for peer,receipt in value['native_receipts'].items():assert receipt['actual_body_received_in_owned_test_group'] and receipt['body']==attempt['token'] and receipt['peer'].split('/',1)[0]==ROOM
   actual_result=Path(value['path'])/'result.json';assert actual_result.resolve().is_relative_to(r.ROOT)
   assert r.read(actual_result)==value and type(value['recipient_confirmation_Done_submitted']) is bool
  finally:r.v1.stop_owned(child)
  tokens.append({'sender':'nora','text':value['token'],'sender_uuid':value['sender']['uuid'],'normal_UI_only':True,'Done_submitted':value['recipient_confirmation_Done_submitted']})
  deliveries.extend({'sender':'nora','receiver':peer,'text':value['token'],'receipt':receipt} for peer,receipt in value['native_receipts'].items())
  for sender in ('leon','felix'):
   text=r.RUN+':persistent-native:'+sender+':'+uuid.uuid4().hex;tokens.append({'sender':sender,'text':text})
   op(sender,'one-native-persistent-token',{'op':'send_text','room':ROOM,'encryption':'legacy','text':text})
   for receiver in m.ROLES:
    if receiver==sender:continue
    m.wait_for(lambda receiver=receiver:op(receiver,'actual-decoded-persistent-token'),lambda state,receiver=receiver:m.received(state,receiver,text,ROOM),seconds=30)
    deliveries.append({'sender':sender,'receiver':receiver,'text':text})
  assert len(tokens)==3 and len(deliveries)==6
  result={'result':'PERSISTENT_MIXED_TEXT_THREE_TOKENS_SIX_RECEIPTS_PASS','exact_sender_device_auth_claimed':False,'automatic_retry':False}
 except BaseException as error:result.update(type=type(error).__name__,detail=str(error))
 finally:
  write('persistent-text-result.json',{**result,'room':ROOM,'tokens':tokens,'deliveries':deliveries,'Nora_UI_attempt':attempt,
   'Nora_Bridge_send_count':0,'actual_tokens_attempted':None if attempt['submission_may_have_happened'] and not tokens else len(tokens),
   'no_calls_or_runtimes_started_or_stopped':True})
  print(json.dumps({'result':result['result'],'path':str(out),'automatic_retry':False}),flush=True)
 if result['result']=='PARTIAL':raise SystemExit(2)
if __name__=='__main__':
 def terminate(signum,frame):
  signal.signal(signal.SIGTERM,signal.SIG_IGN);signal.signal(signal.SIGINT,signal.SIG_IGN)
  raise SystemExit('Owned text sibling interrupted; never resend')
 signal.signal(signal.SIGTERM,terminate);signal.signal(signal.SIGINT,terminate)
 main()

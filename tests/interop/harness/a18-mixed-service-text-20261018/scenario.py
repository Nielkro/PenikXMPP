#!/usr/bin/env python3
"""Separate persistent-fixture service text; one normal frozen Bridge send per owned sender, no UI claim."""
import argparse,hashlib,importlib.util,json,os,re,signal,sys,time,uuid
from pathlib import Path
sys.dont_write_bytecode=True
assert not sys.flags.optimize
HERE=Path(__file__).resolve().parent
BASE=HERE/'service_support.py'
sha=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()
assert sha(BASE)=='0a74b6302f07bc62c6b475953e495de4a66d38c0682ba476f637af7a521a2daf'
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

def validate_scope(states,a):
 nora=states['nora'];assert not nora['pending_invites']
 rooms=[c for c in nora['conversations']if c['jid']==ROOM];assert len(rooms)==1;room=rooms[0]
 assert room['uuid']==UUID and room['online'] and room['private_nonanonymous'] and room['muc_error']=='NONE' and room['encryption']==5
 members=[x['real_jid'].split('/',1)[0] for x in room['members']];assert len(members)==len(set(members))
 assert set(r.OWN.values())-{r.OWN['nora']}<=set(members)<=set(r.OWN.values())
 for role,state in states.items():
  idle_identity(state,role,a)
  for peer in m.ROLES:
   if peer==role:continue
   contacts=[c for c in state['contacts']if c['jid']==r.OWN[peer]];assert len(contacts)==1
   identity=a['identities'][peer]
   if role=='nora':
    all_sessions=contacts[0]['legacy_sessions'];assert all_sessions and all(x['trust']in('TRUSTED','VERIFIED','VERIFIED_X509')for x in all_sessions)
    rows=[x for x in all_sessions if x['device_id']==identity['device_id']and x['fingerprint']==identity['legacy_fingerprint']]
   else:
    rows=[x for x in contacts[0]['devices']if x['device_id']==identity['device_id']and x['public_identity_hex']==identity['legacy_fingerprint']and x['active']and x['legacy']and type(x['trust']) is int and x['trust'] in (0,1)]
   assert len(rows)==1,'Exact current sender public key must already be trusted; never mutate trust'
 return room

def main():
 p=argparse.ArgumentParser();p.add_argument('--root-admission',type=Path,required=True);args=p.parse_args()
 assert args.root_admission.is_file() and not args.root_admission.is_symlink() and args.root_admission.stat().st_mode&0o077==0
 a=r.read(args.root_admission)
 assert a['operation']=='owner-persistent-mixed-service-text-sibling' and a['script_sha256']==sha(__file__)
 assert a['runtime_profile']=='A18' and a['role']=='nora' and a['run_id']==r.RUN and a['accounts']==r.OWN
 assert a['room']==ROOM and a['conversation_uuids']=={'nora':UUID}
 assert set(a['identities'])==set(a['full_jids'])==set(m.ROLES)
 for role in m.ROLES:
  identity=a['identities'][role]
  assert identity['account']==r.OWN[role] and type(identity['device_id']) is int and identity['device_id']>0
  assert re.fullmatch('05[0-9a-f]{64}',identity['legacy_fingerprint'])
  assert a['full_jids'][role].startswith(r.OWN[role]+'/') and a['full_jids'][role].split('/',1)[1]
 assert a['identities']['leon']['device_id']==172062497 and a['identities']['felix']['device_id']==1228426141
 assert 0<=time.time()-a['created_unix']<=120 and time.time()<a['expires_unix']<=a['created_unix']+240
 assert os.getpriority(os.PRIO_PROCESS,0)==19
 cfg,session=m.owner_session(a)
 assert m.FREEZE==r.frozen_files()==a['runtime_freeze_sha256']
 assert session['batch_deadline_unix']-time.time()>=120, 'Keep cleanup reserve; no late token start'
 fixture_authorization(a)  # Root's actual redacted config readback; no config edit in this sibling.
 import room_scope
 context=r.room_control_context()
 room_admission=room_scope.private_artifact(a['room_control_admission'],[r.HERE,r.ROOT])
 room_scope.validate_admission(room_admission,context,time.time(),at_entry=True)
 assert room_admission['fixture_room_authorization']==a['fixture_room_authorization']
 case_deadline=min(a['expires_unix'],room_admission['expires_unix'],session['batch_deadline_unix']-120)
 assert case_deadline-time.time()>=90, 'Insufficient fresh case budget; no product command'
 room_scope.claim_scenario_once(context,a['room_control_admission'],{'path':str(args.root_admission),'sha256':sha(args.root_admission)})
 m.ROOM_CONTROL_ADMISSION=a['room_control_admission']
 binding=session['native_readonly_bindings'];directory=Path(binding['directory']).resolve(strict=True)
 assert directory.is_relative_to(m.HARNESS) and directory!=m.HARNESS
 assert sha(directory/'native_control.py')==binding['control_sha256'] and sha(directory/'native_recorder.py')==binding['recorder_sha256']
 spec=importlib.util.spec_from_file_location('native_control',directory/'native_control.py');control=importlib.util.module_from_spec(spec);sys.modules['native_control']=control;spec.loader.exec_module(control)
 assert control.admission(binding['admission_sha256'])==binding['owner_admission']
 spec=importlib.util.spec_from_file_location('persistent_native_recorder',directory/'native_recorder.py');native=importlib.util.module_from_spec(spec);spec.loader.exec_module(native);native.ADMISSION_SHA=binding['admission_sha256']
 assert Path(native.native_control.__file__).resolve()==directory/'native_control.py'
 out=r.ROOT/('persistent-mixed-service-text-'+uuid.uuid4().hex);out.mkdir(mode=0o700);write=lambda name,value:r.v1.write(out/name,value)
 rec={'nora':m.android_record({'action':'begin','label':'Persistent fixture one Nora frozen Bridge service text'}),
      'native':native.server({'action':'begin','label':'Persistent fixture native text','local_recording':True})}
 def op(role,tag,payload=None):
  assert role in m.ROLES;r.v1.resources();m.owner_session(a)
  assert time.time()<case_deadline, 'Case scope expired; no further operation or resend'
  if payload and payload['op']=='send_text':
   assert case_deadline-time.time()>=40, 'Keep one send/result observation budget; no late token'
  assert session['batch_deadline_unix']-time.time()>=120, 'Keep cleanup reserve; no further text operation'
  assert not payload or payload['op'] in ('authorize_room','join_room','prepare_crypto','send_text')
  assert not payload or role!='nora' or payload['op'] in ('prepare_crypto','send_text'), 'Nora has no UI/call/runtime operation here'
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
  states={role:op(role,'actual-persistent-before-service-send') for role in m.ROLES}
  validate_scope(states,a)
  write('actual-before-service-send-scope.json',states)
  for sender in m.ROLES:
   text=r.RUN+':persistent-service:'+sender+':'+uuid.uuid4().hex
   attempt={'submission_may_have_happened':True,'sender':sender,'text':text,'service_route':'frozen_A_recorder_Bridge' if sender=='nora' else 'exact_current_native_recorder'}
   write('before-single-service-send-'+sender+'.json',attempt)
   tokens.append({'sender':sender,'text':text,'exactly_one_service_submission':True})
   sent=op(sender,'one-service-persistent-token',{'op':'send_text','room':ROOM,'encryption':'legacy','text':text})
   for receiver in m.ROLES:
    if receiver==sender:continue
    state=m.wait_for(lambda receiver=receiver:op(receiver,'actual-decoded-persistent-token'),lambda state,receiver=receiver:m.received(state,receiver,text,ROOM),seconds=30)
    if receiver=='nora':
     rooms=[c for c in state['conversations'] if c['jid']==ROOM];rows=[x for x in rooms[0]['test_messages']if x.get('text')==text and x['status']==0 and x['encryption']==5]
     assert len(rows)==1 and rows[0]['uuid'];receipt=rows[0]
    else:
     rows=[x for x in state['messages']if x.get('body')==text and x['direction']=='received' and x['peer'].split('/',1)[0]==ROOM and x['encryption']in('OMEMO','DINO_ENTITIES_ENCRYPTION_OMEMO')and not x.get('error')]
     assert len(rows)==1 and rows[0]['stanza_id'];receipt=rows[0]
    deliveries.append({'sender':sender,'receiver':receiver,'text':text,'actual_decoded_receipt':receipt})
  assert len(tokens)==3 and len(deliveries)==6
  result={'result':'PERSISTENT_MIXED_SERVICE_TEXT_THREE_TOKENS_SIX_RECEIPTS_PASS','exact_sender_device_auth_claimed':False,'automatic_retry':False}
 except BaseException as error:result.update(type=type(error).__name__,detail=str(error))
 finally:
  write('persistent-service-text-result.json',{**result,'room':ROOM,'tokens':tokens,'deliveries':deliveries,'last_service_attempt':attempt,'UI_send_or_Done_claimed':False,
   'Nora_Bridge_send_count':1 if result['result']=='PERSISTENT_MIXED_SERVICE_TEXT_THREE_TOKENS_SIX_RECEIPTS_PASS' else None,'service_submission_attempts':tokens,'actual_tokens_attempted':None if attempt['submission_may_have_happened'] and not tokens else len(tokens),
   'no_calls_or_runtimes_started_or_stopped':True})
  print(json.dumps({'result':result['result'],'path':str(out),'automatic_retry':False}),flush=True)
 if result['result']=='PARTIAL':raise SystemExit(2)
if __name__=='__main__':
 def terminate(signum,frame):
  signal.signal(signal.SIGTERM,signal.SIG_IGN);signal.signal(signal.SIGINT,signal.SIG_IGN)
  raise SystemExit('Owned text sibling interrupted; never resend')
 signal.signal(signal.SIGTERM,terminate);signal.signal(signal.SIGINT,terminate)
 main()

#!/usr/bin/env python3
"""Pure synthetic guards/orchestration only; never ADB, SSH, guests or peers."""
import ast
import copy
import json
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
import time
import xml.etree.ElementTree as ET
import normal_mixed_ui_consent as m


def reject(fn,*args):
    try:fn(*args)
    except (AssertionError,KeyError,ValueError):return
    raise AssertionError('Invalid fixture admitted')


def fixture():
    a={'room':'owned@conference.dinox.im','room_title':'Owned room','conversation_uuid':'room-uuid',
       'mode':'legacy','call_ids':{'nora':'nora-conf','leon':21,'felix':22},
       'full_jids':{p:m.OWN[p]+'/real-'+p for p in m.ROLES},
       'identities':{p:{'account':m.OWN[p],'device_id':10+i,'legacy_fingerprint':'05'+str(i+1)*64}
                     for i,p in enumerate(m.ROLES)},'sids':dict(zip(m.PAIRS,('sid-nl','sid-nf','sid-lf'))),
       'display_names':{m.OWN[p]:p.title() for p in ('leon','felix')},'expires_unix':time.time()+240}
    room={'uuid':a['conversation_uuid'],'jid':a['room'],'online':True,'private_nonanonymous':True,'muc_error':'NONE',
          'encryption':5,'members':[{'occupant':a['room']+'/'+p,'real_jid':a['full_jids'][p]} for p in m.ROLES],
          'test_messages':[]}
    nora={'run_id':m.RUN,'account':m.OWN['nora'],'online':True,'service_bound':True,'time_ms':int(time.time()*1000),
          'own_device_id':10,'own_legacy_fingerprint':a['identities']['nora']['legacy_fingerprint'],
          'conference':{'room':a['room'],'call_id':a['call_ids']['nora'],
                        'participants':[a['full_jids'][p] for p in ('leon','felix')]},
          'calls':[{'session_id':a['sids']['nora:'+p],'peer':a['full_jids'][p],'muji_room':a['room'],
                    'end_user_state':'CONNECTED','media':['AUDIO']} for p in ('leon','felix')],
          'conversations':[room],'contacts':[{'jid':m.OWN[p],'legacy_sessions':[{
              'device_id':a['identities'][p]['device_id'],'fingerprint':a['identities'][p]['legacy_fingerprint'],
              'trust':'TRUSTED'}]} for p in ('leon','felix')]}
    natives={}
    for role in ('leon','felix'):
        natives[role]={'run_id':m.RUN,'account':m.OWN[role],'full_jid':a['full_jids'][role],
            'online':True,'profile_lock_held':True,'own_omemo_device_id':a['identities'][role]['device_id'],
            'own_public_identity_hex':a['identities'][role]['legacy_fingerprint'],
            'call':{'id':a['call_ids'][role],'room':a['room'],'peers':2,'state':'IN_PROGRESS'},'messages':[],
            'sessions':[{'sid':a['sids'][k],'local':a['full_jids'][role],
                'peer':a['full_jids'][next(p for p in k.split(':') if p!=role)],'room':a['room'],
                'wire_state':'ACTIVE','peer_connection_state':'CONNECTED','audio_sink_samples':100}
                for k in m.PAIRS if role in k.split(':')]}
    return a,nora,natives


def node(resource,text=''):
    return ET.Element('node',{'package':m.c.PACKAGE,'resource-id':m.c.PACKAGE+':id/'+resource,
        'text':text,'clickable':'true','enabled':'true','bounds':'[10,20][110,60]'})


def run():
    groups=[];ast.parse(Path(m.__file__).read_text());assert m.sha(m.PURE)==m.PURE_SHA
    groups.append('syntax_exact_reviewed_59d6_nodeguards_and_ca618_UI_helpers')
    a,n,p=fixture();m.active_scope(n,p,a,time.time())
    for key,value in (('call_id','other-conf'),('room','other@conference.dinox.im')):
        bad=copy.deepcopy(n);bad['conference'][key]=value;reject(m.active_scope,bad,p,a,time.time())
    for key,value in (('session_id','stale'),('peer',m.OWN['leon']+'/replaced'),('end_user_state','DISCONNECTED')):
        bad=copy.deepcopy(n);bad['calls'][0][key]=value;reject(m.active_scope,bad,p,a,time.time())
    bad=copy.deepcopy(n);bad['time_ms']=0;reject(m.active_scope,bad,p,a,time.time())
    groups.append('exact_active_Nora_conference_room_two_SIDs_fullJIDs_and_fresh_identity')
    for key,value in (('full_jid',m.OWN['leon']+'/old'),('own_omemo_device_id',14234),('own_public_identity_hex','05'+'f'*64),('online',False)):
        bad=copy.deepcopy(p);bad['leon'][key]=value;reject(m.active_scope,n,bad,a,time.time())
    for key,value in (('wire_state','INACTIVE'),('peer_connection_state','DISCONNECTED'),('peer',m.OWN['nora']+'/old'),('sid','old-sid')):
        bad=copy.deepcopy(p);bad['leon']['sessions'][0][key]=value;reject(m.active_scope,n,bad,a,time.time())
    bad=copy.deepcopy(p);bad['leon']['call']['state']='ENDED';reject(m.active_scope,n,bad,a,time.time())
    groups.append('exact_current_native_public_device_fullJID_callid_active_connected_not_suffixes')
    bad=copy.deepcopy(n);bad['conversations'][0]['members'].append({'occupant':'foreign','real_jid':'foreign@invalid/other'})
    reject(m.active_scope,bad,p,a,time.time())
    bad=copy.deepcopy(n);bad['contacts'][0]['legacy_sessions'][0]['trust']='UNDECIDED'
    reject(m.active_scope,bad,p,a,time.time())
    groups.append('only_three_known_room_identities_and_already_TRUSTED_exact_legacy_keys')
    state={'messages':[{'body':'one-token','peer':a['room']+'/Nora','direction':'received','encryption':'OMEMO','stanza_id':'sent-uuid'}]}
    receipt=m.native_receipt(state,'one-token',a['room'],'sent-uuid')
    assert receipt['stanza_id_equals_Nora_sent_UUID'] and not receipt['exact_sender_device_fingerprint_proven_by_this_snapshot']
    assert m.native_receipt(state,'other',a['room'],'sent-uuid') is None
    for key,value in (('peer','other@conference.dinox.im/Nora'),('direction','sent'),('encryption','NONE')):
        bad=copy.deepcopy(state);bad['messages'][0][key]=value;assert m.native_receipt(bad,'one-token',a['room'],'sent-uuid') is None
    bad=copy.deepcopy(state);bad['messages']*=2;reject(m.native_receipt,bad,'one-token',a['room'],'sent-uuid')
    groups.append('two_received_body_schema_and_optional_actual_stanza_match_no_sender_FP_invention')
    # A well-shaped Root admission for the *old* runtime is still blocked before
    # any Android/native client or subprocess. Only a reviewed derivative can bind.
    base=copy.deepcopy(a);base.update(operation='normal-mixed-recipient-consent',schema_version=1,helper_sha256=m.sha(m.__file__),
        pure_guards_sha256=m.PURE_SHA,run_id=m.RUN,accounts=m.OWN,role='nora',no_trust_or_call_changes_authorized=True,
        created_unix=time.time(),expires_unix=time.time()+180,nonce='a'*32,batch_id='b'*32)
    for family,names in (('runtime',('runtime.py','control.py')),('native',('native_control.py','native_recorder.py'))):
        d=m.HARNESS/('pair_v2' if family=='runtime' else 'legacy3_followup')
        base[family]={'directory':str(d),'files_sha256':{name:m.sha(d/name) for name in names}}
    with patch.object(m,'load',return_value=SimpleNamespace()) as loaded,patch.object(m.subprocess,'run') as io:
        reject(m.bindings,base,time.time());assert loaded.call_count==1;io.assert_not_called()
    for key,value in (('role','leon'),('mode','omemo2'),('room','unknown@elsewhere.invalid'),('helper_sha256','x'*64)):
        bad=copy.deepcopy(base);bad[key]=value
        with patch.object(m,'load') as loaded,patch.object(m.subprocess,'run') as io:
            reject(m.bindings,bad,time.time());loaded.assert_not_called();io.assert_not_called()
    groups.append('private_Root_shape_scope_pins_and_missing_exact_runtime_adoption_before_IO')
    # Actual run orchestration, synthetic UI and raw states only.
    for fail in (False,True):
        driver=object.__new__(m.MixedUI);driver.a=a;driver.role='nora';driver.room=a['room'];driver.out=Path('/synthetic')
        driver.token=m.RUN+':mixed-consent:nora:'+'a'*32;driver.sent=driver.confirmed=False;actions=[]
        driver.write=lambda *args:None;driver.activity=lambda *args:None
        def scope():
            x,y=copy.deepcopy(n),copy.deepcopy(p)
            if driver.confirmed:
                x['conversations'][0]['test_messages']=[{'uuid':'nora-sent','text':driver.token,'status':2,'encryption':5}]
                for value in y.values():value['messages']=[{'body':driver.token,'peer':a['room']+'/Nora',
                    'direction':'received','encryption':'OMEMO','stanza_id':'nora-sent'}]
            return x,y
        driver.scope=scope;driver.tap=lambda tree,stamp,resource,label:actions.append(resource)
        driver.adb=lambda *args,**kwargs:('Status: ok\nActivity: '+m.c.PACKAGE+'/UI\n').encode()
        def dump(label):
            t=ET.Element('hierarchy')
            if label in ('fresh-confirmation','fresh-before-done'):
                if fail:raise AssertionError('Synthetic missing confirmation')
                t.append(node('toolbar_title','Trust legacy OMEMO Fingerprints'))
                for role in ('leon','felix'):
                    card=node('foreign_keys_card');card.append(node('foreign_keys_title',m.OWN[role]))
                    card.append(node('foreign_keys_details'));card.append(node('no_keys_to_accept',m.c.CONFIRM[0].format(role.title())));t.append(card)
                t.append(node('save_button','Done'))
            else:
                t.append(node('toolbar_title',a['room_title']));t.append(node('textinput',driver.token if label=='fresh-before-single-send' else ''))
                t.append(node('textSendButton'))
            return t,time.monotonic()
        driver.dump=dump
        with patch.object(m.time,'sleep'):
            try:result=driver.run()
            except AssertionError:assert fail
            else:assert not fail and len(result['native_received'])==2
        assert actions.count('textSendButton')==1 and actions.count('save_button')==(0 if fail else 1)
        assert not any(x in actions for x in ('action_group_call','hangup','trust_fingerprint'))
    groups.append('one_normal_Nora_send_done_resume_two_native_bodies_no_resend_on_partial')
    # The copied pure toolbar/consent guard is exercised without accepting a
    # matching name in the chat list or any key-choice UI.
    tree=ET.Element('hierarchy');tree.append(node('toolbar_title','Wrong selected chat'));tree.append(node('chat_list_entry',a['room_title']));tree.append(node('textinput',''))
    reject(m.c.conversation_ui,tree,a,'')
    groups.append('inherited_two_pane_selected_toolbar_guard_no_UI_target_weakening')
    result={'result':'OFFLINE_MIXED_FIXTURES_PASS_NOT_RUNTIME','groups':groups,'actual_ADB_SSH_or_product_actions':False}
    path=m.HERE/'offline-results.json';path.write_text(json.dumps(result,indent=2)+'\n');path.chmod(0o600)
    print(json.dumps(result))


if __name__=='__main__':run()

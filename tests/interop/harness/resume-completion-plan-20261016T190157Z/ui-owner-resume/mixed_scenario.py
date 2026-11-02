#!/usr/bin/env python3
"""Separate owner scenario: frozen Recorder CLI, existing media proof, one normal UI Nora token."""
import argparse
import datetime
import json
import os
from pathlib import Path
import resource
import re
import signal
import subprocess
import sys
import time
import uuid

HERE = Path(__file__).resolve().parent
sys.dont_write_bytecode = True
HARNESS = Path('/media/linux/SSD128/xmppwin/local/monocles-dinox-interop-20261015/harness')
A_DIR = HARNESS/'devicefix_nora_runtime'
sys.path.insert(0,str(A_DIR))
import runtime as r
native_rec = server_control = None

ROLES = ('nora', 'leon', 'felix')
PAIRS = (('nora', 'leon'), ('nora', 'felix'), ('leon', 'felix'))
MAIN = '0a8ce212645b5a4876ee7f88122e5065d8f34a4f2a5c212ac91eec4402d0bebe'
FREEZE = r.frozen_files()
BASE_SCENARIO_SHA = '09229db8f8398deda9ed25ced3c69c5325c9c57bb63d17f6d1652acd82adb0d0'
RECORDER_SHA = '416a89203a246dd481f8a79fd08dd930f6ed988d8eccceb5a12ed31bbdfb16b5'

import importlib.util as _ci
_cs=_ci.spec_from_file_location('scoped_consent_dispatch','/media/linux/SSD128/xmppwin/local/monocles-dinox-interop-20261015/harness/devicefix_runtime_derivation/consent_dispatch.py')
assert r.sha(Path(_cs.origin))=='5300cbb2521eb4c0693c8956b17ee611a16a41f1fe08f1b165948b8f6b942dac'
consent_ui=_ci.module_from_spec(_cs);_cs.loader.exec_module(consent_ui)


PREFIX = {**dict.fromkeys(('RINGING', 'IN_PROGRESS', 'ESTABLISHING', 'ENDED'), 'DINO_ENTITIES_CALL_STATE_'),
          'ACTIVE': 'DINO_PLUGINS_GOOGLE_WEBRTC_SIGNALING_STATE_', 'CONNECTED': 'DINOX_WEBRTC_PEER_CONNECTION_STATE_',
          'AVAILABLE': 'DINO_PARTICIPANT_INVITE_AVAILABILITY_'}


def enum_is(value, name): return value in (name, PREFIX[name] + name)


def idle(role, state):
    if role == 'nora': return not state['calls'] and not state.get('conference') and not state['busy']
    return (not state.get('call') or enum_is(state['call']['state'], 'ENDED')) and not any(
        enum_is(s.get('wire_state'), 'ACTIVE') for s in state['sessions'])


def wait_for(read, ready, sleep=time.sleep, clock=time.monotonic, seconds=90):
    deadline = clock() + seconds
    while True:
        value = read()
        if ready(value): return value
        assert clock() < deadline, 'Bounded observation incomplete; no mutation retry'
        sleep(1)


def endpoints(states, pair, room):
    a, b = pair
    native = states[b]['sessions'] if a == 'nora' else states[a]['sessions']
    peer = r.OWN[a] if a == 'nora' else states[b]['full_jid']
    rows = [s for s in native if s['peer'].split('/', 1)[0] == peer.split('/', 1)[0]
            and s.get('room') == room and enum_is(s.get('wire_state'), 'ACTIVE')
            and enum_is(s.get('peer_connection_state'), 'CONNECTED')]
    assert len(rows) == 1, 'Missing or ambiguous current native media session'
    first = rows[0]
    if a == 'nora':
        other = [c for c in states[a]['calls'] if c['session_id'] == first['sid']
                 and c['peer'] == states[b]['full_jid'] and c.get('muji_room') == room
                 and c['end_user_state'] == 'CONNECTED']
        assert first['local'] == states[b]['full_jid'] and first['peer'].startswith(r.OWN['nora'] + '/')
    else:
        other = [s for s in states[b]['sessions'] if s['sid'] == first['sid'] and s.get('room') == room
                 and enum_is(s.get('wire_state'), 'ACTIVE') and enum_is(s.get('peer_connection_state'), 'CONNECTED')]
        assert first['local'] == states[a]['full_jid'] and first['peer'] == states[b]['full_jid']
        assert len(other) == 1 and other[0]['local'] == first['peer'] and other[0]['peer'] == first['local']
    assert len(other) == 1
    if a == 'nora': assert other[0]['media'] == ['AUDIO'], 'Unexpected negotiated media in audio-only case'
    for row in ([first] if a == 'nora' else [first, other[0]]):
        assert row['capture_running'] == row['video_in_packets'] == row['video_out_packets'] == 0
    return first['sid'], {'nora': other[0], b: first} if a == 'nora' else {a: first, b: other[0]}


def counters(role, row):
    if role != 'nora': return row['audio_in_packets'], row['audio_out_packets'], row['audio_sink_samples']
    incoming = [s for s in row['rtp_stats'] if s['type'] == 'inbound-rtp' and s.get('kind') == 'audio']
    outgoing = [s for s in row['rtp_stats'] if s['type'] == 'outbound-rtp' and s.get('kind') == 'audio']
    assert len(incoming) == len(outgoing) == 1
    return incoming[0]['packetsReceived'], outgoing[0]['packetsSent'], incoming[0]['totalSamplesReceived']


def received(state, receiver, text, room):
    if receiver == 'nora':
        return any(m.get('text') == text and m['status'] == 0 and m['encryption'] == 5
                   for c in state['conversations'] if c['jid'] == room for m in c['test_messages'])
    return any(m['body'] == text and m['direction'] == 'received' and m['encryption'] in ('OMEMO', 'DINO_ENTITIES_ENCRYPTION_OMEMO')
               and m['peer'].split('/', 1)[0] == room for m in state['messages'])


def public_identity(state, role):
    device = state['own_omemo_device_id']; fingerprint = state['own_public_identity_hex']
    assert type(device) is int and device > 0 and re.fullmatch('05[0-9a-f]{64}', fingerprint)
    contacts = []
    for contact in state['contacts']:
        assert contact['jid'] in {r.OWN[x] for x in ROLES if x != role}
        contacts.append({k: contact[k] for k in ('jid', 'resources', 'devices')})
    return {'account': state['account'], 'full_jid': state['full_jid'], 'own_device_id': device,
            'own_public_identity_hex': fingerprint, 'contacts': contacts,
            'call_auth_proven_by_this_observation': False}


def same_three(states, original, room, context):
    conf = states['nora']['conference']
    assert conf['room'] == room and conf['call_id'] == original['nora']['conference']['call_id']
    expected_peers = {states[x]['full_jid'] for x in ('leon', 'felix')}
    assert expected_peers <= set(conf['participants']) <= expected_peers | {context['nora_full_jid']}
    for role in ('leon', 'felix'):
        assert states[role]['call']['id'] == original[role]['call']['id']
        assert states[role]['call']['room'] == room and states[role]['call']['peers'] == 2
        assert enum_is(states[role]['call']['state'], 'IN_PROGRESS')
        assert states[role]['full_jid'] == original[role]['full_jid']
    for pair in PAIRS:
        sid, rows = endpoints(states, pair, room); assert sid == endpoints(original, pair, room)[0]
        if pair[0] == 'nora': assert rows[pair[1]]['peer'] == context['nora_full_jid']


def owner_session(root):
    # Independent exact owner binding; never call a forbidden frozen caller guard.
    cfg = r.role_config('nora'); session = r.read(cfg['state']/'live-session.json')
    assert session['schema_version']==2 and session['state']=='running' and session['ready'] is True
    assert session['run_id']==r.RUN and session['role']=='nora' and session['batch_id']==root['batch_id']
    assert session['freeze_sha256']==root['runtime_freeze_sha256']==FREEZE
    assert session['apk_sha256']==r.APKS and session['guest_memory_mib']==2048
    assert session['inputs_sha256']==root['runtime_inputs_sha256']==r.sha(r.ROOT/'runtime-inputs.json')
    assert time.time()<session['batch_deadline_unix']
    keys={'controller_pid','controller_start_ticks','adb_pid','adb_start_ticks',
          'emulator_pid','emulator_start_ticks','adb_cgroup','approval_sha256'}
    assert set(root['session_binding'])==keys
    assert {key:session[key] for key in keys}==root['session_binding']
    assert set(root['process_cgroups'])=={'controller','adb','emulator'}
    for name in ('controller','adb','emulator'):
        assert r.v1.start_ticks(session[name+'_pid'])==session[name+'_start_ticks']
        group=r.v1.process_cgroup(session[name+'_pid'])
        assert group==root['process_cgroups'][name] and r.v1.SLICE in Path(group).parts
    assert session['adb_cgroup']==root['process_cgroups']['adb']
    assert session['adb_sha256']==r.sha(r.ROOT/'sdk/platform-tools/adb')
    assert session['native_readonly_bindings']==root['native_bindings']
    return cfg,session


def root_admission(path):
    path=Path(path);assert path.is_file() and not path.is_symlink() and path.stat().st_mode&0o077==0
    root=r.read(path)
    assert root['operation']=='owner-mixed-media-consent-sibling' and root['runtime_profile']=='A'
    assert root['scenario_sha256']==r.sha(Path(__file__)) and root['run_id']==r.RUN
    assert root['accounts']==r.OWN and root['role']=='nora'
    assert 0<=time.time()-root['created_unix']<=120 and time.time()<root['expires_unix']<=root['created_unix']+240
    assert r.sha(A_DIR/'scenario.py')==BASE_SCENARIO_SHA and r.sha(A_DIR/'recorder.py')==RECORDER_SHA
    assert FREEZE==r.frozen_files()=='131aa89a08adf3075e7ddcbc62af03b4ac14a682e3df4547099cd6bd6ef7b294'
    assert r.APKS=={'main.apk':MAIN,'android-test.apk':'486b06a8f472fc68d89f9ced35b1befbc67805f22aa0d3dbf1c162cf3aab6e65'}
    helper=HERE/'owner_ui.py';manifest=HERE/'source-manifest.json'
    assert r.sha(helper)==root['owner_ui_sha256'] and r.sha(manifest)==root['owner_ui_manifest_sha256']
    reviewed=r.read(manifest)
    assert reviewed['files_sha256']['owner_ui.py']==root['owner_ui_sha256']
    assert reviewed['input_dispatch_enabled'] is True, 'Capture-only UI cannot complete this scenario'
    target=Path(root['consent_reference_target'])
    assert target.is_absolute() and target.resolve().is_relative_to(r.ROOT) and not target.exists()
    assert set(root['identities'])==set(ROLES)
    for role in ROLES:
        public=root['identities'][role]
        assert public['account']==r.OWN[role] and type(public['device_id']) is int
        assert re.fullmatch('05[0-9a-f]{64}',public['legacy_fingerprint'])
    assert root['identities']['leon']['device_id']==172062497
    assert root['identities']['felix']['device_id']==1228426141
    owner_session(root)
    return root


def android_record(value):
    # The CLI itself creates/records a command UUID once. No forged caller or direct recorder import.
    assert r.sha(A_DIR/'recorder.py')==RECORDER_SHA
    action=value['action'];argv=[sys.executable,'-B',str(A_DIR/'recorder.py'),action]
    if action=='begin':argv.append(value['label'])
    else:
        assert action in ('state','command','result') and value['role']=='nora' and value['transport']=='local-android'
        assert 0<=value['wait']<=30
        argv += [value['recording'],value['tag'],'nora','--transport','local-android','--wait',str(value['wait'])]
        if action=='command':
            assert value['payload'].get('op')!='stop', 'Scenario does not stop a runtime'
            argv.append(json.dumps(value['payload']))
        if action=='result':argv.append(value['id'])
    result=subprocess.run(argv,stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=value.get('wait',0)+45)
    assert result.returncode==0, 'Frozen Nora recorder failed; inspect recorded actual UUID, never resend'
    assert len(result.stdout)<=12*1024**2
    return json.loads(result.stdout)


def normal_owner_consent(write,context,current,room):
    root=context['root_admission'];cfg,session=owner_session(root)
    full={'nora':context['nora_full_jid'],**{role:current[role]['full_jid'] for role in ('leon','felix')}}
    calls={'nora':current['nora']['conference']['call_id'],**{role:current[role]['call']['id'] for role in ('leon','felix')}}
    sids={':'.join(pair):endpoints(current,pair,room)[0] for pair in PAIRS}
    rooms=[c for c in current['nora']['conversations'] if c['jid']==room];assert len(rooms)==1
    scope={'room':room,'states':current,'runtime_profile':'A','session_binding':root['session_binding'],
           'process_cgroups':root['process_cgroups'],'native_bindings':root['native_bindings'],
           'native_recording':context['native_recording'],'identities':root['identities'],
           'full_jids':full,'call_ids':calls,'sids':sids,'conversation_uuids':{'nora':rooms[0]['uuid']},
           'owner_ui_sha256':root['owner_ui_sha256'],'owner_ui_manifest_sha256':root['owner_ui_manifest_sha256']}
    reference=consent_ui.owner_reference(r,write,context['consent_references'],'nora',scope,context['evidence_directory'],seconds=90)
    path=Path(reference['path'])
    assert path.is_file() and not path.is_symlink() and path.stat().st_mode&0o077==0
    assert path.resolve().is_relative_to(r.ROOT) and r.sha(path)==reference['sha256']
    admission=r.read(path)
    assert admission['runtime_profile']=='A' and admission['role']=='nora' and admission['action']=='consent'
    assert admission['room']==room and admission['mode']=='legacy' and admission['batch_id']==session['batch_id']
    assert admission['adapter_sha256']==root['owner_ui_sha256']
    for name in ('session_binding','process_cgroups','native_bindings','native_recording','identities','full_jids','call_ids','sids','conversation_uuids'):
        assert admission[name]==scope[name], 'Fresh Root consent scope changed: '+name
    assert r.sha(HERE/'owner_ui.py')==root['owner_ui_sha256']
    remaining=admission['expires_unix']-time.time();assert 5<=remaining<=240
    argv=[sys.executable,'-B',str(HERE/'owner_ui.py'),'--admission',str(path)]
    write('normal-owner-consent-before-submit.json',{'argv':argv,'admission_sha256':reference['sha256'],
        'actual_scope':scope,'automatic_retry':False,'Nora_Bridge_send_for_this_token':False})
    context['nora_ui_attempt']={'dispatch_intent_recorded':True,'submission_may_have_happened':True,
        'token':r.RUN+':owner-ui-consent:nora:'+admission['nonce'],'admission_path':str(path),
        'admission_sha256':reference['sha256'],'automatic_retry':False}
    child=subprocess.Popen(argv,stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
    try:
        assert r.v1.process_cgroup(child.pid)==r.v1.process_cgroup(os.getpid())
        stdout,stderr=child.communicate(timeout=remaining)
        write('normal-owner-consent-child.json',{'exit':child.returncode,'stdout':stdout.decode(errors='replace')[:16384],
            'stderr':stderr.decode(errors='replace')[:8192],'submission_may_have_happened':True,'automatic_retry':False})
        assert child.returncode==0, 'Normal owner consent partial; inspect same token, never resend'
        value=json.loads(stdout)
        assert value['result']=='OWNER_NORMAL_UI_TWO_NATIVE_DECODED_GROUP_RECEIPTS_PASS'
        assert value['adapter_sha256']==root['owner_ui_sha256']
        assert value['token']==r.RUN+':owner-ui-consent:nora:'+admission['nonce']
        assert value['sender']['uuid'] and value['sender']['status'] in (2,7,8) and value['sender']['encryption']==5
        assert set(value['native_receipts'])=={'leon','felix'}
        for receipt in value['native_receipts'].values():
            assert receipt['actual_body_received_in_owned_test_group'] is True
            assert receipt['body']==value['token'] and receipt['peer'].split('/',1)[0]==room
        result_path=Path(value['path'])/'result.json'
        assert result_path.resolve().is_relative_to(r.ROOT) and r.read(result_path)==value
        write('normal-owner-consent-result.json',value)
        return value
    finally:r.v1.stop_owned(child)  # This child process only, never a guest/native stop operation.


def text_stage(op,write,context,room):
    tokens,deliveries=[],[];text_error=None
    context['nora_ui_attempt']={'dispatch_intent_recorded':False,'submission_may_have_happened':False,'automatic_retry':False}
    nora_row=None
    try:
        op('nora','prepare-room-legacy-once',{'op':'prepare_crypto','room':room,'encryption':'legacy'})
        current={role:op(role,'normal-consent-owner-scope',{'op':'stats'} if role=='nora' else None) for role in ROLES}
        nora_row={'sender':'nora','text':None,'receivers':[],'send_outcome':'normal_UI_not_submitted',
                  'Nora_Bridge_send_for_this_token':False};tokens.append(nora_row)
        consent=normal_owner_consent(write,context,current,room)
        text=consent['token']
        nora_row.update(text=text,receivers=['leon','felix'],send_outcome='normal_UI_sender_and_two_native_receipts',
                        sender_uuid=consent['sender']['uuid'])
        deliveries.extend({'sender':'nora','receiver':peer,'text':text,'receipt':consent['native_receipts'][peer]} for peer in ('leon','felix'))
        for sender in ('leon','felix'):
            op(sender,'prepare-room-legacy-once',{'op':'prepare_crypto','room':room,'encryption':'legacy'})
            text=r.RUN+':legacy3:'+uuid.uuid4().hex+':'+sender
            row={'sender':sender,'text':text,'receivers':[],'send_outcome':'attempting'};tokens.append(row)
            try:op(sender,'send-one-room-token',{'op':'send_text','room':room,'encryption':'legacy','text':text})
            except Exception:row['send_outcome']='no_success_reply_observed';raise
            row['send_outcome']='reply_observed'
            for receiver in ROLES:
                if receiver==sender:continue
                wait_for(lambda receiver=receiver:op(receiver,'observe-decrypted-room-token'),
                         lambda state,receiver=receiver:received(state,receiver,text,room))
                row['receivers'].append(receiver);deliveries.append({'sender':sender,'receiver':receiver,'text':text})
    except Exception as error:
        if nora_row is not None and nora_row['send_outcome']!='normal_UI_sender_and_two_native_receipts' and context['nora_ui_attempt']['submission_may_have_happened']:
            nora_row.update(text=context['nora_ui_attempt'].get('token'),send_outcome='normal_UI_submission_unknown',
                            submission_may_have_happened=True,attempt_reference=context['nora_ui_attempt'])
        text_error={'type':type(error).__name__,'detail':str(error),'product_bug_proven':False,
                    'possible_normal_recipient_consent_not_bypassed':True,'automatic_retry':False}
    return tokens,deliveries,text_error


def scenario(op, write, context, sleep=time.sleep, clock=time.monotonic):
    def observe(tag): return {role: op(role, tag, {'op': 'stats'} if role == 'nora' else None) for role in ROLES}
    def wait(read, ready): return wait_for(read, ready, sleep, clock)
    def media(tag, pairs, room, expected=None):
        def ready(states):
            try:
                for role in set(sum((list(p) for p in pairs), [])):
                    if role == 'nora' and room: assert states[role]['conference']['room'] == room
                    elif role != 'nora': assert enum_is(states[role]['call']['state'], 'IN_PROGRESS') and states[role]['call'].get('room') == room
                for pair in pairs: endpoints(states, pair, room)
                return True
            except (AssertionError, KeyError, TypeError): return False
        wait(lambda: observe(tag + '-readiness'), ready)
        samples = [observe(tag + '-sample1')]; sleep(4); samples.append(observe(tag + '-sample2'))
        if expected is not None:
            for sample in samples: same_three(sample, expected, room, context)
        edges, sids = [], []
        for pair in pairs:
            sid, before = endpoints(samples[0], pair, room); sid2, after = endpoints(samples[1], pair, room)
            assert sid == sid2; sids.append(sid)
            if pair[0] == 'nora':
                for rows in (before, after):
                    observed = rows[pair[1]]['peer']
                    assert context.setdefault('nora_full_jid', observed) == observed, 'Nora resource changed'
            if 'felix' in pair: context['trace_sids'].add(sid)
            for sender, receiver in (pair, tuple(reversed(pair))):
                rx0, _, pcm0 = counters(receiver, before[receiver]); rx1, _, pcm1 = counters(receiver, after[receiver])
                _, tx0, _ = counters(sender, before[sender]); _, tx1, _ = counters(sender, after[sender])
                assert rx1 > rx0 and tx1 > tx0 and pcm1 > pcm0, 'No actual directed RTP/PCM increase'
                edges.append({'sid': sid, 'sender': sender, 'receiver': receiver, 'received_rtp': [rx0, rx1],
                              'sent_rtp': [tx0, tx1], 'received_pcm': [pcm0, pcm1]})
        assert len(set(sids)) == len(pairs)
        write(tag + '-media.json', {'room': room, 'edges': edges, 'directed_edges': len(edges),
              'nora_call_trust': [{c['session_id']: c.get('call_trust_level') for c in s['nora']['calls']} for s in samples],
              'nora_negotiated_media': [{c['session_id']: c.get('media') for c in s['nora']['calls']} for s in samples],
              'native_pair_auth': 'NOT_PROVEN', 'nora_legacy_auth': 'PARTIAL_UNTIL_LEGACY_TRUE_AND_EXACT_NATIVE_DEVICE_FINGERPRINT_LOG_AUDIT'})
        return samples[-1]
    for role, peer in (('nora', 'leon'), ('leon', 'nora')):
        op(role, 'select-direct-legacy-once', {'op': 'prepare_crypto', 'peer': peer, 'encryption': 'legacy'})
    sid = op('nora', 'audio-start-once', {'op': 'start_call', 'peer': 'leon', 'video': False})['session_id']
    context['direct_sid'] = sid
    leon = wait(lambda: op('leon', 'observe-direct-incoming'), lambda s: enum_is((s.get('call') or {}).get('state'), 'RINGING'))
    assert leon['call']['counterpart'].startswith(r.OWN['nora'] + '/')
    context['native']['leon'].add(leon['call']['id'])
    op('leon', 'accept-current-direct-once', {'op': 'accept_call', 'call_id': leon['call']['id']})
    direct = media('original-direct', PAIRS[:1], None)
    assert endpoints(direct, PAIRS[0], None)[0] == sid
    host_id = direct['leon']['call']['id']
    promoted = op('leon', 'add-felix-once', {'op': 'add_participant', 'call_id': host_id, 'peer': 'felix'})
    assert enum_is(promoted['invitation_result'], 'AVAILABLE')
    room = context['room'] = promoted['call']['room']
    for role in ('leon', 'felix'): op(role, 'authorize-actual-invited-room', {'op': 'authorize_room', 'room': room})
    def accept_felix(tag, old_id=None):
        state = wait(lambda: op('felix', tag + '-observe-new-invite'), lambda s: enum_is((s.get('call') or {}).get('state'), 'RINGING'))
        call = state['call']; assert call['invited_room'].split('/', 1)[0] == room and call['id'] != old_id
        assert call['inviter'] == promoted['full_jid'], 'Invitation does not belong to current native Leon'
        if old_id is None: context['first_felix_invite_seen_monotonic'] = clock()
        context['native']['felix'].add(call['id'])
        op('felix', tag + '-accept-exact-id-once', {'op': 'accept_call', 'call_id': call['id']})
    accept_felix('first')
    full = media('first-three', PAIRS, room)
    # Reception is after invitation dispatch/watchdog creation. This is a conservative
    # lower bound, not a claim that the local monotonic clock is the server clock.
    seen = context['first_felix_invite_seen_monotonic']; deadline = seen + 65
    same_three(full, full, room, context)
    while clock() < deadline:
        same_three(observe('watchdog-hold-current-three'), full, room, context)
        sleep(max(0, min(4, deadline - clock())))
    late = media('after-first-invite-watchdog', PAIRS, room, expected=full)
    same_three(late, full, room, context)
    write('watchdog-lifetime.json', {'first_invite_seen_monotonic': seen,
        'final_sample_elapsed_seconds': clock() - seen, 'minimum_hold_seconds': 65,
        'same_room_call_ids_and_three_pair_sids': True, 'all_six_audio_rtp_pcm_directions': True,
        'before_first_felix_leave': True, 'membership_timeout_live_evidence_only': True})
    current = op('felix', 'before-owned-leave'); old_id = current['call']['id']
    assert old_id in context['native']['felix'] and current['call']['room'] == room
    op('felix', 'leave-current-call-once', {'op': 'hangup', 'call_id': old_id})
    wait(lambda: op('felix', 'observe-local-leave'), lambda s: idle('felix', s))
    rest = media('surviving-two', PAIRS[:1], room); assert rest['leon']['call']['id'] == host_id
    assert endpoints(rest,PAIRS[0],room)[0]==endpoints(late,PAIRS[0],room)[0], 'Surviving Nora-Leon SID changed'
    again = op('leon', 'reinvite-felix-once', {'op': 'add_participant', 'call_id': host_id, 'peer': 'felix'})
    assert enum_is(again['invitation_result'], 'AVAILABLE') and again['call']['room'] == room
    accept_felix('reinvite', old_id); media('rejoined-three', PAIRS, room)
    tokens, deliveries, text_error = text_stage(op,write,context,room)
    text_complete = text_error is None and len(tokens) == 3 and len(deliveries) == 6
    write('three-room-tokens.json', {'result': 'PASS' if text_complete else 'PARTIAL', 'room': room,
        'tokens': tokens, 'deliveries': deliveries, 'actual_decrypted_deliveries': len(deliveries),
        'actual_new_tokens_attempted':None if any(x['send_outcome']=='normal_UI_submission_unknown' for x in tokens)
            else sum(x['sender']!='nora' or x['send_outcome']=='normal_UI_sender_and_two_native_receipts' for x in tokens),
        'Nora_UI_submission_unknown':any(x['send_outcome']=='normal_UI_submission_unknown' for x in tokens),
        'Nora_UI_attempt':context.get('nora_ui_attempt'),'error': text_error, 'media_stage_completed_before_text': True})
    write('scenario-result.json', {'result': 'AUDIO_MEDIA_PASS_ROOM_TEXT_' + ('PASS' if text_complete else 'PARTIAL') + '_CALL_AUTH_PARTIAL', 'room': room,
          'room_text_result': 'PASS' if text_complete else 'PARTIAL', 'media_first_explicit_derivation': True,
          'nora_call_auth': 'REQUIRES_ACTUAL_LEGACY_TRUE_AND_EXACT_NATIVE_DEVICE_FINGERPRINT_AUDIT_NOT_ANDROID14234',
          'watchdog_more_than_60s_and_same_three_media': True, 'native_pair_auth': 'NOT_PROVEN', 'rejoin': 'new explicit invitation to same live room',
          'native_rejoin_button_tested': False, 'video_tested': False, 'physical_quality_tested': False})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--owner-admitted-existing-session', action='store_true', required=True)
    parser.add_argument('--root-admission',type=Path,required=True)
    args = parser.parse_args()
    global native_rec,server_control
    root = root_admission(args.root_admission)
    initial,session = owner_session(root)
    binding=session['native_readonly_bindings'];directory=Path(binding['directory'])
    assert r.sha(directory/'native_control.py')==binding['control_sha256']
    assert r.sha(directory/'native_recorder.py')==binding['recorder_sha256']
    spec=_ci.spec_from_file_location('native_control',directory/'native_control.py')
    server_control=_ci.module_from_spec(spec);sys.modules['native_control']=server_control;spec.loader.exec_module(server_control)
    spec=_ci.spec_from_file_location('actual_native_recorder',directory/'native_recorder.py')
    native_rec=_ci.module_from_spec(spec);spec.loader.exec_module(native_rec)
    native_rec.ADMISSION_SHA = binding['admission_sha256']
    admission = server_control.admission(native_rec.ADMISSION_SHA)
    assert admission==binding['owner_admission']
    assert not sys.flags.optimize and os.getpriority(os.PRIO_PROCESS, 0) == 19
    assert r.frozen_files() == FREEZE and r.APKS['main.apk'] == MAIN
    join = r.verify_join_product(); assert join['actual_jvm_tests'] == 616
    settings,nora_session = owner_session(root); assert settings['adb_port'] == 5038 and settings['emulator_port'] == 5580
    assert nora_session['guest_memory_mib'] == 2048 and nora_session['lowram_emulation_variant'] is True
    leon_session = r.read(r._historical.role_config('leon')['state'] / 'live-session.json')
    assert leon_session['state'] == 'stopped' and leon_session['all_owned_processes_stopped']
    for name in ('controller', 'adb', 'emulator'):
        try: assert r.v1.start_ticks(leon_session[name + '_pid']) != leon_session[name + '_start_ticks'], 'Android Leon still alive'
        except (FileNotFoundError, ProcessLookupError): pass
    # Owner independently proves fresh Android-Leon cleanup/native startup/profile retention
    # and captures continuous Nora logs; roles/chat mode never prove native Legacy device binding.
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ-') + uuid.uuid4().hex
    out = r.ROOT / ('legacy-three-audio-media-first-' + stamp); out.mkdir(mode=0o700)
    recordings = {'nora': android_record({'action': 'begin', 'label': 'Legacy-three-audio-adopted-session'}),
                  'native': native_rec.server({'action': 'begin', 'label': 'Legacy-three-audio-native-peers', 'local_recording': True})}
    write = lambda name, value: r.v1.write(out / name, value)
    context = {'room': None, 'direct_sid': None, 'native': {'leon': set(), 'felix': set()}, 'trace_sids': set(),'consent_references':Path(root['consent_reference_target']),'evidence_directory':out,'root_admission':root,'native_recording':recordings['native']['recording']}
    full_jids, trace, cleanup_mode = {}, None, False
    public_observations = {}
    def op(role, tag, payload=None):
        assert role in ROLES; r.v1.resources();owner_session(root)
        assert not payload or payload.get('op')!='stop', 'Runtime/native stop forbidden in this scenario'
        if trace is not None and not cleanup_mode: assert trace.poll() is None, 'Felix trace collector ended'
        q = {'action': 'command' if payload else 'state', 'role': role, 'wait': 30 if payload else 0, 'tag': tag,
             'transport': 'local-android' if role == 'nora' else 'server'}
        if payload:
            q['payload']=payload
            if role!='nora':q['id']=uuid.uuid4().hex
        q['recording'] = recordings['nora' if role == 'nora' else 'native']['recording']
        if role == 'nora': result = android_record(q)
        else: q['local_recording'] = True; result = native_rec.server(q); assert result['controller_exit'] == 0
        z = result['observation']; assert z.get('completed'), 'Uncertain operation: inspect same UUID result, never resend'
        z = z['response']; assert z['run_id'] == r.RUN and z['account'] == r.OWN[role] and (not payload or z['ok'])
        s = z['result'] if role == 'nora' and payload else z
        if role != 'nora':
            assert s['online'] and s['profile_lock_held'] and s['full_jid'].startswith(r.OWN[role] + '/')
            assert full_jids.setdefault(role, s['full_jid']) == s['full_jid']
            assert s['own_omemo_device_id']==root['identities'][role]['device_id']
            assert s['own_public_identity_hex']==root['identities'][role]['legacy_fingerprint']
        elif 'own_device_id' in s:
            assert s['own_device_id']==root['identities']['nora']['device_id']
            assert s['own_legacy_fingerprint']==root['identities']['nora']['legacy_fingerprint']
        return s
    trace_file = (out / 'felix-native-debug.log').open('xb'); Path(trace_file.name).chmod(0o600)
    try:
        for role in ROLES:
            s = op(role, 'admission-online-idle')
            assert s['online'] and idle(role, s)
            assert role != 'nora' or not s['calls'] and not s.get('conference') and not s['pending_invites']
            assert role == 'nora' or s['physical_capture_suppressed'] and s['source'] == 'production-core-omemo-xmpp-libwebrtc'
        for role in ('leon', 'felix'):
            public_observations[role] = public_identity(op(role, 'before-call-public-identities'), role)
        write('before-call-native-public-identities.json', public_observations)
        def limit_trace(): resource.setrlimit(resource.RLIMIT_FSIZE, (8 * 1024**2, 8 * 1024**2))
        since = datetime.datetime.now(datetime.timezone.utc).isoformat()
        remote = 'docker exec docker_dind docker logs --timestamps --follow --since ' + since + ' ' + admission['roles']['felix']['container_id']
        trace = subprocess.Popen(['ssh', '-p', '2654', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=12', server_control.HOST, remote],
            stdin=subprocess.DEVNULL, stdout=trace_file, stderr=subprocess.STDOUT, start_new_session=True, preexec_fn=limit_trace)
        write('admission-and-trace.json', {'freeze_sha256': FREEZE, 'join': join, 'native_full_jids': full_jids,
            'trace_started_unix': time.time(), 'before_first_call': True, 'owner_admission_required': True,
            'native_admission_sha256': native_rec.ADMISSION_SHA, 'native_admission': admission})
        scenario(op, write, context)
        write('layout-not-run.json',{'result':'NOT_RUN','reason':'Historical layout helper calls frozen exact-caller guard; separate owner capture required','layout_pass_claimed':False})
    except BaseException as error:
        write('failure.json', {'type': type(error).__name__, 'detail': str(error), 'no_automatic_retry': True}); raise
    finally:
        cleanup_mode = True
        failures = []
        for role in ROLES:
            try:
                s = op(role, 'cleanup-observe-current-owner')
                if role == 'nora':
                    if s.get('conference') and s['conference']['room'] == context['room']:
                        op(role, 'cleanup-end-current-conference-once', {'op': 'hangup', 'call_id': s['conference']['call_id']})
                    elif any(c['session_id'] == context['direct_sid'] for c in s['calls']):
                        op(role, 'cleanup-end-original-direct-once', {'op': 'hangup', 'session_id': context['direct_sid']})
                elif s.get('call') and s['call']['id'] in context['native'][role] and any(enum_is(s['call']['state'], x) for x in ('IN_PROGRESS', 'RINGING', 'ESTABLISHING')):
                    op(role, 'cleanup-end-observed-native-once', {'op': 'hangup', 'call_id': s['call']['id']})
                wait_for(lambda role=role: op(role, 'cleanup-observe-idle'), lambda state: idle(role, state), seconds=20)
            except BaseException as error: failures.append({'role': role, 'type': type(error).__name__, 'detail': str(error)})
        if trace is not None: r.v1.stop_owned(trace)
        trace_file.close()
        text = Path(trace_file.name).read_text(errors='replace')
        write('cleanup-and-trace.json', {'cleanup_errors': failures, 'trace_sha256': r.sha(Path(trace_file.name)),
            'required_felix_sids': sorted(context['trace_sids']),
            'all_required_sids_in_trace': bool(context['trace_sids']) and all(sid in text for sid in context['trace_sids']),
            'native_pair_auth': 'NOT_PROVEN', 'runtime_or_peers_stopped_by_this_scenario': False})
        print('LEGACY_THREE_AUDIO_EVIDENCE', out, flush=True)
        assert not failures, 'Own-call cleanup incomplete; owner must inspect'


if __name__ == '__main__':
    if sys.flags.optimize: raise RuntimeError('Required assertions must stay enabled')
    def terminate(signum, frame):
        signal.signal(signal.SIGTERM, signal.SIG_IGN); signal.signal(signal.SIGINT, signal.SIG_IGN)
        raise SystemExit('Owned scenario interrupted; end observed calls in finally')
    signal.signal(signal.SIGTERM, terminate); signal.signal(signal.SIGINT, terminate)
    main()

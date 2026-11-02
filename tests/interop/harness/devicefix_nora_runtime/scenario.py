#!/usr/bin/env python3
"""Explicit media-first follow-up; retain >65s/reinvite media proof and separate text PARTIAL."""
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
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))
import runtime as r
import recorder as android_rec
native_rec = server_control = None

ROLES = ('nora', 'leon', 'felix')
PAIRS = (('nora', 'leon'), ('nora', 'felix'), ('leon', 'felix'))
MAIN = '0a8ce212645b5a4876ee7f88122e5065d8f34a4f2a5c212ac91eec4402d0bebe'
FREEZE = r.frozen_files()

import importlib.util as _ci
_cs=_ci.spec_from_file_location('scoped_consent_dispatch','/media/linux/SSD128/xmppwin/local/monocles-dinox-interop-20261015/harness/devicefix_runtime_derivation/consent_dispatch.py')
assert r.sha(Path(_cs.origin))=='5300cbb2521eb4c0693c8956b17ee611a16a41f1fe08f1b165948b8f6b942dac'
consent_ui=_ci.module_from_spec(_cs);_cs.loader.exec_module(consent_ui)


_ls=_ci.spec_from_file_location('actual_layout_capture','/media/linux/SSD128/xmppwin/local/monocles-dinox-interop-20261015/harness/devicefix_runtime_derivation/call_layout_capture.py')
assert r.sha(Path(_ls.origin))=='b112ad2232484bea98d19ed5addc67fa5213ae6d12fe0979e6c7d0c7c5d4a664'
layout_capture=_ci.module_from_spec(_ls);_ls.loader.exec_module(layout_capture)

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
    again = op('leon', 'reinvite-felix-once', {'op': 'add_participant', 'call_id': host_id, 'peer': 'felix'})
    assert enum_is(again['invitation_result'], 'AVAILABLE') and again['call']['room'] == room
    accept_felix('reinvite', old_id); media('rejoined-three', PAIRS, room)
    # This explicit media-first derivative preserves the completed >65s/reinvite
    # media proofs even when normal per-room recipient consent is still missing.
    tokens, deliveries = [], []
    text_error = None
    try:
        op('nora','prepare-room-legacy-once',{'op':'prepare_crypto','room':room,'encryption':'legacy'})
        current=observe('normal-consent-owner-scope')
        ref=consent_ui.owner_reference(r,write,context['consent_references'],'nora',{'room':room,'states':current},context['evidence_directory'])
        session=r.read(r.control_settings('nora')['state']/'live-session.json')
        consent_ui.dispatch(r,write,Path('/media/linux/SSD128/xmppwin/local/monocles-dinox-interop-20261015/harness/legacy3_mixed_consent/normal_mixed_ui_consent.py'),'16b236d8a8f8b5cb645114de03cb02635bc524d56cd1fcfc0b27a8c32c7da942',ref,'nora',room,'legacy',session['batch_id'],mixed=True)
        for sender in ROLES:
            if sender != 'nora':op(sender, 'prepare-room-legacy-once', {'op': 'prepare_crypto', 'room': room, 'encryption': 'legacy'})
            text = r.RUN + ':legacy3:' + uuid.uuid4().hex + ':' + sender
            row = {'sender': sender, 'text': text, 'receivers': [], 'send_outcome': 'attempting'}
            tokens.append(row)
            try:
                op(sender, 'send-one-room-token', {'op': 'send_text', 'room': room, 'encryption': 'legacy', 'text': text})
            except Exception:
                row['send_outcome'] = 'no_success_reply_observed'
                raise
            row['send_outcome'] = 'reply_observed'
            for receiver in ROLES:
                if receiver == sender: continue
                wait(lambda receiver=receiver: op(receiver, 'observe-decrypted-room-token'), lambda state, receiver=receiver: received(state, receiver, text, room))
                row['receivers'].append(receiver); deliveries.append({'sender': sender, 'receiver': receiver, 'text': text})
    except Exception as error:
        text_error = {'type': type(error).__name__, 'detail': str(error), 'product_bug_proven': False,
                      'possible_normal_recipient_consent_not_bypassed': True, 'automatic_retry': False}
    text_complete = text_error is None and len(tokens) == 3 and len(deliveries) == 6
    write('three-room-tokens.json', {'result': 'PASS' if text_complete else 'PARTIAL', 'room': room,
        'tokens': tokens, 'deliveries': deliveries, 'actual_decrypted_deliveries': len(deliveries),
        'actual_new_tokens_attempted': len(tokens), 'error': text_error, 'media_stage_completed_before_text': True})
    write('scenario-result.json', {'result': 'AUDIO_MEDIA_PASS_ROOM_TEXT_' + ('PASS' if text_complete else 'PARTIAL') + '_CALL_AUTH_PARTIAL', 'room': room,
          'room_text_result': 'PASS' if text_complete else 'PARTIAL', 'media_first_explicit_derivation': True,
          'nora_call_auth': 'REQUIRES_ACTUAL_LEGACY_TRUE_AND_EXACT_NATIVE_DEVICE_FINGERPRINT_AUDIT_NOT_ANDROID14234',
          'watchdog_more_than_60s_and_same_three_media': True, 'native_pair_auth': 'NOT_PROVEN', 'rejoin': 'new explicit invitation to same live room',
          'native_rejoin_button_tested': False, 'video_tested': False, 'physical_quality_tested': False})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--owner-admitted-existing-session', action='store_true', required=True)
    parser.add_argument('--native-admission-sha256', required=True)
    parser.add_argument('--consent-references',type=Path,required=True)
    args = parser.parse_args()
    global native_rec,server_control
    initial=r.control_settings('nora');session=r.read(initial['state']/'live-session.json')
    binding=session['native_readonly_bindings'];directory=Path(binding['directory'])
    assert r.sha(directory/'native_control.py')==binding['control_sha256']
    assert r.sha(directory/'native_recorder.py')==binding['recorder_sha256']
    spec=_ci.spec_from_file_location('native_control',directory/'native_control.py')
    server_control=_ci.module_from_spec(spec);sys.modules['native_control']=server_control;spec.loader.exec_module(server_control)
    spec=_ci.spec_from_file_location('actual_native_recorder',directory/'native_recorder.py')
    native_rec=_ci.module_from_spec(spec);spec.loader.exec_module(native_rec)
    assert args.native_admission_sha256==binding['admission_sha256']
    native_rec.ADMISSION_SHA = args.native_admission_sha256
    admission = server_control.admission(native_rec.ADMISSION_SHA)
    assert not sys.flags.optimize and os.getpriority(os.PRIO_PROCESS, 0) == 19
    assert r.frozen_files() == FREEZE and r.APKS['main.apk'] == MAIN
    join = r.verify_join_product(); assert join['actual_jvm_tests'] == 616
    settings = r.control_settings('nora'); assert settings['adb_port'] == 5038 and settings['emulator_port'] == 5580
    nora_session = r.read(settings['state'] / 'live-session.json')
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
    recordings = {'nora': android_rec.record({'action': 'begin', 'label': 'Legacy-three-audio-adopted-session'}),
                  'native': native_rec.server({'action': 'begin', 'label': 'Legacy-three-audio-native-peers', 'local_recording': True})}
    write = lambda name, value: r.v1.write(out / name, value)
    context = {'room': None, 'direct_sid': None, 'native': {'leon': set(), 'felix': set()}, 'trace_sids': set(),'consent_references':args.consent_references,'evidence_directory':out}
    full_jids, trace, cleanup_mode = {}, None, False
    public_observations = {}
    def op(role, tag, payload=None):
        assert role in ROLES; r.v1.resources()
        if trace is not None and not cleanup_mode: assert trace.poll() is None, 'Felix trace collector ended'
        q = {'action': 'command' if payload else 'state', 'role': role, 'wait': 30 if payload else 0, 'tag': tag,
             'transport': 'local-android' if role == 'nora' else 'server'}
        if payload: q.update(id=uuid.uuid4().hex, payload=payload)
        q['recording'] = recordings['nora' if role == 'nora' else 'native']['recording']
        if role == 'nora': result = android_rec.record(q)
        else: q['local_recording'] = True; result = native_rec.server(q); assert result['controller_exit'] == 0
        z = result['observation']; assert z.get('completed'), 'Uncertain operation: inspect same UUID result, never resend'
        z = z['response']; assert z['run_id'] == r.RUN and z['account'] == r.OWN[role] and (not payload or z['ok'])
        s = z['result'] if role == 'nora' and payload else z
        if role != 'nora':
            assert s['online'] and s['profile_lock_held'] and s['full_jid'].startswith(r.OWN[role] + '/')
            assert full_jids.setdefault(role, s['full_jid']) == s['full_jid']
        elif 'own_device_id' in s:
            assert s['own_device_id'] == 12210 and s['own_legacy_fingerprint'] == '05c5d680f9afdc5ccbdc1be2770e03776e03d698fbde371c5622670ec2a1e2b844'
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
        layout_capture.capture(r,op,write,out,context['room'])
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

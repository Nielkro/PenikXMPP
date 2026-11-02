#!/usr/bin/env python3
"""Synthetic in-memory Legacy3 checks only; no peers, files, ADB or SSH."""
import ast
import copy
import json
from pathlib import Path
import sys
from unittest.mock import patch
import legacy_three_audio as test


class Peers:
    def __init__(self, missing_delivery=False, no_native_media=False):
        self.phase = 'idle'; self.now = 0; self.tick = 0; self.invites = 0
        self.commands = []; self.messages = {role: [] for role in test.ROLES}; self.written = {}
        self.missing_delivery = missing_delivery; self.no_native_media = no_native_media
    def sleep(self, seconds): self.now += seconds
    def snapshot(self, role):
        n = self.tick * 100 + 1000; group = self.phase in ('invited', 'three', 'left', 'reinvited', 'again')
        room = 'fixture@conference.test' if group else None
        joined = self.phase in ('three', 'again'); fid = 3 if self.invites == 2 else 2
        full = {x: test.r.OWN[x] + '/fixture' for x in test.ROLES}
        def native(sid, owner, peer):
            return {'sid': sid, 'local': full[owner], 'peer': full[peer], 'room': room,
                    'wire_state': 'ACTIVE', 'peer_connection_state': 'CONNECTED',
                    'capture_running': 0, 'video_in_packets': 0, 'video_out_packets': 0,
                    'audio_in_packets': n, 'audio_out_packets': n if not self.no_native_media or sid != 'lf' else 0,
                    'audio_sink_samples': n * 480}
        def android(sid, peer):
            return {'session_id': sid, 'peer': full[peer], 'muji_room': room, 'end_user_state': 'CONNECTED',
                    'call_trust_level': 1, 'rtp_stats': [
                        {'type': 'inbound-rtp', 'kind': 'audio', 'packetsReceived': n, 'totalSamplesReceived': n * 480},
                        {'type': 'outbound-rtp', 'kind': 'audio', 'packetsSent': n}], 'media': ['AUDIO']}
        common = {'account': test.r.OWN[role], 'online': True}
        if role == 'nora':
            calls = [android('nl', 'leon')] if self.phase != 'idle' else []
            if joined: calls.append(android('nf' + str(fid), 'felix'))
            return {**common, 'calls': calls, 'busy': bool(calls), 'pending_invites': [],
                    'conference': {'room': room, 'call_id': 'group-fixture'} if group else None,
                    'conversations': [{'jid': room, 'test_messages': self.messages[role]}]}
        call = None if self.phase == 'idle' else {'id': 1 if role == 'leon' else fid, 'room': room,
                'state': 'IN_PROGRESS' if role == 'leon' or joined else 'ENDED', 'counterpart': full['nora']}
        if role == 'leon' and self.phase == 'ringing': call['state'] = 'RINGING'
        if role == 'felix' and self.phase in ('invited', 'reinvited'):
            call.update(state='RINGING', invited_room=room, inviter=full['leon'])
        sessions = []
        if role == 'leon' and self.phase != 'idle': sessions.append(native('nl', 'leon', 'nora'))
        if joined:
            sessions.append(native('lf', role, 'felix' if role == 'leon' else 'leon'))
            if role == 'felix': sessions.append(native('nf' + str(fid), 'felix', 'nora'))
        return {**common, 'full_jid': full[role], 'call': call, 'sessions': sessions, 'messages': self.messages[role]}
    def op(self, role, tag, payload=None):
        self.tick += 1
        if payload:
            self.commands.append((role, copy.deepcopy(payload))); op = payload['op']
            if op == 'start_call':
                assert role == 'nora' and self.phase == 'idle' and payload['video'] is False
                self.phase = 'ringing'; return {'session_id': 'nl'}
            if op == 'accept_call':
                assert payload['call_id'] == (1 if role == 'leon' else 3 if self.invites == 2 else 2)
                self.phase = 'direct' if role == 'leon' else 'again' if self.invites == 2 else 'three'
            if op == 'add_participant':
                assert role == 'leon' and payload['call_id'] == 1 and payload['peer'] == 'felix'
                self.invites += 1; assert self.invites <= 2
                self.phase = 'invited' if self.invites == 1 else 'reinvited'
                return {**self.snapshot(role), 'invitation_result': 'AVAILABLE'}
            if op == 'hangup':
                assert role == 'felix' and payload['call_id'] == 2; self.phase = 'left'
            if op == 'send_text':
                for receiver in test.ROLES:
                    if receiver == role or self.missing_delivery and receiver == 'leon': continue
                    self.messages[receiver].append({'text': payload['text'], 'status': 0, 'encryption': 5} if receiver == 'nora'
                        else {'body': payload['text'], 'peer': payload['room'], 'direction': 'received', 'encryption': 'DINO_ENTITIES_ENCRYPTION_OMEMO'})
        return self.snapshot(role)
    def run(self):
        context = {'room': None, 'direct_sid': None, 'native': {'leon': set(), 'felix': set()}, 'trace_sids': set()}
        test.scenario(self.op, self.written.__setitem__, context, self.sleep, lambda: self.now)


def run():
    good = Peers(); good.run()
    assert good.written['first-three-media.json']['directed_edges'] == 6
    assert good.written['rejoined-three-media.json']['directed_edges'] == 6
    assert good.written['surviving-two-media.json']['directed_edges'] == 2
    assert good.written['three-room-tokens.json']['actual_decrypted_deliveries'] == 6
    assert sum(command['op'] == 'start_call' for _, command in good.commands) == 1
    assert sum(command['op'] == 'add_participant' for _, command in good.commands) == 2
    assert len([command for _, command in good.commands if command['op'] == 'send_text']) == 3
    assert good.written['scenario-result.json']['result'].endswith('AUTH_PARTIAL')
    assert good.written['scenario-result.json']['native_pair_auth'] == 'NOT_PROVEN'
    for name, bad in (('AVAILABLE', 'UNAVAILABLE'), ('ACTIVE', 'INACTIVE'), ('CONNECTED', 'DISCONNECTED')):
        assert not test.enum_is(bad, name) and not test.enum_is(test.PREFIX[name] + bad, name)
        assert test.enum_is(name, name) and test.enum_is(test.PREFIX[name] + name, name)
    native = {'call': {'state': 'ENDED'}, 'sessions': [{'wire_state': 'ACTIVE'}]}
    assert not test.idle('felix', native)
    assert not test.idle('felix', {'call': {'state': 'UNKNOWN_INTERMEDIATE'}, 'sessions': []})
    assert test.idle('felix', {'call': {'state': 'ENDED'}, 'sessions': []})
    check = Peers(); check.phase = 'three'; check.invites = 1
    states = {role: check.snapshot(role) for role in test.ROLES}
    states['nora']['calls'][0]['media'] = ['AUDIO', 'VIDEO']
    try: test.endpoints(states, test.PAIRS[0], 'fixture@conference.test')
    except AssertionError: pass
    else: raise AssertionError('Unexpected video admitted in audio-only case')
    replaced = Peers(); actual_op = replaced.op
    def changed_resource(role, tag, payload=None):
        state = actual_op(role, tag, payload)
        if role == 'leon' and tag == 'original-direct-sample2':
            state['sessions'][0]['peer'] = test.r.OWN['nora'] + '/replacement'
        return state
    replaced.op = changed_resource
    try: replaced.run()
    except AssertionError: pass
    else: raise AssertionError('Changed full Nora JID in sample2 admitted')
    for broken in (Peers(missing_delivery=True), Peers(no_native_media=True)):
        try: broken.run()
        except AssertionError: pass
        else: raise AssertionError('Incomplete receiver/media matrix incorrectly passed')
        assert 'scenario-result.json' not in broken.written
        assert broken.invites == 1, 'Do not advance/reinvite after a failed primary assertion'
    with patch.object(test.r, 'frozen_files', return_value='0' * 64), \
         patch.object(test.subprocess, 'Popen', side_effect=AssertionError('Offline process forbidden')), \
         patch.object(sys, 'argv', ['legacy_three_audio.py', '--owner-admitted-existing-session']), \
         patch.object(test.os, 'getpriority', return_value=19), \
         patch.object(test.r, 'control_settings') as real_control:
        try: test.main()
        except AssertionError: pass
        else: raise AssertionError('Wrong frozen baseline accepted')
        real_control.assert_not_called()
    for name in ('legacy_three_audio.py', 'legacy_three_audio_checks.py'):
        ast.parse((Path(__file__).parent / name).read_text())
    return {'result': 'PASS_SYNTHETIC_OFFLINE_ONLY', 'full_stub_scenario': True,
            'six_media_directions_both_group_stages': True, 'three_text_senders_six_stub_deliveries': True,
            'missing_delivery_and_missing_outbound_rtp_rejected': True, 'wrong_baseline_blocks_before_process': True,
            'enum_false_friends_and_nonterminal_or_active_cleanup_rejected': True, 'unexpected_video_rejected': True,
            'changed_nora_full_jid_in_sample2_rejected': True,
            'auth_remains_partial': True, 'runtime_or_ADB_or_SSH_or_peer_actions_executed': False}


if __name__ == '__main__': print(json.dumps(run(), indent=2))

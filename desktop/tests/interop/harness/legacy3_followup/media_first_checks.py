#!/usr/bin/env python3
"""Synthetic follow-up ordering checks; no actual peers, ADB, SSH or commands."""
import ast
import hashlib
import json
from pathlib import Path
import sys
sys.dont_write_bytecode = True
import checks as old_checks
import legacy_three_audio_watchdog_media_first as test


class Peers(old_checks.Peers):
    def run(self):
        context = {'room': None, 'direct_sid': None, 'native': {'leon': set(), 'felix': set()}, 'trace_sids': set()}
        test.scenario(self.op, self.written.__setitem__, context, self.sleep, lambda: self.now)


def run():
    source = Path(__file__).with_name('legacy_three_audio_watchdog.py')
    assert hashlib.sha256(source.read_bytes()).hexdigest() == '0816db405632946f8a6cabe71f9455f11cda0cde7438241c2674e2ba802fbbd3'
    good = Peers(); good.run()
    assert good.written['watchdog-lifetime.json']['final_sample_elapsed_seconds'] >= 65
    assert good.written['scenario-result.json']['room_text_result'] == 'PASS'
    assert good.written['three-room-tokens.json']['actual_decrypted_deliveries'] == 6
    partial = Peers(); partial.missing_delivery = True; partial.run()
    names = list(partial.written)
    assert names.index('after-first-invite-watchdog-media.json') < names.index('rejoined-three-media.json') < names.index('three-room-tokens.json')
    assert partial.written['after-first-invite-watchdog-media.json']['directed_edges'] == 6
    assert partial.written['rejoined-three-media.json']['directed_edges'] == 6
    assert partial.written['three-room-tokens.json']['result'] == 'PARTIAL'
    assert partial.written['three-room-tokens.json']['actual_decrypted_deliveries'] < 6
    assert partial.written['scenario-result.json']['result'] == 'AUDIO_MEDIA_PASS_ROOM_TEXT_PARTIAL_CALL_AUTH_PARTIAL'
    assert partial.invites == 2 and sum(q['op'] == 'send_text' for _, q in partial.commands) == 1
    assert partial.written['scenario-result.json']['native_pair_auth'] == 'NOT_PROVEN'
    lost = Peers()
    original_op = lost.op
    def lost_reply(role, tag, payload=None):
        result = original_op(role, tag, payload)
        if payload and payload['op'] == 'send_text':
            raise RuntimeError('synthetic send result unavailable; no retry permitted')
        return result
    lost.op = lost_reply
    lost.run()
    text_result = lost.written['three-room-tokens.json']
    assert text_result['result'] == 'PARTIAL' and text_result['actual_new_tokens_attempted'] == 1
    assert text_result['tokens'][0]['send_outcome'] == 'no_success_reply_observed'
    assert sum(q['op'] == 'send_text' for _, q in lost.commands) == 1
    assert lost.written['rejoined-three-media.json']['directed_edges'] == 6
    for kind in ('removed', 'sid', 'participants'):
        broken = Peers(kind)
        try: broken.run()
        except AssertionError: pass
        else: raise AssertionError('Invalid media became a text-only partial success')
        assert broken.invites == 1 and 'scenario-result.json' not in broken.written
        assert not any(q['op'] == 'send_text' for _, q in broken.commands)
    for name in ('legacy_three_audio_watchdog_media_first.py','media_first_checks.py'):
        ast.parse(Path(__file__).with_name(name).read_text())
    return {'result':'PASS_SYNTHETIC_ONLY','groups':4,'actual_more_than_65s_media_and_reinvite_required_before_text':True,
            'text_failure_keeps_independent_media_and_explicit_PARTIAL':True,'broken_media_never_hidden_by_text_partial':True,
            'attempt_recorded_before_submit_and_unknown_reply_never_resubmitted':True,
            'native_auth_not_proven_scope_preserved':True,'runtime_or_ADB_or_SSH_or_account_action_executed':False}


if __name__ == '__main__': print(json.dumps(run(),indent=2))

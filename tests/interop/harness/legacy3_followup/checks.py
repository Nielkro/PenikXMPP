#!/usr/bin/env python3
"""Synthetic offline checks only: no peers, processes, SSH, ADB or runtime."""
import ast
import copy
import hashlib
import json
from pathlib import Path
import sys
from unittest.mock import patch
from types import SimpleNamespace
from io import StringIO

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import legacy_three_audio_checks as prior
import legacy_three_audio_watchdog as test
import native_control


class Peers(prior.Peers):
    def __init__(self, break_kind=None):
        super().__init__(); self.break_kind = break_kind; self.first_invite = None
    def snapshot(self, role):
        s = super().snapshot(role)
        if role == 'nora' and s.get('conference'):
            s['conference']['participants'] = [test.r.OWN[x] + '/fixture' for x in ('leon', 'felix')]
        elif role != 'nora' and s.get('call'): s['call']['peers'] = 2
        if self.break_kind and self.first_invite is not None and self.now - self.first_invite >= 60:
            if self.break_kind == 'removed' and role == 'felix': s['call']['state'] = 'ENDED'
            if self.break_kind == 'sid' and role == 'leon':
                for row in s['sessions']:
                    if row['sid'] == 'lf': row['sid'] = 'replacement'
            if self.break_kind == 'participants' and role == 'nora': s['conference']['participants'] = []
        return s
    def op(self, role, tag, payload=None):
        state = super().op(role, tag, payload)
        if tag == 'first-observe-new-invite': self.first_invite = self.now
        if payload and payload['op'] == 'hangup':
            assert self.now - self.first_invite >= 65, 'Felix left before watchdog proof'
        return state
    def run(self):
        context = {'room': None, 'direct_sid': None, 'native': {'leon': set(), 'felix': set()}, 'trace_sids': set()}
        test.scenario(self.op, self.written.__setitem__, context, self.sleep, lambda: self.now)


def fails(fn):
    try: fn()
    except (AssertionError, KeyError, ValueError): return
    raise AssertionError('Negative fixture was incorrectly admitted')


def run():
    assert native_control.ORIGINAL == HERE / 'server_control_base.py'
    assert hashlib.sha256(native_control.ORIGINAL.read_bytes()).hexdigest() == '0fe86a2329e77b2f35b804596f900a0d4341d7d2640d8264342cb8e94bbc6555'
    original = HERE.parent / 'legacy_three_audio.py'
    assert hashlib.sha256(original.read_bytes()).hexdigest() == '8632e10bff08f3038980973cfd4da0102b2be50265f2079701cb4ff9e069b70f'
    p = Peers(); p.run()
    assert p.written['watchdog-lifetime.json']['final_sample_elapsed_seconds'] >= 65
    assert p.written['after-first-invite-watchdog-media.json']['directed_edges'] == 6
    assert p.written['rejoined-three-media.json']['directed_edges'] == 6
    assert p.written['three-room-tokens.json']['actual_decrypted_deliveries'] == 6
    assert sum(q['op'] == 'add_participant' for _, q in p.commands) == 2
    assert sum(q['op'] == 'start_call' for _, q in p.commands) == 1
    for kind in ('removed', 'sid', 'participants'):
        broken = Peers(kind); fails(broken.run)
        assert broken.invites == 1 and 'scenario-result.json' not in broken.written
    admission = native_control.admission(native_control.ADMISSION)
    fails(lambda: native_control.admission('0' * 64))
    row = admission['roles']['felix']
    info = {'Id': row['container_id'], 'Name': '/' + row['name'], 'State': {'Running': True},
            'Config': {'Labels': {'im.dinox.interop.run': test.r.RUN}, 'Cmd': row['cmd'], 'User': '1000:1000'},
            'HostConfig': {'ReadonlyRootfs': True}, 'Mounts': [{'Destination': '/driver-wirefix', 'RW': False}]}
    native_control.check_container(info, row, 'felix')
    # Exercise actual dispatch construction: outer AND inner exec must keep stdin.
    request = {'action':'state','role':'felix','transport':'server','wait':0,
               'native_admission_sha256':native_control.ADMISSION}
    result = SimpleNamespace(stdout=json.dumps({'completed':True,'run_id':test.r.RUN}),returncode=0)
    with patch.object(native_control.subprocess,'check_output',return_value=json.dumps([info])) as inspected, \
         patch.object(native_control.subprocess,'run',return_value=result) as sent, patch('builtins.print'):
        assert native_control.server(request) == 0
    assert inspected.call_args.args[0] == ['docker','exec','-i','docker_dind','docker','inspect',row['container_id']]
    argv = sent.call_args.args[0]
    assert argv[:10] == ['docker','exec','-i','docker_dind','docker','exec','-i','--user','1000:1000',row['container_id']]
    assert argv[10:] == ['python3','-c',native_control.base.CONTROL_CODE]
    assert json.loads(sent.call_args.kwargs['input']) == request
    assert sent.call_args.kwargs['text'] is True and sent.call_args.kwargs['timeout'] == 45
    stop = {'action':'command','role':'felix','transport':'server','wait':0,'id':'a'*32,
            'native_admission_sha256':native_control.ADMISSION,'payload':{'op':'stop'}}
    with patch.object(native_control.subprocess,'check_output') as inspected, \
         patch.object(native_control.subprocess,'run') as sent, patch.object(native_control,'admission') as admitted:
        fails(lambda: native_control.server(stop))  # Direct remote dispatch rejects before inspect/exec.
        for remote in (native_control.REMOTE, str(Path(native_control.__file__).resolve())):
            with patch.object(native_control,'REMOTE',remote),patch.object(sys,'argv',['native_control.py','--stdin']), \
                 patch.object(sys,'stdin',StringIO(json.dumps(stop))),patch('builtins.print') as printed:
                assert native_control.main() == 2  # Both local forward and remote entry reject.
                response=json.loads(printed.call_args.args[0])
                assert response['error_type']=='UnsafeDriverStop' and response['submission_outcome_unknown'] is False
        inspected.assert_not_called();sent.assert_not_called();admitted.assert_not_called()
    for branch, key, value in ((None, 'Id', '0' * 64), ('State', 'Running', False),
                               ('Config', 'Cmd', ['/driver-v2/server_entry.sh', 'felix']),
                               ('Config', 'User', '0'), ('HostConfig', 'ReadonlyRootfs', False)):
        bad = copy.deepcopy(info); (bad[branch] if branch else bad)[key] = value
        fails(lambda: native_control.check_container(bad, row, 'felix'))
    bad = copy.deepcopy(info); bad['Mounts'][0]['RW'] = True
    fails(lambda: native_control.check_container(bad, row, 'felix'))
    state = {'account': test.r.OWN['felix'], 'full_jid': test.r.OWN['felix'] + '/fixture',
             'own_omemo_device_id': 123, 'own_public_identity_hex': '05' + 'a' * 64, 'contacts': []}
    assert test.public_identity(state, 'felix')['call_auth_proven_by_this_observation'] is False
    bad = dict(state, own_public_identity_hex='not-a-public-key'); fails(lambda: test.public_identity(bad, 'felix'))
    bad = dict(state, contacts=[{'jid': 'outside@invalid.test'}]); fails(lambda: test.public_identity(bad, 'felix'))
    for name in ('legacy_three_audio_watchdog.py', 'native_control.py', 'native_recorder.py', 'server_control_base.py', 'checks.py'):
        ast.parse((HERE / name).read_text())
    return {'result': 'PASS_SYNTHETIC_OFFLINE_ONLY', 'groups': 7,
            'more_than_65s_before_first_leave': True, 'same_call_and_pair_sids_six_audio_edges': True,
            'three_tokens_six_deliveries_and_explicit_reinvite_preserved': True,
            'removed_or_replaced_or_missing_participant_rejected': True,
            'exact_actual_container_id_cmd_readonly_and_admission_guards': True,
            'actual_mocked_nested_exec_argv_and_JSON_stdin_checked': True,
            'driver_stop_rejected_local_remote_before_any_subprocess_or_submission': True,
            'native_public_identity_only_no_auth_claim': True,
            'historical_controller_unchanged': True, 'runtime_processes_or_ADB_or_SSH_executed': False}


if __name__ == '__main__': print(json.dumps(run(), indent=2))

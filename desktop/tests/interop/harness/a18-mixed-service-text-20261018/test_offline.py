#!/usr/bin/env python3
"""Synthetic scope and extracted-function checks; no historical runtime imports."""
import ast
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import types

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('offline_room_scope', HERE / 'room_scope.py')
scope = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scope)
sha = lambda path: hashlib.sha256(Path(path).read_bytes()).hexdigest()


def function(path, name, last=False):
    nodes = [n for n in ast.parse(Path(path).read_text()).body if isinstance(n, ast.FunctionDef) and n.name == name]
    return nodes[-1] if last else nodes[0]


def execute_node(node, namespace):
    exec(compile(ast.Module(body=[node], type_ignores=[]), '<synthetic-extracted-function>', 'exec'), namespace)
    return namespace[node.name]


def main():
    accepted, rejected = [], []
    now = 2000.0
    with tempfile.TemporaryDirectory(prefix='offline-fixture-', dir=HERE) as folder_name:
        folder = Path(folder_name)
        os.chmod(folder, 0o700)
        def artifact(name, value):
            path = folder / name
            path.write_text(json.dumps(value))
            path.chmod(0o600)
            return {'path': str(path), 'sha256': sha(path)}
        ctx = {
            'run_id': scope.RUN, 'role': 'nora', 'account': scope.OWN['nora'],
            'runtime_freeze_sha256': 'a' * 64, 'runtime_inputs_sha256': 'b' * 64,
            'apk_sha256': {'main.apk': 'c' * 64, 'android-test.apk': 'd' * 64},
            'batch_id': 'e' * 32,
            'session_binding': {key: (100 if key.endswith('_pid') else 200) for key in scope.SESSION_KEYS},
            'process_cgroups': {role: '/synthetic/slice/' + role for role in ('controller', 'adb', 'emulator')},
            'native_readonly_bindings': {'synthetic_exact_container_pair': 'f' * 64},
            'batch_deadline_unix': 2400.0, 'runtime_root': str(folder), 'derivation_root': str(folder),
        }
        receipt = {'run_id': scope.RUN, 'account': scope.OWN['nora'], 'allowed_rooms': [scope.ROOM],
                   'session_binding': ctx['session_binding'], 'validated_write_readback_equal': True, 'observed_unix': 1999.0}
        receipt_ref = artifact('room-receipt.json', receipt)
        admission = {
            'schema_version': 1, 'operation': 'nora-persistent-room-service-controller',
            'runtime_profile': 'A18', 'run_id': scope.RUN, 'role': 'nora', 'account': scope.OWN['nora'],
            'accounts': scope.OWN, 'room': scope.ROOM, 'conversation_uuid': scope.CONVERSATION_UUID,
            'created_unix': 1999.0, 'expires_unix': 2200.0, 'fixture_room_authorization': receipt_ref,
            **{key: ctx[key] for key in ('runtime_freeze_sha256', 'runtime_inputs_sha256', 'apk_sha256', 'batch_id', 'session_binding', 'process_cgroups', 'native_readonly_bindings')},
        }
        admission_ref = artifact('room-admission.json', admission)
        config = {'run_id': scope.RUN, 'jid': scope.OWN['nora'],
                  'allowed_jids': [scope.OWN['leon'], scope.OWN['felix']],
                  'allowed_rooms': [scope.ROOM], 'password': 'SYNTHETIC_NOT_A_CREDENTIAL'}
        request = {'action': 'state', 'role': 'nora', 'transport': 'local-android', 'room_admission': admission_ref}

        def ok(label, cfg=config, req=request, context=ctx, at=now):
            scope.validate_control_config(cfg, req, context, at)
            accepted.append(label)

        def no(label, cfg=None, req=None, context=None, at=now):
            try:
                scope.validate_control_config(config if cfg is None else cfg, request if req is None else req,
                                              ctx if context is None else context, at)
            except (scope.ScopeError, OSError, ValueError, TypeError, KeyError):
                rejected.append(label)
            else:
                raise AssertionError('Unexpected acceptance: ' + label)

        ok('fresh actual-shaped scoped state')
        bootstrap = copy.deepcopy(config); bootstrap['allowed_rooms'] = []
        bootstrap_request = {k: v for k, v in request.items() if k != 'room_admission'}
        ok('empty startup room state', bootstrap, bootstrap_request)
        prepare = {**request, 'action': 'command', 'payload': {'op': 'prepare_crypto', 'room': scope.ROOM, 'encryption': 'legacy'}}
        send = {**request, 'action': 'command', 'payload': {'op': 'send_text', 'room': scope.ROOM, 'encryption': 'legacy',
                                                         'text': scope.RUN + ':persistent-service:nora:' + '1' * 32}}
        ok('fresh exact legacy prepare', req=prepare)
        ok('fresh exact one sender token', req=send)
        ok('same pinned grant continues past initial freshness within explicit expiry', at=2150.0)
        try:
            scope.validate_admission(admission, ctx, 2150.0, at_entry=True)
        except scope.ScopeError:
            rejected.append('late first case entry cannot reuse grant freshness')
        else:
            raise AssertionError('Stale first entry accepted')
        ok('normal stop after short room receipt expiry', req={**bootstrap_request, 'action': 'command', 'payload': {'op': 'stop'}}, at=2250.0)

        for label, edit in (
            ('foreign room', lambda x: x.update(allowed_rooms=['foreign@example.test'])),
            ('extra room', lambda x: x['allowed_rooms'].append('foreign@example.test')),
            ('wrong account', lambda x: x.update(jid=scope.OWN['leon'])),
            ('wrong run', lambda x: x.update(run_id='wrong-run')),
            ('foreign peer', lambda x: x['allowed_jids'].__setitem__(0, 'foreign@example.test')),
            ('duplicate peers', lambda x: x.update(allowed_jids=[scope.OWN['leon']] * 2)),
        ):
            changed = copy.deepcopy(config); edit(changed); no(label, cfg=changed)
        no('missing admission', req=bootstrap_request)
        no('empty rooms cannot send', cfg=bootstrap, req=send)
        no('wrong transport', req={**request, 'transport': 'server'})
        no('wrong controller role', req={**request, 'role': 'leon'})
        no('expired admission', at=2200.0)
        no('future admission timestamp', at=1998.0)
        for key, change in (
            ('runtime_freeze_sha256', '0' * 64), ('runtime_inputs_sha256', '0' * 64),
            ('batch_id', '0' * 32), ('apk_sha256', {}), ('native_readonly_bindings', {}),
            ('session_binding', {}), ('process_cgroups', {}),
            ('batch_deadline_unix', 2250.0),
        ):
            changed = copy.deepcopy(ctx); changed[key] = change; no('changed current ' + key, context=changed)
        for op in ('set_trust', 'join_room', 'start_call', 'start_group_call', 'authorize_room'):
            no('forbidden operation ' + op, req={**request, 'action': 'command', 'payload': {'op': op}})
        changed = copy.deepcopy(send); changed['payload']['room'] = 'foreign@example.test'; no('send wrong room', req=changed)
        changed = copy.deepcopy(send); changed['payload']['encryption'] = 'omemo2'; no('send wrong mode', req=changed)
        changed = copy.deepcopy(send); changed['payload']['peer'] = scope.OWN['leon']; no('hidden direct target', req=changed)
        changed = copy.deepcopy(send); changed['payload']['text'] = 'arbitrary text'; no('wrong sender token', req=changed)
        no('stop hidden room action', req={**request, 'action': 'command', 'payload': {'op': 'stop', 'room': scope.ROOM}})

        bad_ref = {**admission_ref, 'sha256': '0' * 64}
        no('stale admission bytes', req={**request, 'room_admission': bad_ref})
        no('absent admission', req={**request, 'room_admission': {**admission_ref, 'path': str(folder / 'absent')}})
        for label, edit in (
            ('admission wrong room', lambda x: x.update(room='wrong@example.test')),
            ('admission wrong account', lambda x: x.update(account=scope.OWN['leon'])),
            ('admission wrong session', lambda x: x['session_binding'].update(controller_pid=999)),
            ('absent room receipt', lambda x: x.update(fixture_room_authorization={**receipt_ref, 'path': str(folder / 'absent-receipt')})),
            ('stale room receipt bytes', lambda x: x.update(fixture_room_authorization={**receipt_ref, 'sha256': '0' * 64})),
        ):
            changed = copy.deepcopy(admission); edit(changed)
            no(label, req={**request, 'room_admission': artifact('changed-admission.json', changed)})
        for label, edit in (
            ('old readback', lambda x: x.update(observed_unix=1878.0)),
            ('wrong readback account', lambda x: x.update(account=scope.OWN['felix'])),
            ('wrong readback session', lambda x: x['session_binding'].update(adb_start_ticks=999)),
            ('unconfirmed readback', lambda x: x.update(validated_write_readback_equal=False)),
            ('wrong readback room', lambda x: x.update(allowed_rooms=[])),
        ):
            changed_receipt = copy.deepcopy(receipt); edit(changed_receipt)
            changed = copy.deepcopy(admission); changed['fixture_room_authorization'] = artifact('changed-receipt.json', changed_receipt)
            no(label, req={**request, 'room_admission': artifact('changed-admission.json', changed)})
        public = Path(admission_ref['path']); public.chmod(0o644)
        no('public admission file')
        public.chmod(0o600)
        link = folder / 'admission-link.json'; link.symlink_to(public)
        no('symlink admission', req={**request, 'room_admission': {**admission_ref, 'path': str(link)}})
        # Rejections above only read files; no once-claim exists yet.
        assert not (folder / 'runtime-state').exists()
        scope.claim_scenario_once(ctx, admission_ref, {'sha256': '2' * 64})
        accepted.append('durable once-per-batch claim')
        try:
            scope.claim_scenario_once(ctx, admission_ref, {'sha256': '3' * 64})
        except FileExistsError:
            rejected.append('second execution same batch with new scenario admission')
        else:
            raise AssertionError('Reused batch claim')

    original = Path('/media/linux/SSD128/xmppwin/local/monocles-dinox-interop-20261015/harness/devicefix_nora_runtime')
    old_startup = function(original / 'runtime.py', 'validate_private_config')
    new_startup = function(HERE / 'runtime.py', 'validate_private_config')
    assert ast.dump(old_startup, include_attributes=False) == ast.dump(new_startup, include_attributes=False)
    startup = execute_node(new_startup, {'OWN': scope.OWN, 'RUN': scope.RUN})
    startup('nora', bootstrap)
    try:
        startup('nora', config)
    except AssertionError:
        rejected.append('startup still rejects singleton room')
    else:
        raise AssertionError('Startup room policy changed')
    accepted.append('startup validator AST byte-equivalent semantics')

    fake_sys = types.SimpleNamespace(argv=[str(HERE / 'recorder.py')])
    call = execute_node(function(HERE / 'runtime.py', 'control_settings', last=True), {
        '_old_control_settings': lambda role: {'state': HERE},
        'read': lambda path: {'batch_deadline_unix': 3000}, 'time': types.SimpleNamespace(time=lambda: 2000),
        'sys': fake_sys, 'Path': Path, 'HERE': HERE,
    })
    call('nora'); accepted.append('explicit new recorder caller')
    fake_sys.argv = [str(HERE / 'test_offline.py')]
    try:
        call('nora')
    except AssertionError:
        rejected.append('unapproved caller')
    else:
        raise AssertionError('Caller gate weakened')

    # Extract the real derived control() and execute it with an in-memory backend.
    # An invalid room must fail before any inbox submission; a valid one submits once.
    calls = []
    class FakeAndroid:
        scope_request = scope_config = None
        def __init__(self, role): pass
        def read(self, name):
            return config if name == 'config.json' else {'run_id': scope.RUN, 'account': scope.OWN['nora'], 'id': '4' * 32}
        def submit(self, identifier, payload): calls.append((identifier, payload))
    runtime = types.SimpleNamespace(
        RUN=scope.RUN, OWN=scope.OWN, HERE=HERE,
        validate_control_config=lambda role, value, request: scope.require(value.get('allowed_rooms') == [scope.ROOM], 'integration room'),
    )
    ns = {'validate': lambda value: value, 'runtime': runtime, 'Android': FakeAndroid,
          'normalize': lambda value, cfg: value['payload'], 'redact': lambda value, cfg: value,
          'time': types.SimpleNamespace(monotonic=lambda: 2000)}
    control = execute_node(function(HERE / 'control.py', 'control'), ns)
    original_config = config.copy()
    config['allowed_rooms'] = ['wrong@example.test']
    try:
        control({'role': 'nora', 'transport': 'local-android', 'action': 'command', 'id': '4' * 32, 'payload': {'op': 'send_text'}})
    except scope.ScopeError:
        rejected.append('real control rejects before submit')
    else:
        raise AssertionError('Invalid integration room accepted')
    assert calls == []
    config.clear(); config.update(original_config)
    control({'role': 'nora', 'transport': 'local-android', 'action': 'command', 'id': '4' * 32, 'payload': {'op': 'send_text'}})
    assert len(calls) == 1
    accepted.append('real control exactly one backend submission')

    # The actual before-mutation claim must dominate the first recorder/command.
    scenario_main = function(HERE / 'scenario.py', 'main')
    text = ast.unparse(scenario_main)
    assert text.index('claim_scenario_once(') < text.index("'action': 'begin'") < text.index("'actual-persistent-initial-idle'")
    assert "room_control_admission" in (HERE / 'service_support.py').read_text().lower() or 'ROOM_CONTROL_ADMISSION' in (HERE / 'service_support.py').read_text()
    for name in ('idle_identity', 'fixture_authorization', 'validate_scope'):
        old = function(original.parent / 'resume-completion-plan-20261016T190157Z/ui-owner-resume/persistent-service-text/persistent_service_text.py', name)
        new = function(HERE / 'scenario.py', name)
        assert ast.dump(old, include_attributes=False) == ast.dump(new, include_attributes=False)
    accepted.append('existing identity trust and room assertions unchanged')
    manifest = json.loads((HERE / 'source-manifest.json').read_text())
    for path, item in manifest['inputs'].items():
        assert sha(path) == item['sha256']
    for name, digest in manifest['files_sha256'].items():
        assert sha(HERE / name) == digest
    accepted.append('all original and generated pins match')
    report = {
        'result': 'OFFLINE_PASS_SYNTHETIC_ONLY', 'accepted_count': len(accepted), 'rejected_count': len(rejected),
        'accepted': accepted, 'rejected': rejected,
        'no_lab_runtime_import_no_ADB_SSH_build_download_or_profile_access': True,
        'freeze_sha256': sha(HERE / 'freeze.json'), 'manifest_sha256': sha(HERE / 'source-manifest.json'),
        'test_source_sha256': sha(__file__),
    }
    (HERE / 'offline-checks.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({key: report[key] for key in ('result', 'accepted_count', 'rejected_count', 'freeze_sha256', 'manifest_sha256')}))


if __name__ == '__main__':
    main()

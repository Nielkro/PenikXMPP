#!/usr/bin/env python3
"""Pure controller fixtures; never start Android, ADB, accounts or networking."""
import json
from pathlib import Path
import sys
import local_android_runtime as runtime
import server_control


def rejected(function, *args, **kwargs):
    try:
        function(*args, **kwargs)
    except (AssertionError, KeyError, TypeError):
        return
    raise AssertionError('Invalid readiness was accepted')


def run():
    account = 'nora.schneider.interop.de.71115b@dinox.im'
    ready = {'run_id': runtime.RUN, 'account': account, 'service_bound': True}
    options = {'alive': True, 'deadline': 2, 'now': 1}
    checks = []
    for raw in (b'', b' \n', b'{', b'{"run_id":', b'{"name":"\xc3'):
        assert runtime.bridge_ready(raw, account, **options) is None
    checks.append('missing-empty-partial-json-and-utf8-stay-pending')
    assert runtime.bridge_ready(json.dumps(ready), account, **options) == ready
    checks.append('complete-exact-identity-and-service-bound-accepted')
    for field in ('run_id', 'account'):
        rejected(runtime.bridge_ready, json.dumps({**ready, field: 'wrong'}), account, **options)
    for extra in ({'ok': False}, {'error': 'failed'}, {'error_type': 'BridgeFailure'}, {'service_bound': False}):
        rejected(runtime.bridge_ready, json.dumps({**ready, **extra}), account, **options)
    rejected(runtime.bridge_ready, '[]', account, **options)
    checks.append('wrong-scope-complete-error-and-unbound-service-fail-immediately')
    rejected(runtime.bridge_ready, json.dumps(ready), account, alive=False, deadline=2, now=1)
    for raw in ('', json.dumps(ready)):
        rejected(runtime.bridge_ready, raw, account, alive=True, deadline=2, now=2)
    checks.append('dead-child-and-deadline-reject-even-otherwise-valid-or-empty-read')

    scope = {'__name__': 'pure_control_readiness_fixture'}
    exec(compile(server_control.CONTROL_CODE, '<actual-control-code>', 'exec'), scope)
    backend = object.__new__(scope['Android'])
    backend.exists = lambda name: True
    for raw in ('', ' ', '{"run_id":'):
        backend.call = lambda *args, value=raw: value
        assert backend.read('state.json') is None
    backend.call = lambda *args: json.dumps(ready)
    assert backend.read('state.json') == ready
    checks.append('actual-first-android-control-reader-defers-only-unparsed-state')
    config = {'run_id': runtime.RUN, 'jid': account,
              'allowed_jids': ['leon.fischer.interop.de.71115b@dinox.im']}
    scope['Android'] = lambda: backend
    for state in ({**ready, 'account': 'wrong'}, {**ready, 'run_id': 'wrong'}):
        backend.read = lambda name, value=state: config if name == 'config.json' else value
        try:
            scope['control']({'role': 'nora', 'action': 'state', 'wait': 0})
        except scope['ControlError']:
            pass
        else:
            raise AssertionError('Complete wrong-scope control response was accepted')
    checks.append('actual-control-account-and-run-policy-remain-hard-errors')
    return {'setup_revision': 3, 'pure_fixture_groups_passed': checks,
            'runtime_started': False, 'network_used': False, 'android_or_interop_pass_claimed': False}


if __name__ == '__main__':
    print(json.dumps(run(), indent=2))

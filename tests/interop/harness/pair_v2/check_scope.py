#!/usr/bin/env python3
"""Pure scope/parser checks only: no subprocess, socket, device or runtime start."""
import hashlib
import json
import os
from pathlib import Path
import control
import runtime


def rejects(function, *args):
    try: function(*args)
    except (AssertionError, KeyError, TypeError): return
    raise AssertionError('An invalid scope was accepted')


def run():
    checks = []
    for role in ('nora', 'leon'):
        value = {'action': 'state', 'role': role, 'transport': 'local-android', 'wait': 0}
        assert control.validate(value) is value
        checks.append(role + '-local-transport')
    rejects(control.validate, {'action': 'state', 'role': 'felix', 'transport': 'local-android'})
    for role in ('nora', 'leon'):
        rejects(control.validate, {'action': 'state', 'role': role, 'transport': 'server'})
    assert control.validate({'action': 'state', 'role': 'felix', 'transport': 'server'})
    checks.append('no-implicit-server-or-foreign-local-role')
    config = {'run_id': runtime.RUN, 'jid': runtime.OWN['leon'], 'password': 'parser-only-placeholder',
              'allowed_jids': [runtime.OWN['nora']], 'allowed_rooms': []}
    request = {'action': 'command', 'role': 'leon', 'transport': 'local-android', 'id': 'a' * 32,
               'payload': {'op': 'contact', 'peer': 'nora'}, 'wait': 0}
    assert control.normalize(control.validate(request), config)['peer'] == runtime.OWN['nora']
    for peer in ('foreign@example.test', runtime.OWN['leon'], runtime.OWN['nora'] + '/phone', 'nora\n'):
        bad = {**request, 'payload': {'op': 'contact', 'peer': peer}}
        rejects(control.normalize, bad, config)
    checks.append('exact-bare-peer-allowlist')
    for op in ('trust_fingerprint', 'unknown; command'):
        rejects(control.validate, {**request, 'payload': {'op': op}})
    for payload in ({'op': 'stop', 'run_id': runtime.RUN}, {'op': 'stop', 'id': 'b' * 32},
                    {'op': 'stop', 'nested': {'password': 'not-a-command'}}):
        rejects(control.validate, {**request, 'payload': payload})
    checks.append('no-host-trust-private-or-reserved-command')
    uncertain = control.failure(request, RuntimeError('publication followed by cleanup failure'))
    assert uncertain['role'] == 'leon' and uncertain['id'] == request['id'] and uncertain['run_id'] == runtime.RUN
    assert uncertain['submission_outcome_unknown'] is True and uncertain['automatic_retry'] is False
    nora, leon = runtime.role_config('nora'), runtime.role_config('leon')
    assert nora['avd_home'] == runtime.ROOT / 'avd'
    assert leon['avd_home'].is_relative_to(runtime.STATE / 'leon')
    assert nora['avd_home'] != leon['avd_home'] and nora['home'] != leon['home']
    assert (nora['adb_port'], leon['adb_port']) == (5038, 5039)
    assert (nora['emulator_port'], leon['emulator_port']) == (5580, 5582)
    assert (nora['serial'], leon['serial']) == ('emulator-5580', 'emulator-5582')
    checks.append('distinct-avd-userdata-home-adb-emulator')
    for role, port in (('nora', '5038'), ('leon', '5039')):
        inherited_opts = os.environ.get('AVDMANAGER_OPTS')
        try:
            os.environ['AVDMANAGER_OPTS'] = '-Dcom.android.sdkmanager.toolsdir=/unowned-sdk'
            env = runtime.environment(role)
        finally:
            if inherited_opts is None: os.environ.pop('AVDMANAGER_OPTS', None)
            else: os.environ['AVDMANAGER_OPTS'] = inherited_opts
        assert env['AVDMANAGER_OPTS'] == '-Dcom.android.sdkmanager.toolsdir=' + str(runtime.ROOT / 'sdk/cmdline-tools/external')
        assert env['ANDROID_ADB_SERVER_PORT'] == port and env['ADB_SERVER_SOCKET'] == 'tcp:127.0.0.1:' + port
        adb = runtime.adb_command(role)
        assert adb[adb.index('-H') + 1] == '127.0.0.1'
        assert adb[adb.index('-P') + 1] == port and adb[adb.index('-s') + 1] == runtime.role_config(role)['serial']
        emulator = runtime.emulator_command(role)
        assert emulator[emulator.index('-camera-back') + 1] == emulator[emulator.index('-camera-front') + 1] == 'emulated'
        assert emulator[emulator.index('-accel') + 1] == 'on' and '-no-audio' in emulator and '-no-snapshot' in emulator
        assert not any('/dev/video' in value or '/dev/snd' in value or 'webcam' in value for value in emulator)
    checks.append('separate-ports-in-env-and-argv-native-v1-emulator-flags')
    rejects(runtime.role_config, 'felix')
    derivation = runtime.verify_derivation()
    tests = runtime.verify_current_eight()
    history = runtime.verify_invite_history()
    assert derivation['installed_apk_sha256'] != tests['actually_tested_apk_sha256']
    assert tests['tests'] == 8 and tests['diagnostic_apk_test_run_claimed'] is False
    assert history['first_cold'] == 'PARTIAL' and history['omemo_authenticated_call_proven'] is False
    assert runtime.v1.APKS['main.apk'].startswith('2f0e') and runtime.v1.APKS['android-test.apk'].startswith('cc3f')
    assert runtime.APK_PATHS['main.apk'] != runtime.ROOT / 'apk/main.apk'
    checks.append('current-derivatives-use-real-eight-and-separate-partial-first-invite')
    actual = runtime.proof
    try:
        def changed_proof(name):
            value = actual(name)
            if name == 'eight_and_first_cold_audit':
                value['first_cold_invite']['accepted_first_cold_invite_proven'] = True
            return value
        runtime.proof = changed_proof
        rejects(runtime.verify_invite_history)
    finally:
        runtime.proof = actual
    checks.append('first-cold-partial-cannot-be-relabelled-accepted')
    original_main = runtime.APKS['main.apk']
    try:
        runtime.APKS['main.apk'] = '0' * 64
        rejects(runtime.verify_derivation)
    finally:
        runtime.APKS['main.apk'] = original_main
    checks.append('wrong-diagnostic-artifact-pin-rejected')
    rejects(runtime.verify_leon_stop, {'schema_version': 2, 'run_id': runtime.RUN,
        'role': 'leon', 'account': runtime.OWN['nora'], 'profile_retained': True})
    checks.append('incomplete-or-wrong-account-prerequisites-rejected')
    assert {name: runtime.sha(runtime.HERE.parent / name) for name in runtime.V1_PINS} == runtime.V1_PINS
    checks.append('five-current-shared-controller-files-byte-identical')
    assert all(not (runtime.STATE / ('allow-' + role + '.json')).exists() for role in ('nora', 'leon'))
    return {'schema_version': 2, 'pure_checks_passed': checks,
            'runtime_started': False, 'network_used': False, 'runtime_gate_evidence_created': False,
            'root_approval_markers_created': False}


if __name__ == '__main__':
    value = run()
    print(json.dumps(value, indent=2))

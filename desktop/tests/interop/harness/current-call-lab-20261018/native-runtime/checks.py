#!/usr/bin/env python3
"""Focused offline checks. All Docker/SSH dispatch is mocked, never live."""
import ast
import copy
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
from unittest.mock import patch
import native_control as control
import native_recorder as recorder
import runtime_spec as s
import recreate_stopped_native_peers as create_source

ROOT = Path('/media/linux/SSD128/xmppwin')
OLD = ROOT / 'local/muji-device-binding-auth-20261016/native-session-public-direct-link-20261016T202431Z'


def rejected(operation):
    try: operation()
    except (AssertionError, ValueError, KeyError): return
    raise AssertionError('Invalid fixture was accepted')


def fixture(role, running=False):
    # Explicit synthetic IDs only in this offline test, never in an admission file used by runtime.
    value = json.loads((OLD / 'off-preparation/actual-server-deployment' / (role + '-actual-new-complete-created-inspect.json')).read_bytes())[0]
    cid = ('1' if role == 'leon' else '2') * 64
    value['Id'] = cid
    value['Config']['Labels']['im.dinox.interop.current'] = '85879bcf-20261018'
    value['Config']['Cmd'] = [s.MOUNT + '/server_entry_' + role + '.sh', role]
    value['Mounts'] = [m for m in value['Mounts'] if m['Destination'] in ('/opt/interop', s.PROFILE)]
    value['Mounts'].append({'Destination': s.MOUNT, 'Name': s.VOLUME,
                            'Source': '/var/lib/docker/volumes/' + s.VOLUME + '/_data', 'RW': False})
    if running: value['State'].update(Running=True, Status='running', Pid=400, StartedAt='2026-10-18T03:00:00Z')
    row = {'container_id': cid, 'name': 'dinox-interop-20261015-' + role, 'cmd': value['Config']['Cmd'],
           'profile_volume': s.TEMPLATE[role]['profile_volume'], 'created_never_started': True}
    return value, row


def main():
    assert not sys.flags.optimize
    for path in s.HERE.glob('*.py'): ast.parse(path.read_text())
    assert s.digest(s.HERE / 'server_control_base.py') == '0fe86a2329e77b2f35b804596f900a0d4341d7d2640d8264342cb8e94bbc6555'
    old_recorder = (ROOT / 'local/monocles-dinox-interop-20261015/harness/native_session_public/native_recorder.py').read_text()
    assert (s.HERE / 'native_recorder.py').read_text() == old_recorder.replace(
        "ORIGINAL = Path(__file__).resolve().parents[1] / 'scenario_recorder.py'",
        "ORIGINAL = Path('/media/linux/SSD128/xmppwin/local/monocles-dinox-interop-20261015/harness/scenario_recorder.py')")
    assert not (s.HERE / 'owner-native-admission.json').exists()
    fixtures = {}
    for role in ('leon', 'felix'):
        created, row = fixture(role); fixtures[role] = row
        s.check_container(created, row, role, False)
        running, _ = fixture(role, True); s.check_container(running, row, role, True)
        control.check_container(running, row, role)  # Existing A18 runtime binding API.
        rejected(lambda: control.check_container(created, row, role))
        for kind in ('wrong_id', 'old_cmd', 'wrong_image', 'writable_overlay', 'wrong_profile_source', 'duplicate_mount', 'extra_swap', 'capture_device'):
            bad = copy.deepcopy(running)
            if kind == 'wrong_id': bad['Id'] = '3' * 64
            if kind == 'old_cmd': bad['Config']['Cmd'][0] = '/driver-session-public/server_entry_' + role + '.sh'
            if kind == 'wrong_image': bad['Image'] = 'sha256:' + '4' * 64
            if kind == 'writable_overlay': bad['Mounts'][-1]['RW'] = True
            if kind == 'wrong_profile_source': bad['Mounts'][-2]['Source'] = '/different/profile'
            if kind == 'duplicate_mount': bad['Mounts'].append(bad['Mounts'][-1])
            if kind == 'extra_swap': bad['HostConfig']['MemorySwap'] += 1
            if kind == 'capture_device': bad['HostConfig']['Devices'] = [{'PathOnHost': '/dev/video0'}]
            rejected(lambda: s.check_container(bad, row, role, True))
    # A18 imports the native controller by file, without adding its directory to sys.path.
    with patch.object(sys, 'path', [p for p in sys.path if Path(p or '.').resolve() != s.HERE]), \
         patch.dict(sys.modules, {'runtime_spec': None}):
        dynamic_spec = importlib.util.spec_from_file_location('offline_A18_native_binding', s.HERE / 'native_control.py')
        dynamic = importlib.util.module_from_spec(dynamic_spec); dynamic_spec.loader.exec_module(dynamic)
        dynamic.check_container(*fixture('leon', True), 'leon')
    def volume(name):
        created = '2026-10-15T16:08:23Z' if name.endswith('-payload') else (
            s.TEMPLATE['leon']['profile_created_at'] if name.endswith('-leon') else '2026-10-18T03:00:00Z')
        labels = {'im.dinox.interop.run': s.RUN}
        if name == s.VOLUME: labels['im.dinox.interop.current'] = '85879bcf-20261018'
        return {'Name': name, 'Mountpoint': '/var/lib/docker/volumes/' + name + '/_data',
                'Driver': 'local', 'Labels': labels, 'CreatedAt': created}
    for change in (None, 'name', 'mountpoint', 'label', 'driver', 'created_at', 'missing'):
        def fake_inspect(args):
            assert args[:2] == ['volume', 'inspect']; name = args[-1]
            if change == 'missing': raise subprocess.CalledProcessError(1, args)
            value = volume(name)
            if change == 'name': value['Name'] = 'foreign'
            if change == 'mountpoint': value['Mountpoint'] = '/wrong/_data'
            if change == 'label': value['Labels'] = {}
            if change == 'driver': value['Driver'] = 'foreign'
            if change == 'created_at': value['CreatedAt'] = 'new-empty-volume'
            return subprocess.CompletedProcess([], 0, json.dumps([value]), '')
        with patch.object(s, 'call', side_effect=fake_inspect) as execute:
            if change is None:
                assert len(s.require_peer_volumes('leon')) == 3
                assert [c.args[0][-1] for c in execute.call_args_list] == ['dinox-interop-20261015-payload', s.TEMPLATE['leon']['profile_volume'], s.VOLUME]
            else:
                try: s.require_peer_volumes('leon')
                except (AssertionError, KeyError, subprocess.CalledProcessError): pass
                else: raise AssertionError('Missing/foreign named volume was accepted')
    fake_admission = {'scope': 'ACTUAL_CREATED_OFF_CURRENT_IDENTITIES_NOT_A_START_ADMISSION', 'run_id': s.RUN,
                      'overlay_manifest_sha256': s.MANIFEST_SHA, 'readonly_overlay': s.VOLUME,
                      'artifacts_sha256': s.ARTIFACTS, 'roles': fixtures}
    with tempfile.TemporaryDirectory(prefix='current-native-admission-offline-') as folder:
        root = Path(folder); admission_path = root / 'owner-native-admission.json'
        admission_path.write_text(json.dumps(fake_admission)); admission_path.chmod(0o600)
        digest = s.digest(admission_path)
        with patch.object(s, 'HERE', root):
            assert s.admission(digest) == fake_admission
            rejected(lambda: s.admission('0' * 64))
            changed = copy.deepcopy(fake_admission); changed['roles']['leon']['container_id'] = s.TEMPLATE['leon']['historical_absent_id']
            admission_path.write_text(json.dumps(changed)); rejected(lambda: s.admission(s.digest(admission_path)))
    request = {'action': 'state', 'role': 'leon', 'transport': 'server', 'wait': 0, 'native_admission_sha256': '9' * 64}
    info, _ = fixture('leon', True)
    with patch.object(control, 'admission', return_value=fake_admission), \
         patch.object(control.subprocess, 'check_output', return_value=json.dumps([info])) as inspect, \
         patch.object(control.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, '{"completed":true}', '')) as execute, \
         patch('builtins.print'):
        assert control.server(request) == 0
        assert inspect.call_args.args[0][-1] == fixtures['leon']['container_id']
        argv = execute.call_args.args[0]
        assert argv[:3] == ['docker', 'exec', '-i'] and argv[5:7] == ['exec', '-i']
        assert argv[9] == fixtures['leon']['container_id']
        assert json.loads(execute.call_args.kwargs['input']) == request
        assert argv[-1].endswith(control.base.CONTROL_CODE)
    with patch.object(control.sys, 'argv', [str(s.HERE / 'native_control.py'), '--stdin']), \
         patch.object(control.sys, 'stdin', io.StringIO(json.dumps(request))), \
         patch.object(control, 'admission', return_value=fake_admission), \
         patch.object(control.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, '{"completed":true}', '')) as execute, \
         patch('builtins.print'):
        assert control.main() == 0
        assert execute.call_args.args[0][:5] == ['ssh', '-4', '-p', '2654', '-o']
        assert execute.call_args.args[0][-1] == 'python3 -B ' + control.REMOTE + ' --stdin'
        assert json.loads(execute.call_args.kwargs['input']) == request
    stop = {**request, 'action': 'command', 'id': 'a' * 32, 'payload': {'op': 'stop'}}
    for where in (str(s.HERE / 'native_control.py'), control.REMOTE):
        with patch.object(control.sys, 'argv', [where, '--stdin']), patch.object(control.sys, 'stdin', io.StringIO(json.dumps(stop))), \
             patch.object(control, 'admission') as admitted, patch.object(control.subprocess, 'check_output') as inspect, \
             patch.object(control.subprocess, 'run') as execute, patch('builtins.print') as printed:
            assert control.main() == 2
            assert json.loads(printed.call_args.args[0])['error_type'] == 'UnsafeDriverStop'
            admitted.assert_not_called(); inspect.assert_not_called(); execute.assert_not_called()
    with patch.object(control, 'admission') as admitted, patch.object(control.subprocess, 'check_output') as inspect, \
         patch.object(control.subprocess, 'run') as execute:
        rejected(lambda: control.server(stop))
        admitted.assert_not_called(); inspect.assert_not_called(); execute.assert_not_called()
    # Verify actual origin bytes once; do not copy 150 MB or repeatedly hash large sources per negative fixture.
    origins = {}
    for name, row in s.MANIFEST['files'].items():
        if row['source'].startswith('source:'): path = s.HERE / row['source'].split(':', 1)[1]
        elif name == 'bin/dinox-interop-current':
            path = s.HERE.parent / 'from-existing-image/actual-job-20261018T020732Z-2c6dabad/exported/native-current-driver-results/artifacts/native-driver/dinox-interop-current'
        else: path = ROOT / row['origin']
        assert path.stat().st_size == row['bytes'] and s.digest(path) == row['sha256']
        origins[s.MOUNT + '/' + name] = path
    assert len(origins) == 49 and s.MANIFEST['total_bytes'] == 150500672
    runtime = [p for p in origins if p.startswith(s.MOUNT + '/qualified-runtime/')]
    actual_elfs = []
    for p in runtime:
        with origins[p].open('rb') as stream:
            if stream.read(4) == b'\x7fELF': actual_elfs.append(p)
    assert set(actual_elfs) == {s.MOUNT + '/' + p for p in s.MANIFEST['qualified_runtime_elf_files']}
    assert len(runtime) == 43 and len(actual_elfs) == 5
    # Exercise the exact emitted guard, replacing I/O only. Every changed artifact is rejected.
    class FakePath:
        def __init__(self, name): self.name = name
        def open(self, mode): return io.StringIO(self.name)
    class Digest:
        def __init__(self, value): self.value = value
        def hexdigest(self): return self.value
    def guarded(changed=None):
        def fake_digest(stream, algorithm):
            assert algorithm == 'sha256'; path = stream.getvalue()
            return Digest('0' * 64 if path == changed else s.ARTIFACTS[path])
        with patch('pathlib.Path', FakePath), patch('hashlib.file_digest', fake_digest):
            exec(control.ARTIFACT_GUARD_CODE, {})
    guarded()
    for path in s.ARTIFACTS: rejected(lambda p=path: guarded(p))
    for role in ('leon', 'felix'):
        entry = s.HERE / ('server_entry_' + role + '.sh')
        subprocess.run(['/bin/sh', '-n', str(entry)], check=True, capture_output=True, timeout=5)
        text = entry.read_text()
        assert 'export LD_LIBRARY_PATH=' + s.LIBRARY_PATH in text
        assert 'export DINOX_WEBRTC_WORKER_PATH=' + s.WORKER in text
        assert s.BINARY in text and 'exec /usr/bin/nice -n 19 timeout' in text
        assert '/opt/interop/payload/bin/dinox-webrtc-worker' not in text and '/driver-session-public/bin/' not in text
    create = (s.HERE / 'recreate_stopped_native_peers.py').read_text()
    assert "['start'" not in create and "['rm'" not in create and "['rename'" not in create
    assert '--pull=never' in create
    assert 'q.stdout.strip()' in create and 's.check_container(actual, row, role, False)' in create
    network = {'Name': 'dinox-interop-20261015', 'Driver': 'bridge', 'Scope': 'local', 'Id': '7' * 64,
               'Labels': {'im.dinox.interop.run': s.RUN}, 'Internal': False, 'Ingress': False,
               'EnableIPv6': False, 'Containers': {}, 'IPAM': {'Driver': 'default', 'Config': [{'Subnet': '172.19.0.0/16'}]}}
    missing = subprocess.CompletedProcess([], 1, '', 'Error response from daemon: network dinox-interop-20261015 not found\n')
    for initial, wrong in ((subprocess.CompletedProcess([], 0, json.dumps([network]), ''), False),
                           (missing, False),
                           (subprocess.CompletedProcess([], 0, json.dumps([{**network, 'Labels': {}}]), ''), True),
                           (subprocess.CompletedProcess([], 1, '', 'unrelated failure'), True)):
        with patch.object(create_source.subprocess, 'run', return_value=initial), patch.object(s, 'save'), \
             patch.object(s, 'call', side_effect=[subprocess.CompletedProcess([], 0, '7' * 64 + '\n', ''),
                                                  subprocess.CompletedProcess([], 0, json.dumps([network]), '')]) as execute:
            if wrong:
                rejected(create_source.ensure_test_network); execute.assert_not_called()
            else:
                assert create_source.ensure_test_network() == network
                if initial.returncode == 0: execute.assert_not_called()
                else: assert execute.call_args_list[0].args[0] == ['network', 'create', '--driver', 'bridge', '--label', 'im.dinox.interop.run=' + s.RUN, 'dinox-interop-20261015']
    with tempfile.TemporaryDirectory(prefix='current-native-recorder-offline-') as folder:
        root = Path(folder); (root / 'runtime-inputs.json').write_text('{"offline_fixture":true}\n')
        with patch.object(recorder, 'LOCAL_ROOT', root), patch.object(recorder, 'ADMISSION_SHA', '9' * 64), \
             patch.object(control, 'admission', return_value=fake_admission):
            recording = recorder.server({'action': 'begin', 'label': 'offline-fixture', 'local_recording': True})
            metadata = json.loads((Path(recording['server_directory']) / 'recording.json').read_bytes())
            assert metadata['native_artifacts_sha256'] == s.ARTIFACTS and metadata['native_admission_sha256'] == '9' * 64
    output = {'result': 'SOURCE_AND_OFFLINE_FIXTURES_PASS_NOT_A_RUNTIME_ADMISSION', 'overlay_files': 49,
              'overlay_bytes': 150500672, 'qualified_runtime_files': 43, 'runtime_elf_files': 5,
              'all_actual_origin_hashes_checked': True, 'all_50_artifact_guard_negatives_rejected': True,
              'created_running_id_mount_resource_negatives': True, 'stop_blocked_before_any_subprocess': True,
              'outer_ssh_and_both_inner_exec_stdin_checked': True,
              'existing_three_argument_dynamic_import_api_checked': True,
              'all_named_mounts_must_exist_missing_foreign_changed_rejected': True,
              'new_ids_only_actual_future_create': True, 'inner_control_base_unchanged': True,
              'recorder_only_parent_path_changed': True, 'shell_and_python_syntax_pass': True,
              'exact_missing_owned_bridge_restored_foreign_or_other_failure_rejected_offline': True,
              'network_creation_or_remote_runtime_or_account_commands_executed': False}
    path = s.HERE / 'offline-checks.json'
    path.write_text(json.dumps(output, indent=2) + '\n'); path.chmod(0o600)
    print(json.dumps(output, indent=2))


if __name__ == '__main__': main()

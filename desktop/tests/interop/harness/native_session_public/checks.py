#!/usr/bin/env python3
"""Offline mocks and readonly artifact hashes; never SSH/ADB/clients."""
import ast
import copy
import hashlib
from io import StringIO
import json
from pathlib import Path
import sys
import tempfile
import tarfile
from types import SimpleNamespace
from unittest.mock import patch

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import native_control as control
import native_recorder as recorder


def rejected(function):
    try:
        function()
    except (AssertionError, ValueError, KeyError):
        return
    raise AssertionError('Invalid fixture accepted')


def main():
    admission = control.admission(control.ADMISSION)
    rejected(lambda: control.admission('0' * 64))
    assert admission['roles']['leon']['container_id']=='2fd2a5dbf37029dccd0233a78a225316f9a70c4e9fef1c4dbfbc46241c610fac'
    assert admission['roles']['felix']['container_id']=='849fcd337a75f6230ea6c326cdabd55965de346286e1146a8f74f4c219f5ad17'
    assert recorder.ORIGINAL == HERE.parent / 'scenario_recorder.py'
    assert hashlib.sha256(recorder.ORIGINAL.read_bytes()).hexdigest() == '1b534a1b323619a437e5731edbe08100aa3557d61a103194d2a9318655ec6900'
    assert hashlib.sha256(control.ORIGINAL.read_bytes()).hexdigest() == '0fe86a2329e77b2f35b804596f900a0d4341d7d2640d8264342cb8e94bbc6555'
    for role, row in admission['roles'].items():
        info = {'Id': row['container_id'], 'Name': '/' + row['name'], 'State': {'Running': True},
                'Config': {'Labels': {'im.dinox.interop.run': control.base.RUN}, 'Cmd': row['cmd'], 'User': '1000:1000'},
                'HostConfig': {'ReadonlyRootfs': True},
                'Mounts': [{'Destination': '/driver-wirefix', 'RW': False},
                           {'Destination': '/driver-session-public', 'RW': False, 'Name': control.OVERLAY},
                           {'Destination': '/driver-core52-late', 'RW': False, 'Name': control.CORE_OVERLAY},
                           {'Destination': '/opt/interop', 'RW': False, 'Name': 'dinox-interop-20261015-payload'},
                           {'Destination': '/driver-muji-auth', 'RW': False, 'Name': 'dinox-interop-muji-auth-486545cc-20261016'}]}
        control.check_container(info, row, role)
        for branch, key, value in ((None, 'Id', '0' * 64), ('State', 'Running', False),
                                   ('Config', 'Cmd', ['/driver-wirefix/server_entry_' + role + '.sh', role]),
                                   ('Config', 'User', '0'), ('HostConfig', 'ReadonlyRootfs', False)):
            changed = copy.deepcopy(info)
            (changed[branch] if branch else changed)[key] = value
            rejected(lambda: control.check_container(changed, row, role))
        for index in range(len(info['Mounts'])):
            changed = copy.deepcopy(info)
            changed['Mounts'][index]['RW'] = True
            rejected(lambda: control.check_container(changed, row, role))
        for mounts in ([info['Mounts'][0]], *[info['Mounts'] + [item] for item in info['Mounts']],
                       *[[dict(item, Name='foreign-volume') if i==index else item for i,item in enumerate(info['Mounts'])] for index in range(1,len(info['Mounts']))]):
            changed = copy.deepcopy(info)
            changed['Mounts'] = mounts
            rejected(lambda: control.check_container(changed, row, role))
        request = {'action': 'state', 'role': role, 'transport': 'server', 'wait': 0,
                   'native_admission_sha256': control.ADMISSION}
        response = SimpleNamespace(stdout=json.dumps({'completed': True, 'run_id': control.base.RUN}), returncode=0)
        with patch.object(control.subprocess, 'check_output', return_value=json.dumps([info])) as inspect, \
             patch.object(control.subprocess, 'run', return_value=response) as execute, patch('builtins.print'):
            assert control.server(request) == 0
        assert inspect.call_args.args[0] == ['docker', 'exec', '-i', 'docker_dind', 'docker', 'inspect', row['container_id']]
        args = execute.call_args.args[0]
        assert args[:10] == ['docker', 'exec', '-i', 'docker_dind', 'docker', 'exec', '-i', '--user', '1000:1000', row['container_id']]
        assert args[10:] == ['python3', '-c', control.ARTIFACT_GUARD_CODE + control.base.CONTROL_CODE]
        assert json.loads(execute.call_args.kwargs['input']) == request
        assert execute.call_args.kwargs['text'] is True and execute.call_args.kwargs['timeout'] == 45
        stop = dict(request, action='command', id='a' * 32, payload={'op': 'stop'})
        with patch.object(control.subprocess, 'check_output') as inspect, \
             patch.object(control.subprocess, 'run') as execute, patch.object(control, 'admission') as admitted:
            rejected(lambda: control.server(stop))
            for remote in (control.REMOTE, str(Path(control.__file__).resolve())):
                with patch.object(control, 'REMOTE', remote), patch.object(sys, 'argv', ['native_control.py', '--stdin']), \
                     patch.object(sys, 'stdin', StringIO(json.dumps(stop))), patch('builtins.print') as printed:
                    assert control.main() == 2
                    result = json.loads(printed.call_args.args[0])
                    assert result['error_type'] == 'UnsafeDriverStop' and result['submission_outcome_unknown'] is False
            inspect.assert_not_called()
            execute.assert_not_called()
            admitted.assert_not_called()
    artifact_root = Path('/media/linux/SSD128/xmppwin/local/muji-device-binding-auth-20261016/native-session-public-direct-link-20261016T202431Z/actual-server-job/artifacts')
    local_paths = {'/driver-session-public/bin/dinox-interop-fixed': artifact_root / 'native-driver/dinox-interop-fixed',
                   '/driver-muji-auth/lib/omemo.so': artifact_root / 'plugin/omemo.so',
                   '/opt/interop/payload/lib/libomemo-c.so.0': Path('/media/linux/SSD128/xmppwin/local/muji-device-binding-auth-20261016/native-session-public-observer-20261016T201836Z/actual-existing-libomemo-c.so.0')}
    class ReadonlyArtifact:
        def __init__(self, path): self.path = path
        def read_bytes(self):
            if self.path == '/driver-core52-late/lib/libdino.so.0':
                with tarfile.open(artifact_root.parents[1] / 'payload.tar') as archive:
                    return archive.extractfile('wiretest/inputs/libdino.so.0').read()
            return local_paths[self.path].read_bytes()
    with patch('pathlib.Path', ReadonlyArtifact):
        exec(control.ARTIFACT_GUARD_CODE, {})
    for changed_path in control.ARTIFACTS:
        class ChangedArtifact(ReadonlyArtifact):
            def read_bytes(self):
                return b'wrong artifact' if self.path==changed_path else super().read_bytes()
        with patch('pathlib.Path', ChangedArtifact):
            rejected(lambda: exec(control.ARTIFACT_GUARD_CODE, {}))
    with tempfile.TemporaryDirectory(prefix='own-native-control-offline-') as folder:
        root = Path(folder)
        (root / 'runtime-inputs.json').write_text('{"synthetic_offline_fixture":true}\n')
        with patch.object(recorder, 'LOCAL_ROOT', root), patch.object(recorder, 'ADMISSION_SHA', control.ADMISSION):
            recording = recorder.server({'action': 'begin', 'label': 'offline-fixture', 'local_recording': True})
            metadata_path = Path(recording['server_directory']) / 'recording.json'
            metadata = json.loads(metadata_path.read_text())
            assert metadata['native_artifacts_sha256'] == control.ARTIFACTS
            assert metadata['native_admission_sha256'] == control.ADMISSION
            metadata['native_artifacts_sha256']['/driver-muji-auth/lib/omemo.so'] = '0' * 64
            metadata_path.write_text(json.dumps(metadata))
            with patch.object(recorder.subprocess, 'run') as execute:
                rejected(lambda: recorder.server({'action': 'state', 'recording': recording['recording'],
                    'local_recording': True, 'role': 'felix', 'transport': 'server', 'wait': 0, 'tag': 'fixture'}))
                execute.assert_not_called()
    for filename in ('native_control.py', 'native_recorder.py', 'checks.py', 'server_control_base.py'):
        ast.parse((HERE / filename).read_text())
    output = {'result': 'PASS_OFFLINE_ONLY', 'groups': 6,
              'new_actual_id_cmd_and_readonly_overlay_rejections': True,
              'outer_and_inner_exec_stdin_preserved': True,
              'stop_rejected_local_remote_before_admission_or_any_subprocess': True,
              'actual_local_compiled_artifact_hashes_and_wrong_bytes_checked': True,
              'historical_recorder_path_correct_at_same_sibling_depth': True,
              'recorded_native_artifact_and_admission_binding': True,
              'native_or_guest_or_account_or_ssh_or_adb_started': False}
    path = HERE / 'offline-checks.json'
    path.write_text(json.dumps(output, indent=2) + '\n')
    path.chmod(0o600)
    print(json.dumps(output, indent=2))


if __name__ == '__main__': main()

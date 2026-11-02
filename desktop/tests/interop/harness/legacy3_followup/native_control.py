#!/usr/bin/env python3
"""Control only the two already admitted wirefix peers; never launch a peer."""
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
ORIGINAL = HERE / 'server_control_base.py'
assert hashlib.sha256(ORIGINAL.read_bytes()).hexdigest() == '0fe86a2329e77b2f35b804596f900a0d4341d7d2640d8264342cb8e94bbc6555'
spec = importlib.util.spec_from_file_location('historical_native_control', ORIGINAL)
base = importlib.util.module_from_spec(spec); spec.loader.exec_module(base)
REMOTE = '/home/cpaneladmin/dinox-interop-20261015/harness/legacy3_followup/native_control.py'
HOST = base.HOST
DOCKER = ['docker', 'exec', '-i', 'docker_dind', 'docker']  # Preserve stdin through BOTH exec layers.
ADMISSION = '6cc55d8d38a35aaaba63a086538540ff88e221ed2fee344d2eb548a11d5f5909'
BINARY = '12dbce529faea0d1b736d2e2b83479f6022c5f4f534a69534425fb7d2d7c1654'


def admission(expected_sha):
    assert expected_sha == ADMISSION, 'Only the actual reviewed owner identities are admitted'
    path = HERE / 'owner-native-admission.json'
    assert path.is_file() and not path.is_symlink() and path.stat().st_size < 65536
    assert path.stat().st_mode & 0o077 == 0, 'Owner admission must stay private'
    raw = path.read_bytes(); assert hashlib.sha256(raw).hexdigest() == expected_sha
    value = json.loads(raw)
    assert value['run_id'] == base.RUN
    assert set(value['roles']) == {'leon', 'felix'}
    for role, row in value['roles'].items():
        assert re.fullmatch('[0-9a-f]{64}', row['container_id'])
        assert row['name'] == 'dinox-interop-20261015-' + role
        assert row['cmd'] == ['/driver-wirefix/server_entry_' + role + '.sh', role]
    assert value['roles']['leon']['container_id'] != value['roles']['felix']['container_id']
    return value


def check_container(info, row, role):
    assert info['Id'] == row['container_id'] and info['Name'].lstrip('/') == row['name']
    assert info['State']['Running'] and info['Config']['Labels'].get('im.dinox.interop.run') == base.RUN
    assert info['Config']['Cmd'] == row['cmd'] == ['/driver-wirefix/server_entry_' + role + '.sh', role]
    assert info['Config']['User'] == '1000:1000' and info['HostConfig']['ReadonlyRootfs'] is True
    mounts = [m for m in info['Mounts'] if m['Destination'] == '/driver-wirefix']
    assert len(mounts) == 1 and mounts[0]['RW'] is False


class UnsafeDriverStop(ValueError): pass


def validate_request(value):
    value = base.validate_envelope(value)
    assert value['transport'] == 'server' and value['role'] in ('leon', 'felix')
    if value['action'] == 'command' and value['payload']['op'] == 'stop':
        raise UnsafeDriverStop('Private driver stop removes account identity; use ordered exact-container SIGTERM')
    return value


def server(value):
    value = validate_request(value)
    row = admission(value['native_admission_sha256'])['roles'][value['role']]
    # Bind both inspection and execution to the full immutable ID, never merely its name.
    info = json.loads(subprocess.check_output([*DOCKER, 'inspect', row['container_id']], text=True, timeout=15))[0]
    check_container(info, row, value['role'])
    result = subprocess.run([*DOCKER, 'exec', '-i', '--user', '1000:1000', row['container_id'], 'python3', '-c', base.CONTROL_CODE],
                            input=json.dumps(value), text=True, capture_output=True, timeout=value['wait'] + 45)
    print(json.dumps(json.loads(result.stdout), ensure_ascii=False))
    return result.returncode


def main():
    value = None
    try:
        assert not sys.flags.optimize and sys.argv[1:] == ['--stdin']
        raw = sys.stdin.read(32769); assert len(raw) <= 32768
        value = json.loads(raw)
        value = validate_request(value)
        admission(value['native_admission_sha256'])
        if str(Path(__file__).resolve()) == REMOTE: return server(value)
        result = subprocess.run(['ssh', '-p', '2654', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=12', HOST,
                                 'python3 ' + REMOTE + ' --stdin'], input=json.dumps(value), text=True,
                                 capture_output=True, timeout=value['wait'] + 75)
        print(json.dumps(json.loads(result.stdout), ensure_ascii=False)); return result.returncode
    except Exception as error:
        response = {'ok': False, 'error': 'exact_native_admission_or_control_failed', 'error_type': type(error).__name__}
        if isinstance(value, dict): response.update(role=value.get('role'), id=value.get('id'), run_id=base.RUN,
            submission_outcome_unknown=value.get('action') == 'command' and not isinstance(error, UnsafeDriverStop))
        print(json.dumps(response)); return 2


if __name__ == '__main__': sys.exit(main())

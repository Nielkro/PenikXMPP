#!/usr/bin/env python3
"""Exact created-ID control sibling; no launch, private stop or identity reset."""
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys

sys.dont_write_bytecode = True
_SPEC = Path(__file__).resolve().with_name('runtime_spec.py')
assert hashlib.sha256(_SPEC.read_bytes()).hexdigest() == '9c977b2821e257a6ac691e8ba2b17b8e8494489844fd77529d9a4ef1346329e8'
_runtime_spec = importlib.util.spec_from_file_location('exact_current_native_runtime_spec', _SPEC)
s = importlib.util.module_from_spec(_runtime_spec); _runtime_spec.loader.exec_module(s)
HERE = s.HERE
ORIGINAL = HERE / 'server_control_base.py'
assert hashlib.sha256(ORIGINAL.read_bytes()).hexdigest() == '0fe86a2329e77b2f35b804596f900a0d4341d7d2640d8264342cb8e94bbc6555'
spec = importlib.util.spec_from_file_location('historical_native_control', ORIGINAL)
base = importlib.util.module_from_spec(spec); spec.loader.exec_module(base)
REMOTE = s.REMOTE + '/native_control.py'
HOST = base.HOST
DOCKER = s.DOCKER
ARTIFACTS = s.ARTIFACTS
admission = s.admission
ARTIFACT_GUARD_CODE = ('from pathlib import Path\nimport hashlib\n'
    + 'for p,h in ' + repr(ARTIFACTS) + '.items():\n'
    + '    with Path(p).open("rb") as f: assert hashlib.file_digest(f,"sha256").hexdigest()==h, "Readonly artifact changed"\n')


class UnsafeDriverStop(ValueError): pass


def check_container(info, row, role, running=True):
    # Keep the established three-argument runtime-binding API, requiring running peers.
    return s.check_container(info, row, role, running)


def validate_request(value):
    value = base.validate_envelope(value)
    assert value['transport'] == 'server' and value['role'] in ('leon', 'felix')
    if value['action'] == 'command' and value['payload']['op'] == 'stop':
        raise UnsafeDriverStop('Private driver stop removes identity; use ordered exact-container SIGTERM')
    return value


def server(value):
    value = validate_request(value)
    row = admission(value['native_admission_sha256'])['roles'][value['role']]
    info = json.loads(subprocess.check_output([*DOCKER, 'inspect', row['container_id']], text=True, timeout=15))[0]
    check_container(info, row, value['role'], True)
    result = subprocess.run([*DOCKER, 'exec', '-i', '--user', '1000:1000', row['container_id'], 'python3', '-c', ARTIFACT_GUARD_CODE + base.CONTROL_CODE],
                            input=json.dumps(value), text=True, capture_output=True, timeout=value['wait'] + 45)
    print(json.dumps(json.loads(result.stdout), ensure_ascii=False)); return result.returncode


def main():
    value = None
    try:
        assert not sys.flags.optimize and sys.argv[1:] == ['--stdin']
        raw = sys.stdin.read(32769); assert len(raw) <= 32768
        value = validate_request(json.loads(raw))
        admission(value['native_admission_sha256'])
        if str(Path(__file__).resolve()) == REMOTE: return server(value)
        result = subprocess.run(['ssh', '-4', '-p', '2654', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=12', HOST,
                                 'python3 -B ' + REMOTE + ' --stdin'], input=json.dumps(value), text=True,
                                 capture_output=True, timeout=value['wait'] + 75)
        print(json.dumps(json.loads(result.stdout), ensure_ascii=False)); return result.returncode
    except Exception as error:
        response = {'ok': False, 'error': 'exact_native_admission_or_control_failed', 'error_type': type(error).__name__}
        if isinstance(value, dict): response.update(role=value.get('role'), id=value.get('id'), run_id=base.RUN,
            submission_outcome_unknown=value.get('action') == 'command' and not isinstance(error, UnsafeDriverStop))
        print(json.dumps(response)); return 2


if __name__ == '__main__': sys.exit(main())

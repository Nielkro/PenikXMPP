#!/usr/bin/env python3
"""Local additive recording through the exact-ID native controller only."""
import datetime
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import time
import uuid
sys.dont_write_bytecode = True
import native_control

ORIGINAL = Path(__file__).resolve().parents[1] / 'scenario_recorder.py'
assert hashlib.sha256(ORIGINAL.read_bytes()).hexdigest() == '1b534a1b323619a437e5731edbe08100aa3557d61a103194d2a9318655ec6900'
spec = native_control.importlib.util.spec_from_file_location('historical_native_recorder', ORIGINAL)
old = native_control.importlib.util.module_from_spec(spec); spec.loader.exec_module(old)
ROOT, LOCAL_ROOT, RUN = old.ROOT, old.LOCAL_ROOT, old.RUN
store, safe = old.store, old.safe
ADMISSION_SHA = None  # Set from the explicit scenario CLI, not an implicit environment.


def server(value):
    assert value.get('local_recording') is True
    native_control.admission(ADMISSION_SHA)
    local = True
    root = LOCAL_ROOT if local else ROOT
    control = Path(__file__).resolve().with_name('native_control.py') if local else ROOT / 'harness/server_control.py'
    if value['action'] == 'begin':
        identifier = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ-') + uuid.uuid4().hex
        directory = root / 'evidence' / identifier
        directory.mkdir(parents=True, mode=0o700)
        directory.parent.chmod(0o700)
        store(directory / 'recording.json', {'run_id': RUN, 'recording': identifier,
              'label': value['label'], 'runtime_manifest_sha256': hashlib.sha256((root / ('runtime-inputs.json' if local else 'manifest.json')).read_bytes()).hexdigest(),
              'controller_sha256': hashlib.sha256(control.read_bytes()).hexdigest(),
              'recording_host': 'local' if local else 'server',
              'native_admission_sha256': ADMISSION_SHA, 'native_artifacts_sha256': native_control.ARTIFACTS, 'no_interop_result_claimed': True})
        return {'recording': identifier, 'server_directory': str(directory)}
    identifier = value['recording']
    if not re.fullmatch(r'[0-9]{8}T[0-9]{6}Z-[0-9a-f]{32}', identifier):
        raise ValueError('Invalid recording identifier')
    directory = root / 'evidence' / identifier
    metadata = json.loads((directory / 'recording.json').read_text())
    if metadata['run_id'] != RUN: raise ValueError('Foreign recording')
    assert metadata['native_admission_sha256'] == ADMISSION_SHA
    assert metadata['native_artifacts_sha256'] == native_control.ARTIFACTS
    if metadata['controller_sha256'] != hashlib.sha256(control.read_bytes()).hexdigest():
        raise ValueError('Control helper changed during recording')
    manifest = root / ('runtime-inputs.json' if local else 'manifest.json')
    if metadata['runtime_manifest_sha256'] != hashlib.sha256(manifest.read_bytes()).hexdigest():
        raise ValueError('Runtime inputs changed during recording')
    envelope = {k: value[k] for k in ('action', 'role', 'wait')}
    envelope['transport'] = value.get('transport', 'server')
    assert envelope['transport'] == 'server' and envelope['role'] in ('leon', 'felix')
    envelope['native_admission_sha256'] = ADMISSION_SHA
    if envelope['action'] == 'command':
        safe(value['payload'])
        envelope.update(id=value['id'], payload=value['payload'])
    if envelope['action'] == 'result': envelope['id'] = value['id']
    event = str(time.time_ns()) + '-' + uuid.uuid4().hex
    record = {'event': event, 'tag': value['tag'], 'run_id': RUN,
              'started_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'request': envelope}
    store(directory / (event + '.request.json'), record)
    try:
        result = subprocess.run([sys.executable, str(control), '--stdin'],
                                input=json.dumps(envelope), text=True, capture_output=True, timeout=envelope['wait'] + 60)
        record['controller_exit'] = result.returncode
        try: record['observation'] = json.loads(result.stdout)
        except ValueError: raise RuntimeError('non_json_control_response')
    except (OSError, subprocess.TimeoutExpired, RuntimeError) as error:
        record.setdefault('controller_exit', None)
        record['observation'] = {'ok': False, 'error_type': type(error).__name__,
              'role': envelope['role'], 'run_id': RUN, 'id': envelope.get('id'),
              'submission_outcome_unknown': envelope['action'] == 'command', 'automatic_retry': False}
    record['finished_utc'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    store(directory / (event + '.observation.json'), record)
    return {'recording': identifier, 'evidence_file': str(directory / (event + '.observation.json')),
            'observation': record['observation'], 'controller_exit': record['controller_exit']}

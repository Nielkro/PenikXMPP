#!/usr/bin/env python3
"""Record explicitly requested real bridge operations; no launch or scenario automation."""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import time
import uuid

ROOT = Path('/home/cpaneladmin/dinox-interop-20261015')
REMOTE = ROOT / 'harness/scenario_recorder.py'
RUN = '20261015-71115b'
LOCAL_ROOT = Path('/media/linux/SSD128/monocles-interop-runtime-20261015')


def store(path, value):
    temporary = path.with_name(path.name + '.partial')
    with temporary.open('x', encoding='utf-8') as stream:
        json.dump(value, stream, indent=2, ensure_ascii=False)
        stream.write('\n')
    temporary.chmod(0o600)
    temporary.replace(path)


def safe(value):
    if isinstance(value, dict):
        if any(k.casefold() in ('password', 'database_password', 'db_key', 'config') for k in value):
            raise ValueError('Private configuration is not a scenario command')
        for item in value.values(): safe(item)
    elif isinstance(value, list):
        for item in value: safe(item)


def server(value):
    local = value.get('local_recording', False)
    root = LOCAL_ROOT if local else ROOT
    control = Path(__file__).resolve().with_name('server_control.py') if local else ROOT / 'harness/server_control.py'
    if value['action'] == 'begin':
        identifier = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ-') + uuid.uuid4().hex
        directory = root / 'evidence' / identifier
        directory.mkdir(parents=True, mode=0o700)
        directory.parent.chmod(0o700)
        store(directory / 'recording.json', {'run_id': RUN, 'recording': identifier,
              'label': value['label'], 'runtime_manifest_sha256': hashlib.sha256((root / ('runtime-inputs.json' if local else 'manifest.json')).read_bytes()).hexdigest(),
              'controller_sha256': hashlib.sha256(control.read_bytes()).hexdigest(),
              'recording_host': 'local' if local else 'server',
              'no_interop_result_claimed': True})
        return {'recording': identifier, 'server_directory': str(directory)}
    identifier = value['recording']
    if not re.fullmatch(r'[0-9]{8}T[0-9]{6}Z-[0-9a-f]{32}', identifier):
        raise ValueError('Invalid recording identifier')
    directory = root / 'evidence' / identifier
    metadata = json.loads((directory / 'recording.json').read_text())
    if metadata['run_id'] != RUN: raise ValueError('Foreign recording')
    if metadata['controller_sha256'] != hashlib.sha256(control.read_bytes()).hexdigest():
        raise ValueError('Control helper changed during recording')
    manifest = root / ('runtime-inputs.json' if local else 'manifest.json')
    if metadata['runtime_manifest_sha256'] != hashlib.sha256(manifest.read_bytes()).hexdigest():
        raise ValueError('Runtime inputs changed during recording')
    envelope = {k: value[k] for k in ('action', 'role', 'wait')}
    envelope['transport'] = value.get('transport', 'server')
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


def arguments():
    if sys.argv[1:] == ['--stdin']:
        raw = sys.stdin.read(32769)
        if len(raw) > 32768: raise ValueError('Recorder request is too large')
        return json.loads(raw)
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='action', required=True)
    begin = sub.add_parser('begin');begin.add_argument('label')
    begin.add_argument('--local-recording', action='store_true')
    for action in ('state', 'command', 'result'):
        item = sub.add_parser(action)
        item.add_argument('recording');item.add_argument('tag')
        item.add_argument('role', choices=('nora', 'leon', 'felix'))
        item.add_argument('--wait', type=float, default=0)
        item.add_argument('--local-recording', action='store_true')
        item.add_argument('--transport', choices=('server', 'local-android'), default='server')
        if action == 'command': item.add_argument('json')
        if action == 'result': item.add_argument('id')
    value = vars(parser.parse_args())
    if value['action'] == 'command': value['payload'] = json.loads(value.pop('json'))
    return value


def main():
    value = arguments()
    if value.get('action') not in ('begin', 'state', 'command', 'result'):
        raise ValueError('Unsupported recorder operation')
    if value['action'] != 'begin':
        if value.get('transport', 'server') not in ('server', 'local-android'):
            raise ValueError('Unknown transport')
        if value.get('transport') == 'local-android' and not (value.get('local_recording') and value.get('role') == 'nora'):
            raise ValueError('Local Android requires an explicit local Nora recording')
        if value.get('role') not in ('nora', 'leon', 'felix'): raise ValueError('Unsupported role')
        if type(value.get('wait')) not in (int, float) or not 0 <= value['wait'] <= 60:
            raise ValueError('Wait must be between 0 and 60 seconds')
        if value['action'] == 'command':
            value.setdefault('id', uuid.uuid4().hex)
            safe(value['payload'])
        if value['action'] in ('command', 'result') and not re.fullmatch(r'[0-9a-f]{32}', value.get('id', '')):
            raise ValueError('Invalid request identifier')
    if value.get('local_recording') or Path(__file__).resolve() == REMOTE:
        response = server(value)
    else:
        try:
            result = subprocess.run(['ssh', '-p', '2654', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=12',
                                     'cpaneladmin@45.84.199.125', 'python3 ' + str(REMOTE) + ' --stdin'],
                                    input=json.dumps(value), text=True, capture_output=True,
                                    timeout=value.get('wait', 0) + 90)
            if result.returncode: raise RuntimeError('remote_recorder_failed')
            response = json.loads(result.stdout)
        except (OSError, subprocess.TimeoutExpired, ValueError, RuntimeError) as error:
            response = {'ok': False, 'error_type': type(error).__name__, 'role': value.get('role'),
                        'run_id': RUN, 'id': value.get('id'), 'recording': value.get('recording'),
                        'submission_outcome_unknown': value['action'] == 'command', 'automatic_retry': False}
    print(json.dumps(response, ensure_ascii=False))


if __name__ == '__main__':
    try: main()
    except Exception as error:
        print(json.dumps({'ok': False, 'error_type': type(error).__name__, 'automatic_retry': False}))
        sys.exit(2)

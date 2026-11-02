#!/usr/bin/env python3
"""V2 explicit operation recorder; no runtime starts or scenario automation."""
import argparse
import datetime
import json
from pathlib import Path
import re
import sys
import time
import uuid
import control
import runtime


def record(value):
    freeze_sha = runtime.frozen_files()
    base = runtime.STATE / 'evidence'
    if value['action'] == 'begin':
        identifier = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ-') + uuid.uuid4().hex
        directory = base / identifier
        directory.mkdir(parents=True, mode=0o700)
        runtime.v1.write(directory / 'recording.json', {'schema_version': 2, 'run_id': runtime.RUN,
            'recording': identifier, 'label': value['label'], 'freeze_sha256': freeze_sha,
            'client_variant': runtime.CLIENT_VARIANT, 'source_manifest_sha256': runtime.JOIN_PRODUCT_PROOF['source_manifest_sha256'],
            'base_source_manifest_sha256': runtime.v1.SOURCE,
            'apk_sha256': runtime.APKS, 'base_apk_sha256': runtime.v1.APKS,
            'diagnostic_source_manifest_sha256': runtime.DIAGNOSTIC_SOURCE,
            'historical_csi_product_derivation': runtime.CSI_PRODUCT_PROOF,
            'current_join_product_derivation': runtime.JOIN_PRODUCT_PROOF,
            'runtime_inputs_sha256': runtime.sha(runtime.ROOT / 'runtime-inputs.json'),
            'no_interop_result_claimed': True})
        return {'recording': identifier, 'directory': str(directory)}
    identifier = value['recording']
    assert re.fullmatch('[0-9]{8}T[0-9]{6}Z-[0-9a-f]{32}', identifier)
    directory = base / identifier
    metadata = runtime.read(directory / 'recording.json')
    assert metadata['schema_version'] == 2 and metadata['run_id'] == runtime.RUN
    assert metadata['freeze_sha256'] == freeze_sha and metadata['runtime_inputs_sha256'] == runtime.sha(runtime.ROOT / 'runtime-inputs.json')
    request = {k: value[k] for k in ('action', 'role', 'transport', 'wait')}
    if request['action'] == 'command': request.update(id=value['id'], payload=value['payload'])
    if request['action'] == 'result': request['id'] = value['id']
    if 'room_admission' in value: request['room_admission'] = value['room_admission']
    control.validate(request)
    event = str(time.time_ns()) + '-' + uuid.uuid4().hex
    result = {'schema_version': 2, 'run_id': runtime.RUN, 'event': event, 'tag': value['tag'], 'request': request,
              'started_utc': datetime.datetime.now(datetime.timezone.utc).isoformat()}
    runtime.v1.write(directory / (event + '.request.json'), result)
    try:
        result['observation'] = control.control(request)
    except Exception as error:
        result['observation'] = control.failure(request, error)
    result['finished_utc'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    runtime.v1.write(directory / (event + '.observation.json'), result)
    return {'recording': identifier, 'evidence': str(directory / (event + '.observation.json')), 'observation': result['observation']}


def arguments():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='action', required=True)
    begin = sub.add_parser('begin'); begin.add_argument('label')
    for action in ('state', 'command', 'result'):
        item = sub.add_parser(action)
        item.add_argument('recording'); item.add_argument('tag'); item.add_argument('role', choices=tuple(runtime.OWN))
        item.add_argument('--transport', required=True, choices=('local-android', 'server'))
        item.add_argument('--wait', type=float, default=0)
        item.add_argument('--room-admission', type=Path)
        item.add_argument('--room-admission-sha256')
        if action == 'command': item.add_argument('json')
        if action == 'result': item.add_argument('id')
    value = vars(parser.parse_args())
    if value['action'] != 'begin':
        path = value.pop('room_admission')
        digest = value.pop('room_admission_sha256')
        assert (path is None) == (digest is None)
        if path is not None: value['room_admission'] = {'path': str(path), 'sha256': digest}
    if value['action'] == 'command': value.update(payload=json.loads(value.pop('json')), id=uuid.uuid4().hex)
    return value


if __name__ == '__main__':
    value = None
    try:
        value = arguments()
        print(json.dumps(record(value), ensure_ascii=False))
    except Exception as error:
        print(json.dumps(control.failure(value, error)))
        sys.exit(2)

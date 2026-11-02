#!/usr/bin/env python3
"""Explicit V2 control of existing owned bridges. Never starts a runtime."""
import argparse
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
import time
import uuid
import runtime

OPS = {'status', 'stats', 'stop', 'contact', 'chat', 'prepare_crypto', 'send_text',
       'reply_notification', 'join_room', 'leave_room', 'start_call', 'accept_call',
       'reject_call', 'add_participant', 'start_group_call', 'accept_invite',
       'reject_invite', 'hangup', 'retract_call', 'authorize_room'}


def validate(value):
    assert isinstance(value, dict) and value.get('role') in runtime.OWN
    assert value.get('action') in ('state', 'command', 'result')
    assert value.get('transport') in ('local-android', 'server'), 'Explicit transport required'
    if value['transport'] == 'local-android':
        assert value['role'] in ('nora', 'leon')
    else:
        assert value['role'] == 'felix', 'V2 never routes Leon back to DinoX'
    wait = value.get('wait', 0)
    assert type(wait) in (int, float) and 0 <= wait <= 60
    if value['action'] in ('command', 'result'):
        assert isinstance(value.get('id'), str) and re.fullmatch('[0-9a-f]{32}', value['id'])
    if value['action'] == 'command':
        payload = value.get('payload')
        assert isinstance(payload, dict) and payload.get('op') in OPS
        assert 'id' not in payload and 'run_id' not in payload
        reject_private(payload)
    return value


def reject_private(value):
    if isinstance(value, dict):
        assert not any(k.casefold() in ('password', 'database_password', 'db_key', 'config') for k in value)
        for item in value.values(): reject_private(item)
    elif isinstance(value, list):
        for item in value: reject_private(item)


def normalize(value, config):
    runtime.validate_private_config(value['role'], config)
    request = dict(value['payload'])
    if 'peer' in request:
        peer = request['peer']
        assert isinstance(peer, str) and not any(c.isspace() or ord(c) < 32 for c in peer)
        peer = runtime.OWN.get(peer.casefold(), peer)
        assert peer in config['allowed_jids'], 'Bare owned Android peer required'
        request['peer'] = peer
    request.update(run_id=runtime.RUN, id=value['id'])
    return request


def redact(value, config):
    secrets = [config.get(k) for k in ('password', 'database_password', 'db_key') if config.get(k)]
    if isinstance(value, dict):
        return {k: '[redacted]' if k.casefold() in ('password', 'database_password', 'db_key', 'config') else redact(v, config)
                for k, v in value.items()}
    if isinstance(value, list): return [redact(x, config) for x in value]
    if isinstance(value, str):
        for secret in sorted(secrets, key=len, reverse=True): value = value.replace(secret, '[redacted]')
    return value


def failure(value, error):
    result = {'schema_version': 2, 'ok': False, 'error_type': type(error).__name__,
              'submission_outcome_unknown': isinstance(value, dict) and value.get('action') == 'command',
              'automatic_retry': False}
    if isinstance(value, dict):
        result.update(role=value.get('role'), id=value.get('id'), run_id=runtime.RUN,
                      action=value.get('action'), transport=value.get('transport'))
    return result


class Android:
    def __init__(self, role):
        self.role = role
        self.settings = runtime.control_settings(role)
        self.adb = runtime.adb_command(role)
        self.env = runtime.environment(role)
        with socket.create_connection(('127.0.0.1', self.settings['adb_port']), timeout=2): pass

    def call(self, mode, *args, data=None, exists=False):
        # Revalidate exact live owners before every operation. No ADB autostart
        # is accepted as a replacement for the owned server.
        runtime.control_settings(self.role)
        transport = ['shell', '-T'] if mode in ('exec-in', 'exec-out') else [mode]
        result = subprocess.run([*self.adb, *transport, 'run-as', runtime.v1.PACKAGE, *args],
                                env=self.env, input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=8)
        assert result.returncode in ((0, 1) if exists else (0,)), 'Owned Android I/O failed'
        return result

    def has(self, name):
        return self.call('exec-out', 'test', '-e', 'files/interop/' + name, exists=True).returncode == 0

    def read(self, name):
        if not self.has(name): return None
        raw = self.call('exec-out', 'cat', 'files/interop/' + name).stdout
        assert len(raw) <= 4 * 1024**2
        if not raw.strip(): return None
        try: return json.loads(raw)
        except json.JSONDecodeError: return None

    def submit(self, identifier, request):
        assert not self.has('inbox/' + identifier + '.json') and not self.has('results/' + identifier + '.json')
        lock = 'files/interop/inbox/.' + identifier + '.lock'
        temporary = lock + '/command.partial'
        self.call('exec-out', 'mkdir', lock)
        try:
            raw = json.dumps(request).encode()
            self.call('exec-in', 'dd', 'of=' + temporary, data=raw)
            assert self.call('exec-out', 'cat', temporary).stdout == raw, 'Incomplete command transfer'
            self.call('exec-out', 'chmod', '600', temporary)
            self.call('exec-out', 'mv', '-n', temporary, 'files/interop/inbox/' + identifier + '.json')
            self.call('exec-out', 'test', '!', '-e', temporary)
        finally:
            self.call('exec-out', 'rm', '-f', temporary)
            self.call('exec-out', 'rmdir', lock)


def control(value):
    validate(value)
    if value['transport'] == 'server':
        completed = subprocess.run([sys.executable, str(runtime.HERE.parent / 'server_control.py'), '--stdin'],
                                   input=json.dumps(value).encode(), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   timeout=value.get('wait', 0) + 80)
        assert completed.returncode == 0, 'Existing Felix server control failed'
        return json.loads(completed.stdout)
    backend = Android(value['role'])
    config = backend.read('config.json')
    runtime.validate_private_config(value['role'], config)
    if value['action'] == 'command': backend.submit(value['id'], normalize(value, config))
    name = 'state.json' if value['action'] == 'state' else 'results/' + value['id'] + '.json'
    deadline = time.monotonic() + value.get('wait', 0)
    while True:
        response = backend.read(name)
        if response is not None:
            assert response['run_id'] == runtime.RUN and response['account'] == runtime.OWN[value['role']]
            if value['action'] != 'state': assert response['id'] == value['id']
            return redact({'schema_version': 2, 'role': value['role'], 'run_id': runtime.RUN,
                           'transport': 'local-android', 'id': value.get('id'), 'response': response,
                           'completed': True, 'submitted': value['action'] == 'command'}, config)
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return {'schema_version': 2, 'role': value['role'], 'run_id': runtime.RUN,
                    'transport': 'local-android', 'id': value.get('id'), 'completed': False,
                    'submitted': value['action'] == 'command', 'pending': True}
        time.sleep(min(.25, remaining))


def arguments():
    if sys.argv[1:] == ['--stdin']:
        raw = sys.stdin.read(32769)
        assert len(raw) <= 32768
        return validate(json.loads(raw))
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('state', 'command', 'result'))
    parser.add_argument('role', choices=tuple(runtime.OWN))
    parser.add_argument('--transport', required=True, choices=('local-android', 'server'))
    parser.add_argument('--wait', type=float, default=0)
    parser.add_argument('--json')
    parser.add_argument('--id')
    args = parser.parse_args()
    value = {'action': args.action, 'role': args.role, 'transport': args.transport, 'wait': args.wait}
    if args.action == 'command': value.update(id=uuid.uuid4().hex, payload=json.loads(args.json))
    if args.action == 'result': value['id'] = args.id
    return validate(value)


if __name__ == '__main__':
    value = None
    try:
        value = arguments()
        print(json.dumps(control(value), ensure_ascii=False))
    except Exception as error:
        print(json.dumps(failure(value, error)))
        sys.exit(2)

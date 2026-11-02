#!/usr/bin/env python3
"""Future single idle start and separate read-only readiness; no call/account commands."""
import datetime
import json
import os
import subprocess
import sys
import time
import runtime_spec as s

os.umask(0o077)


def cleanup(rows):
    result = {}
    for role, row in rows.items():
        info = s.inspect(row['container_id'])
        if info['State']['Running']:
            s.check_container(info, row, role, True)
            stopped = s.call(['stop', '-t', '20', row['container_id']])
            after = s.inspect(row['container_id'])
            assert not after['State']['Running'] and after['State']['Pid'] == 0
            result[role] = {'stop_exit': stopped.returncode, 'state': after['State']}
    s.save('idle-failure-exact-sigterm-cleanup.json', result)


def start(rows):
    assert not (s.HERE / 'idle-start-attempt.json').exists(), 'No repeated start'
    for role, row in rows.items():
        info = s.inspect(row['container_id']); s.check_container(info, row, role, False)
        s.save(role + '-actual-before-idle-start-inspect.json', [info])
    s.save('idle-start-attempt.json', {'observed_unix': time.time(), 'roles': rows, 'no_call_or_account_commands': True})
    for role, row in rows.items():
        result = s.call(['start', row['container_id']])
        s.save(role + '-actual-idle-start-result.json', {'exit': result.returncode, 'stdout': result.stdout,
                                                      'stderr': result.stderr, 'observed_unix': time.time()})
        assert result.stdout.strip() == row['container_id']


def proof(rows, admission_sha):
    summary = {}
    for role, row in rows.items():
        cid = row['container_id']; info = s.inspect(cid); s.check_container(info, row, role, True)
        s.save(role + '-actual-running-inspect.json', [info])
        started = datetime.datetime.fromisoformat(info['State']['StartedAt'].replace('Z', '+00:00')).timestamp()
        request = {'action': 'state', 'role': role, 'transport': 'server', 'wait': 0,
                   'native_admission_sha256': admission_sha}
        deadline = time.monotonic() + 60
        while True:
            # A retained state file may describe the previous process. Require a fresh write
            # before reading its redacted public state through the unchanged control protocol.
            state_path = s.PROFILE + '/runner-profiles/' + role + '/state.json'
            freshness = s.call(['exec', '-i', '--user', '1000:1000', cid, 'python3', '-c',
                'from pathlib import Path;import json,sys;p=Path(sys.argv[1]);print(json.dumps(p.stat().st_mtime if p.is_file() and not p.is_symlink() else 0))', state_path])
            if float(json.loads(freshness.stdout)) < started:
                assert time.monotonic() < deadline, 'No fresh state from the actual driver'
                time.sleep(1)
                continue
            q = subprocess.run(['python3', '-B', str(s.HERE / 'native_control.py'), '--stdin'],
                               input=json.dumps(request), capture_output=True, text=True, timeout=45)
            assert q.returncode == 0
            envelope = json.loads(q.stdout); assert envelope['completed']
            state = envelope['response']; observer = state.get('private_wire_observers') or {}
            if state.get('online') and observer.get('actual_attached') and not observer.get('late_attach_pending'): break
            assert time.monotonic() < deadline, 'Bounded idle observation failed; no retry/start/account mutation'
            time.sleep(1)
        s.save(role + '-actual-fresh-idle-state.json', state)
        account = role + ('.fischer' if role == 'leon' else '.wagner') + '.interop.de.71115b@dinox.im'
        assert state['account'] == account and state['full_jid'].startswith(account + '/')
        assert (state['own_omemo_device_id'], state['own_public_identity_hex']) == s.PUBLIC[role]
        assert state['profile_lock_held'] and not state.get('call') and not state.get('sessions')
        assert observer['real_draft_module_present'] and not observer['finished']
        assert observer['local_full_jid'] == state['full_jid'] and observer['stream_generation'] > 0
        assert observer['records'] > 0 and observer['bytes'] > 0
        observer_path = observer['path']
        assert observer_path.startswith(s.PROFILE + '/runner-profiles/' + role + '/private-wire-observers-')
        assert observer_path.endswith('.jsonl') and '/..' not in observer_path
        public_code = ('from pathlib import Path;import json,hashlib,sys;'
                       'p=Path(sys.argv[1]);assert p.is_file() and not p.is_symlink() and p.stat().st_size<=2097152;'
                       'raw=p.read_bytes();assert p.stat().st_mode&511==384;'
                       'print(json.dumps({"sha256":hashlib.sha256(raw).hexdigest(),"rows":[json.loads(l) for l in raw.splitlines()]}))')
        q = s.call(['exec', '-i', '--user', '1000:1000', cid, 'python3', '-c', public_code, observer_path])
        actual = json.loads(q.stdout)
        assert any(item['event'] == 'observer_stream_attached' and item['account'] == account
                   and item['local_full_jid'] == state['full_jid'] and item['stream_generation'] == observer['stream_generation']
                   and item['real_draft_module_present'] for item in actual['rows'])
        s.save(role + '-actual-observer-attachment.json', actual)
        wrapper = s.MOUNT + '/qualified-runtime/lib/libdinox-google-webrtc.so'
        config = {'binary': s.BINARY, 'artifacts': s.ARTIFACTS, 'profile': s.PROFILE, 'library_path': s.LIBRARY_PATH,
                  'worker': s.WORKER, 'runtime_lib': s.MOUNT + '/qualified-runtime/lib', 'wrapper': wrapper,
                  'required_driver_maps': [s.BINARY, s.MOUNT + '/lib/libdino.so.0', s.MOUNT + '/lib/libxmpp-vala.so.0',
                                           s.MOUNT + '/lib/omemo.so', wrapper, s.SESSION_PATH],
                  'optional_codec_maps': [s.MOUNT + '/qualified-runtime/lib/' + p for p in ('libavcodec-dinox-hw.so.62', 'libavutil-dinox-hw.so.60')]}
        q = subprocess.run(s.DOCKER + ['exec', '-i', '--user', '1000:1000', cid, 'python3', '-', role, str(started), json.dumps(config)],
                           input=(s.HERE / 'inner_maps.py').read_text(), text=True, capture_output=True, timeout=60)
        s.save(role + '-actual-maps-result.json', {'exit': q.returncode, 'stdout': q.stdout, 'stderr': q.stderr})
        assert q.returncode == 0
        mappings = json.loads(q.stdout); s.save(role + '-actual-current-maps-and-profile-fds.json', mappings)
        summary[role] = {'container_id': cid, 'full_jid': state['full_jid'], 'public_identity': list(s.PUBLIC[role]),
                         'pid': mappings['pid'], 'startticks': mappings['startticks'], 'online': True, 'idle': True,
                         'runtime_deadline_unix': started + 5400}
    s.save('actual-current-native-idle-readiness.json', {'result': 'CURRENT_NATIVE_IDLE_PUBLIC_IDENTITIES_AND_MAPS_ONLY',
           'observed_unix': time.time(), 'native_admission_sha256': admission_sha, 'roles': summary,
           'lazy_workers_or_codecs_not_falsely_claimed_loaded': True, 'calls_text_or_trust_commands_sent': False,
           'media_or_auth_pass': False})


def main():
    assert not sys.flags.optimize and len(sys.argv) == 3
    action, admission_sha = sys.argv[1:]
    assert action in ('--reviewed-idle-start-only', '--prove-idle-only')
    rows = s.admission(admission_sha)['roles']
    try:
        if action == '--reviewed-idle-start-only': start(rows)
        else: proof(rows, admission_sha)
    except BaseException:
        cleanup(rows)
        raise


if __name__ == '__main__': main()

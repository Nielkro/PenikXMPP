"""Exact current-driver staging inputs; no command runs on import."""
from pathlib import Path
import hashlib
import json
import re
import subprocess

HERE = Path(__file__).resolve().parent
REMOTE = '/home/cpaneladmin/dinox-current-native-85879bcf-20261018'
RUN = '20261015-71115b'
DOCKER = ['docker', 'exec', '-i', 'docker_dind', 'docker']
IMAGE = 'sha256:970d032c2b1ae6c46d011b8a5d8141cfdb58db7ba4273eafcf0c3726df810288'
VOLUME = 'dinox-interop-current-85879bcf-20261018'
MOUNT = '/driver-current'
MANIFEST_SHA = '8e4193f3d102c469139d1a2bd7d11985fae9e84bbba319eddd5a80ea249622fd'
LIBRARY_PATH = '/driver-current/lib:/driver-current/qualified-runtime/lib:/opt/interop/payload/lib'
WORKER = '/driver-current/qualified-runtime/lib/dinox-webrtc-worker'
PAYLOAD = Path('/home/cpaneladmin/dinox-current-driver-2c6dabad1b9f4285b124ef5d7efa5446')
BINARY = MOUNT + '/bin/dinox-interop-current'
PROFILE = '/interop/monocles-dinox-interop-20261015'
SESSION_PATH = '/opt/interop/payload/lib/libomemo-c.so.0'
SESSION_SHA = 'c9daded3b2ab289caa7f93276b86ea1d4e081547ed3280b37b71244f3defd484'
PUBLIC = {
    'leon': (172062497, '0557a3d930a3c5e30902ecd826c3c3df3807cf1ede7befd6250498add9e7462f1b'),
    'felix': (1228426141, '056a75e39f7fd0b4a4bcca19dcc8273e6c9174d4dc6c455ae0621de1fb6517bf7c'),
}


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def pinned_json(name, expected):
    path = HERE / name
    assert path.is_file() and not path.is_symlink() and digest(path) == expected
    return json.loads(path.read_bytes())


MANIFEST = pinned_json('overlay-manifest.json', MANIFEST_SHA)
TEMPLATE = pinned_json('launch-template.json', '79d1bd7b42cb4101205f5ccdd5113709015eb3fa48fee085060da99fc79a9279')
CREATE = pinned_json('historical-create-command.json', '89e8143b90f30c75f1dfffc6720ee587eac81e5161b350ccfd9853a9566e88bb')
ARTIFACTS = {MOUNT + '/' + name: row['sha256'] for name, row in MANIFEST['files'].items()}
ARTIFACTS[SESSION_PATH] = SESSION_SHA


def call(args, **kwargs):
    return subprocess.run(DOCKER + args, capture_output=True, text=True, timeout=60, check=True, **kwargs)


def save(name, value):
    import os
    fd = os.open(HERE / name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'w') as stream:
        json.dump(value, stream, indent=2); stream.write('\n'); stream.flush(); os.fsync(stream.fileno())


def inspect(target):
    return json.loads(call(['inspect', target]).stdout)[0]


def require_volume(name, created_at=None):
    row = json.loads(call(['volume', 'inspect', name]).stdout)[0]
    assert row['Name'] == name and row['Mountpoint'] == '/var/lib/docker/volumes/' + name + '/_data'
    assert row['Driver'] == 'local' and row['Labels']['im.dinox.interop.run'] == RUN
    if created_at is not None: assert row['CreatedAt'] == created_at
    if name == VOLUME: assert row['Labels']['im.dinox.interop.current'] == '85879bcf-20261018'
    return row


def require_peer_volumes(role):
    # Every named mount must already exist. Docker --mount would otherwise create an empty volume.
    return {name: require_volume(name, created) for name, created in (
        ('dinox-interop-20261015-payload', '2026-10-15T16:08:23Z'),
        (TEMPLATE[role]['profile_volume'], TEMPLATE[role]['profile_created_at']), (VOLUME, None))}


def check_container(info, row, role, running):
    assert role in PUBLIC and re.fullmatch('[0-9a-f]{64}', row['container_id'])
    assert info['Id'] == row['container_id'] and info['Name'] == '/dinox-interop-20261015-' + role
    assert info['Image'] == IMAGE and info['Config']['Image'] == IMAGE
    assert info['Config']['Cmd'] == row['cmd'] == [MOUNT + '/server_entry_' + role + '.sh', role]
    assert info['Config']['Entrypoint'] == ['/bin/sh']
    assert info['Config']['Labels']['im.dinox.interop.run'] == RUN
    assert info['Config']['Labels']['im.dinox.interop.current'] == '85879bcf-20261018'
    assert info['Config']['User'] == '1000:1000' and info['Config']['Hostname'] == TEMPLATE[role]['hostname']
    host = info['HostConfig']
    assert host['NanoCpus'] == 500000000 and host['Memory'] == host['MemorySwap'] == 536870912
    assert host['PidsLimit'] == 128 and host['ReadonlyRootfs'] and host['Init']
    assert host['CpuShares'] == 128 and host['ShmSize'] == 67108864 and host['IpcMode'] == 'private'
    assert host['NetworkMode'] == 'dinox-interop-20261015' and not host['Privileged']
    assert host['CapDrop'] == ['ALL'] and host['SecurityOpt'] == ['no-new-privileges']
    assert not host['Devices'] and not host['PortBindings'] and host['RestartPolicy']['Name'] == 'no'
    expected = {m['Destination']: (m['Name'], m['Source'], m['RW']) for m in TEMPLATE[role]['historical_mounts']
                if m['Destination'] in ('/opt/interop', PROFILE)}
    expected[MOUNT] = (VOLUME, '/var/lib/docker/volumes/' + VOLUME + '/_data', False)
    actual = {m['Destination']: (m.get('Name'), m['Source'], m['RW']) for m in info['Mounts']}
    assert len(actual) == len(info['Mounts']) and actual == expected
    state = info['State']
    assert state['Running'] is running and not state['OOMKilled'] and not state.get('Paused')
    if running:
        assert state['Status'] == 'running' and state['Pid'] > 0
    else:
        assert state['Status'] == 'created' and state['Pid'] == 0 and state['StartedAt'].startswith('0001-')


def admission(expected_sha):
    assert isinstance(expected_sha, str) and re.fullmatch('[0-9a-f]{64}', expected_sha)
    path = HERE / 'owner-native-admission.json'
    assert path.is_file() and not path.is_symlink() and path.stat().st_size < 65536
    assert path.stat().st_mode & 0o077 == 0 and digest(path) == expected_sha
    value = json.loads(path.read_bytes())
    assert value['run_id'] == RUN and value['overlay_manifest_sha256'] == MANIFEST_SHA
    assert value['scope'] == 'ACTUAL_CREATED_OFF_CURRENT_IDENTITIES_NOT_A_START_ADMISSION'
    assert value['readonly_overlay'] == VOLUME and value['artifacts_sha256'] == ARTIFACTS
    assert set(value['roles']) == set(PUBLIC)
    ids = []
    for role, row in value['roles'].items():
        assert re.fullmatch('[0-9a-f]{64}', row['container_id'])
        assert row['container_id'] != TEMPLATE[role]['historical_absent_id']
        assert row['name'] == 'dinox-interop-20261015-' + role
        assert row['cmd'] == [MOUNT + '/server_entry_' + role + '.sh', role]
        assert row['profile_volume'] == TEMPLATE[role]['profile_volume'] and row['created_never_started'] is True
        ids.append(row['container_id'])
    assert len(set(ids)) == 2
    return value

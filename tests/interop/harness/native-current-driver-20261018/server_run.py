#!/usr/bin/env python3
"""One separately authorized current-driver job in the retained compiler cache."""
from pathlib import Path
import hashlib
import io
import json
import re
import signal
import subprocess
import sys
import tarfile
import time

ROOT = Path(__file__).resolve().parent
DOCKER = ['docker', 'exec', '-i', 'docker_dind', 'docker']
OLD = 'dinox-interop-driver-capabilities-20261016'
OLD_ID = '7928c84b5b32d5346c0bfec74fd414508e6ee5fd6d296df91d921914a30c1535'
BASE = 'sha256:bfcc7b8942a7656a90b2ab40b73c9d29f1843b0df681b6994f89a67132b62391'


def command(args, **kw):
    return subprocess.check_output(DOCKER + args, **kw)


def write(name, value):
    p = ROOT / name
    p.write_text(json.dumps(value, indent=2) + '\n')
    p.chmod(0o600)


def main():
    assert len(sys.argv) == 3
    expected, token = sys.argv[1:]
    assert re.fullmatch(r'[a-f0-9]{64}', expected) and re.fullmatch(r'[a-f0-9]{32}', token)
    assert not any((ROOT / name).exists() for name in ('launch.json', 'terminal.json', 'console.log', 'artifacts', 'job-cleanup.json')), 'Use a fresh actual-job directory'
    archive = ROOT / 'payload.tar'
    assert hashlib.file_digest(archive.open('rb'), 'sha256').hexdigest() == expected
    with tarfile.open(archive) as payload:
        for directory in ('native-current-driver', 'native-current-driver/inputs'):
            member = payload.getmember(directory)
            assert member.isdir() and member.uid == member.gid == 1000 and member.mode == 0o700
        members = payload.getmembers()
        assert len({m.name for m in members}) == len(members)
        assert all(not Path(m.name).is_absolute() and '..' not in Path(m.name).parts and (m.isdir() or m.isfile()) for m in members)
        input_bytes = payload.extractfile('native-current-driver/input-manifest.json').read()
        assert hashlib.sha256(input_bytes).hexdigest() == '0e561ea789e456709fb725bd312ea9a8c8c9ed70e099779dc23d89db7393f8d3'
        inputs = json.loads(input_bytes)
        expected_files = {'native-current-driver/' + name for name in inputs['files']} | {'native-current-driver/server_compile.py', 'native-current-driver/input-manifest.json'}
        assert {m.name for m in members if m.isfile()} == expected_files
        expected_directories = {str(parent) for name in expected_files for parent in Path(name).parents if str(parent) != '.'}
        assert {m.name for m in members if m.isdir()} == expected_directories
        assert all(m.uid == m.gid == 1000 and m.mode == (0o700 if m.isdir() else 0o600) for m in members)
        compiler_sha = hashlib.sha256(payload.extractfile('native-current-driver/server_compile.py').read()).hexdigest()
        assert compiler_sha == hashlib.file_digest((ROOT / 'server_compile.py').open('rb'), 'sha256').hexdigest()
    old = json.loads(command(['inspect', OLD]))[0]
    assert old['Id'] == OLD_ID and old['Image'] == BASE
    assert not old['State']['Running'] and old['State']['ExitCode'] == 0
    name = 'dinox-current-driver-' + token
    tag = 'dinox-current-driver-cache:' + token
    image = command(['commit', OLD, tag], text=True).strip()
    container = None
    def interrupted(signum, _frame):
        raise SystemExit(128 + signum)
    for signum in (signal.SIGTERM, signal.SIGINT):
        signal.signal(signum, interrupted)
    try:
        container = command([
            'create', '--name', name, '--network', 'none', '--cpus', '2',
            '--memory', '4g', '--memory-swap', '4g', '--pids-limit', '128',
            '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges:true',
            '--user', '1000:1000', '--workdir', '/work/native-current-driver',
            '--tmpfs', '/tmp:rw,size=268435456',
            '--log-opt', 'max-size=10m', '--log-opt', 'max-file=1',
            '--mount', 'type=volume,source=dinox-interop-20261015-payload,target=/opt/interop,readonly',
            '--entrypoint', 'nice', image, '-n', '19', 'python3', '-B',
            '/work/native-current-driver/server_compile.py'], text=True).strip()
        with archive.open('rb') as data:
            subprocess.run(DOCKER + ['cp', '-', container + ':/work/'], stdin=data, check=True)
        copied = command(['cp', container + ':/work/native-current-driver/server_compile.py', '-'])
        with tarfile.open(fileobj=io.BytesIO(copied)) as verification:
            members = verification.getmembers()
            assert len(members) == 1 and members[0].isfile()
            assert members[0].uid == members[0].gid == 1000 and members[0].mode & 0o400
            assert hashlib.sha256(verification.extractfile(members[0]).read()).hexdigest() == compiler_sha
        item = json.loads(command(['inspect', container]))[0]
        host = item['HostConfig']
        assert item['Config']['User'] == '1000:1000' and item['Config']['WorkingDir'] == '/work/native-current-driver'
        assert host['NetworkMode'] == 'none' and host['NanoCpus'] == 2000000000
        assert host['Memory'] == host['MemorySwap'] == 4294967296
        assert host['PidsLimit'] == 128 and host['CapDrop'] == ['ALL']
        assert len(item['Mounts']) == 1 and item['Mounts'][0]['Destination'] == '/opt/interop'
        assert item['Mounts'][0]['RW'] is False
        write('launch.json', {'old_cache_container': OLD_ID, 'base_image': BASE,
                             'snapshot_image': image, 'container': container,
                             'name': name, 'payload_sha256': expected,
                             'limits': {k: host[k] for k in ('NanoCpus', 'Memory', 'MemorySwap', 'PidsLimit', 'NetworkMode')},
                             'started_unix': time.time(), 'native_peer_or_profile_touched': False})
        command(['start', container])
        print('BOUNDED_OFFLINE_DRIVER_STARTED', name, flush=True)
        try:
            exit_code = int(command(['wait', container], timeout=1260, text=True).strip())
        except subprocess.TimeoutExpired:
            command(['stop', '-t', '30', container], timeout=45)
            raise
        item = json.loads(command(['inspect', container]))[0]
        assert not item['State']['Running'] and not item['State']['OOMKilled']
        print('BOUNDED_OFFLINE_DRIVER_FINISHED', exit_code, flush=True)
        assert exit_code == 0, 'Inspect the saved actual compiler/test logs'
    finally:
        for signum in (signal.SIGTERM, signal.SIGINT):
            signal.signal(signum, signal.SIG_IGN)
        cleanup = {'own_container_removed': False, 'own_cache_snapshot_removed': False,
                   'payload_profiles_or_other_containers_removed': False, 'evidence_export_errors': []}
        if container:
            try:
                item = json.loads(command(['inspect', container]))[0]
                if item['State']['Running']:
                    command(['stop', '-t', '30', container], timeout=45)
                item = json.loads(command(['inspect', container]))[0]
                write('terminal.json', {'exit_code': item['State']['ExitCode'], 'state': item['State'],
                                        'container': container, 'completed_unix': time.time()})
                try:
                    (ROOT / 'console.log').write_bytes(command(['logs', container], stderr=subprocess.STDOUT))
                except Exception as error:
                    cleanup['evidence_export_errors'].append('console: ' + repr(error))
                try:
                    exported = command(['cp', container + ':/work/native-current-driver/artifacts', '-'])
                    with tarfile.open(fileobj=io.BytesIO(exported)) as artifacts:
                        assert all(not Path(member.name).is_absolute() and
                                   '..' not in Path(member.name).parts and
                                   (member.isfile() or member.isdir()) and
                                   (member.name == 'artifacts' or member.name.startswith('artifacts/'))
                                   for member in artifacts.getmembers())
                        artifacts.extractall(ROOT, filter='data')
                except Exception as error:
                    cleanup['evidence_export_errors'].append('artifacts: ' + repr(error))
            finally:
                command(['rm', container])
                cleanup['own_container_removed'] = True
        command(['image', 'rm', tag])
        cleanup['own_cache_snapshot_removed'] = True
        cleanup['old_cache_unchanged'] = json.loads(command(['inspect', OLD]))[0]['Id'] == OLD_ID
        write('job-cleanup.json', cleanup)


if __name__ == '__main__':
    main()

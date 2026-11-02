#!/usr/bin/env python3
"""Future one-shot additive stage from existing server bytes; no profile mount."""
from pathlib import Path
import hashlib
import io
import json
import os
import re
import subprocess
import sys
import tarfile
import time
import runtime_spec as s

os.umask(0o077)
HELPER = s.VOLUME + '-stage'
CHECK = s.VOLUME + '-loader'


def main():
    assert not sys.flags.optimize and sys.argv[1:] == ['--reviewed-stage-only']
    assert not (s.HERE / 'stage-attempt.json').exists(), 'No automatic second stage'
    archive = s.PAYLOAD / 'payload.tar'
    assert archive.stat().st_size == s.MANIFEST['archive_bytes'] and s.digest(archive) == s.MANIFEST['archive_sha256']
    binary = s.PAYLOAD / 'artifacts/native-driver/dinox-interop-current'
    assert s.digest(binary) == s.MANIFEST['files']['bin/dinox-interop-current']['sha256']
    assert os.statvfs(s.HERE).f_bavail * os.statvfs(s.HERE).f_frsize > 5 * 1024 ** 3 + s.MANIFEST['total_bytes']
    for name in (HELPER, CHECK):
        result = subprocess.run(s.DOCKER + ['inspect', name], capture_output=True, text=True, timeout=30)
        assert result.returncode == 1 and result.stderr.strip().casefold() == ('error: no such object: ' + name).casefold()
    result = subprocess.run(s.DOCKER + ['volume', 'inspect', s.VOLUME], capture_output=True, text=True, timeout=30)
    assert result.returncode == 1 and 'no such volume' in result.stderr.casefold()
    assert not s.call(['ps', '-q', '--filter', 'label=im.dinox.interop.run=' + s.RUN]).stdout.strip()
    temporary = s.HERE / 'overlay-transfer.tar'
    assert not temporary.exists()
    # Select only pinned prebuilt files. Never extract profile/account data or the full source payload.
    with tarfile.open(archive) as incoming, temporary.open('xb') as output, tarfile.open(fileobj=output, mode='w') as outgoing:
        members = incoming.getmembers(); by_name = {m.name: m for m in members}
        assert len(by_name) == len(members)
        directories = {s.MOUNT.lstrip('/')}
        for name in s.MANIFEST['files']:
            parent = Path(s.MOUNT.lstrip('/') + '/' + name).parent
            while str(parent) != '.': directories.add(str(parent)); parent = parent.parent
        for name in sorted(directories, key=lambda p: (p.count('/'), p)):
            item = tarfile.TarInfo(name); item.type = tarfile.DIRTYPE; item.uid = item.gid = 1000; item.mode = 0o755
            outgoing.addfile(item)
        for name, row in s.MANIFEST['files'].items():
            kind, source = row['source'].split(':', 1)
            if kind == 'tar':
                member = by_name[source]; assert member.isfile() and not member.issym() and member.size == row['bytes']
                data = incoming.extractfile(member).read()
            else:
                path = s.HERE / source if kind == 'source' else s.PAYLOAD / source
                assert path.is_file() and not path.is_symlink(); data = path.read_bytes()
            assert len(data) == row['bytes'] and hashlib.sha256(data).hexdigest() == row['sha256']
            item = tarfile.TarInfo(s.MOUNT.lstrip('/') + '/' + name)
            item.mode = row['mode']; item.uid = item.gid = 1000; item.size = len(data)
            outgoing.addfile(item, io.BytesIO(data))
    s.save('stage-attempt.json', {'observed_unix': time.time(), 'volume': s.VOLUME,
           'manifest_sha256': s.MANIFEST_SHA, 'no_profiles_or_peer_start': True})
    helper_id = checker_id = None
    try:
        s.require_volume('dinox-interop-20261015-payload', '2026-10-15T16:08:23Z')
        s.call(['volume', 'create', '--label', 'im.dinox.interop.run=' + s.RUN, '--label', 'im.dinox.interop.current=85879bcf-20261018', s.VOLUME])
        s.require_volume(s.VOLUME)
        made = s.call(['create', '--name', HELPER, '--pull=never', '--network', 'none', '--cpus', '.25', '--memory', '128m',
                      '--memory-swap', '128m', '--pids-limit', '64', '--label', 'im.dinox.interop.run=' + s.RUN,
                      '--mount', 'type=volume,src=' + s.VOLUME + ',dst=' + s.MOUNT, '--entrypoint', '/bin/false', s.IMAGE])
        helper_id = made.stdout.strip(); assert re.fullmatch('[0-9a-f]{64}', helper_id)
        helper = s.inspect(helper_id)
        assert helper['Id'] == helper_id and helper['Name'] == '/' + HELPER and helper['State']['Status'] == 'created'
        with temporary.open('rb') as data:
            subprocess.run(s.DOCKER + ['cp', '-', helper_id + ':/'], stdin=data, check=True, capture_output=True, timeout=120)
        # One networkless, profile-free check, never a native peer or build.
        code = ('import hashlib,json,os,subprocess\nfrom pathlib import Path\n'
                + 'wanted=' + repr(s.ARTIFACTS) + '\n'
                + 'for p,h in wanted.items():\n'
                + ' with Path(p).open("rb") as f: assert hashlib.file_digest(f,"sha256").hexdigest()==h\n'
                + 'for p in ' + repr([s.WORKER, s.MOUNT + '/qualified-runtime/lib/dinox-vision-worker', s.BINARY]) + ': assert os.access(p,os.X_OK)\n'
                + 'for p in ' + repr([s.BINARY, s.MOUNT + '/lib/omemo.so'] + [s.MOUNT + '/' + p for p in s.MANIFEST['qualified_runtime_elf_files']]) + ':\n'
                + ' q=subprocess.run(["ldd","-r",p],text=True,capture_output=True,timeout=30)\n'
                + ' assert q.returncode==0 and "not found" not in q.stdout+q.stderr and "undefined symbol" not in q.stdout+q.stderr\n'
                + ' print(json.dumps({"path":p,"stdout":q.stdout,"stderr":q.stderr}))\n')
        s.require_volume('dinox-interop-20261015-payload', '2026-10-15T16:08:23Z')
        s.require_volume(s.VOLUME)
        made = s.call(['create', '--name', CHECK, '--pull=never', '--network', 'none', '--read-only', '--cpus', '.25',
                      '--memory', '256m', '--memory-swap', '256m', '--pids-limit', '64', '--user', '1000:1000', '--cap-drop', 'ALL',
                      '--security-opt', 'no-new-privileges', '--label', 'im.dinox.interop.run=' + s.RUN,
                      '--env', 'LD_LIBRARY_PATH=' + s.LIBRARY_PATH, '--mount', 'type=volume,src=' + s.VOLUME + ',dst=' + s.MOUNT + ',readonly',
                      '--mount', 'type=volume,src=dinox-interop-20261015-payload,dst=/opt/interop,readonly',
                      '--entrypoint', '/usr/bin/nice', s.IMAGE, '-n', '19', 'timeout', '--signal=TERM', '--kill-after=5', '90', 'python3', '-c', code])
        checker_id = made.stdout.strip(); assert re.fullmatch('[0-9a-f]{64}', checker_id)
        result = s.call(['start', '-a', checker_id]); s.save('stage-loader.json', {'exit': result.returncode, 'stdout': result.stdout, 'stderr': result.stderr})
        assert s.inspect(checker_id)['State']['ExitCode'] == 0
        driver = json.loads(result.stdout.splitlines()[0])['stdout']
        for lib, path in {'libdino.so.0': '/driver-current/lib/libdino.so.0',
                          'libxmpp-vala.so.0': '/driver-current/lib/libxmpp-vala.so.0',
                          'omemo.so': '/driver-current/lib/omemo.so',
                          'libdinox-google-webrtc.so': '/driver-current/qualified-runtime/lib/libdinox-google-webrtc.so',
                          'libomemo-c.so.0': s.SESSION_PATH}.items():
            assert lib + ' => ' + path + ' (' in driver
    finally:
        cleanup = []
        for cid in (checker_id, helper_id):
            if cid:
                row = s.inspect(cid)
                assert row['Id'] == cid and row['Config']['Labels']['im.dinox.interop.run'] == s.RUN
                if row['State']['Running']: s.call(['stop', '-t', '5', cid])
                s.call(['rm', cid])  # Only exact helper IDs made above, never native peers or old IDs.
                absent = subprocess.run(s.DOCKER + ['inspect', cid], capture_output=True, text=True, timeout=30)
                assert absent.returncode == 1 and absent.stderr.strip().casefold() == ('error: no such object: ' + cid).casefold()
                cleanup.append({'exact_id': cid, 'inspect_exit': absent.returncode, 'stderr': absent.stderr})
        temporary.unlink(missing_ok=True)
        s.save('stage-helper-cleanup.json', {'observed_unix': time.time(), 'removed': cleanup, 'temporary_transfer_removed': True})
    s.save('stage-receipt.json', {'result': 'PASS_NEW_RO_OVERLAY_COMPLETE_CLOSURE_HASH_AND_LOADER_ONLY',
           'observed_unix': time.time(), 'manifest_sha256': s.MANIFEST_SHA, 'files': 49, 'bytes': s.MANIFEST['total_bytes'],
           'profile_mounts': False, 'peer_starts': False, 'helpers_exactly_removed': True,
           'source_payload_retained_until_reviewed_staging_export': True})
    print(json.dumps({'result': 'STAGED_RO_CLOSURE_ONLY_NO_NATIVE_PEER_START', 'volume': s.VOLUME}))


if __name__ == '__main__': main()

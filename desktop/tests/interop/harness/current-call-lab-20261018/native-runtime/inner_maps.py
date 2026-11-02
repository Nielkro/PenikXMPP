"""Injected read-only PID/maps/FD proof; arguments contain public pins, no secrets."""
from pathlib import Path
import hashlib
import json
import os
import sys
import time

role, started, config = sys.argv[1], float(sys.argv[2]), json.loads(sys.argv[3])
binary, expected = config['binary'], config['artifacts']


def ticks(pid):
    return (Path('/proc') / str(pid) / 'stat').read_text().rsplit(')', 1)[1].split()[19]


def file_hash(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


processes = []
for entry in Path('/proc').iterdir():
    if not entry.name.isdecimal(): continue
    try: processes.append((int(entry.name), os.readlink(entry / 'exe')))
    except (FileNotFoundError, PermissionError, ProcessLookupError): pass
drivers = [pid for pid, exe in processes if Path(exe).name.startswith('dinox-interop')]
assert len(drivers) == 1
pid = drivers[0]; proc = Path('/proc') / str(pid); before = ticks(pid)
exe_stat = (proc / 'exe').stat()
assert os.readlink(proc / 'exe') == binary and exe_stat.st_uid == 1000
argv = [x.decode() for x in (proc / 'cmdline').read_bytes().split(b'\0') if x]
assert argv == [binary, config['profile'] + '/runner-profiles/' + role]
environment = dict(p.split(b'=', 1) for p in (proc / 'environ').read_bytes().split(b'\0') if b'=' in p)
assert environment[b'LD_LIBRARY_PATH'].decode() == config['library_path']
assert environment[b'DINOX_WEBRTC_WORKER_PATH'].decode() == config['worker']
assert environment[b'DINOX_GOOGLE_WEBRTC_AUDIO_DEVICE'] == b'synthetic'
for path, digest in expected.items():
    assert file_hash(path) == digest


def mapped(target_pid, wanted, optional=()):
    raw = (Path('/proc') / str(target_pid) / 'maps').read_text()
    output = {}
    for path in list(wanted) + list(optional):
        canonical = str(Path(path).resolve(strict=True)); basename = Path(canonical).name
        family = 'libomemo-c.so' if basename.startswith('libomemo-c.so') else basename
        lines = [line for line in raw.splitlines() if len(line.split(None, 5)) == 6
                 and (Path(line.split(None, 5)[5]).name.startswith(family) if family == 'libomemo-c.so'
                      else Path(line.split(None, 5)[5]).name == basename)]
        if not lines and path in optional: continue
        assert lines and {line.split(None, 5)[5] for line in lines} == {canonical}, 'Missing, old or parallel actual module'
        status = Path(canonical).stat(); assert file_hash(canonical) == expected[path]
        for line in lines:
            fields = line.split(None, 5); major, minor = (int(x, 16) for x in fields[3].split(':'))
            assert int(fields[4]) == status.st_ino and (major, minor) == (os.major(status.st_dev), os.minor(status.st_dev))
        output[path] = {'canonical_path': canonical, 'sha256': expected[path], 'inode': status.st_ino,
                        'dev': status.st_dev, 'segments': lines}
    return output


modules = mapped(pid, config['required_driver_maps'], config['optional_codec_maps'])
workers = []
for worker_pid, executable in processes:
    name = Path(executable).name
    if name not in ('dinox-webrtc-worker', 'dinox-vision-worker'): continue
    path = config['runtime_lib'] + '/' + name
    assert executable == path and file_hash(executable) == expected[path]
    worker_proc = Path('/proc') / str(worker_pid); worker_ticks = ticks(worker_pid)
    assert worker_proc.stat().st_uid == 1000
    ancestor = worker_pid
    for _ in range(20):
        ancestor = int((Path('/proc') / str(ancestor) / 'stat').read_text().rsplit(')', 1)[1].split()[1])
        if ancestor in (0, 1, pid): break
    assert ancestor == pid, 'Worker does not belong to this actual driver'
    worker_maps = mapped(worker_pid, [path] + ([config['wrapper']] if name == 'dinox-webrtc-worker' else []), config['optional_codec_maps'])
    assert ticks(worker_pid) == worker_ticks and os.readlink(worker_proc / 'exe') == path
    workers.append({'pid': worker_pid, 'startticks': worker_ticks, 'exe': path, 'maps': worker_maps})
profile = config['profile'] + '/peers/profiles/' + role + '-de/data'
opened = []
for fd in (proc / 'fd').iterdir():
    try: target = os.readlink(fd)
    except (FileNotFoundError, PermissionError): continue
    if target.startswith(profile + '/'): opened.append({'fd': int(fd.name), 'target': target})
assert any('.db' in item['target'] for item in opened)
state = Path(config['profile']) / 'runner-profiles' / role / 'state.json'
assert state.stat().st_mtime >= started
assert ticks(pid) == before and os.readlink(proc / 'exe') == binary
assert (proc / 'exe').stat().st_ino == exe_stat.st_ino
print(json.dumps({'observed_unix': time.time(), 'pid': pid, 'startticks': before, 'exe': binary,
      'uid': exe_stat.st_uid, 'exe_inode': exe_stat.st_ino, 'argv': argv, 'actual_modules': modules,
      'actual_workers_if_started': workers, 'all_artifact_hashes': expected, 'retained_profile_root': profile,
      'open_profile_files': opened, 'state_file_mtime': state.stat().st_mtime, 'start_unix': started,
      'current_library_path': config['library_path'], 'current_worker_path': config['worker'],
      'absent_lazy_workers_or_codecs_are_not_claimed_loaded': True, 'auth_or_media_proven': False}))

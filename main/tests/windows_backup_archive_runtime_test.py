#!/usr/bin/env python3
"""Exercise the actual Windows archive helper with independent tar fixtures."""

# Copyright (C) 2026 Ralf Peter <dinox@handwerker.jetzt>
# SPDX-License-Identifier: GPL-3.0-or-later

import io
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile

sys.stdout.reconfigure(encoding='utf-8')
if len(sys.argv) != 2:
    raise SystemExit(f'usage: {Path(sys.argv[0]).name} HELPER_EXE')
helper = str(Path(sys.argv[1]).resolve())
root = Path(tempfile.mkdtemp(prefix='dinox-archive-helper-fixtures-'))
passed = 0

def run(mode, cwd, data=None):
    return subprocess.run([helper, mode], cwd=cwd, input=data,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)

def check(condition, message):
    global passed
    if not condition:
        raise AssertionError(message)
    passed += 1
    print('PASS', message, flush=True)

try:
    version = subprocess.run([helper, '--version'], stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, timeout=15)
    check(version.returncode == 0 and version.stdout.startswith(b'DinoX backup archive helper 1 ('),
          'native helper loads and reports its version')
    source = root/'Игорь Петров % ! ^ &'
    expected = {
        'dinox/database.db': bytes(range(256))*20000,
        'dinox/данные äöü.txt': 'DinoX Игорь äöü\n'.encode(),
        'dinox/中文/😀 % ! ^ &.bin': b'\0\r\n\xff\x1a\x00data',
        'dinox/empty.txt': b'',
    }
    for name, data in expected.items():
        p = source/name
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(data)
        os.utime(p, (1700000000,1700000000))
    (source/'dinox/пустая').mkdir()
    os.utime(source/'dinox/пустая', (1700000000, 1700000000))
    created = run('create', source)
    check(created.returncode == 0, 'create Unicode + binary files: '+repr(created.stderr))
    check(created.stdout[:2] == b'\x1f\x8b', 'gzip header preserved')
    with tarfile.open(fileobj=io.BytesIO(created.stdout), mode='r:gz') as archive:
        actual = {m.name: archive.extractfile(m).read() for m in archive if m.isfile()}
        check(actual == expected, 'Python independently reads all created filenames and exact bytes')
        check(all(abs(archive.getmember(n).mtime-1700000000)<2 for n in expected), 'created file timestamps preserved')
        check(archive.getmember('dinox/пустая').isdir(), 'empty Unicode directory preserved')
    restore = root/'Восстановление % ! ^ &'
    restore.mkdir()
    restored = run('extract', restore, created.stdout)
    check(restored.returncode == 0, 'extract own archive: '+repr(restored.stderr))
    check(all((restore/name).read_bytes()==data for name,data in expected.items()), 'restored bytes match')
    check(all(abs((restore/n).stat().st_mtime-1700000000)<2 for n in expected), 'restored file timestamps preserved')
    check((restore/'dinox/пустая').is_dir() and abs((restore/'dinox/пустая').stat().st_mtime-1700000000)<2,
          'empty directory timestamp fixups complete before success')
    for fmt, label in [(tarfile.PAX_FORMAT,'PAX'), (tarfile.GNU_FORMAT,'GNU')]:
        buffer = io.BytesIO()
        with tarfile.open(fileobj=buffer, mode='w:gz', format=fmt) as archive:
            for name,data in expected.items():
                entry=tarfile.TarInfo(name); entry.size=len(data); entry.mtime=1700000000
                archive.addfile(entry, io.BytesIO(data))
        target=root/label; target.mkdir()
        result=run('extract',target,buffer.getvalue())
        check(result.returncode==0 and all((target/n).read_bytes()==d for n,d in expected.items()), label+' independent archive restores exact Unicode names and bytes: '+repr(result.stderr))
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode='w:gz', format=tarfile.PAX_FORMAT) as archive:
        child = tarfile.TarInfo('dinox/позже/file')
        child.size = 4
        archive.addfile(child, io.BytesIO(b'data'))
        parent = tarfile.TarInfo('dinox/позже/')
        parent.type = tarfile.DIRTYPE
        parent.mtime = 1700000000
        archive.addfile(parent)
    target = root/'later-directory'
    target.mkdir()
    result = run('extract', target, buffer.getvalue())
    check(result.returncode == 0 and (target/'dinox/позже/file').read_bytes() == b'data' and
          abs((target/'dinox/позже').stat().st_mtime - 1700000000) < 2,
          'later directory metadata preserves an implicitly created directory and its file')
    sentinel=root/'escape.txt'; sentinel.write_bytes(b'unchanged sentinel')
    bad_entries=[('../escape.txt',tarfile.REGTYPE,''), ('dinox/../../escape.txt',tarfile.REGTYPE,''),
                 (str(sentinel).replace('\\','/'),tarfile.REGTYPE,''), (str(sentinel).replace('\\','/').split(':',1)[-1],tarfile.REGTYPE,''),
                 ('dinox/file:stream',tarfile.REGTYPE,''), ('dinox/..\\escape.txt',tarfile.REGTYPE,''),
                 ('other/data',tarfile.REGTYPE,''), ('dinox/file.',tarfile.REGTYPE,''), ('dinox/file ',tarfile.REGTYPE,''), ('dinox/NUL.txt',tarfile.REGTYPE,''), ('dinox/link',tarfile.SYMTYPE,'../../escape'),
                 ('dinox/link',tarfile.LNKTYPE,'../escape.txt')]
    for i,(name,typ,link) in enumerate(bad_entries):
        buffer=io.BytesIO()
        with tarfile.open(fileobj=buffer,mode='w:gz',format=tarfile.PAX_FORMAT) as archive:
            entry=tarfile.TarInfo(name); entry.type=typ; entry.linkname=link
            if typ==tarfile.REGTYPE: entry.size=1
            archive.addfile(entry,io.BytesIO(b'x') if typ==tarfile.REGTYPE else None)
        target=root/('malformed'+str(i)); target.mkdir()
        result=run('extract',target,buffer.getvalue())
        check(result.returncode!=0,'reject unsafe archive entry '+repr(name)+' type='+repr(typ))
    check(sentinel.read_bytes()==b'unchanged sentinel', 'archive traversal did not change outside sentinel')
    collision_cases = [
        ('case collision', [('dinox/A.txt', tarfile.REGTYPE), ('dinox/a.txt', tarfile.REGTYPE)]),
        ('duplicate file', [('dinox/same.txt', tarfile.REGTYPE), ('dinox/same.txt', tarfile.REGTYPE)]),
        ('directory replaces file', [('dinox/data', tarfile.REGTYPE), ('dinox/data', tarfile.DIRTYPE)]),
        ('file replaces directory', [('dinox/data', tarfile.DIRTYPE), ('dinox/data', tarfile.REGTYPE)]),
        ('directory case alias', [('dinox/Data/one', tarfile.REGTYPE), ('dinox/data/two', tarfile.REGTYPE)]),
    ]
    for i, (label, entries) in enumerate(collision_cases):
        buffer = io.BytesIO()
        with tarfile.open(fileobj=buffer, mode='w:gz', format=tarfile.PAX_FORMAT) as archive:
            for j, (name, typ) in enumerate(entries):
                entry = tarfile.TarInfo(name)
                entry.type = typ
                data = f'entry {j}'.encode()
                if typ == tarfile.REGTYPE:
                    entry.size = len(data)
                archive.addfile(entry, io.BytesIO(data) if typ == tarfile.REGTYPE else None)
        target = root/('collision'+str(i))
        target.mkdir()
        result = run('extract', target, buffer.getvalue())
        check(result.returncode != 0, 'reject '+label+' without overwriting earlier data')
        if entries[0][1] == tarfile.REGTYPE:
            check((target/entries[0][0]).read_bytes() == b'entry 0', 'preserve first file after '+label)
    result = run('extract', restore, created.stdout)
    check(result.returncode != 0 and all((restore/n).read_bytes() == d for n,d in expected.items()),
          'reject nonempty extraction directory without changing existing data')
    target=root/'truncated'; target.mkdir()
    truncated=run('extract',target,created.stdout[:len(created.stdout)//2])
    check(truncated.returncode!=0,'reject truncated archive without false success')
    print('ARCHIVE_FIXTURE_CHECKS='+str(passed),flush=True)
finally:
    shutil.rmtree(root)

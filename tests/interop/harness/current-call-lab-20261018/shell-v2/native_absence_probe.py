#!/usr/bin/env python3
"""Read-only fixed remote absence proof; no container/profile/runtime mutation."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time

HOST = 'cpaneladmin@45.84.199.125'
IDS = {
    'leon': '2fd2a5dbf37029dccd0233a78a225316f9a70c4e9fef1c4dbfbc46241c610fac',
    'felix': '849fcd337a75f6230ea6c326cdabd55965de346286e1146a8f74f4c219f5ad17',
}
REMOTE_CODE = r'''
import json,subprocess,time
d=['docker','exec','-i','docker_dind','docker']
run='20261015-71115b'
ids={'leon':'2fd2a5dbf37029dccd0233a78a225316f9a70c4e9fef1c4dbfbc46241c610fac','felix':'849fcd337a75f6230ea6c326cdabd55965de346286e1146a8f74f4c219f5ad17'}
r={'schema_version':1,'result':'ACTUAL_REMOTE_NATIVE_CONTAINERS_ABSENT_NO_OWNED_RUNNING','transport':'ssh-docker-exec-docker_dind-docker','observed_unix':time.time(),'run_id':run,'exact_peers':{},'running_queries':{},'containers_created_started_stopped_or_removed':False,'profile_contents_read_or_modified':False}
deadline=time.monotonic()+60
def query(argv):
 remaining=deadline-time.monotonic();assert remaining>0,'NATIVE_ABSENCE_DEADLINE'
 return subprocess.run(d+argv,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=min(15,remaining))
for role,cid in ids.items():
 c=query(['inspect',cid]);error=c.stderr.decode().strip()
 assert c.returncode==1 and error.lower()=='error: no such object: '+cid,'NATIVE_ID_NOT_PROVEN_ABSENT'
 r['exact_peers'][role]={'historical_container_id':cid,'inspect_exit':c.returncode,'inspect_stderr':error,'actual_absent':True}
queries={'run_label':['--filter','label=im.dinox.interop.run='+run],'any_role_label':['--filter','label=im.dinox.interop.role'],'leon_role_label':['--filter','label=im.dinox.interop.role=leon'],'felix_role_label':['--filter','label=im.dinox.interop.role=felix'],'any_driver_label':['--filter','label=im.dinox.interop.driver'],'run_name':['--filter','name=dinox-interop'],'all_running':[]}
for name,args in queries.items():
 argv=['ps','--no-trunc',*args,'--format','{{json .}}'];c=query(argv);assert c.returncode==0,'NATIVE_RUNNING_QUERY_FAILED'
 rows=[json.loads(line) for line in c.stdout.decode().splitlines()]
 r['running_queries'][name]={'argv':d+argv,'exit':c.returncode,'rows':rows}
 if name!='all_running':assert not rows,'OWNED_NATIVE_OR_COMPILER_RUNNING'
r['running_owned_name_matches']=[v for v in r['running_queries']['all_running']['rows'] if any(x in v['Names'].lower() for x in ('dinox','interop'))]
assert not r['running_owned_name_matches'],'OWNED_NATIVE_NAME_RUNNING'
r['completed_unix']=time.time()
print(json.dumps(r),flush=True)
'''


def probe():
    started = time.time()
    result = subprocess.run(['ssh', '-4', '-p', '2654', '-o', 'BatchMode=yes', '-o',
        'ConnectTimeout=12', HOST, 'python3 -B -'], input=REMOTE_CODE.encode(),
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=85)
    assert result.returncode == 0, 'FIXED_REMOTE_NATIVE_ABSENCE_PROBE_FAILED'
    value = json.loads(result.stdout)
    assert value['result'] == 'ACTUAL_REMOTE_NATIVE_CONTAINERS_ABSENT_NO_OWNED_RUNNING'
    assert set(value['exact_peers']) == set(IDS)
    for role, expected in IDS.items():
        actual = value['exact_peers'][role]
        assert actual['historical_container_id'] == expected
        assert actual['inspect_exit'] == 1 and actual['actual_absent'] is True
        assert actual['inspect_stderr'].lower() == 'error: no such object: ' + expected
    assert started - 5 <= value['observed_unix'] <= value['completed_unix'] <= time.time() + 5
    value.update(probe_source_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                 remote_probe_source_sha256=hashlib.sha256(REMOTE_CODE.encode()).hexdigest(),
                 local_started_unix=started, local_completed_unix=time.time())
    return value


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    value = probe()
    # Fresh receipt only. Do not replace another observation or follow a symlink.
    fd = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'w') as stream:
        json.dump(value, stream, indent=2)
        stream.write('\n')
        stream.flush()
        os.fsync(stream.fileno())
    print(json.dumps({'result': value['result'], 'path': str(args.output),
        'sha256': hashlib.sha256(args.output.read_bytes()).hexdigest()}))


if __name__ == '__main__':
    main()

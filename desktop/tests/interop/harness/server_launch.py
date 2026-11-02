#!/usr/bin/env python3
"""Explicit peer launch after eight real Android tests and root approval."""
import argparse
import json
import pathlib
import subprocess
from local_android_gate import verify_file as verify_local_android_gate

ROOT = pathlib.Path('/home/cpaneladmin/dinox-interop-20261015')
JOB = pathlib.Path('/home/cpaneladmin/dinox-libwebrtc-builder/jobs/monocles-validation-20261015')
DOCKER = ['docker', 'exec', 'docker_dind', 'docker']
RUN = '20261015-71115b'


def read(path):
    return json.loads(path.read_text())


def output(command):
    return json.loads(subprocess.check_output(command, text=True, timeout=60))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('role', choices=('leon', 'felix'))
    parser.add_argument('--print-only', action='store_true')
    args = parser.parse_args()
    assert pathlib.Path(__file__).resolve().parent == ROOT / 'harness', 'Owned server-only launcher'
    receipt = read(ROOT / 'runtime-receipt.json')
    assert receipt['run_id'] == RUN and receipt['state'] == 'prepared'
    assert receipt['all_payload_hashes_checked'] and receipt['dependency_closure_resolved']
    role = args.role
    name = 'dinox-interop-20261015-' + role
    cmd = [*DOCKER, 'create', '--name', name, '--label', 'im.dinox.interop.run=' + RUN,
           '--init', '--network', 'dinox-interop-20261015', '--cpus', '0.5', '--cpu-shares', '128',
           '--memory', '512m', '--memory-swap', '512m', '--pids-limit', '128', '--shm-size', '64m',
           '--ipc', 'private', '--read-only', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges',
           '--user', '1000:1000', '--workdir', '/home/interop', '--env', 'HOME=/home/interop',
           '--tmpfs', '/tmp:rw,nosuid,nodev,size=64m,mode=1777', '--stop-timeout', '20',
           '--log-opt', 'max-size=5m', '--log-opt', 'max-file=2',
           '--mount', 'type=volume,src=' + receipt['payload_volume'] + ',dst=/opt/interop,readonly',
           '--mount', 'type=volume,src=' + receipt['peer_volumes'][role] + ',dst=/interop/monocles-dinox-interop-20261015',
           '--entrypoint', '/bin/sh', receipt['runtime_image'], '/opt/interop/harness/server_entry.sh', role]
    if args.print_only:
        print(json.dumps(cmd))
        return
    assert (ROOT / 'allow-client-launch').read_text().strip() == RUN, 'Explicit root release missing'
    # The earlier server TCG failure remains unchanged as historical evidence.
    # Only the separate, pinned local KVM transcript can release this launcher.
    android_gate = verify_local_android_gate(ROOT / 'local-android-test-gate.json')
    network = output([*DOCKER, 'network', 'inspect', 'dinox-interop-20261015'])[0]
    assert network['Driver'] == 'bridge' and network['Labels'].get('im.dinox.interop.run') == RUN
    subprocess.run(cmd, check=True, timeout=60, capture_output=True)
    info = output([*DOCKER, 'inspect', name])[0]
    c = info['HostConfig']
    assert c['NanoCpus'] == 500000000 and c['Memory'] == c['MemorySwap'] == 512 * 1024**2 and c['PidsLimit'] == 128
    assert c['ReadonlyRootfs'] and not c.get('Devices') and not c.get('PortBindings')
    assert not any(m['Type'] == 'bind' for m in info['Mounts']) and info['Config']['User'] == '1000:1000'
    subprocess.run([*DOCKER, 'start', name], check=True, timeout=60, capture_output=True)
    (ROOT / (role + '-launch.json')).write_text(json.dumps({'container_id': info['Id'], 'run_id': RUN,
         'runtime_image': receipt['runtime_image'], 'limits': {k:c[k] for k in ('NanoCpus','Memory','MemorySwap','PidsLimit')},
         'android_test_gate_passed': True, 'android_test_gate': android_gate}, indent=2) + '\n')
    print(name)


if __name__ == '__main__':
    main()

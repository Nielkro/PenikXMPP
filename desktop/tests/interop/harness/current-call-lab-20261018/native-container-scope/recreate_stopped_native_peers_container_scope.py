#!/usr/bin/env python3
"""Future new CREATED/OFF peers using retained profiles; never rename/remove/start."""
import json
import os
import re
import subprocess
import sys
import time
import runtime_spec as s

os.umask(0o077)


def ensure_test_network():
    name = 'dinox-interop-20261015'
    q = subprocess.run(s.DOCKER + ['network', 'inspect', name], capture_output=True, text=True, timeout=30)
    created = False
    if q.returncode != 0:
        assert q.returncode == 1 and q.stderr.strip() == 'Error response from daemon: network ' + name + ' not found'
        argv = ['network', 'create', '--driver', 'bridge', '--label', 'im.dinox.interop.run=' + s.RUN, name]
        s.save('network-restore-attempt.json', {'observed_unix': time.time(), 'argv': s.DOCKER + argv,
               'only_exact_missing_owned_dind_bridge': True, 'no_host_or_production_network_changes': True})
        made = s.call(argv)
        assert re.fullmatch('[0-9a-f]{64}', made.stdout.strip())
        q = s.call(['network', 'inspect', made.stdout.strip()]); created = True
    network = json.loads(q.stdout)[0]
    assert network['Name'] == name and network['Driver'] == 'bridge' and network['Scope'] == 'local'
    assert network['Labels']['im.dinox.interop.run'] == s.RUN and not network['Internal']
    assert not network['Ingress'] and not network['EnableIPv6'] and not network['Containers']
    assert network['IPAM']['Driver'] == 'default' and network['IPAM']['Config']
    assert re.fullmatch('[0-9a-f]{64}', network['Id'])
    if created: assert network['Id'] == made.stdout.strip()
    s.save('actual-before-first-peer-create-owned-network.json', {'created_only_if_exact_missing': created, 'actual': network})
    return network


def main():
    assert not sys.flags.optimize and sys.argv[1:] == ['--reviewed-create-only']
    assert not (s.HERE / 'create-attempt.json').exists(), 'One create submission per role only'
    receipt = json.loads((s.HERE / 'stage-receipt.json').read_bytes())
    assert receipt['result'] == 'PASS_NEW_RO_OVERLAY_COMPLETE_CLOSURE_HASH_AND_LOADER_ONLY'
    assert receipt['manifest_sha256'] == s.MANIFEST_SHA
    assert not s.call(['ps', '-q', '--filter', 'label=im.dinox.interop.run=' + s.RUN]).stdout.strip()
    # Root authorized the same narrow missing-network restoration within this test job.
    network = ensure_test_network()
    for role, row in s.TEMPLATE.items():
        for target in (row['historical_absent_id'], 'dinox-interop-20261015-' + role):
            q = subprocess.run(s.DOCKER + ['container', 'inspect', target], text=True, capture_output=True, timeout=30)
            assert q.returncode == 1 and json.loads(q.stdout) == [] and q.stderr.strip().casefold() == ('Error response from daemon: No such container: ' + target).casefold()
        volumes = s.require_peer_volumes(role)
        profile = volumes[row['profile_volume']]
        s.save(role + '-before-create-profile-volume-metadata.json', profile)
    s.save('create-attempt.json', {'observed_unix': time.time(), 'manifest_sha256': s.MANIFEST_SHA,
                                 'no_old_id_mutation_or_peer_start': True})
    roles = {}
    for role, expected in s.TEMPLATE.items():
        command = list(s.CREATE)
        assert command[:4] == ['docker', 'exec', 'docker_dind', 'docker'] and command[4] == 'create'
        command[5:5] = ['--pull=never', '--label', 'im.dinox.interop.current=85879bcf-20261018']
        command[command.index('--name') + 1] = 'dinox-interop-20261015-' + role
        command[command.index('--hostname') + 1] = expected['hostname']
        command = [arg.replace('src=dinox-interop-20261015-felix,', 'src=' + expected['profile_volume'] + ',') for arg in command]
        # Only payload, retained role profile and the complete current overlay are needed.
        # Explicitly omit unused historical overlays, never auto-create missing old volumes.
        for index in reversed(range(len(command) - 1)):
            if command[index] == '--mount' and ',dst=/driver-' in command[index + 1]: del command[index:index + 2]
        at = command.index('--entrypoint')
        command[at:at] = ['--mount', 'type=volume,src=' + s.VOLUME + ',dst=' + s.MOUNT + ',readonly']
        command[-3:] = [s.IMAGE, s.MOUNT + '/server_entry_' + role + '.sh', role]
        s.save(role + '-before-create-command.json', {'observed_unix': time.time(), 'argv': command})
        # Immediately before each Docker create, verify every named mount source is genuine.
        s.save(role + '-actual-immediate-before-create-volumes.json', s.require_peer_volumes(role))
        # Unknown submissions are not retried; only genuine Docker stdout provides a new identity.
        q = subprocess.run(command, capture_output=True, text=True, timeout=60)
        s.save(role + '-actual-create-result.json', {'exit': q.returncode, 'stdout': q.stdout, 'stderr': q.stderr})
        assert q.returncode == 0 and re.fullmatch('[0-9a-f]{64}', q.stdout.strip()), 'STOP and inspect; no retry'
        cid = q.stdout.strip()
        row = {'container_id': cid, 'name': 'dinox-interop-20261015-' + role,
               'cmd': [s.MOUNT + '/server_entry_' + role + '.sh', role], 'profile_volume': expected['profile_volume'],
               'created_never_started': True}
        actual = s.inspect(cid); s.save(role + '-actual-created-complete-inspect.json', [actual])
        s.check_container(actual, row, role, False)
        after = json.loads(s.call(['volume', 'inspect', expected['profile_volume']]).stdout)[0]
        before = json.loads((s.HERE / (role + '-before-create-profile-volume-metadata.json')).read_bytes())
        assert after == before
        roles[role] = row
    s.save('owner-native-admission.json', {'scope': 'ACTUAL_CREATED_OFF_CURRENT_IDENTITIES_NOT_A_START_ADMISSION',
           'run_id': s.RUN, 'observed_unix': time.time(), 'roles': roles, 'readonly_overlay': s.VOLUME,
           'existing_test_network_id': network['Id'],
           'overlay_manifest_sha256': s.MANIFEST_SHA, 'artifacts_sha256': s.ARTIFACTS,
           'profiles_copied_reset_or_keys_modified': False, 'peer_started': False})
    print(json.dumps({'result': 'BOTH_NEW_PEERS_CREATED_OFF_NOT_STARTED', 'roles': roles,
                      'admission_sha256': s.digest(s.HERE / 'owner-native-admission.json')}))


if __name__ == '__main__': main()

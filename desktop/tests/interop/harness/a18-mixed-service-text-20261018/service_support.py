"""Selected unchanged service helpers, plus the A18 recorder CLI binding."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import time
import runtime as r

HERE = A_DIR = Path(__file__).resolve().parent
HARNESS = Path('/media/linux/SSD128/xmppwin/local/monocles-dinox-interop-20261015/harness')
ROLES = ('nora', 'leon', 'felix')
FREEZE = r.frozen_files()
RECORDER_SHA = r.read(HERE / 'freeze.json')['files_sha256']['recorder.py']
ROOM_CONTROL_ADMISSION = None
PREFIX = {**dict.fromkeys(('RINGING', 'IN_PROGRESS', 'ESTABLISHING', 'ENDED'), 'DINO_ENTITIES_CALL_STATE_'),
          'ACTIVE': 'DINO_PLUGINS_GOOGLE_WEBRTC_SIGNALING_STATE_', 'CONNECTED': 'DINOX_WEBRTC_PEER_CONNECTION_STATE_',
          'AVAILABLE': 'DINO_PARTICIPANT_INVITE_AVAILABILITY_'}

def enum_is(value, name): return value in (name, PREFIX[name] + name)

def idle(role, state):
    if role == 'nora': return not state['calls'] and not state.get('conference') and not state['busy']
    return (not state.get('call') or enum_is(state['call']['state'], 'ENDED')) and not any(
        enum_is(s.get('wire_state'), 'ACTIVE') for s in state['sessions'])

def wait_for(read, ready, sleep=time.sleep, clock=time.monotonic, seconds=90):
    deadline = clock() + seconds
    while True:
        value = read()
        if ready(value): return value
        assert clock() < deadline, 'Bounded observation incomplete; no mutation retry'
        sleep(1)

def received(state, receiver, text, room):
    if receiver == 'nora':
        return any(m.get('text') == text and m['status'] == 0 and m['encryption'] == 5
                   for c in state['conversations'] if c['jid'] == room for m in c['test_messages'])
    return any(m['body'] == text and m['direction'] == 'received' and m['encryption'] in ('OMEMO', 'DINO_ENTITIES_ENCRYPTION_OMEMO')
               and m['peer'].split('/', 1)[0] == room for m in state['messages'])

def owner_session(root):
    # Independent exact owner binding; never call a forbidden frozen caller guard.
    cfg = r.role_config('nora'); session = r.read(cfg['state']/'live-session.json')
    assert session['schema_version']==2 and session['state']=='running' and session['ready'] is True
    assert session['run_id']==r.RUN and session['role']=='nora' and session['batch_id']==root['batch_id']
    assert session['freeze_sha256']==root['runtime_freeze_sha256']==FREEZE
    assert session['apk_sha256']==r.APKS and session['guest_memory_mib']==2048
    assert session['inputs_sha256']==root['runtime_inputs_sha256']==r.sha(r.ROOT/'runtime-inputs.json')
    assert time.time()<session['batch_deadline_unix']
    keys={'controller_pid','controller_start_ticks','adb_pid','adb_start_ticks',
          'emulator_pid','emulator_start_ticks','adb_cgroup','approval_sha256'}
    assert set(root['session_binding'])==keys
    assert {key:session[key] for key in keys}==root['session_binding']
    assert set(root['process_cgroups'])=={'controller','adb','emulator'}
    for name in ('controller','adb','emulator'):
        assert r.v1.start_ticks(session[name+'_pid'])==session[name+'_start_ticks']
        group=r.v1.process_cgroup(session[name+'_pid'])
        assert group==root['process_cgroups'][name] and r.v1.SLICE in Path(group).parts
    assert session['adb_cgroup']==root['process_cgroups']['adb']
    assert session['adb_sha256']==r.sha(r.ROOT/'sdk/platform-tools/adb')
    assert session['native_readonly_bindings']==root['native_bindings']
    return cfg,session

def android_record(value):
    # The CLI itself creates/records a command UUID once. No forged caller or direct recorder import.
    assert r.sha(A_DIR/'recorder.py')==RECORDER_SHA
    action=value['action'];argv=[sys.executable,'-B',str(A_DIR/'recorder.py'),action]
    if action=='begin':argv.append(value['label'])
    else:
        assert action in ('state','command','result') and value['role']=='nora' and value['transport']=='local-android'
        assert 0<=value['wait']<=30
        argv += [value['recording'],value['tag'],'nora','--transport','local-android','--wait',str(value['wait'])]
        assert ROOM_CONTROL_ADMISSION is not None, 'Scenario needs exact fresh room-control admission'
        argv += ['--room-admission', ROOM_CONTROL_ADMISSION['path'], '--room-admission-sha256', ROOM_CONTROL_ADMISSION['sha256']]
        if action=='command':
            assert value['payload'].get('op')!='stop', 'Scenario does not stop a runtime'
            argv.append(json.dumps(value['payload']))
        if action=='result':argv.append(value['id'])
    result=subprocess.run(argv,stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=value.get('wait',0)+45)
    assert result.returncode==0, 'Frozen Nora recorder failed; inspect recorded actual UUID, never resend'
    assert len(result.stdout)<=12*1024**2
    return json.loads(result.stdout)

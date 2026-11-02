#!/usr/bin/env python3
"""One separately frozen mixed-video case; all runtime starts belong to the owner."""
import argparse,datetime,hashlib,importlib.util,json,os,resource,re,shlex,signal,stat,subprocess,sys,time,uuid
from pathlib import Path
sys.dont_write_bytecode=True
HERE=A_DIR=Path(__file__).resolve().parent
HARNESS=Path('/media/linux/SSD128/xmppwin/local/monocles-dinox-interop-20261015/harness')
import runtime as r
import importlib.util as _ci
native_rec=server_control=None
ROLES=('nora','leon','felix')
PAIRS=(('nora','leon'),('nora','felix'),('leon','felix'))
MAIN='f2e19dbf604e7bfd838f9f269631bbcc56dcf294dad040c3cbf1200bdf36d568'
FREEZE=r.frozen_files()
RECORDER_SHA=r.read(HERE/'freeze.json')['files_sha256']['recorder.py']
CASE=HERE.parent/'mixed-three-video/media_case.py'
CASE_SHA='4ba30539fb8259fd717d83f3f9a619a8fe167bde884d520760993c9eb8434a54'
NATIVE_SOURCE=HERE.parent/'native-current-driver/runtime-source'
PREFIX={**dict.fromkeys(('RINGING','IN_PROGRESS','ESTABLISHING','ENDED'),'DINO_ENTITIES_CALL_STATE_'),
 'ACTIVE':'DINO_PLUGINS_GOOGLE_WEBRTC_SIGNALING_STATE_','CONNECTED':'DINOX_WEBRTC_PEER_CONNECTION_STATE_',
 'AVAILABLE':'DINO_PARTICIPANT_INVITE_AVAILABILITY_'}
assert r.sha(CASE)==CASE_SHA
case_spec=_ci.spec_from_file_location('current_pure_mixed_video_case',CASE)
case=_ci.module_from_spec(case_spec);case_spec.loader.exec_module(case)

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

def public_identity(state, role):
    device = state['own_omemo_device_id']; fingerprint = state['own_public_identity_hex']
    assert type(device) is int and device > 0 and re.fullmatch('05[0-9a-f]{64}', fingerprint)
    contacts = []
    for contact in state['contacts']:
        assert contact['jid'] in {r.OWN[x] for x in ROLES if x != role}
        contacts.append({k: contact[k] for k in ('jid', 'resources', 'devices')})
    return {'account': state['account'], 'full_jid': state['full_jid'], 'own_device_id': device,
            'own_public_identity_hex': fingerprint, 'contacts': contacts,
            'call_auth_proven_by_this_observation': False}

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
        if action=='command':
            assert value['payload'].get('op')!='stop', 'Scenario does not stop a runtime'
            argv.append(json.dumps(value['payload']))
        if action=='result':argv.append(value['id'])
    result=subprocess.run(argv,stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=value.get('wait',0)+45)
    assert result.returncode==0, 'Frozen Nora recorder failed; inspect recorded actual UUID, never resend'
    assert len(result.stdout)<=12*1024**2
    return json.loads(result.stdout)

def root_admission(path):
    path=Path(path);assert path.is_file() and not path.is_symlink() and path.stat().st_mode&0o077==0
    root=r.read(path)
    assert root['operation']=='owner-current-mixed-three-video' and root['runtime_profile']=='A18V'
    assert root['scenario_sha256']==r.sha(Path(__file__)) and root['run_id']==r.RUN
    assert root['accounts']==r.OWN and root['role']=='nora'
    assert 0<=time.time()-root['created_unix']<=120 and time.time()<root['expires_unix']<=root['created_unix']+900
    assert r.sha(A_DIR/'recorder.py')==RECORDER_SHA
    assert FREEZE==r.frozen_files()==root['runtime_freeze_sha256']
    assert r.APKS=={'main.apk':MAIN,'android-test.apk':'486b06a8f472fc68d89f9ced35b1befbc67805f22aa0d3dbf1c162cf3aab6e65'}
    assert set(root['identities'])==set(ROLES)
    for role in ROLES:
        public=root['identities'][role]
        assert public['account']==r.OWN[role] and type(public['device_id']) is int
        assert re.fullmatch('05[0-9a-f]{64}',public['legacy_fingerprint'])
    assert root['identities']['leon']['device_id']==172062497
    assert root['identities']['felix']['device_id']==1228426141
    assert root['case_source_sha256']==CASE_SHA and r.sha(CASE)==CASE_SHA
    assert root['native_runtime_source_manifest_sha256']=='3f9f8fc46e95cd20864e417560366a182e4f94f92e734189b9ad4ae7824584d4'
    assert Path(root['native_bindings']['directory']).resolve()==HARNESS/'native_current_20261018'
    owner_session(root)
    return root

def claim_once(root, admission_path):
    """A18's durable O_EXCL/fsync rule, scoped only to this one video case."""
    assert re.fullmatch('[0-9a-f]{32}',root['batch_id'])
    folder=r.STATE/'operation-claims';folder.mkdir(mode=0o700,parents=True,exist_ok=True)
    info=folder.lstat();assert stat.S_ISDIR(info.st_mode) and info.st_uid==os.getuid() and info.st_mode&0o077==0
    target=folder/('current-mixed-three-video-'+root['batch_id']+'.json')
    value={'scope':'ONE_CURRENT_MIXED_THREE_VIDEO_CASE_PER_BATCH_NO_RETRY','run_id':r.RUN,
           'batch_id':root['batch_id'],'runtime_freeze_sha256':root['runtime_freeze_sha256'],
           'session_binding':root['session_binding'],'root_admission_sha256':r.sha(admission_path),
           'case_source_sha256':CASE_SHA,'product_mutation_may_follow':True,'automatic_retry':False}
    fd=os.open(target,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    try:
        with os.fdopen(fd,'w',closefd=False) as stream:
            json.dump(value,stream,sort_keys=True);stream.write('\n');stream.flush();os.fsync(fd)
    finally:os.close(fd)
    directory_fd=os.open(folder,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
    try:os.fsync(directory_fd)
    finally:os.close(directory_fd)
    return str(target)


def collect_native_maps(root,write,case_deadline):
    """Existing reviewed read-only map observer inside exact active native peers."""
    source=NATIVE_SOURCE/'inner_maps.py'
    assert r.sha(source)=='2c7f37aea4f86a14b8bfe2f2d7973259f6b0bba5047220c0418f4bc2fc422dad'
    s=server_control.s
    wrapper=s.MOUNT+'/qualified-runtime/lib/libdinox-google-webrtc.so'
    config={'binary':s.BINARY,'artifacts':s.ARTIFACTS,'profile':s.PROFILE,'library_path':s.LIBRARY_PATH,
            'worker':s.WORKER,'runtime_lib':s.MOUNT+'/qualified-runtime/lib','wrapper':wrapper,
            'required_driver_maps':[s.BINARY,s.MOUNT+'/lib/libdino.so.0',s.MOUNT+'/lib/libxmpp-vala.so.0',s.MOUNT+'/lib/omemo.so',wrapper,s.SESSION_PATH],
            'optional_codec_maps':[s.MOUNT+'/qualified-runtime/lib/'+p for p in ('libavcodec-dinox-hw.so.62','libavutil-dinox-hw.so.60')]}
    for role in ('leon','felix'):
        r.v1.resources();owner_session(root);assert time.time()<case_deadline
        binding=root['native_bindings'];ref=binding['inspects'][role]
        assert r.sha(Path(ref['path']))==ref['sha256'];info=r.read(ref['path'])
        if isinstance(info,list):assert len(info)==1;info=info[0]
        row=binding['owner_admission']['roles'][role];server_control.check_container(info,row,role)
        started=datetime.datetime.fromisoformat(info['State']['StartedAt'].replace('Z','+00:00')).timestamp()
        argv=[*s.DOCKER,'exec','-i','--user','1000:1000',row['container_id'],'python3','-',role,str(started),json.dumps(config)]
        q=subprocess.run(['ssh','-4','-p','2654','-o','BatchMode=yes','-o','ConnectTimeout=12',server_control.HOST,shlex.join(argv)],
                         input=source.read_bytes(),capture_output=True,timeout=65)
        assert q.returncode==0 and len(q.stdout)<=4*1024**2,'Actual active native maps proof failed; no retry'
        result=json.loads(q.stdout);workers=[w for w in result['actual_workers_if_started'] if w['exe']==s.WORKER]
        assert len(workers)==1,'Actual current media worker must be running during successful video'
        write(role+'-actual-active-current-native-maps.json',result)




def case_budget_deadline(root,session):
    """Fresh case budget, bounded by both already-running native lifetimes."""
    deadlines=[root['expires_unix'],root['created_unix']+900,session['batch_deadline_unix']-120]
    binding=root['native_bindings']
    assert set(binding['inspects'])=={'leon','felix'}
    for role,ref in binding['inspects'].items():
        path=Path(ref['path']);assert r.sha(path)==ref['sha256']
        rows=r.read(path);assert isinstance(rows,list) and len(rows)==1
        info=rows[0]
        assert info['Id']==binding['owner_admission']['roles'][role]['container_id']
        assert info['State']['Running'] is True and info['State']['Status']=='running'
        started=datetime.datetime.fromisoformat(info['State']['StartedAt'].replace('Z','+00:00')).timestamp()
        # Reviewed server_entry_{role}.sh starts its fixed 5400s timer after container start.
        deadlines.append(started+5400-120)
    return min(deadlines)
def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--owner-admitted-existing-session', action='store_true', required=True)
    parser.add_argument('--root-admission',type=Path,required=True)
    args = parser.parse_args()
    global native_rec,server_control
    root = root_admission(args.root_admission)
    initial,session = owner_session(root)
    case_deadline=case_budget_deadline(root,session)
    assert case_deadline-time.time()>=90, 'Keep case and cleanup reserves'
    claim_once(root,args.root_admission)
    binding=session['native_readonly_bindings'];directory=Path(binding['directory'])
    assert r.sha(directory/'native_control.py')==binding['control_sha256']
    assert r.sha(directory/'native_recorder.py')==binding['recorder_sha256']
    spec=_ci.spec_from_file_location('native_control',directory/'native_control.py')
    server_control=_ci.module_from_spec(spec);sys.modules['native_control']=server_control;spec.loader.exec_module(server_control)
    spec=_ci.spec_from_file_location('actual_native_recorder',directory/'native_recorder.py')
    native_rec=_ci.module_from_spec(spec);spec.loader.exec_module(native_rec)
    native_rec.ADMISSION_SHA = binding['admission_sha256']
    admission = server_control.admission(native_rec.ADMISSION_SHA)
    assert admission==binding['owner_admission']
    assert not sys.flags.optimize and os.getpriority(os.PRIO_PROCESS, 0) == 19
    assert r.frozen_files() == FREEZE and r.APKS['main.apk'] == MAIN
    join = r.verify_join_product(); assert join['actual_jvm_tests'] == r.PRODUCT['actual_jvm_tests']
    settings,nora_session = owner_session(root); assert settings['adb_port'] == 5038 and settings['emulator_port'] == 5580
    assert nora_session['guest_memory_mib'] == 2048 and nora_session['lowram_emulation_variant'] is True
    leon_session = r.read(r._historical.role_config('leon')['state'] / 'live-session.json')
    assert leon_session['state'] == 'stopped' and leon_session['all_owned_processes_stopped']
    for name in ('controller', 'adb', 'emulator'):
        try: assert r.v1.start_ticks(leon_session[name + '_pid']) != leon_session[name + '_start_ticks'], 'Android Leon still alive'
        except (FileNotFoundError, ProcessLookupError): pass
    # Owner independently proves fresh Android-Leon cleanup/native startup/profile retention
    # and captures continuous Nora logs; roles/chat mode never prove native Legacy device binding.
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ-') + uuid.uuid4().hex
    out = r.ROOT / ('current-mixed-three-video-' + stamp); out.mkdir(mode=0o700)
    recordings = {'nora': android_record({'action': 'begin', 'label': 'Current-mixed-three-video-adopted-session'}),
                  'native': native_rec.server({'action': 'begin', 'label': 'Current-mixed-three-video-native-peers', 'local_recording': True})}
    def write(name,value):
        if name.endswith('-media.json'):
            context['trace_sids'].update(e['sid'] for e in value['edges'] if 'felix' in (e['sender'],e['receiver']))
        if name=='scenario-result.json': context['case_pair_sids']=value['pair_sids']
        r.v1.write(out/name,value)
    context = {'accounts':r.OWN,'room': None, 'direct_sid': None, 'native': {'leon': set(), 'felix': set()}, 'trace_sids': set(),'evidence_directory':out,'root_admission':root,'native_recording':recordings['native']['recording']}
    full_jids, trace, cleanup_mode = {}, None, False
    public_observations = {}
    def op(role, tag, payload=None):
        assert role in ROLES; r.v1.resources();owner_session(root)
        assert not payload or payload.get('op')!='stop', 'Runtime/native stop forbidden in this scenario'
        if not cleanup_mode: assert time.time()<case_deadline, 'Case expired; no operation retry'
        if trace is not None and not cleanup_mode: assert trace.poll() is None, 'Felix trace collector ended'
        q = {'action': 'command' if payload else 'state', 'role': role, 'wait': 30 if payload else 0, 'tag': tag,
             'transport': 'local-android' if role == 'nora' else 'server'}
        if payload:
            q['payload']=payload
            if role!='nora':q['id']=uuid.uuid4().hex
        q['recording'] = recordings['nora' if role == 'nora' else 'native']['recording']
        if role == 'nora': result = android_record(q)
        else: q['local_recording'] = True; result = native_rec.server(q); assert result['controller_exit'] == 0
        z = result['observation']; assert z.get('completed'), 'Uncertain operation: inspect same UUID result, never resend'
        z = z['response']; assert z['run_id'] == r.RUN and z['account'] == r.OWN[role] and (not payload or z['ok'])
        s = z['result'] if role == 'nora' and payload else z
        if role != 'nora':
            assert s['online'] and s['profile_lock_held'] and s['full_jid'].startswith(r.OWN[role] + '/')
            assert full_jids.setdefault(role, s['full_jid']) == s['full_jid']
            assert s['own_omemo_device_id']==root['identities'][role]['device_id']
            assert s['own_public_identity_hex']==root['identities'][role]['legacy_fingerprint']
        elif 'own_device_id' in s:
            assert s['own_device_id']==root['identities']['nora']['device_id']
            assert s['own_legacy_fingerprint']==root['identities']['nora']['legacy_fingerprint']
        if role=='leon' and payload and payload['op']=='add_participant' and s.get('call'):
            context['native']['leon'].add(s['call']['id'])  # Actual promoted call belongs to our one submitted conversion.
        return s
    trace_file = (out / 'felix-native-debug.log').open('xb'); Path(trace_file.name).chmod(0o600)
    try:
        for role in ROLES:
            s = op(role, 'admission-online-idle')
            assert s['online'] and idle(role, s)
            assert role != 'nora' or not s['calls'] and not s.get('conference') and not s['pending_invites']
            assert role == 'nora' or s['physical_capture_suppressed'] and s['source'] == 'production-core-omemo-xmpp-libwebrtc'
        for role in ('leon', 'felix'):
            public_observations[role] = public_identity(op(role, 'before-call-public-identities'), role)
        write('before-call-native-public-identities.json', public_observations)
        def limit_trace(): resource.setrlimit(resource.RLIMIT_FSIZE, (8 * 1024**2, 8 * 1024**2))
        since = datetime.datetime.now(datetime.timezone.utc).isoformat()
        remote = 'docker exec docker_dind docker logs --timestamps --follow --since ' + since + ' ' + admission['roles']['felix']['container_id']
        trace = subprocess.Popen(['ssh', '-p', '2654', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=12', server_control.HOST, remote],
            stdin=subprocess.DEVNULL, stdout=trace_file, stderr=subprocess.STDOUT, start_new_session=True, preexec_fn=limit_trace)
        write('admission-and-trace.json', {'freeze_sha256': FREEZE, 'join': join, 'native_full_jids': full_jids,
            'trace_started_unix': time.time(), 'before_first_call': True, 'owner_admission_required': True,
            'native_admission_sha256': native_rec.ADMISSION_SHA, 'native_admission': admission})
        case.scenario(op, write, context)
        collect_native_maps(root,write,case_deadline)
        write('auth-required-scope.json',{'requested_encryption':'legacy-OMEMO1','DinoX_PQ_enabled':False,
            'native_call_ids':{role:sorted(ids) for role,ids in context['native'].items()},
            'direct_sid':context['direct_sid'],'room':context['room'],'current_public_identities':root['identities'],
            'pair_sids':context['case_pair_sids'],
            'media_proves_auth':False,'auth':'PENDING_EXACT_SID_DEVICE_FINGERPRINT_AUDIT_MULTI_NODE_AV_UNPROVEN'})
    except BaseException as error:
        write('failure.json', {'type': type(error).__name__, 'detail': str(error), 'no_automatic_retry': True}); raise
    finally:
        cleanup_mode = True
        failures = []
        for role in ROLES:
            try:
                s = op(role, 'cleanup-observe-current-owner')
                if role == 'nora':
                    if s.get('conference') and s['conference']['room'] == context['room']:
                        op(role, 'cleanup-end-current-conference-once', {'op': 'hangup', 'call_id': s['conference']['call_id']})
                    elif any(c['session_id'] == context['direct_sid'] for c in s['calls']):
                        op(role, 'cleanup-end-original-direct-once', {'op': 'hangup', 'session_id': context['direct_sid']})
                elif s.get('call') and s['call']['id'] in context['native'][role] and any(enum_is(s['call']['state'], x) for x in ('IN_PROGRESS', 'RINGING', 'ESTABLISHING')):
                    op(role, 'cleanup-end-observed-native-once', {'op': 'hangup', 'call_id': s['call']['id']})
                wait_for(lambda role=role: op(role, 'cleanup-observe-idle'), lambda state: idle(role, state), seconds=20)
            except BaseException as error: failures.append({'role': role, 'type': type(error).__name__, 'detail': str(error)})
        if trace is not None: r.v1.stop_owned(trace)
        trace_file.close()
        text = Path(trace_file.name).read_text(errors='replace')
        write('cleanup-and-trace.json', {'result': 'CURRENT_MIXED_VIDEO_CLEANUP_PASS_AUTH_PENDING' if not failures else 'PARTIAL',
            'all_three_idle_proven': not failures, 'cleanup_errors': failures, 'trace_sha256': r.sha(Path(trace_file.name)),
            'required_felix_sids': sorted(context['trace_sids']),
            'all_required_sids_in_trace': bool(context['trace_sids']) and all(sid in text for sid in context['trace_sids']),
            'native_pair_auth': 'NOT_PROVEN', 'runtime_or_peers_stopped_by_this_scenario': False})
        print('CURRENT_MIXED_VIDEO_EVIDENCE', out, flush=True)
        assert not failures, 'Own-call cleanup incomplete; owner must inspect'

if __name__ == '__main__':
    if sys.flags.optimize: raise RuntimeError('Required assertions must stay enabled')
    def terminate(signum, frame):
        signal.signal(signal.SIGTERM, signal.SIG_IGN); signal.signal(signal.SIGINT, signal.SIG_IGN)
        raise SystemExit('Owned scenario interrupted; end observed calls in finally')
    signal.signal(signal.SIGTERM, terminate); signal.signal(signal.SIGINT, terminate)
    main()

#!/usr/bin/env python3
"""Derive small A18V sources without importing any operational runtime."""
import ast
import difflib
import hashlib
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
A18 = HERE.parent
HARNESS = Path('/media/linux/SSD128/xmppwin/local/monocles-dinox-interop-20261015/harness')
A = HARNESS / 'devicefix_nora_runtime'
AUTH = HARNESS / 'resume-completion-plan-20261016T190157Z/ui-owner-resume/auth-media-only/auth_media.py'
CASE = A18 / 'mixed-three-video/media_case.py'
NATIVE = A18 / 'native-current-driver/runtime-source'
LIFECYCLE = A18 / 'capture-shell-v2/runtime_consent/process_lifecycle.py'
PINS = {
    A18 / 'mixed-video-owner-source/source-manifest.json': 'e3431bddb31aa783ffa608018d228126000e82087df29fccce57bed453431c74',
    A18 / 'mixed-video-owner-source/freeze.json': '07d2662015e858872ea02476f739aea08811797d0c56dbccc8ac84e9fa2c29e9',
    A18 / 'runtime.py': 'a4f1b23d9a1b6759543cea757ec15551f4697caed834cb5b19f48f1bef81cf5f',
    A18 / 'freeze.json': '73c64b7aba80ff49c83e3425cb20b37fcc33d562aa96b7751e4973ea4ff91c04',
    A18 / 'monitor.py': 'f66b72dd17b59862d3649f932d12dbf1d6e670c6f7ba0d8df556fb7e858b06f9',
    A / 'control.py': '96b54078b0b958d23b8f13f7546877ac0ee5f2c47c92ce368aacd2efe86b7617',
    A / 'recorder.py': '416a89203a246dd481f8a79fd08dd930f6ed988d8eccceb5a12ed31bbdfb16b5',
    AUTH: 'f3b319d70d77c9a67c8be6693fa574f433237bd09c42f0c77c234237368360a3',
    CASE: '4ba30539fb8259fd717d83f3f9a619a8fe167bde884d520760993c9eb8434a54',
    CASE.with_name('source-manifest.json'): '6fcc7e333ede7ed0eca700b1a8af345a44fa580e0c5bb3eb93e60e4ae489dab9',
    NATIVE / 'source-manifest.json': '3f9f8fc46e95cd20864e417560366a182e4f94f92e734189b9ad4ae7824584d4',
    NATIVE / 'inner_maps.py': '2c7f37aea4f86a14b8bfe2f2d7973259f6b0bba5047220c0418f4bc2fc422dad',
    LIFECYCLE: 'cbccb23b594d64471ce2851dd9105c99a874bd3bc061e7631e2fd4dd9a46fff9',
}


def sha(path): return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def function(text, name, last=False):
    nodes = [n for n in ast.parse(text).body if isinstance(n, ast.FunctionDef) and n.name == name]
    node = nodes[-1] if last else nodes[0]
    return '\n'.join(text.splitlines()[node.lineno - 1:node.end_lineno]) + '\n\n'


def replace_function(text, name, new, last=False):
    old = function(text, name, last).rstrip()
    assert text.count(old) == 1
    return text.replace(old, new.rstrip(), 1)


def main():
    HERE.mkdir(mode=0o700, parents=True, exist_ok=True)
    for path, expected in PINS.items(): assert sha(path) == expected, str(path)
    source = (A18 / 'runtime.py').read_text()
    for name in ('room_control_context', 'validate_control_config'):
        source = replace_function(source, name, '')
    frozen = function(source, 'frozen_files')
    frozen = frozen.replace("'Nora-only-persistent-room-service-20261018'", "'Nora-only-current-mixed-three-video-20261018'")
    frozen = frozen.replace("'service_support.py', 'room_scope.py', ", '')
    frozen = frozen.replace("'monitor.py')", "'monitor.py', 'process_lifecycle.py')")
    frozen = frozen.replace("    _current_product()\n", "    assert sha(HERE.parent/'freeze.json')=='73c64b7aba80ff49c83e3425cb20b37fcc33d562aa96b7751e4973ea4ff91c04'\n    parent=read(HERE.parent/'freeze.json')\n    for name,digest in parent['files_sha256'].items(): assert sha(HERE.parent/name)==digest\n    for path,digest in value['external_source_sha256'].items(): assert sha(Path(path))==digest\n    _current_product()\n")
    expected_external={str(p):PINS[p] for p in (CASE,CASE.with_name('source-manifest.json'),NATIVE/'source-manifest.json',NATIVE/'inner_maps.py')}
    frozen = frozen.replace("    for path,digest in value['external_source_sha256'].items():", "    assert value['parent_A18_freeze_sha256']=='73c64b7aba80ff49c83e3425cb20b37fcc33d562aa96b7751e4973ea4ff91c04'\n    assert value['external_source_sha256']=="+repr(expected_external)+"\n    for path,digest in value['external_source_sha256'].items():")
    source = replace_function(source, 'frozen_files', frozen)
    # The only changed process gate: invoke the checked pure lifecycle scanner directly.
    old_scan='inventory.require_no_guests(inventory.guest_processes(inventory.load_baseline()))'
    assert source.count(old_scan)==1
    source=source.replace(old_scan,'inventory.require_no_guests(sdk_guest_inventory(inventory))')
    scanner='''def sdk_guest_inventory(inventory):
    path=HERE/'process_lifecycle.py'
    assert sha(path)=='cbccb23b594d64471ce2851dd9105c99a874bd3bc061e7631e2fd4dd9a46fff9'
    spec=_iu.spec_from_file_location('A18V_checked_process_lifecycle',path)
    lifecycle=_iu.module_from_spec(spec);spec.loader.exec_module(lifecycle)
    def report(value,kind):
        value.update(observed_unix=time.time(),context='A18V-exact-SDK-prestart-'+kind,controller_pid=os.getpid())
        v1.write(STATE/(kind+'-SDK-process-'+uuid.uuid4().hex+'.json'),value)
    return lifecycle.scan(inventory.load_baseline(),inventory,
        reject=lambda value:report(value,'rejected'),observe=lambda value:report(value,'terminal'))


'''
    source=source.replace('def gate(role,memory_mib=2048,lowram=True,android_tests_before_bridge=False):',scanner+'def gate(role,memory_mib=2048,lowram=True,android_tests_before_bridge=False):')
    source = source.replace('A18 requires Python without optimization', 'A18V requires Python without optimization')
    source = source.replace("CLIENT_VARIANT = 'device-dialects-landscape-616-Nora-only-2048-lowram'", "CLIENT_VARIANT = 'device-dialects-landscape-616-Nora-only-2048-lowram-current-mixed-video'")
    (HERE / 'runtime.py').write_text(source)
    (HERE / 'process_lifecycle.py').write_bytes(LIFECYCLE.read_bytes())
    control = (A / 'control.py').read_text()
    begin, end = control.index('OPS = '), control.index('\n\n\ndef validate')
    control = control[:begin] + "OPS = {'status', 'stats', 'stop', 'prepare_crypto', 'start_call', 'hangup'}" + control[end:]
    extra = '''        op = payload['op']
        if op in ('status','stats','stop'): assert set(payload)=={'op'}
        elif op=='prepare_crypto':
            assert set(payload)=={'op','peer','encryption'} and payload['encryption']=='legacy'
            assert payload['peer'] in ('leon',runtime.OWN['leon'])
        elif op=='start_call':
            assert set(payload)=={'op','peer','video'} and payload['video'] is True
            assert payload['peer'] in ('leon',runtime.OWN['leon'])
        elif op=='hangup':
            assert set(payload) in ({'op','session_id'},{'op','call_id'})
            identifier=payload.get('session_id',payload.get('call_id'))
            assert isinstance(identifier,(str,int)) and not isinstance(identifier,bool)
            assert 0<len(str(identifier))<=128 and not any(c.isspace() for c in str(identifier))
'''
    assert control.count('        reject_private(payload)') == 1
    control = control.replace('        reject_private(payload)', '        reject_private(payload)\n' + extra.rstrip())
    (HERE / 'control.py').write_text(control)
    (HERE / 'recorder.py').write_bytes((A / 'recorder.py').read_bytes())
    monitor = (A18 / 'monitor.py').read_text().replace('A18 retained Nora12210 current616: missing persistent mixed service text only; no audio/UI/PQ repeats', 'A18V one current mixed three-party VIDEO case; no text/audio/UI/PQ repeats')
    (HERE / 'monitor.py').write_text(monitor)
    auth = AUTH.read_text()
    header = '''#!/usr/bin/env python3
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
MAIN='0a8ce212645b5a4876ee7f88122e5065d8f34a4f2a5c212ac91eec4402d0bebe'
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

'''
    selected = ''.join(function(auth, n) for n in ('enum_is','idle','wait_for','public_identity','owner_session','android_record'))
    admission = function(auth, 'root_admission')
    assert admission.count("root['created_unix']+240")==1
    admission = admission.replace("root['created_unix']+240","root['created_unix']+900")
    admission = admission.replace("'owner-auth-media-only-sibling'", "'owner-current-mixed-three-video'").replace("root['runtime_profile']=='A'", "root['runtime_profile']=='A18V'")
    admission = admission.replace("r.sha(A_DIR/'scenario.py')==BASE_SCENARIO_SHA and ", '')
    admission = admission.replace("FREEZE==r.frozen_files()=='131aa89a08adf3075e7ddcbc62af03b4ac14a682e3df4547099cd6bd6ef7b294'", "FREEZE==r.frozen_files()==root['runtime_freeze_sha256']")
    admission = admission.replace('    owner_session(root)', "    assert root['case_source_sha256']==CASE_SHA and r.sha(CASE)==CASE_SHA\n    assert root['native_runtime_source_manifest_sha256']=='3f9f8fc46e95cd20864e417560366a182e4f94f92e734189b9ad4ae7824584d4'\n    assert Path(root['native_bindings']['directory']).resolve()==HARNESS/'native_current_20261018'\n    owner_session(root)")
    main_source = function(auth, 'main')
    main_source = main_source.replace('    initial,session = owner_session(root)', "    initial,session = owner_session(root)\n    case_deadline=case_budget_deadline(root,session)\n    assert case_deadline-time.time()>=90, 'Keep case and cleanup reserves'\n    claim_once(root,args.root_admission)")
    main_source = main_source.replace("'auth-media-only-'", "'current-mixed-three-video-'")
    main_source = main_source.replace("Auth-media-only", "Current-mixed-three-video")
    main_source = main_source.replace("    write = lambda name, value: r.v1.write(out / name, value)", "    def write(name,value):\n        if name.endswith('-media.json'):\n            context['trace_sids'].update(e['sid'] for e in value['edges'] if 'felix' in (e['sender'],e['receiver']))\n        r.v1.write(out/name,value)")
    main_source = main_source.replace("        r.v1.write(out/name,value)", "        if name=='scenario-result.json': context['case_pair_sids']=value['pair_sids']\n        r.v1.write(out/name,value)")
    main_source = main_source.replace("context = {'room': None", "context = {'accounts':r.OWN,'room': None")
    main_source = main_source.replace("        if trace is not None and not cleanup_mode:", "        if not cleanup_mode: assert time.time()<case_deadline, 'Case expired; no operation retry'\n        if trace is not None and not cleanup_mode:")
    main_source = main_source.replace("        return s\n", "        if role=='leon' and payload and payload['op']=='add_participant' and s.get('call'):\n            context['native']['leon'].add(s['call']['id'])  # Actual promoted call belongs to our one submitted conversion.\n        return s\n")
    main_source = main_source.replace("        scenario(op, write, context)", "        case.scenario(op, write, context)\n        collect_native_maps(root,write,case_deadline)\n        write('auth-required-scope.json',{'requested_encryption':'legacy-OMEMO1','DinoX_PQ_enabled':False,\n            'native_call_ids':{role:sorted(ids) for role,ids in context['native'].items()},\n            'direct_sid':context['direct_sid'],'room':context['room'],'current_public_identities':root['identities'],\n            'pair_sids':context['case_pair_sids'],\n            'media_proves_auth':False,'auth':'PENDING_EXACT_SID_DEVICE_FINGERPRINT_AUDIT_MULTI_NODE_AV_UNPROVEN'})")
    main_source = main_source.replace("'AUTH_MEDIA_ONLY_CLEANUP_PASS_AUTH_PENDING'", "'CURRENT_MIXED_VIDEO_CLEANUP_PASS_AUTH_PENDING'").replace("AUTH_MEDIA_ONLY_EVIDENCE", "CURRENT_MIXED_VIDEO_EVIDENCE")
    ending = auth[auth.index("if __name__ == '__main__':"):]
    helpers = (HERE / 'owner_helpers.source').read_text()
    (HERE / 'scenario.py').write_text(header + selected + admission + helpers + main_source + ending)
    names = ('runtime.py','control.py','recorder.py','scenario.py','monitor.py','process_lifecycle.py')
    parent = json.loads((A18 / 'freeze.json').read_bytes())
    freeze = {'schema_version':1,'mode':'Nora-only-current-mixed-three-video-20261018','roles':['nora'],
              'parent_A_freeze_sha256':parent['parent_A_freeze_sha256'],'parent_A18_freeze_sha256':PINS[A18/'freeze.json'],
              'product':parent['product'],'apk_sha256':parent['apk_sha256'],
              'files_sha256':{name:sha(HERE/name) for name in names},
              'external_source_sha256':{str(p):PINS[p] for p in (CASE,CASE.with_name('source-manifest.json'),NATIVE/'source-manifest.json',NATIVE/'inner_maps.py')},
              'root_start_authorized':False,'marker_created':False,'runtime_started':False}
    (HERE / 'freeze.json').write_text(json.dumps(freeze,indent=2)+'\n')
    diff=[]
    for old,new in [(A18/'runtime.py','runtime.py'),(A/'control.py','control.py'),(AUTH,'scenario.py'),(A18/'monitor.py','monitor.py')]:
        diff.extend(difflib.unified_diff(old.read_text().splitlines(keepends=True),(HERE/new).read_text().splitlines(keepends=True),fromfile=str(old),tofile=str(HERE/new)))
    (HERE/'derivation.diff').write_text(''.join(diff))
    for name in names: ast.parse((HERE/name).read_text())
    print(json.dumps({'result':'SOURCES_DERIVED_ONLY_NO_RUNTIME_IMPORT','operational_files':len(names),'operational_bytes':sum((HERE/n).stat().st_size for n in names),'freeze_sha256':sha(HERE/'freeze.json')}))


if __name__ == '__main__': main()

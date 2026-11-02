#!/usr/bin/env python3
"""AST + extracted-method checks only; never import a runtime or start a process."""
import ast
import copy
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import tempfile
from types import SimpleNamespace

HERE = Path(__file__).resolve().parent
HARNESS = Path('/media/linux/SSD128/xmppwin/local/monocles-dinox-interop-20261015/harness')
AUTH = HARNESS / 'resume-completion-plan-20261016T190157Z/ui-owner-resume/auth-media-only/auth_media.py'
OWN = {'nora':'nora.schneider.interop.de.71115b@dinox.im','leon':'leon.fischer.interop.de.71115b@dinox.im','felix':'felix.wagner.interop.de.71115b@dinox.im'}


def sha(path): return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def node(path, name, kind=ast.FunctionDef, last=False):
    nodes = [n for n in ast.parse(Path(path).read_text()).body if isinstance(n, kind) and n.name == name]
    return nodes[-1] if last else nodes[0]


def extract(path, names, scope):
    selected = [node(path, n) for n in names]
    exec(compile(ast.Module(body=selected, type_ignores=[]), '<actual-extracted-source>', 'exec'), scope)
    return scope


def rejected(operation, error=(AssertionError, ValueError, KeyError)):
    try: operation()
    except error: return
    raise AssertionError('Invalid offline fixture was accepted')


def main():
    for path in HERE.glob('*.py'): ast.parse(path.read_text())
    freeze = json.loads((HERE / 'freeze.json').read_bytes())
    assert freeze['mode'] == 'Nora-only-current-mixed-three-video-20261018'
    assert freeze['files_sha256'] == {name:sha(HERE/name) for name in ('runtime.py','control.py','recorder.py','scenario.py','monitor.py','process_lifecycle.py')}
    assert freeze['root_start_authorized'] is freeze['marker_created'] is freeze['runtime_started'] is False
    for name, digest in freeze['external_source_sha256'].items(): assert sha(name) == digest
    # All actual launch, immutable input, PID, cgroup, SDK, role and source gates stay intact.
    for name in ('run','role_config','environment','emulator_command','adb_command','_native_readonly_bindings','control_settings','validate_private_config','verify_derivation'):
        assert ast.dump(node(HERE/'runtime.py',name,last=True),include_attributes=False) == ast.dump(node(HERE.parent/'runtime.py',name,last=True),include_attributes=False), name
    gate=ast.unparse(node(HERE/'runtime.py','gate',last=True))
    old_gate=ast.unparse(node(HERE.parent/'runtime.py','gate',last=True))
    assert gate==old_gate.replace('inventory.guest_processes(inventory.load_baseline())','sdk_guest_inventory(inventory)')
    assert sha(HERE/'process_lifecycle.py')=='cbccb23b594d64471ce2851dd9105c99a874bd3bc061e7631e2fd4dd9a46fff9'
    assert not any(isinstance(n,ast.Assign) and any(isinstance(t,ast.Attribute) and t.attr=='guest_processes' for t in n.targets) for n in ast.walk(ast.parse((HERE/'runtime.py').read_text())))
    for name in ('enum_is','idle','wait_for','public_identity','owner_session','android_record'):
        assert ast.dump(node(HERE/'scenario.py',name),include_attributes=False) == ast.dump(node(AUTH,name),include_attributes=False), name
    assert (HERE/'recorder.py').read_bytes() == (HARNESS/'devicefix_nora_runtime/recorder.py').read_bytes()
    for name,kind in [('normalize',ast.FunctionDef),('reject_private',ast.FunctionDef),('redact',ast.FunctionDef),('failure',ast.FunctionDef),('Android',ast.ClassDef),('control',ast.FunctionDef),('arguments',ast.FunctionDef)]:
        assert ast.dump(node(HERE/'control.py',name,kind),include_attributes=False) == ast.dump(node(HARNESS/'devicefix_nora_runtime/control.py',name,kind),include_attributes=False)
    runtime = SimpleNamespace(OWN=OWN)
    scope = {'runtime':runtime,'re':re,'Path':Path,'OPS':{'status','stats','stop','prepare_crypto','start_call','hangup'}}
    extract(HERE/'control.py',('reject_private','validate'),scope)
    envelope = lambda payload:{'action':'command','role':'nora','transport':'local-android','wait':0,'id':'a'*32,'payload':payload}
    for payload in ({'op':'status'},{'op':'stats'},{'op':'stop'},{'op':'prepare_crypto','peer':'leon','encryption':'legacy'},
                    {'op':'start_call','peer':'leon','video':True},{'op':'hangup','session_id':'owned-session'},
                    {'op':'hangup','call_id':'owned-conference'}): scope['validate'](envelope(payload))
    for payload in ({'op':'start_call','peer':'leon','video':False},{'op':'start_call','peer':'felix','video':True},
                    {'op':'prepare_crypto','peer':'leon','encryption':'pq'},{'op':'prepare_crypto','room':'foreign','encryption':'legacy'},
                    {'op':'send_text','text':'not-in-this-case'},{'op':'trust'},{'op':'add_participant'},
                    {'op':'status','password':'unmasked'},{'op':'hangup','call_id':True},{'op':'hangup','call_id':'space value'},
                    {'op':'hangup','call_id':'one','session_id':'two'}): rejected(lambda p=payload:scope['validate'](envelope(p)))
    for extra in ({'role':'leon'},{'transport':'server'},{'id':'not-a-command-uuid'}): rejected(lambda e=extra:scope['validate']({**envelope({'op':'stats'}),**e}))
    # Run the actual durable claim function on small private temporary files only.
    with tempfile.TemporaryDirectory(prefix='A18V-once-offline-') as folder:
        base = Path(folder); evidence = base/'admission.json';evidence.write_text('{"offline_fixture":true}\n');evidence.chmod(0o600)
        fake = SimpleNamespace(STATE=base/'runtime-state',RUN='20261015-71115b',sha=sha)
        env = {'r':fake,'re':re,'os':os,'stat':stat,'json':json,'CASE_SHA':freeze['external_source_sha256'][str(HERE.parent/'mixed-three-video/media_case.py')]}
        extract(HERE/'scenario.py',('claim_once',),env)
        root={'batch_id':'b'*32,'runtime_freeze_sha256':'f'*64,'session_binding':{'offline_fixture':True}}
        path=Path(env['claim_once'](root,evidence));before=sha(path)
        assert path.stat().st_mode&0o777==0o600
        evidence.write_text('{"different_admission_same_batch":true}\n')
        rejected(lambda:env['claim_once'](root,evidence),(FileExistsError,))
        assert sha(path)==before
    # Execute the unchanged actual session guard using synthetic public process facts.
    keys={'controller_pid','controller_start_ticks','adb_pid','adb_start_ticks','emulator_pid','emulator_start_ticks','adb_cgroup','approval_sha256'}
    session={'schema_version':2,'state':'running','ready':True,'run_id':'20261015-71115b','role':'nora','batch_id':'b'*32,
             'freeze_sha256':'f'*64,'apk_sha256':{'main.apk':'m'},'guest_memory_mib':2048,'inputs_sha256':'i'*64,
             'batch_deadline_unix':200,'controller_pid':10,'controller_start_ticks':'10t','adb_pid':11,'adb_start_ticks':'11t',
             'emulator_pid':12,'emulator_start_ticks':'12t','adb_cgroup':'/slice/owned','approval_sha256':'p'*64,
             'adb_sha256':'s'*64,'native_readonly_bindings':{'offline_fixture':True}}
    root={'batch_id':session['batch_id'],'runtime_freeze_sha256':'f'*64,'runtime_inputs_sha256':'i'*64,
          'session_binding':{k:session[k]for k in keys},'process_cgroups':{n:'/slice/owned'for n in ('controller','adb','emulator')},
          'native_bindings':session['native_readonly_bindings']}
    current=copy.deepcopy(session)
    fake=SimpleNamespace(RUN='20261015-71115b',ROOT=Path('/offline-fixture'),APKS={'main.apk':'m'},
        role_config=lambda role:{'state':Path('/offline-fixture/state')},read=lambda path:current,
        sha=lambda path:'s'*64 if str(path).endswith('/adb')else'i'*64,
        v1=SimpleNamespace(SLICE='slice',start_ticks=lambda pid:str(pid)+'t',process_cgroup=lambda pid:'/slice/owned'))
    env={'r':fake,'Path':Path,'time':SimpleNamespace(time=lambda:100),'FREEZE':'f'*64}
    extract(HERE/'scenario.py',('owner_session',),env);env['owner_session'](root)
    for field,value in [('ready',False),('batch_id','other'),('freeze_sha256','changed'),('apk_sha256',{}),
                        ('guest_memory_mib',4096),('inputs_sha256','changed'),('batch_deadline_unix',99),
                        ('controller_start_ticks','reused-pid'),('adb_sha256','replacement'),('native_readonly_bindings',{})]:
        current.clear();current.update(copy.deepcopy(session));current[field]=value
        rejected(lambda:env['owner_session'](root))
    scenario=(HERE/'scenario.py').read_text();main_node=node(HERE/'scenario.py','main')
    assert scenario.index('    claim_once(root,args.root_admission)')<scenario.index('        case.scenario(op, write, context)')
    assert 'scenario(op, write, context)' in scenario and 'video_tested\': False' not in scenario
    assert "payload.get('op')!='stop'" in scenario and 'finally:' in scenario
    assert 'context[\'native\'][role]' in scenario and 'cleanup-end-observed-native-once' in scenario
    assert 'no_automatic_retry' in scenario and 'media_proves_auth\':False' in scenario
    assert 'actual_workers_if_started' in scenario and 'len(workers)==1' in scenario
    assert 'sys.modules[\'native_control\']' in scenario  # Normal explicit dependency registration, no frozen caller impersonation.
    assert not (HERE/'runtime-state').exists() and not (HERE/'owner-native-admission.json').exists()
    result={'result':'SOURCE_AST_AND_EXTRACTED_OFFLINE_METHODS_PASS','operational_files':6,
            'operational_bytes':sum((HERE/n).stat().st_size for n in freeze['files_sha256']),
            'launch_owner_input_controls_AST_unchanged':True,'session_and_recorder_helpers_AST_unchanged':True,
            'sole_process_gate_delta_explicit_checked_lifecycle_scan_no_globals_override':True,
            'original_call_IO_redaction_and_command_UUID_path_unchanged':True,'Nora_video_only_allowlist_negatives':True,
            'actual_once_claim_second_admission_same_batch_rejected':True,'actual_owner_session_negative_cases':10,
            'native_ids_and_runtime_admissions_not_fabricated':True,'pure_case_source_unchanged':True,
            'no_operational_runtime_import_or_process_ADB_SSH_build_action':True}
    (HERE/'offline-checks.json').write_text(json.dumps(result,indent=2)+'\n');(HERE/'offline-checks.json').chmod(0o600)
    print(json.dumps(result,indent=2))


if __name__=='__main__':main()

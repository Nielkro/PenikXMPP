#!/usr/bin/env python3
"""Pure local derivation/receipt regression. Never imports a runtime or contacts a guest."""
import ast
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile

HERE=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('checked_source_derivation',HERE/'prepare_source.py')
d=importlib.util.module_from_spec(spec);spec.loader.exec_module(d)
guard=(HERE/'current_product_guard.source').read_text()
checks=[]

def check(name,predicate):
    assert predicate,name
    checks.append(name)

def nodes(raw):return ast.parse(raw.decode() if isinstance(raw,bytes) else raw).body

def dumps(items):return [ast.dump(x,include_attributes=False) for x in items]

def accepts(product):
    env={'PRODUCT':product,'APKS':{'main.apk':product['main_sha256'],'android-test.apk':product['test_sha256']},
         'JOIN_PRODUCT_PROOF':{'synthetic_offline_fixture':True},'Path':Path,'sha':d.sha,'read':d.read}
    exec(compile(ast.parse(guard),'<actual-product-guard-offline>','exec'),env)
    return env['_current_product']()

with tempfile.TemporaryDirectory(prefix='remesh-source-only-') as tmp:
    root=Path(tmp)
    original=ast.literal_eval([x.value for x in nodes((d.BASE/'runtime.py').read_bytes())
        if isinstance(x,ast.Assign) and any(isinstance(t,ast.Name) and t.id=='PRODUCT' for t in x.targets)][-1])
    product=copy.deepcopy(original)
    # Deliberately synthetic and not 633: the derivation reads the actual receipt count.
    product.update(main_path=str(root/'synthetic-main.apk'),main_sha256=hashlib.sha256(b'synthetic-not-an-apk').hexdigest(),
        actual_jvm_tests=641,actual_focus_tests=17,commit='a'*40)
    (root/'synthetic-main.apk').write_bytes(b'synthetic-not-an-apk')
    focus=[['eu.siacs.conversations.xmpp.jingle.MujiLegWatchdogTest','syntheticCase'+str(i)] for i in range(17)]
    full=focus+[['synthetic.parent.Test','syntheticCase'+str(i)] for i in range(624)]
    delta='ffd723b693499c3b5a0eec194ded034b16519bbe0e2e4a0a9ddd6b106ab48b7f'
    source={'product_delta_manifest_sha256':delta,'product_delta_review_sha256':'e'*64,
        'accepted_parent_source_sha256':original['source']['sha256'],
        'files':{k:{'sha256':v} for k,v in {
            'src/main/java/eu/siacs/conversations/xmpp/jingle/MujiConferenceManager.java':'035fd5f32085b4fb807abb840a63d06642f09bf7b2eaaca23e26b12c488640cb',
            'src/test/java/eu/siacs/conversations/xmpp/jingle/MujiLegWatchdogTest.java':'dd9d6e1ddcc58cc6a40d3af12d5b8036abd8cd498301d1af79af40c052f880c1',
            'src/test/java/eu/siacs/conversations/xmpp/jingle/MujiInvitationSecurityTest.java':'c97b82909f83e99cac5a9497e590ebc12ff6ce6460425ec9d5f7541f6770cc4b',
        }.items()}}
    native={str(i):'f'*64 for i in range(5)}
    values={'source':source}
    def write_ref(name,value):
        path=root/(name+'.json');path.write_text(json.dumps(value));product[name]={'path':str(path),'sha256':d.sha(path)}
    write_ref('source',source)
    common={'result':'PASS','source_manifest_sha256':product['source']['sha256'],'failures':0,'errors':0,'skipped':0}
    values['focus']={**common,'tests':17,'unique_cases':17,'cases':focus}
    values['jvm']={**common,'tests':641,'unique_cases':641,'cases':full,'whole_application_suite_without_test_filter':True,
        'product_delta_manifest_sha256':delta,'historical_parent_test_count':616,'native_unchanged':native}
    write_ref('jvm',values['jvm']);write_ref('focus',values['focus'])
    values['build']={'result':'PASS','apk_sha256':product['main_sha256'],'existing_signed_test_apk_sha256':product['test_sha256'],
        'source_manifest_sha256':product['source']['sha256'],'jvm_receipt_sha256':product['jvm']['sha256'],
        'focus_jvm_receipt_sha256':product['focus']['sha256'],'actual_jvm_tests':641,'actual_focus_tests':17,
        'product_delta_manifest_sha256':delta,'product_delta_review_sha256':'e'*64,
        'normal_main_basis_sha256':original['main_sha256'],'only_MujiConferenceManager_class_family_changed':True,
        'all_non_dex_payload_entries_unchanged':True,'all_36_native_entries_unchanged':True,
        'native_or_sdk_build_requested':False,'test_apk_rebuilt':False,'native_unchanged':native,
        'signer_certificate_sha256':product['signer_certificate_sha256']}
    write_ref('build',values['build'])
    values['handoff']={'result':'PASS','apk_sha256':product['main_sha256'],'test_apk_sha256':product['test_sha256'],
        'source_manifest_sha256':product['source']['sha256'],'actual_jvm_tests':641,'actual_focus_tests':17,
        'signer_certificate_sha256':product['signer_certificate_sha256'],'reviewed_source_commit':product['commit']}
    write_ref('handoff',values['handoff'])
    check('actual_guard_accepts_consistent_synthetic_641_receipts',accepts(product)=={'synthetic_offline_fixture':True})
    pin_loop=next(n for n in ast.parse(guard).body[0].body if isinstance(n,ast.For)
        and isinstance(n.iter,ast.Call) and isinstance(n.iter.func,ast.Attribute)
        and isinstance(n.iter.func.value,ast.Dict))
    def source_pin_check(files):
        exec(compile(ast.Module(body=[pin_loop],type_ignores=[]),'<actual-three-source-pin-loop>','exec'),{'s':{'files':files}})
    source_pin_check(source['files']);checks.append('actual_guard_three_file_closure_accepts_exact_hashes')
    for name in source['files']:
        bad=copy.deepcopy(source['files']);bad[name]['sha256']='0'*64
        try:source_pin_check(bad)
        except AssertionError:checks.append('reject_changed_source_'+Path(name).name)
        else:raise AssertionError('Unexpected source acceptance: '+name)
    check('actual_qualifier_hashes_small_new_fixture_and_unchanged_existing_test_apk',d.qualify(product,guard)==original)
    for name,key,value in [('jvm','errors',1),('jvm','whole_application_suite_without_test_filter',False),
        ('jvm','historical_parent_test_count',615),('focus','tests',16),('focus','cases',focus[:-1]+[focus[0]]),
        ('build','product_delta_manifest_sha256','0'*64),('build','native_or_sdk_build_requested',True),
        ('build','test_apk_rebuilt',True),('build','signer_certificate_sha256','0'*64),
        ('handoff','actual_jvm_tests',633),('handoff','test_apk_sha256','0'*64)]:
        saved=copy.deepcopy(values[name]);bad=copy.deepcopy(saved);bad[key]=value;write_ref(name,bad)
        try:accepts(product)
        except AssertionError:checks.append('reject_'+name+'_'+key)
        else:raise AssertionError('Unexpected guard acceptance: '+name+'/'+key)
        write_ref(name,saved)
    values_out=d.derive(product,guard)
    for name in ('control.py','recorder.py','monitor.py','process_lifecycle.py'):
        check(name+'_byte_identical',values_out[name]==(d.BASE/name).read_bytes())
    runtime_old=nodes((d.BASE/'runtime.py').read_bytes());runtime_new=nodes(values_out['runtime.py'])
    changed=[]
    check('runtime_top_level_statement_count_unchanged',len(runtime_old)==len(runtime_new))
    for before,after in zip(runtime_old,runtime_new):
        if dumps([before])!=dumps([after]):
            name=before.name if isinstance(before,ast.FunctionDef) else before.targets[0].id
            changed.append(name)
    check('only_runtime_product_bindings_and_receipt_guard_changed',changed==['PRODUCT','CLIENT_VARIANT','JOIN_PRODUCT_PROOF','_current_product','verify_derivation'])
    scenario_old=nodes((d.BASE/'scenario.py').read_bytes());scenario_new=nodes(values_out['scenario.py'])
    check('scenario_top_level_statement_count_unchanged',len(scenario_old)==len(scenario_new))
    changed=[]
    for before,after in zip(scenario_old,scenario_new):
        if dumps([before])!=dumps([after]):
            name=before.name if isinstance(before,ast.FunctionDef) else before.targets[0].id
            changed.append(name)
            if name=='main':
                expected=ast.parse(ast.unparse(before).replace("join['actual_jvm_tests'] == 616","join['actual_jvm_tests'] == r.PRODUCT['actual_jvm_tests']")).body[0]
                check('scenario_main_only_uses_receipt_count',dumps([expected])==dumps([after]))
    check('scenario_only_main_apk_hash_and_actual_count_changed',changed==['MAIN','main'])
    old_freeze=d.read(d.BASE/'freeze.json');new_freeze=json.loads(values_out['freeze.json'])
    check('freeze_external_case_lifecycle_native_pins_unchanged',new_freeze['external_source_sha256']==old_freeze['external_source_sha256'])
    check('new_freeze_has_no_runtime_authorization',all(new_freeze[k] is False for k in ('root_start_authorized','marker_created','runtime_started')))
    # Real generator must fail closed before deriving any operational file without true inputs.
    q=subprocess.run([sys.executable,'-B',str(HERE/'prepare_source.py'),'--product-pins',str(root/'missing-real-pins.json')],capture_output=True,text=True,timeout=15)
    check('missing_real_build_fails_closed',q.returncode==2 and q.stdout.strip()=='NOT_READY_REAL_BUILD_JVM_FOCUS_APK_HANDOFF_PINS_REQUIRED' and not q.stderr)
    check('no_operational_sources_claim_markers_runtime_or_freeze_created',not (HERE/'runtime-state').exists() and all(not (HERE/n).exists() for n in (*d.NAMES,'freeze.json','product-pins.json')))

print(json.dumps({'result':'PASS','scope':'SOURCE_ONLY_SYNTHETIC_RECEIPT_AND_ACTUAL_DERIVATION_OFFLINE_CHECKS',
    'checks':checks,'checks_count':len(checks),'actual_new_jvm_or_apk_result_claimed':False,
    'runtime_module_imported':False,'guest_server_or_build_action':False},indent=2))

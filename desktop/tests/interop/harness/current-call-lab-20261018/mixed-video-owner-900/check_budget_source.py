#!/usr/bin/env python3
"""Check only the actual new case budget functions with public offline facts."""
import ast
import copy
import datetime
import hashlib
import json
from pathlib import Path
import re
import tempfile
from types import SimpleNamespace

HERE=Path(__file__).resolve().parent
OLD=HERE.parent/'mixed-video-owner-source'


def sha(path): return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def definitions(path):
    return {n.name:n for n in ast.parse(path.read_text()).body if isinstance(n,ast.FunctionDef)}


def rejected(fn):
    try:fn()
    except (AssertionError,KeyError,ValueError):return
    raise AssertionError('Invalid offline case budget accepted')


def main():
    assert sha(OLD/'source-manifest.json')=='e3431bddb31aa783ffa608018d228126000e82087df29fccce57bed453431c74'
    assert sha(OLD/'freeze.json')=='07d2662015e858872ea02476f739aea08811797d0c56dbccc8ac84e9fa2c29e9'
    native=HERE.parent/'native-current-driver/runtime-source'
    assert sha(native/'source-manifest.json')=='3f9f8fc46e95cd20864e417560366a182e4f94f92e734189b9ad4ae7824584d4'
    native_manifest=json.loads((native/'source-manifest.json').read_bytes())
    for role in ('leon','felix'):
        entry=native/('server_entry_'+role+'.sh')
        assert sha(entry)==native_manifest['files'][entry.name]['sha256']
        assert entry.read_text().count('timeout --signal=TERM --kill-after=20 5400 ')==1
    for name in ('runtime.py','control.py','recorder.py','monitor.py','process_lifecycle.py'):
        assert (HERE/name).read_bytes()==(OLD/name).read_bytes(),name
    old=definitions(OLD/'scenario.py');new=definitions(HERE/'scenario.py')
    assert set(new)==set(old)|{'case_budget_deadline'}
    for name in set(old)-{'main','root_admission'}:
        assert ast.dump(old[name],include_attributes=False)==ast.dump(new[name],include_attributes=False),name
    admission=copy.deepcopy(new['root_admission'])
    changed=[n for n in ast.walk(admission) if isinstance(n,ast.Constant) and n.value==900]
    assert len(changed)==1;changed[0].value=240
    assert ast.dump(admission,include_attributes=False)==ast.dump(old['root_admission'],include_attributes=False)
    current=copy.deepcopy(new['main']);prior=old['main']
    assignment=lambda node:next(n for n in node.body if isinstance(n,ast.Assign) and any(isinstance(t,ast.Name) and t.id=='case_deadline' for t in n.targets))
    new_assignment=assignment(current);old_assignment=assignment(prior)
    assert ast.unparse(new_assignment.value)=='case_budget_deadline(root, session)'
    new_assignment.value=copy.deepcopy(old_assignment.value)
    assert ast.dump(current,include_attributes=False)==ast.dump(prior,include_attributes=False)
    # Execute the complete changed admission function. Unchanged session checks
    # have their independent original AST regressions; no runtime is imported.
    scenario_path=HERE/'scenario.py';case_path=HERE.parent/'mixed-three-video/media_case.py'
    freeze=json.loads((HERE/'freeze.json').read_bytes());clock=SimpleNamespace(time=lambda:1000.0)
    accounts={role:role+'@offline.invalid' for role in ('nora','leon','felix')}
    root={'operation':'owner-current-mixed-three-video','runtime_profile':'A18V','scenario_sha256':sha(scenario_path),
          'run_id':'offline-fixture','accounts':accounts,'role':'nora','created_unix':1000.0,'expires_unix':1900.0,
          'runtime_freeze_sha256':sha(HERE/'freeze.json'),'identities':{
              role:{'account':accounts[role],'device_id':device,'legacy_fingerprint':'05'+'1'*64}
              for role,device in [('nora',1),('leon',172062497),('felix',1228426141)]},
          'case_source_sha256':sha(case_path),'native_runtime_source_manifest_sha256':'3f9f8fc46e95cd20864e417560366a182e4f94f92e734189b9ad4ae7824584d4',
          'native_bindings':{'directory':str(Path('/media/linux/SSD128/xmppwin/local/monocles-dinox-interop-20261015/harness/native_current_20261018'))}}
    with tempfile.TemporaryDirectory(prefix='A18V900-offline-') as folder:
        folder=Path(folder);admission_path=folder/'admission.json'
        admission_path.write_text('{"offline":true}\n');admission_path.chmod(0o600)
        fixture=copy.deepcopy(root)
        runtime=SimpleNamespace(read=lambda path:fixture,sha=sha,RUN='offline-fixture',OWN=accounts,
            frozen_files=lambda:sha(HERE/'freeze.json'),APKS=freeze['apk_sha256'])
        env={'Path':Path,'r':runtime,'time':clock,'__file__':str(scenario_path),'A_DIR':HERE,
             'RECORDER_SHA':sha(HERE/'recorder.py'),'FREEZE':sha(HERE/'freeze.json'),
             'MAIN':freeze['apk_sha256']['main.apk'],'ROLES':('nora','leon','felix'),'re':re,
             'CASE':case_path,'CASE_SHA':sha(case_path),
             'HARNESS':Path('/media/linux/SSD128/xmppwin/local/monocles-dinox-interop-20261015/harness'),
             'owner_session':lambda value:None}
        exec(compile(ast.Module(body=[new['root_admission']],type_ignores=[]),'<actual-admission-AST>','exec'),env)
        env['root_admission'](admission_path)
        for created,expires in [(1000.0,1240.0),(880.0,1780.0),(1000.0,1000.001)]:
            fixture.clear();fixture.update(copy.deepcopy(root));fixture.update(created_unix=created,expires_unix=expires)
            env['root_admission'](admission_path)
        for created,expires in [(1000.0,1900.001),(879.999,1779.999),(1000.001,1900.0),
                                (1000.0,1000.0),(1000.0,float('nan'))]:
            fixture.clear();fixture.update(copy.deepcopy(root));fixture.update(created_unix=created,expires_unix=expires)
            rejected(lambda:env['root_admission'](admission_path))
        # Actual whole helper reads and hashes the stored exact inspect bytes.
        binding={'inspects':{},'owner_admission':{'roles':{}}}
        def inspect(role,started):
            path=folder/(role+'-inspect.json');cid={'leon':'a'*64,'felix':'b'*64}[role]
            path.write_text(json.dumps([{'Id':cid,'State':{'Running':True,'Status':'running',
                'StartedAt':datetime.datetime.fromtimestamp(started,datetime.timezone.utc).isoformat()}}]))
            binding['inspects'][role]={'path':str(path),'sha256':sha(path)}
            binding['owner_admission']['roles'][role]={'container_id':cid}
        inspect('leon',0);inspect('felix',1)
        budget_root={'created_unix':1000.0,'expires_unix':1900.0,'native_bindings':binding}
        session={'batch_deadline_unix':2300.0}
        env={'Path':Path,'r':SimpleNamespace(read=lambda path:json.loads(Path(path).read_bytes()),sha=sha),'datetime':datetime}
        exec(compile(ast.Module(body=[new['case_budget_deadline']],type_ignores=[]),'<actual-budget-AST>','exec'),env)
        deadline=lambda:env['case_budget_deadline'](budget_root,session)
        assert deadline()==1900.0
        budget_root['expires_unix']=1800.0;assert deadline()==1800.0
        budget_root['expires_unix']=2000.0;assert deadline()==1900.0
        budget_root['expires_unix']=1900.0;session['batch_deadline_unix']=1700.0;assert deadline()==1580.0
        session['batch_deadline_unix']=2300.0;inspect('leon',-4000);assert deadline()==1280.0
        inspect('felix',-4100);assert deadline()==1180.0
        actual_reserve=next(n for n in new['main'].body if isinstance(n,ast.Assert) and 'Keep case and cleanup reserves' in ast.unparse(n))
        for value,accepted in ((1090.0,True),(1089.999,False),(1000.0,False)):
            call=lambda:exec(compile(ast.Module(body=[actual_reserve],type_ignores=[]),'<actual-reserve-AST>','exec'),{'case_deadline':value,'time':clock})
            if accepted:call()
            else:rejected(call)
        ref=binding['inspects']['leon'];original=ref['sha256'];ref['sha256']='0'*64;rejected(deadline);ref['sha256']=original
        cid=binding['owner_admission']['roles']['leon']['container_id'];binding['owner_admission']['roles']['leon']['container_id']='c'*64
        rejected(deadline);binding['owner_admission']['roles']['leon']['container_id']=cid
        saved=binding['inspects'].pop('felix');rejected(deadline);binding['inspects']['felix']=saved
        path=Path(saved['path']);raw=path.read_bytes();rows=json.loads(raw)
        rows[0]['State']['Running']=False;path.write_text(json.dumps(rows));saved['sha256']=sha(path);rejected(deadline)
        path.write_bytes(raw);saved['sha256']=sha(path)
        rows=json.loads(raw);rows[0]['State']['StartedAt']='invalid-time';path.write_text(json.dumps(rows));saved['sha256']=sha(path);rejected(deadline)
    report={'result':'SOURCE_ONLY_ACTUAL_900S_BUDGET_AST_BOUNDARIES_PASS',
            'five_other_operational_sources_byte_identical':True,'other_scenario_functions_AST_identical':True,
            'main_only_deadline_assignment_changed':True,'entry_age_max_seconds':120,'case_max_seconds':900,
            'Nora_and_both_native_cleanup_reserve_seconds':120,'minimum_entry_runtime_seconds':90,
            'actual_admission_positive_cases':4,'actual_admission_negative_cases':5,
            'actual_deadline_positive_cases':6,'actual_deadline_reject_cases':5,'actual_reserve_boundaries':3,
            'native_5400s_timer_verified_against_both_manifest_pinned_entry_sources':True,
            'UUID_claim_product_ops_cleanup_and_auth_semantics_unchanged':True,
            'no_runtime_import_or_SSH_ADB_guest_build_or_account_action':True}
    path=HERE/'budget-offline-checks.json';path.write_text(json.dumps(report,indent=2)+'\n');path.chmod(0o600)
    print(json.dumps(report,indent=2))


if __name__=='__main__':main()

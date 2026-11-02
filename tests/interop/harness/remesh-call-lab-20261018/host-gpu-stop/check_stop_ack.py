#!/usr/bin/env python3
"""Offline tests of the real helper and AST-loaded actual controller, no runtime imports."""
import ast
import copy
from contextlib import nullcontext
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import threading
import time
from types import SimpleNamespace
import uuid

HERE=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('checked_stop_ack',HERE/'stop_ack.py')
ack=importlib.util.module_from_spec(spec);spec.loader.exec_module(ack)
checks=[]

def check(name,value):
    assert value,name
    checks.append(name)

def rejects(name,action):
    try:action()
    except (AssertionError,FileExistsError):checks.append(name)
    else:raise AssertionError(name)

def session(role='nora'):
    return {'run_id':'20261015-71115b','role':role,'batch_id':uuid.uuid4().hex,'freeze_sha256':'a'*64,
        'controller_pid':11,'controller_start_ticks':'12','adb_pid':21,'adb_start_ticks':'22',
        'emulator_pid':31,'emulator_start_ticks':'32','batch_deadline_unix':time.time()+3600}

class Clock:
    def __init__(self,value=100):self.value=float(value)
    def __call__(self):return self.value
    def sleep(self,seconds):self.value+=seconds

with tempfile.TemporaryDirectory(prefix='stop-ack-pure-') as temporary:
    root=Path(temporary)
    for name in ('pending','settled'):
        target=root/('atomic.'+name+'.json');paused=threading.Event();release=threading.Event();errors=[]
        class PausedDict(dict):
            def items(self):
                for i,item in enumerate(super().items()):
                    if i==1:
                        paused.set();assert release.wait(5)
                    yield item
        payload=PausedDict(prefix='x'*12000,suffix='y'*12000)
        def writer():
            try:ack.write_once(target,payload)
            except BaseException as error:errors.append(type(error).__name__)
        thread=threading.Thread(target=writer);thread.start();assert paused.wait(5)
        partials=list(root.glob('.'+target.name+'.*.partial'))
        check(name+'_writer_really_has_partial_hidden_bytes',len(partials)==1 and partials[0].stat().st_size>0)
        observed=[]
        def reader():
            for _ in range(100):
                try:observed.append(ack.read(target))
                except FileNotFoundError:observed.append(None)
        concurrent=threading.Thread(target=reader);concurrent.start();concurrent.join(5)
        check(name+'_partial_never_visible_at_final_path',len(observed)==100 and all(v is None for v in observed))
        release.set();thread.join(5);check(name+'_complete_json_published',not thread.is_alive() and not errors and ack.read(target)==dict(payload))
        before=target.read_bytes();rejects(name+'_atomic_publish_never_overwrites',lambda:ack.write_once(target,{'other':True}))
        check(name+'_once_bytes_unchanged_and_no_temp_left',target.read_bytes()==before and not list(root.glob('.'+target.name+'.*.partial')))
    s=session();s['batch_deadline_unix']=2000;clock=Clock();ticket=ack.begin(root,s,'1'*32,clock(),clock=clock,wall=lambda:1000)
    original=Path(ticket['pending_path']).read_bytes();clock.value=120
    result=ack.drain(root,s,clock=clock,sleep=clock.sleep,wall=lambda:1000)
    check('no_ack_deadline_counts_from_original_intent_not_exit',result['status']=='fixed_deadline_expired' and abs(result['waited_seconds']-35)<.001 and clock()==155)
    check('drain_never_renews_or_rewrites_intent',Path(ticket['pending_path']).read_bytes()==original)
    rejects('second_stop_id_same_batch_rejected',lambda:ack.begin(root,s,'2'*32,clock(),clock=clock,wall=lambda:1000))
    foreign=dict(s,controller_start_ticks='999')
    rejects('foreign_controller_generation_rejected',lambda:ack.drain(root,foreign,clock=clock,sleep=clock.sleep,wall=lambda:1000))
    s2=session();s2['batch_deadline_unix']=1005;c2=Clock();t2=ack.begin(root,s2,'3'*32,c2(),clock=c2,wall=lambda:1000);c2.value=104
    r2=ack.drain(root,s2,clock=c2,sleep=c2.sleep,wall=lambda:1004)
    check('batch_hard_deadline_wins_without_extra_grace',r2['status']=='fixed_deadline_expired' and c2()==105)
    for role in ('nora','leon','felix'):
        row=session(role);a,b=ack.paths(root,row)
        check(role+'_explicit_role_in_pending_filename',a.name.startswith('stop-ack-'+role+'-') and b.name.startswith('stop-ack-'+role+'-'))
    # Reader disappearance does not create an unbounded runtime wait.
    sd=session();sd['batch_deadline_unix']=2000;cd=Clock();td=ack.begin(root,sd,'4'*32,cd(),clock=cd,wall=lambda:1000)
    vd=copy.deepcopy(td['value']);vd['reader_pid']=2147483646
    pd=Path(td['pending_path']);pd.write_text(json.dumps(vd));pd.chmod(0o600)
    rejects('foreign_reader_cannot_settle_creator_intent',lambda:ack.settle({'pending_path':str(pd),'value':vd},'ack_received','response_validated'))
    rd=ack.drain(root,sd,clock=cd,sleep=cd.sleep,wall=lambda:1000)
    check('dead_reader_bounded_timeout_cleanup',rd['status']=='fixed_deadline_expired' and cd()==155)

# Actual modified Android.call/submit/control/failure, with only I/O endpoints mocked.
source=ast.parse((HERE/'control.py').read_text())
function_names={'safe_leaf','validate','reject_private','normalize','redact','failure','_control_active','control'}
body=[n for n in source.body if isinstance(n,ast.FunctionDef) and n.name in function_names or isinstance(n,ast.ClassDef) and n.name=='Android'
      or isinstance(n,ast.Assign) and any(isinstance(t,ast.Name) and t.id in ('OPS','_PHASE','_LAST_RC','_DIAGNOSTIC') for t in n.targets)]

def controller_case(mode):
    with tempfile.TemporaryDirectory(prefix='actual-controller-stop-') as temporary:
        directory=Path(temporary);s=session();(directory/'live-session.json').write_text(json.dumps(s))
        alive=[True];published=[0];response_read=[False];drained=[];thread=[];failures=[];guards=[0];config_reads=[0];validations=[]
        identifier=uuid.uuid4().hex;secret='FAKE_SECRET_DO_NOT_LOG';account='nora@example.test'
        config={'run_id':s['run_id'],'jid':account,'password':secret,'allowed_jids':[]}
        files={'files/interop/config.json':json.dumps(config).encode()}
        def owner_guard(role):
            guards[0]+=1;assert alive[0],secret
            return {'state':directory,'adb_port':5038}
        def validate_config(role,value):
            validations.append(not ack.paths(directory,s)[0].exists() and published[0]==0)
            assert mode!='bad_config' and value['jid']==account and value['run_id']==s['run_id'],secret
        runtime=SimpleNamespace(control_settings=owner_guard,read=lambda path:json.loads(Path(path).read_text()),
            stop_ack=ack,RUN=s['run_id'],OWN={'nora':account},v1=SimpleNamespace(PACKAGE='test.package'),
            adb_command=lambda role:['adb'],environment=lambda role:{},validate_private_config=validate_config)
        def runtime_end():
            try:
                value=ack.drain(directory,s,sleep=lambda duration:time.sleep(min(duration,.001)))
                drained.append(value);alive[0]=False
            except BaseException as error:failures.append(type(error).__name__)
        def run(argv,**kwargs):
            args=argv[argv.index('run-as')+2:];command=args[0];rc=0;stdout=b''
            if mode=='io_failure' and scope['_PHASE']=='postpublication_verify':rc=24
            elif command=='test':
                rc=0 if (args[-1] in files)==(args[1]!='!') else 1
            elif command=='dd':files[args[1][3:]]=kwargs['input']
            elif command=='cat':
                stdout=files[args[1]]
                if args[1]=='files/interop/config.json':config_reads[0]+=1
                if '/results/' in args[1]:response_read[0]=True
            elif command=='mv':
                files[args[-1]]=files.pop(args[-2]);published[0]+=1
                if mode!='no_ack':files['files/interop/results/'+identifier+'.json']=json.dumps(
                    {'run_id':s['run_id'],'account':account,'id':identifier,'ok':True,'stopping':True,'note':secret}).encode()
                if mode=='old_race':alive[0]=False
                else:
                    worker=threading.Thread(target=runtime_end);thread.append(worker);worker.start()
            elif command=='rm':files.pop(args[-1],None)
            time.sleep(.001)
            return SimpleNamespace(returncode=rc,stdout=stdout,stderr=secret.encode())
        scope={'runtime':runtime,'Path':Path,'time':time,'json':json,'re':re,'os':os,'sys':sys,'uuid':uuid,
            'socket':SimpleNamespace(create_connection=lambda *a,**kw:nullcontext()),
            'subprocess':SimpleNamespace(run=run,PIPE=object())}
        exec(compile(ast.Module(body=body,type_ignores=[]),'<actual-stop-controller-AST>','exec'),scope)
        request={'action':'command','role':'nora','transport':'local-android','wait':0 if mode=='no_ack' else 20,
            'id':identifier,'payload':{'op':'stop'}}
        try:result=scope['control'](request)
        except Exception as error:result=scope['failure'](request,error)
        for worker in thread:worker.join(5)
        check(mode+'_no_raw_error_stderr_argv_or_config_secret',secret not in json.dumps(result))
        check(mode+'_private_config_read_once_before_intent',config_reads[0]==1 and validations[0])
        if mode=='bad_config':
            check('invalid_private_account_creates_no_intent_or_guest_publication',published[0]==0 and not ack.paths(directory,s)[0].exists() and result['error_type']=='AssertionError')
            return
        check(mode+'_one_guest_publication_no_retry',published[0]==1)
        check(mode+'_original_owner_guards_remain_used',guards[0]>=8)
        if mode=='success':
            check('actual_control_ack_consumed_before_runtime_cleanup',result['completed'] and response_read[0] and drained[0]['observer_status']=='ack_received' and not failures and not alive[0])
            rejects('settled_role_stays_closed_until_runtime_exit',lambda:ack.require_open(directory,s))
        elif mode=='no_ack':check('pending_is_not_reported_as_ack_success',not result['completed'] and drained[0]['observer_status']=='pending')
        else:
            check(mode+'_failed_reader_diagnosis_is_safe_and_precise',result['error_type']=='AssertionError' and result['diagnostic']['phase']=='postpublication_verify' and set(result['diagnostic']['leaf'])=={'file','line','function'})
            if mode=='io_failure':check('real_adb_rc_preserved_over_finally_cleanup',result['diagnostic']['rc']==24 and drained[0]['observer_status']=='reader_failed')
            else:check('original_emulator_teardown_race_reproduced_without_guard_relaxation',result['diagnostic']['rc'] is None and not result['automatic_retry'])

for mode in ('success','no_ack','io_failure','old_race','bad_config'):controller_case(mode)

# Execute the actual newly inserted runtime-finally prefix, without importing the runtime.
runtime_tree=ast.parse((HERE/'runtime.py').read_text())
run_node=next(n for n in runtime_tree.body if isinstance(n,ast.FunctionDef) and n.name=='run')
outer=next(n for n in run_node.body if isinstance(n,ast.Try) and n.finalbody)
cleanup_index=next(i for i,n in enumerate(outer.finalbody) if isinstance(n,ast.For))
prefix=outer.finalbody[:cleanup_index]
check('real_finally_drains_before_original_child_cleanup',cleanup_index==4
    and any(isinstance(n,ast.Call) and isinstance(n.func,ast.Attribute) and n.func.attr=='drain' for statement in prefix for n in ast.walk(statement)))
with tempfile.TemporaryDirectory(prefix='actual-runtime-finally-') as temporary:
    directory=Path(temporary);s=session();t=ack.begin(directory,s,'5'*32,time.monotonic())
    ack.settle(t,'ack_received','response_validated');reports=[]
    env={'stop_ack':ack,'settings':{'state':directory},'session':s,'normal_instrumentation_end':True,
        'output':directory,'v1':SimpleNamespace(resources=lambda:None,write=lambda path,value:reports.append(value))}
    exec(compile(ast.Module(body=prefix,type_ignores=[]),'<actual-runtime-finally-prefix>','exec'),env)
    check('normal_runtime_finally_accepts_real_settled_ack',reports[-1]['observer_status']=='ack_received')
    env['normal_instrumentation_end']=False
    exec(compile(ast.Module(body=prefix,type_ignores=[]),'<actual-runtime-finally-prefix>','exec'),env)
    check('signal_or_abnormal_exit_skips_drain',reports[-1]['status']=='not_normal_instrumentation_end')

# Cancellation executes the entire real finally, including the original owned cleanup.
for abort in (SystemExit(17),KeyboardInterrupt()):
    with tempfile.TemporaryDirectory(prefix='actual-finally-abort-') as temporary:
        directory=Path(temporary);s=session();s.update(adb_sha256='b'*64,state='running',ready=True)
        ack.begin(directory,s,'6'*32,time.monotonic());events=[];reports={}
        class Child:
            returncode=None
            def poll(self):return self.returncode
            def wait(self,timeout):self.returncode=0;return 0
        children=[Child(),Child(),Child()]
        def stop_owned(child):child.returncode=0;events.append('owned_stop')
        def command(argv,timeout):
            events.append('sync' if 'sync' in argv else 'emulator_console_stop')
            return b'OK'
        def observe():raise abort
        v1=SimpleNamespace(resources=observe,write=lambda path,value:reports.update({Path(path).name:copy.deepcopy(value)}),
            stop_owned=stop_owned,cleanup_adb_residuals=lambda *args:{'clean':True},process_cgroup=lambda pid:'owned',
            verify_inputs=lambda:{'unchanged':True},SETUP_REVISION='test')
        env={'normal_instrumentation_end':True,'stop_ack':ack,'settings':{'state':directory,'adb_port':5038},
            'session':s,'output':directory,'v1':v1,'children':children,'RUN':s['run_id'],'role':'nora',
            'adb':['fake-adb'],'command':command,'subprocess':SimpleNamespace(SubprocessError=RuntimeError),
            'handles':[],'os':os,'proof':{'inputs_sha256':{'unchanged':True}},
            'verify_install_apks':lambda:events.append('verify_apks'),'lock':SimpleNamespace(close=lambda:events.append('lock_closed'))}
        try:exec(compile(ast.Module(body=outer.finalbody,type_ignores=[]),'<actual-entire-runtime-finally>','exec'),env)
        except BaseException as error:caught=error
        else:raise AssertionError('drain abort was swallowed')
        name=type(abort).__name__
        check(name+'_drain_abort_runs_original_owned_cleanup_before_rethrow',caught is abort and
            all(child.poll()==0 for child in children) and events[-1]=='lock_closed' and
            'sync' in events and 'emulator_console_stop' in events and reports['live-session.json']['state']=='stopped'
            and not reports['live-session.json']['ready'] and reports['stop-ack-drain.json']['status']=='drain_aborted')

# The exact helper loader also works for an outer spec import with no HERE in sys.path.
def stop_loader_node(node):
    names={n.id for n in ast.walk(node) if isinstance(n,ast.Name)}
    return bool(names&{'_stop_ack_path','_stop_ack_spec'})
loader=[n for n in runtime_tree.body if stop_loader_node(n) and not isinstance(n,(ast.FunctionDef,ast.ClassDef))]
check('helper_absolute_loader_after_HERE_and_bytecode_guard',len(loader)==5 and
    not any(isinstance(n,ast.Import) and any(a.name=='stop_ack' for a in n.names) for n in runtime_tree.body) and
    next(i for i,n in enumerate(runtime_tree.body) if n is loader[0])>
    next(i for i,n in enumerate(runtime_tree.body) if isinstance(n,ast.Assign) and any(isinstance(t,ast.Attribute) and t.attr=='dont_write_bytecode' for t in n.targets)))
env={'HERE':HERE,'hashlib':hashlib}
original_path=list(sys.path)
try:
    sys.path[:]=[path for path in sys.path if path!=str(HERE)]
    exec(compile(ast.Module(body=loader,type_ignores=[]),'<actual-absolute-helper-loader>','exec'),env)
finally:sys.path[:]=original_path
check('absolute_loader_works_without_source_directory_on_sys_path',Path(env['stop_ack'].__file__)==HERE/'stop_ack.py'
    and env['stop_ack'].LIMIT==55 and not (HERE/'__pycache__').exists())

gpu=HERE.parent/'host-gpu-a18v-source'
parent=ast.parse((gpu/'runtime.py').read_text())
trim=lambda tree:[ast.dump(n,include_attributes=False) for n in tree.body
    if not stop_loader_node(n)
    and not (isinstance(n,ast.FunctionDef) and n.name in ('run','frozen_files'))]
check('all_other_runtime_guards_and_host_gpu_functions_AST_unchanged',trim(parent)==trim(runtime_tree))
baseline_run=next(n for n in parent.body if isinstance(n,ast.FunctionDef) and n.name=='run')
stripped_run=copy.deepcopy(run_node)
stripped_run.body=[n for n in stripped_run.body if not (isinstance(n,ast.Assign) and
    any(isinstance(t,ast.Name) and t.id=='normal_instrumentation_end' for t in n.targets))]
stripped_outer=next(n for n in stripped_run.body if isinstance(n,ast.Try) and n.finalbody)
stripped_outer.body=[n for n in stripped_outer.body if not (isinstance(n,ast.Assign) and
    any(isinstance(t,ast.Name) and t.id=='normal_instrumentation_end' for t in n.targets))]
stripped_outer.finalbody=stripped_outer.finalbody[cleanup_index:-1]
check('original_run_body_GPU_checks_and_cleanup_AST_unchanged',ast.dump(stripped_run,include_attributes=False)==ast.dump(baseline_run,include_attributes=False))
old_control=ast.parse((gpu/'control.py').read_text())
for name in ('validate','reject_private','normalize','redact','arguments'):
    original=next(n for n in old_control.body if isinstance(n,ast.FunctionDef) and n.name==name)
    updated=next(n for n in source.body if isinstance(n,ast.FunctionDef) and n.name==name)
    check(name+'_control_security_function_AST_unchanged',ast.dump(original,include_attributes=False)==ast.dump(updated,include_attributes=False))
for name in ('recorder.py','scenario.py','monitor.py','process_lifecycle.py','host_gpu.py'):
    check(name+'_byte_identical_to_reviewed_GPU_parent',(HERE/name).read_bytes()==(gpu/name).read_bytes())
freeze=json.loads((HERE/'freeze.json').read_text());parent_freeze=json.loads((gpu/'freeze.json').read_text())
names=('runtime.py','control.py','recorder.py','scenario.py','monitor.py','process_lifecycle.py','host_gpu.py','stop_ack.py')
check('freeze_exactly_pins_all_eight_operational_sources',freeze['files_sha256']=={
    name:hashlib.sha256((HERE/name).read_bytes()).hexdigest() for name in names})
check('actual_product_media_external_sources_and_original_leases_not_relabelled',
    all(freeze[key]==parent_freeze[key] for key in parent_freeze if key!='files_sha256') and
    freeze['parent_host_gpu_freeze_sha256']==hashlib.sha256((gpu/'freeze.json').read_bytes()).hexdigest())
for path in HERE.glob('*.py'):ast.parse(path.read_text())
check('all_source_python_AST_syntax_valid',True)
print(json.dumps({'result':'PASS','checks_count':len(checks),'checks':checks,
    'actual_helper_and_controller_AST_executed':True,'runtime_imported':False,
    'ADB_Guest_Server_Build_Product_actions':False},indent=2))

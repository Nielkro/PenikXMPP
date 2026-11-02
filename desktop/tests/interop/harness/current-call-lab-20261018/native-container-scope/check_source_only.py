"""Exercise only the actual absence-loop AST with fake Docker responses."""
import ast
import json
from pathlib import Path
import subprocess
from types import SimpleNamespace

HERE=Path(__file__).resolve().parent
BASE=HERE.parent/'runtime-source/recreate_stopped_native_peers.py'
FIX=HERE/'recreate_stopped_native_peers_container_scope.py'


def absence_loop(path):
    main=next(n for n in ast.parse(path.read_text()).body if isinstance(n,ast.FunctionDef)and n.name=='main')
    roles=next(n for n in main.body if isinstance(n,ast.For)and ast.unparse(n.iter)=='s.TEMPLATE.items()')
    return roles.body[0]


def exercise(path,mode):
    calls=[]
    def run(argv,**kwargs):
        calls.append(argv);target=argv[-1]
        if mode=='existing':return subprocess.CompletedProcess(argv,0,'[{"Id":"existing_container"}]','')
        if mode=='daemon':return subprocess.CompletedProcess(argv,1,'[]\n','Cannot connect to Docker daemon')
        if mode=='bad_stdout':return subprocess.CompletedProcess(argv,1,'not-json','Error response from daemon: No such container: '+target+'\n')
        if mode=='wrong_target':return subprocess.CompletedProcess(argv,1,'[]\n','Error response from daemon: No such container: foreign\n')
        if argv[-3:-1]==['container','inspect']:return subprocess.CompletedProcess(argv,1,'[]\n','Error response from daemon: No such container: '+target+'\n')
        if target.startswith('dinox-'):return subprocess.CompletedProcess(argv,0,'[{"Name":"retained_profile_volume"}]','')
        return subprocess.CompletedProcess(argv,1,'[]\n','error: no such object: '+target+'\n')
    env={'s':SimpleNamespace(DOCKER=['docker','exec','-i','docker_dind','docker']),
         'subprocess':SimpleNamespace(run=run),'json':json}
    for role in ('leon','felix'):
        env.update(role=role,row={'historical_absent_id':('a'if role=='leon'else'b')*64})
        exec(compile(ast.Module(body=[absence_loop(path)],type_ignores=[]),'<actual-absence-loop-only>','exec'),env)
    return calls


def main():
    try:exercise(BASE,'absent')
    except AssertionError:pass
    else:raise AssertionError('Original volume collision not reproduced')
    calls=exercise(FIX,'absent');assert len(calls)==4 and all(c[-3:-1]==['container','inspect']for c in calls)
    for mode in ('existing','daemon','bad_stdout','wrong_target'):
        try:exercise(FIX,mode)
        except (AssertionError,json.JSONDecodeError):pass
        else:raise AssertionError('Invalid response accepted: '+mode)
    text=FIX.read_text()
    assert "s.save('actual-before-first-peer-create-owned-network.json'" in text
    result={'result':'PASS_ACTUAL_ABSENCE_LOOP_AST_OFFLINE_ONLY','original_generic_inspect_profile_volume_collision_reproduced':True,
        'four_exact_container_namespace_absences_accepted':True,'existing_container_daemon_error_bad_stdout_wrong_target_rejected':True,
        'earlier_network_restore_receipt_not_overwritten':True,'no_runtime_or_create_performed_by_test':True}
    (HERE/'offline-checks.json').write_text(json.dumps(result,indent=2)+'\n');(HERE/'offline-checks.json').chmod(0o600)
    print(json.dumps(result))


if __name__=='__main__':main()

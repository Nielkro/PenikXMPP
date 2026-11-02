#!/usr/bin/env python3
"""Small source-only host-GPU delta; never import/start an operational runtime."""
import ast,difflib,hashlib,json,os
from pathlib import Path
HERE=Path(__file__).resolve().parent
BASE=HERE.parent/'mixed-video-remesh-fixed-source'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
    assert sha(BASE/'actual-source-manifest.json')=='3e7e9b69929456b0583bdd58b6e2a3671accf9c5deeee327c0f10eb7eb26bf30'
    manifest=json.loads((BASE/'actual-source-manifest.json').read_text())
    for name,row in manifest['files'].items():assert sha(BASE/name)==row['sha256']
    names=('runtime.py','control.py','recorder.py','scenario.py','monitor.py','process_lifecycle.py')
    data={n:(BASE/n).read_text()for n in names}
    text=data['runtime.py'];helper_sha=sha(HERE/'host_gpu.py')
    old="def role_config(role):\n    assert role in ('nora', 'leon'), 'Only the two explicit Android owners exist'"
    new=("_host_gpu_path=HERE/'host_gpu.py'\n"
         "assert hashlib.sha256(_host_gpu_path.read_bytes()).hexdigest()=="+repr(helper_sha)+"\n"
         "_host_gpu_spec=__import__('importlib.util',fromlist=['spec_from_file_location']).spec_from_file_location('exact_A18V_host_gpu',_host_gpu_path)\n"
         "host_gpu=__import__('importlib.util',fromlist=['module_from_spec']).module_from_spec(_host_gpu_spec);_host_gpu_spec.loader.exec_module(host_gpu)\n\n"+old)
    assert text.count(old)==1;text=text.replace(old,new)
    old="    env = environment(role)\n    children = []"
    new="    env = environment(role)\n    env.update(host_gpu.display_environment()['forwarded_environment'])\n    children = []"
    assert text.count(old)==1;text=text.replace(old,new)
    assert text.count("'-gpu', 'swiftshader'")==1;text=text.replace("'-gpu', 'swiftshader'","'-gpu', 'host'")
    old="        for name, path in APK_PATHS.items():"
    new="        host_gpu.verify(session,v1,ROOT,settings,output)\n        v1.write(settings['state']/'live-session.json',session)\n"+old
    assert text.count(old)==1;text=text.replace(old,new)
    old="            sample = v1.resources()\n            assert time.time()<proof['batch_deadline_unix']"
    new="            sample = v1.resources()\n            sample['host_gpu_device_access']=host_gpu.access(session,v1,ROOT)\n            assert time.time()<proof['batch_deadline_unix']"
    assert text.count(old)==1;text=text.replace(old,new)
    old="names = ('runtime.py', 'control.py', 'recorder.py', 'scenario.py', 'monitor.py', 'process_lifecycle.py')"
    assert text.count(old)==1;text=text.replace(old,old[:-1]+", 'host_gpu.py')")
    old="    session=read(settings['state']/'live-session.json')\n    assert time.time()<session['batch_deadline_unix']"
    new="    session=read(settings['state']/'live-session.json')\n    assert session.get('host_gpu_verified') is True and session.get('gpu_mode')=='host'\n    assert time.time()<session['batch_deadline_unix']"
    assert text.count(old)==1;text=text.replace(old,new)
    data['runtime.py']=text
    text=data['monitor.py'];old="'events':{x.split()[0]:int(x.split()[1]) for x in(cg/'memory.events').read_text().splitlines()}"
    new=old+",'cpu_stat':{x.split()[0]:int(x.split()[1])for x in(cg/'cpu.stat').read_text().splitlines()}"
    assert text.count(old)==1;text=text.replace(old,new)
    old="'events_last':samples[-1]['events'],'nora_observed_running'"
    new="'events_last':samples[-1]['events'],'cpu_stat_first':samples[0]['cpu_stat'],'cpu_stat_last':samples[-1]['cpu_stat'],'cpu_stat_delta':{k:samples[-1]['cpu_stat'][k]-v for k,v in samples[0]['cpu_stat'].items()},'nora_observed_running'"
    assert text.count(old)==1;text=text.replace(old,new);data['monitor.py']=text
    for name,text in data.items():ast.parse(text,filename=name)
    freeze=json.loads((BASE/'freeze.json').read_text());freeze['files_sha256']={n:hashlib.sha256(t.encode()).hexdigest()for n,t in data.items()};freeze['files_sha256']['host_gpu.py']=helper_sha
    # The same package/source, case, caps, identity and hard lifetime contracts remain.
    diff=''.join(''.join(difflib.unified_diff((BASE/n).read_text().splitlines(keepends=True),t.splitlines(keepends=True),fromfile=str(BASE/n),tofile=str(HERE/n)))for n,t in data.items())
    for name,text in {**data,'freeze.json':json.dumps(freeze,indent=2)+'\n','derivation.diff':diff}.items():
        fd=os.open(HERE/name,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
        with os.fdopen(fd,'w')as stream:stream.write(text)
    sources={n:{'sha256':sha(HERE/n),'bytes':(HERE/n).stat().st_size}for n in [*names,'host_gpu.py','freeze.json','derivation.diff','derive.py']}
    result={'scope':'SOURCE_ONLY_A18V2048_HOST_GPU_SAME_PRODUCT_CAPS_CASE_LIFETIMES','parent_manifest_sha256':sha(BASE/'actual-source-manifest.json'),'parent_freeze_sha256':sha(BASE/'freeze.json'),'files':sources,'freeze_sha256':sha(HERE/'freeze.json'),'no_runtime_or_new_admission':True,'probe_sha256':'30302b9f69432122545a388b7947faf9774cf5e6988950f2624dc111edce5f6f'}
    (HERE/'source-manifest.json').write_text(json.dumps(result,indent=2)+'\n');(HERE/'source-manifest.json').chmod(0o600)
    print(json.dumps({'manifest_sha256':sha(HERE/'source-manifest.json'),'freeze_sha256':sha(HERE/'freeze.json'),'runtime_started':False}))
if __name__=='__main__':main()

#!/usr/bin/env python3
"""Actual function/Fakeproc checks only. No operational runtime import or SDK."""
import ast,copy,hashlib,importlib.util,json,os,stat,tempfile
from pathlib import Path
from types import SimpleNamespace as NS
from unittest.mock import patch
HERE=Path(__file__).resolve().parent;BASE=HERE.parent/'mixed-video-remesh-fixed-source'
def load(name,path):
    s=importlib.util.spec_from_file_location(name,path);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);return m
def function(text,name):return [n for n in ast.parse(text).body if isinstance(n,ast.FunctionDef)and n.name==name][-1]
positive=negative=0
def yes(fn):
    global positive
    fn();positive+=1
def no(fn):
    global negative
    try:fn()
    except (AssertionError,FileNotFoundError,PermissionError):negative+=1;return
    raise AssertionError('Expected refusal')
def main():
    global positive,negative
    g=load('actual_new_host_gpu_helper',HERE/'host_gpu.py');p=g.probe()
    old=(BASE/'runtime.py').read_text();new=(HERE/'runtime.py').read_text()
    scope={'ROOT':Path('/fixture'),'role_config':lambda role:{'avd':'retained_nora','emulator_port':5580}}
    commands=[]
    for text in [old,new]:
        local=dict(scope);exec(compile(ast.Module(body=[function(text,'emulator_command')],type_ignores=[]),'<actual-emulator-command>','exec'),local)
        commands.append(local['emulator_command']('nora',2048,True))
    a,b=commands;i=a.index('-gpu')+1;assert a[i]=='swiftshader'and b[i]=='host'
    b[i]='swiftshader';assert a==b and a[a.index('-memory')+1]=='2048'and '-lowram'in a;positive+=1
    # Every other function remains exactly the accepted function AST.
    allowed={'run','emulator_command','frozen_files','control_settings'}
    for name in set(n.name for n in ast.parse(old).body if isinstance(n,ast.FunctionDef))-allowed:
        assert ast.dump(function(old,name))==ast.dump(function(new,name))
    for name in ['control.py','recorder.py','scenario.py','process_lifecycle.py']:
        assert (HERE/name).read_bytes()==(BASE/name).read_bytes()
    positive+=1
    # Existing pure renderer contract: both GL renderer and selected Vulkan/GLES.
    hardware='hw.gpu.mode = host\nhw.ramSize = 2048\n'
    renderer='Graphics Adapter Android Emulator OpenGL ES Translator (Intel(R) HD Graphics)\n'
    yes(lambda:p.validate_host_gpu(hardware,renderer,[{'exact_current_service_identity':True}]))
    for h,log,fd in [(hardware.replace('host','swiftshader'),renderer,[1]),(hardware+hardware,renderer,[1]),
        (hardware,renderer,[]),(hardware,renderer.replace('Intel','Other'),[1]),
        (hardware,renderer+'gles_mode_selected:swiftshader',[1]),(hardware,renderer+'Selecting Vulkan device: llvmpipe',[1]),
        (hardware,renderer+'Graphics Adapter Android Emulator OpenGL ES Translator (Google SwiftShader)',[1])]:
        no(lambda h=h,log=log,fd=fd:p.validate_host_gpu(h,log,fd))
    # Real display metadata function; cookie data must never be read.
    def display(env,*,socket_uid=0,auth_uid=None,auth_mode=0o600,readable=True):
        auth_uid=os.getuid()if auth_uid is None else auth_uid
        def meta(path):return NS(st_mode=(stat.S_IFSOCK|0o700)if str(path).endswith('/X0')else(stat.S_IFREG|auth_mode),st_uid=socket_uid if str(path).endswith('/X0')else auth_uid,st_dev=1,st_ino=2)
        with patch.object(Path,'lstat',meta),patch.object(p.os,'access',lambda *a:readable),patch.object(Path,'read_bytes',side_effect=AssertionError('Cookie read forbidden')):
            return p.validated_display_environment(env)
    env={'DISPLAY':':0','XAUTHORITY':'/home/linux/.Xauthority'}
    yes(lambda:display(env));no(lambda:display(dict(env,DISPLAY=':1')));no(lambda:display(dict(env,XAUTHORITY='/other')))
    no(lambda:display(env,socket_uid=1));no(lambda:display(env,auth_uid=os.getuid()+1));no(lambda:display(env,auth_mode=0o644));no(lambda:display(env,readable=False))
    # Exact new owner() uses real code and a fake systemd result, no systemctl.
    group='/user.slice/user-1000.slice/user@1000.service/dinoxinterop20261015.slice/dinox-a18v-hostgpu-nora-test.service'
    session={'controller_pid':101,'controller_start_ticks':'100','emulator_pid':202,'emulator_start_ticks':'200'}
    v1=NS(start_ticks=lambda pid:'100',process_cgroup=lambda pid:group,SLICE='dinoxinterop20261015.slice')
    props={'Type':'exec','MainPID':'101','ControlGroup':group,'InvocationID':'a'*32}
    def owner(fields):
        result=NS(returncode=0,stdout='\n'.join(k+'='+v for k,v in fields.items()))
        with patch.object(g.os,'getpid',lambda:101),patch.object(g.subprocess,'run',lambda *a,**kw:result):return g.owner(session,v1,Path('/fixture'))
    yes(lambda:owner(props))
    for key,value in [('Type','simple'),('MainPID','102'),('ControlGroup','/foreign'),('InvocationID','invalid')]:no(lambda key=key,value=value:owner(dict(props,**{key:value})))
    # Actual access()+qualified gpu_access()/exact_service_sdk() against fake /proc.
    with tempfile.TemporaryDirectory(prefix='a18v-gpu-pure-')as temp:
        root=Path(temp);proc=root/'proc';sdk=root/'sdk';exe=sdk/'emulator/qemu/linux-x86_64/qemu-system-x86_64-headless';exe.parent.mkdir(parents=True);exe.write_bytes(b'fake SDK inode, never executable')
        def ticks(pid,value):
            path=proc/str(pid);path.mkdir(parents=True,exist_ok=True);(path/'stat').write_text(str(pid)+' (fake) R '+' '.join(['0']*18+[str(value)]));(path/'cgroup').write_text('0::'+group+'\n')
        ticks(101,100);ticks(202,200);child=proc/'202';(child/'exe').symlink_to(exe);(child/'fd').mkdir();(child/'fdinfo').mkdir();(child/'fd/4').symlink_to('/dev/null');(child/'fdinfo/4').write_text('pos: 0\nflags: 0100002\n')
        bound={'main_pid':101,'main_start_ticks':'100','uid':os.getuid(),'cgroup':group,'crashpad_exe':str(sdk/'emulator/crashpad_handler'),'emulator_pid':202,'emulator_start_ticks':'200'}
        ss=dict(session,host_gpu_service_owner=bound)
        actualPath=Path
        def fakePath(*a):return proc.joinpath(*map(str,a[1:]))if a and a[0]=='/proc'else actualPath(*a)
        def access():
            proxy=NS(gpu_access=lambda items,own:p.gpu_access(items,own,proc_root=proc,render_node=actualPath('/dev/null')))
            with patch.object(g,'Path',fakePath),patch.object(g,'probe',lambda:proxy):return g.access(ss,NS(start_ticks=lambda pid:(proc/str(pid)/'stat').read_text().rsplit(')',1)[1].split()[19]),root)
        yes(access)
        (child/'fd/4').unlink();no(access);(child/'fd/4').symlink_to('/dev/null')
        ticks(202,201);no(access);ticks(202,200)
        (child/'cgroup').write_text('0::/foreign\n');no(access);(child/'cgroup').write_text('0::'+group+'\n')
        ticks(101,101);no(access);ticks(101,100)
        bound['uid']=os.getuid()+1;no(access);bound['uid']=os.getuid()
    print(json.dumps({'result':'ACTUAL_PURE_HOST_GPU_SOURCE_CHECKS_PASS_NO_RUNTIME','positive':positive,'negative':negative,'operational_runtime_imports':0,'sdk_processes_started':0}))
if __name__=='__main__':main()

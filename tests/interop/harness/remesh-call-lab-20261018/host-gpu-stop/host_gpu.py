"""Existing host-GPU proof contract, bound to this exact Nora service/child."""
import hashlib,importlib.util,os,re,stat,subprocess
from pathlib import Path
PROBE=Path('/media/linux/SSD128/xmppwin/local/monocles-dinox-interop-20261015/harness/triple_v3/gpu_probe/probe.py')
PROBE_SHA='30302b9f69432122545a388b7947faf9774cf5e6988950f2624dc111edce5f6f'
def probe():
    assert hashlib.sha256(PROBE.read_bytes()).hexdigest()==PROBE_SHA
    spec=importlib.util.spec_from_file_location('qualified_pure_host_gpu_contract',PROBE)
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    return module
def display_environment():
    return probe().validated_display_environment()
def owner(session,v1,root):
    pid=session['controller_pid'];assert pid==os.getpid()
    assert v1.start_ticks(pid)==session['controller_start_ticks']
    group=v1.process_cgroup(pid);unit=Path(group).name
    assert Path(group).parent.name==v1.SLICE
    assert unit.startswith('dinox-a18v-hostgpu-nora-') and unit.endswith('.service')
    result=subprocess.run(['systemctl','--user','show',unit,'-p','MainPID','-p','Type','-p','ControlGroup','-p','InvocationID'],capture_output=True,text=True,timeout=5)
    assert result.returncode==0
    actual=dict(line.split('=',1)for line in result.stdout.splitlines())
    assert actual['Type']=='exec' and actual['MainPID']==str(pid) and actual['ControlGroup']==group
    assert re.fullmatch('[0-9a-f]{32}',actual['InvocationID'])
    return {'main_pid':pid,'main_start_ticks':session['controller_start_ticks'],'uid':os.getuid(),
        'cgroup':group,'systemd_service':actual,'crashpad_exe':str(root/'sdk/emulator/crashpad_handler'),
        'emulator_pid':session['emulator_pid'],'emulator_start_ticks':session['emulator_start_ticks']}
def access(session,v1,root):
    bound=session['host_gpu_service_owner'];pid=session['emulator_pid']
    assert bound['emulator_pid']==pid and bound['emulator_start_ticks']==session['emulator_start_ticks']
    assert bound['main_pid']==session['controller_pid'] and bound['main_start_ticks']==session['controller_start_ticks']
    assert v1.start_ticks(pid)==session['emulator_start_ticks']
    proc=Path('/proc',str(pid));exe=(proc/'exe').resolve(strict=True)
    assert exe.is_relative_to(root/'sdk')
    item={'pid':pid,'start_ticks':session['emulator_start_ticks'],'exe':str(exe)}
    found=probe().gpu_access([item],bound)
    assert found,'Current exact Nora SDK child lost its renderD128 descriptor'
    return found
def verify(session,v1,root,settings,output):
    # This reads existing display metadata, never Xauthority cookie contents.
    display=display_environment();session['host_gpu_service_owner']=owner(session,v1,root)
    hardware=(settings['avd_home']/(settings['avd']+'.avd')/'hardware-qemu.ini').read_text()
    evidence=probe().validate_host_gpu(hardware,(output/'emulator.log').read_text(errors='replace'),access(session,v1,root))
    evidence.update(display=display,actual_emulator_cmdline_sha256=hashlib.sha256(Path('/proc',str(session['emulator_pid']),'cmdline').read_bytes()).hexdigest())
    saved=output/'generated-hardware-qemu.ini';saved.write_text(hardware);saved.chmod(0o600)
    v1.write(output/'actual-host-gpu-provenance.json',evidence)
    session.update(gpu_mode='host',host_gpu_verified=True)
    return evidence

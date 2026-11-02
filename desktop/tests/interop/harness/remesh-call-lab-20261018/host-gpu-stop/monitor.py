#!/usr/bin/env python3
"""Bounded shared resources and continuous private logs for the existing role lifecycles."""
import sys,json,time,signal,datetime,subprocess,resource
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parent))
import runtime as r,recorder as rec
out=r.STATE/('devicefix-Nora-Legacy3-'+datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ'));out.mkdir(mode=0o700);r.v1.write(r.STATE/'current-devicefix-nora-probe.json',{'path':str(out),'run_id':r.RUN});r.v1.write(out/'recording.json',rec.record({'action':'begin','label':'A18V one current mixed three-party VIDEO case; no text/audio/UI/PQ repeats'}));print('DEVICEFIX_NORA_OUTPUT',out,flush=True)
cg=Path(r.v1.resources()['cgroup']);samples=[];deadline=time.monotonic()+3000;seen=set();loggers={};handles=[]
def stop(*a):raise SystemExit()
signal.signal(signal.SIGTERM,stop);signal.signal(signal.SIGINT,stop)
f=(out/'shared-resources.jsonl').open('x');(out/'shared-resources.jsonl').chmod(0o600)
try:
 while time.monotonic()<deadline:
  m={x.split()[0]:int(x.split()[1]) for x in(cg/'memory.stat').read_text().splitlines()};host=next(int(x.split()[1])*1024 for x in Path('/proc/meminfo').read_text().splitlines() if x.startswith('MemAvailable:'));s={'time_ns':time.time_ns(),'anon':m['anon'],'kernel':m['kernel'],'file':m['file'],'current':int((cg/'memory.current').read_text()),'host_available':host,'swap':int((cg/'memory.swap.current').read_text()),'events':{x.split()[0]:int(x.split()[1]) for x in(cg/'memory.events').read_text().splitlines()},'cpu_stat':{x.split()[0]:int(x.split()[1])for x in(cg/'cpu.stat').read_text().splitlines()}};samples.append(s);f.write(json.dumps(s)+'\n');f.flush();roles={}
  for role in ['nora']:
   p=r.role_config(role)['state']/'live-session.json'
   if not p.exists():continue
   z=r.read(p);roles[role]=z
   if z['state']=='running':seen.add(role)
   if z['state']=='running'and z.get('emulator_pid')and role not in loggers:
    r.v1.require_adb_ready(z['adb_pid'],z['adb_start_ticks'],r.role_config(role)['adb_port'],z['adb_sha256'],z['adb_cgroup'])
    probe=subprocess.run(r.adb_command(role)+['get-state'],capture_output=True,timeout=3)
    if probe.returncode==0 and probe.stdout.strip()==b'device':
     path=out/(role+'-continuous-boot-devicefix-system-app.log');h=path.open('xb');path.chmod(0o600);handles.append(h)
     def cap():resource.setrlimit(resource.RLIMIT_FSIZE,(64*1024**2,64*1024**2))
     child=subprocess.Popen(r.adb_command(role)+['logcat','-b','all','-v','epoch','*:D'],stdin=subprocess.DEVNULL,stdout=h,stderr=subprocess.STDOUT,start_new_session=True,preexec_fn=cap);loggers[role]=(child,path);print('CONTINUOUS_OWN_LOG_STARTED',role,str(path),flush=True)
  if seen=={'nora'}and all(roles.get(role,{}).get('state')=='stopped' for role in ['nora']):break
  if(out/'finish-resource-monitor.json').exists():break
  time.sleep(1)
finally:
 f.close()
 for role,(child,path)in loggers.items():r.v1.stop_owned(child);r.v1.write(out/(role+'-continuous-log-receipt.json'),{'path':str(path),'sha256':r.sha(path),'started_from_first_adb_device_readiness':True})
 for h in handles:h.close()
 if samples:r.v1.write(out/'shared-resource-peaks.json',{'count':len(samples),'peak_anon':max(x['anon']for x in samples),'peak_kernel':max(x['kernel']for x in samples),'peak_anon_plus_kernel':max(x['anon']+x['kernel']for x in samples),'peak_current':max(x['current']for x in samples),'min_host_available':min(x['host_available']for x in samples),'peak_swap':max(x['swap']for x in samples),'events_initial':samples[0]['events'],'events_last':samples[-1]['events'],'cpu_stat_first':samples[0]['cpu_stat'],'cpu_stat_last':samples[-1]['cpu_stat'],'cpu_stat_delta':{k:samples[-1]['cpu_stat'][k]-v for k,v in samples[0]['cpu_stat'].items()},'nora_observed_running':seen=={'nora'}})
 print('DEVICEFIX_NORA_MONITOR_FINISHED',out,flush=True)

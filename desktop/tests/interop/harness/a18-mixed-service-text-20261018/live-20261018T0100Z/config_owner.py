"""A18 exact-owner app-private room config only; no UI, message or trust action."""
import argparse, hashlib, importlib.util, json, os, signal, subprocess, sys, time, uuid
from pathlib import Path
sys.dont_write_bytecode=True
if sys.flags.optimize:raise RuntimeError('Required guards need unoptimized Python')
HERE=Path(__file__).resolve().parent;A=HERE.parent
sys.path.insert(0,str(A));import runtime as r
FREEZE='73c64b7aba80ff49c83e3425cb20b37fcc33d562aa96b7751e4973ea4ff91c04'
ROOM='interop-three-71115b-8df83d69736d9417@conference.dinox.im'
B=r.HARNESS/'triple_v3/runtime_consent'
assert hashlib.sha256((B/'runtime.py').read_bytes()).hexdigest()=='5cd87d8c758f623c4e85a0874e00c5243ce5819a4eb3604bba0ffea6cb3de01c'
sys.path.insert(0,str(B))
spec=importlib.util.spec_from_file_location('reviewed_shared_inventory_lock',B/'runtime.py')
shared=importlib.util.module_from_spec(spec);spec.loader.exec_module(shared)
sha=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()

def session_now(a):
 assert a['operation']=='A18-app-private-room-config-only' and a['source_sha256']==sha(__file__)
 assert a['action']in('append','restore') and a['run_id']==r.RUN and a['role']=='nora' and a['account']==r.OWN['nora']
 assert a['room']==ROOM and a['runtime_freeze_sha256']==r.frozen_files()==FREEZE
 now=time.time();assert 0<=now-a['created_unix']<=120 and now<a['expires_unix']<=a['created_unix']+180
 assert os.getpriority(os.PRIO_PROCESS,0)==19;r.v1.resources()
 cfg=r.role_config('nora');s=r.read(cfg['state']/'live-session.json')
 assert s['state']=='running' and s['ready']is True and s['run_id']==r.RUN and s['role']=='nora'
 assert s['batch_id']==a['batch_id'] and s['freeze_sha256']==FREEZE and s['apk_sha256']==r.APKS
 assert s['inputs_sha256']==r.sha(r.ROOT/'runtime-inputs.json')
 assert time.time()<s['batch_deadline_unix']
 keys={'controller_pid','controller_start_ticks','adb_pid','adb_start_ticks','emulator_pid','emulator_start_ticks','adb_cgroup','approval_sha256'}
 assert set(a['session_binding'])==keys and {key:s[key]for key in keys}==a['session_binding']
 assert set(a['process_cgroups'])=={'controller','adb','emulator'}
 for role in('controller','adb','emulator'):
  assert r.v1.start_ticks(s[role+'_pid'])==s[role+'_start_ticks']
  assert r.v1.process_cgroup(s[role+'_pid'])==a['process_cgroups'][role]
  assert r.v1.SLICE in Path(a['process_cgroups'][role]).parts
 assert s['adb_cgroup']==a['process_cgroups']['adb'] and s['adb_sha256']==r.sha(r.ROOT/'sdk/platform-tools/adb')
 assert s['native_readonly_bindings']==a['native_bindings']
 return cfg,s

def sdk(a, mode, data=None):
 assert mode in('read','write') and (data is not None)==(mode=='write')
 cfg,s=session_now(a);child=None;begin=None;result={'mode':mode,'automatic_retry':False}
 tail=['shell','-T','run-as',r.v1.PACKAGE]+(['cat','files/interop/config.json']if mode=='read'else['dd','of=files/interop/config.json'])
 try:
  with shared.inventory_lock():
   begin=time.monotonic();session_now(a)
   r.v1.require_adb_ready(s['adb_pid'],s['adb_start_ticks'],cfg['adb_port'],s['adb_sha256'],s['adb_cgroup'])
   child=subprocess.Popen([*r.adb_command('nora'),*tail],env=r.environment('nora'),
     stdin=subprocess.PIPE if data is not None else subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
   ticks=None
   try:
    ticks=r.v1.start_ticks(child.pid)
    assert r.v1.process_cgroup(child.pid)==r.v1.process_cgroup(os.getpid())
    output,error=child.communicate(input=data,timeout=max(.01,3.8-(time.monotonic()-begin)))
    assert child.returncode==0,'Exact owned config I/O failed; no retry'
    assert len(output)<=32768 and len(error)<=32768
    return output
   finally:
    if child.poll()is None:
     if ticks is not None:assert r.v1.start_ticks(child.pid)==ticks
     child.terminate()
     try:child.wait(timeout=.12)
     except subprocess.TimeoutExpired:
      if ticks is not None:assert r.v1.start_ticks(child.pid)==ticks
      child.kill();child.wait(timeout=.2)
    assert child.poll()is not None and time.monotonic()-begin<5
 finally:
  result.update(child_pid=child.pid if child else None,exit=child.poll()if child else None,
   child_dead_before_unlock=child is not None and child.poll()is not None,
   lock_elapsed_seconds=time.monotonic()-begin if begin else None)
  r.v1.write(HERE/('config-'+a['action']+'-sdk-'+uuid.uuid4().hex+'.json'),result)

def main():
 p=argparse.ArgumentParser();p.add_argument('--admission',type=Path,required=True);args=p.parse_args()
 path=args.admission;assert path.is_file()and not path.is_symlink()and path.stat().st_mode&0o077==0
 a=r.read(path);session_now(a)
 # The two real config transitions are one-shot per batch/action.
 claim=HERE/('config-'+a['batch_id']+'-'+a['action']+'.claim')
 fd=os.open(claim,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
 with os.fdopen(fd,'w')as stream:stream.write(sha(path)+'\n');stream.flush();os.fsync(stream.fileno())
 raw=sdk(a,'read');current=json.loads(raw)
 host=r.read(r.role_config('nora')['config']);r.validate_private_config('nora',host)
 assert current.get('allowed_rooms',[])in([],[ROOM])
 without=dict(current);without['allowed_rooms']=[]
 expected=dict(host);expected['allowed_rooms']=[]
 assert without==expected,'Unexpected non-room private config difference'
 if a['action']=='append':assert current.get('allowed_rooms',[])==[]
 desired=dict(current);desired['allowed_rooms']=[ROOM]if a['action']=='append'else[]
 body=json.dumps(desired,ensure_ascii=False).encode()
 write_may_have_happened=False
 if current!=desired:
  write_may_have_happened=True;sdk(a,'write',body)
 else:body=raw
 actual=sdk(a,'read');assert actual==body,'Actual app-private config readback differs; no retry'
 cfg,s=session_now(a)
 receipt={'run_id':r.RUN,'account':r.OWN['nora'],'allowed_rooms':desired['allowed_rooms'],
  'session_binding':a['session_binding'],'validated_write_readback_equal':True,'observed_unix':time.time(),
  'config_helper_sha256':sha(__file__),'config_admission_sha256':sha(path),'action':a['action'],
  'write_may_have_happened':write_may_have_happened,'only_allowed_rooms_changed':True,'automatic_retry':False}
 target=r.ROOT/('A18-actual-config-'+a['action']+'-'+uuid.uuid4().hex+'.json');r.v1.write(target,receipt)
 r.v1.write(HERE/('actual-'+a['action']+'-room-config-result.json'),{'result':'PASS','receipt':{'path':str(target),'sha256':sha(target)},**receipt})
 print(json.dumps({'result':'PASS','action':a['action'],'receipt_path':str(target),'receipt_sha256':sha(target),'no_secrets_exported':True}))
if __name__=='__main__':
 def terminate(signum,frame):
  signal.signal(signal.SIGTERM,signal.SIG_IGN);signal.signal(signal.SIGINT,signal.SIG_IGN)
  raise SystemExit('Exact A18 config owner interrupted; retain one-shot claim')
 signal.signal(signal.SIGTERM,terminate);signal.signal(signal.SIGINT,terminate)
 main()

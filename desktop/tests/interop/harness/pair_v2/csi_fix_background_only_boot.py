#!/usr/bin/env python3
"""One approved Nora lowram boot: retained tested APKs -> stable Home -> background MUJI only -> cleanup."""
from pathlib import Path
import json,sys,time,uuid,subprocess,threading,os,resource,traceback,datetime,signal,re,xml.etree.ElementTree as ET
import runtime as r,recorder as rec
import scenario_recorder as native_rec
v=r.v1;out=r.STATE/('csi-fix-background-only-'+time.strftime('%Y%m%dT%H%M%SZ',time.gmtime())+'-'+uuid.uuid4().hex);out.mkdir(mode=0o700)
print('CSI_FIX_ONE_BOOT_OUTPUT',str(out),flush=True)
assert hasattr(r,'CSI_PRODUCT_PROOF'),'The verified CSI product derivation has not been installed in the private harness'
assert r.APKS['main.apk']!='ffd803a9663a9fb7cd93f983763a0ce557850f93d5b64d1c108bb7fededf41d5'
def terminate(signum,frame):raise SystemExit('Owned single-boot batch interrupted')
signal.signal(signal.SIGTERM,terminate);signal.signal(signal.SIGINT,terminate)
runner=None;recording=None;native_recording=None;logger=None;log_handle=None;system_logger=None;system_handle=None;system_ui_wait_used=False;stop_sent=False;ui_end_attempts=set();native_end_attempts=set();phase='prestart';samples=[];done=threading.Event()
cg=Path('/sys/fs/cgroup'+Path('/proc/self/cgroup').read_text().strip().split('::',1)[1]);assert v.SLICE in cg.parts

def monitor():
 p=out/'resources.jsonl'
 with p.open('x') as f:
  p.chmod(0o600)
  while not done.is_set():
   s={x.split()[0]:int(x.split()[1]) for x in (cg/'memory.stat').read_text().splitlines()};host=next(int(x.split()[1])*1024 for x in Path('/proc/meminfo').read_text().splitlines() if x.startswith('MemAvailable:'))
   d={'time_ns':time.time_ns(),'phase':phase,'anon':s['anon'],'kernel':s['kernel'],'file':s['file'],'current':int((cg/'memory.current').read_text()),'swap':int((cg/'memory.swap.current').read_text()),'host_available':host,'events':{x.split()[0]:int(x.split()[1]) for x in (cg/'memory.events').read_text().splitlines()}};samples.append(d);f.write(json.dumps(d)+'\n');f.flush();done.wait(1)
thread=threading.Thread(target=monitor,daemon=True);thread.start();adb=r.adb_command('nora')

def op(role,tag,payload=None):
 global stop_sent
 v.resources()
 if role=='nora' and payload and payload.get('op')=='stop':assert not stop_sent;stop_sent=True
 q={'action':'command' if payload else 'state','role':role,'wait':30 if payload else 0,'tag':tag,'transport':'local-android' if role=='nora' else 'server'}
 if payload:q.update(id=uuid.uuid4().hex,payload=payload)
 if role=='nora':
  q['recording']=recording['recording'];x=rec.record(q);s=x['observation'];assert s.get('completed'),x;z=s['response'];path=x['evidence']
 else:
  q.update(recording=native_recording['recording'],local_recording=True);x=native_rec.server(q);assert x['controller_exit']==0 and x['observation'].get('completed'),x;z=x['observation']['response'];path=x['evidence_file']
 assert z['run_id']==r.RUN;assert not payload or z.get('ok') is True,z
 print('OBSERVED',role,tag,path,flush=True)
 return z['result'] if role=='nora' and payload else z

def cli(args,timeout=30):
 r.control_settings('nora');p=subprocess.run(adb+args,stdin=subprocess.DEVNULL,capture_output=True,timeout=timeout);v.write(out/('adb-'+uuid.uuid4().hex+'.json'),{'arguments':args,'exit':p.returncode,'stdout':p.stdout.decode(errors='replace'),'stderr':p.stderr.decode(errors='replace')});assert p.returncode==0,(args,p.returncode);return p.stdout

def inspect_native(role):
 p=subprocess.run(['ssh','-p','2654','-o','BatchMode=yes','-o','ConnectTimeout=12','cpaneladmin@45.84.199.125','docker exec docker_dind docker inspect dinox-interop-20261015-'+role],capture_output=True,timeout=25);assert p.returncode==0
 f=out/('native-'+role+'-inspect-'+uuid.uuid4().hex+'.json');f.write_bytes(p.stdout);f.chmod(0o600);d=json.loads(p.stdout)[0];assert d['Name']=='/dinox-interop-20261015-'+role and d['Config']['Labels']['im.dinox.interop.run']==r.RUN;return d

def native_action(role,action):
 assert action in ['start','stop'];p=subprocess.run(['ssh','-p','2654','-o','BatchMode=yes','-o','ConnectTimeout=12','cpaneladmin@45.84.199.125','docker exec docker_dind docker '+action+' dinox-interop-20261015-'+role],capture_output=True,timeout=45);v.write(out/('native-'+role+'-'+action+'-'+uuid.uuid4().hex+'.json'),{'exit':p.returncode,'stdout':p.stdout.decode(),'stderr':p.stderr.decode()});assert p.returncode==0

def ensure_native(role,budget=900):
 before=inspect_native(role)
 if before['State']['Running']:
  s=op(role,'actual-idle-before-timer-check');assert not s.get('call') or s['call']['state'].endswith('ENDED')
  start=datetime.datetime.fromisoformat(before['State']['StartedAt'][:19]+'+00:00');remaining=5400-(datetime.datetime.now(datetime.timezone.utc)-start).total_seconds()
  if remaining<budget:native_action(role,'stop');native_action(role,'start')
 else:native_action(role,'start')
 after=inspect_native(role)
 assert after['Id']==before['Id'] and after['Config']==before['Config'] and after['HostConfig']==before['HostConfig'] and sorted(after['Mounts'],key=lambda x:x['Destination'])==sorted(before['Mounts'],key=lambda x:x['Destination']) and after['State']['Running']
 deadline=time.monotonic()+90
 while True:
  a=op(role,'actual-fresh-online-resource-after-start-or-timer-check')
  if a['online']:
   time.sleep(3);b=op(role,'actual-second-stable-online-resource-sample')
   if b['online'] and b['full_jid']==a['full_jid']:return b
  assert time.monotonic()<deadline;time.sleep(1)

def identity(s):
 assert s['account']==r.OWN['nora'] and s['own_device_id']==12210 and s['own_legacy_fingerprint']=='05c5d680f9afdc5ccbdc1be2770e03776e03d698fbde371c5622670ec2a1e2b844'

def inspect_guest_ui(label):
 dest='/data/local/tmp/dinox-own-ui-'+uuid.uuid4().hex+'.xml'
 cli(['shell','-T','uiautomator','dump',dest],timeout=20)
 raw=cli(['shell','-T','cat',dest]);file=out/(label+'-actual-ui.xml');file.write_bytes(raw);file.chmod(0o600)
 return ET.fromstring(raw)

def handle_exact_system_ui_anr(label):
 global system_ui_wait_used
 ui=inspect_guest_ui(label)
 title=[n for n in ui.iter('node') if n.get('resource-id')=='android:id/alertTitle' and n.get('text')=="System UI isn't responding"]
 if not title:return
 assert len(title)==1 and not system_ui_wait_used,'SystemUI ANR persists/recurs; no repeated dismissal'
 wait=[n for n in ui.iter('node') if n.get('package')=='android' and n.get('resource-id')=='android:id/aerr_wait' and n.get('text')=='Wait' and n.get('enabled')=='true' and n.get('clickable')=='true']
 assert len(wait)==1,'No exact normal SystemUI Wait action'
 coords=list(map(int,re.fullmatch(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]',wait[0].get('bounds','')).groups()))
 system_ui_wait_used=True
 v.write(out/'actual-system-ui-wait-once.json',{'title':title[0].get('text'),'resource_id':wait[0].get('resource-id'),'normal_guest_action':True,'not_product_ANR':True,'no_retry':True})
 cli(['shell','-T','input','tap',str((coords[0]+coords[2])//2),str((coords[1]+coords[3])//2)])
 time.sleep(2)
 after=inspect_guest_ui(label+'-after-normal-Wait')
 assert not any(n.get('resource-id')=='android:id/alertTitle' and n.get('text')=="System UI isn't responding" for n in after.iter('node')),'SystemUI ANR remained after one Wait'

def stable_normal_home():
 handle_exact_system_ui_anr('precase-home')
 cli(['shell','-T','input','keyevent','KEYCODE_HOME'])
 observations=[]
 for i in range(2):
  time.sleep(2);ui=inspect_guest_ui('stable-home-'+str(i+1))
  assert not any(n.get('resource-id')=='android:id/alertTitle' for n in ui.iter('node')),'Unexpected dialog blocks normal Home'
  dump=cli(['shell','-T','dumpsys','activity','activities']).decode();top=[x.strip() for x in dump.splitlines() if 'topResumedActivity' in x]
  assert top and all('com.android.launcher3/' in x for x in top),'Normal actual Launcher Home not stable'
  observations.append({'sample':i+1,'top_resumed':top})
 v.write(out/'actual-stable-normal-home-before-case.json',observations)

def ui_bind(n,sid,label,for_cleanup=False):
 handle_exact_system_ui_anr(label+'-before-ui-binding')
 allowed={'CONNECTED','CONNECTING','RECONNECTING','INCOMING_CONTENT_ADD'} if for_cleanup else {'CONNECTED'}
 c=next(x for x in n['calls'] if x['session_id']==sid and x['end_user_state'] in allowed)
 cli(['shell','-T','su','0','am','start','-W','-a','android.intent.action.VIEW','-n',v.PACKAGE+'/eu.siacs.conversations.ui.RtpSessionActivity','--es','account',n['account'],'--es','with',c['peer'],'--es','session_id',sid])
 dump=cli(['shell','-T','dumpsys','activity','activities']).decode();top=[x.strip() for x in dump.splitlines() if 'topResumedActivity' in x and v.PACKAGE in x and 'RtpSessionActivity' in x];assert top;v.write(out/(label+'-exact-normal-ui-binding.json'),{'account':n['account'],'sid':sid,'peer':c['peer'],'resumed':top});return c

def direct(peer,video,label):
 started=op('nora',label+'-start-once',{'op':'start_call','peer':peer,'video':video});sid=started['session_id'];deadline=time.monotonic()+25
 while True:
  s=op(peer,label+'-observe-actual-incoming')
  if s.get('call') and s['call']['state'].endswith('RINGING'):break
  assert time.monotonic()<deadline;time.sleep(.3)
 op(peer,label+'-accept-current-exact-call-once',{'op':'accept_call','call_id':s['call']['id']});time.sleep(8)
 n=op('nora',label+'-actual-connected-before-ui',{'op':'stats'});identity(n);ui_bind(n,sid,label);return sid

def media(peer,sid,video,label):
 values=[]
 for idx in [1,2]:
  if idx==2:time.sleep(4)
  values.append({role:op(role,label+'-real-media-sample'+str(idx),{'op':'stats'} if role=='nora' else None) for role in [peer,'nora']})
 a,b=[next(s for s in x[peer]['sessions'] if s['sid']==sid and s.get('wire_state','').endswith('ACTIVE')) for x in values];na,nb=[next(c for c in x['nora']['calls'] if c['session_id']==sid and c['end_user_state']=='CONNECTED') for x in values]
 def inbound(c,kind):return next(s for s in c['rtp_stats'] if s['type']=='inbound-rtp' and s.get('kind')==kind)
 aa,ab=inbound(na,'audio'),inbound(nb,'audio');ok=a['audio_in_packets']<b['audio_in_packets'] and a['audio_sink_samples']<b['audio_sink_samples'] and aa['packetsReceived']<ab['packetsReceived'] and aa['totalSamplesReceived']<ab['totalSamplesReceived']
 result={'sid':sid,'peer':peer,'video':video,'audio_rtp_native':[a['audio_in_packets'],b['audio_in_packets']],'audio_pcm_native':[a['audio_sink_samples'],b['audio_sink_samples']],'audio_rtp_nora':[aa['packetsReceived'],ab['packetsReceived']],'audio_pcm_nora':[aa['totalSamplesReceived'],ab['totalSamplesReceived']],'audio_pass':ok,'call_trust_level':[na['call_trust_level'],nb['call_trust_level']],'physical_quality_tested':False}
 if video:
  va,vb=inbound(na,'video'),inbound(nb,'video');vok=a['video_in_packets']<b['video_in_packets'] and a['video_decoded']<b['video_decoded'] and a['video_sink_frames']<b['video_sink_frames'] and va['packetsReceived']<vb['packetsReceived'] and va['framesDecoded']<vb['framesDecoded'];result.update(video_pass=vok,video_rtp_native=[a['video_in_packets'],b['video_in_packets']],video_decoded_native=[a['video_decoded'],b['video_decoded']],video_sink_native=[a['video_sink_frames'],b['video_sink_frames']],video_rtp_nora=[va['packetsReceived'],vb['packetsReceived']],video_decoded_nora=[va['framesDecoded'],vb['framesDecoded']]);ok=ok and vok
 v.write(out/(label+'-media-verdict.json'),result);assert ok,'Actual media counters did not prove the required edges';return values

def close(label):
 # Real call UI invokes the product's normal endCall even while XMPP is offline.
 # No Bridge hangup is submitted, so there is no ambiguous mutation retry.
 s=op('nora',label+'-actual-state-before-normal-ui-close');identity(s)
 live=[c for c in s['calls'] if c.get('end_user_state') in {'CONNECTED','CONNECTING','RECONNECTING','INCOMING_CONTENT_ADD'} and (c.get('muji_room') or c['session_id']) not in ui_end_attempts]
 if live:
  assert len(live)==1 or s.get('conference'),'Ambiguous current calls'
  c=live[0];ui_bind(s,c['session_id'],label+'-end',for_cleanup=True)
  dest='/data/local/tmp/dinox-end-ui-'+uuid.uuid4().hex+'.xml'
  cli(['shell','-T','uiautomator','dump',dest],timeout=20)
  raw=cli(['shell','-T','cat',dest]);(out/(label+'-end-ui.xml')).write_bytes(raw);(out/(label+'-end-ui.xml')).chmod(0o600)
  buttons=[n for n in ET.fromstring(raw).iter('node') if n.get('resource-id')==v.PACKAGE+':id/end_call' and n.get('enabled')=='true' and n.get('clickable')=='true']
  assert len(buttons)==1,'No exact normal end-call control'
  coords=list(map(int,re.fullmatch(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]',buttons[0].get('bounds','')).groups()))
  ui_end_attempts.add(c.get('muji_room') or c['session_id'])
  v.write(out/(label+'-normal-ui-end-attempt.json'),{'account':s['account'],'sid':c['session_id'],'peer':c['peer'],'room':c.get('muji_room'),'at_most_once':True})
  cli(['shell','-T','input','tap',str((coords[0]+coords[2])//2),str((coords[1]+coords[3])//2)])
 for role in ['leon','felix']:
  if role=='leon' and not inspect_native('leon')['State']['Running']:continue
  s=op(role,label+'-actual-native-state-after-normal-ui-close')
  if s.get('call') and s['call']['state'].endswith(('IN_PROGRESS','RINGING','ESTABLISHING')) and (role,s['call']['id']) not in native_end_attempts:
   native_end_attempts.add((role,s['call']['id']));op(role,label+'-close-current-call-once',{'op':'hangup','call_id':s['call']['id']})
 deadline=time.monotonic()+60
 while True:
  s=op('nora',label+'-actual-idle-after-normal-ui-close');identity(s)
  if not s['calls'] and not s.get('conference'):break
  assert time.monotonic()<deadline,'Normal UI end did not reach idle; no automatic repeat'
  time.sleep(1)
 cli(['shell','-T','input','keyevent','KEYCODE_HOME'])


try:
 assert not (r.STATE/'allow-leon.json').exists();v.resources();r.gate('nora',2048,True,False)
 native_recording=native_rec.server({'action':'begin','label':'DinoX-peers-for-single-Nora-CSI-fix-UI-and-background-retest','local_recording':True});ensure_native('felix',1500)
 f=(out/'runtime-controller.log').open('xb');(out/'runtime-controller.log').chmod(0o600);runner=subprocess.Popen([sys.executable,'-B',str(r.HERE/'runtime.py'),'nora','--guest-memory-mib','2048','--lowram'],stdin=subprocess.DEVNULL,stdout=f,stderr=subprocess.STDOUT,start_new_session=True);phase='boot-retained-tested-main-and-account';deadline=time.monotonic()+600
 while True:
  assert runner.poll() is None,'The single runtime exited before genuine readiness'
  try:
   session=r.read(r.role_config('nora')['state']/'live-session.json')
   if session.get('controller_pid')==runner.pid and session.get('emulator_pid') and system_logger is None:
    v.require_adb_ready(session['adb_pid'],session['adb_start_ticks'],5038,session['adb_sha256'],session['adb_cgroup'])
    probe=subprocess.run(adb+['get-state'],capture_output=True,timeout=3)
    if probe.returncode==0 and probe.stdout.strip()==b'device':
     system_rawlog=out/'guest-system-connectivity-from-adb-ready.log';system_handle=system_rawlog.open('xb');system_rawlog.chmod(0o600)
     def limitsystemlog():resource.setrlimit(resource.RLIMIT_FSIZE,(32*1024**2,32*1024**2))
     system_logger=subprocess.Popen(adb+['logcat','-b','all','-v','epoch','*:D'],stdin=subprocess.DEVNULL,stdout=system_handle,stderr=subprocess.STDOUT,start_new_session=True,preexec_fn=limitsystemlog)
   if session.get('controller_pid')==runner.pid and session.get('ready'):break
  except FileNotFoundError:pass
  assert time.monotonic()<deadline;time.sleep(1)
 tests=r.read(Path('/media/linux/SSD128/monocles-interop-runtime-20261015/pair-v2/nora/logs-20261016T015030Z-bf7099bcd9574eb38edada814a829814/current-main-eight-android-tests-receipt.json'));assert tests['tests']==8 and tests['actually_installed_apk_sha256']==r.APKS;assert r.sha(Path(tests['raw']['path']))==tests['raw']['sha256'];v.verify_instrumentation(Path(tests['raw']['path']).read_text())
 assert system_logger is not None and system_logger.poll() is None,'No live system/network logger'
 recording=rec.record({'action':'begin','label':'background-only-same-tested-APKs-retained-Nora-normal-Home-MUJI'});v.write(out/'actual-recording-provenance.json',{'android_recording':recording,'dinox_recording':native_recording,'prior_same_apk_eight':tests,'CSI_product_derivation':r.CSI_PRODUCT_PROOF,'controller_sha256':r.sha(Path(__file__)),'prior_video_verdict':{'path':'/media/linux/SSD128/monocles-interop-runtime-20261015/pair-v2/csi-fix-continuation-20261016T075620Z-9287b5922a1349fb8d732113b447cdda/new-product-direct-video-media-verdict.json','sha256':r.sha(Path('/media/linux/SSD128/monocles-interop-runtime-20261015/pair-v2/csi-fix-continuation-20261016T075620Z-9287b5922a1349fb8d732113b447cdda/new-product-direct-video-media-verdict.json'))}})
 deadline=time.monotonic()+90
 while True:
  n=op('nora','actual-retained-identity-and-online-after-new-eight');identity(n)
  if n['online']:break
  assert time.monotonic()<deadline;time.sleep(1)
 assert not n['calls'] and not n.get('conference') and not n['pending_invites'];raw=cli(['shell','-T','cat','/proc/meminfo']);memtotal=next(int(x.split()[1])*1024 for x in raw.decode().splitlines() if x.startswith('MemTotal:'));assert 1536*1024**2<memtotal<=2048*1024**2;prop=cli(['shell','-T','getprop','ro.config.low_ram']).decode().strip();v.write(out/'actual-guest-identity-memory.json',{'account':n['account'],'device':n['own_device_id'],'fingerprint':n['own_legacy_fingerprint'],'guest_memtotal_bytes':memtotal,'ro.config.low_ram':prop,'lowram_emulation_variant':True})
 pid=int(cli(['shell','-T','pidof',v.PACKAGE]).strip());rawlog=out/'own-app-normal-CSI-fix-and-background-lifecycle.log';log_handle=rawlog.open('xb');rawlog.chmod(0o600)
 def limitlog():resource.setrlimit(resource.RLIMIT_FSIZE,(16*1024**2,16*1024**2))
 logger=subprocess.Popen(adb+['logcat','--pid='+str(pid),'-v','threadtime','*:D'],stdin=subprocess.DEVNULL,stdout=log_handle,stderr=subprocess.STDOUT,start_new_session=True,preexec_fn=limitlog)
 stable_normal_home()
 phase='normal-background-MUJI';ensure_native('leon',900);ensure_native('felix',900);sid=direct('leon',False,'pre-background-direct');media('leon',sid,False,'pre-background-direct')
 offset=rawlog.stat().st_size;bg_before=rawlog.read_text(errors='replace').count('app switched into background');cli(['shell','-T','input','keyevent','KEYCODE_HOME']);deadline=time.monotonic()+20
 while True:
  dump=cli(['shell','-T','dumpsys','activity','activities']).decode();top=[x.strip() for x in dump.splitlines() if 'topResumedActivity' in x];bg_after=rawlog.read_text(errors='replace').count('app switched into background')
  if top and all(v.PACKAGE not in x for x in top) and bg_after>bg_before:break
  assert time.monotonic()<deadline;time.sleep(.5)
 v.write(out/'actual-normal-Home-background.json',{'sid':sid,'top_resumed':top,'background_count_before':bg_before,'background_count_after':bg_after,'log_offset_before_home':offset,'no_forced_CSI_or_callback':True})
 l=op('leon','current-same-direct-before-one-promotion');assert l['online'] and l['call']['state'].endswith('IN_PROGRESS') and any(s['sid']==sid and s.get('wire_state','').endswith('ACTIVE') for s in l['sessions']);start=time.monotonic();promoted=op('leon','single-normal-DinoX-promotion-add-Felix-once',{'op':'add_participant','call_id':l['call']['id'],'peer':'felix'});assert promoted['invitation_result'].endswith('AVAILABLE');room=promoted['call']['room'];accepted=set();joined=False;uis=[];mesh=0
 while time.monotonic()-start<90:
  states={role:op(role,'actual-background-promotion-observation') for role in ['nora','leon','felix']};dump=cli(['shell','-T','dumpsys','activity','activities']).decode();uis.append({'elapsed':time.monotonic()-start,'top_resumed':[x.strip() for x in dump.splitlines() if 'topResumedActivity' in x]});v.write(out/'background-live-ui-observations.json',uis);assert uis[-1]['top_resumed'],'No positive current Activity observation: background not proven';assert all(v.PACKAGE not in x for x in uis[-1]['top_resumed']),'Actual automatic UI foreground transition: continued-background MUJI not proven';n=states['nora'];c=states['felix'].get('call')or{}
  if c.get('invited_room') and c.get('state','').endswith(('RINGING','IN_PROGRESS','ESTABLISHING')) and c['id'] not in accepted:
   assert c['invited_room'].split('/',1)[0]==room;op('felix','authorize-exact-current-room',{'op':'authorize_room','room':room});op('felix','accept-exact-current-invitation-once',{'op':'accept_call','call_id':c['id']});accepted.add(c['id'])
  if n.get('conference') and n['conference']['room']==room and all((states[x].get('call')or{}).get('room')==room and states[x]['call']['state'].endswith('IN_PROGRESS') for x in ['leon','felix']):joined=True
  if joined:
   for role in ['leon','felix','nora']:op(role,'actual-background-six-edge-media-sample'+str(mesh+1),{'op':'stats'} if role=='nora' else None)
   mesh+=1
   if mesh==2:break
  time.sleep(2)
 v.write(out/'background-promotion-observations.json',{'sid':sid,'room':room,'exactly_one_promotion':True,'complete_three_way_state_observed':joined,'mesh_sample_sets':mesh,'ui_observations':uis,'no_manual_reforeground':True,'elapsed_seconds':time.monotonic()-start,'media_verdict_requires_raw_edge_audit':True});assert joined and mesh==2,'No complete background conference with two real sample sets'
 close('final-background-case');n=op('nora','final-retained-identity-idle');identity(n);assert not n['calls'] and not n.get('conference')
 phase='idle-pair-resource-decision';shared=v.resources();common=Path(shared['cgroup']);mem={x.split()[0]:int(x.split()[1]) for x in (common/'memory.stat').read_text().splitlines()}
 v.write(out/'actual-idle-for-pair-resource-decision.json',{'account':n['account'],'device':n['own_device_id'],'fingerprint':n['own_legacy_fingerprint'],'nora_controller_pid':runner.pid,'shared':shared,'shared_anon':mem['anon'],'shared_kernel':mem['kernel'],'shared_file':mem['file'],'no_second_Android_started':True,'decision_window_seconds':180,'finally_cleanup_retained':True})
 print('ACTUAL_BACKGROUND_COMPLETED_NORA_IDLE_FOR_PAIR_DECISION',str(out),flush=True)
 deadline=time.monotonic()+180;extended=False
 while time.monotonic()<deadline and not (out/'finish-retained-nora.json').exists():
  v.resources();assert runner.poll() is None,'Owned runtime ended during bounded idle hold'
  if not extended and (r.STATE/'allow-leon.json').exists():
   # Existing explicit second-role gate authorizes that separate lifecycle, never this loop.
   deadline=time.monotonic()+1200;extended=True
  time.sleep(1)
 phase='normal-cleanup';op('nora','normal-final-bridge-stop-once',{'op':'stop'});runner.wait(timeout=180);assert runner.returncode==0;v.write(out/'completed-observations.json',{'result':'OBSERVATIONS_COMPLETED_PENDING_INDEPENDENT_MEDIA_AUDIT','prior_same_apk_eight':tests,'new_direct_video_run':False,'prior_direct_audio_video_are_historical':True,'background_conference_observed':True,'same_identity':True,'runner_exit':0,'second_android_started_by_this_batch':False,'physical_quality_tested':False})
except BaseException as e:
 traceback.print_exc();v.write(out/'actual-failure.json',{'error_type':type(e).__name__,'detail':str(e),'no_automatic_mutation_retry':True})
 if recording is not None and runner is not None and runner.poll() is None:
  try:close('failure-cleanup')
  except BaseException:pass
 raise
finally:
 if logger is not None:v.stop_owned(logger);log_handle.close();v.write(out/'private-log-receipt.json',{'path':str(rawlog),'sha256':r.sha(rawlog),'main_logging_is_normal_product':True})
 if runner is not None and runner.poll() is None:
  if recording is not None and not stop_sent:
   try:op('nora','normal-finally-bridge-stop-once',{'op':'stop'})
   except BaseException:pass
  try:runner.wait(timeout=180)
  except subprocess.TimeoutExpired:v.stop_owned(runner)
 if system_logger is not None:
  v.stop_owned(system_logger);system_handle.close();v.write(out/'system-network-log-receipt.json',{'path':str(system_rawlog),'sha256':r.sha(system_rawlog),'started_from_first_adb_device_readiness':True,'contains_private_test_data':True})
 done.set();thread.join(timeout=3)
 if samples:v.write(out/'resource-peaks.json',{'sample_count':len(samples),'peak_anon':max(x['anon']for x in samples),'peak_kernel':max(x['kernel']for x in samples),'peak_anon_plus_kernel':max(x['anon']+x['kernel']for x in samples),'peak_current':max(x['current']for x in samples),'min_host_available':min(x['host_available']for x in samples),'peak_swap':max(x['swap']for x in samples),'events_last':samples[-1]['events'],'lowram_emulation_variant':True,'second_Android_safe_proven':False})
 original=r.ROOT/'private/interop-config-before-csi-fix-single-boot.json'
 if original.exists():r.role_config('nora')['config'].write_bytes(original.read_bytes());r.role_config('nora')['config'].chmod(0o600)
 marker=r.STATE/'allow-nora.json'
 if marker.exists():marker.rename(out/'used-single-boot-approval.json')
 print('CSI_FIX_ONE_BOOT_FINISHED',str(out),'RUNNER',None if runner is None else runner.poll(),flush=True)

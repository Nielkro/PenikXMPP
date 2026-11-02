from pathlib import Path
import ast,re,json,hashlib,shlex,tempfile,subprocess,os,time
P=Path('/media/linux/SSD128/xmppwin/local/monocles-dinox-interop-20261015/harness/resume-completion-plan-20261016T190157Z/ui-owner-resume');out=P/'a-parallel-capture';base=P/'a-banner-batched-capture';fixture=Path('/media/linux/SSD128/monocles-interop-runtime-20261015/pair-v2/session-public-Nora-auth-text-preflight-20261016T204821Z/actual-owner-ui-nora-b62679fe15df42049d7f19b566959044');stem='actual-current-surface-capture-only';sha=lambda f:hashlib.sha256(f.read_bytes()).hexdigest()
def definitions(path):
 tree=ast.parse(path.read_text());names={'binary_capture_frame','parallel_capture_program','combined_windows_input','input_rectangle','parse_input_dispatcher','visible_windows','input_ownership'};ns={'re':re,'shlex':shlex};exec(compile(ast.Module(body=[x for x in tree.body if isinstance(x,ast.FunctionDef)and x.name in names],type_ignores=[]),str(path),'exec'),ns);return ns
n=definitions(out/'wait_capture.py');raw=(fixture/(stem+'-input.txt')).read_text();wm=(fixture/(stem+'-windows.txt')).read_text();png=(fixture/(stem+'.png')).read_bytes();xml=(fixture/(stem+'.xml')).read_bytes();payload=b'__OWNER_CHILD_EXITS__0,0\n__OWNER_XML_BEGIN__\n'+xml+b'\n__OWNER_XML_END__\n__OWNER_PNG_BEGIN__\n'+png+b'\n__OWNER_PNG_END__\n'+('__OWNER_WINDOWS_BEGIN__\n'+wm+'__OWNER_INPUT_BEGIN__\n'+raw+'__OWNER_QUERY_END__\n').encode();assert n['binary_capture_frame'](payload)==(xml,png,wm,raw)
groups=['realBinaryXML_PNG_WM_InputRoundtrip']
for bad in(payload.replace(b'CHILD_EXITS__0,0',b'CHILD_EXITS__7,0'),payload[:-1],payload+b'__OWNER_XML_END__\n__OWNER_PNG_BEGIN__\n',payload.replace(b'\x89PNG\r\n\x1a\n',b'INVALIDPNG',1)):
 try:n['binary_capture_frame'](bad)
 except (AssertionError,ValueError,UnicodeDecodeError):pass
 else:raise AssertionError('Invalid frame accepted')
groups.append('nonzeroGuestStatus_truncated_ambiguous_badPNGReject')
assert n['input_ownership'](raw,n['visible_windows'](wm),[540,1059],'android',1000)['tap_permitted']
assert not n['input_ownership'](raw,n['visible_windows'](wm),[540,200],'android',1000)['tap_permitted'];groups.append('knownANRWaitPointOnly_noBannerInput')
def method(path,name):
 c=next(x for x in ast.parse(path.read_text()).body if isinstance(x,ast.ClassDef)and x.name=='OwnerUI');return next(x for x in c.body if isinstance(x,ast.FunctionDef)and x.name==name)
for name in ('wait_capture.py','owner_ui.py'):
 for fun in('adb','session_now','require_touch','submit_semantic','activity','capture_target','run'):assert ast.dump(method(out/name,fun))==ast.dump(method(base/name,fun)),fun
assert sha(out/'persistent_text.py')==sha(base/'persistent_text.py');groups.append('allLowerGuards5s3_8sLock_PIDSourceAndRunnerUnchanged')
mock=[]
with tempfile.TemporaryDirectory(prefix='owner-capture-pure-mocks-')as tmp:
 root=Path(tmp);bin=root/'bin';bin.mkdir();pids=root/'pids';pids.mkdir()
 files={'toybox':'#!/bin/sh\n[ "$1" = timeout ] || exit 91\nshift\nexec /usr/bin/timeout "$@"\n','uiautomator':'#!/bin/sh\necho $$ >"$FAKE_PIDS/ua"\n[ "$FAKE_MODE" != fail-ua ] || exit 7\nif [ "$FAKE_MODE" = stall-ua ]; then exec /bin/sleep 10; fi\nprintf "<hierarchy/>" >"$2"\n','screencap':'#!/bin/sh\necho $$ >"$FAKE_PIDS/png"\n[ "$FAKE_MODE" != fail-png ] || exit 8\nif [ "$FAKE_MODE" = stall-png ]; then exec /bin/sleep 10; fi\nprintf "\\211PNG\\r\\n\\032\\nABCD"\n','dumpsys':'#!/bin/sh\nif [ "$1" = window ]; then cat "$FAKE_WM"; elif [ "$1" = input ]; then cat "$FAKE_INPUT"; else exit 99; fi\n'}
 for name,s in files.items():q=bin/name;q.write_text(s);q.chmod(0o700)
 def dead(pid):
  try:return Path('/proc',str(pid),'stat').read_text().rsplit(')',1)[1].split()[0]in('Z','X')
  except FileNotFoundError:return True
 for mode in ('success','fail-ua','fail-png','stall-ua','stall-png','host-parent-killed'):
  for f in pids.iterdir():f.unlink()
  directory=root/('capture-'+mode);script=n['parallel_capture_program']('/data/local/tmp/interop-owner-'+'a'*32+'.capture').replace('/data/local/tmp/interop-owner-'+'a'*32+'.capture',str(directory));env={**os.environ,'PATH':str(bin)+':/usr/bin:/bin','FAKE_MODE':'stall-ua'if mode=='host-parent-killed'else mode,'FAKE_PIDS':str(pids),'FAKE_WM':str(fixture/(stem+'-windows.txt')),'FAKE_INPUT':str(fixture/(stem+'-input.txt'))}
  child=subprocess.Popen(['/bin/sh','-c',script],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True);before=time.monotonic()
  if mode=='host-parent-killed':time.sleep(.15);child.kill()
  stdout,stderr=child.communicate(timeout=4.5)
  if mode=='host-parent-killed':time.sleep(max(0,3.85-(time.monotonic()-before)))
  assert not directory.exists(),(mode,'Own directory/files left')
  assert all(dead(int(f.read_text()))for f in pids.iterdir()),(mode,'Live mock guest helper left')
  if mode=='success':assert child.returncode==0 and n['binary_capture_frame'](stdout)[0]==b'<hierarchy/>'
  else:assert child.returncode!=0
  mock.append({'mode':mode,'exit':child.returncode,'own_files_absent':True,'both_helpers_exited':True})
groups.append('fakeGuestShell_success_bothChildFailures_deadlineBothStalls_cleanup')
groups.append('fakeHostParentKill_independentDeadlineOwnHelpersAndFilesCleanup')
q=out/'offline-checks.json';q.write_text(json.dumps({'result':'PASS','groups_count':len(groups),'groups':groups,'fake_shell_results':mock,'fake_timeout_implementation':'local GNU timeout mock of separately reviewed Android15Toybox processgroup+TERM/KILL contract','actual_guest_ADB_SSH_or_input_executed':False,'fixture_sha256':{str(f):sha(f)for f in(fixture/(stem+'-input.txt'),fixture/(stem+'-windows.txt'),fixture/(stem+'.png'),fixture/(stem+'.xml'))},'source_sha256':{str(out/n):sha(out/n)for n in('wait_capture.py','owner_ui.py','persistent_text.py')}},indent=2)+'\n');print(json.dumps({'result':'PASS','groups':len(groups),'receipt_sha256':sha(q)}))

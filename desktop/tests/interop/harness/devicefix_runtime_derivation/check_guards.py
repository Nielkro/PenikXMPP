#!/usr/bin/env python3
"""Pure source/mocked-input checks. Never generate admitted runtimes or use ADB."""
import ast,contextlib,hashlib,importlib.util,io,json,tempfile
from pathlib import Path
from unittest import mock
HERE=Path(__file__).resolve().parent
def module(name):
 spec=importlib.util.spec_from_file_location(name,HERE/(name+'.py'))
 value=importlib.util.module_from_spec(spec);spec.loader.exec_module(value);return value
def rejected(call):
 try:call()
 except (AssertionError,FileNotFoundError,RuntimeError):return
 raise AssertionError('Expected rejection')
def main():
 d=module('derive');c=module('consent_dispatch');groups=[]
 assert all(not p.exists() for p in (d.A,d.B,d.C))
 with tempfile.TemporaryDirectory() as tmp:
  rejected(lambda:d.generate(Path(tmp)/'NO_ACTUAL_HANDOFF.json'))
 assert all(not p.exists() for p in (d.A,d.B,d.C));groups.append('missing_actual_handoff_before_any_output')
 # Deliberately in-memory source-shape fixture, never a product/admission receipt.
 fixture={'main_sha256':'not-an-actual-apk-fixture','main_path':'/NONEXISTENT/main',
  'test_path':'/NONEXISTENT/test','test_sha256':d.p.TEST,'actual_jvm_tests':616,'commit':d.p.COMMIT,
  'signer_certificate_sha256':d.p.CERT,'source':{'path':'/NONEXISTENT/source','sha256':d.p.SOURCE},
  'handoff':{'path':'/NONEXISTENT/handoff','sha256':'fixture-only'},
  'build':{'path':'/NONEXISTENT/build','sha256':'fixture-only'},'jvm':{'path':'/NONEXISTENT/jvm','sha256':d.p.JVM}}
 files,_=d.render(fixture)
 for path,raw in files.items():
  if path.suffix=='.py':compile(ast.parse(raw),str(path),'exec')
 assert all(not p.exists() for p in (d.A,d.B,d.C));groups.append('source_only_in_memory_render_and_AST')
 n=files[d.A/'runtime.py'].decode();s=files[d.A/'scenario.py'].decode()
 assert "choices=('nora',)" in n and 'choices=(2048,), default=2048' in n
 assert "assert role=='nora'" in n and "r._historical.role_config('leon')['state'] / 'live-session.json'" in s
 assert "r.role_config('leon')['state'] / 'live-session.json'" not in s
 groups.append('one_android_and_readonly_historical_Leon_stop')
 assert "context['evidence_directory']" in s and "'evidence_directory':out" in s
 assert s.index('normal-consent-owner-scope')>s.index('text_error = None')
 assert s.count("op('nora','prepare-room-legacy-once'")==1
 assert "if sender != 'nora':op(sender, 'prepare-room-legacy-once'" in s
 assert s.index("op('nora','prepare-room-legacy-once'")<s.index('normal-consent-owner-scope')
 assert s.index('normal-consent-owner-scope')<s.index('for sender in ROLES:',s.index('text_error = None'))
 groups.append('explicit_checkpoint_directory_and_consent_before_text')
 b=files[d.B/'runtime.py'].decode();p=files[d.C/'scenarios.py'].decode()
 assert 'CONSENT_HELPER)' in b and '_CurrentProductBase' in b
 assert "local_handoff_path=PRODUCT['handoff']['path']" in b
 assert 'layout_capture.capture(r,op,write,out,context[\'room\'])' in s
 assert p.index('for role in ROLES:io.normal_consent(role,mode)')<p.index('tokens, deliveries=[],[]')
 groups.append('GPU_baseline_and_per_sender_consent_binding')
 with mock.patch.object(c.subprocess,'Popen') as child:
  rejected(lambda:c.dispatch(None,None,HERE/'consent_dispatch.py','wrong',{},'nora','room','legacy','batch'))
  child.assert_not_called()
 groups.append('wrong_helper_SHA_before_any_child')
 with tempfile.TemporaryDirectory() as tmp:
  root=Path(tmp);path=root/'admission.json'
  admission={'role':'felix','room':'room','mode':'legacy','batch_id':'batch'}
  path.write_text(json.dumps(admission));path.chmod(0o600)
  ref={'path':str(path),'sha256':hashlib.sha256(path.read_bytes()).hexdigest()}
  with mock.patch.object(c.subprocess,'Popen') as child:
   rejected(lambda:c.dispatch(None,None,HERE/'consent_dispatch.py',hashlib.sha256((HERE/'consent_dispatch.py').read_bytes()).hexdigest(),ref,'nora','room','legacy','batch'))
   child.assert_not_called()
 groups.append('wrong_role_admission_before_any_child')
 with tempfile.TemporaryDirectory() as tmp:
  root=Path(tmp);reference=root/'refs.json';reference.write_text(json.dumps({'nora':{'test_fixture':True}}));reference.chmod(0o600)
  class R:ROOT=root
  def write(name,value):(root/name).write_text(json.dumps(value))
  out=io.StringIO()
  with contextlib.redirect_stdout(out):result=c.owner_reference(R,write,reference,'nora',{'fixture':'not-real'},root)
  event=json.loads(out.getvalue());scope=Path(event['scope_path'])
  assert result=={'test_fixture':True} and scope.is_file()
  assert hashlib.sha256(scope.read_bytes()).hexdigest()==event['scope_sha256']
  assert event['reference_target']==str(reference) and event['owner_must_forward_to_Root_now'] is True
 groups.append('checkpoint_actual_path_SHA_deadline_no_admission_fabrication')
 print(json.dumps({'result':'OFFLINE_SOURCE_AND_MOCK_ONLY_PASS','groups':groups,'runtime_outputs_created':False,
  'adb_server_build_calls':False,'actual_product_verified':False},indent=2))
if __name__=='__main__':main()

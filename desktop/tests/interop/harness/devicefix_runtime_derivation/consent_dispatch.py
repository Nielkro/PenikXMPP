"""One exact source-pinned UI subprocess in the existing bounded cgroup."""
import hashlib,json,os
from pathlib import Path
import subprocess,sys,time


def owner_reference(r,write,path,role,scope,directory,seconds=90):
    path=Path(path);assert path.is_absolute() and path.resolve().is_relative_to(r.ROOT)
    assert seconds==90
    name='normal-consent-needed-'+role+'.json'
    deadline=time.time()+seconds;write(name,{'actual_scope':scope,'root_reference_target':str(path),'deadline_unix':deadline})
    scope_path=Path(directory)/name
    assert scope_path.resolve().is_relative_to(r.ROOT) and scope_path.is_file()
    scope_sha=hashlib.sha256(scope_path.read_bytes()).hexdigest()
    # Runtimeowner forwards this immediately to Root. No fabricated admission and
    # no dependency on an agent's final message or a second text submission.
    print(json.dumps({'event':'ROOT_CONSENT_CHECKPOINT_READY','role':role,'scope_path':str(scope_path.resolve()),'scope_sha256':scope_sha,
        'reference_target':str(path),'deadline_unix':deadline,'owner_must_forward_to_Root_now':True}),flush=True)
    while time.time()<deadline:
        if path.exists():
            assert path.is_file() and not path.is_symlink() and path.stat().st_mode&0o077==0
            value=json.loads(path.read_text())
            if role in value:return value[role]
        time.sleep(1)
    raise RuntimeError('Root consent reference missing at bounded checkpoint; no send attempted')


def dispatch(r,write,helper,expected_sha,reference,role,room,mode,batch,mixed=False):
    assert hashlib.sha256(Path(helper).read_bytes()).hexdigest()==expected_sha
    path=Path(reference['path']);assert path.is_file() and not path.is_symlink() and path.stat().st_mode&0o077==0
    raw=path.read_bytes();assert hashlib.sha256(raw).hexdigest()==reference['sha256']
    admission=json.loads(raw)
    assert admission['role']==role and admission['room']==room and admission['mode']==mode and admission['batch_id']==batch
    assert admission['helper_sha256']==expected_sha
    remaining=admission['expires_unix']-time.time();assert 5<=remaining<=240
    argv=[sys.executable,'-B',str(helper),*(() if mixed else (role,)),'--admission',str(path)]
    write('consent-'+role+'-before-submit.json',{'argv':argv,'admission_sha256':reference['sha256'],'room':room,'automatic_retry':False})
    child=subprocess.Popen(argv,stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
    try:
        assert r.v1.process_cgroup(child.pid)==r.v1.process_cgroup(os.getpid())
        stdout,stderr=child.communicate(timeout=min(240,remaining))
        write('consent-'+role+'-subprocess.json',{'exit':child.returncode,'stdout':stdout.decode(errors='replace')[:16384],
            'stderr':stderr.decode(errors='replace')[:8192],'submission_may_have_happened':True,'automatic_retry':False})
        assert child.returncode==0,'Consent PARTIAL: inspect same token, never resend'
        value=json.loads(stdout)
        expected='NORMAL_NORA_CONSENT_TWO_OWNED_GROUP_DECODED_BODIES_PASS' if mixed else 'NORMAL_RECIPIENT_CONSENT_AND_DECODED_TEXT_PASS'
        assert value['result']==expected and value['room']==room
        result_path=Path(value['path'])/'result.json';assert result_path.resolve().is_relative_to(r.ROOT)
        assert json.loads(result_path.read_text())==value
        write('consent-'+role+'-result.json',value);return value
    finally:r.v1.stop_owned(child)  # Its own helper PGID only; no guest/peer control.

"""Private host-side stop-reader drain. No ADB, process signals, guest mutation or retry."""
import json
import math
import os
from pathlib import Path
import re
import stat
import time
import uuid

LIMIT=55.0
KEYS=('run_id','role','batch_id','freeze_sha256','controller_pid','controller_start_ticks',
      'adb_pid','adb_start_ticks','emulator_pid','emulator_start_ticks')

def context(session):
    value={k:session[k] for k in KEYS}
    assert value['run_id']=='20261015-71115b' and value['role'] in ('nora','leon','felix')
    assert re.fullmatch('[0-9a-f]{32}',value['batch_id'])
    assert re.fullmatch('[0-9a-f]{64}',value['freeze_sha256'])
    for name in ('controller','adb','emulator'):
        assert type(value[name+'_pid']) is int and value[name+'_pid']>0
        assert str(value[name+'_start_ticks']).isdigit()
    return value

def ticks(pid):
    raw=Path('/proc',str(pid),'stat').read_text()
    return raw.rsplit(')',1)[1].split()[19]

def paths(directory,session):
    value=context(session)
    name='stop-ack-'+value['role']+'-'+value['batch_id']
    return Path(directory)/(name+'.pending.json'),Path(directory)/(name+'.settled.json')

def read(path):
    meta=path.lstat()
    assert stat.S_ISREG(meta.st_mode) and meta.st_uid==os.getuid()
    assert meta.st_mode&0o777==0o600 and meta.st_size<=32768
    return json.loads(path.read_bytes())

def write_once(path,value):
    temporary=path.with_name('.'+path.name+'.'+uuid.uuid4().hex+'.partial')
    fd=os.open(temporary,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    try:
        with os.fdopen(fd,'w') as stream:
            json.dump(value,stream);stream.write('\n');stream.flush();os.fsync(stream.fileno())
        # Readers see only complete JSON; link refuses an existing once-only name.
        os.link(temporary,path,follow_symlinks=False)
        directory=os.open(path.parent,os.O_RDONLY|os.O_DIRECTORY)
        try:os.fsync(directory)
        finally:os.close(directory)
    finally:
        temporary.unlink()

def require_open(directory,session):
    pending,settled=paths(directory,session)
    # Closing remains permanent for this batch, including Settled -> emulator exit.
    assert not pending.exists() and not pending.is_symlink() and not settled.exists() and not settled.is_symlink(), 'Stop already closes this role'

def begin(directory,session,identifier,started,clock=time.monotonic,wall=time.time):
    require_open(directory,session)
    assert re.fullmatch('[0-9a-f]{32}',identifier)
    now=clock();assert math.isfinite(started) and 0<=now-started<LIMIT
    deadline=min(started+LIMIT,now+session['batch_deadline_unix']-wall())
    assert now<deadline
    pending,_=paths(directory,session)
    value={'schema_version':1,'context':context(session),'id':identifier,
           'started_monotonic':started,'deadline_monotonic':deadline,
           'reader_pid':os.getpid(),'reader_start_ticks':ticks(os.getpid())}
    write_once(pending,value)
    return {'pending_path':str(pending),'value':value}

def remaining(ticket,clock=time.monotonic):
    value=read(Path(ticket['pending_path']));assert value==ticket['value']
    assert value['reader_pid']==os.getpid() and value['reader_start_ticks']==ticks(os.getpid())
    remaining=value['deadline_monotonic']-clock();assert remaining>0,'Fixed stop budget expired'
    return remaining

def settle(ticket,status,phase,rc=None,leaf=None,clock=time.monotonic):
    assert status in ('ack_received','pending','reader_failed')
    value=read(Path(ticket['pending_path']));assert value==ticket['value']
    assert value['reader_pid']==os.getpid() and value['reader_start_ticks']==ticks(os.getpid())
    assert re.fullmatch('[a-z_]+',phase) and (rc is None or type(rc) is int)
    if leaf is not None:
        assert set(leaf)=={'file','line','function'} and '/' not in leaf['file']
    path=Path(ticket['pending_path'].replace('.pending.json','.settled.json'))
    write_once(path,{'schema_version':1,'context':value['context'],'id':value['id'],
        'reader_pid':value['reader_pid'],'reader_start_ticks':value['reader_start_ticks'],
        'status':status,'phase':phase,'rc':rc,'leaf':leaf,'finished_monotonic':clock()})

def drain(directory,session,observe=lambda:None,clock=time.monotonic,sleep=time.sleep,wall=time.time):
    pending,settled=paths(directory,session)
    if not pending.exists():
        assert not pending.is_symlink() and not settled.exists()
        return {'status':'no_stop_intent','waited_seconds':0}
    value=read(pending);assert value['schema_version']==1 and value['context']==context(session)
    assert re.fullmatch('[0-9a-f]{32}',value['id'])
    start=value['started_monotonic'];end=value['deadline_monotonic']
    assert math.isfinite(start) and math.isfinite(end) and start<end<=start+LIMIT
    entered=clock()
    # No deadline is renewed at instrumentation exit. Hard batch expiry wins.
    deadline=min(end,entered+max(0,session['batch_deadline_unix']-wall()))
    while True:
        if settled.exists():
            done=read(settled)
            assert done['context']==value['context'] and done['id']==value['id']
            assert done['reader_pid']==value['reader_pid'] and done['reader_start_ticks']==value['reader_start_ticks']
            assert done['status'] in ('ack_received','pending','reader_failed')
            return {'status':'control_settled','observer_status':done['status'],'phase':done['phase'],
                    'id':value['id'],'waited_seconds':max(0,clock()-entered)}
        left=deadline-clock()
        if left<=0:return {'status':'fixed_deadline_expired','id':value['id'],'waited_seconds':max(0,clock()-entered)}
        observe();sleep(min(.1,left))

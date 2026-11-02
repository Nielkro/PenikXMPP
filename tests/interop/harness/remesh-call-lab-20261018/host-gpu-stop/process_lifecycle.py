"""Private same-process exit checks and exact-service shutdown settlement."""
from pathlib import Path
import errno
import hashlib
import os
import re
import select
import signal
import time

EXIT_STATES = ('Z', 'X', 'x')
SCAN_SETTLEMENT_SECONDS = .1
OPERATIONS = {'ADB_SERVER','ADB_BOOT_PROPERTY','ADB_OS_PROPERTY','ADB_MEMINFO','ADB_BLOCK_LIST',
 'ADB_ZRAM_DISKSIZE','ADB_ZRAM_MM_STAT','ADB_SWAPS','ADB_APP_PID','ADB_INSTALL','ADB_BRIDGE',
 'ADB_LOGCAT','ADB_APP_IO','ADB_PERMISSION','ADB_SYNC','ADB_EMULATOR_STOP','ADB_OTHER',
 'EMULATOR_START','SDK_TOOL','UNKNOWN_PROGRAM'}


def argument_diagnostic(arguments, sdk):
    """Fixed operation enum and canonical argv digest; never argument/input text."""
    args=[os.fsdecode(value)for value in arguments]
    value={'operation':'UNKNOWN_PROGRAM','argv_sha256':hashlib.sha256(b'\0'.join(os.fsencode(x)for x in args)+(b'\0'if args else b'')).hexdigest()}
    if not args:return value
    if args[0]==str(sdk/'emulator/emulator'):value['operation']='EMULATOR_START';return value
    if args[0]!=str(sdk/'platform-tools/adb'):
        if Path(args[0]).is_absolute()and Path(args[0]).is_relative_to(sdk):value['operation']='SDK_TOOL'
        return value
    tail=args[7:]if len(args)>=7 and args[1]=='-H'and args[3]=='-P'and args[5]=='-s'else args[1:]
    op='ADB_OTHER'
    if tail[:1]==['-L']:op='ADB_SERVER'
    elif tail==['shell','-T','getprop','sys.boot_completed']:op='ADB_BOOT_PROPERTY'
    elif tail[:3]==['shell','-T','getprop']:op='ADB_OS_PROPERTY'
    elif tail==['shell','-T','cat','/proc/meminfo']:op='ADB_MEMINFO'
    elif tail==['shell','-T','ls','/sys/block']:op='ADB_BLOCK_LIST'
    elif len(tail)==4 and tail[:3]==['shell','-T','cat']and re.fullmatch(r'/sys/block/zram\d+/disksize',tail[3]):op='ADB_ZRAM_DISKSIZE'
    elif len(tail)==4 and tail[:3]==['shell','-T','cat']and re.fullmatch(r'/sys/block/zram\d+/mm_stat',tail[3]):op='ADB_ZRAM_MM_STAT'
    elif tail==['shell','-T','cat','/proc/swaps']:op='ADB_SWAPS'
    elif tail[:3]==['shell','-T','pidof']:op='ADB_APP_PID'
    elif tail[:1]==['install']:op='ADB_INSTALL'
    elif tail[:4]==['shell','am','instrument','-w']:op='ADB_BRIDGE'
    elif tail[:1]==['logcat']:op='ADB_LOGCAT'
    elif tail[:2]==['shell','run-as']or tail[:3]==['shell','-T','run-as']:op='ADB_APP_IO'
    elif tail[:3]==['shell','pm','grant']:op='ADB_PERMISSION'
    elif tail==['shell','-T','sync']:op='ADB_SYNC'
    elif tail==['emu','kill']:op='ADB_EMULATOR_STOP'
    value['operation']=op;return value


def safe_comm(value):
    if value in('adb','emulator','qemu','netsimd','crashpad_handler','crashpad_handle'):return value
    if value.startswith('qemu-system-'):return 'QEMU_SYSTEM'
    if value.startswith('emulator64-'):return 'EMULATOR64'
    if re.fullmatch(r'python(?:\d+(?:\.\d+)*)?',value):return 'PYTHON'
    return 'OTHER'


def popen_binding(row,controller_pid):
    """Only validated diagnostic fields; never authority for skipping a process."""
    diagnostic=row.get('diagnostic',{})
    if not(type(row.get('pid'))is int and row['pid']>0 and type(controller_pid)is int and controller_pid>0):return None
    if not re.fullmatch(r'\d+',str(row.get('start_ticks',''))):return None
    if diagnostic.get('operation')not in OPERATIONS or not re.fullmatch(r'[0-9a-f]{64}',diagnostic.get('argv_sha256','')):return None
    return {'pid':row['pid'],'start_ticks':str(row['start_ticks']),'controller_pid':controller_pid,
            'operation':diagnostic['operation'],'argv_sha256':diagnostic['argv_sha256']}


def same_identity(item, value, before=None):
    assert value['pid']==item['pid']and value['start_ticks']==str(item['start_ticks']), 'Process PID/start changed'
    assert value['uid']==item.get('uid',os.getuid()), 'Process UID changed'
    for field in('ppid','pgid'):
        expected=item.get(field,before[field]if before is not None else value[field])
        assert value[field]==expected, 'Process parent/group changed'
    if before is not None:
        assert all(value[field]==before[field]for field in('pid','uid','ppid','pgid','start_ticks')), 'Process identity drift'


def snapshot(proc):
    fields = (proc / 'stat').read_text().rsplit(')', 1)[1].split()
    return {'pid': int(proc.name), 'uid': proc.stat().st_uid, 'state': fields[0],
            'ppid': int(fields[1]), 'pgid': int(fields[2]), 'start_ticks': fields[19],
            'kernel_flags':int(fields[6])}


def absent(proc):
    try: proc.lstat()
    except OSError as error:
        if error.errno in (errno.ENOENT, errno.ESRCH): return True
        raise
    return False


def terminal_proof(item, proc, before, deadline):
    """Read-only pidfd settlement. No signal; no R/PF_EXITING/parent exemption."""
    started=time.monotonic();fd=None;poll=None
    value={'terminal':False,'proof':None,'pidfd_readable':False,'last':None,'elapsed_seconds':0}
    try:
        while True:
            try:
                state=snapshot(proc);value['last']=state;same_identity(item,state,before)
            except OSError as error:
                if error.errno in(errno.ENOENT,errno.ESRCH)and absent(proc):
                    value.update(terminal=True,proof='ACTUAL_PROC_ABSENT');return value
                raise
            if fd is None:
                try:fd=os.pidfd_open(item['pid']);poll=select.poll();poll.register(fd,select.POLLIN)
                except ProcessLookupError:
                    # A live R snapshot is not exit proof even when pidfd_open races.
                    if time.monotonic()>=deadline:return value
                    time.sleep(min(.001,max(0,deadline-time.monotonic())));continue
                # Bind the fd to the same exact identity after pidfd_open, before polling.
                continue
            events=poll.poll(0);flags=0
            for event_fd,mask in events:
                assert event_fd==fd and not mask&(select.POLLERR|select.POLLNVAL), 'Invalid pidfd readiness'
                flags|=mask
            value['pidfd_readable']=bool(flags&select.POLLIN)
            if value['pidfd_readable']and state['state']in EXIT_STATES:
                try:final=snapshot(proc)
                except OSError as error:
                    if error.errno in(errno.ENOENT,errno.ESRCH)and absent(proc):
                        value.update(terminal=True,proof='ACTUAL_PROC_ABSENT');return value
                    raise
                same_identity(item,final,before);value['last']=final
                if final['state']in EXIT_STATES:
                    value.update(terminal=True,proof='PIDFD_READABLE_AND_SAME_EXIT_STATE');return value
            remaining=deadline-time.monotonic()
            if remaining<=0:return value
            # A ready fd with a nonterminal /proc state must not create a busy loop.
            if value['pidfd_readable']:time.sleep(min(.001,remaining))
            else:
                milliseconds=min(5,int(remaining*1000))
                if milliseconds<=0:return value
                events=poll.poll(milliseconds)
                for event_fd,mask in events:
                    assert event_fd==fd and not mask&(select.POLLERR|select.POLLNVAL), 'Invalid pidfd readiness'
    except(OSError,AssertionError,ValueError,IndexError)as error:
        value.update(proof='UNVERIFIABLE',error_type=type(error).__name__,errno=getattr(error,'errno',None));return value
    finally:
        if fd is not None:os.close(fd)
        value['elapsed_seconds']=time.monotonic()-started


def current(item, operation=None, proc_root=Path('/proc'), reject=None, settle_deadline=None, observe=None):
    """Only inspect ENOENT/ESRCH can spend the scan's shared terminal budget."""
    proc = proc_root / str(item['pid']); before = None
    inspection=False;settlement=None
    try:
        try: before = snapshot(proc)
        except OSError as error:
            if error.errno in (errno.ENOENT, errno.ESRCH) and absent(proc): return None
            raise
        same_identity(item,before)
        if before['state'] in EXIT_STATES:
            terminal=terminal_proof(item,proc,before,time.monotonic())
            assert terminal['terminal'], 'Terminal snapshot without kernel exit proof'
            return None
        inspection=operation is not None
        value = operation(proc, before) if operation else before
        inspection=False
        after = snapshot(proc)
        same_identity(item,after,before)
        if after['state'] in EXIT_STATES:
            terminal=terminal_proof(item,proc,before,time.monotonic())
            assert terminal['terminal'], 'Terminal snapshot without kernel exit proof'
            return None
        return value
    except (OSError, AssertionError, ValueError, IndexError) as error:
        after = None; reread_error = None;reread_retryable=False
        try:
            after = snapshot(proc)
            same_identity(item,after,before)
            reread_retryable=True
        except (OSError, AssertionError, ValueError, IndexError) as reread:
            reread_error = type(reread).__name__
            if isinstance(error, OSError) and error.errno in (errno.ENOENT, errno.ESRCH) and isinstance(reread, OSError) and reread.errno in (errno.ENOENT, errno.ESRCH) and absent(proc): return None
            reread_retryable=isinstance(reread,OSError)and reread.errno in(errno.ENOENT,errno.ESRCH)
        if inspection and before is not None and reread_retryable and isinstance(error,OSError)and error.errno in(errno.ENOENT,errno.ESRCH):
            deadline=settle_deadline if settle_deadline is not None else time.monotonic()
            settlement=terminal_proof(item,proc,before,deadline)
            if settlement['terminal']:
                if observe:observe({'pid':item['pid'],'expected_start_ticks':str(item['start_ticks']),
                    'reason':'INSPECT_ENOENT_ESRCH','initial':before,'reread':after,'settlement':settlement,
                    'candidate':item.get('candidate_diagnostic'),'own_popen':item.get('own_popen_diagnostic'),
                    'environment_or_credentials_read':False,'signal_sent':False})
                return None
        if reject: reject({'pid': item['pid'], 'expected_start_ticks': str(item['start_ticks']),
            'initial': before, 'reread': after, 'error_type': type(error).__name__, 'errno': getattr(error, 'errno', None),
            'reread_error_type': reread_error, 'scope': 'same-PID-startticks-exit-recheck',
            'candidate':item.get('candidate_diagnostic'),'own_popen':item.get('own_popen_diagnostic'),
            'settlement':settlement,'environment_or_credentials_read': False})
        raise AssertionError('Cannot verify current SDK/test-controller candidate PID ' + str(item['pid'])) from error


def scan(r, probe, proc_root=Path('/proc'), reject=None, observe=None, own_bindings=None):
    settle_deadline=time.monotonic()+SCAN_SETTLEMENT_SECONDS
    result = []
    for proc in proc_root.iterdir():
        if not proc.name.isdecimal() or int(proc.name) == os.getpid(): continue
        try:
            if proc.stat().st_uid != os.getuid(): continue
            first = snapshot(proc)
        except OSError as error:
            if error.errno in (errno.ENOENT, errno.ESRCH) and absent(proc): continue
            if reject: reject({'pid': int(proc.name), 'phase': 'initial-stat', 'error_type': type(error).__name__, 'errno': error.errno})
            raise AssertionError('Cannot read initial process identity PID ' + proc.name) from error
        if first['uid'] != os.getuid(): continue
        binding=(own_bindings or{}).get((first['pid'],first['start_ticks']))
        if binding is not None:first['own_popen_diagnostic']={**binding,'parent_matches':first['ppid']==binding['controller_pid']}
        def inspect(path, identity):
            raw=(path / 'cmdline').read_bytes()
            args = [os.fsdecode(x) for x in raw.rstrip(b'\0').split(b'\0')]if raw else[]
            comm = (path / 'comm').read_text().strip()
            if not probe.process_candidate(args, comm, r.ROOT / 'sdk'): return None
            first['candidate_diagnostic']={'comm':safe_comm(comm),
                'candidate_class':'PYTHON_CANDIDATE'if probe.is_python(comm)else'SDK_CANDIDATE',
                **argument_diagnostic(args,r.ROOT/'sdk')}
            first['candidate_diagnostic']['argv_sha256']=hashlib.sha256(raw).hexdigest()
            exe = (path / 'exe').resolve(strict=True)
            sdk = exe.is_relative_to(r.ROOT / 'sdk') or probe.is_sdk_program(exe.name)
            script = probe.python_script(args) if probe.is_python(exe.name) else None
            cwd = (path / 'cwd').resolve(strict=True) if script is not None and not script.is_absolute() else '/'
            if sdk or probe.is_controller(exe, args, cwd):
                return {'pid': identity['pid'], 'start_ticks': identity['start_ticks'], 'exe': str(exe), 'pgid': identity['pgid']}
        item = current(first, inspect, proc_root, reject, settle_deadline, observe)
        if item is not None: result.append(item)
    return result


def stopping(session, now):
    if session.get('lifecycle_phase') != 'stopping': return False
    begin, end = session['shutdown_started_unix'], session['shutdown_deadline_unix']
    assert session['state'] == 'running' and end == begin + 120 and begin <= now < end, 'Expired or invalid stopping owner'
    return True


def settle(r, probe, owner, record, scan_processes, grace_seconds=8):
    """8s normal grace plus 15s total pidfd budget; foreign processes untouched."""
    begin = time.monotonic(); grace_end = begin + grace_seconds; end = grace_end + 15
    def own():
        result = []
        for item in scan_processes(r):
            group = current(item, lambda proc, identity: next(line.split(':',2)[2] for line in (proc/'cgroup').read_text().splitlines() if line.startswith('0::')),
                reject=lambda report: record({**report, 'phase':'settle-own-cgroup-recheck', 'signal_sent':False}))
            if group != owner['cgroup']: continue
            if not probe.exact_service_sdk(item, owner):
                if current(item, reject=lambda report: record({**report, 'phase':'settle-after-failed-exact-check', 'signal_sent':False})) is None: continue
                raise AssertionError('Unverifiable SDK process in own stopping service')
            result.append(item)
        return result
    while time.monotonic() < grace_end:
        own(); time.sleep(min(.2, max(0, grace_end - time.monotonic())))
    actions = []
    for item in own():
        if time.monotonic() >= end: break
        if not probe.exact_service_sdk(item, owner): continue
        try: fd = os.pidfd_open(item['pid'])
        except ProcessLookupError: continue
        try:
            if not probe.exact_service_sdk(item, owner): continue
            poll = select.poll(); poll.register(fd, select.POLLIN)
            for signum in (signal.SIGTERM, signal.SIGKILL):
                if time.monotonic() >= end or poll.poll(0) or not probe.exact_service_sdk(item, owner): break
                event = {'identity': item, 'signal': int(signum), 'single_pidfd_only': True,
                    'exact_service_owner': owner, 'before_dispatch_unix': time.time()}
                record(event)
                try:
                    signal.pidfd_send_signal(fd, signum)
                    event = {**event, 'kernel_signal_call_succeeded': True,
                        'exited_in_bound': bool(poll.poll(min(5000, max(0, int((end-time.monotonic())*1000)))))}
                except ProcessLookupError: event = {**event, 'already_exited': True}
                actions.append(event)
        finally: os.close(fd)
    return {'grace_seconds': grace_seconds, 'total_bound_seconds': grace_seconds+15,
            'actions': actions, 'remaining': own(), 'foreign_services_signalled': False,
            'no_process_group_or_foreign_service_signal': True}

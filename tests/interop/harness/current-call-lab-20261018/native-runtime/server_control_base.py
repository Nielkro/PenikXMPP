#!/usr/bin/env python3
"""Control existing real interop bridges through private files; never start one."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import uuid

REMOTE = '/home/cpaneladmin/dinox-interop-20261015/harness/server_control.py'
HOST = 'cpaneladmin@45.84.199.125'
RUN = '20261015-71115b'
DOCKER = ['docker', 'exec', 'docker_dind', 'docker']

# Constant code travels as an argv operand. Requests/configuration never become code.
CONTROL_CODE = r'''
import json,os,re,socket,subprocess,sys,time
from pathlib import Path

RUN='20261015-71115b'
PACKAGE='de.monocles.chat.interop20261015'
OWN={'nora':'nora.schneider.interop.de.71115b@dinox.im',
     'leon':'leon.fischer.interop.de.71115b@dinox.im',
     'felix':'felix.wagner.interop.de.71115b@dinox.im'}

class ControlError(Exception): pass

def require(condition,code):
    if not condition: raise ControlError(code)

def validate(value):
    require(isinstance(value,dict),'object_required')
    require(value.get('role') in OWN,'unknown_role')
    require(value.get('action') in ('command','result','state'),'unknown_action')
    wait=value.get('wait',0)
    require(type(wait) in (int,float) and 0 <= wait <= 60,'wait_out_of_range')
    if value['action'] in ('command','result'):
        require(isinstance(value.get('id'),str) and re.fullmatch('[0-9a-f]{32}',value['id']) is not None,'invalid_uuid')
    if value['action']=='command':
        p=value.get('payload')
        require(isinstance(p,dict) and isinstance(p.get('op'),str) and 1<=len(p['op'])<=80,'operation_required')
        require('id' not in p and 'run_id' not in p,'reserved_fields')
    value=dict(value)
    value.setdefault('wait',0)
    return value

def normalise(payload,config,role,identifier):
    require(config.get('run_id')==RUN and config.get('jid')==OWN[role],'wrong_private_config')
    allowed=config.get('allowed_jids')
    require(isinstance(allowed,list) and 1<=len(allowed)<=2 and all(isinstance(p,str) for p in allowed),'invalid_allowlist')
    require(len(set(allowed))==len(allowed),'duplicate_allowed_peer')
    require(set(allowed)<=set(OWN.values())-{OWN[role]},'foreign_peer_in_config')
    result=dict(payload)
    if 'peer' in result:
        peer=result['peer']
        require(isinstance(peer,str) and not any(c.isspace() or ord(c)<32 for c in peer),'invalid_peer')
        if peer.casefold() in OWN:
            candidates=[p for p in allowed if p.split('@',1)[0].split('.',1)[0].casefold()==peer.casefold()]
            require(len(candidates)==1,'alias_not_allowed')
            peer=candidates[0]
        require(peer.split('/',1)[0] in allowed,'peer_not_allowed')
        if role=='nora': require('/' not in peer,'android_bare_peer_required')
        result['peer']=peer
    result['id']=identifier
    result['run_id']=config['run_id']
    return result

def redact(value,config):
    secrets=[config.get(k) for k in ('password','db_key','database_password') if isinstance(config.get(k),str) and config[k]]
    def walk(item):
        if isinstance(item,dict):
            return {k:('[redacted]' if k.casefold() in ('password','db_key','database_password','config') else walk(v)) for k,v in item.items()}
        if isinstance(item,list): return [walk(v) for v in item]
        if isinstance(item,str):
            for secret in sorted(secrets,key=len,reverse=True): item=item.replace(secret,'[redacted]')
        return item
    return walk(value)

class Files:
    def __init__(self,role): self.root=Path('/interop/monocles-dinox-interop-20261015/runner-profiles')/role
    def read(self,name):
        p=self.root/name
        if not p.exists(): return None
        require(p.is_file() and not p.is_symlink() and p.stat().st_size<=4*1024**2,'invalid_control_file')
        return json.loads(p.read_text())
    def submit(self,identifier,request):
        target=self.root/'inbox'/(identifier+'.json')
        pending=target.with_suffix('.partial')
        require(not target.exists() and not (self.root/'results'/(identifier+'.json')).exists(),'uuid_already_used')
        created=False
        try:
            fd=os.open(pending,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
            created=True
            with os.fdopen(fd,'w') as stream:
                json.dump(request,stream);stream.flush();os.fsync(stream.fileno())
            os.link(pending,target)  # Atomic publication, never replaces an earlier command.
        finally:
            if created: pending.unlink(missing_ok=True)

class Android:
    def __init__(self):
        settings=globals().get('ANDROID_CONTROL_SETTINGS',{})
        program=settings.get('adb','/cache/sdk/platform-tools/adb')
        port=settings.get('port',5038)
        serial=settings.get('serial','emulator-5580')
        self.guard=globals().get('ANDROID_CONTROL_GUARD')
        if self.guard is not None: self.guard()
        with socket.create_connection(('127.0.0.1',port),timeout=2): pass
        self.adb=[program,'-H','127.0.0.1','-P',str(port),'-s',serial]
        self.env=dict(os.environ,ANDROID_ADB_SERVER_PORT='5038',ADB_SERVER_SOCKET='tcp:127.0.0.1:5038',ADB_MDNS_AUTO_CONNECT='0')
    def call(self,mode,*args,data=None):
        if self.guard is not None: self.guard()
        transport=['shell','-T'] if mode in ('exec-in','exec-out') else [mode]
        result=subprocess.run(self.adb+transport+['run-as',PACKAGE,*args],input=data,text=True,capture_output=True,timeout=8,env=self.env)
        require(result.returncode==0,'android_control_io_failed')
        return result.stdout
    def exists(self,name):
        if self.guard is not None: self.guard()
        result=subprocess.run(self.adb+['shell','-T','run-as',PACKAGE,'test','-e','files/interop/'+name],text=True,capture_output=True,timeout=8,env=self.env)
        require(result.returncode in (0,1),'android_control_io_failed')
        return result.returncode==0
    def read(self,name):
        if not self.exists(name): return None
        raw=self.call('exec-out','cat','files/interop/'+name)
        require(len(raw)<=4*1024**2,'oversized_control_file')
        if not raw.strip(): return None
        try: return json.loads(raw)
        except json.JSONDecodeError: return None
    def submit(self,identifier,request):
        name='inbox/'+identifier
        require(not self.exists(name+'.json') and not self.exists('results/'+identifier+'.json'),'uuid_already_used')
        lock='files/interop/inbox/.'+identifier+'.lock'
        self.call('exec-out','mkdir',lock)  # Atomic nonce reservation, no competing partial writer.
        temporary=lock+'/command.partial'
        target='files/interop/'+name+'.json'
        try:
            raw=json.dumps(request)
            self.call('exec-in','dd','of='+temporary,data=raw)
            require(self.call('exec-out','cat',temporary)==raw,'incomplete_command_transfer')
            self.call('exec-out','chmod','600',temporary)
            self.call('exec-out','mv','-n',temporary,target)  # Nonce lock; Android SELinux prohibits hard links.
            self.call('exec-out','test','!','-e',temporary)  # mv -n must actually publish, never silently skip.
        finally:
            self.call('exec-out','rm','-f',temporary)
            self.call('exec-out','rmdir',lock)

def control(value):
    value=validate(value);role=value['role']
    backend=Android() if role=='nora' else Files(role)
    config=backend.read('config.json')
    require(isinstance(config,dict),'private_config_unavailable')
    normalise({},config,role,'0'*32)  # Validate scope without printing configuration.
    action=value['action'];identifier=value.get('id')
    if action=='command':
        request=normalise(value['payload'],config,role,identifier)
        backend.submit(identifier,request)
    name='state.json' if action=='state' else 'results/'+identifier+'.json'
    deadline=time.monotonic()+value.get('wait',0)
    while True:
        response=backend.read(name)
        if response is not None:
            require(isinstance(response,dict) and response.get('run_id')==config['run_id'],'response_run_mismatch')
            require(response.get('account')==config['jid'],'response_account_mismatch')
            if action!='state': require(response.get('id')==identifier,'response_id_mismatch')
            return redact({'role':role,'run_id':config['run_id'],'id':identifier,'submitted':action=='command','completed':True,'response':response},config)
        remaining=deadline-time.monotonic()
        if remaining<=0:
            return {'role':role,'run_id':config['run_id'],'id':identifier,'submitted':action=='command','completed':False,'pending':True}
        time.sleep(min(.25,remaining))

def main():
    value=None
    try:
        raw=sys.stdin.read(32769)
        require(len(raw)<=32768,'oversized_request')
        value=validate(json.loads(raw))
        response=control(value)
        print(json.dumps(response,ensure_ascii=False))
    except Exception as error:
        response={'ok':False,'error':str(error) if isinstance(error,ControlError) else 'control_transport_failed','error_type':type(error).__name__}
        if value is not None:
            response.update(role=value['role'],id=value.get('id'),run_id=RUN,
                            submission_outcome_unknown=value['action']=='command')
        print(json.dumps(response))
        raise SystemExit(2)

if __name__=='__main__': main()
'''


def validate_envelope(value):
    scope = {'__name__': 'control_parser'}
    exec(compile(CONTROL_CODE, '<fixed-control-code>', 'exec'), scope)
    value = scope['validate'](value)
    transport = value.setdefault('transport', 'server')
    if transport not in ('server', 'local-android'):
        raise ValueError('Unknown explicit transport')
    if transport == 'local-android' and value['role'] != 'nora':
        raise ValueError('Only the first local Nora device is prepared')
    return value


def local_android(value):
    from local_android_runtime import local_control_settings
    if value['role'] != 'nora' or value['transport'] != 'local-android':
        raise ValueError('Wrong local Android owner')
    settings = local_control_settings()
    scope = {'__name__': 'local_android_control', 'ANDROID_CONTROL_SETTINGS': settings,
             'ANDROID_CONTROL_GUARD': local_control_settings}
    exec(compile(CONTROL_CODE, '<fixed-local-android-control>', 'exec'), scope)
    response = scope['control'](value)
    response['transport'] = 'local-android'
    print(json.dumps(response, ensure_ascii=False))
    return 0


def server(value):
    validate_envelope(value)
    if value.get('transport', 'server') != 'server':
        raise ValueError('The server does not control local Android devices')
    name = ('dinox-monocles-validation-bridge-20261015' if value['role'] == 'nora'
            else 'dinox-interop-20261015-' + value['role'])
    info = json.loads(subprocess.check_output([*DOCKER, 'inspect', name], text=True, timeout=15))[0]
    if not info['State']['Running'] or info['Config']['Labels'].get('im.dinox.interop.run') != RUN:
        raise ValueError('Existing owned bridge must already be running')
    user = '0' if value['role'] == 'nora' else '1000:1000'
    result = subprocess.run([*DOCKER, 'exec', '-i', '--user', user, name, 'python3', '-c', CONTROL_CODE],
                            input=json.dumps(value), text=True, capture_output=True, timeout=value['wait'] + 45)
    # Never forward arbitrary stderr, which might include private file content.
    response = json.loads(result.stdout)
    print(json.dumps(response, ensure_ascii=False))
    return result.returncode


def parse_args():
    if sys.argv[1:] == ['--stdin']:
        raw = sys.stdin.read(32769)
        if len(raw) > 32768:
            raise ValueError('Request exceeds limit')
        return validate_envelope(json.loads(raw))
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='action', required=True)
    for action in ('state', 'command', 'result'):
        command = sub.add_parser(action)
        command.add_argument('role', type=str.lower, choices=('nora', 'leon', 'felix'))
        if action == 'command':
            command.add_argument('json', help='Explicit bridge command JSON; no config/secrets')
        if action == 'result':
            command.add_argument('id', help='UUID returned by command')
        command.add_argument('--wait', type=float, default=0, help='Result/state wait, 0–60 seconds')
        command.add_argument('--transport', choices=('server', 'local-android'), default='server')
    args = parser.parse_args()
    value = {'role': args.role, 'action': args.action, 'wait': args.wait, 'transport': args.transport}
    if args.action == 'command':
        value.update(id=uuid.uuid4().hex, payload=json.loads(args.json))
    if args.action == 'result':
        value['id'] = args.id
    return validate_envelope(value)


def main():
    value = None
    try:
        value = parse_args()
        if value['transport'] == 'local-android':
            return local_android(value)
        if str(Path(__file__).resolve()) == REMOTE:
            return server(value)
        result = subprocess.run(['ssh', '-p', '2654', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=12',
                                 HOST, 'python3 ' + REMOTE + ' --stdin'],
                                input=json.dumps(value), text=True, capture_output=True, timeout=value['wait'] + 75)
        response = json.loads(result.stdout)
        print(json.dumps(response, ensure_ascii=False))
        return result.returncode
    except Exception as error:
        response = {'ok': False, 'error': 'control_request_failed', 'error_type': type(error).__name__}
        if isinstance(value, dict):
            response.update(role=value.get('role'), id=value.get('id'), run_id=RUN,
                            submission_outcome_unknown=value.get('action') == 'command')
        print(json.dumps(response))
        return 2


if __name__ == '__main__':
    sys.exit(main())

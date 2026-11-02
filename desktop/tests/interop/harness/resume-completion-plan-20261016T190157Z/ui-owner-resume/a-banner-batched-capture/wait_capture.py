#!/usr/bin/env python3
"""Separate source-only owner derivative: capture first, unknown touch ownership stops input."""
import argparse, ast, hashlib, importlib.util, json, os, re, signal, subprocess, sys, time, uuid, shlex
from pathlib import Path
import xml.etree.ElementTree as ET
sys.dont_write_bytecode = True
assert not sys.flags.optimize
H = Path('/media/linux/SSD128/xmppwin/local/monocles-dinox-interop-20261015/harness')
sys.path.insert(0, str(H/'triple_v3/runtime_consent'))
import runtime as r
PURE = H/'triple_v3/normal_consent_ui/normal_ui_consent.py'
PURE_SHA = '59d623366d17a75d77c6afcc3269531ce6d313704b69d39de18cb9224fde3b8a'
assert r.sha(PURE) == PURE_SHA
spec = importlib.util.spec_from_file_location('historical_pure_ui_checks', PURE)
pure = importlib.util.module_from_spec(spec); spec.loader.exec_module(pure)
PQ = H/'triple_v3/public_ui_observer/public_ui_observer.py'
PQ_SHA = '4731f057bae30c207d6dcdd1c5ba411364a1b46969e4ca26d8758faa232dbde7'
assert r.sha(PQ) == PQ_SHA
ps = importlib.util.spec_from_file_location('historical_pure_public_checks',PQ)
pq = importlib.util.module_from_spec(ps); ps.loader.exec_module(pq)
PACKAGE = r.v1.PACKAGE
BASE = Path('/media/linux/SSD128/monocles-interop-runtime-20261015/triple-v3/fresh-startup-consent-preflight-20261016T180350Z/owner-ui-adapter/owner_ui.py')
BASE_SHA = '65b702c534dc2151590f14e99b2807ae33be6fb3748ec489f28d6eddcd1ea5ad'
MENU_LABELS = {
    'join': ('Join ongoing group call', 'Laufendem Gruppenanruf beitreten'),
    'rejoin': ('Rejoin previous group call', 'Vorherigem Gruppenanruf erneut beitreten'),
}
A_DIR = H/'devicefix_nora_runtime'
MIXED = H/'legacy3_mixed_consent/normal_mixed_ui_consent.py'
MIXED_SHA = '16b236d8a8f8b5cb645114de03cb02635bc524d56cd1fcfc0b27a8c32c7da942'
A_PINS = {
    'runtime.py':'3eb5100e0ddcaeb60f87929b01ff9e75e8e350eb7bf3b718d1ef2755bccbac31',
    'control.py':'96b54078b0b958d23b8f13f7546877ac0ee5f2c47c92ce368aacd2efe86b7617',
    'recorder.py':'416a89203a246dd481f8a79fd08dd930f6ed988d8eccceb5a12ed31bbdfb16b5',
    'freeze.json':'131aa89a08adf3075e7ddcbc62af03b4ac14a682e3df4547099cd6bd6ef7b294',
}

def visible_windows(raw):
    # Observation only. This exact block shape is covered by the retained real window fixture.
    marker = 'WINDOW MANAGER WINDOWS (dumpsys window windows)'
    if raw.count(marker) != 1:
        return {'status':'UNKNOWN', 'reason':'Missing/ambiguous window section'}
    section = raw.split(marker, 1)[1].split('\n  mGlobalConfiguration=', 1)[0]
    headers = list(re.finditer(r'(?m)^  Window #(\d+) Window\{([^ }]+) u(\d+) ([^\n]+)\}:$', section))
    if not headers or len(re.findall(r'(?m)^  Window #',section)) != len(headers):
        return {'status':'UNKNOWN', 'reason':'Unrecognized window block'}
    rows = []
    for index, header in enumerate(headers):
        block = section[header.end():headers[index+1].start() if index+1 < len(headers) else len(section)]
        fields = {}
        for key, pattern in (
            ('package', r'(?m)^    mOwnerUid=\d+[^\n]*\bpackage=([^\s]+)'),
            ('visible', r'(?m)^    isVisible=(true|false)$'),
            ('surface', r'(?m)^    mHasSurface=(true|false)\b'),
            ('uid', r'(?m)^    mOwnerUid=(\d+)\b'),
            ('display', r'(?m)^    mDisplayId=(\d+)\b')):
            values = re.findall(pattern, block)
            if len(values) != 1:
                return {'status':'UNKNOWN', 'reason':'Unrecognized/ambiguous window fields'}
            fields[key] = values[0]
        rows.append({'index':int(header[1]), 'token':header[2], 'user':int(header[3]),
                     'name':header[4], **fields})
    if [x['index'] for x in rows] != list(range(len(rows))):
        return {'status':'UNKNOWN', 'reason':'Incomplete/reordered window blocks'}
    return {'status':'OBSERVATION_ONLY', 'windows':rows,
            'visible_windows':[x for x in rows if x['visible']=='true'],
            'touch_ownership_proven':False}

def input_rectangle(raw):
    if raw=='<empty>':return None
    match=re.fullmatch(r'\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]',raw)
    if not match:raise ValueError('Unknown region format')
    rect=list(map(int,match.groups()))
    if not all(-16384<=v<=16384 for v in rect) or rect[0]>rect[2] or rect[1]>rect[3]:raise ValueError('Invalid rectangle')
    return rect

def parse_input_dispatcher(raw):
    try:
        if raw.count('Input Dispatcher State:\n')!=1:raise ValueError('Missing/ambiguous dispatcher')
        state=raw.split('Input Dispatcher State:\n',1)[1]
        for key,value in (('DispatchEnabled','true'),('DispatchFrozen','false'),('InputFilterEnabled','false'),('FocusedDisplayId','0')):
            if re.findall(r'(?m)^  '+key+r': (.+)$',state)!=[value]:raise ValueError('Unready dispatcher '+key)
        if re.findall(r'(?m)^  TouchStates: (.+)$',state)!=['<no displays touched>']:raise ValueError('Touch already active')
        focused=re.findall(r"(?m)^  FocusedWindows:\n    displayId=0, name='([^'\n]+)'\n  FocusRequests:",state)
        if len(focused)!=1:raise ValueError('Unknown focus representation')
        display=re.findall(r'(?m)^  Display: (\d+)\n    logicalSize=(\d+)x(\d+)\n        transform \(ROT_0\) \(IDENTITY\)\n    Windows:\n',state)
        if len(display)!=1 or display[0][0]!='0':raise ValueError('Unknown display/rotation')
        section=state.split('    Windows:\n',1)[1].split('  Global monitors on display 0:',1)
        if len(section)!=2:raise ValueError('Missing window section end')
        starts=list(re.finditer(r'(?m)^      (\d+): name=',section[0]));rows=[]
        allowed={'NOT_FOCUSABLE','TRUSTED_OVERLAY','SLIPPERY','DUPLICATE_TOUCH_TO_WALLPAPER',
                 'NO_INPUT_CHANNEL','NOT_TOUCHABLE','NOT_VISIBLE','PREVENT_SPLITTING','IS_WALLPAPER'}
        if not starts:raise ValueError('No dispatcher windows')
        for i,start in enumerate(starts):
            block=section[0][start.start():starts[i+1].start() if i+1<len(starts) else len(section[0])]
            line,transform=block.split('\n',1)
            match=re.fullmatch(r'      (\d+): name=([^,]+), id=(\d+), displayId=(\d+), inputConfig=([^,]+), alpha=([0-9.]+), frame=(\[[^,]+,-?\d+\]\[-?\d+,-?\d+\]), globalScale=([0-9.]+), applicationInfo.name=(.*), applicationInfo.token=(<null>|0x[0-9a-f]+), touchableRegion=(<empty>|\[-?\d+,-?\d+\]\[-?\d+,-?\d+\]), ownerPid=(\d+), ownerUid=(\d+), dispatchingTimeout=(\d+)ms, token=(0x[0-9a-f]+), touchOcclusionMode=(BLOCK_UNTRUSTED|USE_OPACITY)(?:, canOccludePresentation)?',line)
            if not match:raise ValueError('Unknown dispatcher window fields')
            index,name,wid,display_id,config,alpha,frame,scale,application,application_token,region,pid,uid,timeout,token,occlusion=match.groups()
            flags=set() if config=='0x0' else set(config.split(' | '))
            if 'WATCH_OUTSIDE_TOUCH' in flags:
                # Only the retained actual portrait SystemUI banner representation is known.
                if not (re.fullmatch('[0-9a-f]+ NotificationShade',name)
                        and flags=={'NOT_FOCUSABLE','TRUSTED_OVERLAY','WATCH_OUTSIDE_TOUCH'}
                        and uid=='10120' and int(pid)>0 and alpha==scale=='1'
                        and frame=='[0,0][1080,1920]' and region=='[42,0][1038,452]'
                        and application=='' and application_token=='<null>' and timeout=='5000'
                        and token!='0x0' and occlusion=='BLOCK_UNTRUSTED'):
                    raise ValueError('Unknown WATCH_OUTSIDE_TOUCH owner/geometry')
            elif flags-allowed:raise ValueError('Unknown flags')
            if int(index)!=i or display_id!='0':raise ValueError('Unknown order/display')
            mode=re.fullmatch(r'    transform \(ROT_0\) \((IDENTITY|TRANSLATE|SCALE TRANSLATE)\)\n(?:        [-0-9.]+  [-0-9.]+  [-0-9.]+\n){0,3}',transform)
            if not mode:raise ValueError('Unknown window transform')
            if 'WATCH_OUTSIDE_TOUCH' in flags and mode[1]!='IDENTITY':raise ValueError('Unknown banner transform')
            rows.append({'name':name,'wm_token':name.split(' ',1)[0],'index':i,'flags':sorted(flags),
                         'alpha':float(alpha),'frame':input_rectangle(frame),'scale':float(scale),
                         'region':None if flags&{'NO_INPUT_CHANNEL','NOT_VISIBLE'} else input_rectangle(region),
                         'pid':int(pid),'uid':int(uid),'token':token,'transform':mode[1]})
        return {'status':'PARSED','windows':rows,'focused':focused[0],'size':[int(display[0][1]),int(display[0][2])]}
    except (ValueError,IndexError,TypeError) as error:
        return {'status':'UNKNOWN','reason':str(error)}

def input_ownership(raw, windows, point, expected_package, expected_uid=None):
    result={'status':'UNKNOWN','reason':'No proved receiver','point':point,'expected_package':expected_package,
            'expected_uid':expected_uid,'tap_permitted':False}
    parsed=parse_input_dispatcher(raw)
    if parsed['status']!='PARSED':return {**result,'reason':parsed['reason']}
    if windows['status']!='OBSERVATION_ONLY':return {**result,'reason':'Unknown WindowManager stack'}
    def wm(row):
        matches=[w for w in windows['windows'] if w['token']==row['wm_token']]
        if len(matches)!=1 or matches[0]['visible']!='true' or matches[0]['surface']!='true' or int(matches[0]['uid'])!=row['uid']:
            raise ValueError('Input/visible WindowManager mismatch')
        return matches[0]
    try:
        focused=[r for r in parsed['windows'] if r['name']==parsed['focused']]
        if len(focused)!=1:return {**result,'reason':'Unknown focused receiver'}
        focused_wm=wm(focused[0])
        if focused_wm['package']!=expected_package or focused[0]['uid']!=expected_uid:
            return {**result,'status':'BLOCKED','reason':'Different focused owner','receiver':focused[0],'window':focused_wm}
        if point is None:return {**result,'reason':'A fresh semantic target point is required'}
        if type(expected_uid) is not int or expected_uid<=0:return {**result,'reason':'Expected package UID not bound'}
        x,y=point
        if not (0<=x<parsed['size'][0] and 0<=y<parsed['size'][1]):return {**result,'reason':'Point outside display'}
        for row in parsed['windows']:
            region=row['region'];frame=row['frame'];flags=set(row['flags'])
            if row['alpha']==0 or 'NO_INPUT_CHANNEL' in flags or 'NOT_VISIBLE' in flags:continue
            if 'NOT_TOUCHABLE' in flags:
                if frame and frame[0]<=x<frame[2] and frame[1]<=y<frame[3] and 'TRUSTED_OVERLAY' not in flags:
                    return {**result,'status':'BLOCKED','reason':'Untouchable occluding surface'}
                continue
            if not region or not (region[0]<=x<region[2] and region[1]<=y<region[3]):continue
            visible=wm(row)
            if visible['package']!=expected_package or row['uid']!=expected_uid:
                return {**result,'status':'BLOCKED','reason':'Different top touch receiver','receiver':row,'window':visible}
            if not frame or not (frame[0]<=x<frame[2] and frame[1]<=y<frame[3]):
                return {**result,'reason':'Target lies outside actual receiver frame'}
            if row['scale']!=1 or row['transform'] not in ('IDENTITY','TRANSLATE') or row['token']=='0x0' or row['alpha']!=1:
                return {**result,'reason':'Unknown receiver transform/opacity/channel'}
            channel=re.findall(r"(?m)^    \d+: channelName='"+re.escape(row['name'])+r" \(server\)', status=NORMAL, monitor=false, responsive=true$",raw)
            if len(channel)!=1:return {**result,'reason':'Receiver connection is not proved responsive'}
            return {**result,'status':'PROVEN_RECEIVER','reason':'Fresh top touch region and focused package owner agree',
                    'receiver':row,'window':visible,'tap_permitted':True}
        return {**result,'reason':'No touch receiver at target'}
    except (ValueError,TypeError) as error:return {**result,'reason':str(error)}

def combined_windows_input(raw):
    markers=('__OWNER_WINDOWS_BEGIN__\n','__OWNER_INPUT_BEGIN__\n','__OWNER_QUERY_END__\n')
    if any(raw.count(m)!=1 for m in markers) or not raw.startswith(markers[0]) or not raw.endswith(markers[2]):
        raise AssertionError('Incomplete combined read-only window/input query')
    windows,tail=raw[len(markers[0]):].split(markers[1])
    return windows,tail[:-len(markers[2])]

def systemui_wait_node(tree):
    titles=[n for n in tree.iter('node') if n.get('resource-id')=='android:id/alertTitle']
    assert len(titles)==1 and titles[0].get('package')=='android' and titles[0].get('text')=="System UI isn't responding"
    matches=[n for n in tree.iter('node') if n.get('package')=='android' and n.get('resource-id')=='android:id/aerr_wait'
             and n.get('text')=='Wait' and n.get('clickable')=='true' and n.get('enabled')=='true']
    assert len(matches)==1
    rect=input_rectangle(matches[0].get('bounds',''));assert rect and 0<=rect[0]<rect[2]<=4096 and 0<=rect[1]<rect[3]<=4096
    return {'resource':'android:id/aerr_wait','text':'Wait','bounds':rect,'point':[(rect[0]+rect[2])//2,(rect[1]+rect[3])//2]}

def capture_state_reusable(transaction, session, target, capture_id, now_monotonic, now_unix):
    assert transaction['id']==capture_id and transaction['target']==target, 'Capture/action/target changed'
    assert transaction['session']==session, 'Exact owner session changed during capture'
    assert 0<=now_monotonic-transaction['observed_monotonic']<=5, 'Capture state transaction expired'
    assert 0<=now_unix-transaction['state']['time_ms']/1000<=5, 'Actual cached Bridge state expired'
    return True

def toolbar_navigation(tree):
    bars = [n for n in tree.iter('node') if n.get('package')==PACKAGE
            and n.get('resource-id')==PACKAGE+':id/toolbar']
    assert len(bars)==1, 'Actual unique app toolbar required'
    candidates = [n for n in bars[0].iter('node') if n.get('package')==PACKAGE
                  and n.get('class')=='android.widget.ImageButton'
                  and n.get('content-desc')=='Navigate up' and n.get('clickable')=='true'
                  and n.get('enabled')=='true' and n.get('visible-to-user','true')=='true']
    assert len(candidates)==1, 'Actual toolbar Navigate up required; BACK is not navigation proof'
    node = candidates[0]
    match = re.fullmatch(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]', node.get('bounds',''))
    assert match, 'Missing semantic navigation bounds'
    left,top,right,bottom = map(int,match.groups())
    assert 0 <= left < right <= 4096 and 0 <= top < bottom <= 4096
    return {'resource':node.get('resource-id'), 'text':node.get('text'),
            'content_desc':node.get('content-desc'), 'bounds':[left,top,right,bottom],
            'point':[(left+right)//2,(top+bottom)//2]}

def actual_menu_choice(tree, action):
    labels = MENU_LABELS[action]
    choices = [n for n in tree.iter('node') if n.get('package')==PACKAGE
               and n.get('resource-id')==PACKAGE+':id/title' and n.get('text') in labels]
    assert len(choices)==1, 'Actual unique JOIN/REJOIN popup choice required; never retap parent'
    return pure.ui.select_node(tree,'title',choices[0].get('text'))

def actual_confirmation(tree,admission,role):
    # UIAutomator omits GONE/empty detail containers. Never interpret other content as an empty card.
    assert not any(n.get('resource-id')=='android:id/alertTitle'for n in tree.iter('node'))
    assert any(n.get('package')==PACKAGE and n.get('text')in pure.TITLES[admission['mode']]for n in tree.iter('node'))
    assert not any(n.get('checkable')=='true'or n.get('class','').endswith(('CheckBox','Switch'))for n in tree.iter('node'))
    forbidden=('own_keys_card','exclude_keyless','key_error_message_card','disable_button','axolotl_fingerprint')
    assert not any(pure.nodes(tree,name)for name in forbidden)
    cards=pure.nodes(tree,'foreign_keys_card');assert len(cards)==2;found=[]
    for card in cards:
        titles=pure.nodes(card,'foreign_keys_title');info=pure.nodes(card,'no_keys_to_accept');details=pure.nodes(card,'foreign_keys_details')
        assert len(titles)==len(info)==1 and len(details)<=1
        assert not details or not list(details[0])
        allowed={'',PACKAGE+':id/foreign_keys_card',PACKAGE+':id/foreign_keys_title',PACKAGE+':id/no_keys_to_accept',PACKAGE+':id/foreign_keys_details'}
        assert all(n.get('resource-id','')in allowed for n in card.iter('node'))
        assert all(not n.get('text')or n in(titles[0],info[0])for n in card.iter('node'))
        for n in card.iter('node'):
            if not n.get('resource-id'):
                assert n.get('class')in('android.widget.LinearLayout','android.widget.FrameLayout','android.widget.RelativeLayout')
                assert n.get('clickable')=='false'and not n.get('content-desc')
        jid=titles[0].get('text');assert jid in {r.OWN[p]for p in r.ROLES if p!=role}
        assert info[0].get('text')in {s.format(admission['display_names'][jid])for s in pure.CONFIRM}
        found.append(jid)
    assert len(set(found))==2 and set(found)=={r.OWN[p]for p in r.ROLES if p!=role}
    done=pure.button(tree,'save_button');assert done['text']in('Done','Fertig');return done

def focused_activity(raw):
    # Current/resumed records only: stopped ACTIVITY tasks are not focus evidence.
    patterns = (r'(?m)^\s*topResumedActivity\s*[:=]\s*ActivityRecord\{[^\n]*?\bu\d+\s+([^\s}]+)',
                r'(?m)^\s*mResumedActivity\s*[:=]\s*ActivityRecord\{[^\n]*?\bu\d+\s+([^\s}]+)')
    for pattern in patterns:
        values = set(re.findall(pattern, raw))
        if values:
            assert len(values) == 1, 'Ambiguous focused/resumed Activity'
            component = values.pop(); package, name = component.split('/', 1)
            return package + '/' + (package + name if name.startswith('.') else name)
    raise AssertionError('No actual focused/resumed Activity evidence')

def binary_capture_frame(payload):
    # Fixed bytes boundaries: never decode PNG bytes as text.
    begin=b'__OWNER_PNG_BEGIN__\n';end=b'\n__OWNER_PNG_END__\n'
    assert payload.startswith(begin) and payload.count(begin)==payload.count(end)==1, 'Incomplete/ambiguous binary capture frame'
    png,combined=payload[len(begin):].split(end)
    assert png.startswith(b'\x89PNG\r\n\x1a\n') and len(png)<=12*1024**2, 'Invalid/bounded PNG required'
    windows,input_raw=combined_windows_input(combined.decode('utf-8'))
    return png,windows,input_raw

class OwnerUI:
    def __init__(self, admission_path):
        self.a = r.probe.private_json(admission_path); a = self.a
        self.profile = a['runtime_profile']; assert self.profile=='A' and a['action'] in ('capture-only','systemui-wait')
        self.owner_runtime = r
        if self.profile=='A':
            # A uses the real frozen recorder subprocess and an exact session binding.
            # Never call A.control_settings(), _old_control_settings() or historical MixedUI here.
            assert a['role']=='nora' and a['action'] in ('capture-only','systemui-wait','consent','resume-consent','own-pq')
            assert {name:r.sha(A_DIR/name) for name in A_PINS}==A_PINS
            spec = importlib.util.spec_from_file_location('owner_capture_profile_A',A_DIR/'runtime.py')
            self.owner_runtime = importlib.util.module_from_spec(spec);spec.loader.exec_module(self.owner_runtime)
        assert r.sha(BASE)==BASE_SHA
        self.role = a['role']; assert self.role in r.ROLES
        assert a['operation'] == 'owner-normal-ui-adapter' and a['schema_version'] == 1
        assert a['adapter_sha256'] == r.sha(Path(__file__)) and a['pure_checks_sha256'] == PURE_SHA
        assert a['public_checks_sha256'] == PQ_SHA
        assert a['runtime_freeze_sha256'] == self.owner_runtime.frozen_files()
        assert a['run_id'] == r.RUN and a['accounts'] == r.OWN and a['no_trust_changes_authorized'] is True
        assert a['action'] in ('capture-only','systemui-wait','consent','resume-consent','join','rejoin','own-pq') and a['mode'] in ('legacy','omemo2')
        assert a['action'] not in ('own-pq','join','rejoin'), 'PQUI/notification/JOIN input route not admitted by this narrow derivative'
        if a['action'] not in ('capture-only','systemui-wait'):
            assert type(a['app_uid']) is int and a['app_uid']>=10000, 'Actual package UID must be Root-bound'
        if a['action']=='own-pq':assert a['mode']=='omemo2' and a['profiles_already_PQ_initialized'] is True
        assert re.fullmatch('[0-9a-f]{32}',a['batch_id'])
        if self.profile=='B':assert a['room']=='interop-three-71115b-8df83d69736d9417@conference.dinox.im'
        else:assert re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,128}@conference\.dinox\.im',a['room'])
        assert all(re.fullmatch('[0-9a-f-]{36}',v)for v in a['conversation_uuids'].values())
        assert set(a['identities']) == set(r.ROLES)
        assert set(a['conversation_uuids']) == (set(r.ROLES) if self.profile=='B' else {'nora'})
        if self.profile=='A':
            assert a['identities']['leon']['device_id']==172062497
            assert a['identities']['felix']['device_id']==1228426141
            if a['action'] in ('consent','resume-consent'):
                assert a['mode']=='legacy'
                assert set(a['call_ids'])==set(a['full_jids'])==set(r.ROLES)
                assert set(a['sids'])=={'nora:leon','nora:felix','leon:felix'}
                assert len(set(a['sids'].values()))==3 and all(a['sids'].values())
                assert all(a['call_ids'].values())
                for peer in r.ROLES:
                    assert a['full_jids'][peer].startswith(r.OWN[peer]+'/')
                    assert a['full_jids'][peer].split('/',1)[1]
                    assert a['identities'][peer]['account']==r.OWN[peer]
                    assert re.fullmatch('05[0-9a-f]{64}',a['identities'][peer]['legacy_fingerprint'])
                assert re.fullmatch('[0-9]{8}T[0-9]{6}Z-[0-9a-f]{32}',a['native_recording'])
        assert re.fullmatch('[0-9a-f]{32}', a['nonce'])
        assert 0 <= time.time()-a['created_unix'] <= 120 and time.time() < a['expires_unix'] <= a['created_unix']+240
        assert os.getpriority(os.PRIO_PROCESS,0) == 19
        if self.profile=='B':
            for peer in r.ROLES:
                assert r.verify_live(peer,a['batch_id'],a['runtime_freeze_sha256'])['public_identity']==a['identities'][peer]
        self.session = self.session_now()
        self.out = Path(admission_path).parent/('actual-owner-ui-'+self.role+'-'+a['nonce'])
        self.out.mkdir(mode=0o700)
        self.sent = self.confirmed = self.choice_submitted = False
        self.last_capture = None
        self.pending_input = None
        self.systemui_wait_submitted = False
        self.capture_transaction = None
        self.active_capture_id = None
        self.last_native = None
        if self.profile=='A' and a['action'] in ('consent','resume-consent'):
            self.prepare_mixed_checks()
        self.recording = self.rec({'action':'begin','label':'SEPARATE-owner-normal-UI-adapter'})
        r.v1.write(self.out/'scope.json', {'admission_path':str(admission_path),'admission_sha256':r.sha(admission_path),
            'adapter_sha256':r.sha(Path(__file__)),'pure_checks_sha256':PURE_SHA,'session':self.session,
            'historical_59d_runner_used':False,'action':a['action']})

    def prepare_mixed_checks(self):
        # Extract only pure definitions, never the historical active bindings/UI class.
        assert r.sha(MIXED)==MIXED_SHA
        parsed = ast.parse(MIXED.read_text())
        definitions = [n for n in parsed.body if isinstance(n,ast.FunctionDef)
                       and n.name in ('exact','active_scope','native_receipt')]
        assert len(definitions)==3
        context = {'RUN':r.RUN,'OWN':r.OWN,'ROLES':r.ROLES,
                   'PAIRS':('nora:leon','nora:felix','leon:felix'),'c':pure}
        exec(compile(ast.Module(body=definitions,type_ignores=[]),str(MIXED),'exec'),context)
        self.active_scope_check, self.native_receipt_check = context['active_scope'], context['native_receipt']
        native = self.a['native_bindings']; directory = Path(native['directory']).resolve(strict=True)
        assert directory.is_relative_to(H) and directory!=H
        assert r.sha(directory/'native_control.py')==native['control_sha256']
        assert r.sha(directory/'native_recorder.py')==native['recorder_sha256']
        # These modules never create an SDK child; the recorder delegates exact native state over SSH.
        assert 'native_control' not in sys.modules, 'Unexpected preloaded native controller'
        spec = importlib.util.spec_from_file_location('native_control',directory/'native_control.py')
        control = importlib.util.module_from_spec(spec);sys.modules['native_control']=control;spec.loader.exec_module(control)
        assert control.admission(native['admission_sha256'])==native['owner_admission']
        spec = importlib.util.spec_from_file_location('owner_native_state_recorder',directory/'native_recorder.py')
        self.native_recorder = importlib.util.module_from_spec(spec);spec.loader.exec_module(self.native_recorder)
        assert Path(self.native_recorder.native_control.__file__).resolve()==directory/'native_control.py'
        self.native_recorder.ADMISSION_SHA = native['admission_sha256']

    def mixed_scope(self, nora):
        previous = self.last_native; peers = {}
        for peer in ('leon','felix'):
            record = self.native_recorder.server({'action':'state','role':peer,'transport':'server','wait':0,
                'recording':self.a['native_recording'],'tag':'owner-mixed-readonly-'+uuid.uuid4().hex,'local_recording':True})
            assert record['controller_exit']==0 and record['observation'].get('completed')
            peers[peer] = record['observation']['response']
            identity = self.a['identities'][peer]; value = peers[peer]
            assert value['own_omemo_device_id']==identity['device_id']
            assert value['own_public_identity_hex']==identity['legacy_fingerprint']
        scope = dict(self.a,conversation_uuid=self.a['conversation_uuids']['nora'])
        room = self.active_scope_check(nora,peers,scope,time.time())
        if previous is not None:
            for peer in ('leon','felix'):
                old = {s['sid']:s['audio_sink_samples'] for s in previous[peer]['sessions']
                       if s.get('wire_state') in ('ACTIVE','DINO_PLUGINS_GOOGLE_WEBRTC_SIGNALING_STATE_ACTIVE')}
                for row in peers[peer]['sessions']:
                    if row.get('wire_state') in ('ACTIVE','DINO_PLUGINS_GOOGLE_WEBRTC_SIGNALING_STATE_ACTIVE'):
                        assert row['audio_sink_samples']>old[row['sid']], 'Stale/stalled actual native state'
        self.last_native = peers
        r.v1.write(self.out/('actual-mixed-scope-'+str(time.time_ns())+'.json'),{'nora':nora,'native':peers})
        return room

    def room(self, state, role):
        if self.profile=='A' and self.a['action'] in ('consent','resume-consent'):
            assert role=='nora' and self.last_native is not None
            return self.active_scope_check(state,self.last_native,
                dict(self.a,conversation_uuid=self.a['conversation_uuids']['nora']),time.time())
        return pure.room_state(state,role,self.a,time.time())

    def session_now(self):
        a = self.a
        if self.profile=='B':
            value = r.verify_live(self.role,a['batch_id'],a['runtime_freeze_sha256'])
            assert value['public_identity']==a['identities'][self.role]
            return value
        value = r.probe.private_json(self.owner_runtime.role_config('nora')['state']/'live-session.json')
        assert value['schema_version']==2 and value['state']=='running' and value['ready'] is True
        assert value['run_id']==r.RUN and value['role']=='nora' and value['batch_id']==a['batch_id']
        assert value['freeze_sha256']==a['runtime_freeze_sha256']==A_PINS['freeze.json']
        assert value['apk_sha256']==self.owner_runtime.APKS and value['guest_memory_mib']==2048
        assert value['inputs_sha256']==r.sha(r.ROOT/'runtime-inputs.json')
        assert time.time()<value['batch_deadline_unix']
        keys = {'controller_pid','controller_start_ticks','adb_pid','adb_start_ticks',
                'emulator_pid','emulator_start_ticks','adb_cgroup','approval_sha256'}
        assert set(a['session_binding'])==keys
        assert {k:value[k] for k in keys}==a['session_binding'], 'Exact A owner changed'
        assert value['native_readonly_bindings']==a['native_bindings'], 'A native owner admission changed'
        assert set(a['process_cgroups'])=={'controller','adb','emulator'}
        for name in ('controller','adb','emulator'):
            assert r.v1.start_ticks(value[name+'_pid'])==value[name+'_start_ticks']
            group = r.v1.process_cgroup(value[name+'_pid'])
            assert group==a['process_cgroups'][name] and r.v1.SLICE in Path(group).parts
        assert a['process_cgroups']['adb']==value['adb_cgroup']
        assert value['adb_sha256']==r.sha(r.ROOT/'sdk/platform-tools/adb')
        return value

    def rec(self, value):
        if self.profile=='A':
            # This is the actual frozen recorder process; its own caller guard remains effective.
            argv = ['/usr/bin/python3','-B',str(A_DIR/'recorder.py'),value['action']]
            if value['action']=='begin':argv += [value['label']]
            else:
                assert value['action']=='state' and value['role']=='nora' and value['wait']==0
                argv += [value['recording'],value['tag'],'nora','--transport','local-android','--wait','0']
            data = None
        else:
            argv = ['/usr/bin/python3','-B',str(r.HERE/'recorder.py'),'--stdin']; data = json.dumps(value).encode()
        c = subprocess.run(argv,input=data,
            stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=35)
        assert c.returncode == 0, 'Existing recorder failed; never replay command'
        return json.loads(c.stdout)

    def android_state(self, role):
        assert time.time() < self.a['expires_unix']
        event = self.rec({'action':'state','recording':self.recording['recording'],'role':role,
            'transport':'local-android','tag':'owner-normal-ui-current-scope','wait':0})
        o = event['observation']; assert o['completed']
        state = o['response']
        assert state['run_id']==r.RUN and state['account']==r.OWN[role] and state['online'] is True
        assert state['service_bound'] is True and 0 <= time.time()-state['time_ms']/1000 <= 10
        assert r.public_identity(state)==self.a['identities'][role]
        r.v1.write(self.out/('actual-'+role+'-'+str(time.time_ns())+'.json'),event)
        return state

    def state(self, role):
        self.capture_transaction=None;self.active_capture_id=None
        state = self.android_state(role)
        if self.profile=='A' and self.a['action'] in ('consent','resume-consent'):self.mixed_scope(state)
        else:self.room(state,role)
        return state

    def adb(self, tail, label, not_after=None):
        # All tails are fixed below; no CLI raw command/coordinates and no parent-policy change.
        # No command can bypass the missing InputDispatcher proof through a raw input call.
        proof = None
        if 'input' in tail[:3]:
            proof = getattr(self,'pending_input',None);self.pending_input=None
            assert proof and proof['tail']==tail and proof['capture_id']==self.last_capture['id'], 'No exact unused input proof'
            assert time.monotonic()<=proof['expires'], 'Input proof expired; never replay'
            assert not_after==proof['expires']
        assert time.time() < self.a['expires_unix']
        s = self.session_now()
        for key in ('controller_pid','controller_start_ticks','adb_pid','adb_start_ticks'):
            assert s[key] == self.session[key]
        if self.profile=='A':
            # Keep all host/source ownership checks live for every child. Only the redundant
            # Bridge-state SDK read is reused inside one exact, at-most-five-second transaction.
            r.v1.resources()
            assert self.owner_runtime.frozen_files()==self.a['runtime_freeze_sha256']
            assert {name:r.sha(A_DIR/name) for name in A_PINS}==A_PINS
            transaction=getattr(self,'capture_transaction',None)
            if transaction:
                capture_state_reusable(transaction,s,self.capture_target(),self.active_capture_id,time.monotonic(),time.time())
            else:self.android_state('nora')
            cfg = self.owner_runtime.role_config('nora')
        else:cfg = r.control_settings(self.role)
        child = None; begin = None
        r.v1.write(self.out/(label+'-intent.json'),{'tail':tail,'unix':time.time(),'one_attempt':True})
        try:
            with r.inventory_lock():
                begin = time.monotonic()
                r.v1.require_adb_ready(s['adb_pid'],s['adb_start_ticks'],cfg['adb_port'],s['adb_sha256'],s['adb_cgroup'])
                if not_after is not None:assert time.monotonic()<=not_after,'Bounds expired before actual dispatch'
                if proof:assert time.monotonic()<=proof['expires'], 'Input proof expired before actual child'
                child = subprocess.Popen([*self.owner_runtime.adb_command(self.role),*tail],env=self.owner_runtime.environment(self.role),stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
                ticks = None
                try:
                    ticks = r.v1.start_ticks(child.pid)
                    out,err = child.communicate(timeout=max(.01,3.8-(time.monotonic()-begin)))
                    assert child.returncode == 0, 'Own normal UI command failed; no automatic retry'
                    assert len(out) <= 12*1024**2
                    return out
                finally:
                    if child.poll() is None:
                        # This unreaped Popen child cannot have its PID reused, even if initial /proc read failed.
                        if ticks is not None:assert r.v1.start_ticks(child.pid) == ticks
                        child.terminate()
                        try: child.wait(timeout=.12)
                        except subprocess.TimeoutExpired:
                            if ticks is not None:assert r.v1.start_ticks(child.pid) == ticks
                            child.kill(); child.wait(timeout=.2)
                    assert child.poll() is not None and time.monotonic()-begin < 5
        finally:
            r.v1.write(self.out/(label+'-result.json'),{'child_pid':child.pid if child else None,
                'exit':child.poll() if child else None,'child_dead_before_unlock':child is not None and child.poll() is not None,
                'lock_elapsed_seconds':time.monotonic()-begin if begin else None,'automatic_retry':False})

    def activity(self, expected, label):
        self.capture_transaction=None;self.active_capture_id=None
        raw = self.adb(['shell','-T','dumpsys','activity','activities'],label).decode(errors='replace')
        (self.out/(label+'.txt')).write_text(raw); (self.out/(label+'.txt')).chmod(0o600)
        assert focused_activity(raw) == PACKAGE+'/eu.siacs.conversations.ui.'+expected

    def capture_target(self):
        return {key:self.a.get(key) for key in ('action','role','nonce','room','mode','conversation_uuids','call_ids','sids')}

    def dump(self, label):
        self.capture_transaction=None;self.active_capture_id=None
        # Activity is diagnostic and deliberately outside the unchanged five-second touch interval.
        diagnostic = self.adb(['shell','-T','dumpsys','activity','activities'],label+'-activity')
        p=self.out/(label+'-activity.txt');p.write_bytes(diagnostic);p.chmod(0o600)
        capture_id=uuid.uuid4().hex
        if self.profile=='A':
            state=self.android_state('nora');observed=time.monotonic()
            assert 0<=time.time()-state['time_ms']/1000<=5
            self.active_capture_id=capture_id
            self.capture_transaction={'id':capture_id,'target':json.loads(json.dumps(self.capture_target())),
                'session':self.session_now(),'observed_monotonic':observed,'state':state}
        guest='/data/local/tmp/interop-owner-'+uuid.uuid4().hex+'.xml'
        assert re.fullmatch('/data/local/tmp/interop-owner-[0-9a-f]{32}\\.xml',guest)
        xml_script = "set -eu\ntrap 'rm -f "+guest+"' EXIT\nuiautomator dump "+guest+" >/dev/null\nprintf '__OWNER_XML_BEGIN__\\n'\ncat "+guest+"\nprintf '\\n__OWNER_XML_END__\\n'\n"
        started=time.monotonic()  # Before UIAutomator starts, including the owner-validation overhead.
        framed=self.adb(['shell','-T',xml_script],label+'-xml-dump-read-remove')
        prefix=b'__OWNER_XML_BEGIN__\n';suffix=b'\n__OWNER_XML_END__\n'
        assert framed.startswith(prefix) and framed.endswith(suffix) and framed.count(prefix)==framed.count(suffix)==1
        raw=framed[len(prefix):-len(suffix)];stamp=time.monotonic()
        tree=ET.fromstring(raw);pq.safe_capture(tree)
        p=self.out/(label+'.xml');p.write_bytes(raw);p.chmod(0o600)
        query="set -eu\nprintf '__OWNER_PNG_BEGIN__\\n'\nscreencap -p\nprintf '\\n__OWNER_PNG_END__\\n'\nprintf '__OWNER_WINDOWS_BEGIN__\\n'\ndumpsys window windows\nprintf '__OWNER_INPUT_BEGIN__\\n'\ndumpsys input\nprintf '__OWNER_QUERY_END__\\n'\n"
        payload=self.adb(['exec-out',shlex.join(['sh','-c',query])],label+'-binary-png-window-input')
        png,window_raw,input_raw=binary_capture_frame(payload)
        p=self.out/(label+'.png');p.write_bytes(png);p.chmod(0o600)
        for kind,value in (('windows',window_raw),('input',input_raw)):
            p=self.out/(label+'-'+kind+'.txt');p.write_text(value);p.chmod(0o600)
        windows=visible_windows(window_raw);finished=time.monotonic()
        self.last_capture={'id':capture_id,'tree':tree,'stamp':stamp,'started':started,'finished':finished,
                           'label':label,'input':input_raw,'windows':windows}
        r.v1.write(self.out/(label+'-window-observation.json'),windows)
        r.v1.write(self.out/(label+'-capture.json'),{'started_monotonic':started,'finished_monotonic':finished,
            'XML_monotonic':stamp,'snapshot_is_atomic':False,'activity_diagnostic_outside_touch_interval':True,
            'freshness_begins_before_UIAutomator_dump':True,'actual_evidence_period_seconds':finished-started,
            'within_unchanged_five_second_limit':finished-started<=5,'input_or_banner_action_submitted':False})
        return tree,stamp

    def require_touch(self, tree, stamp, node, label, package=PACKAGE, uid=None, window_name=None):
        capture=self.last_capture
        assert capture and capture['tree'] is tree and capture['stamp']==stamp
        if self.profile=='A':
            assert self.capture_transaction and self.capture_transaction['id']==capture['id']==self.active_capture_id
        uid=self.a.get('app_uid') if uid is None else uid
        decision=input_ownership(capture['input'],capture['windows'],node['point'],package,uid)
        decision['evidence_age_seconds']=time.monotonic()-capture['started']
        r.v1.write(self.out/(label+'-touch-decision.json'),decision)
        assert 0<=time.monotonic()-capture['started']<=5, 'Evidence expired from UIAutomator dump start'
        assert decision['tap_permitted'] is True, 'No proved fresh input receiver; no input'
        if window_name:assert decision['window']['name']==window_name, 'Wrong exact semantic window'
        return decision

    def submit_semantic(self, tree, stamp, node, tail, label, package=PACKAGE, uid=None, window_name=None):
        if tail[:4]==['shell','-T','input','tap']:
            assert tail==['shell','-T','input','tap',*[str(x) for x in node['point']]]
        elif tail[:4]==['shell','-T','input','text']:
            assert label=='normal-input-new-token-once' and len(tail)==5 and re.fullmatch('[A-Za-z0-9:-]+',tail[4])
            assert node['resource']==PACKAGE+':id/textinput'
            fields=pure.nodes(tree,'textinput');assert len(fields)==1 and fields[0].get('focused')=='true'
            assert fields[0].get('class')=='android.widget.EditText'
        else:raise AssertionError('Keyevent/swipe/raw input has no reviewed semantic proof route')
        decision=self.require_touch(tree,stamp,node,label,package,uid,window_name)
        assert self.pending_input is None, 'Previous input proof cannot be replaced'
        expiry=self.last_capture['started']+5
        self.pending_input={'tail':list(tail),'expires':expiry,'capture_id':self.last_capture['id']}
        r.v1.write(self.out/(label+'-before-input.json'),{**node,'proof':decision,'automatic_retry':False,'one_attempt':True})
        if label=='normal-choice-once':
            assert self.choice_submitted is False;self.choice_submitted=True
        if label=='systemui-normal-Wait-once':
            assert self.systemui_wait_submitted is False;self.systemui_wait_submitted=True
        try:self.adb(tail,label,not_after=expiry)
        finally:self.capture_transaction=None;self.active_capture_id=None

    def tap(self, tree, stamp, resource, label, text=None):
        node=pure.ui.select_node(tree,resource,text)
        self.submit_semantic(tree,stamp,node,['shell','-T','input','tap',*[str(x) for x in node['point']]],label)

    def type_token(self, token):
        assert re.fullmatch('[A-Za-z0-9:-]+',token)
        tree,stamp=self.dump('fresh-focused-empty-composer-before-token')
        node=pure.ui.select_node(tree,'textinput');pure.conversation_ui(tree,self.a,node['text'])
        assert node['text'] in ('',self.a['empty_composer_hint'])
        fields=pure.nodes(tree,'textinput');assert len(fields)==1
        assert fields[0].get('class')=='android.widget.EditText' and fields[0].get('focused')=='true', 'Actual focused editor required'
        self.submit_semantic(tree,stamp,node,['shell','-T','input','text',token],'normal-input-new-token-once')

    def run(self):
        a = self.a
        if a['action'] in ('capture-only','systemui-wait'):
            # Current surface only: no VIEW, focus, notification, toolbar, keyboard or JOIN action.
            self.android_state(self.role)  # Own account/identity only; no room or peer-trust prerequisite.
            tree,stamp = self.dump('actual-current-surface-capture-only')
            if a['action']=='systemui-wait':
                node=systemui_wait_node(tree)
                self.submit_semantic(tree,stamp,node,['shell','-T','input','tap',*[str(x) for x in node['point']]],
                    'systemui-normal-Wait-once',package='android',uid=1000,
                    window_name='Application Not Responding: com.android.systemui')
                return {'result':'SYSTEMUI_NORMAL_WAIT_SUBMITTED_ONCE','systemui_responsive_after_action_proven':False,
                        'room_or_call_action_submitted':False,'JOIN_submission_may_have_happened':False}
            decision = input_ownership(self.last_capture['input'],self.last_capture['windows'],None,PACKAGE,self.a.get('app_uid'))
            self.capture_transaction=None;self.active_capture_id=None
            r.v1.write(self.out/'capture-only-touch-decision.json',decision)
            return {'result':'CAPTURE_ONLY_INPUT_UNKNOWN_NO_ACTION','runtime_profile':self.profile,
                    'touch_decision':decision,'normal_UI_input_submitted':False,
                    'JOIN_submission_may_have_happened':False}
        roles = r.ROLES if self.profile=='B' and a['action'] in ('consent','resume-consent') else (self.role,)
        before = {role:self.state(role)for role in roles}
        pure.trusted_legacy_peers(before[self.role],self.role,a)
        token = r.RUN+':owner-ui-consent:'+self.role+':'+a['nonce']
        if a['action']=='resume-consent':
            scope_path=Path(a['resume_scope']['path']);assert scope_path.resolve().is_relative_to(r.ROOT)
            assert r.sha(scope_path)==a['resume_scope']['sha256']
            old_scope=r.probe.private_json(scope_path);old_path=Path(old_scope['admission_path'])
            assert r.sha(old_path)==old_scope['admission_sha256'];old=r.probe.private_json(old_path)
            partial=scope_path.parent/'partial.json';assert r.sha(partial)==a['resume_partial_sha256']
            prior=r.probe.private_json(partial)
            assert prior['sent_submission_may_have_happened']is True and prior['Done_submission_may_have_happened']is False
            for field in('batch_id','identities','conversation_uuids','room','role','mode','room_title','display_names'):
                assert old[field]==a[field]
            if self.profile=='A':
                for field in ('runtime_profile','session_binding','process_cgroups','native_bindings','native_recording','call_ids','full_jids','sids'):
                    assert old[field]==a[field]
            token=r.RUN+':owner-ui-consent:'+self.role+':'+old['nonce']
            assert a['resume_token']==token
            before_xml=Path(a['resume_before_send_xml']['path'])
            assert before_xml.parent==scope_path.parent and r.sha(before_xml)==a['resume_before_send_xml']['sha256']
            pure.conversation_ui(ET.fromstring(before_xml.read_bytes()),old,token)
            self.sent=True
            return self.finish_consent(token)
        for role,state in before.items():
            assert not any(m['text']==token for m in self.room(state,role)['test_messages'])
        if self.profile=='A' and a['action']=='consent':
            assert all(self.native_receipt_check(value,token,a['room'],None) is None for value in self.last_native.values())
        self.adb(['shell','-T','su','0','am','start','-n',PACKAGE+'/eu.siacs.conversations.ui.ConversationsActivity',
            '-a','eu.siacs.conversations.action.VIEW','--es','conversationUuid',a['conversation_uuids'][self.role]],'normal-room-UUID-VIEW-once')
        self.activity('ConversationsActivity','actual-focused-room')
        if a['action']=='own-pq':return self.own_pq()
        if a['action'] != 'consent':
            tree,stamp = self.dump('room-before-menu'); pure.conversation_ui(tree,a,pure.ui.select_node(tree,'textinput')['text'])
            self.tap(tree,stamp,'action_group_call','normal-parent-menu-once')
            tree,stamp = self.dump('actual-menu-choice')
            text = actual_menu_choice(tree,a['action'])['text']
            assert self.choice_submitted is False, 'At most one normal JOIN choice'
            self.tap(tree,stamp,'title','normal-choice-once',text)
            return {'result':'OWNER_NORMAL_UI_CHOICE_SUBMITTED_ONLY','choice':a['action']}
        tree,stamp = self.dump('before-composer')
        # Never clear/replace a draft. Exact post-input token also distinguishes a real draft from a displayed hint.
        empty = pure.ui.select_node(tree,'textinput')['text']
        assert empty in ('',a['empty_composer_hint'])
        pure.conversation_ui(tree,a,empty)
        self.tap(tree,stamp,'textinput','normal-focus-empty-composer')
        self.type_token(token)
        pure.trusted_legacy_peers(self.state(self.role),self.role,a)
        tree,stamp = self.dump('fresh-before-send'); pure.conversation_ui(tree,a,token); pure.button(tree,'textSendButton')
        self.sent = True
        self.tap(tree,stamp,'textSendButton','normal-Send-once')
        return self.finish_consent(token)

    def finish_consent(self,token):
        a=self.a
        self.activity('TrustKeysActivity','actual-focused-recipient-consent')
        tree,stamp = self.dump('actual-two-trusted-empty-key-cards'); actual_confirmation(tree,a,self.role)
        pure.trusted_legacy_peers(self.state(self.role),self.role,a)
        tree,stamp = self.dump('fresh-before-Done'); actual_confirmation(tree,a,self.role)
        self.confirmed = True
        self.tap(tree,stamp,'save_button','normal-Done-once')
        if self.profile=='A':return self.finish_mixed_receipts(token)
        deadline = min(time.time()+60,a['expires_unix'])
        while True:
            states = {role:self.state(role)for role in r.ROLES}; deliveries = [];sender=None
            for role,state in states.items():
                room = pure.room_state(state,role,a,time.time())
                rows = [m for m in room['test_messages']if m['text']==token]; assert len(rows)<=1
                if rows:
                    m = rows[0]; assert m['encryption']==pure.ENCRYPTION[a['mode']]
                    if role==self.role:
                        assert m['status']!=3,'Actual sender failed; never resend'
                        if m['status']in(2,7,8):sender={'uuid':m['uuid'],'status':m['status'],'encryption':m['encryption']}
                        continue
                    if m['status']==0:
                        mapping = {v['occupant']:v['real_jid']for v in room['members']}
                        assert mapping[m['counterpart']].split('/',1)[0] == r.OWN[self.role]
                        deliveries.append({'receiver':role,**m})
            if len(deliveries)==2 and sender:
                self.activity('ConversationsActivity','normal-completed-room-focused')
                tree,stamp=self.dump('normal-completed-empty-room')
                empty=pure.ui.select_node(tree,'textinput')['text'];assert empty in('',a['empty_composer_hint'])
                pure.conversation_ui(tree,a,empty)
                return {'result':'OWNER_NORMAL_UI_TWO_DECRYPTED_GROUP_RECEIPTS_PASS','token':token,'sender':sender,'deliveries':deliveries}
            assert time.time()<deadline,'Two decoded receipts not proven; never resend'
            time.sleep(1)

    def finish_mixed_receipts(self, token):
        # Same normal Send/Done path as B; native bodies are observed, never resent by Bridge.
        a = self.a; deadline = min(time.time()+60,a['expires_unix'])
        while True:
            nora = self.state('nora'); room = self.room(nora,'nora')
            local = [m for m in room['test_messages'] if m['text']==token];assert len(local)<=1
            if local:assert local[0]['encryption']==5 and local[0]['status']!=3
            sender = local[0] if local and local[0]['status'] in (2,7,8) else None
            received = {peer:self.native_receipt_check(value,token,a['room'],sender['uuid'] if sender else None)
                        for peer,value in self.last_native.items()}
            if sender and all(received.values()):
                self.activity('ConversationsActivity','normal-mixed-completed-room-focused')
                tree,stamp = self.dump('normal-mixed-completed-empty-room')
                empty = pure.ui.select_node(tree,'textinput')['text'];assert empty in ('',a['empty_composer_hint'])
                pure.conversation_ui(tree,a,empty)
                return {'result':'OWNER_NORMAL_UI_TWO_NATIVE_DECODED_GROUP_RECEIPTS_PASS','token':token,
                        'sender':{'uuid':sender['uuid'],'status':sender['status'],'encryption':5},
                        'native_receipts':received,'exact_sender_device_auth_claimed_by_receipts':False}
            assert time.time()<deadline, 'Two actual native decoded receipts not proven; never resend'
            time.sleep(1)

    def own_pq(self):
        a = self.a; tree,stamp = self.dump('initial-bound-room')
        assert pq.one(tree,'toolbar_title').get('text')==a['room_title'] and pq.nodes(tree,'textinput')
        pq.no_dialog(tree)
        node = toolbar_navigation(tree)
        self.require_touch(tree,stamp,node,'normal-room-toolbar-Navigate-up-once')
        self.adb(['shell','-T','input','tap',*[str(x)for x in node['point']]],'normal-room-toolbar-Navigate-up-once',not_after=stamp+5)
        tree,stamp = self.dump('actual-overview');pq.no_dialog(tree)
        assert not pq.nodes(tree,'account_jid') and not pq.nodes(tree,'save_button')
        self.adb(['shell','-T','input','keyevent','82'],'normal-overview-menu-once')
        tree,stamp = self.dump('actual-account-menu');pq.no_dialog(tree)
        choices = [n for n in pq.nodes(tree,'title')if n.get('text')in pq.TITLES];assert len(choices)==1
        self.tap(tree,stamp,'title','normal-manage-own-account',choices[0].get('text'))
        tree,stamp = self.dump('normal-own-account-navigation');pq.no_dialog(tree)
        if pq.nodes(tree,'account_list'):
            values = pq.nodes(tree,'account_jid');assert len(values)==1 and values[0].get('text')==r.OWN[self.role]
            self.tap(tree,stamp,'account_jid','normal-own-account-details',r.OWN[self.role])
            tree,stamp = self.dump('bound-own-account-details')
        pq.own_details(tree,r.OWN[self.role]);found=None
        for attempt in range(9):
            if pq.nodes(tree,'axolotl_fingerprint')and pq.nodes(tree,'legacy_fingerprint'):
                found = pq.keys(tree,self.a['identities'][self.role]);break
            assert attempt<8
            scroll = [n for n in tree.iter('node')if n.get('package')==PACKAGE and n.get('class')=='android.widget.ScrollView'and n.get('scrollable')=='true']
            assert len(scroll)==1
            match = re.fullmatch(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]',scroll[0].get('bounds',''));assert match
            left,top,right,bottom = map(int,match.groups());assert 0<=left<right<=4096 and 0<=top<bottom<=4096 and bottom-top>120
            x=(left+right)//2;gap=(bottom-top)//5;assert time.monotonic()-stamp<=5
            self.adb(['shell','-T','input','swipe',str(x),str(bottom-gap),str(x),str(top+gap),'300'],'normal-public-scroll-'+str(attempt),not_after=stamp+5)
            tree,stamp=self.dump('actual-public-key-scroll-'+str(attempt));pq.no_dialog(tree)
        assert found
        self.tap(tree,stamp,'show_qr_code_button','normal-PQ-box-share-QR-once')
        qr,stamp=self.dump('actual-own-PQ-share-QR');pq.qr_dialog(qr)
        self.adb(['shell','-T','input','keyevent','4'],'normal-close-proven-QR')
        tree,stamp=self.dump('after-key-QR');pq.no_dialog(tree)
        assert pq.keys(tree,self.a['identities'][self.role])==found
        self.adb(['shell','-T','su','0','am','start','-n',PACKAGE+'/eu.siacs.conversations.ui.ConversationsActivity',
            '-a','eu.siacs.conversations.action.VIEW','--es','conversationUuid',a['conversation_uuids'][self.role]],'normal-return-exact-room-UUID')
        self.activity('ConversationsActivity','actual-focused-return-room')
        tree,stamp=self.dump('actual-return-room');pq.no_dialog(tree)
        assert pq.one(tree,'toolbar_title').get('text')==a['room_title']
        self.state(self.role)
        return {'result':'OWNER_PUBLIC_HYBRID_UI_AND_QR_CAPTURED_CLASSICAL_DECODE_PENDING',
            'role':self.role,'identity':a['identities'][self.role],**found,'call_or_payload_auth_claimed':False}

if __name__ == '__main__':
    def terminate(signum,frame):
        signal.signal(signal.SIGTERM,signal.SIG_IGN)
        raise SystemExit('Owner adapter interrupted; exact current child finally follows')
    signal.signal(signal.SIGTERM,terminate)
    p = argparse.ArgumentParser();p.add_argument('--admission',type=Path,required=True);args=p.parse_args()
    owner = None
    try:
        owner = OwnerUI(args.admission); result = owner.run()
    except BaseException as e:
        result = {'result':'PARTIAL','type':type(e).__name__,'detail':str(e),'automatic_retry':False}
        if owner:result.update(sent_submission_may_have_happened=owner.sent,Done_submission_may_have_happened=owner.confirmed,
            choice_submission_may_have_happened=owner.choice_submitted,systemui_Wait_submission_may_have_happened=owner.systemui_wait_submitted)
        if owner:r.v1.write(owner.out/'partial.json',result)
        print(json.dumps(result),flush=True);sys.exit(2)
    result.update(path=str(owner.out),adapter_sha256=r.sha(Path(__file__)),historical_59d_runner_used=False)
    r.v1.write(owner.out/'result.json',result);print(json.dumps(result),flush=True)

#!/usr/bin/env python3
"""One Nora normal UI consent in an exact existing mixed call; no call/crypto OPs."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys
import time
import uuid

sys.dont_write_bytecode = True
if sys.flags.optimize: raise RuntimeError('Required guards must remain enabled')
HERE = Path(__file__).resolve().parent
HARNESS = HERE.parent
PURE = HARNESS / 'triple_v3/normal_consent_ui/normal_ui_consent.py'
PURE_SHA = '59d623366d17a75d77c6afcc3269531ce6d313704b69d39de18cb9224fde3b8a'


def sha(path): return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec); sys.modules[name] = module
    spec.loader.exec_module(module); return module


assert sha(PURE) == PURE_SHA
c = load(PURE, 'reviewed_consent_pure_guards')
assert sha(c.ui.__file__) == 'ca61881676054deed0c18d3814eab132a6a9e6ab4f949b207a10c67002eb813a'
OWN, RUN, ROOT = c.r.OWN, c.r.RUN, c.r.ROOT
ROLES = ('nora', 'leon', 'felix')
PAIRS = ('nora:leon', 'nora:felix', 'leon:felix')


def exact(value, token, prefix): return value in (token, prefix + token)


def active_scope(nora, natives, a, now):
    assert nora['run_id'] == RUN and nora['account'] == OWN['nora'] and nora['online'] and nora['service_bound']
    assert 0 <= now - nora['time_ms'] / 1000 <= 10
    own = a['identities']['nora']
    assert nora['own_device_id'] == own['device_id'] and nora['own_legacy_fingerprint'] == own['legacy_fingerprint']
    conf = nora['conference']; assert conf['room'] == a['room'] and conf['call_id'] == a['call_ids']['nora']
    full = a['full_jids']; expected = {full[p] for p in ('leon', 'felix')}
    assert expected <= set(conf['participants']) <= expected | {full['nora']}
    rooms = [r for r in nora['conversations'] if r['jid'] == a['room']]; assert len(rooms) == 1
    room = rooms[0]
    assert room['uuid'] == a['conversation_uuid'] and room['online'] and room['private_nonanonymous']
    assert room['muc_error'] == 'NONE' and room['encryption'] == 5
    real = [m['real_jid'] for m in room['members']]; assert all(real)
    bare = [x.split('/', 1)[0] for x in real]
    assert len(bare) == len(set(bare)) and set(bare) <= set(OWN.values())
    assert {OWN['leon'], OWN['felix']} <= set(bare)
    for jid in real:
        if '/' in jid: assert jid in set(full.values()), 'Unexpected resource in current room'
    assert len(nora['calls']) == 2
    for peer in ('leon', 'felix'):
        rows = [x for x in nora['calls'] if x['session_id'] == a['sids']['nora:' + peer]]
        assert len(rows) == 1 and rows[0]['peer'] == full[peer] and rows[0]['muji_room'] == a['room']
        assert rows[0]['end_user_state'] == 'CONNECTED' and rows[0]['media'] == ['AUDIO']
        value = natives[peer]; public = a['identities'][peer]
        assert value['run_id'] == RUN and value['account'] == OWN[peer] and value['full_jid'] == full[peer]
        assert value['online'] and value['profile_lock_held']
        assert value['own_omemo_device_id'] == public['device_id']
        assert value['own_public_identity_hex'] == public['legacy_fingerprint']
        call = value['call']; assert call['id'] == a['call_ids'][peer] and call['room'] == a['room'] and call['peers'] == 2
        assert exact(call['state'], 'IN_PROGRESS', 'DINO_ENTITIES_CALL_STATE_')
        current = [s for s in value['sessions'] if exact(s.get('wire_state'), 'ACTIVE', 'DINO_PLUGINS_GOOGLE_WEBRTC_SIGNALING_STATE_')]
        assert len(current) == 2
        for other in (p for p in ROLES if p != peer):
            key = next(k for k in PAIRS if set(k.split(':')) == {peer, other})
            legs = [s for s in current if s['sid'] == a['sids'][key]]; assert len(legs) == 1
            leg = legs[0]
            assert leg['local'] == full[peer] and leg['peer'] == full[other] and leg['room'] == a['room']
            assert exact(leg['peer_connection_state'], 'CONNECTED', 'DINOX_WEBRTC_PEER_CONNECTION_STATE_')
    c.trusted_legacy_peers(nora, 'nora', a)
    return room


def native_receipt(state, token, room, sent_uuid):
    rows = [m for m in state['messages'] if m.get('body') == token and m['direction'] == 'received'
            and m['encryption'] in ('OMEMO', 'DINO_ENTITIES_ENCRYPTION_OMEMO')
            and m['peer'].split('/', 1)[0] == room]
    assert len(rows) <= 1, 'Duplicate token is not one received message'
    if not rows: return None
    value = rows[0]
    return {'actual_body_received_in_owned_test_group':True, 'body':value['body'],
        'peer':value['peer'], 'stanza_id':value.get('stanza_id', ''), 'encryption':value['encryption'],
        'stanza_id_equals_Nora_sent_UUID':bool(sent_uuid and value.get('stanza_id') == sent_uuid),
        'exact_sender_device_fingerprint_proven_by_this_snapshot':False,
        'sender_presence_and_crypto_auth_correlation':'SEPARATE_SCOPED_OBSERVER_AUDIT_REQUIRED'}


def bindings(a, now):
    # All values are from a private, explicit Root admission; no CLI shell/ADB/path payload.
    assert a['operation'] == 'normal-mixed-recipient-consent' and a['schema_version'] == 1
    assert a['helper_sha256'] == sha(__file__) and a['pure_guards_sha256'] == sha(PURE) == PURE_SHA
    assert a['run_id'] == RUN and a['accounts'] == OWN and a['role'] == 'nora' and a['mode'] == 'legacy'
    assert a['no_trust_or_call_changes_authorized'] is True
    assert 0 <= now - a['created_unix'] <= 120 and now < a['expires_unix'] <= a['created_unix'] + 240
    assert re.fullmatch('[0-9a-f]{32}', a['nonce']) and re.fullmatch('[0-9a-f]{32}', a['batch_id'])
    assert re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,128}@conference\.dinox\.im', a['room'])
    assert set(a['sids']) == set(PAIRS) and len(set(a['sids'].values())) == 3 and all(a['sids'].values())
    assert set(a['call_ids']) == set(a['identities']) == set(a['full_jids']) == set(ROLES)
    assert set(a['display_names']) == {OWN['leon'], OWN['felix']}
    for role in ROLES:
        assert a['full_jids'][role].startswith(OWN[role] + '/') and a['full_jids'][role].split('/',1)[1]
        assert a['identities'][role]['account'] == OWN[role]
        assert type(a['identities'][role]['device_id']) is int and a['identities'][role]['device_id'] > 0
        assert re.fullmatch('05[0-9a-f]{64}', a['identities'][role]['legacy_fingerprint'])
    modules = {}
    for family, required in (('runtime', {'runtime.py','control.py'}), ('native', {'native_control.py','native_recorder.py'})):
        item = a[family]; directory = Path(item['directory']).resolve(strict=True)
        assert directory.is_relative_to(HARNESS) and directory != HARNESS
        assert required <= set(item['files_sha256']) and set(item['files_sha256']) <= required | {'server_control_base.py'}
        for name, digest in item['files_sha256'].items():
            path = directory / name; assert path.is_file() and not path.is_symlink() and sha(path) == digest
        modules[family] = directory
    # Pin bytes BEFORE imports. Old runtimes lack this constant and stop before I/O.
    sys.path.insert(0, str(modules['runtime']))
    r = load(modules['runtime']/'runtime.py', 'runtime')
    assert getattr(r, 'NORMAL_MIXED_CONSENT_UI_SHA256', None) == sha(__file__), 'MIXED_CONSENT_RUNTIME_NOT_ADMITTED'
    assert r.ROOT == ROOT and r.RUN == RUN and r.OWN == OWN and r.frozen_files() == a['runtime']['freeze_sha256']
    build = c.r.probe.referenced_json(a['main_build_receipt'], Path('/media/linux/SSD128/xmppwin'))
    assert build['result'] == 'PASS' and build['actual_jvm_tests'] == 616
    assert build['jvm_receipt_sha256'] == '4f47c0fc108684c2bdf1706d77c72d45ff841acc7b87c34fcd47909beb020229'
    assert build['source_manifest_sha256'] == 'b1ac6b70000caa0b5e512e94da128508ad09bc2a14d0b8b86708404db7cd4491'
    assert r.APKS['main.apk'] == build['apk_sha256'] and r.APKS['android-test.apk'] == '486b06a8f472fc68d89f9ced35b1befbc67805f22aa0d3dbf1c162cf3aab6e65'
    source = Path(a['main_build_receipt']['path']).parent / 'source-reviewed-jvm.json'
    assert sha(source) == build['source_manifest_sha256']
    contract = PURE.with_name('source-contract.json')
    assert sha(contract) == '033e7251a794a8592c8600889771d647b9545db445880ca777fab5d2417160ac'
    contract = json.loads(contract.read_text()); actual = json.loads(source.read_text())
    for name, digest in contract['files_sha256'].items():
        assert actual['files'][name]['sha256'] == sha(Path(contract['source_root'])/name) == digest
    android = load(modules['runtime']/'control.py', 'control')
    sys.path.insert(0, str(modules['native']))
    native = load(modules['native']/'native_control.py', 'native_control')
    assert native.admission(a['native']['admission_sha256']) == a['native']['owner_admission']
    recorder = load(modules['native']/'native_recorder.py', 'mixed_native_recorder')
    recorder.ADMISSION_SHA = a['native']['admission_sha256']
    return r, android, recorder


class MixedUI(c.ui.RoomUI):
    def __init__(self, admission):
        self.a = admission; self.r, self.android, self.native = bindings(admission, time.time())
        self.role, self.room = 'nora', admission['room']; self.sent = self.confirmed = False
        self.token = RUN + ':mixed-consent:nora:' + admission['nonce']
        self.cfg = self.r.control_settings('nora')
        self.session = self.r.read(self.cfg['state']/'live-session.json')
        assert self.session['batch_id'] == admission['batch_id'] and self.session['freeze_sha256'] == admission['runtime']['freeze_sha256']
        self.adb_prefix, self.env = self.r.adb_command('nora'), self.r.environment('nora')
        self.out = ROOT / 'mixed-consent-evidence' / admission['nonce']; self.out.mkdir(parents=True, mode=0o700)
        with (self.out/'claimed-once').open('x') as stream: stream.write(self.token+'\n')
        (self.out/'claimed-once').chmod(0o600)
        self.previous_native = None
        self.write('scope.json', admission)

    def write(self, name, value): self.r.v1.write(self.out/name, value)

    def owners(self):
        assert time.time() < self.a['expires_unix']
        cfg = self.r.control_settings('nora'); session = self.r.read(cfg['state']/'live-session.json')
        for key in ('batch_id','freeze_sha256','controller_pid','controller_start_ticks'):
            assert session[key] == self.session[key], 'Nora owner changed'

    def scope(self):
        self.owners()
        response = self.android.control({'action':'state','role':'nora','transport':'local-android','wait':2})
        assert response.get('completed'); nora = response['response']; peers = {}
        for role in ('leon','felix'):
            receipt = self.native.server({'action':'state','role':role,'transport':'server','wait':0,
                'recording':self.a['native']['recording'],'tag':'mixed-consent-readonly-'+uuid.uuid4().hex,'local_recording':True})
            assert receipt['controller_exit'] == 0 and receipt['observation'].get('completed')
            peers[role] = receipt['observation']['response']
        active_scope(nora, peers, self.a, time.time())
        if self.previous_native is not None:
            # Native state files have no timestamp. Actual rising sink counters prove
            # these repeated same-SID snapshots are live; this is no new media PASS.
            for role in ('leon','felix'):
                old = {s['sid']:s['audio_sink_samples'] for s in self.previous_native[role]['sessions']
                       if exact(s.get('wire_state'),'ACTIVE','DINO_PLUGINS_GOOGLE_WEBRTC_SIGNALING_STATE_')}
                for row in peers[role]['sessions']:
                    if exact(row.get('wire_state'),'ACTIVE','DINO_PLUGINS_GOOGLE_WEBRTC_SIGNALING_STATE_'):
                        assert row['audio_sink_samples'] > old[row['sid']], 'Stale/stalled native snapshot'
        self.previous_native = peers
        self.write('actual-scope-'+str(time.time_ns())+'.json', {'nora':nora,'native':peers})
        return nora, peers

    def adb(self, tail, label, binary=False, not_after=None):
        self.owners()
        if not_after is not None: assert time.monotonic() <= not_after
        done = subprocess.run([*self.adb_prefix,*tail], env=self.env, stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=30)
        self.write(label+'-command.json', {'arguments':tail,'exit':done.returncode,'stderr':done.stderr.decode(errors='replace')[:4096]})
        assert done.returncode == 0 and len(done.stdout) <= (12*1024**2 if binary else 2*1024**2)
        return done.stdout

    def activity(self, expected, label):
        text = self.adb(['shell','-T','dumpsys','activity','top'],label).decode(errors='replace')
        (self.out/(label+'.txt')).write_text(text);(self.out/(label+'.txt')).chmod(0o600)
        assert re.findall(r'^ACTIVITY ([^\s]+)',text,re.M) == [c.PACKAGE+'/eu.siacs.conversations.ui.'+expected]

    def run(self):
        self.scope(); time.sleep(1); first, peers = self.scope()
        assert not any(m['text'] == self.token for x in first['conversations'] for m in x['test_messages'])
        assert all(native_receipt(v,self.token,self.room,None) is None for v in peers.values())
        opened = self.adb(['shell','-T','am','start','-W','-a','android.intent.action.VIEW',
            '-d','xmpp:'+self.room+'?join','-p',c.PACKAGE], 'normal-existing-room-once')
        assert b'Status: ok' in opened and ('Activity: '+c.PACKAGE+'/').encode() in opened
        self.activity('ConversationsActivity','actual-before-compose')
        tree,stamp = self.dump('fresh-empty-composer');c.conversation_ui(tree,self.a,'')
        self.tap(tree,stamp,'textinput','normal-focus-empty-composer')
        self.adb(['shell','-T','input','text',self.token],'normal-compose-single-token')
        self.scope()
        tree,stamp = self.dump('fresh-before-single-send');c.conversation_ui(tree,self.a,self.token);c.button(tree,'textSendButton')
        self.sent = True;self.tap(tree,stamp,'textSendButton','normal-send-once')
        for attempt in range(3):
            try:
                self.activity('TrustKeysActivity','actual-confirmation-'+str(attempt))
                tree,stamp=self.dump('fresh-confirmation');c.confirmation_ui(tree,self.a,'nora');break
            except AssertionError:
                if attempt == 2:raise
                time.sleep(1)
        self.scope()
        tree,stamp=self.dump('fresh-before-done');c.confirmation_ui(tree,self.a,'nora')
        self.confirmed=True;self.tap(tree,stamp,'save_button','normal-done-once')
        deadline=time.monotonic()+60
        while True:
            nora,peers=self.scope()
            local=[m for x in nora['conversations'] if x['jid']==self.room for m in x['test_messages'] if m['text']==self.token]
            assert len(local)<=1
            if local:assert local[0]['encryption']==5 and local[0]['status']!=3
            sent=local[0]['uuid'] if local and local[0]['status'] in (2,7,8) else None
            received={role:native_receipt(value,self.token,self.room,sent) for role,value in peers.items()}
            if sent and all(received.values()):break
            assert time.monotonic()<deadline,'PARTIAL: two actual native decoded receipts not observed'
            time.sleep(1)
        self.activity('ConversationsActivity','normal-return-activity')
        tree,stamp=self.dump('normal-return-empty-composer');c.conversation_ui(tree,self.a,'')
        self.scope()
        result={'result':'NORMAL_NORA_CONSENT_TWO_OWNED_GROUP_DECODED_BODIES_PASS','room':self.room,
            'token':self.token,'nora_sent_message_uuid':sent,'native_received':received,'send_taps':1,'done_taps':1,
            'same_text_resumed_by_product':True,'exact_sender_FP_or_call_auth_claimed':False,
            'media_verdict_replaced':False,'active_call_and_runtime_cleanup_remains_with_owner':True,'path':str(self.out)}
        self.write('result.json',result);return result

    def cleanup(self):
        if not self.sent or self.confirmed:return {'normal_cancel_submitted':False}
        self.scope();self.activity('TrustKeysActivity','abort-current-activity')
        tree,stamp=self.dump('abort-fresh-consent');c.confirmation_ui(tree,self.a,'nora');c.button(tree,'cancel_button')
        self.tap(tree,stamp,'cancel_button','abort-normal-cancel-once')
        self.activity('ConversationsActivity','abort-return-activity')
        tree,stamp=self.dump('abort-retained-draft');c.conversation_ui(tree,self.a,self.token);self.scope()
        return {'normal_cancel_submitted':True,'draft_retained_no_resend':True,'calls_not_touched':True}


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--admission',type=Path,required=True)
    args=parser.parse_args();runner=None
    try:
        runner=MixedUI(c.r.probe.private_json(args.admission));print(json.dumps(runner.run()))
    except BaseException as error:
        cleanup={'normal_cancel_submitted':False}
        if runner is not None:
            try:cleanup=runner.cleanup()
            except BaseException as cleanup_error:cleanup['incomplete_detail']=str(cleanup_error)
        value={'result':'PARTIAL','type':type(error).__name__,'detail':str(error),'automatic_retry':False,
            'submission_may_have_happened':bool(runner and runner.sent),'product_failure_not_assumed':True,
            'cleanup':cleanup,'normal_UI_draft_dialog_and_call_cleanup_requires_owner':True}
        if runner is not None:runner.write('partial.json',value)
        print(json.dumps(value));sys.exit(2)

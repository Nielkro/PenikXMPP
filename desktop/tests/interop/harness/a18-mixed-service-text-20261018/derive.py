#!/usr/bin/env python3
"""Generate only this reviewed A18 source sibling; never import lab runtimes."""
import ast
import difflib
import hashlib
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
HARNESS = Path('/media/linux/SSD128/xmppwin/local/monocles-dinox-interop-20261015/harness')
A = HARNESS / 'devicefix_nora_runtime'
S = HARNESS / 'resume-completion-plan-20261016T190157Z/ui-owner-resume'
PINS = {
    A / 'runtime.py': '3eb5100e0ddcaeb60f87929b01ff9e75e8e350eb7bf3b718d1ef2755bccbac31',
    A / 'control.py': '96b54078b0b958d23b8f13f7546877ac0ee5f2c47c92ce368aacd2efe86b7617',
    A / 'recorder.py': '416a89203a246dd481f8a79fd08dd930f6ed988d8eccceb5a12ed31bbdfb16b5',
    A / 'freeze.json': '131aa89a08adf3075e7ddcbc62af03b4ac14a682e3df4547099cd6bd6ef7b294',
    S / 'mixed_scenario.py': '895aa598f4f069ad8978b352c870cb544a7b4f0c5f7310bdd5240d9c120a7f87',
    S / 'persistent-service-text/persistent_service_text.py': 'e9c49a2bf9ceb1ba134508e895cca1e97467fbcf0bd0c4460e3d3cb334a7b721',
    HARNESS / 'devicefix_nora_monitor/monitor.py': 'f2bb8e96ddcf4284c34efc668c0ee1973a7f26bff32fd840a6d356d4dc45529e',
}


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def once(text, old, new):
    assert text.count(old) == 1, old[:120]
    return text.replace(old, new)


def replace_function(text, name, replacement, last=False):
    nodes = [n for n in ast.parse(text).body if isinstance(n, ast.FunctionDef) and n.name == name]
    assert nodes
    node = nodes[-1] if last else nodes[0]
    lines = text.splitlines(keepends=True)
    return ''.join(lines[:node.lineno - 1]) + replacement.rstrip() + '\n\n' + ''.join(lines[node.end_lineno:])


def function_source(text, name):
    node = next(n for n in ast.parse(text).body if isinstance(n, ast.FunctionDef) and n.name == name)
    return '\n'.join(text.splitlines()[node.lineno - 1:node.end_lineno]) + '\n\n'


def main():
    for path, digest in PINS.items():
        assert sha(path) == digest, str(path)
    source = (A / 'runtime.py').read_text()
    source = once(source, "HERE = Path(__file__).resolve().parent\nsys.path.insert(0, str(HERE.parent))", "HERE = Path(__file__).resolve().parent\nHARNESS = Path(" + repr(str(HARNESS)) + ")\nsys.path.insert(0, str(HARNESS))")
    source = source.replace('HERE.parent', 'HARNESS')
    source = once(source, 'import uuid\n', 'import uuid\nsys.dont_write_bytecode = True\nif sys.flags.optimize:\n    raise RuntimeError("A18 requires Python without optimization")\n')
    source = once(source, "STATE = ROOT / 'pair-v2'", "STATE = HERE / 'runtime-state'")
    freeze_function = '''def frozen_files():
    # The historical A chain stays frozen; this sibling owns a distinct source freeze.
    assert _historical.frozen_files() == 'e406750ab36b260618f254c15d8cedcbc52db6dcfa0a1e26e073aaf1cf46df28'
    baseline = read(HARNESS / 'devicefix_nora_runtime/freeze.json')
    assert sha(HARNESS / 'devicefix_nora_runtime/freeze.json') == '131aa89a08adf3075e7ddcbc62af03b4ac14a682e3df4547099cd6bd6ef7b294'
    for name, digest in baseline['files_sha256'].items():
        assert sha(HARNESS / 'devicefix_nora_runtime' / name) == digest
    value = read(HERE / 'freeze.json')
    assert value['mode'] == 'Nora-only-persistent-room-service-20261018' and value['roles'] == ['nora']
    names = ('runtime.py', 'control.py', 'recorder.py', 'scenario.py', 'service_support.py', 'room_scope.py', 'monitor.py')
    assert value['files_sha256'] == {name: sha(HERE / name) for name in names}
    assert value['parent_A_freeze_sha256'] == '131aa89a08adf3075e7ddcbc62af03b4ac14a682e3df4547099cd6bd6ef7b294'
    assert value['apk_sha256'] == APKS and value['product'] == PRODUCT
    assert sha(MIXED_HELPER) == NORMAL_MIXED_CONSENT_UI_SHA256
    assert sha(LAYOUT_CAPTURE) == LAYOUT_CAPTURE_SHA256
    _current_product()
    return sha(HERE / 'freeze.json')'''
    source = replace_function(source, 'frozen_files', freeze_function, last=True)
    source = once(source, "approved={HERE/'runtime.py',HERE/'control.py',HERE/'recorder.py',HERE/'scenario.py',MIXED_HELPER}", "approved={HERE/'runtime.py',HERE/'control.py',HERE/'recorder.py',HERE/'scenario.py'}")
    source = once(source, "    if script==MIXED_HELPER:assert sha(script)==NORMAL_MIXED_CONSENT_UI_SHA256\n", '')
    extra = '''
def room_control_context():
    # This exact new caller has already passed the same source/owner/resource gate.
    settings = control_settings('nora')
    session = read(settings['state'] / 'live-session.json')
    keys = {'controller_pid', 'controller_start_ticks', 'adb_pid', 'adb_start_ticks',
            'emulator_pid', 'emulator_start_ticks', 'adb_cgroup', 'approval_sha256'}
    return {
        'run_id': RUN, 'role': 'nora', 'account': OWN['nora'],
        'runtime_freeze_sha256': frozen_files(), 'runtime_inputs_sha256': session['inputs_sha256'],
        'apk_sha256': session['apk_sha256'], 'batch_id': session['batch_id'],
        'session_binding': {key: session[key] for key in keys},
        'process_cgroups': {name: v1.process_cgroup(session[name + '_pid']) for name in ('controller', 'adb', 'emulator')},
        'native_readonly_bindings': session['native_readonly_bindings'],
        'batch_deadline_unix': session['batch_deadline_unix'],
        'runtime_root': str(ROOT), 'derivation_root': str(HERE),
    }


def validate_control_config(role, value, request):
    assert role == 'nora'
    # Startup validate_private_config remains byte-identical and still requires [].
    scope_spec = _iu.spec_from_file_location('persistent_room_scope', HERE / 'room_scope.py')
    scope = _iu.module_from_spec(scope_spec)
    scope_spec.loader.exec_module(scope)
    assert scope.RUN == RUN and scope.OWN == OWN
    return scope.validate_control_config(value, request, room_control_context(), time.time())


'''
    source = once(source, "if __name__ == '__main__':", extra + "if __name__ == '__main__':")
    # A dead former V2 freeze function is removed: only the actual A18 freeze exists.
    source = replace_function(source, 'frozen_files', 'def historical_v2_freeze_not_used():\n    raise RuntimeError("Historical V2 freeze is not an A18 entry point")')
    (HERE / 'runtime.py').write_text(source)

    control = (A / 'control.py').read_text()
    begin = control.index('OPS = ')
    end = control.index('\n\n\ndef validate', begin)
    control = control[:begin] + "OPS = {'status', 'stats', 'stop', 'prepare_crypto', 'send_text'}" + control[end:]
    control = control.replace("runtime.validate_private_config(value['role'], config)", "runtime.validate_control_config(value['role'], config, value)")
    control = once(control, "        self.settings = runtime.control_settings(role)", "        self.scope_request = self.scope_config = None\n        self.settings = runtime.control_settings(role)")
    control = once(control, '        runtime.control_settings(self.role)\n', '        runtime.control_settings(self.role)\n        if self.scope_request is not None:\n            runtime.validate_control_config(self.role, self.scope_config, self.scope_request)\n')
    control = once(control, "    if value['action'] == 'command': backend.submit", "    backend.scope_request, backend.scope_config = value, config\n    if value['action'] == 'command': backend.submit")
    control = once(control, "    if value['action'] == 'command':\n        payload =", "    if 'room_admission' in value:\n        ref = value['room_admission']\n        assert isinstance(ref, dict) and set(ref) == {'path', 'sha256'}\n        assert isinstance(ref['path'], str) and Path(ref['path']).is_absolute()\n        assert re.fullmatch('[0-9a-f]{64}', ref['sha256'])\n    if value['action'] == 'command':\n        payload =")
    control = once(control, "    parser.add_argument('--id')", "    parser.add_argument('--id')\n    parser.add_argument('--room-admission', type=Path)\n    parser.add_argument('--room-admission-sha256')")
    control = once(control, "    if args.action == 'command':", "    assert (args.room_admission is None) == (args.room_admission_sha256 is None)\n    if args.room_admission is not None:\n        value['room_admission'] = {'path': str(args.room_admission), 'sha256': args.room_admission_sha256}\n    if args.action == 'command':")
    (HERE / 'control.py').write_text(control)

    recorder = (A / 'recorder.py').read_text()
    recorder = once(recorder, "    control.validate(request)", "    if 'room_admission' in value: request['room_admission'] = value['room_admission']\n    control.validate(request)")
    recorder = once(recorder, "        item.add_argument('--wait', type=float, default=0)", "        item.add_argument('--wait', type=float, default=0)\n        item.add_argument('--room-admission', type=Path)\n        item.add_argument('--room-admission-sha256')")
    recorder = once(recorder, "    if value['action'] == 'command': value.update", "    if value['action'] != 'begin':\n        path = value.pop('room_admission')\n        digest = value.pop('room_admission_sha256')\n        assert (path is None) == (digest is None)\n        if path is not None: value['room_admission'] = {'path': str(path), 'sha256': digest}\n    if value['action'] == 'command': value.update")
    (HERE / 'recorder.py').write_text(recorder)

    mixed = (S / 'mixed_scenario.py').read_text()
    support = '''"""Selected unchanged service helpers, plus the A18 recorder CLI binding."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import time
import runtime as r

HERE = A_DIR = Path(__file__).resolve().parent
HARNESS = Path(''' + repr(str(HARNESS)) + ''')
ROLES = ('nora', 'leon', 'felix')
FREEZE = r.frozen_files()
RECORDER_SHA = r.read(HERE / 'freeze.json')['files_sha256']['recorder.py']
ROOM_CONTROL_ADMISSION = None
PREFIX = {**dict.fromkeys(('RINGING', 'IN_PROGRESS', 'ESTABLISHING', 'ENDED'), 'DINO_ENTITIES_CALL_STATE_'),
          'ACTIVE': 'DINO_PLUGINS_GOOGLE_WEBRTC_SIGNALING_STATE_', 'CONNECTED': 'DINOX_WEBRTC_PEER_CONNECTION_STATE_',
          'AVAILABLE': 'DINO_PARTICIPANT_INVITE_AVAILABILITY_'}

'''
    for name in ('enum_is', 'idle', 'wait_for', 'received', 'owner_session', 'android_record'):
        support += function_source(mixed, name)
    support = once(support, "        if action=='command':\n", "        assert ROOM_CONTROL_ADMISSION is not None, 'Scenario needs exact fresh room-control admission'\n        argv += ['--room-admission', ROOM_CONTROL_ADMISSION['path'], '--room-admission-sha256', ROOM_CONTROL_ADMISSION['sha256']]\n        if action=='command':\n")
    (HERE / 'service_support.py').write_text(support)

    scenario = (S / 'persistent-service-text/persistent_service_text.py').read_text()
    scenario = once(scenario, "BASE=HERE.parent/'mixed_scenario.py'", "BASE=HERE/'service_support.py'")
    scenario = once(scenario, "assert sha(BASE)=='895aa598f4f069ad8978b352c870cb544a7b4f0c5f7310bdd5240d9c120a7f87'", "assert sha(BASE)==" + repr(sha(HERE / 'service_support.py')))
    scenario = once(scenario, "a['runtime_profile']=='A'", "a['runtime_profile']=='A18'")
    scenario = once(scenario, "assert m.FREEZE==r.frozen_files()=='131aa89a08adf3075e7ddcbc62af03b4ac14a682e3df4547099cd6bd6ef7b294'", "assert m.FREEZE==r.frozen_files()==a['runtime_freeze_sha256']")
    scenario = once(scenario, " fixture_authorization(a)  # Root's actual redacted config readback; no config edit in this sibling.", " fixture_authorization(a)  # Root's actual redacted config readback; no config edit in this sibling.\n import room_scope\n context=r.room_control_context()\n room_admission=room_scope.private_artifact(a['room_control_admission'],[r.HERE,r.ROOT])\n room_scope.validate_admission(room_admission,context,time.time(),at_entry=True)\n assert room_admission['fixture_room_authorization']==a['fixture_room_authorization']\n case_deadline=min(a['expires_unix'],room_admission['expires_unix'],session['batch_deadline_unix']-120)\n assert case_deadline-time.time()>=90, 'Insufficient fresh case budget; no product command'\n room_scope.claim_scenario_once(context,a['room_control_admission'],{'path':str(args.root_admission),'sha256':sha(args.root_admission)})\n m.ROOM_CONTROL_ADMISSION=a['room_control_admission']")
    scenario = once(scenario, "  assert role in m.ROLES;r.v1.resources();m.owner_session(a)", "  assert role in m.ROLES;r.v1.resources();m.owner_session(a)\n  assert time.time()<case_deadline, 'Case scope expired; no further operation or resend'\n  if payload and payload['op']=='send_text':\n   assert case_deadline-time.time()>=40, 'Keep one send/result observation budget; no late token'")
    (HERE / 'scenario.py').write_text(scenario)

    monitor = (HARNESS / 'devicefix_nora_monitor/monitor.py').read_text()
    monitor = once(monitor, "sys.path.insert(0,str(Path(__file__).resolve().parent.parent/'devicefix_nora_runtime'))", "sys.path.insert(0,str(Path(__file__).resolve().parent))")
    monitor = once(monitor, "Retained Nora12210 current616: real Legacy3 media/auth/watchdog/reinvite, normal text consent, responsive layout captures; no old test repeats", "A18 retained Nora12210 current616: missing persistent mixed service text only; no audio/UI/PQ repeats")
    (HERE / 'monitor.py').write_text(monitor)

    names = ('runtime.py', 'control.py', 'recorder.py', 'scenario.py', 'service_support.py', 'room_scope.py', 'monitor.py')
    old_freeze = json.loads((A / 'freeze.json').read_text())
    freeze = {
        'schema_version': 1, 'mode': 'Nora-only-persistent-room-service-20261018',
        'roles': ['nora'], 'parent_A_freeze_sha256': PINS[A / 'freeze.json'],
        'product': old_freeze['product'], 'apk_sha256': old_freeze['apk_sha256'],
        'files_sha256': {name: sha(HERE / name) for name in names},
        'root_start_authorized': False, 'marker_created': False, 'runtime_started': False,
    }
    (HERE / 'freeze.json').write_text(json.dumps(freeze, indent=2) + '\n')
    manifest = {
        'scope': 'SOURCE_ONLY_A18_SINGLE_FIXTURE_NO_START',
        'inputs': {str(path): {'sha256': digest, 'bytes': path.stat().st_size} for path, digest in PINS.items()},
        'files_sha256': {name: sha(HERE / name) for name in (*names, 'freeze.json', 'derive.py')},
        'generated_source_bytes': sum((HERE / name).stat().st_size for name in names),
        'startup_config_still_empty_rooms': True,
        'runtime_or_ADB_SSH_build_download_executed': False,
    }
    (HERE / 'source-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    diffs = []
    for name in ('runtime.py', 'control.py', 'recorder.py'):
        diffs.extend(difflib.unified_diff((A / name).read_text().splitlines(True), (HERE / name).read_text().splitlines(True), fromfile='frozen-A/' + name, tofile='A18/' + name))
    diffs.extend(difflib.unified_diff((S / 'persistent-service-text/persistent_service_text.py').read_text().splitlines(True), (HERE / 'scenario.py').read_text().splitlines(True), fromfile='frozen-service/scenario.py', tofile='A18/scenario.py'))
    (HERE / 'derivation.diff').write_text(''.join(diffs))
    for name in names:
        ast.parse((HERE / name).read_text(), filename=name)
    print(json.dumps({'result': 'SOURCE_DERIVATION_WRITTEN_NO_RUNTIME_IMPORT', 'freeze_sha256': sha(HERE / 'freeze.json'), 'manifest_sha256': sha(HERE / 'source-manifest.json'), 'source_bytes': manifest['generated_source_bytes']}))


if __name__ == '__main__':
    main()

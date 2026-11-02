"""Pure, fail-closed authorization for the one retained Nora service-text room.

No application, process, network or runtime module is imported here. Root records
the actual session and room readback; callers supply the current runtime context.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import stat

RUN = '20261015-71115b'
ROOM = 'interop-three-71115b-8df83d69736d9417@conference.dinox.im'
CONVERSATION_UUID = 'dae15cd3-0777-46f6-a28f-818d4854ab85'
OWN = {
    'nora': 'nora.schneider.interop.de.71115b@dinox.im',
    'leon': 'leon.fischer.interop.de.71115b@dinox.im',
    'felix': 'felix.wagner.interop.de.71115b@dinox.im',
}
SESSION_KEYS = {
    'controller_pid', 'controller_start_ticks', 'adb_pid', 'adb_start_ticks',
    'emulator_pid', 'emulator_start_ticks', 'adb_cgroup', 'approval_sha256',
}
READ_OR_STOP = {'status', 'stats', 'stop'}
ROOM_OPS = {'prepare_crypto', 'send_text'}


class ScopeError(ValueError):
    """An actual command must not be dispatched after this error."""


def require(condition, label):
    if not condition:
        raise ScopeError(label)


def private_artifact(ref, roots, max_bytes=32768):
    """Read only a private regular file whose bytes match the supplied pin."""
    require(isinstance(ref, dict) and set(ref) == {'path', 'sha256'}, 'artifact reference')
    require(isinstance(ref['path'], str) and isinstance(ref['sha256'], str), 'artifact reference types')
    require(re.fullmatch('[0-9a-f]{64}', ref['sha256']) is not None, 'artifact digest')
    path = Path(ref['path'])
    require(path.is_absolute(), 'absolute artifact path')
    info = path.lstat()  # Missing files are intentionally fatal.
    require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid(), 'private regular owned artifact')
    require(info.st_mode & 0o077 == 0 and info.st_size <= max_bytes, 'artifact mode or size')
    resolved = path.resolve(strict=True)
    require(any(resolved.is_relative_to(Path(root).resolve(strict=True)) for root in roots), 'artifact root')
    # Open the checked final component without following a replacement symlink.
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        current = os.fstat(fd)
        require((current.st_dev, current.st_ino) == (info.st_dev, info.st_ino), 'artifact replaced')
        with os.fdopen(fd, 'rb', closefd=False) as stream:
            raw = stream.read(max_bytes + 1)
        require(len(raw) <= max_bytes, 'artifact grew')
    finally:
        os.close(fd)
    require(hashlib.sha256(raw).hexdigest() == ref['sha256'], 'stale or changed artifact')
    return json.loads(raw)


def fresh_window(value, now, seconds, label):
    require(type(value) in (int, float), label)
    require(0 <= now - value <= seconds, label)


def validate_admission(admission, context, now, artifact_reader=private_artifact, at_entry=False):
    require(isinstance(admission, dict), 'room admission object')
    require(admission.get('schema_version') == 1, 'room admission schema')
    require(admission.get('operation') == 'nora-persistent-room-service-controller', 'room operation')
    require(admission.get('runtime_profile') == 'A18', 'runtime profile')
    require(admission.get('run_id') == RUN == context['run_id'], 'run identity')
    require(admission.get('role') == context['role'] == 'nora', 'Nora role')
    require(admission.get('account') == context['account'] == OWN['nora'], 'Nora account')
    require(admission.get('accounts') == OWN, 'owned accounts')
    require(admission.get('room') == ROOM, 'exact fixture room')
    require(admission.get('conversation_uuid') == CONVERSATION_UUID, 'exact fixture conversation')
    require(set(admission.get('session_binding', {})) == SESSION_KEYS, 'session binding keys')
    for name in ('runtime_freeze_sha256', 'runtime_inputs_sha256', 'apk_sha256',
                 'batch_id', 'session_binding', 'process_cgroups', 'native_readonly_bindings'):
        require(admission.get(name) == context[name], 'current ' + name)
    created = admission.get('created_unix')
    require(type(created) in (int, float) and created <= now, 'room admission timestamp')
    if at_entry:
        fresh_window(created, now, 120, 'fresh room admission at case entry')
    expires = admission.get('expires_unix')
    require(type(expires) in (int, float), 'room admission expiry')
    require(now < expires <= created + 240, 'room admission expiry')
    require(expires <= context['batch_deadline_unix'] - 120, 'room grant preserves cleanup reserve')
    require(now < context['batch_deadline_unix'], 'runtime lease')
    receipt = artifact_reader(admission.get('fixture_room_authorization'), [context['runtime_root']])
    require(receipt.get('run_id') == RUN and receipt.get('account') == OWN['nora'], 'room receipt account')
    require(receipt.get('allowed_rooms') == [ROOM], 'room receipt singleton')
    require(receipt.get('session_binding') == context['session_binding'], 'room receipt session')
    require(receipt.get('validated_write_readback_equal') is True, 'actual room readback')
    # Readback must actually precede and be fresh at the grant's creation. The
    # pinned grant then lasts at most its explicit 240s expiry, in one session.
    fresh_window(receipt.get('observed_unix'), created, 120, 'fresh room readback at grant creation')
    if at_entry:
        fresh_window(receipt.get('observed_unix'), now, 120, 'fresh room readback at case entry')
    return admission


def validate_control_config(config, request, context, now, artifact_reader=private_artifact):
    """Startup uses the unchanged [] validator; this gate is only for control.

    Status and stop can operate with [] for bootstrap/cleanup. A stop of the
    exact owned bridge also remains available after the short room receipt has
    expired; it grants no room action. All other scoped-room control, including
    state reads, requires the fresh pinned room admission and receipt.
    """
    require(request.get('role') == 'nora' and request.get('transport') == 'local-android', 'Nora-only transport')
    require(config.get('run_id') == RUN == context['run_id'], 'config run')
    require(config.get('jid') == OWN['nora'] == context['account'], 'config account')
    peers = config.get('allowed_jids')
    require(isinstance(peers, list) and len(peers) == len(set(peers)) == 2, 'two unique peers')
    require(set(peers) == {OWN['leon'], OWN['felix']}, 'exact owned peers')
    require(isinstance(config.get('password'), str) and bool(config['password']), 'private password present')
    rooms = config.get('allowed_rooms', [])
    require(rooms in ([], [ROOM]), 'exact room list')
    payload = request.get('payload', {})
    op = payload.get('op') if request.get('action') == 'command' else None
    require(request.get('action') in ('state', 'command', 'result'), 'controller action')
    if op is not None:
        require(op in READ_OR_STOP | ROOM_OPS, 'service-only controller operation')
    if op in READ_OR_STOP:
        require(set(payload) == {'op'}, 'status/stop has no room or hidden arguments')
    if op == 'stop':
        return None  # Normal exact-owner bridge cleanup, no room privilege.
    ref = request.get('room_admission')
    if rooms or op in ROOM_OPS or ref is not None:
        require(rooms == [ROOM], 'room authorization required')
        require(ref is not None, 'room admission required')
        admission = artifact_reader(ref, [context['derivation_root'], context['runtime_root']])
        validate_admission(admission, context, now, artifact_reader)
    else:
        admission = None
    if op in ROOM_OPS:
        expected = {'op', 'room', 'encryption'} | ({'text'} if op == 'send_text' else set())
        require(set(payload) == expected, 'exact room operation fields')
        require(payload['room'] == ROOM and payload['encryption'] == 'legacy', 'legacy fixture command')
        if op == 'send_text':
            require(isinstance(payload['text'], str), 'text type')
            prefix = RUN + ':persistent-service:nora:'
            require(payload['text'].startswith(prefix) and re.fullmatch('[0-9a-f]{32}', payload['text'][len(prefix):]) is not None,
                    'fresh scoped sender token')
    return admission


def claim_scenario_once(context, room_admission_ref, scenario_admission_ref):
    """Durable once-per-batch claim, created before the first product mutation.

    Never remove this claim automatically, including on partial/uncertain sends.
    A different admission file cannot authorize a second attempt in this batch.
    """
    require(re.fullmatch('[0-9a-f]{32}', context['batch_id']) is not None, 'claim batch')
    folder = Path(context['derivation_root']) / 'runtime-state' / 'operation-claims'
    folder.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = folder.lstat()
    require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid() and info.st_mode & 0o077 == 0,
            'private claim directory')
    target = folder / ('persistent-service-text-' + context['batch_id'] + '.json')
    value = {
        'scope': 'ONE_PERSISTENT_MIXED_SERVICE_TEXT_CASE_PER_BATCH_NO_RETRY',
        'run_id': RUN, 'batch_id': context['batch_id'],
        'runtime_freeze_sha256': context['runtime_freeze_sha256'],
        'session_binding': context['session_binding'], 'room': ROOM,
        'room_admission_sha256': room_admission_ref['sha256'],
        'scenario_admission_sha256': scenario_admission_ref['sha256'],
        'product_mutation_may_follow': True, 'automatic_retry': False,
    }
    fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, 'w', closefd=False) as stream:
            json.dump(value, stream, sort_keys=True)
            stream.write('\n')
            stream.flush()
            os.fsync(fd)
    finally:
        os.close(fd)
    directory_fd = os.open(folder, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)
    return str(target)

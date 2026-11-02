#!/usr/bin/env python3
"""Check actual source contracts only; no simulated observer or Vala execution."""
import hashlib
import json
from pathlib import Path
import resource

HERE = Path(__file__).resolve().parent
BASE = HERE.parent / 'auth-observer-driver'
ROOT = HERE.parents[4]
FILES = ('dinox_interop.vala', 'observer_scope.vala',
         'muji_presence_observer.vala', 'fingerprint_rewrite_observer.vala')


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def method(source, declaration):
    start = source.index(declaration)
    opening = source.index('{', start)
    depth = 1
    for end in range(opening + 1, len(source)):
        if source[end] == '{':
            depth += 1
        elif source[end] == '}':
            depth -= 1
        if depth == 0:
            return source[start:end + 1]
    raise AssertionError('Unbalanced method: ' + declaration)


def require_order(source, *tokens):
    positions = [source.index(token) for token in tokens]
    assert positions == sorted(positions), tokens


def main():
    checks = []
    old = (BASE / 'observer_scope.vala').read_text()
    new = (HERE / 'observer_scope.vala').read_text()
    base_manifest = json.loads((BASE / 'source-manifest.json').read_text())
    for name in FILES:
        assert sha(BASE / name) == base_manifest['files'][name]['sha256']
        if name != 'observer_scope.vala':
            assert (BASE / name).read_bytes() == (HERE / name).read_bytes()
    checks.append('compiled baseline source pins and three unchanged Vala files')

    ready = method(new, 'private void on_stream_ready(')
    attach = method(new, 'private void attach_ready(')
    detach = method(new, 'internal void detach()')
    status = method(new, 'internal Json.Object status()')
    finish = method(new, 'public void finish()')
    reduced = new.replace('    private uint attach_idle;\n', '')
    reduced = reduced.replace('    private XmppStream? pending_attach_stream;\n', '')
    reduced = reduced.replace(attach + '\n\n    ', '')
    for declaration in ('private void on_stream_ready(', 'internal void detach()', 'internal Json.Object status()'):
        reduced = reduced.replace(method(reduced, declaration), method(old, declaration))
    assert reduced == old
    checks.append('delta confined to lifecycle scheduling, detach cleanup and status')

    core = (ROOT / 'xmpp-vala/src/core/xmpp_stream.vala').read_text()
    interactor = (ROOT / 'libdino/src/service/stream_interactor.vala').read_text()
    require_order(core, 'stream_negotiated(this);', 'negotiation_complete = true;')
    getter = method(interactor, 'public XmppStream? get_connected_stream_for_action(')
    assert 'stream == null || !((!) stream).negotiation_complete' in getter
    assert 'get_connected_stream_for_action' not in ready
    assert ready.count('Idle.add(') == 1 and ready.count('attach_ready(account, candidate);') == 1
    assert 'Source.REMOVE' in ready and 'presence.attach(' not in ready and 'auth.attach(' not in ready
    checks.append('initial pre-flag signal reaches one deferred callback without weakening getter')

    require_order(ready, 'get_stream(owner) != candidate', 'detach();', 'pending_attach_stream = candidate;', 'Idle.add(')
    require_order(ready, 'attach_idle = 0; pending_attach_stream = null;', 'attach_ready(account, candidate);')
    for gate in ('finished', 'account != owner', 'account.id != owner_id', 'owner.id != owner_id',
                 '!owner.enabled', 'get_connected_stream_for_action(owner) != candidate'):
        assert gate in attach
    require_order(attach, 'get_connected_stream_for_action(owner) != candidate',
                  'Bind.Flag? bind', 'if (bind == null', 'stream = candidate;', 'presence.attach(candidate);', 'auth.attach(candidate);')
    for gate in ('!((!) bind).my_jid.equals_bare(owner.bare_jid)',
                 '((!) bind).my_jid.resourcepart == null || draft == null'):
        assert gate in attach
    checks.append('replacement before idle cannot attach stale candidate; exact account, Bind and draft gates retained')

    assert 'if (account == owner && state != ConnectionManager.ConnectionState.CONNECTED) detach();' in new
    require_order(detach, 'Source.remove(attach_idle)', 'pending_attach_stream = null;',
                  'if (stream == null) return;', 'presence.detach(old); auth.detach(old);')
    checks.append('offline and detach cancel pending idle even before first stream attachment')

    require_order(ready, '(stream == candidate && current(candidate)) || pending_attach_stream == candidate', 'detach();')
    checks.append('duplicate pending or already-current ready notification is idempotent')

    require_order(finish, 'if (finished) return;', 'detach(); finished = true;', 'Source.remove(timer)')
    assert 'account_removed.connect' in new and 'if (account == owner) finish();' in new
    assert 'SignalHandler.disconnect(app.stream_interactor, negotiated_handler)' in finish
    checks.append('owner removal and finish cancel pending callback and disconnect future ready signals')

    require_order(status, 'bool attached = stream != null && current((!) stream);',
                  '"actual_attached", attached', '"late_attach_pending", attach_idle != 0')
    for token in ('"stream_generation", generation', '"local_full_jid", attached ? local_full : ""',
                  '"real_draft_module_present", attached &&', '"observation_only_no_blanket_call_auth_claim", true'):
        assert token in status
    checks.append('pre-call status derives attachment and draft presence from actual current stream')

    for declaration in ('internal bool current(', 'internal Json.Object? own_public_binding(',
                        'internal Json.Object? public_binding(', 'internal void emit('):
        assert method(new, declaration) == method(old, declaration)
    for forbidden in ('identity_key_private', 'identity_key_pair', '.save_identity(', '.store_session(',
                      '.set_device_trust(', '.get_session('):
        assert forbidden not in new
    for cap in ('MAX_RECORDS = 1024', 'MAX_BYTES = 4 * 1024 * 1024', 'MAX_DURATION_US = 2700'):
        assert cap in new
    checks.append('public-only binding, current validation, bounded private output and security filter source unchanged')

    receipt = {
        'schema_version': 1,
        'scope': 'ACTUAL_SOURCE_CONTRACT_CHECKS_ONLY_NO_MIRROR_NO_VALA_EXECUTION',
        'checks': checks,
        'passed': True,
        'check_count': len(checks),
        'source_sha256': {name: sha(HERE / name) for name in FILES},
        'check_source_sha256': sha(Path(__file__)),
        'baseline_manifest_sha256': sha(BASE / 'source-manifest.json'),
        'no_native_compile_or_runtime': True,
        'no_network_or_client_operations': True,
        'not_proven': ['Vala compilation', 'actual Mainloop lifecycle execution',
                       'live hook attachment', 'cryptographic verification', 'engine DTLS/media binding'],
    }
    (HERE / 'offline-source-contract-checks.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(receipt, indent=2))


if __name__ == '__main__':
    resource.setrlimit(resource.RLIMIT_AS, (128 * 1024**2, 128 * 1024**2))
    resource.setrlimit(resource.RLIMIT_CPU, (5, 5))
    main()

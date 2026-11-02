#!/usr/bin/env python3
"""Actual-source contract and differential checks; no Vala, crypto or model execution."""
import ast
import hashlib
import json
from pathlib import Path
import re
import resource

HERE = Path(__file__).resolve().parent
BASE = HERE.parent / 'auth-observer-late-attach-20261016'
ROOT = HERE.parents[4]
CACHE = ROOT / 'local/muji-device-binding-auth-20261016/native-core52-late-attach-20261016T190802Z/actual-server-job/artifacts/plugin'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def method(source, declaration):
    start = source.index(declaration)
    opening = source.index('{', start)
    depth = 1
    for end in range(opening + 1, len(source)):
        depth += (source[end] == '{') - (source[end] == '}')
        if depth == 0:
            return source[start:end + 1]
    raise AssertionError(declaration)


def order(source, *tokens):
    positions = [source.index(token) for token in tokens]
    assert positions == sorted(positions), tokens


def main():
    checks = []
    assert sha(BASE / 'observer_scope.vala') == '98c17792e5cf531db6758c5279dcaeb8bd655c4b4602ac0eee0910e61a4aa38c'
    for name in ('dinox_interop.vala', 'muji_presence_observer.vala'):
        assert (HERE / name).read_bytes() == (BASE / name).read_bytes()
    checks.append('98c baseline pinned; Driver and Presence translation units byte-identical')
    old = (BASE / 'observer_scope.vala').read_text()
    new = (HERE / 'observer_scope.vala').read_text()
    assert old.split('    // Reads only selected-account', 1)[0] == new.split('    // Pre-filter pin only:', 1)[0]
    assert old.split('    internal void note_unavailable', 1)[1] == new.split('    internal void note_unavailable', 1)[1]
    checks.append('Own binding, exact stream/account lifecycle, output limits and status untouched')
    auth_old = (BASE / 'fingerprint_rewrite_observer.vala').read_text()
    auth = (HERE / 'fingerprint_rewrite_observer.vala').read_text()
    reduced = auth
    for declaration in ('private void before_filters(', 'public void prepare_receive('):
        reduced = reduced.replace(method(reduced, declaration), method(auth_old, declaration))
    assert reduced == auth_old
    checks.append('Auth delta confined to pre-filter pins/diagnostics and post-rewrite public proof; envelope/shape/pending/filter lifecycle untouched')
    api = (CACHE / 'omemo.vapi').read_text()
    assert sha(CACHE / 'omemo.vapi') == 'a4cc13c98b054588d7d34188b57a78e346cb6280dd4619c31463f6a202bb715b'
    assert 'public Omemo.SessionRecord load_session (Omemo.Address other) throws GLib.Error;' in api
    wrapper = method((ROOT / 'plugins/omemo/src/native/store.vala').read_text(), 'public SessionRecord load_session (')
    order(wrapper, 'ensure_persistence_ready();', 'Protocol.Session.load_session (native_context, out record, other)', 'return record;')
    assert 'int32 version = 3' in (ROOT / 'plugins/omemo/vapi/libomemo-c.vapi').read_text()
    assert 'class BackedSessionStore' not in api and 'native_context' not in method(new, 'internal Json.Object? public_binding(').split('try {', 1)[0]
    checks.append('Reviewed public Store.load_session wrapper enforces persistence and delegates to version-3 native loader; backing-owner method not public')
    binding = method(new, 'internal Json.Object? public_binding(')
    code = re.sub(r'//[^\n]*', '', binding)
    for forbidden in ('store.native_context', '.is_persistence_ready', 'store.registration_pending', '.belongs_to(', 'record.serialize', 'record.user_record',
                      'identity_key_private', 'identity_key_pair', '.record_base64', '.get_session(', '.save_identity(', '.store_session(',
                      '.perform(', '.update(', 'e.message', 'get_deep_string_content'):
        assert forbidden not in code, forbidden
    checks.append('Public APIs only; no internal shim, session/private serialization, ciphertext/body access, store/DB/trust mutation or exception-text export')
    order(binding, 'database.identity.get_id_checked(owner_id)', '"registration"', 'database.identity.registration_pending',
          '"peer_public_identity_not_accepted"', 'store.contains_session(address)', 'store.load_session(address)',
          'record.state.session_version != 3', 'record.state.remote_identity_key', 'public_hex(((!) remote_public).serialize())',
          'session_hex != row.get_string_member("peer_public_identity_hex")', 'store.identity_key_store.load_identity(address)',
          'memory_public != null && public_hex(memory_public) != session_hex', '"current_identity_recheck"', 'return row;')
    assert binding.count('return row;') == 1
    assert 'if (session_hex == null)' in binding and 'if (remote_public == null)' in binding
    checks.append('Only success return requires an existing version-3 session, valid public remote key and equality to selected-account metadata before optional MemoryMap handling')
    for required in ('store.session_store != session_store', '((!) module).store != store', 'current(candidate)',
                     'ready_after == null', '((!) ready_after)[database.identity.id] != identity',
                     '((!) ready_after)[database.identity.registration_pending]',
                     'current_public.get_int_member("own_device_id") != row.get_int_member("own_device_id")',
                     'current_public.get_string_member("own_public_identity_hex") != row.get_string_member("own_public_identity_hex")',
                     'current_public.get_string_member("peer_public_identity_hex") != session_hex', 'peer_identity_changed', 'TrustLevel.VERIFIED'):
        assert required in binding, required
    checks.append('Own public identity/device, registration, selected DB identity, accepted peer trust, store object and exact current stream rechecked before success')
    before = method(auth, 'private void before_filters(')
    after = method(auth, 'public void prepare_receive(')
    assert 'public_before = scope.public_metadata_binding(stream, iq.from, shape.sender_device);' in before
    assert 'own_before = scope.own_public_binding(stream);' in before
    assert '"before_filters", out before_diagnostic' in before
    assert '"pre_filter_metadata_is_session_auth_proof", false' in before
    order(before, 'public_before = scope.public_metadata_binding', 'scope.emit(row)', 'new PendingFingerprintObservation')
    order(after, 'before.generation != scope.generation', 'after.signature != before.shape',
          'scope.public_binding(stream, iq.from, before.device,', '"after_real_draft_rewrite", out after_diagnostic',
          'public_after.get_boolean_member("public_session_equals_metadata")', '"public_identity_bound", public_bound')
    checks.append('Pending metadata pin independent of pre-existing session; only matching post-Draft SID/generation/shape plus session proof can bind')
    assert 'bool public_bound = after.plain == 1 && public_after != null' in after
    assert 'if (after.plain != 1)' in after and '"multiple_fingerprints_not_individually_proven"' in after
    checks.append('Only a single rewritten fingerprint can bind; multi-fingerprint IQs remain observations without individual decryption-origin proof')
    assert '"native_memory_present", memory_public != null' in binding
    assert '"public_native_store_equals_metadata", memory_public != null' in binding
    assert '"session_public_identity_matches_native_memory_absent"' in binding
    assert '"public_session_equals_metadata", true' in binding
    checks.append('Absent MemoryMap is explicitly distinct from matching MemoryMap and accepted only after required session-public equality')
    for token in ('"stage", stage', '"step",', '"reason",', '"public_session_origin",',
                  '"backing_belongs_to_not_public"', '"backing_owner_independently_verified", false',
                  '"native_memory_checked", false', '"public_session_equals_metadata", false'):
        assert token in binding, token
    assert '"public_identity_binding_diagnostic", after_diagnostic' in after
    assert '"engine_DTLS_media_binding_proven_by_this_event", false' in after
    checks.append('Bounded diagnostics expose stage/reason/public-key origin and unavailable backing-owner API; engine/DTLS/media claim remains false')
    sources = {p.name: {'sha256': sha(p), 'bytes': p.stat().st_size} for p in sorted(HERE.glob('*.vala'))}
    receipt = {'scope': 'ACTUAL_SOURCE_CONTRACTS_AND_DIFFERENTIAL_AUDIT_ONLY_NO_VALA_CRYPTO_OR_RUNTIME',
               'passed': True, 'checks': checks, 'check_count': len(checks), 'sources': sources,
               'checker_sha256': sha(Path(__file__)), 'baseline_manifest_sha256': sha(BASE / 'source-manifest.json'),
               'not_executed': ['Vala compile', 'native SessionRecord load', 'cryptographic authentication', 'live post-Draft observation', 'DTLS/media verification']}
    (HERE / 'offline-source-contract-checks.json').write_text(json.dumps(receipt, indent=2) + '\n')
    audit = {'scope': 'SOURCE_ONLY_DIFFERENTIAL_AUDIT', 'baseline': str(BASE), 'baseline_scope_sha256': sha(BASE / 'observer_scope.vala'),
             'changed_translation_units': ['observer_scope.vala', 'fingerprint_rewrite_observer.vala'],
             'unchanged_translation_units': ['dinox_interop.vala', 'muji_presence_observer.vala'],
             'unchanged_shared_regions': ['all source before public binding helpers including own_public_binding', 'all source after public binding helpers'],
             'unchanged_auth_regions': ['all source outside before_filters and prepare_receive'], 'sources': sources,
             'public_api_limit': 'BackedSessionStore.belongs_to and Store internal readiness flags are not in reviewed public VAPI; no false independent backing-owner verification',
             'runtime_or_current_run_authentication_proven': False}
    (HERE / 'differential-source-audit.json').write_text(json.dumps(audit, indent=2) + '\n')
    print(json.dumps(receipt, indent=2))


if __name__ == '__main__':
    resource.setrlimit(resource.RLIMIT_AS, (128 * 1024**2, 128 * 1024**2))
    resource.setrlimit(resource.RLIMIT_CPU, (5, 5))
    main()

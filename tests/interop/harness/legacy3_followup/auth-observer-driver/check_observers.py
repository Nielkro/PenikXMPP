#!/usr/bin/env python3
"""Synthetic contract mocks + actual Vala source guards, NOT Vala/runtime tests."""
import copy
import hashlib
import json
from pathlib import Path
import re
import resource
import unittest
import xml.etree.ElementTree as E

HERE = Path(__file__).resolve().parent
J = 'urn:xmpp:jingle:1'
ICE = 'urn:xmpp:jingle:transports:ice-udp:1'
DTLS = 'urn:xmpp:jingle:apps:dtls:0'
DRAFT = 'http://gultsch.de/xmpp/drafts/omemo/dlts-srtp-verification'
OMEMO = 'eu.siacs.conversations.axolotl'
MUJI = 'urn:xmpp:muji:0'
ROOM = 'fixture@conference.dinox.im'
OWN = 'leon.fischer.interop.de.71115b@dinox.im/native-leon'
PEER = 'felix.wagner.interop.de.71115b@dinox.im/native-felix'
TEST_BARES = {f'{name}.interop.de.71115b@dinox.im' for name in
              ('leon.fischer', 'felix.wagner', 'nora.schneider')}


def number(raw):
    if raw is None or not 0 < len(raw) <= 10 or not raw.isascii() or not raw.isdigit():
        return 0
    value = int(raw)
    return value if value <= 2147483647 else 0


def iq_fixture(contents=('audio',), device='14234', wrapped=True):
    iq = E.Element('iq', {'id': 'iq-1', 'from': PEER, 'to': OWN, 'type': 'set'})
    jingle = E.SubElement(iq, f'{{{J}}}jingle', {'sid': 'sid-1', 'action': 'session-initiate'})
    E.SubElement(jingle, f'{{{MUJI}}}muji', {'room': ROOM})
    for name in contents:
        content = E.SubElement(jingle, f'{{{J}}}content', {'name': name, 'creator': 'initiator'})
        transport = E.SubElement(content, f'{{{ICE}}}transport')
        fp = E.SubElement(transport, f'{{{DRAFT if wrapped else DTLS}}}fingerprint', {'hash': 'sha-256', 'setup': 'actpass'})
        if wrapped:
            encrypted = E.SubElement(fp, f'{{{OMEMO}}}encrypted')
            header = E.SubElement(encrypted, f'{{{OMEMO}}}header', {'sid': device})
            E.SubElement(header, f'{{{OMEMO}}}key', {'rid': '172062497'}).text = 'KEY-DO-NOT-LOG'
            E.SubElement(encrypted, f'{{{OMEMO}}}payload').text = 'CIPHER-DO-NOT-LOG'
        else:
            fp.text = 'PUBLIC-DTLS-NOT-EXPORTED'
    return iq


def shape(iq):
    jingle = iq.find(f'{{{J}}}jingle')
    if jingle is None:
        return None
    result = {'wrapped': 0, 'plain': 0, 'device': 0, 'valid': True, 'contents': [], 'signature': []}
    seen = set()
    for content in jingle.findall(f'{{{J}}}content'):
        name, creator = content.get('name'), content.get('creator')
        result['valid'] &= bool(name) and name not in seen
        seen.add(name)
        formats, wrapped, plain = [], 0, 0
        transports = content.findall(f'{{{ICE}}}transport')
        for transport in transports:
            for fp in transport:
                if fp.tag.rsplit('}', 1)[-1] != 'fingerprint':
                    continue
                formats.append((fp.get('hash'), fp.get('setup')))
                if fp.tag == f'{{{DTLS}}}fingerprint':
                    plain += 1
                elif fp.tag == f'{{{DRAFT}}}fingerprint':
                    wrapped += 1
                    headers = fp.findall(f'{{{OMEMO}}}encrypted/{{{OMEMO}}}header')
                    value = number(headers[0].get('sid')) if len(headers) == 1 else 0
                    result['valid'] &= value > 0 and result['device'] in (0, value)
                    if result['device'] == 0:
                        result['device'] = value
                else:
                    result['valid'] = False
        result['wrapped'] += wrapped
        result['plain'] += plain
        result['contents'].append({'name': name, 'wrapped': wrapped, 'plain': plain})
        result['signature'].append((name, creator, len(transports), tuple(formats), wrapped + plain))
    result['valid'] &= bool(seen)
    return result


def simulated_draft_rewrite(iq):
    """A mock successful filter, NOT cryptographic validation or an OMEMO test."""
    for fp in iq.iter(f'{{{DRAFT}}}fingerprint'):
        fp.tag = f'{{{DTLS}}}fingerprint'
        fp[:] = []
        fp.text = 'PUBLIC-DTLS-NOT-EXPORTED'


class PipelineMock:
    def __init__(self):
        self.generation = 1
        self.current = True
        self.pending = {}
        self.records = []

    def envelope(self, iq):
        jingle = iq.find(f'{{{J}}}jingle')
        if not self.current or jingle is None or iq.get('type') != 'set' or iq.get('from') != PEER or iq.get('to') not in (None, OWN, OWN.split('/')[0]):
            return None
        muji = jingle.find(f'{{{MUJI}}}muji')
        if muji is None or muji.get('room') != ROOM:
            return None
        return (self.generation, iq.get('id'), iq.get('from'), iq.get('to'), jingle.get('sid'), jingle.get('action'), muji.get('room'))

    def before(self, iq):
        key, before = self.envelope(iq), shape(iq)
        if key and before:
            self.records.append(copy.deepcopy(before))
            if before['valid'] and before['wrapped'] > 0 and before['plain'] == 0:
                self.pending[key] = copy.deepcopy(before)

    def after(self, iq, public_bound=True):
        key, after = self.envelope(iq), shape(iq)
        before = self.pending.pop(key, None)
        if before and after['valid'] and after['wrapped'] == 0 and after['plain'] == before['wrapped'] and after['signature'] == before['signature']:
            event = {'rewrite_succeeded': True, 'public_identity_bound': public_bound, 'device': before['device'],
                     'media_binding_proven': False, 'contents_after': after['contents']}
            self.records.append(event)
            return event
        return None

    def detach(self):
        self.current = False
        self.generation += 1
        self.pending.clear()


class ContractTests(unittest.TestCase):
    def test_01_device_numeric_edges(self):
        for raw in [None, '', '0', '-1', '+1', ' 1', '1 ', '2147483648', '99999999999', '١٢']:
            self.assertEqual(number(raw), 0, raw)
        for raw in ['12210', '172062497', '2147483647', '0000012210']:
            self.assertEqual(number(raw), int(raw))

    def test_02_success_exact_iq_and_no_sensitive_values(self):
        pipeline, iq = PipelineMock(), iq_fixture()
        pipeline.before(iq); simulated_draft_rewrite(iq)
        event = pipeline.after(iq)
        self.assertTrue(event['rewrite_succeeded']); self.assertTrue(event['public_identity_bound'])
        self.assertEqual(event['device'], 14234); self.assertFalse(event['media_binding_proven'])
        serialized = json.dumps(pipeline.records)
        for private in ['KEY-DO-NOT-LOG', 'CIPHER-DO-NOT-LOG', 'PUBLIC-DTLS-NOT-EXPORTED']:
            self.assertNotIn(private, serialized)

    def test_03_two_contents_exact_counts(self):
        pipeline, iq = PipelineMock(), iq_fixture(('audio', 'video'))
        pipeline.before(iq); simulated_draft_rewrite(iq)
        event = pipeline.after(iq)
        self.assertEqual([x['plain'] for x in event['contents_after']], [1, 1])

    def test_04_veto_skips_postfilter(self):
        pipeline, iq = PipelineMock(), iq_fixture()
        pipeline.before(iq)
        try:
            raise PermissionError('mock real security-filter veto')
        except PermissionError:
            pass
        self.assertFalse(any(x.get('rewrite_succeeded') for x in pipeline.records))

    def test_05_plain_is_never_omemo_success(self):
        pipeline, iq = PipelineMock(), iq_fixture(wrapped=False)
        pipeline.before(iq); self.assertIsNone(pipeline.after(iq))

    def test_06_mixed_and_remaining_wrapper_are_not_success(self):
        for mixed in [False, True]:
            pipeline, iq = PipelineMock(), iq_fixture()
            if mixed:
                transport = next(iq.iter(f'{{{ICE}}}transport'))
                E.SubElement(transport, f'{{{DTLS}}}fingerprint')
            pipeline.before(iq); self.assertIsNone(pipeline.after(iq))

    def test_07_exact_envelope_changes_fail_closed(self):
        for field in ['id', 'from', 'to', 'sid', 'action', 'room']:
            pipeline, iq = PipelineMock(), iq_fixture()
            pipeline.before(iq); simulated_draft_rewrite(iq)
            if field in ('id', 'from', 'to'):
                iq.set(field, 'different')
            elif field == 'room':
                iq.find(f'{{{J}}}jingle/{{{MUJI}}}muji').set(field, 'other@conference.dinox.im')
            else:
                iq.find(f'{{{J}}}jingle').set(field, 'different')
            self.assertIsNone(pipeline.after(iq), field)

    def test_08_exact_content_shape_changes_fail_closed(self):
        for field in ['name', 'creator', 'hash', 'setup']:
            pipeline, iq = PipelineMock(), iq_fixture()
            pipeline.before(iq); simulated_draft_rewrite(iq)
            target = next(iq.iter(f'{{{J}}}content')) if field in ('name', 'creator') else next(iq.iter(f'{{{DTLS}}}fingerprint'))
            target.set(field, 'different'); self.assertIsNone(pipeline.after(iq), field)

    def test_09_stream_replacement_and_detach_no_proof(self):
        pipeline, iq = PipelineMock(), iq_fixture()
        pipeline.before(iq); pipeline.detach(); simulated_draft_rewrite(iq)
        self.assertIsNone(pipeline.after(iq)); self.assertFalse(pipeline.pending)

    def test_10_invalid_or_conflicting_device_no_proof(self):
        for raw in ['0', '-1', '2147483648', 'not-a-device']:
            pipeline, iq = PipelineMock(), iq_fixture(device=raw)
            pipeline.before(iq); simulated_draft_rewrite(iq)
            self.assertIsNone(pipeline.after(iq), raw)
        pipeline, iq = PipelineMock(), iq_fixture(('audio', 'video'))
        list(iq.iter(f'{{{OMEMO}}}header'))[1].set('sid', '12210')
        pipeline.before(iq); simulated_draft_rewrite(iq); self.assertIsNone(pipeline.after(iq))

    def test_11_public_binding_failure_does_not_invent_auth(self):
        pipeline, iq = PipelineMock(), iq_fixture()
        pipeline.before(iq); simulated_draft_rewrite(iq)
        event = pipeline.after(iq, public_bound=False)
        self.assertTrue(event['rewrite_succeeded']); self.assertFalse(event['public_identity_bound'])

    def test_12_copy_before_xml_mutation(self):
        pipeline, iq = PipelineMock(), iq_fixture()
        pipeline.before(iq); before = next(iter(pipeline.pending.values()))
        simulated_draft_rewrite(iq)
        self.assertEqual(before['wrapped'], 1); self.assertEqual(before['plain'], 0)

    def test_13_presence_dialect_observation_not_policy(self):
        for attr, nested in [('12210', []), (None, ['12210']), ('12210', ['12210']), ('12210', ['14234']), (None, ['12210', '14234'])]:
            muji = E.Element(f'{{{MUJI}}}muji')
            if attr is not None: muji.set('device', attr)
            for device in nested: E.SubElement(muji, f'{{{DRAFT}}}device', {'id': device})
            metadata = {'attribute': muji.get('device'), 'children': [x.get('id') for x in muji.findall(f'{{{DRAFT}}}device')]}
            self.assertEqual(metadata, {'attribute': attr, 'children': nested})

    def test_14_sources_readonly_and_no_cipher_serialization(self):
        auth = (HERE / 'fingerprint_rewrite_observer.vala').read_text()
        presence = (HERE / 'muji_presence_observer.vala').read_text()
        shared = (HERE / 'observer_scope.vala').read_text()
        pending = auth.split('class PendingFingerprintObservation', 1)[1].split('class FingerprintRewriteObserver', 1)[0]
        self.assertNotIn('StanzaNode', pending.split('{', 1)[1])
        for forbidden in ['.put_node(', '.put_attribute(', '.set_attribute(', '.remove(', 'get_deep_string_content(', '.to_string() +']:
            self.assertNotIn(forbidden, auth)
        self.assertNotIn('iq.stanza.to_string', auth)
        self.assertIn('received_node.connect(on_incoming)', presence)
        self.assertIn('pre_send_presence_stanza.connect_after', presence)
        self.assertIn('outgoing_muji_presence_PREWRITE_ONLY', presence)
        self.assertIn('serialized_muji_xml', presence)
        self.assertNotIn('muji.to_string()', presence)
        self.assertIn('detached_xml_copy(muji).to_xml()', presence)
        self.assertIn('new StanzaNode.build(original.name, original.ns_uri ?? "").add_self_xmlns()', presence)
        self.assertNotIn('original.put_', presence)
        for forbidden in ['identity_key_private', 'identity_key_pair', '.save_identity(', '.store_session(', '.set_device_trust(', '.get_session(']:
            self.assertNotIn(forbidden, shared)

    def test_15_sources_lifecycle_limits_and_public_binding(self):
        shared = (HERE / 'observer_scope.vala').read_text()
        auth = (HERE / 'fingerprint_rewrite_observer.vala').read_text()
        for required in ['MAX_RECORDS = 1024', 'MAX_BYTES = 4 * 1024 * 1024', 'MAX_DURATION_US = 2700',
                         'FileCreateFlags.PRIVATE', 'stream_resumed.connect(on_stream_ready)',
                         'connection_state_changed.connect', 'owner.id != owner_id', 'get_connected_stream_for_action(owner) != candidate',
                         'metadata_hex != native_hex', 'own_public_binding', 'identity_key_store.load_identity(address)',
                         'Bytes? own_public =', 'if (own_public == null) return null;', 'presence.detach(old); auth.detach(old)']:
            self.assertIn(required, shared)
        own_function = shared.split('internal Json.Object? own_public_binding', 1)[1].split('// Reads only', 1)[0]
        self.assertLess(own_function.index('if (own_device == 0 || own_device > int.MAX) return null;'),
                        own_function.index('identity_key_store.identity_key_public'))
        self.assertLess(own_function.index('if (own_public == null) return null;'),
                        own_function.index('((!) own_public).get_data()'))
        for required in ['add_incoming_request_filter(this)', 'remove_incoming_request_filter(this)',
                         'pending.clear(); collisions.clear()', 'pending.size >= 64', '30 * 1000000L',
                         'before.generation != scope.generation', 'after.signature != before.shape',
                         'after.wrapped != 0', 'after.plain != before.fingerprints', 'before.before_own_device',
                         'before.before_peer_public', 'peer_identity_changed', 'Dino.Plugins.Omemo.TrustLevel.VERIFIED']:
            self.assertIn(required, auth)

    def test_16_safe_stop_and_exact_baseline_preserved(self):
        baseline = HERE.parent / 'future-safe-driver/dinox_interop.vala'
        self.assertEqual(hashlib.sha256(baseline.read_bytes()).hexdigest(), 'e4651db3a3b12eb9d5ef81238ff1aa5099306484c53c95dda3ea6ae2423ff882')
        driver = (HERE / 'dinox_interop.vala').read_text()
        self.assertIn('connection_manager.disconnect_account((!) account)', driver)
        self.assertNotIn('yield app.stream_interactor.disconnect_account', driver)
        self.assertEqual(driver.count('app.stream_interactor.connect_account(fresh);'), 1)
        self.assertIn('else start_observers();', driver)
        self.assertIn('driver.finish_observers();', driver)

    def test_17_actual_source_pipeline_order_is_bound(self):
        root = Path('/media/linux/SSD128/xmppwin')
        stream = (root / 'xmpp-vala/src/core/xmpp_stream.vala').read_text()
        iq = (root / 'xmpp-vala/src/module/iq/module.vala').read_text()
        stream = stream.split('private async void handle_stanza', 1)[1]
        self.assertLess(stream.index('received_node(this, node)'), stream.index('received_presence_stanza(this, node)'))
        iq = iq.split('private async void process_received_iq_stanza', 1)[1]
        self.assertLess(iq.index('preprocess_incoming_iq_set_get (stream, iq)'), iq.index('filter.prepare_receive (stream, iq)'))
        self.assertLess(iq.index('filter.prepare_receive (stream, iq)'), iq.index('interceptor.try_handle_iq_set'))

    def test_18_presence_xml_inherited_namespaces_roundtrip_and_no_mutation(self):
        wrapper = E.fromstring(f'''<root xmlns="urn:wrapper" xmlns:m="{MUJI}" xmlns:d="{DRAFT}" xmlns:p="urn:public-extra">
          <m:muji device="12210"><d:device id="12210"/><m:content p:marker="one &amp; two"><m:preparing/></m:content></m:muji>
        </root>''')
        original = wrapper.find(f'{{{MUJI}}}muji')
        untouched = E.tostring(wrapper)
        # Independent desired-output mock: copied detached XML must parse alone.
        serialized = E.tostring(copy.deepcopy(original), encoding='unicode')
        parsed = E.fromstring(serialized)
        self.assertEqual(parsed.tag, f'{{{MUJI}}}muji')
        self.assertEqual(parsed.find(f'{{{DRAFT}}}device').get('id'), '12210')
        self.assertEqual(parsed.find(f'{{{MUJI}}}content').get('{urn:public-extra}marker'), 'one & two')
        self.assertEqual(E.tostring(wrapper), untouched)
        self.assertNotIn('<{', serialized)


if __name__ == '__main__':
    resource.setrlimit(resource.RLIMIT_AS, (128 * 1024**2, 128 * 1024**2))
    resource.setrlimit(resource.RLIMIT_CPU, (5, 5))
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(ContractTests)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    receipt = {'scope': 'SOURCE_ONLY_SYNTHETIC_CONTRACT_MOCKS_AND_REAL_SOURCE_GUARDS_NOT_VALA_OR_RUNTIME_TESTS',
               'tests': result.testsRun, 'failures': len(result.failures), 'errors': len(result.errors),
               'skipped': len(result.skipped), 'passed': result.wasSuccessful(),
               'source_sha256': {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in HERE.glob('*.vala')},
               'test_source_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
               'native_compile_run': False, 'network_or_client_started': False}
    (HERE / 'offline-observer-contract-checks.json').write_text(json.dumps(receipt, indent=2) + '\n')
    raise SystemExit(not result.wasSuccessful())

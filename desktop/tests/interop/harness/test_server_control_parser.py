#!/usr/bin/env python3
"""Pure parser/scope checks only; no Docker, ADB, app or server is contacted."""
import ast
import hashlib
import io
import json
from pathlib import Path
import runpy
import tarfile
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
MODULE = runpy.run_path(str(HERE / 'server_control.py'), run_name='parser_only')
SCOPE = {'__name__': 'parser_only'}
exec(compile(MODULE['CONTROL_CODE'], '<fixed-container-code>', 'exec'), SCOPE)
validate = SCOPE['validate']
normalise = SCOPE['normalise']
ControlError = SCOPE['ControlError']
IDENTIFIER = 'a' * 32
CONFIG = {'run_id': '20261015-71115b', 'jid': SCOPE['OWN']['leon'],
          'allowed_jids': [SCOPE['OWN']['nora'], SCOPE['OWN']['felix']],
          'password': 'private-password-example', 'db_key': 'private-database-key-example'}


class ParserTests(unittest.TestCase):
    def test_local_transport_is_explicit_and_first_device_only(self):
        envelope = MODULE['validate_envelope']({'role': 'nora', 'action': 'state'})
        self.assertEqual(envelope['transport'], 'server')
        self.assertEqual(MODULE['validate_envelope'](dict(envelope, transport='local-android'))['role'], 'nora')
        for role, transport in (('leon', 'local-android'), ('felix', 'local-android'), ('nora', 'automatic')):
            with self.assertRaises(ValueError):
                MODULE['validate_envelope']({'role': role, 'action': 'state', 'transport': transport})

    def test_all_roles_and_wait_endpoints(self):
        for role in ('nora', 'leon', 'felix'):
            for wait in (0, 60):
                self.assertEqual(validate({'role': role, 'action': 'state', 'wait': wait})['wait'], wait)

    def test_default_wait_is_zero(self):
        self.assertEqual(validate({'role': 'leon', 'action': 'state'})['wait'], 0)

    def test_out_of_range_and_nonfinite_waits_fail(self):
        for wait in (-1, 61, True, float('nan'), float('inf'), '10'):
            with self.assertRaises(ControlError):
                validate({'role': 'leon', 'action': 'state', 'wait': wait})

    def test_foreign_role_or_action_fails(self):
        for role, action in [('someone', 'state'), ('leon', 'start'), ('nora', 'config')]:
            with self.assertRaises(ControlError):
                validate({'role': role, 'action': action})

    def test_exact_uuid_required(self):
        for identifier in ('../config', 'a' * 31, 'b' * 33, 'g' * 32, 'a;id', None):
            with self.assertRaises(ControlError):
                validate({'role': 'leon', 'action': 'result', 'id': identifier})

    def test_reserved_request_fields_rejected(self):
        for key in ('id', 'run_id'):
            with self.assertRaises(ControlError):
                validate({'role': 'leon', 'action': 'command', 'id': IDENTIFIER,
                          'payload': {'op': 'status', key: 'replacement'}})

    def test_alias_comes_only_from_allowlist(self):
        result = normalise({'op': 'contact', 'peer': 'NoRa'}, CONFIG, 'leon', IDENTIFIER)
        self.assertEqual(result['peer'], CONFIG['allowed_jids'][0])
        reduced = dict(CONFIG, allowed_jids=[SCOPE['OWN']['felix']])
        with self.assertRaises(ControlError):
            normalise({'op': 'contact', 'peer': 'nora'}, reduced, 'leon', IDENTIFIER)

    def test_self_and_foreign_peers_fail(self):
        for peer in ('leon', CONFIG['jid'], 'stranger@example.org', 'nora\nanything'):
            with self.assertRaises(ControlError):
                normalise({'op': 'chat', 'peer': peer}, CONFIG, 'leon', IDENTIFIER)

    def test_foreign_private_config_fails(self):
        for key, value in [('jid', 'foreign@example.org'), ('run_id', 'other-run'),
                           ('allowed_jids', ['foreign@example.org'])]:
            with self.assertRaises(ControlError):
                normalise({}, dict(CONFIG, **{key: value}), 'leon', IDENTIFIER)

    def test_duplicate_allowlist_fails(self):
        with self.assertRaises(ControlError):
            normalise({}, dict(CONFIG, allowed_jids=[SCOPE['OWN']['nora']] * 2), 'leon', IDENTIFIER)

    def test_request_stays_data_and_call_identity_is_not_filled(self):
        payload = {'op': 'send_text', 'peer': 'nora', 'text': '20261015-71115b: $(touch /tmp/never); "quoted"\ntext'}
        result = normalise(payload, CONFIG, 'leon', IDENTIFIER)
        self.assertEqual(result['text'], payload['text'])
        self.assertNotIn('call_id', normalise({'op': 'accept_call'}, CONFIG, 'leon', IDENTIFIER))
        self.assertNotIn('trusted', normalise({'op': 'status'}, CONFIG, 'leon', IDENTIFIER))
        self.assertEqual(normalise({'op': 'hangup', 'call_id': 37}, CONFIG, 'leon', IDENTIFIER)['call_id'], 37)

    def test_secret_redaction_never_returns_config(self):
        result = SCOPE['redact']({'config': CONFIG, 'nested': ['error ' + CONFIG['password']],
                                 'database_password': 'irrelevant'}, CONFIG)
        text = json.dumps(result)
        self.assertNotIn(CONFIG['password'], text)
        self.assertNotIn(CONFIG['db_key'], text)
        self.assertEqual(result['config'], '[redacted]')

    def test_no_shell_subprocess_or_shell_json_interpolation(self):
        tree = ast.parse(MODULE['CONTROL_CODE'])
        for node in ast.walk(tree):
            if isinstance(node, ast.Call):
                self.assertFalse(any(k.arg == 'shell' and isinstance(k.value, ast.Constant) and k.value.value
                                     for k in node.keywords))
        self.assertNotIn("'sh','-c'", MODULE['CONTROL_CODE'])

    def test_inner_error_keeps_nonce_without_config_output(self):
        import contextlib
        import io
        import sys
        original_control, original_stdin = SCOPE['control'], sys.stdin
        def fail_after_publish(value):
            raise OSError('private transport detail must stay hidden')
        SCOPE['control'] = fail_after_publish
        request = {'role': 'nora', 'action': 'command', 'id': IDENTIFIER,
                   'payload': {'op': 'status'}, 'wait': 0}
        output = io.StringIO()
        try:
            sys.stdin = io.StringIO(json.dumps(request))
            with contextlib.redirect_stdout(output), self.assertRaises(SystemExit):
                SCOPE['main']()
        finally:
            SCOPE['control'], sys.stdin = original_control, original_stdin
        result = json.loads(output.getvalue())
        self.assertEqual(result['id'], IDENTIFIER)
        self.assertEqual(result['role'], 'nora')
        self.assertTrue(result['submission_outcome_unknown'])
        self.assertNotIn('private transport detail', output.getvalue())


class InstrumentationParserTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.runtime = runpy.run_path(str(HERE / 'local_android_runtime.py'), run_name='parser_only')

    def transcript(self, cases, skipped=False):
        lines = []
        for index, (owner, name) in enumerate(cases):
            lines += ['INSTRUMENTATION_STATUS: class=' + owner,
                      'INSTRUMENTATION_STATUS: test=' + name,
                      'INSTRUMENTATION_STATUS: numtests=8',
                      'INSTRUMENTATION_STATUS_CODE: 1',
                      'INSTRUMENTATION_STATUS: class=' + owner,
                      'INSTRUMENTATION_STATUS: test=' + name,
                      'INSTRUMENTATION_STATUS: numtests=8',
                      'INSTRUMENTATION_STATUS_CODE: ' + ('-3' if skipped and index == 0 else '0')]
        return '\n'.join(lines) + '\nOK (8 tests)\nINSTRUMENTATION_CODE: -1\n'

    def test_only_eight_exact_real_cases_are_accepted_by_parser(self):
        cases = sorted(self.runtime['CASES'])
        self.runtime['verify_instrumentation'](self.transcript(cases))
        self.assertEqual(len(cases), 8)

    def test_a_skipped_case_cannot_become_a_parser_pass(self):
        with self.assertRaises(AssertionError):
            self.runtime['verify_instrumentation'](self.transcript(sorted(self.runtime['CASES']), skipped=True))

    def test_missing_duplicate_or_different_case_cannot_become_a_parser_pass(self):
        cases = sorted(self.runtime['CASES'])
        for variant in (cases[:-1], cases[:-1] + [cases[0]], cases[:-1] + [('foreign.Test', 'other')]):
            with self.assertRaises(AssertionError):
                self.runtime['verify_instrumentation'](self.transcript(variant))

    def test_missing_start_wrong_count_or_failed_terminal_cannot_pass(self):
        raw = self.transcript(sorted(self.runtime['CASES']))
        for variant in (raw.replace('INSTRUMENTATION_STATUS_CODE: 1\n', '', 1),
                        raw.replace('numtests=8', 'numtests=9'),
                        raw.replace('INSTRUMENTATION_CODE: -1', 'INSTRUMENTATION_CODE: 0'),
                        raw.replace('INSTRUMENTATION_CODE: -1', ''),
                        raw + 'INSTRUMENTATION_CODE: -1\n'):
            with self.assertRaises(AssertionError):
                self.runtime['verify_instrumentation'](variant)

    def test_actual_retained_eight_case_log_still_parses(self):
        receipt = json.loads((self.runtime['ROOT'] / 'latest-tests-receipt.json').read_text())
        transcript = Path(receipt['instrumentation_log'])
        self.assertEqual(self.runtime['sha'](transcript), receipt['instrumentation_log_sha256'])
        self.runtime['verify_instrumentation'](transcript.read_text())


class EmptyInstallationProofTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.runtime = runpy.run_path(str(HERE / 'local_android_runtime.py'), run_name='parser_only')

    def inspect(self, files=(), omit_inventory=None):
        package = self.runtime['PACKAGE']
        roots = ['data/' + area + '/0/' + package for area in ('user', 'user_de')]
        names = list(roots)
        config = b'{"host_bootstrap_fixture":true}'
        with tempfile.TemporaryDirectory(prefix='interop-private-backup-fixture-') as directory:
            archive_path = Path(directory) / 'private.tar'
            with tarfile.open(archive_path, 'w:') as archive:
                for root in roots:
                    entry = tarfile.TarInfo(root); entry.type = tarfile.DIRTYPE; archive.addfile(entry)
                for relative, data in files:
                    name = roots[0] + '/' + relative; names.append(name)
                    entry = tarfile.TarInfo(name); entry.size = len(data)
                    archive.addfile(entry, io.BytesIO(data))
            if omit_inventory is not None:
                names.remove(roots[0] + '/' + omit_inventory)
            inventory = b'\0'.join(('/' + name).encode() for name in names) + b'\0'
            return self.runtime['assess_app_backup'](archive_path, inventory, hashlib.sha256(config).hexdigest())

    def test_only_exact_host_bootstrap_config_is_auto_explained(self):
        result = self.inspect([('files/interop/config.json', b'{"host_bootstrap_fixture":true}')])
        self.assertEqual(result['blocked_paths'], [])
        self.assertEqual(result['preferences_for_review'], [])
        self.assertTrue(result['production_database_files_absent'])
        other = self.inspect([('files/interop/config.json', b'{"different":true}')])
        self.assertTrue(other['blocked_paths'])

    def test_even_empty_history_requires_separate_read_only_database_review(self):
        result = self.inspect([('databases/history', b'')])
        self.assertFalse(result['production_database_files_absent'])
        self.assertTrue(result['blocked_paths'])

    def test_unknown_key_store_cannot_be_erased(self):
        result = self.inspect([('files/identity.key', b'private-key-fixture')])
        self.assertTrue(result['blocked_paths'])

    def test_unknown_preferences_need_owner_review(self):
        result = self.inspect([('shared_prefs/app_preferences.xml', b'<map/>')])
        self.assertEqual(result['blocked_paths'], [])
        self.assertEqual(len(result['preferences_for_review']), 1)

    def test_only_namespaced_test_fixture_preferences_are_auto_explained(self):
        filename = 'shared_prefs/legacy-bundle-test-12345678-1234-1234-1234-123456789abc-fixture.xml'
        result = self.inspect([(filename, b'<map/>')])
        self.assertEqual(result['blocked_paths'], [])
        self.assertEqual(result['preferences_for_review'], [])

    def test_archive_inventory_disagreement_stops_before_any_uninstall(self):
        with self.assertRaises(AssertionError):
            self.inspect([('files/identity.key', b'key')], omit_inventory='files/identity.key')


class PackageAbsenceProofTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.runtime = runpy.run_path(str(HERE / 'local_android_runtime.py'), run_name='parser_only')

    def result(self, code=0, out='', error=''):
        return {'exit_code': code, 'stdout': out, 'stderr': error}

    def test_package_absent_requires_both_real_pm_results(self):
        package = self.runtime['PACKAGE']
        self.assertFalse(self.runtime['package_is_installed'](package, self.result(), self.result(1)))
        for listing, path in ((self.result(), self.result()),
                              (self.result(1), self.result(1)),
                              (self.result(), self.result(1, error='service unavailable'))):
            with self.assertRaises(AssertionError):
                self.runtime['package_is_installed'](package, listing, path)

    def test_installed_package_needs_its_actual_path(self):
        package = self.runtime['PACKAGE']
        listing = self.result(out='package:' + package + '\n')
        self.assertTrue(self.runtime['package_is_installed'](package, listing, self.result(out='package:/data/app/test/base.apk\n')))
        with self.assertRaises(AssertionError):
            self.runtime['package_is_installed'](package, listing, self.result(1))

    def test_directory_permission_failure_cannot_become_absence(self):
        self.runtime['require_absent_app_directory'](self.result(1, error='ls: /private/app: No such file or directory\n'))
        for value in (self.result(), self.result(1, error='ls: /private/app: Permission denied\n'),
                      self.result(1, out='su: inaccessible or not found\n'),
                      self.result(1, error='unexpected transport error')):
            with self.assertRaises(AssertionError): self.runtime['require_absent_app_directory'](value)

    def test_existing_orphan_directory_is_preserved_for_backup_not_called_absent(self):
        path = '/data/user/0/' + self.runtime['PACKAGE']
        actual = self.result(out='drwx------ 10 u0_a148 u0_a148 4096 2026-10-16 00:01 ' + path + '\n')
        self.assertTrue(self.runtime['app_directory_exists'](path, actual))
        with self.assertRaises(AssertionError):
            self.runtime['require_absent_app_directory'](actual)
        with self.assertRaises(AssertionError):
            self.runtime['app_directory_exists'](path, self.result(out='lrwx------ ' + path + '\n'))


if __name__ == '__main__':
    unittest.main()

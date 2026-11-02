#!/usr/bin/env python3
"""Explicit V2 local Android pair. Preparing this file never authorizes a start."""
import argparse
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import sys
import time
import uuid
sys.dont_write_bytecode = True
if sys.flags.optimize:
    raise RuntimeError("A18 requires Python without optimization")

HERE = Path(__file__).resolve().parent
HARNESS = Path('/media/linux/SSD128/xmppwin/local/monocles-dinox-interop-20261015/harness')
sys.path.insert(0, str(HARNESS))
import local_android_runtime as v1

ROOT = v1.ROOT
STATE = HERE / 'runtime-state'
RUN = v1.RUN
OWN = {'nora': 'nora.schneider.interop.de.71115b@dinox.im',
       'leon': 'leon.fischer.interop.de.71115b@dinox.im',
       'felix': 'felix.wagner.interop.de.71115b@dinox.im'}
V1_PINS = {'local_android_runtime.py': 'ef5292f3d2776d05814af6083b66ed1082bf1b9330b3d069c666884ab26fa5a9', 'server_control.py': '0fe86a2329e77b2f35b804596f900a0d4341d7d2640d8264342cb8e94bbc6555', 'scenario_recorder.py': '1b534a1b323619a437e5731edbe08100aa3557d61a103194d2a9318655ec6900', 'dinoxinterop20261015.slice': '09b7adc1a634d8a8e4eb916d8e60608c85e879b5fe4e5b28cce9c8595404f029', 'local-runtime-start-plan.json': '25e66152305bb97110086dd532ddabb32742fdb1b6bfc25d6780f25c4af53673'}
V2_FILES = ('runtime.py', 'control.py', 'recorder.py')
CLIENT_VARIANT = 'fixed-fork-csi-and-group-join-fix'
DERIVATION = Path('/media/linux/SSD128/xmppwin/local/monocles-server-validation-20261015/test-bridge-api35-fix')
APKS = {'main.apk': 'ebc9b9d9f8264cf22acc3235614bea118722da171666a98865f5df8b446d5d8a',
        'android-test.apk': '486b06a8f472fc68d89f9ced35b1befbc67805f22aa0d3dbf1c162cf3aab6e65'}
TESTED_APKS = {'main.apk': '4fcd551aff5a41041533174bbe5eb901263728b4f38c7e9b6b62d2dfa582a36a',
               'android-test.apk': APKS['android-test.apk']}
APK_PATHS = {'main.apk': Path('/media/linux/SSD128/xmppwin/local/monocles-server-validation-20261015/group-call-join-fix/main-artifacts/main-join-fixed.apk'),
             'android-test.apk': DERIVATION / 'signpair/artifacts/test-interop-signed.apk'}
DIAGNOSTIC_SOURCE = 'e014744e0a836ca1aa42fa6b23d38e66e353ce00588a9be4e1bc43e7da0ac3a4'
PROOFS = {
    'diagnostic_receipt': (DERIVATION / 'diagnostic-main-xml/diagnostic-main-receipt.json', 'bc8a37c51ff8233491aae577fb81622b80a52997296cae1a5f3d43aef5efaea1'),
    'signing_receipt': (DERIVATION / 'signpair/artifacts/signing-receipt.json', '61ceea9407e979c96bd9d2e530a4e20eabc4b2ea3eebba039cf187cf822cf66d'),
    'eight_and_first_cold_audit': (ROOT / 'evidence/20261015T234039Z-79a51073920845faac50b272cababf63/independent-results-audit.json', 'f72c0c91851b8bb09b4f382d9294ad2fdc8dac0a921ef63dfb19fa1fcbb96b2f'),
    'renewed_audio_audit': (ROOT / 'evidence/20261015T234513Z-005abad01bec43efa0facf1ad1406c98/independent-audio-media-audit.json', '3e894f371fb9f0427470e410ca16a7b48514e6ab23586975b7c74fbb9ea3f1d7')}

CSI_PRODUCT_PROOF = {'main_sha256': '67ebc94d82b1caf72d8d51724d72e2863c3a3956905699bfac05cc232201ee40', 'source_manifest_sha256': 'daa5054868ed2d3e5bc091acf302494a3cacbf9bcfa626acbaa7abd9d31564c8', 'handoff': {'path': '/media/linux/SSD128/xmppwin/local/monocles-server-validation-20261015/csi-background-fix/main-artifacts/local-artifact-handoff.json', 'sha256': 'a52d4029cc66fa56724fce91c45272f773f2b25f28c87c2c509f130a5f00df84'}, 'jvm': {'path': '/media/linux/SSD128/xmppwin/local/monocles-server-validation-20261015/csi-background-fix/jvm-attempt2/jvm-receipt.json', 'sha256': '472551f1eb1ac0a130f474f8eee599aaad8f90e1af44030b319feb21e12d225a'}, 'android_result_claimed': False}
PROOFS.update({
'csi_handoff': (Path('/media/linux/SSD128/xmppwin/local/monocles-server-validation-20261015/csi-background-fix/main-artifacts/local-artifact-handoff.json'), 'a52d4029cc66fa56724fce91c45272f773f2b25f28c87c2c509f130a5f00df84'),
'csi_build': (Path('/media/linux/SSD128/xmppwin/local/monocles-server-validation-20261015/csi-background-fix/main-artifacts/main-build-receipt.json'), 'dbccfa9fd56bd65d777104935ae383564ed8b3094617d49f5e02511f1312044a'),
'csi_jvm': (Path('/media/linux/SSD128/xmppwin/local/monocles-server-validation-20261015/csi-background-fix/jvm-attempt2/jvm-receipt.json'), '472551f1eb1ac0a130f474f8eee599aaad8f90e1af44030b319feb21e12d225a'),
'csi_source': (Path('/media/linux/SSD128/xmppwin/local/monocles-server-validation-20261015/csi-background-fix/main-artifacts/source-csi-jvm.json'), 'daa5054868ed2d3e5bc091acf302494a3cacbf9bcfa626acbaa7abd9d31564c8'),
})

JOIN_ROOT = Path('/media/linux/SSD128/xmppwin/local/monocles-server-validation-20261015/group-call-join-fix')
JOIN_PRODUCT_PROOF = {
    'main_sha256': APKS['main.apk'],
    'source_manifest_sha256': 'a8e1977915425d4bbe8a720204f69471b43b9681e41ed9085ef7da7a3b8cc2d5',
    'reviewed_source_commit': 'dfbc289e20e23f14ce3037f7a2ec9f646d02a369',
    'actual_jvm_tests': 600,
    'new_join_regression_cases': 12,
    'local_handoff_path': str(JOIN_ROOT / 'main-artifacts/local-artifact-handoff.json'),
    # Root's completed local signature/hash verification; no runtime result implied.
    'local_handoff_sha256': '3d15fad93eb12e324f9b8dfc992f271b0f7598a0fc118cf4002e1f588eb39dfc',
    'new_android_runtime_result_claimed_before_boot': False,
}
PROOFS.update({
    'join_handoff': (JOIN_ROOT / 'main-artifacts/local-artifact-handoff.json', JOIN_PRODUCT_PROOF['local_handoff_sha256']),
    'join_build': (JOIN_ROOT / 'main-artifacts/main-build-receipt.json', '99102316eb472efebee3ba6a38da332aa83b511334a3368cdf928a4aa5350910'),
    'join_jvm': (JOIN_ROOT / 'jvm-results/jvm-receipt.json', 'd53d33af698bcf8c989d10ffdcb3a834ad63ce1100665385563958251143039a'),
    'join_source': (JOIN_ROOT / 'main-artifacts/source-reviewed-jvm.json', JOIN_PRODUCT_PROOF['source_manifest_sha256']),
})


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def regular(path, limit=2 * 1024**2):
    path = Path(path)
    assert stat.S_ISREG(path.lstat().st_mode) and path.stat().st_size <= limit
    return path.read_bytes()


def read(path):
    return json.loads(regular(path))


def role_config(role):
    assert role in ('nora', 'leon'), 'Only the two explicit Android owners exist'
    avd_home = ROOT / 'avd' if role == 'nora' else STATE / 'leon/avd'
    return {'role': role, 'jid': OWN[role], 'state': STATE / role,
            'avd_home': avd_home, 'home': avd_home / 'home',
            'avd': 'monocles_local_' + role + '_20261015',
            'adb_port': 5038 if role == 'nora' else 5039,
            'emulator_port': 5580 if role == 'nora' else 5582,
            'serial': 'emulator-5580' if role == 'nora' else 'emulator-5582',
            'config': ROOT / 'private' / ('interop-config.json' if role == 'nora' else 'interop-config-leon-v2.json')}


def environment(role):
    settings = role_config(role)
    value = {key: val for key, val in os.environ.items() if key not in
             ('DISPLAY', 'WAYLAND_DISPLAY', 'DBUS_SESSION_BUS_ADDRESS', 'PULSE_SERVER', 'LD_PRELOAD')}
    value.update(HOME=str(settings['home']), JAVA_HOME=str(v1.JDK),
                 ANDROID_HOME=str(ROOT / 'sdk'), ANDROID_SDK_ROOT=str(ROOT / 'sdk'),
                 AVDMANAGER_OPTS='-Dcom.android.sdkmanager.toolsdir=' + str(ROOT / 'sdk/cmdline-tools/external'),
                 ANDROID_USER_HOME=str(settings['home'] / '.android'),
                 ANDROID_EMULATOR_HOME=str(settings['home'] / '.android'),
                 ANDROID_AVD_HOME=str(settings['avd_home']), ADB_MDNS_AUTO_CONNECT='0',
                 ADB_SERVER_SOCKET='tcp:127.0.0.1:' + str(settings['adb_port']),
                 ANDROID_ADB_SERVER_PORT=str(settings['adb_port']), QEMU_AUDIO_DRV='none',
                 JAVA_TOOL_OPTIONS='-Xmx512m -XX:ActiveProcessorCount=2')
    return value


def adb_command(role):
    settings = role_config(role)
    return [str(ROOT / 'sdk/platform-tools/adb'), '-H', '127.0.0.1', '-P', str(settings['adb_port']), '-s', settings['serial']]


def emulator_command(role, memory_mib=2560, lowram=False):
    assert memory_mib in (2048, 2560)
    settings = role_config(role)
    return [str(ROOT / 'sdk/emulator/emulator'), '-avd', settings['avd'], '-port', str(settings['emulator_port']),
            '-accel', 'on', '-no-window', '-no-audio', '-no-boot-anim', '-no-snapshot', '-gpu', 'swiftshader',
            '-camera-back', 'emulated', '-camera-front', 'emulated', '-memory', str(memory_mib), '-cores', '2', '-no-metrics'] + (['-lowram'] if lowram else [])


def historical_v2_freeze_not_used():
    raise RuntimeError("Historical V2 freeze is not an A18 entry point")



def evidence(reference):
    assert set(reference) == {'path', 'sha256'}
    path = Path(reference['path'])
    assert path.is_absolute() and path.resolve(strict=True).is_relative_to(ROOT / 'evidence')
    raw = regular(path)
    assert hashlib.sha256(raw).hexdigest() == reference['sha256'], 'Evidence bytes changed'
    return path, raw


def require_absent_sdk_cache(cache):
    assert not os.path.lexists(cache), 'Unexpected SDK cache before owned AVD create'


def preserve_created_sdk_cache(cache, output, role):
    if not os.path.lexists(cache):
        return None
    with os.fdopen(os.open(cache, os.O_RDONLY | os.O_NOFOLLOW), 'rb') as stream:
        metadata = os.fstat(stream.fileno())
        assert stat.S_ISREG(metadata.st_mode) and metadata.st_uid == os.getuid()
        assert metadata.st_size <= 4096, 'Unexpected SDK cache metadata size'
        raw = stream.read(4097)
        assert len(raw) == metadata.st_size
    current = cache.lstat()
    assert (current.st_dev, current.st_ino) == (metadata.st_dev, metadata.st_ino)
    destination = output / 'avdmanager-knownPackages'
    assert not os.path.lexists(destination)
    digest = hashlib.sha256(raw).hexdigest()
    os.rename(cache, destination)
    preserved = destination.lstat()
    assert stat.S_ISREG(preserved.st_mode) and preserved.st_uid == os.getuid()
    assert (preserved.st_dev, preserved.st_ino) == (metadata.st_dev, metadata.st_ino)
    assert sha(destination) == digest, 'Created SDK cache bytes changed'
    receipt = {'schema_version': 2, 'run_id': RUN, 'role': role,
               'setup_revision': v1.SETUP_REVISION,
               'phase': 'owned-avd-create-cache-preserved', 'source': str(cache),
               'destination': str(destination), 'size': len(raw), 'sha256': digest,
               'owner_uid': metadata.st_uid, 'cache_absent_before_create': True}
    v1.write(output / 'sdk-cache-preserved.json', receipt)
    return receipt


def proof(name):
    path, digest = PROOFS[name]
    raw = regular(path)
    assert hashlib.sha256(raw).hexdigest() == digest, 'Existing derivation evidence changed'
    return json.loads(raw)


def verify_derivation():
    diagnostic, signing = proof('diagnostic_receipt'), proof('signing_receipt')
    assert diagnostic['run_id'] == signing['run_id'] == RUN
    assert diagnostic['result'] == signing['result'] == 'PASS'
    assert diagnostic['apk_sha256'] == 'ffd803a9663a9fb7cd93f983763a0ce557850f93d5b64d1c108bb7fededf41d5'
    assert diagnostic['source_manifest_sha256'] == DIAGNOSTIC_SOURCE
    assert diagnostic['source_restored'] and diagnostic['all_resources_and_native_apk_entries_byte_identical']
    assert diagnostic['all_other_class_files_byte_identical'] and diagnostic['dao_and_parser_and_existing_eight_test_classes_unchanged']
    assert diagnostic['native_build_requested'] is diagnostic['test_apk_rebuilt'] is False
    assert diagnostic['existing_test_apk_sha256'] == APKS['android-test.apk']
    assert signing['compiled'] is signing['source_or_sdk_or_jni_changed'] is False
    assert signing['apks']['main']['signed_sha256'] == TESTED_APKS['main.apk']
    assert signing['apks']['test']['signed_sha256'] == APKS['android-test.apk']
    signer = '89ad5d0085ecee67350b62cb634d5d2ee7255f928c9979e32753f4e4bc519ecf'
    assert diagnostic['signer_certificate_sha256'] == signing['signer_certificate_sha256'] == signer
    for role in ('main', 'test'):
        assert signing['apks'][role]['all_nonsignature_entries_byte_identical']
        assert signing['apks'][role]['signed_certificate_sha256'] == signer
    csi = verify_csi_product()
    join = verify_join_product()
    return {'installed_apk_sha256': APKS, 'actually_tested_apk_sha256': TESTED_APKS,
            'historical_csi_product': csi, 'current_join_product': join,
            'diagnostic_source_manifest_sha256': DIAGNOSTIC_SOURCE,
            'receipt_sha256': {name: value[1] for name, value in PROOFS.items()}}


def verify_csi_product():
    handoff, build, jvm = proof('csi_handoff'), proof('csi_build'), proof('csi_jvm')
    assert handoff['result'] == build['result'] == jvm['result'] == 'PASS'
    assert handoff['apk_sha256'] == build['apk_sha256'] == CSI_PRODUCT_PROOF['main_sha256']
    assert handoff['source_manifest_sha256'] == build['source_manifest_sha256'] == jvm['source_manifest_sha256'] == CSI_PRODUCT_PROOF['source_manifest_sha256']
    assert sha(PROOFS['csi_source'][0]) == PROOFS['csi_source'][1]
    assert build['normal_main_basis_sha256'] == TESTED_APKS['main.apk']
    assert handoff['test_apk_sha256'] == build['existing_signed_test_apk_sha256'] == APKS['android-test.apk']
    assert handoff['signer_certificate_sha256'] == build['signer_certificate_sha256'] == '89ad5d0085ecee67350b62cb634d5d2ee7255f928c9979e32753f4e4bc519ecf'
    assert handoff['local_v1_cms_signature_and_all_entry_digests_verified'] and handoff['server_apksigner_v1_and_v2_verified']
    assert build['all_other_main_classes_unchanged'] and build['all_resources_and_36_native_entries_unchanged']
    assert build['crypto_classes_unchanged'] == 98 and build['unchanged_main_class_count'] == 2113
    assert build['native_or_sdk_build_requested'] is build['test_apk_rebuilt'] is build['config_background_stanza_logging'] is False
    assert jvm['whole_application_suite_without_test_filter'] and jvm['tests'] == jvm['unique_cases'] == 588
    assert jvm['failures'] == jvm['errors'] == jvm['skipped'] == 0
    import xml.etree.ElementTree as ET
    xmls = list(PROOFS['csi_jvm'][0].parent.rglob('TEST-*.xml'))
    assert len(xmls) == 66
    cases = []
    for path in xmls:
        root = ET.parse(path).getroot()
        for case in root.iter('testcase'):
            assert not any(case.find(tag) is not None for tag in ('failure', 'error', 'skipped'))
            cases.append((case.get('classname'), case.get('name')))
    assert len(cases) == len(set(cases)) == 588
    return {'main_apk_sha256': CSI_PRODUCT_PROOF['main_sha256'], 'source_manifest_sha256': CSI_PRODUCT_PROOF['source_manifest_sha256'],
            'actual_jvm_tests': 588, 'failures': 0, 'new_android_runtime_result_claimed_before_boot': False}


def verify_join_product():
    assert re.fullmatch('[0-9a-f]{64}', JOIN_PRODUCT_PROOF['local_handoff_sha256'] or ''), 'Completed local JOIN handoff not pinned'
    handoff, build, jvm = proof('join_handoff'), proof('join_build'), proof('join_jvm')
    assert handoff['result'] == build['result'] == jvm['result'] == 'PASS'
    assert handoff['apk_sha256'] == build['apk_sha256'] == JOIN_PRODUCT_PROOF['main_sha256'] == APKS['main.apk']
    assert handoff['source_manifest_sha256'] == build['source_manifest_sha256'] == jvm['source_manifest_sha256'] == JOIN_PRODUCT_PROOF['source_manifest_sha256']
    assert sha(PROOFS['join_source'][0]) == PROOFS['join_source'][1]
    assert handoff['main_build_receipt_sha256'] == PROOFS['join_build'][1]
    assert handoff['jvm_receipt_sha256'] == build['jvm_receipt_sha256'] == PROOFS['join_jvm'][1]
    assert handoff['reviewed_source_commit'] == JOIN_PRODUCT_PROOF['reviewed_source_commit']
    assert handoff['source_overlay_sha256'] == build['source_overlay_sha256']
    assert Path(handoff['apk_path']) == APK_PATHS['main.apk']
    assert build['normal_main_basis_sha256'] == CSI_PRODUCT_PROOF['main_sha256']
    assert handoff['test_apk_sha256'] == build['existing_signed_test_apk_sha256'] == APKS['android-test.apk']
    assert Path(handoff['test_apk_path']) == APK_PATHS['android-test.apk']
    assert handoff['signer_certificate_sha256'] == build['signer_certificate_sha256'] == '89ad5d0085ecee67350b62cb634d5d2ee7255f928c9979e32753f4e4bc519ecf'
    assert handoff['local_jarsigner_signature_and_entry_digests_verified'] and handoff['local_certificate_keytool_verified']
    assert handoff['server_apksigner_v1_and_v2_verified']
    assert handoff['local_v2_independently_checked'] is False
    assert build['all_other_main_classes_unchanged'] and build['all_resources_and_36_native_entries_unchanged']
    assert build['crypto_classes_unchanged'] == 98 and build['unchanged_main_class_count'] == 2156
    assert build['native_or_sdk_build_requested'] is build['test_apk_rebuilt'] is build['config_background_stanza_logging'] is False
    assert handoff['native_or_sdk_rebuild'] is handoff['runtime_or_new_android_test_result_claimed'] is build['runtime_result_claimed'] is False
    assert build['source_restored'] and jvm['source_restored']
    assert handoff['actual_jvm_tests'] == build['actual_jvm_tests'] == jvm['tests'] == jvm['unique_cases'] == 600
    assert jvm['whole_application_suite_without_test_filter']
    assert jvm['failures'] == jvm['errors'] == jvm['skipped'] == 0
    import xml.etree.ElementTree as ET
    xmls = list(PROOFS['join_jvm'][0].parent.rglob('TEST-*.xml'))
    assert len(xmls) == 67
    cases = []
    for path in xmls:
        root = ET.parse(path).getroot()
        for case in root.iter('testcase'):
            assert not any(case.find(tag) is not None for tag in ('failure', 'error', 'skipped'))
            cases.append((case.get('classname'), case.get('name')))
    assert len(cases) == len(set(cases)) == 600
    new_cases = [tuple(case) for case in jvm['new_join_regression_cases']]
    assert len(new_cases) == len(set(new_cases)) == 12 and set(new_cases) <= set(cases)
    return {**JOIN_PRODUCT_PROOF, 'signer_certificate_sha256': handoff['signer_certificate_sha256'],
            'basis_csi_main_sha256': CSI_PRODUCT_PROOF['main_sha256'], 'failures': 0,
            'historical_eight_tests_not_relabelled': True}


def verify_install_apks():
    for name, path in APK_PATHS.items():
        assert path.is_file() and not path.is_symlink() and sha(path) == APKS[name]


def verify_current_eight():
    audit = proof('eight_and_first_cold_audit')
    assert audit['run_id'] == RUN and audit['installation']['artifact_sha256'] == TESTED_APKS
    tests = audit['new_eight_tests']
    assert tests['unique_tests'] == tests['start_count'] == tests['pass_end_count'] == 8
    assert tests['failures'] == tests['skipped_or_ignored'] == 0
    reference = tests['raw']; path = Path(reference['path'])
    assert path.resolve(strict=True).is_relative_to(ROOT / 'logs')
    raw = regular(path); assert hashlib.sha256(raw).hexdigest() == reference['sha256']
    v1.verify_instrumentation(raw.decode())
    # Historical real 4fcd/486b run; never relabel it as testing a later product APK.
    return {'tests': 8, 'failures': 0, 'skipped': 0, 'actually_tested_apk_sha256': TESTED_APKS,
            'instrumentation_log_sha256': reference['sha256'], 'diagnostic_apk_test_run_claimed': False}


def verify_invite_history():
    first = proof('eight_and_first_cold_audit')['first_cold_invite']
    assert first['result'] == 'PARTIAL' and first['two_pending_without_autojoin_verified']
    assert first['accepted_first_cold_invite_proven'] is first['conference_media_proven'] is False
    evidence(first['initial_state']); evidence(first['accept_failure'])
    for sample in first['pending_samples']: evidence(sample['raw'])
    renewed = proof('renewed_audio_audit')
    assert renewed['result'] == 'PASS' and renewed['directed_edge_count'] == 6
    assert renewed['first_cold_case']['result'] == 'PARTIAL' and renewed['first_cold_case']['not_relabelled_by_this_success']
    assert renewed['omemo_authenticated_call_proven'] is False
    for reference in renewed['raw_sources'].values(): evidence(reference)
    for edge in renewed['directed_edges']:
        assert edge['rtp_delta'] > 0 and edge['sample_delta'] > 0
    return {'first_cold': 'PARTIAL', 'renewed_case': 'DTLS-SRTP audio media PASS only',
            'omemo_authenticated_call_proven': False}


def verify_leon_stop(value):
    assert value['schema_version'] == 2 and value['run_id'] == RUN
    assert value['role'] == 'leon' and value['account'] == OWN['leon'] and value['profile_retained'] is True
    _, raw = evidence(value['container_inspect'])
    item = json.loads(raw)
    if isinstance(item, list):
        assert len(item) == 1
        item = item[0]
    assert item['Id'] == value['container_id'] and re.fullmatch('[0-9a-f]{64}', item['Id'])
    assert item['Name'] == '/dinox-interop-20261015-leon'
    assert item['Config']['Labels']['im.dinox.interop.run'] == RUN
    assert item['State']['Running'] is False and item['State']['Status'] == 'exited' and item['State']['ExitCode'] == 0
    assert any(m['Type'] == 'volume' and m['Name'] == value['profile_volume'] and
               m['Destination'] == '/interop/monocles-dinox-interop-20261015' for m in item['Mounts'])
    _, raw = evidence(value['stop_result'])
    result = json.loads(raw)
    if 'response' in result:
        result = result['response']
    assert result['run_id'] == RUN and result['account'] == OWN['leon']
    assert result['ok'] is True and result['online'] is False


def gate(role, memory_mib=2560, lowram=False, android_tests_before_bridge=False):
    freeze_sha = frozen_files()
    path = STATE / ('allow-' + role + '.json')
    assert path.stat().st_mode & 0o077 == 0, 'Private explicit root marker required'
    value = read(path)
    assert value['schema_version'] == 2 and value['run_id'] == RUN and value['role'] == role
    assert value['mode'] == 'bridge' and value['freeze_sha256'] == freeze_sha
    inputs = sha(ROOT / 'runtime-inputs.json')
    assert inputs == value['inputs_sha256'] == '497bdf37cdcd317895a8d33efc3e0f9be189d4110f81f89d218b0c1817f775c2'
    assert value.get('guest_memory_mib', 2560) == memory_mib
    assert value.get('lowram_emulation_variant', False) is lowram
    assert value.get('android_tests_before_bridge', False) is android_tests_before_bridge
    if android_tests_before_bridge: assert role == 'nora'
    if lowram: assert memory_mib == 2048
    if memory_mib == 2048:
        if role == 'nora':
            assert value.get('single_nora_memory_probe') is True
        else:
            assert role == 'leon' and lowram is True
            assert value.get('dual_android_memory_probe') is True
            assert value.get('single_nora_memory_probe', False) is False
    assert value['installed_apk_sha256'] == APKS
    assert value['derivation_receipt_sha256'] == {name: item[1] for name, item in PROOFS.items()}
    derivation = verify_derivation()
    tests = verify_current_eight()
    history = verify_invite_history()
    verify_install_apks()
    _, raw = evidence(value['original_leon_stop'])
    verify_leon_stop(json.loads(raw))
    return {'freeze_sha256': freeze_sha, 'inputs_sha256': inputs,
            'client_variant': CLIENT_VARIANT, 'source_manifest_sha256': JOIN_PRODUCT_PROOF['source_manifest_sha256'],
            'base_source_manifest_sha256': v1.SOURCE, 'apk_sha256': APKS,
            'approval_sha256': sha(path), 'nora_eight_test_gate': tests,
            'derivation': derivation, 'invite_history': history,
            'original_leon_stop_sha256': value['original_leon_stop']['sha256']}


def validate_private_config(role, value):
    assert value['run_id'] == RUN and value['jid'] == OWN[role]
    peers = value['allowed_jids']
    assert isinstance(peers, list) and 1 <= len(peers) <= 2 and len(set(peers)) == len(peers)
    assert set(peers) <= set(OWN.values()) - {OWN[role]}
    assert value.get('allowed_rooms', []) == []
    assert isinstance(value['password'], str) and value['password']


def control_settings(role):
    v1.resources()
    settings = role_config(role)
    session = read(settings['state'] / 'live-session.json')
    assert session['schema_version'] == 2 and session['run_id'] == RUN and session['role'] == role
    assert session['state'] == 'running' and session['ready'] and session['freeze_sha256'] == frozen_files()
    assert session['inputs_sha256'] == sha(ROOT / 'runtime-inputs.json')
    assert session['apk_sha256'] == APKS
    for name in ('controller', 'adb', 'emulator'):
        assert v1.start_ticks(session[name + '_pid']) == session[name + '_start_ticks'], 'Stale process owner'
        groups = Path('/proc', str(session[name + '_pid']), 'cgroup').read_text()
        assert any(v1.SLICE in line.split(':', 2)[2].strip().split('/') for line in groups.splitlines() if line.startswith('0::'))
    assert session['adb_sha256'] == sha(ROOT / 'sdk/platform-tools/adb')
    v1.require_adb_ready(session['adb_pid'], session['adb_start_ticks'], settings['adb_port'],
                         session['adb_sha256'], session['adb_cgroup'])
    return settings


def run(role, memory_mib=2560, lowram=False, android_tests_before_bridge=False):
    settings = role_config(role)
    proof = gate(role, memory_mib, lowram, android_tests_before_bridge)
    v1.resources()
    assert v1.verify_inputs() == proof['inputs_sha256']
    assert stat.S_ISCHR(Path('/dev/kvm').stat().st_mode) and os.access('/dev/kvm', os.R_OK | os.W_OK)
    settings['state'].mkdir(parents=True, mode=0o700, exist_ok=True)
    settings['avd_home'].mkdir(parents=True, mode=0o700, exist_ok=True)
    (settings['home'] / '.android').mkdir(parents=True, mode=0o700, exist_ok=True)
    lock = (settings['avd_home'] / (role + '.lock')).open('a')
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    owner = settings['avd_home'] / (role + '-owner.json')
    expected_owner = {'run_id': RUN, 'role': role, 'inputs_sha256': proof['inputs_sha256'], 'freshly_created': True}
    avd_path = settings['avd_home'] / (settings['avd'] + '.avd')
    ini = settings['avd_home'] / (settings['avd'] + '.ini')
    fresh = not owner.exists()
    if fresh:
        assert role == 'leon' and not avd_path.exists() and not ini.exists(), 'Never adopt/copy another AVD'
        assert __import__('shutil').disk_usage(ROOT).free >= 6 * 1024**3
    else:
        assert read(owner) == expected_owner and ini.is_file() and avd_path.is_dir()
    output = settings['state'] / ('logs-' + datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ-') + uuid.uuid4().hex)
    output.mkdir(mode=0o700)
    env = environment(role)
    children = []
    handles = []
    session = {**proof, 'schema_version': 2, 'run_id': RUN, 'role': role,
               'setup_revision': v1.SETUP_REVISION,
               'controller_pid': os.getpid(), 'controller_start_ticks': v1.start_ticks(os.getpid()),
               'state': 'running', 'ready': False, 'output': str(output),
               'guest_memory_mib': memory_mib, 'lowram_emulation_variant': lowram,
               'adb_sha256': sha(ROOT / 'sdk/platform-tools/adb')}

    def command(arguments, timeout=30, data=None):
        if arguments[0] == str(ROOT / 'sdk/platform-tools/adb'):
            v1.require_adb_ready(session['adb_pid'], session['adb_start_ticks'], settings['adb_port'],
                                 session['adb_sha256'], session['adb_cgroup'])
        child = subprocess.Popen(arguments, env=env, stdin=subprocess.PIPE if data is not None else subprocess.DEVNULL,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        deadline = time.monotonic() + timeout
        try:
            while True:
                v1.resources()
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise subprocess.TimeoutExpired(arguments, timeout)
                try:
                    stdout, stderr = child.communicate(input=data, timeout=min(1, remaining))
                    break
                except subprocess.TimeoutExpired:
                    data = None
            if child.returncode:
                private_config = any('config.json' in x for x in arguments)
                v1.write(output / ('failed-command-' + uuid.uuid4().hex + '.json'),
                         {'arguments': arguments, 'exit_code': child.returncode,
                          'stdout': '[private configuration omitted]' if private_config else stdout.decode(errors='replace'),
                          'stderr': stderr.decode(errors='replace')})
                raise RuntimeError('Owned Android command failed; no private input is printed')
            return stdout
        finally:
            v1.stop_owned(child)

    adb = adb_command(role)
    try:
        if fresh:
            cache = ROOT / 'sdk/.knownPackages'
            require_absent_sdk_cache(cache)
            v1.write(owner, expected_owner)
            try:
                raw = command([str(v1.AVDMANAGER), 'create', 'avd', '--name', settings['avd'], '--path', str(avd_path),
                               '--package', 'system-images;android-35;default;x86_64', '--device', 'pixel_2'], timeout=90, data=b'no\n')
                (output / 'avdmanager.log').write_bytes(raw)
            finally:
                preserve_created_sdk_cache(cache, output, role)
            assert v1.verify_inputs() == proof['inputs_sha256']
        assert ini.is_file() and avd_path.is_dir()
        # Nora's pre-existing AVD is reused in place; no wipe-data/snapshot/key copy.
        v1.write(settings['state'] / 'live-session.json', session)
        programs = [('adb', [str(ROOT / 'sdk/platform-tools/adb'), '-L', 'tcp:' + str(settings['adb_port']),
                             '--one-device', settings['serial'], 'server', 'nodaemon']),
                    ('emulator', emulator_command(role, memory_mib, lowram))]
        for name, arguments in programs:
            if name == 'emulator':
                v1.require_adb_ready(session['adb_pid'], session['adb_start_ticks'], settings['adb_port'],
                                     session['adb_sha256'], session['adb_cgroup'])
            handle = (output / (name + '.log')).open('xb'); handles.append(handle)
            child = subprocess.Popen(arguments, env=env, stdin=subprocess.DEVNULL, stdout=handle,
                                     stderr=subprocess.STDOUT, start_new_session=True)
            children.append(child)
            session[name + '_pid'] = child.pid; session[name + '_start_ticks'] = v1.start_ticks(child.pid)
            if name == 'adb':
                session['adb_cgroup'] = v1.process_cgroup(child.pid)
                session['adb_ready'] = v1.wait_adb_ready(child, settings['adb_port'], session['adb_sha256'], session['adb_cgroup'], v1.resources)
                v1.write(output / 'adb-readiness.json', session['adb_ready'])
        v1.write(settings['state'] / 'live-session.json', session)
        deadline = time.monotonic() + 300
        while True:
            v1.resources(); assert all(p.poll() is None for p in children)
            assert time.monotonic() < deadline, 'No successful Android boot'
            try:
                if command([*adb, 'shell', 'getprop', 'sys.boot_completed'], timeout=5).strip() == b'1': break
            except (RuntimeError, subprocess.TimeoutExpired):
                pass
            time.sleep(2)
        assert command([*adb, 'shell', 'getprop', 'ro.build.version.sdk']).strip() == b'35'
        for name, path in APK_PATHS.items():
            command([*adb, 'install', '-r', '-t', str(path)], timeout=180)
        if android_tests_before_bridge:
            # Re-run the real eight unchanged tests against this installed Main.
            # Their cache/UUID fixture DBs do not replace the retained app profile.
            raw_tests = command([*adb, 'shell', '-T', 'am', 'instrument', '-w', '-r', '-e', 'class',
                v1.DB + ',' + v1.NATIVE, v1.PACKAGE + '.test/androidx.test.runner.AndroidJUnitRunner'], timeout=240)
            test_log = output / 'current-main-eight-android-tests.log'
            test_log.write_bytes(raw_tests); test_log.chmod(0o600)
            v1.verify_instrumentation(raw_tests.decode(errors='replace'))
            test_receipt = {'run_id': RUN, 'role': role, 'actually_installed_apk_sha256': APKS,
                            'tests': 8, 'failures': 0, 'skipped': 0,
                            'raw': {'path': str(test_log), 'sha256': sha(test_log)},
                            'actual_runtime_execution': True, 'profile_reset': False}
            v1.write(output / 'current-main-eight-android-tests-receipt.json', test_receipt)
            session['current_main_eight_android_tests'] = test_receipt
            v1.write(settings['state'] / 'live-session.json', session)
        config_path = settings['config']
        assert config_path.stat().st_mode & 0o077 == 0
        raw = regular(config_path, 32768); config = json.loads(raw); validate_private_config(role, config)
        command([*adb, 'shell', 'run-as', v1.PACKAGE, 'mkdir', '-p', 'files/interop/inbox', 'files/interop/results'])
        command([*adb, 'shell', '-T', 'run-as', v1.PACKAGE, 'dd', 'of=files/interop/config.json'], data=raw)
        assert command([*adb, 'shell', '-T', 'run-as', v1.PACKAGE, 'cat', 'files/interop/config.json']) == raw, 'Incomplete private config transfer'
        command([*adb, 'exec-out', 'run-as', v1.PACKAGE, 'chmod', '600', 'files/interop/config.json'])
        for permission in ('android.permission.RECORD_AUDIO', 'android.permission.CAMERA',
                           'android.permission.POST_NOTIFICATIONS', 'android.permission.BLUETOOTH_CONNECT'):
            command([*adb, 'shell', 'pm', 'grant', v1.PACKAGE, permission])
        command([*adb, 'shell', 'run-as', v1.PACKAGE, 'rm', '-f',
                 'files/interop/ready.json', 'files/interop/state.json'])
        handle = (output / 'instrumentation.log').open('xb'); handles.append(handle)
        v1.require_adb_ready(session['adb_pid'], session['adb_start_ticks'], settings['adb_port'],
                             session['adb_sha256'], session['adb_cgroup'])
        child = subprocess.Popen([*adb, 'shell', 'am', 'instrument', '-w', '-r', '-e', 'class',
            'eu.siacs.conversations.interop.MonoclesInteropTest', '-e', 'run_id', RUN,
            v1.PACKAGE + '.test/androidx.test.runner.AndroidJUnitRunner'], env=env, stdin=subprocess.DEVNULL,
            stdout=handle, stderr=subprocess.STDOUT, start_new_session=True)
        children.append(child)
        deadline = time.monotonic() + 5400
        while child.poll() is None:
            sample = v1.resources()
            assert time.time()<proof['batch_deadline_unix']
            with (output / 'resources.jsonl').open('a') as stream: stream.write(json.dumps(sample) + '\n')
            assert all(p.poll() is None for p in children[:2]) and time.monotonic() < deadline
            if not session['ready']:
                try:
                    raw_ready = command([*adb, 'exec-out', 'run-as', v1.PACKAGE, 'cat', 'files/interop/ready.json'], timeout=5)
                    ready = v1.bridge_ready(raw_ready, OWN[role], alive=all(p.poll() is None for p in children), deadline=deadline)
                    if ready is not None:
                        session['ready'] = True; v1.write(settings['state'] / 'live-session.json', session)
                except (RuntimeError, subprocess.TimeoutExpired):
                    pass
            time.sleep(1)
        assert child.returncode == 0
        assert re.search(r'OK\s*\(1 test\)', (output / 'instrumentation.log').read_text())
    finally:
        for child in reversed(children[2:]): v1.stop_owned(child)
        shutdown = {'run_id': RUN, 'role': role, 'sync_succeeded': False,
                    'emulator_console_stop_succeeded': False}
        try:
            if len(children) >= 2 and all(p.poll() is None for p in children[:2]):
                command([*adb, 'shell', '-T', 'sync'], timeout=15)
                shutdown['sync_succeeded'] = True
                raw = command([*adb, 'emu', 'kill'], timeout=15)
                children[1].wait(timeout=15)
                shutdown.update(emulator_console_stop_succeeded=True,
                                emulator_exit_code=children[1].returncode,
                                emulator_console_stdout=raw.decode(errors='replace'))
        except (OSError, AssertionError, subprocess.SubprocessError, RuntimeError) as error:
            shutdown.update(error_type=type(error).__name__, detail=str(error))
        v1.write(output / 'guest-sync-and-emulator-stop.json', shutdown)
        for child in reversed(children[:2]): v1.stop_owned(child)
        for handle in handles: handle.close()
        cleanup = v1.cleanup_adb_residuals(settings['adb_port'], session['adb_sha256'],
                                           session.get('adb_cgroup', v1.process_cgroup(os.getpid())))
        v1.write(output / 'adb-cleanup.json', cleanup)
        session.update(state='stopped', ready=False, all_owned_processes_stopped=all(p.poll() is not None for p in children))
        v1.write(settings['state'] / 'live-session.json', session)
        immutable_inputs_ok = v1.verify_inputs() == proof['inputs_sha256']
        verify_install_apks()
        v1.write(output / 'runtime-receipt.json', {'schema_version': 2, 'run_id': RUN, 'session': session,
                 'host_audio': False, 'host_cameras': False, 'acceleration': 'KVM',
                 'setup_revision': v1.SETUP_REVISION, 'adb_cleanup': cleanup,
                 'shared_sdk_apks_hashes_unchanged': immutable_inputs_ok, 'keys_copied': False, 'trust_changed_by_host': False})
        lock.close()


# Additive Nora-only overrides. Historical e406 functions run in their own module.
import importlib.util as _iu
assert sha(Path('/media/linux/SSD128/xmppwin/local/monocles-dinox-interop-20261015/harness/pair_v2/runtime.py'))=='bdcf594aa98be73fc08fb4ce1a955d53671a91bc0c523df4ba26b4ef1bd52816'
_spec = _iu.spec_from_file_location('historical_join_v2_nora', Path('/media/linux/SSD128/xmppwin/local/monocles-dinox-interop-20261015/harness/pair_v2/runtime.py'))
_historical = _iu.module_from_spec(_spec); _spec.loader.exec_module(_historical)
_old_role_config = role_config
_old_control_settings = control_settings
PRODUCT = {'handoff': {'path': '/media/linux/SSD128/xmppwin/local/monocles-server-validation-20261015/muji-device-landscape-fix/main-artifacts/local-artifact-handoff.json', 'sha256': '592877fbf8760b4579f831b6a33096f59631d2634b82722711a2791e18961dca'}, 'build': {'path': '/media/linux/SSD128/xmppwin/local/monocles-server-validation-20261015/muji-device-landscape-fix/main-artifacts/main-build-receipt.json', 'sha256': '81f1d2f5ec05a1ec06958d32afd3374f8c8b98f52564d0dbde254a1271c92fd8'}, 'jvm': {'path': '/media/linux/SSD128/xmppwin/local/monocles-server-validation-20261015/muji-device-landscape-fix/jvm-results/jvm-receipt.json', 'sha256': '4f47c0fc108684c2bdf1706d77c72d45ff841acc7b87c34fcd47909beb020229'}, 'source': {'path': '/media/linux/SSD128/xmppwin/local/monocles-server-validation-20261015/muji-device-landscape-fix/main-artifacts/source-reviewed-jvm.json', 'sha256': 'b1ac6b70000caa0b5e512e94da128508ad09bc2a14d0b8b86708404db7cd4491'}, 'main_path': '/media/linux/SSD128/xmppwin/local/monocles-server-validation-20261015/muji-device-landscape-fix/main-artifacts/main-device-layout-fixed.apk', 'main_sha256': '0a8ce212645b5a4876ee7f88122e5065d8f34a4f2a5c212ac91eec4402d0bebe', 'test_path': '/media/linux/SSD128/xmppwin/local/monocles-server-validation-20261015/test-bridge-api35-fix/signpair/artifacts/test-interop-signed.apk', 'test_sha256': '486b06a8f472fc68d89f9ced35b1befbc67805f22aa0d3dbf1c162cf3aab6e65', 'commit': '05ea2fb4c144f5373883dbc1124396d12bd4ed4d', 'actual_jvm_tests': 616, 'signer_certificate_sha256': '89ad5d0085ecee67350b62cb634d5d2ee7255f928c9979e32753f4e4bc519ecf'}
NORMAL_MIXED_CONSENT_UI_SHA256 = '16b236d8a8f8b5cb645114de03cb02635bc524d56cd1fcfc0b27a8c32c7da942'
MIXED_HELPER = Path('/media/linux/SSD128/xmppwin/local/monocles-dinox-interop-20261015/harness/legacy3_mixed_consent/normal_mixed_ui_consent.py')
LAYOUT_CAPTURE = Path('/media/linux/SSD128/xmppwin/local/monocles-dinox-interop-20261015/harness/devicefix_runtime_derivation/call_layout_capture.py')
LAYOUT_CAPTURE_SHA256 = 'b112ad2232484bea98d19ed5addc67fa5213ae6d12fe0979e6c7d0c7c5d4a664'
APKS = {'main.apk': PRODUCT['main_sha256'], 'android-test.apk': PRODUCT['test_sha256']}
APK_PATHS = {'main.apk': Path(PRODUCT['main_path']), 'android-test.apk': Path(PRODUCT['test_path'])}
CLIENT_VARIANT = 'device-dialects-landscape-616-Nora-only-2048-lowram'
JOIN_PRODUCT_PROOF = dict(_historical.JOIN_PRODUCT_PROOF, main_sha256=PRODUCT['main_sha256'],
    source_manifest_sha256=PRODUCT['source']['sha256'], actual_jvm_tests=616,
    reviewed_source_commit=PRODUCT['commit'], local_handoff_path=PRODUCT['handoff']['path'],
    local_handoff_sha256=PRODUCT['handoff']['sha256'])

def _current_product():
    for name in ('handoff','build','jvm','source'):
        ref=PRODUCT[name];assert sha(Path(ref['path']))==ref['sha256']
    h,b,j=(read(PRODUCT[k]['path']) for k in ('handoff','build','jvm'))
    assert h['result']==b['result']==j['result']=='PASS'
    assert h['apk_sha256']==b['apk_sha256']==APKS['main.apk']
    assert h['actual_jvm_tests']==b['actual_jvm_tests']==j['tests']==j['unique_cases']==616
    assert h['test_apk_sha256']==APKS['android-test.apk']
    assert j['failures']==j['errors']==j['skipped']==0
    assert h['signer_certificate_sha256']==PRODUCT['signer_certificate_sha256']
    return dict(JOIN_PRODUCT_PROOF)

def frozen_files():
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
    return sha(HERE / 'freeze.json')


def role_config(role):
    assert role=='nora','This derivative cannot start/control Android Leon or Felix'
    return _old_role_config(role)

def verify_join_product():return _current_product()

def verify_derivation():
    return {'historical_e406':_historical.verify_derivation(),'current_616':_current_product(),
        'installed_apk_sha256':APKS,'historical_eight_not_relabelled':True}

def _native_readonly_bindings(value, now):
    assert set(value)=={'directory','control_sha256','recorder_sha256','admission_sha256','owner_admission','inspects'}
    directory=Path(value['directory']).resolve(strict=True)
    assert directory.is_relative_to(HARNESS)
    script=directory/'native_control.py';assert sha(script)==value['control_sha256']
    assert sha(directory/'native_recorder.py')==value['recorder_sha256']
    spec=_iu.spec_from_file_location('admitted_native_readonly',script)
    native=_iu.module_from_spec(spec);spec.loader.exec_module(native)
    admission=native.admission(value['admission_sha256']);assert admission==value['owner_admission']
    assert set(value['inspects'])=={'leon','felix'}
    for role,ref in value['inspects'].items():
        assert 0<=now-ref['observed_unix']<=300
        assert sha(Path(ref['path']))==ref['sha256'];info=read(ref['path'])
        if isinstance(info,list):assert len(info)==1;info=info[0]
        native.check_container(info,admission['roles'][role],role)
    return value

def gate(role,memory_mib=2048,lowram=True,android_tests_before_bridge=False):
    assert role=='nora' and memory_mib==2048 and lowram is True and android_tests_before_bridge is False
    freeze=frozen_files();path=STATE/'allow-nora.json';assert path.stat().st_mode&0o077==0
    value=read(path);now=time.time()
    assert value['schema_version']==2 and value['run_id']==RUN and value['role']=='nora'
    assert value['mode']=='bridge' and value['freeze_sha256']==freeze and value['installed_apk_sha256']==APKS
    assert value['guest_memory_mib']==2048 and value['lowram_emulation_variant'] is True
    assert value['android_tests_before_bridge'] is False and value['single_nora_memory_probe'] is True
    assert re.fullmatch('[0-9a-f]{32}',value['batch_id'])
    assert 0<=now-value['created_unix']<=300 and now<value['expires_unix']<=value['created_unix']+600
    assert now<value['batch_deadline_unix']<=value['created_unix']+2700
    assert value['inputs_sha256']==sha(ROOT/'runtime-inputs.json')=='497bdf37cdcd317895a8d33efc3e0f9be189d4110f81f89d218b0c1817f775c2'
    _native_readonly_bindings(value['native_bindings'],now)
    probe_path=HARNESS/'triple_v3/gpu_probe/probe.py'
    assert sha(probe_path)=='30302b9f69432122545a388b7947faf9774cf5e6988950f2624dc111edce5f6f'
    spec=_iu.spec_from_file_location('nora_sdk_inventory_guard',probe_path)
    inventory=_iu.module_from_spec(spec);spec.loader.exec_module(inventory)
    inventory.require_no_guests(inventory.guest_processes(inventory.load_baseline()))
    # Existing historical evidence remains historical; no currently running native
    # testpeer is required OFF by this one-Android profile.
    verify_install_apks();verify_current_eight();verify_invite_history()
    return {'freeze_sha256':freeze,'inputs_sha256':value['inputs_sha256'],'client_variant':CLIENT_VARIANT,
        'source_manifest_sha256':PRODUCT['source']['sha256'],'apk_sha256':APKS,
        'approval_sha256':sha(path),'batch_id':value['batch_id'],'batch_deadline_unix':value['batch_deadline_unix'],
        'derivation':verify_derivation(),'native_readonly_bindings':value['native_bindings']}

def control_settings(role):
    settings=_old_control_settings(role)
    session=read(settings['state']/'live-session.json')
    assert time.time()<session['batch_deadline_unix']
    script=Path(sys.argv[0]).resolve(strict=True)
    approved={HERE/'runtime.py',HERE/'control.py',HERE/'recorder.py',HERE/'scenario.py'}
    assert script in approved,'Exact frozen Nora caller required'
    return settings



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


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('role', choices=('nora',))
    parser.add_argument('--guest-memory-mib', type=int, choices=(2048,), default=2048)
    parser.add_argument('--lowram', action='store_true')
    parser.add_argument('--android-tests-before-bridge', action='store_true')
    args = parser.parse_args()
    def terminate(signum, frame): raise SystemExit('Owned V2 runtime interrupted')
    signal.signal(signal.SIGTERM, terminate); signal.signal(signal.SIGINT, terminate)
    run(args.role, args.guest_memory_mib, args.lowram, args.android_tests_before_bridge)

"""Read-only actual616 product contract; importing never creates runtime files."""
import hashlib
import json
from pathlib import Path
import re
import subprocess
import xml.etree.ElementTree as ET

JVM = '4f47c0fc108684c2bdf1706d77c72d45ff841acc7b87c34fcd47909beb020229'
SOURCE = 'b1ac6b70000caa0b5e512e94da128508ad09bc2a14d0b8b86708404db7cd4491'
OVERLAY = 'befe44fee0119bb07a6097edeb5034f7323b38766a74da656a34a202a565fde3'
CERT = '89ad5d0085ecee67350b62cb634d5d2ee7255f928c9979e32753f4e4bc519ecf'
TEST = '486b06a8f472fc68d89f9ced35b1befbc67805f22aa0d3dbf1c162cf3aab6e65'
COMMIT = '05ea2fb4c144f5373883dbc1124396d12bd4ed4d'
FORK = Path('/media/linux/SSD128/monocles-chat-upstream')


def sha(path):
    with Path(path).open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()


def read(path):
    path=Path(path);assert path.is_file() and not path.is_symlink() and path.stat().st_size<=8*1024**2
    return json.loads(path.read_text())


def verify(handoff_path):
    path=Path(handoff_path);h=read(path)  # Missing real handoff hard-fails BEFORE output.
    b=read(h['main_build_receipt_path']);j=read(h['jvm_receipt_path']);s=read(h['source_manifest_path'])
    assert h['result']==b['result']==j['result']=='PASS'
    assert sha(h['main_build_receipt_path'])==h['main_build_receipt_sha256']
    assert sha(h['source_manifest_path'])==h['source_manifest_sha256']==b['source_manifest_sha256']==j['source_manifest_sha256']==SOURCE
    assert sha(h['jvm_receipt_path'])==h['jvm_receipt_sha256']==b['jvm_receipt_sha256']==JVM
    assert sha(h['apk_path'])==h['apk_sha256']==b['apk_sha256'] and Path(h['apk_path']).stat().st_size==b['apk_size']
    assert sha(h['test_apk_path'])==h['test_apk_sha256']==b['existing_signed_test_apk_sha256']==TEST
    assert h['signer_certificate_sha256']==b['signer_certificate_sha256']==CERT
    for flag in ('local_jarsigner_signature_and_entry_digests_verified','local_certificate_keytool_verified','server_apksigner_v1_and_v2_verified'):
        assert h[flag] is True
    assert h['actual_jvm_tests']==b['actual_jvm_tests']==j['tests']==j['unique_cases']==616
    assert j['failures']==j['errors']==j['skipped']==0 and j['source_restored'] and b['source_restored']
    assert b['all_other_main_classes_unchanged'] and b['all_36_native_entries_unchanged']
    assert b['only_reviewed_semantic_call_layout_and_resource_table_changed']
    semantic=read(h['resource_semantic_receipt_path'])
    assert sha(h['resource_semantic_receipt_path'])==h['resource_semantic_receipt_sha256']==b['resource_semantic_receipt_sha256']
    assert semantic['result']=='PASS' and semantic['new_apk_sha256']==h['apk_sha256']
    assert semantic['semantic_changed_entries']==b['semantic_resource_changes']==['res/layout/activity_rtp_session.xml','resources.arsc']
    assert semantic['actual_binary_changed_non_dex_entries']==b['resource_changes'] and len(b['resource_changes'])==317
    assert b['acceptance']==h['acceptance']=='VERIFY_COMPLETED_EXISTING_SUCCESSFUL_BUILD' and b['original_controller_exit']==1
    assert b['native_or_sdk_build_requested'] is b['test_apk_rebuilt'] is b['config_background_stanza_logging'] is False
    assert h['runtime_or_new_android_test_result_claimed'] is h['native_or_sdk_rebuild'] is False
    assert h['reviewed_source_commit']==COMMIT and h['source_overlay_sha256']==b['source_overlay_sha256']==OVERLAY
    overlay=read(path.parent.parent/'source-overlay.json');assert sha(path.parent.parent/'source-overlay.json')==OVERLAY
    assert len(overlay['files'])==18 and len(overlay['expected_regression_cases'])==28
    for name,record in overlay['files'].items():
        raw=subprocess.check_output(['git','show',COMMIT+':'+name],cwd=FORK,timeout=10)
        assert hashlib.sha256(raw).hexdigest()==record['sha256']==s['files'][name]['sha256']
        assert sha(FORK/name)==record['sha256'], 'Live fork source diverged from reviewed commit'
    names=[]
    for xml in (Path(h['jvm_receipt_path']).parent/'jvm-results').glob('TEST-*.xml'):
        tree=ET.parse(xml).getroot()
        for case in tree.findall('testcase'):
            assert not any(case.find(tag) is not None for tag in ('failure','error','skipped'))
            names.append((case.get('classname'),case.get('name')))
    assert len(names)==len(set(names))==616
    assert set(map(tuple,overlay['expected_regression_cases']))<=set(names)
    return {'handoff':{'path':str(path.resolve()),'sha256':sha(path)},'build':{'path':h['main_build_receipt_path'],'sha256':h['main_build_receipt_sha256']},
        'jvm':{'path':h['jvm_receipt_path'],'sha256':JVM},'source':{'path':h['source_manifest_path'],'sha256':SOURCE},
        'main_path':h['apk_path'],'main_sha256':h['apk_sha256'],'test_path':h['test_apk_path'],'test_sha256':TEST,
        'commit':COMMIT,'actual_jvm_tests':616,'signer_certificate_sha256':CERT}


def checked(reference):
    assert set(reference)=={'path','sha256'} and re.fullmatch('[a-f0-9]{64}',reference['sha256'])
    assert sha(reference['path'])==reference['sha256'];return read(reference['path'])

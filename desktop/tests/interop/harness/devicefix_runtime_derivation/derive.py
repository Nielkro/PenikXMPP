#!/usr/bin/env python3
"""Generate additive source copies only after the actual verified616 Main exists."""
import argparse,ast,difflib,hashlib,json,os,re
from pathlib import Path
import product_proof as p

HERE=Path(__file__).resolve().parent;H=HERE.parent
A=H/'devicefix_nora_runtime';B=H/'triple_v3/runtime_consent';C=H/'triple_v3/product_devicefix_consent'
BASE_A=H/'pair_v2';BASE_B=H/'triple_v3/runtime_host_gpu'
MIXED=H/'legacy3_mixed_consent/normal_mixed_ui_consent.py'
CONSENT=H/'triple_v3/normal_consent_ui/normal_ui_consent.py'
CAPTURE=HERE/'call_layout_capture.py'
PINS={'devicefix_runtime_derivation/call_layout_capture.py':'b112ad2232484bea98d19ed5addc67fa5213ae6d12fe0979e6c7d0c7c5d4a664',
      'pair_v2/runtime.py':'bdcf594aa98be73fc08fb4ce1a955d53671a91bc0c523df4ba26b4ef1bd52816',
      'pair_v2/control.py':'f078c3f59836e7de0691e4a7cbe1947adda5a5d47327a44ca6d1bc60a6f08a00',
      'pair_v2/recorder.py':'416a89203a246dd481f8a79fd08dd930f6ed988d8eccceb5a12ed31bbdfb16b5',
      'pair_v2/freeze.json':'e406750ab36b260618f254c15d8cedcbc52db6dcfa0a1e26e073aaf1cf46df28',
      'triple_v3/runtime_host_gpu/runtime.py':'219e6597254e744d0bbabf494344d9037488b8f4fc11a82b7b68ea482613f4ac',
      'triple_v3/runtime_host_gpu/freeze.json':'0e33619d5e0274115d5b06039f5e499b0bd62c17d7c4a4bb5da58b001706350e',
      'triple_v3/normal_consent_ui/normal_ui_consent.py':'59d623366d17a75d77c6afcc3269531ce6d313704b69d39de18cb9224fde3b8a',
      'legacy3_mixed_consent/normal_mixed_ui_consent.py':'16b236d8a8f8b5cb645114de03cb02635bc524d56cd1fcfc0b27a8c32c7da942',
      'legacy3_followup/legacy_three_audio_watchdog_media_first.py':'2286580380ef81b81a355c1e93405e2e4da4278bc4fc268570956928a0d525b8',
      'triple_v3/product_host_gpu/scenarios.py':'e7b4b211cb9c095da5b42855952983cc49870f1db5a140fea245970633ed2006'}


def once(text,old,new):
    assert text.count(old)==1,old[:100]
    return text.replace(old,new)


def before_main(text,block):return once(text,"if __name__ == '__main__':",block+"\n\nif __name__ == '__main__':")


def function(text,name,replacement):
    node=next(n for n in ast.parse(text).body if isinstance(n,ast.FunctionDef) and n.name==name)
    lines=text.splitlines(keepends=True);return ''.join(lines[:node.lineno-1])+replacement+'\n\n'+''.join(lines[node.end_lineno:])


def baselines():
    for path,digest in PINS.items():assert p.sha(H/path)==digest,path
    value=p.read(BASE_B/'freeze.json')
    for name,digest in value['files_sha256'].items():assert p.sha(BASE_B/name)==digest
    return dict(PINS)


def render(product):
    """In-memory source transform only. CLI verifies real inputs before calling."""
    baselines();files={};originals={}
    def add(path,text,old=''):
        if path.suffix=='.py':ast.parse(text)
        files[path]=text.encode();originals[path]=old
    dispatch=HERE/'consent_dispatch.py'
    dispatch_import="\nimport importlib.util as _ci\n_cs=_ci.spec_from_file_location('scoped_consent_dispatch',"+repr(str(dispatch))+ ")\nassert r.sha(Path(_cs.origin))=="+repr(p.sha(dispatch))+"\nconsent_ui=_ci.module_from_spec(_cs);_cs.loader.exec_module(consent_ui)\n"
    # A: copy only the three reviewed V2 sources; Nora keeps its own AVD/profile.
    source=(BASE_A/'runtime.py').read_text()
    source=once(source,"choices=('nora', 'leon')","choices=('nora',)")
    source=once(source,'choices=(2048, 2560), default=2560','choices=(2048,), default=2048')
    source=once(source,"sample = v1.resources()\n            with", "sample = v1.resources()\n            assert time.time()<proof['batch_deadline_unix']\n            with")
    block=(HERE/'nora_overrides.py.in').read_text()
    for token,value in {'_BASELINE_':str(BASE_A/'runtime.py'),'_PRODUCT_':product,'_MIXED_SHA_':p.sha(MIXED),'_MIXED_PATH_':str(MIXED),'_LAYOUT_PATH_':str(CAPTURE),'_LAYOUT_SHA_':p.sha(CAPTURE)}.items():
        block=re.sub(r'(?<!\w)'+re.escape(token)+r'(?!\w)',lambda _:repr(value),block)
    source=before_main(source,block);add(A/'runtime.py',source,(BASE_A/'runtime.py').read_text())
    control=(BASE_A/'control.py').read_text()
    control=once(control,"assert value.get('transport') in ('local-android', 'server'), 'Explicit transport required'","assert value.get('transport') == 'local-android', 'Nora-only Android control; natives use separate readonly admission'")
    control=once(control,"assert value['role'] in ('nora', 'leon')","assert value['role'] == 'nora'")
    add(A/'control.py',control,(BASE_A/'control.py').read_text());add(A/'recorder.py',(BASE_A/'recorder.py').read_text())
    legacy=(H/'legacy3_followup/legacy_three_audio_watchdog_media_first.py').read_text()
    legacy=once(legacy,"str(HERE.parent / 'pair_v2')","str(HERE)")
    legacy=once(legacy,"r.role_config('leon')['state'] / 'live-session.json'","r._historical.role_config('leon')['state'] / 'live-session.json'")
    legacy=once(legacy,'import native_recorder as native_rec\nimport native_control as server_control','native_rec = server_control = None')
    new_native="""    global native_rec,server_control
    initial=r.control_settings('nora');session=r.read(initial['state']/'live-session.json')
    binding=session['native_readonly_bindings'];directory=Path(binding['directory'])
    assert r.sha(directory/'native_control.py')==binding['control_sha256']
    assert r.sha(directory/'native_recorder.py')==binding['recorder_sha256']
    spec=_ci.spec_from_file_location('native_control',directory/'native_control.py')
    server_control=_ci.module_from_spec(spec);sys.modules['native_control']=server_control;spec.loader.exec_module(server_control)
    spec=_ci.spec_from_file_location('actual_native_recorder',directory/'native_recorder.py')
    native_rec=_ci.module_from_spec(spec);spec.loader.exec_module(native_rec)
    assert args.native_admission_sha256==binding['admission_sha256']
    native_rec.ADMISSION_SHA = args.native_admission_sha256"""
    legacy=once(legacy,'    native_rec.ADMISSION_SHA = args.native_admission_sha256',new_native)
    legacy=once(legacy,"MAIN = 'ebc9b9d9f8264cf22acc3235614bea118722da171666a98865f5df8b446d5d8a'",'MAIN = '+repr(product['main_sha256']))
    legacy=once(legacy,"FREEZE = 'e406750ab36b260618f254c15d8cedcbc52db6dcfa0a1e26e073aaf1cf46df28'",'FREEZE = r.frozen_files()')
    legacy=once(legacy,"assert join['actual_jvm_tests'] == 600","assert join['actual_jvm_tests'] == 616")
    legacy=once(legacy,"parser.add_argument('--native-admission-sha256', required=True)","parser.add_argument('--native-admission-sha256', required=True)\n    parser.add_argument('--consent-references',type=Path,required=True)")
    legacy=once(legacy,"    text_error = None\n    try:\n        for sender in ROLES:","    text_error = None\n    try:\n        op('nora','prepare-room-legacy-once',{'op':'prepare_crypto','room':room,'encryption':'legacy'})\n        current=observe('normal-consent-owner-scope')\n        ref=consent_ui.owner_reference(r,write,context['consent_references'],'nora',{'room':room,'states':current},context['evidence_directory'])\n        session=r.read(r.control_settings('nora')['state']/'live-session.json')\n        consent_ui.dispatch(r,write,Path("+repr(str(MIXED))+"),"+repr(p.sha(MIXED))+",ref,'nora',room,'legacy',session['batch_id'],mixed=True)\n        for sender in ROLES:")
    legacy=once(legacy,"'trace_sids': set()}","'trace_sids': set(),'consent_references':args.consent_references,'evidence_directory':out}")
    legacy=once(legacy,"            op(sender, 'prepare-room-legacy-once', {'op': 'prepare_crypto', 'room': room, 'encryption': 'legacy'})","            if sender != 'nora':op(sender, 'prepare-room-legacy-once', {'op': 'prepare_crypto', 'room': room, 'encryption': 'legacy'})")
    legacy=once(legacy,"PREFIX = {",dispatch_import+"\nPREFIX = {")
    layout_import="\n_ls=_ci.spec_from_file_location('actual_layout_capture',"+repr(str(CAPTURE))+")\nassert r.sha(Path(_ls.origin))=="+repr(p.sha(CAPTURE))+"\nlayout_capture=_ci.module_from_spec(_ls);_ls.loader.exec_module(layout_capture)\n"
    legacy=once(legacy,"PREFIX = {",layout_import+"\nPREFIX = {")
    legacy=once(legacy,"        scenario(op, write, context)","        scenario(op, write, context)\n        layout_capture.capture(r,op,write,out,context['room'])")
    add(A/'scenario.py',legacy,(H/'legacy3_followup/legacy_three_audio_watchdog_media_first.py').read_text())
    # B: six small copies, unchanged infrastructure behavior plus exact helper.
    for name in ('runtime.py','control.py','recorder.py','check_guards.py','ui_control.py','README.md'):
        old=(BASE_B/name).read_text();text=old
        if name=='runtime.py':
            text=once(text,"(HERE / 'control.py', HERE / 'recorder.py', HERE / 'ui_control.py')", "(HERE / 'control.py', HERE / 'recorder.py', HERE / 'ui_control.py', CONSENT_HELPER)")
            block=(HERE/'gpu_overrides.py.in').read_text()
            for token,value in {'_PRODUCT_':product,'_CONSENT_SHA_':p.sha(CONSENT),'_CONSENT_PATH_':str(CONSENT)}.items():
                block=re.sub(r'(?<!\w)'+re.escape(token)+r'(?!\w)',lambda _:repr(value),block)
            text=before_main(text,block)
        add(B/name,text,old)
    # Freeze these source copies, never a Root approval or a measured-fit claim.
    def digest(data):return hashlib.sha256(data).hexdigest()
    af={'schema_version':1,'mode':'Nora-only-2048-devicefix-consent','roles':['nora'],'product':product,
        'apk_sha256':{'main.apk':product['main_sha256'],'android-test.apk':product['test_sha256']},
        'files_sha256':{name:digest(files[A/name]) for name in ('runtime.py','control.py','recorder.py','scenario.py')},
        'root_start_authorized':False,'marker_created':False,'runtime_started':False}
    bf=p.read(BASE_B/'freeze.json');bf.update(product=product,apk_sha256=af['apk_sha256'],join_handoff_sha256=product['handoff']['sha256'],
        files_sha256={name:digest(files[B/name]) for name in bf['files_sha256']})
    add(A/'freeze.json',json.dumps(af,indent=2)+'\n');add(B/'freeze.json',json.dumps(bf,indent=2)+'\n')
    # Separate host-GPU product source, preserving 3 tokens/6 decrypts and media.
    old=(H/'triple_v3/product_host_gpu/scenarios.py').read_text();scenario=old
    scenario=once(scenario,"'runtime_host_gpu'","'runtime_consent'")
    scenario=once(scenario,"RUNTIME_FREEZE = '0e33619d5e0274115d5b06039f5e499b0bd62c17d7c4a4bb5da58b001706350e'",'RUNTIME_FREEZE = r.frozen_files()')
    scenario=once(scenario,'class InfrastructureIncomplete',dispatch_import+'\nclass InfrastructureIncomplete')
    scenario=once(scenario,'    tokens, deliveries=[],[]','    for role in ROLES:io.normal_consent(role,mode)\n    tokens, deliveries=[],[]')
    scenario=once(scenario,'    def __init__(self,room):','    def __init__(self,room,consent_references=None):\n        self.consent_references=consent_references')
    method="""    def normal_consent(self,role,mode):
        assert self.consent_references is not None
        scope={p:self.state(p,'normal-consent-owner-scope') for p in ROLES}
        ref=consent_ui.owner_reference(r,self.write,self.consent_references,role,{'room':self.room,'states':scope,'batch_id':self.batch},self.out)
        return consent_ui.dispatch(r,self.write,Path(HELPER),DIGEST,ref,role,self.room,mode,self.batch)
""".replace('HELPER',repr(str(CONSENT))).replace('DIGEST',repr(p.sha(CONSENT)))
    scenario=once(scenario,'    def ui_choice(self,role,action):',method+'\n    def ui_choice(self,role,action):')
    scenario=once(scenario,"parser.add_argument('--leave-normal-ui-rejoin',action='store_true');args=parser.parse_args()", "parser.add_argument('--leave-normal-ui-rejoin',action='store_true');parser.add_argument('--consent-references',type=Path);args=parser.parse_args()\n    assert args.case!='group-text' or args.consent_references is not None")
    scenario=once(scenario,'io=IO(args.room)','io=IO(args.room,args.consent_references)')
    proof_fn="""def source_contract():
    freeze=r.read(HERE/'source-freeze.json')
    assert freeze['runtime_freeze_sha256']==r.frozen_files()==RUNTIME_FREEZE
    for name,digest in freeze['files_sha256'].items():assert r.sha(HERE/name)==digest
    value=r.read(HERE/'source-contract.json')
    assert value['main_apk_sha256']==r.APKS['main.apk'] and value['test_apk_sha256']==r.APKS['android-test.apk']
    manifest=r.read(r.base.PROOFS['join_source'][0])
    assert r.sha(r.base.PROOFS['join_source'][0])==value['main_source_manifest_sha256']
    for name,digest in value['source_files'].items():
        assert manifest['files'][name]['sha256']==r.sha(Path(value['source_root'])/name)==digest
    assert r.sha(r.HERE/'ui_control.py')==UI_SHA
    assert r.sha(Path(CONSENT))==CONSENT_SHA
    return value
""".replace('Path(CONSENT)', 'Path('+repr(str(CONSENT))+')').replace('CONSENT_SHA',repr(p.sha(CONSENT)))
    scenario=function(scenario,'source_contract',proof_fn)
    add(C/'scenarios.py',scenario,old)
    contract=p.read(H/'triple_v3/product_host_gpu/source-contract.json')
    contract.update(main_apk_sha256=product['main_sha256'],test_apk_sha256=product['test_sha256'],main_source_manifest_sha256=product['source']['sha256'],
        normal_ui_join_route_reviewed_for_runtime_freeze=False,new_derivative_independent_review_and_Root_admission_required=True)
    contract['normal_ui_route'].update(runtime_freeze_sha256=digest(files[B/'freeze.json']))
    add(C/'source-contract.json',json.dumps(contract,indent=2)+'\n')
    note='Additive616 product/normal consent source only; independently review before Root launch. Original e7b4/0e336 evidence unchanged.\n'
    add(C/'README.md',note)
    sf={'runtime_freeze_sha256':digest(files[B/'freeze.json']),'files_sha256':{name:digest(files[C/name]) for name in ('scenarios.py','source-contract.json','README.md')},'runtime_started':False}
    add(C/'source-freeze.json',json.dumps(sf,indent=2)+'\n')
    return files,originals


def generate(handoff):
    product=p.verify(handoff)  # Must succeed before any output directory/file.
    files,originals=render(product)
    assert all(not target.exists() for target in (A,B,C)),'Never overwrite a prior derivative'
    os.umask(0o077)
    for path,raw in files.items():path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(raw)
    for directory in (A,B,C):
        changes=''.join(''.join(difflib.unified_diff(originals[path].splitlines(True),raw.decode().splitlines(True),
            fromfile='historical/'+path.name,tofile=str(path))) for path,raw in files.items() if path.parent==directory and originals[path])
        (directory/'derivation.diff').write_text(changes)
    receipt={'result':'ACTUAL_PRODUCT_BOUND_SOURCE_DERIVATIVES_NOT_RUNTIME_ADMISSION','product':product,
        'files_sha256':{str(path):p.sha(path) for path in files},'source_baselines_unchanged':baselines(),
        'root_marker_admission_AVD_profile_account_created':False,'runtime_started':False}
    target=HERE/'actual-generation.json';assert not target.exists();target.write_text(json.dumps(receipt,indent=2)+'\n')
    print(json.dumps({'source_only_generated':str(target),'sha256':p.sha(target)}))


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--actual-main-handoff',type=Path,required=True)
    args=parser.parse_args();generate(args.actual_main_handoff)

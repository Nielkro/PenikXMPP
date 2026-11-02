#!/usr/bin/env python3
"""Derive sources only after real remesh build, JVM, signing and handoff receipts exist."""
import argparse
import ast
import difflib
import hashlib
import json
import os
from pathlib import Path
import re
import sys

HERE=Path(__file__).resolve().parent
BASE=HERE.parent/'mixed-video-owner-900-source'
BASE_MANIFEST='303cb669ce0e737b76ef45f78ed1dad10d52877cb199209a62dde9d05701a577'
BASE_FREEZE='aa26bdddf406771b167bdffca3ec4a62b5339f6d8990f2b4dc9af2790b4e4fe2'
NAMES=('runtime.py','control.py','recorder.py','scenario.py','monitor.py','process_lifecycle.py')


def sha(path):
    with Path(path).open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()


def read(path):
    path=Path(path)
    assert path.is_file() and not path.is_symlink() and path.stat().st_size<=2*1024**2
    return json.loads(path.read_bytes())


def assignment(text,name,replacement):
    nodes=[n for n in ast.parse(text).body if isinstance(n,ast.Assign)
           and any(isinstance(t,ast.Name) and t.id==name for t in n.targets)]
    node=nodes[-1];lines=text.splitlines(keepends=True)
    return ''.join(lines[:node.lineno-1])+replacement+'\n'+''.join(lines[node.end_lineno:])


def function(text,name,replacement):
    node=[n for n in ast.parse(text).body if isinstance(n,ast.FunctionDef) and n.name==name][-1]
    lines=text.splitlines(keepends=True)
    return ''.join(lines[:node.lineno-1])+replacement.rstrip()+'\n'+''.join(lines[node.end_lineno:])


def qualify(product,guard):
    previous=ast.literal_eval([n.value for n in ast.parse((BASE/'runtime.py').read_text()).body
        if isinstance(n,ast.Assign) and any(isinstance(t,ast.Name) and t.id=='PRODUCT' for t in n.targets)][-1])
    assert set(product)==set(previous)|{'focus','actual_focus_tests'}
    for name in ('handoff','build','jvm','focus','source'):
        ref=product[name];assert set(ref)=={'path','sha256'}
        assert Path(ref['path']).is_absolute() and re.fullmatch('[0-9a-f]{64}',ref['sha256'])
    assert re.fullmatch('[0-9a-f]{40}',product['commit'])
    assert product['main_sha256']!=previous['main_sha256']
    for kind in ('main','test'):
        path=Path(product[kind+'_path'])
        assert path.is_absolute() and path.is_file() and not path.is_symlink()
        assert sha(path)==product[kind+'_sha256']
    scope={'PRODUCT':product,'APKS':{'main.apk':product['main_sha256'],
        'android-test.apk':product['test_sha256']},'JOIN_PRODUCT_PROOF':{},'Path':Path,'sha':sha,'read':read}
    exec(compile(ast.parse(guard),'<actual-pure-product-receipt-guard>','exec'),scope)
    scope['_current_product']()
    return previous


def derive(product,guard):
    runtime=(BASE/'runtime.py').read_text()
    runtime=assignment(runtime,'PRODUCT','PRODUCT = '+repr(product))
    runtime=assignment(runtime,'CLIENT_VARIANT',"CLIENT_VARIANT = 'remesh-fixed-current-mixed-video-' + str(PRODUCT['actual_jvm_tests']) + '-Nora-only-2048-lowram'")
    proof="""JOIN_PRODUCT_PROOF = dict(_historical.JOIN_PRODUCT_PROOF,
    main_sha256=PRODUCT['main_sha256'],source_manifest_sha256=PRODUCT['source']['sha256'],
    actual_jvm_tests=PRODUCT['actual_jvm_tests'],actual_focus_tests=PRODUCT['actual_focus_tests'],
    reviewed_source_commit=PRODUCT['commit'],local_handoff_path=PRODUCT['handoff']['path'],
    local_handoff_sha256=PRODUCT['handoff']['sha256'])"""
    runtime=assignment(runtime,'JOIN_PRODUCT_PROOF',proof)
    runtime=function(runtime,'_current_product',guard)
    assert runtime.count("'current_616':_current_product()")==1
    runtime=runtime.replace("'current_616':_current_product()","'current_remesh_fixed':_current_product()")
    scenario=(BASE/'scenario.py').read_text()
    scenario=assignment(scenario,'MAIN','MAIN='+repr(product['main_sha256']))
    old_apks=read(BASE/'freeze.json')['apk_sha256']
    # MAIN already supplies the APK value in this unchanged scenario assertion.
    target=next(line for line in scenario.splitlines() if line.startswith('    assert r.APKS=='))
    expected="    assert r.APKS=={'main.apk':MAIN,'android-test.apk':"+repr(old_apks['android-test.apk'])+'}'
    assert ast.dump(ast.parse(target.strip()))==ast.dump(ast.parse(expected.strip()))
    assert product['test_sha256']==old_apks['android-test.apk']
    new_apks={'main.apk':product['main_sha256'],'android-test.apk':product['test_sha256']}
    assert scenario.count("join['actual_jvm_tests'] == 616")==1
    scenario=scenario.replace("join['actual_jvm_tests'] == 616","join['actual_jvm_tests'] == r.PRODUCT['actual_jvm_tests']")
    values={name:(BASE/name).read_bytes() for name in NAMES}
    values['runtime.py']=runtime.encode();values['scenario.py']=scenario.encode()
    for name,raw in values.items():ast.parse(raw.decode(),filename=name)
    freeze=read(BASE/'freeze.json')
    freeze['product']=product;freeze['apk_sha256']=new_apks
    freeze['files_sha256']={name:hashlib.sha256(raw).hexdigest() for name,raw in values.items()}
    assert freeze['root_start_authorized'] is freeze['marker_created'] is freeze['runtime_started'] is False
    values['freeze.json']=(json.dumps(freeze,indent=2)+'\n').encode()
    values['product-pins.json']=(json.dumps(product,indent=2)+'\n').encode()
    return values


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--product-pins',type=Path,default=HERE/'verified-build-product.json')
    args=parser.parse_args()
    assert not sys.flags.optimize
    assert sha(BASE/'source-manifest.json')==BASE_MANIFEST and sha(BASE/'freeze.json')==BASE_FREEZE
    manifest=read(BASE/'source-manifest.json')
    for name,row in manifest['files'].items():assert sha(BASE/name)==row['sha256']
    assert not (HERE/'runtime-state').exists()
    assert all(not (HERE/name).exists() for name in (*NAMES,'freeze.json','product-pins.json'))
    guard=(HERE/'current_product_guard.source').read_text()
    try:
        product=read(args.product_pins);qualify(product,guard)
    except (OSError,AssertionError,KeyError,ValueError,TypeError):
        print('NOT_READY_REAL_BUILD_JVM_FOCUS_APK_HANDOFF_PINS_REQUIRED');return 2
    values=derive(product,guard)
    diff=[]
    for name in (*NAMES,'freeze.json'):
        diff.extend(difflib.unified_diff((BASE/name).read_text().splitlines(keepends=True),
            values[name].decode().splitlines(keepends=True),fromfile=str(BASE/name),tofile=str(HERE/name)))
    values['product-derivation.diff']=''.join(diff).encode()
    # Freeze is written last; no marker, claim, admission, session or runtime is created.
    for name in [n for n in values if n!='freeze.json']+['freeze.json']:
        fd=os.open(HERE/name,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
        with os.fdopen(fd,'wb') as stream:stream.write(values[name]);stream.flush();os.fsync(stream.fileno())
    print(json.dumps({'result':'SOURCES_DERIVED_FROM_ACTUAL_QUALIFIED_PRODUCT_ONLY_NO_RUNTIME_START',
        'freeze_sha256':sha(HERE/'freeze.json'),'actual_jvm_tests':product['actual_jvm_tests'],
        'actual_focus_tests':product['actual_focus_tests'],'main_sha256':product['main_sha256']}))
    return 0


if __name__=='__main__':sys.exit(main())

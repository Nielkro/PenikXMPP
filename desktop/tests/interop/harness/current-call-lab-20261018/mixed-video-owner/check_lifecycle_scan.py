#!/usr/bin/env python3
"""Run the checked Fake-/proc scan cases on this exact pure lifecycle copy only."""
import ast
import contextlib
import hashlib
import io
import json
from pathlib import Path

HERE=Path(__file__).resolve().parent
ORIGINAL=HERE.parent/'lifecycle-terminal-fix/check_lifecycle_offline.py'
ORIGINAL_SHA='e53d574100e0fe6fdb518ead3d80a345ceb91c0577177921c4b9267dab301dfb'
assert hashlib.sha256(ORIGINAL.read_bytes()).hexdigest()==ORIGINAL_SHA
assert hashlib.sha256((HERE/'process_lifecycle.py').read_bytes()).hexdigest()=='cbccb23b594d64471ce2851dd9105c99a874bd3bc061e7631e2fd4dd9a46fff9'
text=ORIGINAL.read_text()
assert text.count("HERE/'runtime_consent/process_lifecycle.py'")==1
text=text.replace("HERE/'runtime_consent/process_lifecycle.py'","HERE/'process_lifecycle.py'")
text=text.replace('PASS_ACTUAL_LIFECYCLE_FAKEPROC_AND_SPAWN','PASS_ACTUAL_LIFECYCLE_SCAN_FAKEPROC_ONLY')
tree=ast.parse(text)
main=next(n for n in tree.body if isinstance(n,ast.FunctionDef)and n.name=='main')
removed=[];body=[]
for statement in main.body:
    if isinstance(statement,ast.Expr)and isinstance(statement.value,ast.Call):
        call=statement.value
        if isinstance(call.func,ast.Name)and call.func.id in ('publication_test','topology_test'):
            removed.append(call.func.id);continue
        if isinstance(call.func,ast.Attribute)and call.func.attr=='append'and call.args and isinstance(call.args[0],ast.Constant):
            if call.args[0].value in ('actual_spawn_publication_before_inventory_unlock_no_arguments',
                'actual_capture_admission_and_all_active_helper_paths_and_pins','actual_capture_admission_wrong_helper_hash_rejected'):
                continue
    body.append(statement)
assert removed==['publication_test','topology_test']
main.body=body;ast.fix_missing_locations(tree)
scope={'__file__':str(HERE/'check_lifecycle_scan.py'),'__name__':'A18V_fakeproc_scan_only'}
stdout=io.StringIO()
with contextlib.redirect_stdout(stdout):
    exec(compile(tree,'<reviewed-Fakeproc-only-adaptation>','exec'),scope)
    scope['main']()
result=json.loads(stdout.getvalue())
assert result['result']=='PASS_ACTUAL_LIFECYCLE_SCAN_FAKEPROC_ONLY'
assert result['live_process_ADB_SDK']is False
result.update(original_offline_source_sha256=ORIGINAL_SHA,
    pure_lifecycle_sha256='cbccb23b594d64471ce2851dd9105c99a874bd3bc061e7631e2fd4dd9a46fff9',
    only_unrelated_B_spawn_and_capture_topology_tests_omitted=True,
    actual_A18V_gate_uses_this_scanner_without_global_override=True)
path=HERE/'lifecycle-offline-checks.json';path.write_text(json.dumps(result,indent=2)+'\n');path.chmod(0o600)
print(json.dumps(result,indent=2))

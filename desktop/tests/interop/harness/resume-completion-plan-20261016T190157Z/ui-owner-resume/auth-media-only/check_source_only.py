#!/usr/bin/env python3
"""Pure AST checks of the narrow auth-media-only derivation; no application imports."""
import ast,hashlib,json
from pathlib import Path
HERE=Path(__file__).resolve().parent
base_path=HERE.parent/'mixed_scenario.py'
assert hashlib.sha256(base_path.read_bytes()).hexdigest()=='895aa598f4f069ad8978b352c870cb544a7b4f0c5f7310bdd5240d9c120a7f87'
base=ast.parse(base_path.read_text());source=ast.parse((HERE/'auth_media.py').read_text())
old={n.name:n for n in base.body if isinstance(n,ast.FunctionDef)}
new={n.name:n for n in source.body if isinstance(n,ast.FunctionDef)}
checks=[]
for name in ('enum_is','idle','wait_for','endpoints','counters','received','public_identity','same_three','owner_session','android_record'):
 assert ast.dump(new[name])==ast.dump(old[name]),name
checks.append('Ten accepted pure/media/identity/exact-session/actual-A-recorder-CLI functions AST unchanged from895')
def first_three(node):
 prefix=[]
 for item in node.body:
  prefix.append(item)
  if isinstance(item,ast.Assign) and any(isinstance(t,ast.Name) and t.id=='full' for t in item.targets):break
 assert ast.unparse(prefix[-1])=="full = media('first-three', PAIRS, room)"
 return ast.Module(body=prefix,type_ignores=[])
assert ast.dump(first_three(new['scenario']))==ast.dump(first_three(old['scenario']))
checks.append('Complete direct Legacy preparation/start/accept/promotion/Felix acceptance and first-three six RTP/PCM edges mechanically unchanged')
def inner(node,name):return next(n for n in node.body if isinstance(n,ast.FunctionDef) and n.name==name)
assert ast.dump(inner(new['main'],'op'))==ast.dump(inner(old['main'],'op'))
def cleanup(node):
 final=next(n.finalbody for n in node.body if isinstance(n,ast.Try) and n.finalbody)
 return next(n for n in final if isinstance(n,ast.For))
assert ast.dump(cleanup(new['main']))==ast.dump(cleanup(old['main']))
checks.append('Current dynamic native bindings and real recorder operation path retained; exact observed call-ID/SID cleanup loop unchanged')
assert 'normal_owner_consent' not in new and 'text_stage' not in new
admission=ast.unparse(new['root_admission'])
assert 'owner-auth-media-only-sibling' in admission
assert 'owner_ui' not in admission and 'consent_reference' not in admission
scenario=ast.unparse(new['scenario'])
ops={value.value for n in ast.walk(new['scenario']) if isinstance(n,ast.Dict)
 for key,value in zip(n.keys,n.values) if isinstance(key,ast.Constant) and key.value=='op' and isinstance(value,ast.Constant)}
assert ops=={'stats','prepare_crypto','start_call','accept_call','add_participant','authorize_room'}
assert '65' not in scenario.split("write('scenario-result.json'")[0] and 'reinvite' not in scenario.split("write('scenario-result.json'")[0]
checks.append('Distinct auth-media-only operation has no UI dependency, text operation, 65-second hold or re-invite')
writes={n.value.args[0].value:n.value.args[1] for n in new['scenario'].body if isinstance(n,ast.Expr) and isinstance(n.value,ast.Call)
 and isinstance(n.value.func,ast.Name) and n.value.func.id=='write'}
assert set(writes)=={'auth-required-scope.json','scenario-result.json'}
result={k.value:ast.literal_eval(v) for k,v in zip(writes['scenario-result.json'].keys,writes['scenario-result.json'].values) if isinstance(v,ast.Constant)}
assert result['result']=='AUTH_MEDIA_ONLY_RTP_PCM_CAPTURED_AUTH_PENDING'
assert result['first_three_directed_RTP_PCM_edges']==6 and result['normal_end_requires_cleanup_receipt'] is True
assert result['text_tokens_sent']==result['normal_UI_actions_submitted']==0
assert result['hold_65s_tested'] is result['reinvite_tested'] is False
assert "'sids'" in ast.unparse(writes['auth-required-scope.json']) and 'PENDING' in ast.unparse(writes['auth-required-scope.json'])
checks.append('Actual three-SID/full-JID/call/public scope exported for separate observer; media result keeps auth PENDING and no old hold/re-invite claim')
text=(HERE/'auth_media.py').read_text()
assert 'r.control_settings(' not in text and 'android_rec.record' not in text and 'consent_ui' not in text
for node in ast.walk(source):
 if isinstance(node,ast.Assign):
  assert not any(isinstance(t,ast.Subscript) and isinstance(t.value,ast.Attribute) and t.value.attr=='argv' for t in node.targets)
assert "payload.get('op')!='stop'" in text and 'AUTH_MEDIA_ONLY_CLEANUP_PASS_AUTH_PENDING' in text
checks.append('No caller disguise or old UI dispatch; native/runtime stop remains forbidden and verified-idle cleanup receipt remains separate')
print(json.dumps({'result':'AUTH_MEDIA_ONLY_SOURCE_CHECKS_PASS','groups':checks,'count':len(checks),
 'actual_runtime_ADB_SSH_build_or_UI_inputs':False,'auth_PASS_claimed':False},indent=2))

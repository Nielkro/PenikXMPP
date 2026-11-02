from pathlib import Path
import ast,json,hashlib,copy,types,time
p=Path('/media/linux/SSD128/xmppwin/local/monocles-dinox-interop-20261015/harness/resume-completion-plan-20261016T190157Z/ui-owner-resume/persistent-service-text');q=p/'persistent_service_text.py';tree=ast.parse(q.read_text());old=ast.parse((p.parent/'persistent-text/persistent_text.py').read_text());sha=lambda f:hashlib.sha256(f.read_bytes()).hexdigest()
for name in('idle_identity','fixture_authorization'):assert ast.dump(next(n for n in tree.body if isinstance(n,ast.FunctionDef)and n.name==name))==ast.dump(next(n for n in old.body if isinstance(n,ast.FunctionDef)and n.name==name))
OWN={r:r+'@test'for r in('nora','leon','felix')};ids={r:{'device_id':i+1,'legacy_fingerprint':'05'+'a'*64}for i,r in enumerate(OWN)};a={'identities':ids,'full_jids':{r:jid+'/own'for r,jid in OWN.items()}}
def idle(state,role,admission):assert state['online'] and state['account']==OWN[role] and state['idle'];return state
ns={'r':types.SimpleNamespace(OWN=OWN),'m':types.SimpleNamespace(ROLES=tuple(OWN)),'idle_identity':idle,'ROOM':'fixture@test','UUID':'known'};node=next(x for x in tree.body if isinstance(x,ast.FunctionDef)and x.name=='validate_scope');exec(compile(ast.Module(body=[node],type_ignores=[]),str(q),'exec'),ns)
states={r:{'online':True,'idle':True,'account':jid,'contacts':[]}for r,jid in OWN.items()}
for role,s in states.items():
 for peer,jid in OWN.items():
  if peer==role:continue
  item={'jid':jid};item['legacy_sessions'if role=='nora'else'devices']=[{'device_id':ids[peer]['device_id'],'fingerprint':ids[peer]['legacy_fingerprint'],'public_identity_hex':ids[peer]['legacy_fingerprint'],'trust':'TRUSTED'if role=='nora'else 1,'active':True,'legacy':True}];s['contacts'].append(item)
states['nora'].update(pending_invites=[],conversations=[{'jid':'fixture@test','uuid':'known','online':True,'private_nonanonymous':True,'muc_error':'NONE','encryption':5,'members':[{'real_jid':OWN[x]}for x in('leon','felix')]}]);ns['validate_scope'](states,a)
neg=[]
for label,edit in(('untrusted',lambda s:s['nora']['contacts'][0]['legacy_sessions'][0].update(trust='UNDECIDED')),('changedNativeKey',lambda s:s['felix']['contacts'][0]['devices'][0].update(public_identity_hex='05'+'b'*64)),('foreignMember',lambda s:s['nora']['conversations'][0]['members'].append({'real_jid':'foreign@test'})),('busy',lambda s:s['leon'].update(idle=False)),('NativeUNTRUSTED',lambda s:s['leon']['contacts'][0]['devices'][0].update(trust=2)),('NativeUNKNOWN',lambda s:s['leon']['contacts'][0]['devices'][0].update(trust=3)),('NativeBoolean',lambda s:s['leon']['contacts'][0]['devices'][0].update(trust=True))):
 s=copy.deepcopy(states);edit(s)
 try:ns['validate_scope'](s,a)
 except AssertionError:neg.append(label)
 else:raise AssertionError(label)
verified=copy.deepcopy(states);verified['leon']['contacts'][0]['devices'][0]['trust']=0;ns['validate_scope'](verified,a)
main=next(n for n in tree.body if isinstance(n,ast.FunctionDef)and n.name=='main');text=ast.unparse(main);assert 'owner_ui.py'not in text and 'Popen('not in text and 'owner_reference'not in text;assert "for sender in m.ROLES:"in text and "'send_text'"in text;assert 'hangup'not in text and 'start_call'not in text
receipt={'result':'PASS','focused_groups':['existingIdleAndConfigAuthorizationASTidentical','currentTrusted3ScopeAccepted','untrustedChangedKeyForeignMemberBusyReject','exact3SenderLoopSingleSendSite_NoUI_NoCall_NoRuntime'],'negative_cases':neg,'actual_ADB_SSH_UI_or_runtime_executed':False,'source_sha256':sha(q)};f=p/'offline-checks.json';f.write_text(json.dumps(receipt,indent=2)+'\n');print(json.dumps({'result':'PASS','sha256':sha(f)}))

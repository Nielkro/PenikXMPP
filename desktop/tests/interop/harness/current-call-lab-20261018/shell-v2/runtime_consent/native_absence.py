"""Additional exact-ID absence evidence; no transport, starts or Exited emulation."""
IDS={'leon':'2fd2a5dbf37029dccd0233a78a225316f9a70c4e9fef1c4dbfbc46241c610fac',
     'felix':'849fcd337a75f6230ea6c326cdabd55965de346286e1146a8f74f4c219f5ad17'}
SOURCE_SHA='0f268b566f98ba57d13a8be910d30359009f4ad2c641882cc41cb6c0495b15a2'
REMOTE_SHA='d961e1a246b44ad60194ba29d4a2c46b421ffdd35914988c3c7f017921430b76'
QUERY_FILTERS={'run_label':['--filter','label=im.dinox.interop.run=20261015-71115b'],
 'any_role_label':['--filter','label=im.dinox.interop.role'],
 'leon_role_label':['--filter','label=im.dinox.interop.role=leon'],
 'felix_role_label':['--filter','label=im.dinox.interop.role=felix'],
 'any_driver_label':['--filter','label=im.dinox.interop.driver'],
 'run_name':['--filter','name=dinox-interop'],'all_running':[]}

def validate_absence(value,role,container_id,observed_unix,created_unix,now):
 assert role in IDS and container_id==IDS[role]
 assert value['schema_version']==1 and value['run_id']=='20261015-71115b'
 assert value['result']=='ACTUAL_REMOTE_NATIVE_CONTAINERS_ABSENT_NO_OWNED_RUNNING'
 assert value['transport']=='ssh-docker-exec-docker_dind-docker'
 assert value['probe_source_sha256']==SOURCE_SHA and value['remote_probe_source_sha256']==REMOTE_SHA
 start,end=value['local_started_unix'],value['local_completed_unix']
 remote_start,remote_end=value['observed_unix'],value['completed_unix']
 assert all(type(x)in(int,float)for x in(start,end,remote_start,remote_end,observed_unix,created_unix,now))
 assert start<=end and 0<=end-start<=90 and 0<=now-end<=300
 assert start-5<=remote_start<=remote_end<=end+5 and remote_end-remote_start<=60
 assert observed_unix==end and end<=created_unix<=now
 assert value['containers_created_started_stopped_or_removed']is False
 assert value['profile_contents_read_or_modified']is False
 assert set(value['exact_peers'])==set(IDS)
 for peer,cid in IDS.items():
  row=value['exact_peers'][peer]
  assert row['historical_container_id']==cid and row['actual_absent']is True
  assert type(row['inspect_exit'])is int and row['inspect_exit']==1
  assert row['inspect_stderr'].lower()=='error: no such object: '+cid
 assert set(value['running_queries'])==set(QUERY_FILTERS)
 prefix=['docker','exec','-i','docker_dind','docker','ps','--no-trunc']
 for name,filters in QUERY_FILTERS.items():
  row=value['running_queries'][name]
  assert row['argv']==prefix+filters+['--format','{{json .}}']
  assert type(row['exit'])is int and row['exit']==0 and isinstance(row['rows'],list)
  if name!='all_running':assert row['rows']==[]
  else:
   assert all(isinstance(item,dict)and isinstance(item.get('Names'),str)for item in row['rows'])
   assert not any(word in item['Names'].lower()for item in row['rows']for word in('dinox','interop'))
 assert value['running_owned_name_matches']==[]

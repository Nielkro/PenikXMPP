# A18: one retained mixed three-party service-text case

This is a **source-only** sibling of the frozen 2026-10-16 Nora A chain. No
application, ADB, emulator, SSH, container, profile, message, key, trust, APK or
SDK operation was performed to generate or test it. Historical PASS cases are
not repeated. Root and an independent auditor must review the final source
hashes and actual fresh runtime inputs before any live action.

## Narrow change and source contract

The original A runtime checks host startup config `allowed_rooms == []` and
the original controller mistakenly applied that same rule to the running
bridge config. The existing idle fixture needs exactly one explicit room.

`derive.py` pins the original source bytes without importing the lab modules.
It creates a separate runtime/controller/recorder chain, a small extracted
service-support module, the existing service scenario with new bindings, and a
monitor sibling. `derivation.diff` contains the differences from the actual
frozen A sources and service scenario. `source-manifest.json` records the
source closure; `freeze.json` pins every operational sibling source and the
unchanged original A freeze/product/APK chain. The original startup validator
is AST-identical and still rejects a nonempty room list.

The new runtime owns `runtime-state/` **inside this directory**, including its
own `allow-nora.json` marker, live session, logs, evidence and once claims.
It uses the retained original Nora AVD, SDK, APKs and host private startup
config. Old A/B/C source files and their state/markers are not modified.
Only this runtime, controller, recorder and scenario are approved callers.
The original PID/starttick/cgroup/ADB-executable/APK/freeze/resource/lease
checks remain active. No caller disguise or old-control-settings bypass is
introduced.

`room_scope.py` grants only the exact existing fixture and original account
set. Running control requires exactly both owned peers. The only command
operations are status, stats, normal bridge stop, legacy room preparation and
legacy service send. Calls, room creation/join, trust changes and direct-target
text are unavailable through the new Nora controller. Native room preparation
still uses its separately admitted original native controller.

## Actual fresh room admission

After Nora READY and three fresh idle/current-identity observations, Root may
use the already reviewed owner mechanism to change **only** the app-private
`allowed_rooms: []` to the one exact fixture, under its existing owned SDK
lock/child deadlines, then actually read back equal bytes. The host startup
config remains `[]`. No helper in this derivation performs that configuration
write, generates consent or fabricates a readback.

The controller receives a private artifact reference through the recorder's
`--room-admission ABSOLUTE_PATH --room-admission-sha256 ACTUAL_SHA` options.
The artifact is a regular owned file with mode 0600, in this derivation or the
original runtime root. It contains these fields, populated from actual data:

| Field | Required value/source |
| --- | --- |
| `schema_version` | `1` |
| `operation` | `nora-persistent-room-service-controller` |
| `runtime_profile` | `A18` |
| `run_id`, `role`, `account`, `accounts` | Current fixed test run, Nora and the original three owned accounts |
| `room`, `conversation_uuid` | `room_scope.ROOM`, `room_scope.CONVERSATION_UUID` |
| `runtime_freeze_sha256`, `runtime_inputs_sha256`, `apk_sha256` | Actual A18 freeze and current runtime/session pins |
| `batch_id`, `session_binding`, `process_cgroups`, `native_readonly_bindings` | Exact output of the new runtime's `room_control_context()` under an approved caller |
| `created_unix`, `expires_unix` | Real current timestamp and at most 240 seconds after creation; expiry also at most batch deadline minus 120 seconds |
| `fixture_room_authorization` | Actual readback receipt `{path, sha256}`, in the original runtime root |

The readback receipt keeps the existing schema: real `run_id`, Nora `account`,
`allowed_rooms: [ROOM]`, exact `session_binding`,
`validated_write_readback_equal: true`, and actual `observed_unix`.
The readback must precede the grant and be at most 120 seconds old at grant
creation. At first scenario entry, both grant and readback must additionally
still be at most 120 seconds old. Root should produce them immediately before
the case.

During this single case the unchanged **explicit maximum 240-second grant**
remains valid only until its actual expiry, bound to the same source, batch,
process identities, cgroups, APKs, SDK-input manifest and native bindings.
Each controller I/O reopens and checks the pinned admission/receipt files and
current runtime owners. This avoids accidentally turning the existing
120-second *entry freshness* into a 120-second total execution allowance.
There is no refresh of timestamps or reuse of an old receipt as a new one.

The scenario additionally requires an actual private root admission with the
original service-case fields (including current three public identities,
full JIDs, actual room authorization and conversation UUID), but
`runtime_profile: A18`, this new `scenario.py` hash and this new freeze. Add
`room_control_admission: {path, sha256}` pointing to the artifact above. Its
original entry age limit remains 120 seconds, expiry at most creation plus
240 seconds. `fixture_room_authorization` must equal the controller grant's
actual receipt reference.

Before the first product mutation, the scenario durably claims this batch with
O_CREAT|O_EXCL and fsync under `runtime-state/operation-claims/`. A second
scenario execution in that batch fails even with a different admission file.
The claim is never automatically deleted. After an uncertain command, inspect
the recorded UUID/result and retain the partial result; never restart the
scenario or resend a token to obtain evidence.

The case deadline is the minimum of both explicit admission expiries and batch
deadline minus 120 seconds. The case refuses entry with less than 90 seconds
remaining and refuses a new send with less than 40 seconds remaining. No
further operation begins after the case deadline. Existing individual
controller/subprocess deadlines still apply to an already submitted operation;
expiry cannot undo a command already accepted by the app. Completion within
the grant is **not runtime-proven**. A slow or uncertain attempt remains
PARTIAL, with the one-shot claim retained. Do not extend the grant to make it
pass or automatically repeat the case.

To revoke room access, invalidate/remove the actual pinned room-admission
artifact and restore app-private `allowed_rooms: []` through the reviewed owner
path with actual readback. Changing the app config alone is insufficient to
revoke an already running CLI's cached config. The next I/O detects the revoked
artifact. A submitted command cannot be recalled. Normal exact-owner bridge
`stop` remains available even after the short room grant expires; it grants no
room action. No automatic trust, identity or profile cleanup is performed.

## Bounded resumption order and commands

1. Root reviews source pins, offline checks and independent audit. Source-only
   checks are safe and do not import any historical runtime:

   ```sh
   python3 -B local/monocles-dinox-interop-20261018/derive.py
   python3 -B local/monocles-dinox-interop-20261018/test_offline.py
   ```

2. Root repairs the isolated test network if needed and freshly checks the
   exact stopped native session-public peers, RO artifact/profile mounts,
   image, entry and resource configuration. An absent network is an environment
   blocker, not an app failure. Recreating a container requires a separate
   native controller/recorder/admission sibling with its actual new IDs. That
   sibling must remain under the original `.../harness/` because A18 preserves
   that native-directory scope. No historical container ID is silently reused.
   The new runtime marker's `native_bindings` must contain the fresh actual
   controller/recorder/admission hashes and <=300-second exact-container
   observations.

3. Fresh preflight: no other owned Android guests, all required ports/locks
   free, actual KVM access, current disk and RAM reserves, SDK/APK/source pins,
   retained Nora identity, and exact native peer scope. Preserve common slice
   `dinoxinterop20261015.slice`: 2 CPUs, 7 GiB RAM, swap 0, <=512 tasks,
   Nice19, >=3 GiB host RAM and >=3 GiB disk reserve. No new AVD or SDK download.

4. Create the **new** private `runtime-state/allow-nora.json` with the existing
   A gate schema, new A18 freeze, actual current native bindings, new batch ID,
   real created/expiry timestamps (marker entry <=300 seconds; expiry <=600
   seconds), guest memory 2048, `lowram_emulation_variant: true`,
   `single_nora_memory_probe: true`, `android_tests_before_bridge: false`,
   original input/APK pins and a batch deadline <=creation+2700 seconds. The
   marker is operational authorization; this source directory contains none.
   Do not copy an expired historical marker and change its timestamp.

   The minimal payload construction below is for Root **after** source/auditor
   acceptance and an actual fresh native-bindings artifact. Run it in the common
   bounded slice (Nice19, at most 1 CPU/512 MiB, swap 0), not as source inspection.
   It creates only the new A18 marker and runs the existing gate; it does not boot
   a guest or call ADB/SSH. Replace both positional values with the actual fresh
   artifact and digest. That artifact uses the preserved binding shape:
   `directory`, `control_sha256`, `recorder_sha256`, `admission_sha256`, actual
   `owner_admission`, and fresh `inspects` for Leon/Felix. The read-only container
   inspect files must carry their real observation timestamps and actual hashes.

   ```sh
   python3 -B - ACTUAL_FRESH_NATIVE_BINDINGS_JSON ACTUAL_SHA256 <<'PY'
   import hashlib, json, os, sys, time, uuid
   from pathlib import Path
   sibling = Path('/media/linux/SSD128/xmppwin/local/monocles-dinox-interop-20261018')
   sys.path.insert(0, str(sibling))
   import runtime as r
   ref = Path(sys.argv[1]); raw = ref.read_bytes()
   assert ref.is_file() and not ref.is_symlink() and ref.stat().st_mode & 0o077 == 0
   assert hashlib.sha256(raw).hexdigest() == sys.argv[2]
   bindings = json.loads(raw); now = time.time()
   r._native_readonly_bindings(bindings, now)
   assert os.getpriority(os.PRIO_PROCESS, 0) == 19
   r.v1.resources()
   marker = {
       'schema_version': 2, 'run_id': r.RUN, 'role': 'nora', 'mode': 'bridge',
       'freeze_sha256': r.frozen_files(), 'installed_apk_sha256': r.APKS,
       'guest_memory_mib': 2048, 'lowram_emulation_variant': True,
       'android_tests_before_bridge': False, 'single_nora_memory_probe': True,
       'batch_id': uuid.uuid4().hex, 'created_unix': now, 'expires_unix': now + 300,
       'batch_deadline_unix': now + 2700,
       'inputs_sha256': r.sha(r.ROOT / 'runtime-inputs.json'),
       'native_bindings': bindings,
   }
   r.STATE.mkdir(mode=0o700, parents=True, exist_ok=True)
   target = r.STATE / 'allow-nora.json'
   assert not target.exists(), 'Never overwrite a previous A18 marker implicitly'
   r.v1.write(target, marker)
   proof = r.gate('nora', 2048, True, False)
   print(json.dumps({'gate': 'PASS_NO_GUEST_STARTED', 'marker_path': str(target),
       'marker_sha256': r.sha(target), 'batch_id': marker['batch_id'],
       'batch_deadline_unix': marker['batch_deadline_unix'],
       'freeze_sha256': proof['freeze_sha256']}))
   PY
   ```

   Current resumption update from Root: the test network was repaired and the
   original exact native container IDs could be restarted with their original
   profiles/identities. Therefore no new native source or admission is required
   if fresh checks still prove the same IDs and RO artifacts; use the original
   session-public controller/recorder and admission `773b9aaf…163ea38e` with
   **new actual inspect receipts**, not the old receipt timestamps.

5. After Root's real admission, the bounded Nora command is:

   ```text
   systemd-run --user --slice=dinoxinterop20261015.slice --unit=ACTUAL_NEW_UNIQUE_NORA_UNIT \
     --property=Type=exec --property=Restart=no --property=KillMode=mixed \
     --property=Nice=19 --property=RuntimeMaxSec=2700 --property=TimeoutStopSec=240 \
     /usr/bin/python3 -B /media/linux/SSD128/xmppwin/local/monocles-dinox-interop-20261018/runtime.py \
     nora --guest-memory-mib 2048 --lowram
   ```

   Redirect the owned service console to a new private case directory as in
   the preserved launch receipt. Launch the new `monitor.py` in its separate
   unique Type=exec service, same slice/Nice19/Restart=no/KillMode=mixed,
   RuntimeMaxSec=3000 and TimeoutStopSec=60. This is the existing one-Nora
   strategy. One owner controls all ADB/runtime actions. No audio/UI/PQ cases
   are included in this boot.

6. Once genuinely READY, get fresh actual states, scoped readback and the two
   admissions above. Then invoke exactly once in that same bounded slice at
   Nice19:

   ```text
   /usr/bin/python3 -B /media/linux/SSD128/xmppwin/local/monocles-dinox-interop-20261018/scenario.py \
     --root-admission ACTUAL_PRIVATE_SCENARIO_ADMISSION
   ```

   The existing native preparation/room membership, all current devices and
   already trusted fingerprints, private/nonanonymous fixture, three idle
   clients and exact native admissions are checked before any token. PASS
   requires exactly three sender tokens and six actual decrypted receipts.
   There is no normal UI/Done or exact sender-device-authentication claim.

7. Revoke the room grant and actually restore `[]`, then submit the existing
   normal bridge `stop` via this exact recorder with a new command UUID and
   verify its actual result. Sync/regular emulator termination, monitor end,
   exact native peer stop and final owned process/port/lock/input/profile checks
   follow the preserved cleanup recipe. Never call the unsafe native legacy
   `stop` command or reset keys. Preserve any unknown submission as PARTIAL.

Do not execute `--help` on operational modules merely to inspect them: their
imports validate the private historical closure. The commands above are a
reviewable resumption recipe, not execution performed by this change.

## Disk and remaining limits

The seven generated operational source files total about 92 KiB. Including
the generator, synthetic tests, manifests, diff and documentation, this source
sibling stays well below 0.3 MiB before future logs. It copies no APK/SDK/AVD
or userdata. Future monitor logs retain the existing per-file 64-MiB cap;
actual runtime evidence and AVD growth need fresh disk monitoring. No package,
new build or download is needed for this controller fix.

Offline checks cover both accepted scoped operations and rejection of wrong
room/account/run/transport/peer, changed session/cgroup/source/APK/native
bindings, absent/stale/changed/public/symlink artifacts, missing/old readback,
expired or stale-entry admissions, forbidden calls/trust operations, hidden
targets, startup nonempty rooms, wrong caller and repeated batch claims.
They exercise the extracted real controller to prove rejection precedes
submission. They do not prove real Android latency, service execution,
interoperability, decrypted receipt, resources, physical media or UI behavior.

Three-Monocles PQ audio, three current own PQ128/QR mappings with normal JOIN,
three-party video and the new landscape/tablet live checks remain open.

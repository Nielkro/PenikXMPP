# DinoX / monocles interop lab source snapshot

## Monocles-only source relocation, 2026-10-18

The 184 Android-only/Monocles PQ fixture files (2,565,762 bytes) now live in the
[Monocles fork retained fixture](https://git.dinox.im/dinoxim/monocles-chat/src/commit/a4980b9f43bc6288cc0cfc0abcf188623f1949ea/tools/interop/retained_fixture/README.md). Its relocation manifest
records every original path and byte-identical SHA-256. They were committed and
pushed there before removal here. Mixed Monocles-DinoX cases, native DinoX drivers,
observers and shared hybrid controller baselines remain in this repository.

The historical inventory and frozen source references below describe their
original locations. Removed Android/PQ entries refer to that retained fixture,
not current files in this checkout. Absolute private lab paths and frozen pins
were deliberately not rewritten. This is not a standalone executable closure;
shared historical dependencies can now span both repositories.


This directory preserves selected host, native-driver and Android UI helper source
from the October 2026 interoperability lab. The original October 16 collection
retains its fixed run/account identifiers, absolute paths and source/artifact pins.
Four Python files only normalize redundant blank lines at EOF; its manifest
records their original hashes and unchanged-AST normalization. Its other copied
source bytes are unchanged. Later siblings have their own manifests and explicit
normalizations described below. This is a reviewable lab snapshot, not a portable
live test framework or a clone-and-run interoperability suite.
It is not registered as a normal DinoX build/test target.

`source-snapshot.json` maps each copied file to its original path relative to the
DinoX checkout, SHA-256 and byte size. The three `owner-ui-adapter` sources came
from a sibling runtime directory; their relative origins therefore start with
`../monocles-interop-runtime-20261015/`. The manifest contains source provenance
only, not test results. Files retained below `gpu_probe/baseline`,
`runtime_host_gpu`, `auth-observer-driver` and `future-safe-driver` are actual
source dependencies of the selected derivations/checks. Older before/staged/failed
variants, generated code, binaries, logs, screenshots and run data are excluded.

## Entry points and original locations

`harness/` mirrors the selected source paths below the original
`local/monocles-dinox-interop-20261015/harness/` directory:

| Sources | Purpose |
| --- | --- |
| `local_android_runtime.py`, `local_android_gate.py`, `dinoxinterop20261015.slice` | Original owned Android runtime, admission checks and resource limits |
| `control_runner.py`, `server_control.py`, `server_launch.py`, `server_entry.sh`, `scenario_recorder.py` | Scoped native control/recording and original launch helpers |
| `pair_v2/` | Two-Android control, recording, media/text/UI cases and source checks |
| `triple_v3/runtime_consent/`, `gpu_probe/` | Three-Android launch/process ownership, stagger/capacity gates and their retained source baseline |
| `triple_v3/root_role_gate.py`, `root_consent_admit.py` | Owner-side helpers requiring actual fresh preflight/UI scope and independent review inputs |
| `triple_v3/product_devicefix_consent/`, `normal_consent_ui/`, `public_ui_observer/` | Group text/media assertions, normal recipient confirmation and public own-key UI observation |
| `devicefix_runtime_derivation/`, `devicefix_nora_runtime/`, `devicefix_nora_monitor/` | Reviewed additive source derivation, its two Python source templates and mixed-case Android controller |
| `legacy3_mixed_consent/`, `legacy3_followup/`, `native_muji_auth/` | Mixed Android/native consent, media watchdogs and native IQ/presence observers/control |
| `native_core52_late/` | Exact-ID native controller/recorder sibling pinned to the Core52 and late-attach driver artifacts, with its unchanged control base and source checks |
| `legacy3_followup/auth-observer-session-public-20261016/`, `native_session_public/` | Post-Draft single-fingerprint session public-key observer and its exact-ID native control/recorder sibling, with source checks and required control base |
| `resume-completion-plan-20261016T190157Z/ui-owner-resume/` | Separate operational owner UI and mixed text/media scenario, plus their source-only checkers; earlier UI history is excluded |
| `resume-completion-plan-20261016T190157Z/ui-owner-resume/{auth-media-only,persistent-text,b-owner-public-join}/` | Separate bounded media/auth observation, persistent mixed text, and public-PQ/normal-JOIN source siblings with their source-only checkers |
| `resume-completion-plan-20261016T190157Z/ui-owner-resume/b-pq-audio/` | B requested-PQ-mode audio wrapper and source-only checker, with all three current public-receipt gates |
| `resume-completion-plan-20261016T190157Z/ui-owner-resume/a-banner-batched-capture/` | Separate A banner parser, fixed binary batched capture/Wait helper and persistent-text runner, with source-only checker |
| `resume-completion-plan-20261016T190157Z/ui-owner-resume/a-parallel-capture/` | Separate A parallel read-capture/Wait and persistent-text sources with unchanged guards and source-only checker |
| `resume-completion-plan-20261016T190157Z/ui-owner-resume/{b-parallel-public-join,b-parallel-pq-audio}/` | Archived B parallel-capture source siblings and source-only checkers; no successful runtime/timing claim |
| `resume-completion-plan-20261016T190157Z/ui-owner-resume/persistent-service-text/` | Separate existing-room service text runner and source-only checker; no normal UI or Done claim |
| `a18-mixed-service-text-20261018/` | Separate A18 controller/room-authorization derivation, scoped configuration owner and source-only checks, with its own source snapshot manifest |
| `b18-pq-audio-20261018/` | Separate B18 capture diagnostics, Nora-only capture barrier, scoped configuration owner and existing PQ/normal-JOIN media assertions |
| `capture-timeout-diagnostics-20261018/` | Narrow capture-timeout source correction and a portable offline regression against the actual extracted controller method |
| `native-current-driver-20261018/` | Source-only driver relink recipe using current wire/IQ inputs and the existing qualified media runtime |
| `current-call-lab-20261018/` | Later lifecycle and Android capture fixes, completed native relink/runtime helpers, mixed-video case sources and bounded PQ UI dispatch; source provenance only |
| `remesh-call-lab-20261018/` | Offline APK/JVM recipes, phase-watchdog qualification, hardware-rendering provenance, PQ UI ownership and bounded stop-response cleanup; source provenance only |
| `pq_identity_decode.py` | Offline decoding of public QR identity observations |
| `owner-ui-adapter/` outside `harness/` | Operational `owner_ui.py`, `pq_text.py` and `pq_audio.py` from `triple-v3/fresh-startup-consent-preflight-20261016T180350Z/owner-ui-adapter/` |

The Android instrumentation bridge is maintained separately in the monocles fork
at `src/androidTest/java/eu/siacs/conversations/interop/MonoclesInteropTest.java`.
It is not duplicated here. It requires an explicitly separate test application
package, an emulator, the matching opt-in run id and private test configuration.
Its source and configuration example are documented in that fork's
`docs/interop-test-bridge.md`.

## Local prerequisites and execution boundary

The operational closure intentionally remains incomplete without the original
private lab inputs: isolated account/profile credentials, runtime/configuration
files, matching build/source receipts, original source READMEs/manifests and
freeze files, actual module/APK identities, capacity and native-off observations,
and fresh owner/Root admission records. None of those files is included here.
Several modules validate these inputs while importing, so even `--help` is not a
safe offline inspection command. Do not import or execute these snapshots merely
to inspect them. Python assertion gates require execution without `-O`.

The original guarded entry points include `pair_v2/runtime.py`,
`triple_v3/runtime_consent/launch.py ROLE`, the respective `control.py --stdin`
and `recorder.py --stdin` interfaces, and
`triple_v3/product_devicefix_consent/scenarios.py`. The operational
`owner-ui-adapter/*.py` files require `--admission` pointing to a fresh private
record. Read their argument definitions as source; a runtime owner must restore
and review the exact private environment and admit each operation before use.
Fixed historical pins are not portable defaults. Changing paths/pins requires a
separate reviewed derivation rather than weakening validation or fabricating
matching receipts. `csi_fix_background_only_boot.py` is retained because current
pair helpers extract its reviewed UI functions from the AST; running that whole
script is not an equivalent offline operation.

Some frozen UI modules are retained for their validation functions, not as the
preferred navigation entry point. Their original URI/focus assumptions did not
work in the observed Android environment. Use a separately reviewed current
owner UI derivation; preserving an older source file is not a successful runtime
test of it.

The separate `ui-owner-resume` selection preserves its own source pins in the
snapshot manifest. Its input/window parser, scoped state reuse and mixed-scenario
checks are source, not evidence of successful app input, decrypted delivery, call
authentication or media. The checkers also refer to retained local WindowManager,
InputDispatcher, ANR, XML and package-UID observations that are deliberately not
exported. AST syntax inspection does not execute those checkers or establish that
their private fixture closure is available. The runtime owner must review and pin
any later narrow UI/parser derivation before admitting an operation; the snapshot
does not authorize automatic reuse of an older source or admission.

The newer siblings preserve distinct operation scopes. `auth-media-only` stops
after initial three-way audio observations and normal exact-call cleanup; it sends
no text and does not exercise the longer hold, leave/reinvite or UI. `persistent-text`
uses a separately admitted existing private room, exactly one normal Nora UI send
and two native sends; its private room-authorization readback remains an external
prerequisite. `b-owner-public-join` observes own public PQ128/classical QR mappings
and submits only the actual normal JOIN/REJOIN choice. It requires three matching
current public-identity receipts before PQ JOIN/REJOIN, and a submitted choice
does not prove completed joining, media or call authentication. Its narrow
NotificationShade/window handling does not authorize a general notification-input
route. Private configuration, admissions, identity results and all raw fixtures
remain excluded from this snapshot.
The separate `b-pq-audio` wrapper requires all three actual own-PQ128/QR/session
receipts before the single Nora call start; requested mode and public-key
observations alone make no call-authentication claim.
The separate `a-banner-batched-capture` sources retain the narrow known-banner
parser and fixed binary screenshot/window/input capture for A Wait/capture or
persistent consent; their source checks do not prove a Wait response or text
delivery, and the original input freshness and ownership gates remain required.
The later `a-parallel-capture` sibling reads UI XML and PNG in parallel, then
window/input state; the observations are not atomic. It retains the existing
freshness, child-timeout, lock and ownership guards. The independent guest
deadline and cleanup were checked with local fake shells only, not on Android;
SIGKILL cannot run cleanup traps, so no unconditional guest-cleanup guarantee is
claimed. The actual A parallel attempt (`048e`) returned an incomplete WM/Input
tail and submitted zero inputs; its exact cause is unknown. The corresponding
B parallel siblings have only SOURCE_OK review and are archived without a B
runtime or timing PASS.
The separate `persistent-service-text` path submits one Nora send through the
real frozen bridge service and one send from each native client; six actual
decryptions are required. It does not establish normal UI-send or Done coverage.

The persistent service-text sibling has a known harness incompatibility with the
unchanged A controller: that controller requires `allowed_rooms == []`, so adding
the scoped persistent room makes even its read-only commands fail before any
send. This snapshot does not claim a working mixed three-party text case. A later
run needs a separately reviewed controller/configuration derivation with consistent
room authorization; editing frozen inputs or bypassing validation is not a repair.

The later `harness/a18-mixed-service-text-20261018/` preserves that separate A18
derivation and its scoped configuration-owner source. Its own `source-snapshot.json`
records the origins, SHA-256 hashes and byte sizes of 15 source/document copies;
13 retain identical bytes. `service_support.py` removes one redundant EOF blank
line with unchanged Python AST. `derivation.diff` is a valid zero-context unified
diff regenerated from the same pinned before/after sources. Both derived files
record separate original and snapshot hashes and exact normalization details.
The earlier snapshot files and manifest retain their original scope.
The copied README, REVIEW, `freeze.json` and `source-manifest.json` retain their
source-preparation context and original source hashes, including the original
`service_support.py` hash. These source pins provide provenance and no runtime
permission or interoperability result. The snapshot cannot run directly with
these preserved pins, fixed lab paths and missing private dependencies. Private
inputs, admissions, observations and actual case/cleanup results remain outside
Git; do not import or run the snapshot merely to inspect it.

The B18 snapshot preserves its 28 source/document copies byte-for-byte, with its
own `source-snapshot.json`. Its original manifests describe the source-preparation
stage, not an interoperability result. The separate timeout correction preserves
available timeout stdout for bounded, masked diagnostics after the exact child
has stopped. It retains the original deadlines and never retries or accepts a
timeout as a successful observation. Only `OwnerUI.adb()` changes. Its pure
`check_timeout_offline.py` extracts that actual method with AST, uses fake child
processes and verifies the old missing-diagnostic failure; its sibling baseline
path is adapted to the tracked B18 sources. This checker is runnable without
private runtime inputs. Do not import the preserved live OwnerUI module.

The native-current-driver snapshot is an unexecuted relink recipe and input
manifest, without its large binary inputs. It retains the existing Core/OMEMO
and observer bytes while selecting the current wire engine, matching IQ
interfaces and complete qualified runtime. Existing single-fingerprint observer
limits still apply, including multiple identical audio/video fingerprint nodes.
It supplies no media or authentication PASS. Its diff, and the timeout-owner
diff, are regenerated with zero context from the same pinned before/after
sources. Per-file original hashes and normalization details are recorded in
their individual snapshot manifests. Live admissions, logs, profiles, captures,
device observations and actual run/cleanup results remain excluded from Git.

The original `harness/dinox_interop.vala` has an unsafe legacy `stop` operation
that can remove the test account's identity. Later `future-safe-driver` and
`auth-observer-late-attach-20261016` variants use the connection manager's safe
disconnect path. The current `legacy3_followup/native_control.py` still blocks
`stop` defensively. Do not bypass that controller or submit `stop` directly to
the native inbox. The lab uses exact owned-container SIGTERM and verifies the
retained profile, keys and process termination. This distinction concerns the
native snapshots, not the separately scoped Android instrumentation `stop`.

Safe syntax inspection from the DinoX checkout, without imports or runtime:

```sh
python3 -B - <<'PY'
import ast
from pathlib import Path
for path in Path('tests/interop').rglob('*'):
    if path.is_file() and (path.suffix == '.py' or path.name.endswith('.py.in')):
        ast.parse(path.read_text(), filename=str(path))
PY
bash -n tests/interop/harness/server_entry.sh
```

The Vala sources require the reviewed DinoX/OMEMO/XMPP/Google runtime and the
original limited driver build command. This snapshot does not claim a fresh Vala
build. `auth-observer-late-attach-20261016` is the separate deferred-attachment
source fix; its presence does not establish that a deployed driver contains it.
The separate session-public observer additionally reads only the public remote
identity of the post-Draft version-3 session and compares it to the selected-account
metadata. A present native MemoryMap key must also match; an absent entry alone
cannot bind. Binding is limited to exactly one rewritten fingerprint per IQ.
The public API does not expose an independent backing-store ownership check;
diagnostics state that limitation rather than asserting it. These sources and
their source-only checks do not constitute a runtime authentication result.

## Meaning of observations

These helpers can mutate isolated test state through real app/service APIs,
including creating conversations, preparing crypto, changing an explicitly known
fingerprint's trust, sending messages and controlling exact current calls. A test
source commit grants no runtime permission. Normal UI consent, no-trust-change
admissions, resource/process ownership, no automatic retry and exact call/invite
checks remain in force. No automatic start, trust reset or fake PASS is added by
this export. Parser/source tests contain explicitly synthetic rejection/redaction
fixtures; those are not actual account keys or interoperability evidence.

An accepted command, source-contract check, connected transport, selected mode or
trust-level field does not prove decrypted delivery, PQ/hybrid usage or call
authentication. Those require actual matching account/full-JID/SID/room/device
and public-key observations, successful authentication and independently matching
live media evidence. Native fingerprint-rewrite observers retain their narrower
IQ/auth-container claim and do not assert engine/DTLS/media binding. The lab uses
synthetic media sources and does not measure physical camera/microphone quality.

Keep generated configurations, credentials, admissions, receipts, runtime freeze state,
runtime output, logs, screenshots and binaries outside this directory and Git.

# Current call-lab sources, October 18, 2026

The Android lifecycle, shell-v2 capture and PQ UI-dispatch sources were relocated byte-identically to the
[Monocles retained fixture](https://git.dinox.im/dinoxim/monocles-chat/src/commit/a4980b9f43bc6288cc0cfc0abcf188623f1949ea/tools/interop/retained_fixture/README.md).
The inventory below is historical; native/mixed sources remain here. Frozen
paths and pins are unchanged, so this snapshot is not standalone.

This archive preserves selected private interoperability helper source under the
user's explicit instruction to version the scripts while excluding logs and
private runtime data. It is source provenance, not an interoperability result or
a portable executable test suite. No build/test target registers these helpers.

The source snapshot records each original path, byte size and SHA-256. Python
files and the Python `owner_helpers.source` fragment with redundant empty lines
at EOF are normalized to one final newline;
their AST and original digest are retained. Other source bytes are unchanged.
Historical diff copies and actual result reports are omitted. The original
source manifests may refer to omitted private inputs or preparation reports.
Their source-only status describes their original preparation stage and does
not grant permission to start an emulator or reuse an old operational admission.

| Directory | Scope |
| --- | --- |
| `lifecycle/` | Pure PID/UID/starttick/parent/process-group terminal-process regressions and the bounded real-child stress recipe |
| `shell-v2/` | Final separate-channel Android capture, common `shell_v2` capability checks, and retained three-guest runtime/product helpers |
| `driver-relink/` | Current Vala wire/IQ driver relink using an existing server image and qualified native runtime; no binary inputs |
| `native-runtime/` | Read-only runtime staging, retained profile mounts, actual-ID native control, idle readiness and live worker/module/profile-FD observation |
| `native-container-scope/` | Narrow creation precheck using `docker container inspect`; generic inspect can match a same-name profile volume |
| `mixed-video-case/` | One direct video call, the real DinoX add-participant operation, and six directed AV counter checks |
| `mixed-video-owner/` | Original four-minute owner derivation, retained only as the fixed source baseline of the next sibling |
| `mixed-video-owner-900/` | Separate maximum 15-minute case, additionally bounded by Android and both native runtime deadlines; fresh batch and durable once claim required |
| `pq-ui-dispatch/` | Exact role-specific fixture-title checking and five-second capture/input freshness measured from actual dispatch under the inventory lock |

The direct one-to-one and private-MUC/MUJI cases have distinct scopes. The mixed
video case requests legacy OMEMO1. DinoX's PQ path remains disabled; proprietary
Monocles PQ calls are tested only between Android instances. Media delivery,
normal UI actions and exact-device/fingerprint authentication require separate
runtime evidence. In particular, the unchanged native fingerprint observer does
not prove multiple audio/video fingerprint nodes by counting them as one.

The 15-minute sibling does not renew an expired case or remove its claim. The
original four-minute run and every uncertain submission retain their original
result. A new actual batch, fresh owner/session/native bindings and exact cleanup
are required before another case. The pure media guards, product operations,
UUID handling and cleanup semantics are unchanged.

The PQ UI helper preserves the five-second bound through actual input dispatch.
It permits at most three new read-only observations in a bounded 20-second phase
only when no input dispatch was attempted. Context, identity, capture-channel,
timeout and uncertain mutation errors are not general retry conditions. Its
public QR observation binds the classical OMEMO2 fingerprint, hybrid fingerprint
and current device; a legacy fingerprint is not a replacement for that evidence.

These snapshots retain fixed laboratory paths and pins. Several modules validate
private inputs on import. Read them as source; do not import them or invoke
`--help` merely for inspection. The original private lab closure, actual source
review, fresh capacity/ownership checks and new operational admissions are needed
to run them. Python assertions must not be disabled. The scanner rejects live,
reused or unverifiable process identities; no global process ownership policy is
overridden. Native shutdown uses exact owned-container SIGTERM and preserves
profiles and keys, rather than the historical unsafe native stop command.

Credentials, operational grants/admissions, actual process/device observations,
offline result reports, logs, screenshots, profiles, generated code, binaries and
transfer archives are deliberately excluded. Public fixture JIDs and public
artifact/device fingerprints appearing as source constants are not credentials.

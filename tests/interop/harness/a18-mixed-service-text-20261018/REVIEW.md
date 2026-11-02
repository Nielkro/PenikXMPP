# Source review before live execution

Status: source-only developer implementation; independent audit pending separately.
No ADB, SSH, emulator, container, installation, message, trust or key operation
was performed by this implementation task. Only this new directory was written.

- Root cause: the frozen A controller reused the startup `allowed_rooms == []`
  policy for the running bridge, although the admitted idle fixture needs one
  explicit room. No product or cryptographic change is required.
- Fix: distinct A18 runtime/controller/recorder with its own freeze/state/marker,
  unchanged startup validator and process/resource/caller checks; scoped control
  accepts only the fixed fixture with actual pinned account/session/source/native
  bindings and room readback. The operational source diff is `derivation.diff`.
- Freshness: first case entry still requires grant and readback <=120 seconds
  old. A granted capability then lasts only its explicit expiry <=240 seconds
  after creation and <=batch deadline minus 120 seconds. Every I/O rechecks
  files, pins, current owners and expiry. A stale first entry is rejected.
- No replay: a durable exclusive once-per-batch scenario claim precedes the
  first product mutation. A partial or unknown send never triggers a retry.
- Validation: `python3 -B test_offline.py` passed 12 positive and 49 negative
  synthetic checks, including real controller-function extraction, startup AST
  equivalence, wrong room/account/session/native/APK/source, stale/missing
  artifacts, forbidden operations, caller rejection and repeated batch claim.
- Current operational freeze SHA-256:
  `73c64b7aba80ff49c83e3425cb20b37fcc33d562aa96b7751e4973ea4ff91c04`.
  Source manifest SHA-256:
  `20b99ed7d7df75de3969eb7971a527a920cb56080b27e9e38321456cb813c69b`.
- Disk: about 165 KiB total source/doc/check data, including this review;
  generated operational source is 93,509 bytes. No SDK/APK/AVD/profile copy.
  Runtime logs and AVD growth require fresh reserve monitoring.
- Live prerequisites remain actual current native peers/inspects, resource and
  no-other-guest preflight, new A18 marker, real Nora READY, scoped readback,
  current three identities and the two real admissions. The README gives the
  exact marker payload and bounded start commands.
- Limits: completion within the grant is not measured. Already accepted
  commands cannot be undone by expiry. A late/uncertain case stays PARTIAL and
  retains its once claim. Normal UI/Done, PQ audio/QR/JOIN and new layout live
  checks remain unproved. Existing PASS cases are not repeated.

Revocation requires invalidating the actual pinned room-admission artifact and
restoring app-private `allowed_rooms: []` with real readback. Normal exact-owner
bridge stop remains available for cleanup after short room-grant expiry.

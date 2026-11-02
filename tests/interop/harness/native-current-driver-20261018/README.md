# Current native driver: source-only derivation

Status: **SOURCE_ONLY — no compiler, server, account, Android or media action has
run from this directory.** This is a narrowly derived build recipe, not a new
runtime result. It does not change a call scenario or the product.

The derivation starts from the October 16 `server_compile.py` and `server_run.py`
listed in `input-manifest.json`. It keeps the same cached Vala-to-C-to-link flow.
All 26 Google source/interface inputs now come from the pinned current checkout.
Only `engine_jingle_wire_session.vala` differs from the old original product
source set. The old private `fixed-engine_jingle_wire_session.vala` is not used.
The current IQ DSO is paired with its current generated VAPI and header, whose
include directory precedes the old cached headers.

The byte-identical Core52 DSO, existing OMEMO plugin and direct `libomemo-c`
remain prebuilt. All four driver/SessionPublic observer units are unchanged.
The current qualified wrapper, matching worker, vision worker, models, private
codec libraries, licenses, provenance and source archives are pinned as one
complete existing runtime tree. No SDK, native library, JNI or APK build and no
download is part of this job. The manifest describes about 150 MB of existing
input bytes; those files have not been copied or archived here.

## Before a later server job

Root must first finish the separately owned Android phase and freshly inspect
the retained stopped compiler cache, server disk and memory, current native peer
state and absence of another owned compiler. The cache identity and image are
hard pinned. Availability and compatibility have not been established by this
source-only work. Do not start the job merely because these sources exist.

After independent source review and Root's separate job authorization, use a
fresh actual-job directory. Copy these two scripts and this input manifest
there. Build `payload.tar` with the root `native-current-driver/`, its exact
`server_compile.py` and `input-manifest.json`, and exactly the manifest's `files`
mapping, using each listed origin. Verify every origin's hash and size before
packaging. All directories must be UID/GID 1000 mode 0700; files UID/GID 1000 mode
0600. No links, profiles, credentials, old results or unrelated files belong in
the archive. Check local/server capacity before creating or transferring it.

Run the staged server-side script with the archive SHA-256 and one fresh
32-character lowercase hexadecimal token. This is the same Docker-in-Docker
location as the prior job. Its limits remain exactly two CPUs, 4 GiB RAM,
MemorySwap equal to Memory (no additional swap), 128 PIDs, UID/GID 1000, Nice 19,
network none, read-only retained payload volume and no profile mounts. The
compiler budget is 1200 seconds and the outer wait 1260 seconds. No extra job or
automatic retry is introduced. Cleanup targets only the newly created exact
container and temporary image tag; the old cache and native peers are retained.

Require actual compilation/link success, all required symbols, `ldd -r` with no
missing or undefined symbols, exact intended IQ/Core/OMEMO/wrapper/session DSO
paths, all complete-runtime loaders, expected no-argument exit 2, unchanged
protected inputs, no OOM and confirmed owned-job cleanup. Successful compilation
does not establish media, device authentication or interoperability.

## Runtime handoff remains separate

No old overlay, frozen input, controller hash, native profile or Docker peer is
modified by this preparation. A later accepted binary needs a new read-only
overlay, updated separate native-control/recorder/admission pins and loaded
module path/inode/full-hash and retained-device checks before a call.

The observer counts fingerprint nodes rather than unique values. Two identical
audio/video fingerprint nodes are still reported as
`multiple_fingerprints_not_individually_proven`; this diagnostic does not reject
the product call. Keep the observer unchanged. A future three-party-video media
PASS must remain separate from full authentication: it must not turn that
diagnostic into a blanket AV authentication PASS. Existing synthetic media also
does not prove physical microphone, camera, speaker or mobile-link quality.

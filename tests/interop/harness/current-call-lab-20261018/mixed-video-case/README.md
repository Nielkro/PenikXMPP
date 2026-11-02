# Mixed three-party legacy video — source preparation

This small injected case derives its call sequence from the retained
`ui-owner-resume/auth-media-only/auth_media.py` case. It starts Nora→Leon with
video, accepts that exact call, invokes DinoX Leon's real `add_participant` for
Felix, and accepts Felix's exact observed invitation. It does not bootstrap any
SDK, guest, account, native process, recorder or admission. The existing owner
must supply those guards and the same exact-call cleanup; there is no standalone
execution path. No actual video result has yet been obtained from this source.

`delivery()` binds two observations to the same three session IDs, peer full
addresses, room, native call IDs, Android conference ID and Android RTP stream
IDs. Each of the six directed edges must independently advance audio send and
receive packets, received PCM samples, video send and receive packets, encoded
and decoded frames, and actual receiving sink frames. Native physical camera
capture must remain off. The Android receiver must negotiate both audio and
video and observe positive frame dimensions. Connected state or synthetic
source pushes alone cannot produce a pass.

The 24 pure checks exercise the positive six-edge proof and independent failures
for each receiving sink, stalled PCM/encode/packets/decode, physical capture,
missing video/dimensions, replaced streams/sessions/calls/conference, wrong
room/address/connection and malformed counters. They do not simulate or prove
real media delivery. Run with `python3 -B check_media_proof.py`.

Authentication remains a separate result. The retained private observer binds
one fingerprint node per IQ; multiple AV fingerprint nodes remain individually
unproven, including identical duplicates. This case does not modify that
observer or label successful video delivery as full device authentication.
DinoX participates using legacy OMEMO1. DinoX PQ remains disabled; the separate
PQ audio case uses three Monocles Android clients.

Before live integration, review this source and provide the freshly built
current native driver, read-only runtime overlay, exact new native container
bindings, retained-device identity checks, and a current owner/session admission.
The removed historical native container IDs must not be reused as live proofs.
Existing Android APKs already expose the required real RTP and video sinks; no
SDK/APK/JNI or native-library build is introduced by this case.

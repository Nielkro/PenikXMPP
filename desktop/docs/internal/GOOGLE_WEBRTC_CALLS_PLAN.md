# DinoX Google/libwebrtc Calls Plan

> Status: Google/libwebrtc is the production call engine on `master`; Linux package revalidation is in progress
> Goal: preserve one Google/libwebrtc call engine across supported packages
> Non-goal: keep two competing call engines permanently

Slices 0-12 below retain the chronological implementation record. References
there to development-only environment gates, early ABI revisions or an active
GStreamer fallback describe those earlier milestones, not the current release
architecture. The authoritative current boundary is Slices 13-25 together with
`GOOGLE_WEBRTC_WRAPPER_ABI.md` and `GOOGLE_WEBRTC_RELEASE_PACKAGING.md`.

The M152 update advances the Linux and Windows native runtimes. The complete
Windows application build remains a separate acceptance step. Older milestone
and codec statements below are historical; current pins and codec capabilities
are documented in `GOOGLE_WEBRTC_RELEASE_PACKAGING.md`.

## 1. Decision

DinoX targets a real Google/libwebrtc call engine.

The retired GStreamer RTP/Jingle call stack accumulated distribution-specific
runtime problems around GStreamer, PipeWire/PulseAudio, video capture, codec
plugins, hardware acceleration and package contents. A libwebrtc-based engine is
the better long-term direction if DinoX wants one predictable media stack across
Linux packages and Windows builds.

This plan does not target GStreamer `webrtcbin` as the final answer. `webrtcbin`
is useful technical reference material, but it keeps DinoX dependent on the
same GStreamer runtime family that caused many of the cross-distribution call
issues.

## 2. End state

The desired final architecture is:

- DinoX keeps XMPP/Jingle signaling.
- Google/libwebrtc owns the live media engine:
  - capture
  - encoding/decoding
  - RTP/RTCP
  - ICE
  - DTLS-SRTP
  - jitter buffering
  - packet loss handling
- DinoX provides a small native wrapper around libwebrtc.
- Vala/GTK code talks to that wrapper through a stable C or GObject ABI.
- The old GStreamer RTP call engine is removed after the libwebrtc engine passes
  the agreed interop and packaging gates.

Audio/video messages are separate from live calls. Message recording may use the
same Google/libwebrtc capture boundary when that reduces Linux/Windows camera
and microphone variance. Message playback must stay out of the libwebrtc
capture/call settings UI until it has a Google/libwebrtc-owned path; it must not
be reintroduced there through GStreamer controls, playback tests or fallback
sinks. This plan is primarily about live audio/video calls; shared device
settings must still avoid mixing GStreamer-selected devices with
libwebrtc-selected devices.

## 3. Transition policy

The old GStreamer call engine may stay during development only as a safety
reference. It must not become a permanent second production call engine.

Rules for the transition:

1. There must be one selected call engine per build or runtime profile.
2. The libwebrtc branch may compare behavior against the old engine, but new
   call features should target libwebrtc first.
3. Existing half-finished WebRTC-related code must be audited early.
4. Dead or misleading WebRTC experiments should be removed or renamed before
   adding new libwebrtc code.
5. The final merge plan must include removal of the old GStreamer live-call
   path, not just addition of a new one.

This avoids repeating the current problem where "WebRTC" names exist in the
tree without representing a complete libwebrtc-based call implementation.

## 4. Current call stack

Current DinoX live calls are split across these layers:

### UI and call lifecycle

- `main/src/ui/call_window/call_window_controller.vala`
- `libdino/src/service/calls.vala`
- `libdino/src/service/call_state.vala`
- `libdino/src/service/call_peer_state.vala`

### Plugin boundary

- `libdino/src/plugin/interfaces.vala`
- `VideoCallPlugin`

The current `VideoCallPlugin` interface is shaped around the existing RTP stream
model. It may be too narrow for a libwebrtc `PeerConnection` model and should be
reviewed before implementation starts.

### XMPP/Jingle signaling

- `xmpp-vala/src/module/xep/0167_jingle_rtp/`
- `xmpp-vala/src/module/xep/0176_jingle_ice_udp/`
- `xmpp-vala/src/module/xep/0353_jingle_message_initiation.vala`
- `xmpp-vala/src/module/xep/0482_call_invites.vala`
- `xmpp-vala/src/module/xep/0272_muji.vala`

These layers remain relevant. libwebrtc does not replace XMPP signaling.

### Current transport and security

- `plugins/ice`
- libnice
- GnuTLS
- libsrtp2

With a real libwebrtc engine, this live-call transport/security work should move
inside libwebrtc for calls. The old code may remain only where other features
still require it.

### Current media engine

- `plugins/rtp`
- GStreamer `rtpbin`
- GStreamer audio/video/RTP elements

This is the engine to replace for live calls.

## 5. Existing WebRTC-like code that must be audited first

Before adding new libwebrtc code, inspect and classify the existing WebRTC-named
files:

- `plugins/rtp/src/webrtc_module.vala`
- `plugins/rtp/src/webrtc_session_manager.vala`
- `plugins/rtp/src/sdp_jingle_converter.vala`
- optional `gstreamer-webrtc` and `gstreamer-sdp` handling in
  `plugins/rtp/meson.build`

Known concern:

- `webrtc_module.vala` was not a real Google/libwebrtc implementation.
- `webrtc_session_manager.vala` was an incomplete or unused bridge attempt.
- `sdp_jingle_converter.vala` contained prototype mapping ideas, but it was not
  tested or used by the production call path.

Acceptance criteria for this audit:

- every WebRTC-named file is classified as one of:
  - keep and reuse
  - keep temporarily as migration reference
  - rename because the name is misleading
  - remove as dead code
- the build graph clearly shows whether a file is active or unused
- no new libwebrtc code is added on top of misleading old names

## 6. Protocol constraints

DinoX still has to interoperate with XMPP clients. The libwebrtc engine must be
driven by XMPP/Jingle state.

Relevant XEPs:

- XEP-0166: Jingle session framework
- XEP-0167: Jingle RTP sessions
- XEP-0176: Jingle ICE-UDP transport
- XEP-0320: DTLS-SRTP in Jingle
- XEP-0353: Jingle Message Initiation
- XEP-0482: Call Invites

Required mapping:

- Jingle session-initiate/session-accept -> libwebrtc offer/answer flow
- Jingle RTP content descriptions -> SDP media sections
- Jingle ICE candidates -> libwebrtc remote ICE candidates
- libwebrtc local ICE candidates -> Jingle `transport-info`
- DTLS fingerprints and setup attributes -> XEP-0320-compatible Jingle data
- content names and media directions -> stable call state in DinoX

DTLS-SRTP must stay mandatory for live calls. SDES-SRTP must not become a
fallback.

Codec and bandwidth policy belongs at the DinoX/libwebrtc boundary, not in a
new hand-written media pipeline:

- Opus is the preferred audio codec.
- VP8 is the preferred video codec when DinoX controls offer ordering.
- H.264 is not enabled for the DinoX libwebrtc artifact by default. The
  licensing and patent-distribution risk is intentionally avoided until there
  is a separate explicit legal and release decision.
- VP8 must remain the primary interoperable target codec. Non-H.264 codecs
  offered by the prepared libwebrtc artifact, such as VP9 or AV1, may remain
  available as libwebrtc-managed fallback choices, but DinoX must not add
  proprietary codec build flags for the default artifact.
- Runtime bitrate, loss recovery, frame-rate and resolution adaptation belong
  to libwebrtc. DinoX may set policy bounds later, but must not recreate fixed
  GStreamer-style codec/bitrate pipelines in the libwebrtc path.
- If video negotiation or maintenance fails, keep the call alive as audio-only
  where possible instead of failing the entire call.

## 7. Proposed architecture

### 7.1 Native wrapper

Create a small native library around libwebrtc:

- language: C++
- public ABI: C or GObject
- consumers: Vala plugin code
- responsibility:
  - create/destroy peer connection factory
  - create/destroy call sessions
  - apply local/remote descriptions
  - emit ICE candidates
  - add remote ICE candidates
  - expose local/remote audio/video track state
  - expose video frames to GTK-compatible rendering code
  - control mute, camera, screen/video pause and device switching

The wrapper must hide libwebrtc API churn from the Vala layer.

### 7.2 DinoX plugin

Add a new libwebrtc-based call plugin or a clearly separated libwebrtc engine
inside the existing call plugin boundary.

The preferred implementation shape is:

- new engine code path with explicit build option
- no silent fallback to old GStreamer calls inside the same runtime path
- old engine kept only until the replacement passes acceptance gates

Possible names:

- `plugins/webrtc`
- `plugins/google-webrtc`
- `plugins/rtp-webrtc`

Avoid ambiguous names that suggest generic WebRTC while actually using
GStreamer.

### 7.3 Signaling bridge

Implement a tested Jingle/SDP bridge.

The bridge must be deterministic and fixture-tested. It should not be a loose
string converter hidden inside call setup.

Required fixtures:

- DinoX generated audio-only offer
- DinoX generated audio/video offer
- Conversations-compatible offer/answer
- monocles-compatible offer/answer
- Monal-compatible offer/answer
- trickle ICE candidate exchange
- session terminate during ICE gathering
- rejected media content

### 7.4 UI integration

The current call UI should remain the product UI, but its backend assumptions
must be reviewed:

- video frame delivery should not depend on GStreamer widgets
- mute/unmute must map to libwebrtc audio tracks
- camera pause must map to libwebrtc video tracks
- device switching must not rebuild the entire call window
- GTK updates must be marshalled to the main thread

### 7.5 Engine ownership and process isolation

The native wrapper already creates dedicated libwebrtc network, worker and
signaling threads. This is necessary for libwebrtc, but it is not sufficient
to protect the DinoX GTK process:

- context creation and destruction are still initiated synchronously by Vala
- device enumeration and switching still enter the native wrapper from the
  GTK process
- session creation, close and camera start/stop cross the C ABI synchronously
- factory release, ADM termination and libwebrtc thread shutdown still happen
  inside the GTK process
- an `RTC_CHECK`, `RTC_NOTREACHED`, abort or native memory error therefore
  still terminates DinoX

The production end state is one external `dinox-webrtc-worker` process per
DinoX process, not one process per call. It owns:

- the libwebrtc network, worker and signaling threads
- the peer-connection factory and all peer connections
- the platform audio device module
- camera capture and native video sinks
- device enumeration and switching
- call audio/video, DTMF and local call feedback
- libwebrtc-based media-message recorders and device tests, because they share
  the same ADM/camera lifecycle

The DinoX main process keeps:

- XMPP streams, JMI and Jingle signaling
- OMEMO call verification and trust decisions
- application settings and persistence
- GTK windows, controls and rendering
- worker supervision and user-visible failure handling

Audio samples must not be streamed through DinoX or GTK. Audio capture,
processing, encoding, decoding and playout remain entirely in the worker.
Video crosses the boundary through a bounded shared-memory ring with a
latest-frame-wins policy. Ordinary request/response IPC must not carry every
video frame.

The worker protocol must be local, versioned and strictly bounded:

- fixed frame header containing magic, protocol version, message type,
  request ID, session ID and payload length
- explicit request/reply and asynchronous event types
- monotonic session generations so late callbacks from a closed session are
  discarded
- strict maximum payload sizes and validation before allocation
- Unix socket pair or Unix-domain socket on Linux
- named pipe on Windows
- ABI/build-revision/feature handshake before creating a context
- no TURN credentials, SDP, ICE passwords or contact identifiers in normal
  logs

The process boundary is the crash-containment boundary. If the worker exits or
stops responding, active calls fail once with a clear media-engine error. They
are not silently resumed. The supervisor reaps the process and starts a fresh
worker only for a later operation.

Before process extraction, introduce a serial native-engine executor and the
same command/event ownership model in-process. This is a migration step, not a
second permanent architecture. It proves ordering, cancellation and
single-owner teardown before the transport changes from direct calls to IPC.

Lifecycle rules:

- one long-lived context per worker
- do not destroy the context after every call
- calls, recorders and device tests acquire explicit activity leases
- idle shutdown is permitted only after the final lease is released and a
  grace timer expires
- all native handles are created, used and destroyed by their owning executor
- peer-connection mutations are marshalled from that executor to libwebrtc's
  signaling thread instead of being invoked from the GTK or IPC thread
- Vala finalizers must never decide the native destruction thread
- UI callbacks contain only immutable copied data and are dispatched on the
  GTK main context
- shutdown drains or invalidates callbacks before releasing their user data

This also addresses a current side-effect risk: the plugin closes the context
when the last call session ends, while the recorder provider and device tests
can still retain objects obtained from that context. The implementation must
replace that implicit `sessions.is_empty` ownership test with explicit leases
before process extraction.

### 7.6 Low-bandwidth audio policy

DinoX should provide a deliberate audio-only mode for severely constrained
GPRS/EDGE/2G-style links. This is an Opus policy inside the single libwebrtc
engine, not a legacy codec pipeline.

Initial product modes:

- `Automatic` is the default and retains normal libwebrtc adaptation
- `Low bandwidth (2G)` is an explicit user choice and forces audio-only calls

The first low-bandwidth baseline is:

- Opus remains the only preferred audio codec
- RTP clock remains `48000`; this is required for Opus and does not imply a
  48 kbit/s media bitrate or fullband encoding
- mono speech preference
- local outbound sender maximum: 16 kbit/s through
  `RtpSenderInterface::GetParameters()` / `SetParameters()` and
  `RtpEncodingParameters.max_bitrate_bps`
- no artificial minimum sender bitrate; libwebrtc must be allowed to reduce
  traffic below the cap
- DTX enabled for severe bandwidth constraints
- adaptive packet duration enabled where the pinned M150 API supports it
- receiver support for Opus in-band FEC signaled; the encoder still decides
  whether redundancy is affordable from loss and capacity estimates
- VBR and libwebrtc congestion control remain enabled
- no video transceiver or camera capture in this mode

Structured Jingle/SDP mapping may advertise the standard Opus parameters
`maxaveragebitrate`, `maxplaybackrate`, `sprop-maxcapturerate`, `stereo`,
`sprop-stereo`, `usedtx` and `useinbandfec`. It must use the negotiated Opus
payload ID and the existing typed payload model. Never rewrite raw SDP and
never assume payload type 111.

The initial advertised 2G values are:

- `maxaveragebitrate=16000`
- `maxplaybackrate=16000`
- `sprop-maxcapturerate=16000`
- `stereo=0` and `sprop-stereo=0`
- `usedtx=1`
- `useinbandfec=1`

`maxaveragebitrate` describes what a receiver asks the remote sender to send;
it is not a substitute for the local outbound sender cap. Both directions
must therefore be handled deliberately. The non-standard
`x-google-min-bitrate`, `x-google-max-bitrate` and
`x-google-start-bitrate` SDP parameters are not part of the DinoX baseline.

Do not hard-code 60 ms packetization in the first implementation. Longer
packets reduce header overhead but increase latency and the impact of a lost
packet. Start from libwebrtc adaptive packet duration, then compare 20, 40 and
60 ms under controlled loss before changing the production default.

The 16 kbit/s value is an encoded-audio cap, not a promise that an IP link
carrying RTP, SRTP, DTLS, ICE and possibly TURN needs only 16 kbit/s. Acceptance
must record total wire traffic as well as the libwebrtc outbound audio bitrate.

Analysis references:

- [Monocles issue 516](https://codeberg.org/monocles/monocles_chat/issues/516)
  motivates a 6-16 kbit/s Opus mode for slow mobile links.
- [The accepted Monocles patch](https://codeberg.org/monocles/monocles_chat/commit/4347d03aebaf28ef49edd23572ec15adae7be143)
  is useful interop evidence, but its raw SDP replacement and payload-ID
  assumption are not copied into DinoX.
- [RFC 7587](https://www.rfc-editor.org/rfc/rfc7587) defines Opus RTP clock,
  bitrate, DTX, FEC, packet duration and SDP parameters.
- [Pinned libwebrtc M150 RTP parameters](https://webrtc.googlesource.com/src/+/1f975dfd761af6e5d76d28333191973b258d82a8/api/rtp_parameters.h)
  provide the typed sender bitrate cap and adaptive packet-duration field.
- [Pinned libwebrtc peer-connection interface](https://webrtc.googlesource.com/src/+/1f975dfd761af6e5d76d28333191973b258d82a8/api/peer_connection_interface.h)
  is the ownership/threading reference for peer-connection work.

## 8. Build and packaging strategy

libwebrtc is not a normal small distro dependency. Treat it as a pinned vendor
dependency.

### 8.1 Version pinning

The current artifact is pinned to WebRTC M150 commit
`1f975dfd761af6e5d76d28333191973b258d82a8`. Keep recording and validating:

- upstream revision
- branch number
- build flags
- generated headers
- produced libraries
- license files
- patent/IP grant reference
- update procedure

Do not track random tip-of-tree in normal builds.

### 8.2 First target

Start with local Linux x86_64.

Do not start with all package formats at once. The first proof must show:

- libwebrtc builds reproducibly
- DinoX links to the wrapper
- DinoX starts with the wrapper enabled
- one minimal audio-only call can be attempted locally

### 8.3 Packaging order

1. local Linux x86_64
2. AppImage
3. Debian package
4. Windows/MSYS2
5. Flatpak
6. additional architectures

Flatpak needs special care because runtime ABI and sandbox boundaries are
stricter than local/AppImage builds.

### 8.4 Video implementation and Windows order

Windows must be considered during the video design, but it is not the first
runtime to debug.

Rules for the video phase:

1. Keep the native wrapper and Vala boundary platform-neutral from the first
   video slice.
2. Do not introduce V4L2, PipeWire, PulseAudio or GStreamer dependencies into
   the new libwebrtc live-call video path.
3. First prove Linux/libwebrtc video behavior locally:
   - video offer/answer and Jingle mapping
   - remote video frame delivery through a wrapper callback/sink
   - GTK rendering on the main thread
   - local preview
   - camera capture and camera pause/resume
   - stable call teardown
4. Preserve the completed audio-call baseline while adding video. If video
   negotiation, receive, render or capture fails, keep the call alive as
   audio-only where possible.
5. Keep VP8 as the preferred video codec when DinoX controls offer ordering.
   Do not enable H.264 in the default DinoX libwebrtc artifact; non-H.264
   fallback codecs exposed by the artifact may remain available.
6. After Linux video calls are functional, validate/build the Windows/MSYS2
   libwebrtc artifact and package/runtime behavior as a separate porting
   slice. Do not debug Linux video, GTK rendering, camera capture and Windows
   runtime failures in one mixed slice.

### 8.5 CI

CI should not build libwebrtc from source on every normal push unless that cost
is explicitly accepted. Use pinned prepared artifacts or a dedicated dependency
build workflow.

Required CI checks:

- wrapper compile check
- DinoX compile check with libwebrtc enabled
- DinoX compile check with libwebrtc disabled while migration is incomplete
- wrapper-enabled builds use an explicit Clang >= 21 toolchain; the current
  local proof path is Chromium clang from the WebRTC checkout
- license/NOTICE packaging check
- package contents check

## 9. Implementation slices

### Slice 0: branch and documentation

Status: started.

Deliverables:

- isolated development branch (merged into `master`)
- this plan
- no runtime behavior changes

### Slice 1: current WebRTC/GStreamer call audit

Status: audit documented in `docs/internal/GOOGLE_WEBRTC_CALLS_SLICE1_AUDIT.md`.
The misleading optional GStreamer `webrtcbin` source path has been removed from
the RTP build graph; the current production RTP call engine remains unchanged.

Deliverables:

- classify existing WebRTC-named files
- identify unused/dead WebRTC bridge code
- decide which code can be removed before new work starts
- document current `VideoCallPlugin` assumptions

Acceptance:

- no ambiguous "WebRTC" code remains unexplained
- build graph is understood
- no user-visible behavior change unless dead code is removed safely

### Slice 2: libwebrtc dependency proof

Status: started in `docs/internal/GOOGLE_WEBRTC_DEPENDENCY_PROOF.md`.
Self-contained release packaging strategy is documented in
`docs/internal/GOOGLE_WEBRTC_RELEASE_PACKAGING.md`.
The external build helper is `scripts/build-libwebrtc-artifact.sh`.

Deliverables:

- selected libwebrtc revision
- reproducible local build notes
- minimal generated artifact layout
- license/NOTICE inventory

Acceptance:

- local build produces the required library/header set
- artifact can be consumed by Meson without changing DinoX call behavior

### Slice 3: native wrapper skeleton

Status: started in `docs/internal/GOOGLE_WEBRTC_WRAPPER_ABI.md`.

Deliverables:

- C++ wrapper library
- C or GObject ABI
- Meson option for enabling the wrapper
- lifecycle smoke test

Acceptance:

- DinoX builds with wrapper enabled
- DinoX builds with wrapper disabled
- no call UI behavior is changed yet

### Slice 4: Jingle/SDP bridge tests

Status: bridge and development engine proof started in
`docs/internal/GOOGLE_WEBRTC_JINGLE_SDP_BRIDGE.md` and
`docs/internal/GOOGLE_WEBRTC_CONVERSATIONS_COMPARISON.md`.

Deliverables:

- explicit converter module
- fixtures for known client shapes
- tests for offer/answer/candidates/fingerprints

Acceptance:

- generated Jingle is stable
- generated SDP is accepted by libwebrtc
- remote Jingle from target clients maps without lossy hacks

Current additional proof:

- `plugins/google-webrtc` builds only behind `plugin-google-webrtc`
- the engine smoke creates two native libwebrtc sessions and roundtrips
  offer/answer SDP through the Jingle adapter
- the combined engine/Jingle smoke runs an in-process initiator/responder
  `session-initiate` -> `session-accept` handshake through the native engine and
  XEP-0166/XEP-0167 adapter boundary
- the IQ wire smoke wraps the engine/Jingle session in a real IQ set/result
  boundary, with malformed peer/SID/error handling kept outside the global
  production `Xep.Jingle.Module` handler
- the JMI wire smoke proves an audio-only `propose` -> `proceed` gate before
  creating the libwebrtc Jingle IQ session, then carries offer/answer,
  bidirectional `transport-info`, decoded audio samples and `session-terminate`
  through that JMI-owned wire session, without replacing `PeerState.call_resource()`
- the JMI wire smoke now routes `proceed` and Jingle IQ sets through an
  explicit local-full-JID/SID router, proving that the libwebrtc path can own
  only its registered SIDs while leaving unrelated Jingle IQs to the production
  RTP/Jingle stack
- `Xmpp.Iq.Module` now has an optional consume-capable namespace interceptor
  hook. A libwebrtc route can inspect Jingle IQ get/set stanzas before the
  existing namespace handler and consume only explicitly owned sessions; when it
  declines, the existing handler path or `service-unavailable` fallback remains
  active. This hook is additive and is not registered by the production call
  path yet.
- `plugins/google-webrtc` now has a development-only `EngineJmiIqInterceptor`
  adapter and registers it when the explicit Google/libwebrtc plugin is loaded.
  The adapter delegates to `EngineJmiSessionRouter` and consumes only Jingle IQ
  sets with a registered local full JID plus SID. Unknown sessions still fall
  through to the existing production Jingle/RTP handler.
- the plugin shell now has explicit development-only factory methods for
  outgoing audio JMI sessions and incoming JMI session objects using the real
  `XmppEngineJmiTransport` and `XmppEngineJingleWireTransport`. These methods
  are not called from `VideoCallPlugin`, `PeerState.call_resource()` or the call
  UI yet.
- `libdino` now exposes a narrow optional `JmiCallEnginePlugin` interface and
  registry slot. The Google/libwebrtc plugin registers there, but only reports
  itself development-enabled when `DINOX_GOOGLE_WEBRTC_CALLS=1`/`true`/`yes`.
  This prevents the existing `Calls`/JMI service from accidentally starting a
  second call engine just because the development plugin was built.
- the existing `Calls`/`PeerState` JMI path now consults that gated
  `JmiCallEnginePlugin` only for outgoing 1:1 audio JMI calls. With the gate
  off, with video requested or with the plugin unavailable, the old JMI message
  and RTP/GStreamer `call_resource()` path is unchanged. With the gate on,
  outgoing `propose` and peer `proceed` are routed through the libwebrtc
  development engine; real device media, user-facing call controls and complete
  production state transitions are still pending.
- the development engine session is now exposed to `PeerState` as a typed
  `JmiCallEngineSession` rather than a raw object. `PeerState` connects its
  `active`, `failed` and `remote_terminated` signals to the existing call-state
  bridge, disconnects those handlers during cleanup, and uses the engine
  session's `end()` method for local hangup/retract so libwebrtc-owned SIDs are
  released from the development router instead of falling back to the old JMI
  stanza path. Remote JMI `reject`/`retract` and same-account retractions use
  the session's local `discard()` boundary, which releases the registered
  development SID without sending another JMI stanza. The `Calls` termination
  signal path also discards any remaining development sessions before removing
  the call, covering direct timeout/error terminations that do not pass through
  `PeerState.end()`.
- incoming audio-only JMI proposals now create a development
  `JmiCallEngineSession` when `DINOX_GOOGLE_WEBRTC_CALLS` is enabled, the
  proposal comes from a full JID and the Google/libwebrtc plugin is available.
  `PeerState.accept()` then sends JMI accept/proceed through that engine
  session so the following Jingle IQs are owned by the libwebrtc SID router.
  Video proposals, missing full JIDs, missing streams or disabled gates continue
  through the existing RTP/GStreamer JMI path.
- the call window detects when a call is owned by the development
  Google/libwebrtc JMI engine and does not create RTP/GStreamer video widgets
  or device chooser bindings for that audio-only dev path. The RTP device
  chooser bindings/buttons are not used for these calls. This avoids pulling
  the old GStreamer live-call runtime into the libwebrtc proof UI.
- the call window now exposes explicit libwebrtc microphone/speaker chooser
  integration for gated audio-only development calls. `AudioSettingsPopover`
  can receive a pre-enumerated device list, the Google/libwebrtc plugin wraps
  native `EngineAudioDeviceInfo` values as `MediaDevice`, and the controller
  applies the saved or preferred capture/playout device through the same
  account-scoped audio-only `JmiCallEnginePlugin` gate that starts the call.
  The RTP/GStreamer `VideoCallPlugin` device path remains the default for
  production calls and is not called by the libwebrtc dev call UI.
- unsupported call controls are explicitly gated for the audio-only
  Google/libwebrtc development path. The call window hides the video toggle and
  DTMF dialpad, ignores DTMF and RTP dot-dump callbacks for libwebrtc-owned
  calls, does not show RTP participant volume controls, and `CallState` avoids
  applying RTP/GStreamer media devices or the RTP pipeline-dispose fallback to
  libwebrtc-owned sessions. Microphone mute/unmute remains wired through
  `JmiCallEngineSession.set_local_audio_enabled()`.
- call availability is now split by media capability. A gated audio-only
  Google/libwebrtc engine can make 1:1 audio calls available even when the old
  RTP/GStreamer `VideoCallPlugin` is not the selected runtime, but video calls,
  group calls, video-call notifications and incoming-call accept controls still
  require the existing RTP/GStreamer call capability until libwebrtc has explicit
  implementations for those paths.
- the `main-ui-runtime-test` now covers the libwebrtc audio-only bottom-bar
  boundary: video controls and the DTMF dialpad stay hidden, unsupported
  popovers are closed, injected libwebrtc microphone/speaker devices render in
  the audio chooser, and the RTP/GStreamer-only digital gain control is absent.
- `JmiCallEngineSession` now exposes generic runtime diagnostics for the
  development engine. `PeerState.get_info()` maps those diagnostics into the
  existing call-details model for libwebrtc-owned calls, and the call details
  dialog displays PeerConnection state, ICE state, Opus/48000 and native audio
  counters instead of showing empty RTP/GStreamer data. The production RTP
  details path is unchanged. The JMI wire smoke asserts both pending
  pre-wire diagnostics and active native audio diagnostics.
- the native wrapper ABI v9 exposes the first audio-device boundary required
  for real call UI integration: count capture/playout devices, read
  device name/GUID by index and select capture/playout devices on the
  libwebrtc AudioDeviceModule. The synthetic ADM path returns one deterministic
  microphone and one deterministic speaker for tests; the optional platform
  probe verifies the same API against libwebrtc's platform-default ADM when the
  host audio service exposes devices, and tolerates the headless/no-audio-server
  case where libwebrtc reports enumeration as unavailable.
- the audio-only smoke proves a native libwebrtc offer/answer roundtrip with
  `audio_enabled=true`, `video_enabled=false`, exactly one XEP-0166 content,
  an XEP-0167 `media="audio"` description and an Opus/48000 payload on both
  `session-initiate` and `session-accept`
- the audio-only wire smoke now also pumps generated Jingle `transport-info`
  IQs in both directions and waits until both remote audio sinks have decoded
  non-zero samples through the libwebrtc audio path
- the audio-only wire smoke also sends a real `session-terminate` IQ through
  the same wire boundary, verifies the ACK and asserts that both local and
  remote signaling state machines enter `ENDED`
- the native ABI v7 smoke proves that send-capable audio sessions now attach a
  local libwebrtc `AudioSource` and enabled `AudioTrack` to the audio
  transceiver; receive-only/inactive audio can still negotiate without creating
  a local sending track
- the native ABI v7 smoke also proves that the answer path binds the local
  audio track to the matched remote-offer transceiver before `CreateAnswer()`,
  exchanges gathered ICE candidates between two local libwebrtc sessions and
  reaches a connected ICE/PeerConnection state
- the native ABI v7 smoke additionally attaches a counting
  `AudioTrackSinkInterface` to negotiated remote audio tracks on both sides,
  proving the remote-audio track boundary before real playout/device wiring
- the wrapper proof uses a DinoX-owned synthetic audio device module for the
  development build: it generates deterministic 10-ms PCM capture frames,
  lets libwebrtc encode/transport/decode them as part of the local two-session
  call, pulls discard playout, and asserts that remote audio sinks receive
  non-zero samples
- the production `plugins/rtp` call path remains unchanged

### Slice 5: audio-only 1:1 calls

Status: completed for the current development branch in commit
`cea8f124 plugins: complete libwebrtc audio call proof`.

The completed audio proof includes:

- outgoing and incoming JMI-gated audio-only calls
- libwebrtc-owned Jingle IQ session routing
- platform microphone/speaker device selection
- microphone mute/unmute
- XEP-0215 STUN/TURN discovery and ICE server handoff
- DTLS-SRTP call security display
- real Monal interop for audio calls
- remote DTMF through libwebrtc `DtmfSenderInterface`
- local DTMF feedback through a libwebrtc `AudioMixer::Source`
- targeted debug diagnostics gated behind
  `DINOX_GOOGLE_WEBRTC_CALL_DEBUG=1`

Validation evidence:

- `meson compile -C build-google-webrtc-local main/dinox
  google-webrtc-engine google-webrtc-wrapper-smoke
  google-webrtc-jmi-wire-smoke`
- `meson test -C build-google-webrtc-local --num-processes 1
  google-webrtc-wrapper-smoke google-webrtc-engine-smoke
  google-webrtc-signaling-smoke google-webrtc-jingle-engine-smoke
  google-webrtc-jingle-wire-smoke google-webrtc-jmi-wire-smoke
  google-webrtc-audio-only-smoke --print-errorlogs
  --timeout-multiplier 4`
- runtime interop with Monal confirmed audio in both directions and local plus
  remote DTMF; logs showed local DTMF frames mixed with
  `fmt:48000/1/2 peak:0.6999`.

Current boundary before this slice is considered complete: the engine negotiates
audio-only Jingle/SDP and attaches a local libwebrtc audio source/track for
send-capable sessions. The native proof can connect two local libwebrtc
PeerConnections over ICE and attach remote audio sinks to the negotiated remote
audio tracks. The development wire proof now carries both offer/answer and
trickle ICE `transport-info` between two in-process DinoX Jingle sessions and
proves synthetic PCM samples through the libwebrtc audio path. It also proves
remote `session-terminate` teardown into `ENDED` state over the same wire
boundary. The JMI-gated proof now covers the same audio-only path after
`propose`/`proceed`, including terminate propagation into JMI `ENDED` state. The
current router proof is still local/in-process, but it defines the safety rule
for the future real XMPP hook: route only explicitly registered libwebrtc SIDs
and do not consume arbitrary production Jingle sessions. The IQ interceptor hook
and plugin-side adapter exist for explicit Google/libwebrtc dev builds. The
plugin also has dev-only session factory methods and a registry interface behind
`DINOX_GOOGLE_WEBRTC_CALLS`. The first outgoing audio-only lifecycle hook now
creates a libwebrtc development JMI session and routes peer `proceed` through it
when that gate is enabled. This is not a complete user-visible call yet:
complete production call lifecycle wiring is still required below.
Platform-default capture/playout, explicit libwebrtc microphone/speaker device
selection and local mute are wired through the native engine for the gated
runtime, while smokes keep using the deterministic synthetic audio module
unless a platform-audio probe is explicitly requested. The typed development
session now covers
active/failure/remote-terminate signaling and local retract/terminate cleanup
through the same `PeerState` bridge that the current Jingle path uses.
JMI reject/retract cleanup is local-only through `discard()` so the router does
not retain stale SIDs after `Calls` removes the call.
Incoming audio-only JMI proposals can now enter that same development engine
when the proposal is from a full JID; accepting the call sends proceed through
the engine-owned JMI session.
The native ABI v7 can create the WebRTC context either with the deterministic
synthetic audio device or with libwebrtc's platform default audio device module.
Default smokes stay synthetic and hardware-independent. The runtime plugin uses
the platform module by default when `DINOX_GOOGLE_WEBRTC_CALLS` is enabled;
`DINOX_GOOGLE_WEBRTC_AUDIO_DEVICE=synthetic` forces the synthetic module for
targeted harness/debug runs. The optional wrapper probe
`DINOX_WEBRTC_TEST_PLATFORM_AUDIO_DEVICE=1` verifies that the linked M150
artifact can open the platform module on a local runtime.
The development runtime emits visible `Google/libwebrtc dev call:` log lines
when the gate is active and when it owns a call SID. Before any call starts,
the startup log must show `plugin registered gate=enabled audio-device=platform`
unless `DINOX_GOOGLE_WEBRTC_AUDIO_DEVICE=synthetic` was set deliberately. For a
real audio-only dev test, these lines must show the libwebrtc JMI/Jingle path,
platform audio and `rtp-gstreamer=not-started`, `rtp-gstreamer=skipped` or
`rtp-gstreamer=not-used`. Missing startup/ownership lines or a following
`call_resource()`/RTP start means the test did not exercise the
Google/libwebrtc path. If the gate is active but a call cannot use the
development engine, DinoX emits `Google/libwebrtc dev call: not selected` with
a concrete reason such as `video-requested`, `no-jmi-resource` or
`no-jmi-resource-or-direct-resource`; those cases are deliberate fallback or
no-route cases, not successful libwebrtc call tests.
The libwebrtc Jingle bridge must keep XEP-0176 ICE credentials on trickled
`transport-info` candidates. Local candidates are therefore paired with the
`ufrag`/`pwd` from the matching local description content before they are
serialized to Jingle. Incoming `transport-info` also accepts multiple
`candidate` elements in one stanza so interop does not depend on one-candidate
trickle batching. A `remote-candidate` nomination is acknowledged as a
no-candidate update; libwebrtc keeps owning candidate-pair nomination internally.
The call window no longer instantiates RTP/GStreamer video widgets or device
chooser bindings/buttons for the gated audio-only development engine path, and
audio device selection for that path now uses the libwebrtc engine boundary
instead of `VideoCallPlugin`. Video toggle, DTMF dialpad, participant RTP
volume controls and RTP dot-dump are disabled or no-op for libwebrtc-owned
audio-only calls until those features have explicit libwebrtc implementations.

Deliverables:

- Opus audio call through libwebrtc
- Jingle Message Initiation/proceed path
- session-initiate/session-accept path
- trickle ICE
- terminate/error handling

Acceptance:

- DinoX-to-DinoX audio call works
- no GStreamer RTP elements are used for the live call path
- failure states are visible and recoverable

### Slice 6: video receive

Status: active; the native remote-frame, Vala remote-frame, GTK-render-boundary
and gated video-requested JMI selection micro-slices are completed. Camera
capture is not implemented yet.

Starting evidence after the audio proof:

- the native wrapper can already create video transceivers and video SDP
  sections when `video_enabled=true`
- `EngineJmiSession` can carry video-requested JMI descriptions and build a
  video-enabled engine config
- `EngineMediaPolicy` records VP8 preference, keeps H.264 disabled for the
  default DinoX artifact, and only allows license-safe fallback codecs exposed
  by libwebrtc
- native local synthetic video source/track support exists for wrapper proof
  builds
- native remote video sink ABI exists with frame count and last-frame size
  diagnostics
- the current GTK video widgets still use the old `VideoCallPlugin`/
  GStreamer-oriented `VideoCallWidget` boundary
- the M150 artifact exposes libwebrtc video capture, video frame and video sink
  headers, so the first video boundary can stay libwebrtc-native and
  platform-neutral

Status as of the current video implementation slice:

- C ABI bumped to 21 for video state and synthetic-frame proof support.
- `DinoXWebrtcSessionState` now exposes local video source/track state and
  remote video sink frame counters.
- The native wrapper can create a libwebrtc `VideoTrack` from a synthetic I420
  source and attach remote `VideoSinkInterface<VideoFrame>` counters.
- Incoming/answer-side sessions have a video defer path matching the existing
  audio defer path. This avoids duplicate answer-side transceivers and binds
  the local video track to the transceiver created from the remote offer before
  `CreateAnswer()`.
- The wrapper smoke proves bidirectional synthetic video frame delivery between
  two local libwebrtc peer connections.
- Vala/JMI diagnostics carry the new video track/sink counters.
- C ABI bumped to 22 for decoded remote video frame callbacks.
- Native remote video sinks can now convert received I420 frames to copied
  BGRA frame memory and emit it through the C ABI. The callback memory is valid
  only during the native callback; Vala copies it before main-thread dispatch.
- `EngineSessionOwner`, `EngineJmiSession` and `PeerState` now re-emit remote
  libwebrtc video frames as `JmiCallVideoFrame` objects without using the old
  RTP/GStreamer `VideoCallWidget`.
- The call window has a dedicated `LibwebrtcVideoWidget` that renders
  `Gdk.MemoryTexture` frames on the GTK main thread. It is only fed by the
  gated libwebrtc JMI path and does not instantiate GStreamer video sinks.
- The wrapper smoke now asserts both remote video sink counters and the new
  C video-frame callback.
- The engine smoke now pumps in-process ICE between two video-enabled
  libwebrtc sessions, pushes a controlled synthetic video frame from the local
  source and asserts that it reaches the Vala `remote_video_frame` signal as
  BGRA frame data. This proves the runtime path up to Vala without camera
  capture or GStreamer RTP.

Validation:

- `meson compile -C build-google-webrtc-local google-webrtc/google-webrtc-wrapper-smoke`
- `./build-google-webrtc-local/google-webrtc/google-webrtc-wrapper-smoke`
- `meson compile -C build-google-webrtc-local main/dinox`
- `meson compile -C build-google-webrtc-local google-webrtc-engine`
- `meson compile -C build-google-webrtc-local google-webrtc-engine-smoke google-webrtc-jmi-wire-smoke google-webrtc-audio-only-smoke`
- `./build-google-webrtc-local/google-webrtc/google-webrtc-wrapper-smoke &&
  ./build-google-webrtc-local/plugins/google-webrtc/google-webrtc-engine-smoke &&
  ./build-google-webrtc-local/plugins/google-webrtc/google-webrtc-jmi-wire-smoke &&
  ./build-google-webrtc-local/plugins/google-webrtc/google-webrtc-audio-only-smoke`

Deliverables:

- remote VP8-preferred video frame delivery
- non-H.264 fallback-codec receive path where the peer cannot use VP8 cleanly
- GTK rendering path
- stable teardown

Acceptance:

- DinoX can receive video without GStreamer RTP
- unsupported or failed video can degrade to audio-only when the call can still
  continue
- no GTK updates from libwebrtc worker/signaling threads

Micro-slices:

1. Map current video path and wrapper capability without behavior changes.
   Completed for the initial video slice.
2. Add native remote video sink/callback diagnostics with synthetic or
   in-process frame proof, no GTK rendering yet. Completed for the initial
   video slice.
3. Extend Vala diagnostics and smokes to prove remote video receiver/frame
   counters. Completed for the initial video slice.
4. Add GTK rendering widget fed from the libwebrtc video frame callback on the
   main thread. Completed in ABI v22.
5. Enable video-requested libwebrtc JMI calls behind the explicit
   `DINOX_GOOGLE_WEBRTC_CALLS` gate, without adding camera capture. Completed
   for the gated video-requested JMI slice.
6. Add a controlled remote-frame runtime smoke for the Vala/GTK boundary, still
   without camera capture. Completed for the Vala remote-frame runtime slice.
7. Only after remote receive/render is stable, add local preview and camera
   capture.

Status as of the gated video-requested JMI slice:

- `JmiCallEnginePlugin` now has an explicit `can_start_video()` capability and
  a media-generic `start_outgoing_session(..., video_requested)` entry point.
  Engines that do not implement video keep the safe default: video is not
  supported.
- `Calls.get_development_jmi_call_engine(account, true)` no longer has a hard
  video-requested block. It returns the development engine only when the
  runtime gate is enabled and that engine explicitly reports video support.
- Outgoing 1:1 video JMI calls can now choose the gated Google/libwebrtc path
  instead of falling back to the existing RTP/GStreamer JMI path solely because
  video was requested.
- Incoming JMI proposals with video descriptions can attach the gated
  Google/libwebrtc development session; missing full peer JIDs, missing streams
  and disabled gates still fall back/decline as before.
- The Google/libwebrtc plugin now starts outgoing `audio-video` sessions by
  setting `video_requested=true` on `EngineJmiSession`. Local camera capture is
  still not implemented; the current native synthetic video source remains a
  proof boundary.
- The JMI wire smoke now includes a lightweight video-requested proof: it sends
  an audio+video JMI propose, creates the libwebrtc Jingle wire session after
  proceed, asserts an audio+video `session-initiate`, and verifies that the
  native session has a local video source/track and video transceiver.

Validation:

- `meson compile -C build-google-webrtc-local google-webrtc-engine google-webrtc-jmi-wire-smoke`
- `./build-google-webrtc-local/plugins/google-webrtc/google-webrtc-jmi-wire-smoke`
- `meson compile -C build-google-webrtc-local main/dinox google-webrtc-engine-smoke google-webrtc-audio-only-smoke google-webrtc-wrapper-smoke`
- `./build-google-webrtc-local/google-webrtc/google-webrtc-wrapper-smoke &&
  ./build-google-webrtc-local/plugins/google-webrtc/google-webrtc-engine-smoke &&
  ./build-google-webrtc-local/plugins/google-webrtc/google-webrtc-jmi-wire-smoke &&
  ./build-google-webrtc-local/plugins/google-webrtc/google-webrtc-audio-only-smoke`
- `meson compile -C build main/dinox`

Next micro-slice:

- add local preview/camera capture as its own slice
- keep it behind the explicit Google/libwebrtc gate and do not route the old
  RTP/GStreamer video widgets into this path

### Slice 7: video send

Status: active; camera enumeration, first camera start/stop, local preview,
explicit camera selection/switching and video pause/resume plumbing are
implemented behind the Google/libwebrtc development gate. Live interop
validation is still pending.

Current progress:

- C ABI bumped to 23 for libwebrtc camera enumeration.
- The native wrapper exposes `dinox_webrtc_context_get_video_device_count()`
  and `dinox_webrtc_context_get_video_device_name()`.
- The Vala engine exposes `EngineContext.get_video_devices()` and
  `EngineVideoDeviceInfo`.
- Linux camera enumeration is linked through libwebrtc's own
  `modules/video_capture` implementation. This pulled in the expected
  GLib/GIO portal dependency, so the wrapper now links `gio-2.0` and
  `gio-unix-2.0`.
- Wrapper and engine smokes validate that camera enumeration is callable and
  can return zero devices without failing the libwebrtc path.
- C ABI bumped to 24 for local preview/camera capture control.
- The native wrapper exposes `dinox_webrtc_session_start_video_capture()` and
  `dinox_webrtc_session_stop_video_capture()`.
- Capture frames are fed into the existing libwebrtc local video track/source
  and are also emitted through a copied BGRA local-preview callback. This keeps
  the send path and GTK preview path on the libwebrtc boundary.
- `EngineSessionOwner`, `EngineJmiSession`, `PeerState` and
  `CallWindowController` now carry a separate `local_video_frame` signal chain.
  The call window uses a dedicated `LibwebrtcVideoWidget` for local preview and
  does not route preview frames through the old RTP/GStreamer `VideoCallWidget`.
- The wrapper smoke proves the local-preview callback with synthetic frames and
  validates invalid camera start/stop ABI arguments without depending on
  hardware.
- The engine smoke proves that a synthetic local preview frame reaches the Vala
  `local_video_frame` signal.
- Video-requested JMI sessions try to start the first available libwebrtc
  camera at 640x480/30fps. If no camera is available, the call path remains
  non-blocking and the failure is only logged under call debug.
- C ABI bumped to 25 for `dinox_webrtc_session_set_local_video_enabled()`.
- `EngineJmiSession` now stores pending local-video enabled state and selected
  camera before the wire session exists, then applies them when the libwebrtc
  Jingle session starts.
- The libwebrtc video button is visible for gated video calls and maps to
  libwebrtc video track/capture pause/resume. Turning video off stops camera
  capture and detaches the local preview widget; turning it back on restarts
  capture.
- `VideoSettingsPopover` can now be fed an explicit camera list, so the
  libwebrtc path shows libwebrtc cameras instead of querying the old
  GStreamer `VideoCallPlugin`.
- The JMI wire smoke proves pending video-off is applied to the native video
  track and that video can be re-enabled after the wire session exists.

Validation:

- `meson compile -C build-google-webrtc-local google-webrtc-wrapper-smoke
  google-webrtc-engine-smoke google-webrtc-jmi-wire-smoke main/dinox`
- `./build-google-webrtc-local/google-webrtc/google-webrtc-wrapper-smoke &&
  ./build-google-webrtc-local/plugins/google-webrtc/google-webrtc-engine-smoke &&
  ./build-google-webrtc-local/plugins/google-webrtc/google-webrtc-jmi-wire-smoke`

Next micro-slice:

- run live interop checks against Monal/Conversations/monocles for outgoing
  and incoming video calls
- harden any camera-permission or no-camera UI behavior seen in those checks
- keep the slice gated and keep the old RTP/GStreamer video widget path out of
  this implementation

Deliverables:

- camera capture
- local preview
- VP8-preferred send path
- no fixed-bandwidth send path; VP8 remains the default interoperability target
- camera pause/resume

Acceptance:

- DinoX can send and receive video in a 1:1 call
- weak mobile bandwidth reduces quality through libwebrtc adaptation instead of
  breaking the call
- device errors do not crash the call window

### Slice 8: call controls

Deliverables:

- microphone mute/unmute
- speaker/output handling
- camera switch
- audio/video pause
- volume controls where technically meaningful
- DTMF if supported by the chosen libwebrtc path

Acceptance:

- current UI controls have equivalent behavior or documented replacements

### Slice 8a: Audio/Video preferences backend boundary and device tests

Status: implemented on the feature branch; the native Linux device-test paths
are covered by a real-hardware smoke test, while live UI verification and
Windows build/runtime verification are still pending.

Problem statement:

- `Preferences -> Audio & Video` must not enumerate devices through
  `AudioVideoDeviceService`; that service is GStreamer-backed.
- The Google/libwebrtc call path already has its own microphone, speaker and
  camera device APIs through `JmiCallEnginePlugin`.
- The Google/libwebrtc media-message recorder already uses libwebrtc capture,
  so the preferences page must save libwebrtc device IDs that match the recorder
  and call engine on Linux and Windows.
- The old device test rows were GStreamer pipelines. They must not be shown in
  the libwebrtc settings UI. The replacement tests must use Google/libwebrtc
  paths only.

Target architecture:

1. The preferences page must ask the active backend for devices:
   - Google/libwebrtc call engine for call microphone, speaker and camera when
     the libwebrtc plugin is built and registered. Device preferences must not
     depend on the explicit call-runtime gate.
   - Google/libwebrtc media-message recorder for recording microphone and
     recording camera when that provider is registered.
2. Saved values must be backend-stable identifiers where possible:
   - libwebrtc rows save `MediaDevice.id`;
   - matching must accept both ID and display name during migration so existing
     user settings do not become dead.
3. GStreamer test rows must be removed from the libwebrtc settings UI.
   Replacement device tests use libwebrtc-native paths:
   - call speaker: audible libwebrtc context-level PCM test tone;
   - call/message microphones: short writerless WebRTC PCM capture against the
     selected `MediaDevice`, followed by automatic playback over the selected
     WebRTC speaker;
   - call/message cameras: WebRTC recorder live-preview check against the
     selected `MediaDevice`.
4. Linux and Windows must use the same libwebrtc-facing device model. No V4L2,
   PulseAudio, PipeWire, WASAPI, MediaFoundation or GStreamer device-specific
   branches should be added to this preferences page for the libwebrtc path.

Implementation slices:

1. Add optional device-enumeration methods to the media-message recorder
   provider boundary, so the preferences UI does not depend on
   `plugins/google-webrtc` internals.
2. Add Google/libwebrtc recorder device enumeration to
   `GoogleWebrtcMediaMessageRecorderProvider`.
3. Change `AudioVideoPreferencesPage` from display-only `Gtk.StringList`
   persistence to label/value choices, saving stable backend IDs while showing
   user-friendly names.
4. Prefer `JmiCallEnginePlugin` device lists for call rows and the recorder
   provider device lists for recording-message rows. A message-playback speaker
   row may only be shown after a libwebrtc playback provider owns that path; it
   must never be backed by a GStreamer output device.
5. Remove the existing GStreamer test rows from the libwebrtc settings UI.
6. Update call-window and call-state matching to preserve libwebrtc IDs instead
   of saving only display names.
7. Add a libwebrtc context-level speaker test-tone API, so the preferences
   page can test the selected output device without creating a call.
8. Add optional recorder-provider methods for creating audio/video recorder
   sessions against an explicit selected `MediaDevice`, so device tests do not
   mutate saved preferences or depend on plugin internals.
9. Reintroduce a `Device Testing` preferences section backed by the
   Google/libwebrtc call engine and recorder provider only.

Acceptance:

- Opening the Audio & Video preferences page with the libwebrtc plugin built
  shows libwebrtc microphone, speaker and camera choices for calls, even when
  the explicit call-runtime gate is disabled.
- Voice/video message recording rows use libwebrtc recording devices when the
  Google/libwebrtc recorder provider is active.
- Message playback speaker is shown only when the Google/libwebrtc playback
  provider is active and saves a libwebrtc device identifier.
- Selecting a libwebrtc device persists a value that later matches the same
  libwebrtc device by ID, with display-name compatibility for old settings.
- The preferences page does not contain or run GStreamer device tests.
- The preferences page does not use GStreamer playback as a substitute output
  for WebRTC microphone or speaker tests.
- The preferences page offers WebRTC-native tests for call microphone, call
  speaker, call camera, recording microphone and recording camera.
- Microphone tests must not create AAC/MP4 test media. Captured PCM is held only
  for the short playback, and both PCM plus any temporary placeholder file are
  discarded when playback finishes or the settings page closes.
- Starting a test disables parallel tests, cleans up temporary files and
  cancels active preview/recording sessions when the page is closed.
- The preferences page does not instantiate `AudioVideoDeviceService`.

Current implementation:

- `MediaMessageRecorderProvider` exposes optional recording-device enumeration.
- `GoogleWebrtcMediaMessageRecorderProvider` returns libwebrtc microphone and
  camera devices for preferences.
- `AudioVideoPreferencesPage` uses label/value choices, saves libwebrtc device
  IDs, keeps display-name compatibility for migration, and has no
  `AudioVideoDeviceService` dependency or GStreamer test rows. The message
  playback speaker row is supplied by `MediaMessagePlaybackProvider`.
- `AudioVideoPreferencesPage` now has a WebRTC-native `Device Testing` section:
  speaker test plays a libwebrtc-generated tone on the selected output, mic
  tests record three seconds of writerless WebRTC PCM and automatically play
  the usable clip back through the selected WebRTC speaker, and camera tests
  show a live preview through the WebRTC recorder preview path.
- `JmiCallEnginePlugin` exposes optional test-tone, PCM-test-playback and
  explicit test-playout-stop methods.
- Native wrapper ABI 32 adds bounded PCM test-clip playback and explicit test
  playout teardown. Both libwebrtc playout callback styles,
  `NeedMorePlayData()` and `PullRenderData()`, generate standalone test PCM even
  when no call audio delegate exists.
- `MediaMessageRecorderProvider` exposes optional explicit-device recorder
  creation methods, and the Google/libwebrtc provider implements them for
  microphone and camera tests.
- Camera testing uses a dedicated preview-only provider session. It starts
  libwebrtc camera capture without an MP4/H.264 writer and without microphone
  capture, so testing a camera does not depend on FFmpeg or audio-device state.
- Microphone testing uses a dedicated writerless provider session. The initial
  500 ms capture warm-up is excluded from playback, the remaining PCM is copied
  into a bounded in-memory test clip, and native libwebrtc handles output,
  channel mapping and the short test fade without a GStreamer player.
- The chat-input provider recorder backends accept an optional explicit device,
  preserving the same lifecycle/cancel/preview behavior for both real message
  recording and preferences tests.
- The native ADM wrapper remembers the selected audio devices. Re-selecting an
  already active device is a safe no-op, while an initialized but inactive
  playout/recording side is stopped before a real device change. Recorder start
  no longer overwrites the selected microphone with device index 0.
- `GoogleWebrtc.Plugin` registers itself as the call device provider even when
  the explicit call-runtime gate is disabled; only actual call start/incoming
  routing remains gated by `development_enabled()`.
- `CallState` and the libwebrtc call popovers match saved devices by ID,
  display name or detail name, preserving old settings while allowing stable
  libwebrtc settings.

Validation so far:

- `meson compile -C build-google-webrtc-local main/dinox`
- `meson compile -C build-google-webrtc-local`
- `meson test -C build-google-webrtc-local google-webrtc-wrapper-smoke
  google-webrtc-engine-smoke google-webrtc-signaling-smoke
  google-webrtc-jingle-engine-smoke google-webrtc-jingle-wire-smoke
  google-webrtc-jmi-wire-smoke google-webrtc-audio-only-smoke`
- The engine smoke also proves that the writerless microphone-test provider
  emits 48 kHz mono PCM and creates no media file.
- `meson compile -C build-google-webrtc-local google-webrtc-engine
  google-webrtc-jmi-wire-smoke google-webrtc-audio-only-smoke`
- `meson test -C build-google-webrtc-local --num-processes 1
  google-webrtc-engine-smoke google-webrtc-jmi-wire-smoke
  google-webrtc-audio-only-smoke --print-errorlogs --timeout-multiplier 4`
- `meson test -C build-google-webrtc-local "Tests for main" --print-errorlogs`
- `meson test -C build-google-webrtc-local "Tests for main UI runtime"
  --print-errorlogs`
- `DINOX_GOOGLE_WEBRTC_PLATFORM_DEVICE_TEST_SMOKE=1
  DINOX_WEBRTC_RECORDER_DEBUG=1 meson test -C
  build-google-webrtc-local google-webrtc-engine-smoke --print-errorlogs`
  validates repeated speaker selection plus the test tone and a preview-only
  camera capture against real Linux hardware. Audible output and microphone
  playback still require the interactive settings-page check.
- No-GStreamer surface check for the Audio/Video preferences Vala/UI files:
  no `Gst`, `GStreamer`, `AudioVideoDeviceService`, message playback speaker
  row or old device-test row IDs remain.

### Slice 9: interop matrix

Required clients:

- DinoX
- Conversations
- monocles
- Monal

Required cases:

- incoming audio call
- outgoing audio call
- incoming video call
- outgoing video call
- decline
- timeout
- reconnect
- ICE failure
- microphone missing
- camera missing
- multiple devices
- network switch

Acceptance:

- failures are classified as DinoX bug, remote client behavior or unsupported
  feature
- no known regression against the current released call behavior is left
  untracked

### Slice 10: package integration

#### Windows portability work order

The Windows port must use this order so that platform cleanup does not get
mixed with unverified artifact assumptions:

1. Before the first Windows artifact is available, keep changes
   platform-neutral only:
   - annotate the public C ABI for Windows DLL export/import;
   - use C++20 synchronization and time primitives in the native wrapper smoke;
   - require `gio-unix-2.0` only on Unix while retaining `gio-2.0` everywhere;
   - rebuild and run the Linux wrapper smoke after those changes.
2. Build the pinned M150 Windows artifact from the existing source checkout in
   a separate GN output directory. Do not overwrite the Linux artifact.
3. Use the actual Windows build output to define `.lib`, DLL and import-library
   staging. Do not guess final paths or library names before that proof.
4. Link the C ABI wrapper as a Windows DLL, connect the MSYS2-built plugin and
   bundle the DLL plus license files in `dist/`.
5. Validate Windows calls, device selection, media messages and teardown before
   selecting libwebrtc as the sole production call engine.
6. Only after Linux and Windows package/runtime gates pass, continue with
   Slice 11 and remove the old RTP/GStreamer call engine, migrate remaining
   non-call ICE/S5B helpers, and remove libnice plus the separate
   webrtc-audio-processing dependency.

Project-wide GStreamer removal is not part of the Windows call-engine port.
Media-file playback, metadata extraction and Windows notification sounds need
their own replacement because libwebrtc is not a general media-file player.

Deliverables:

- AppImage package contents
- Debian package contents
- Windows bundle contents
- Flatpak manifest strategy
- dependency update procedure
- explicit toolchain policy for wrapper-enabled builds or a prepared wrapper
  artifact model

Acceptance:

- package runtime checks know about the libwebrtc artifacts
- release builds are reproducible
- license/NOTICE files are included

### Slice 11: remove old live-call engine

Deliverables:

- remove old GStreamer RTP live-call code
- remove obsolete ICE/DTLS/SRTP call-only code if no other feature uses it
- remove obsolete WebRTC bridge attempts
- update docs and build dependencies

Acceptance:

- DinoX has one production live-call engine
- GStreamer remains only for file demux/decode, playback, metadata and
  thumbnails
- no stale "temporary" call path remains

### Slice 12: MUJI/group calls

Deliverables:

- evaluate MUJI support with libwebrtc
- implement only after 1:1 calls are stable

Acceptance:

- group-call behavior is not allowed to destabilize the 1:1 call baseline

### Slice 13: freeze the media-engine baseline and audit lifecycle ownership

Status: completed on 2026-07-11 on the Linux M150 development build.

Completion evidence:

- fixed the Chromium `clang++` driver configuration so C++ compilation and
  linking use the same reproducible wrapper
- added explicit call/recorder activity leases and deferred context close
- kept one plugin context alive instead of creating a second platform ADM
  after the final call while recorders/tests may still be active
- added session and recorder callback/teardown barriers for raw C-ABI
  `user_data` lifetime
- added opt-in lifecycle timing with
  `DINOX_GOOGLE_WEBRTC_LIFECYCLE_DEBUG=1`; normal runs remain quiet
- added 100-cycle session/recorder lease stress coverage and concurrent
  callback-versus-close/cancel regression tests
- serialized plugin context creation/shutdown and protected `EngineContext`
  leases so background Preferences device discovery cannot race final shutdown;
  a four-thread device-enumeration-versus-close regression test proves the
  defined `CLOSED` result and zero leaked leases
- the six focused wrapper/engine/Jingle/JMI smokes pass; the JMI smoke also
  passed five consecutive standalone repetitions

Execution rule for Slices 13-25:

- complete one slice and its acceptance checks before changing the next layer
- perform an implementation review and a separate lifecycle/security audit on
  every slice that changes ownership, IPC or teardown
- fix every reproducible bug in the touched audio/video path in the same slice
  and add a regression test
- record genuinely unrelated findings separately instead of mixing broad
  cleanup into the worker migration
- keep all new behavior behind the feature branch/build gate until the final
  Linux and Windows cutover criteria pass

Deliverables:

- record the passing Linux audio-call, video-call, DTMF, device-test and
  media-message-recorder smoke commands
- inventory every synchronous C-ABI operation and its expected owning thread
- add targeted timing around context creation, device operations, session
  create/close, camera start/stop and context destruction
- map every context consumer: active calls, recorder provider, audio recorder,
  video recorder, speaker test, microphone test, camera test and settings
  device refresh
- replace the implicit `sessions.is_empty` context-lifetime assumption with
  explicit activity leases
- audit callback `user_data`, signal handler IDs, timers and Vala object
  references for late-callback use-after-free hazards

Side-bug gate:

- reproduce or add a regression test for ending the final call while a
  recorder or device test still owns the context
- test call end during ICE gathering, device refresh and camera startup
- test recorder cancellation while a call is active
- fix discovered lifecycle bugs in the touched path before starting Slice 14

Acceptance:

- the baseline behavior is documented and repeatable
- no context is destroyed while any lease exists
- 100 repeated context/session/recorder lifecycle cycles complete without a
  crash, stale callback or leaked activity lease
- normal builds remain free of unconditional call-diagnostic output

### Slice 14: introduce a typed engine command/event boundary

Status: completed on 2026-07-11.

Implemented foundation:

- fixed 48-byte little-endian frame header
- protocol magic/version, typed message IDs and strict flag validation
- request, session and generation IDs
- 1 MiB bounded control payload
- malformed, truncated, oversized, unknown and stale-frame tests
- one protocol shared by the Linux worker and the future Windows named-pipe
  transport
- handshake identity comes from the pinned compile-time constants, so the
  standalone IPC target has no accidental link dependency on the wrapper DLL

Deliverables:

- define platform-neutral commands for context, devices, sessions,
  descriptions, candidates, tracks, DTMF, recorders and tests
- define replies and events with request IDs, session IDs and generation IDs
- separate signaling data from media-frame transport
- define cancellation and timeout semantics for every blocking operation
- keep the current public plugin behavior while routing native operations
  through the new boundary

Acceptance:

- no GTK or XMPP object crosses the engine boundary
- unit tests reject unknown commands, oversized data, stale generations and
  replies for cancelled requests
- existing live-call and recorder tests pass unchanged

### Slice 15: serialize native ownership on an in-process executor

Status: completed on 2026-07-11. The serial executor remains test coverage for
ordering and shutdown semantics but is no longer linked into the production
wrapper. Production ownership is serialized by the external worker; ordinary
session and recorder commands are one-way and do not block the GTK thread.

Deliverables:

- add one serial control executor that owns native context/session operations
- convert Vala entry points to asynchronous completion on the GTK main context
- keep libwebrtc's own network, worker and signaling threads unchanged
- ensure native creation and teardown occur on the documented owner
- add a shutdown barrier that invalidates late callbacks before releasing
  callback state

Side-bug gate:

- review all call buttons, incoming-call cancellation and window close paths
  for double-close or duplicate command submission
- review device changes during active capture and calls
- review application shutdown with an active call, recorder or device test

Acceptance:

- opening settings, refreshing devices, starting/ending a call and stopping a
  recorder do not block the GTK main loop
- ordering tests cover create-close, close-before-create-completes,
  device-change-close and shutdown-with-pending-request
- ThreadSanitizer/AddressSanitizer runs are clean where the M150 build permits
  them; otherwise equivalent generation and stress tests are mandatory

### Slice 16: build the external worker and control IPC

Status: completed for Linux and implemented for Windows on 2026-07-11. The
installable worker, Unix socket-pair and Windows named-pipe transports,
mandatory handshake, bounded protocol, supervision, timeout, reaping and fault
injection tests are present. Native Windows artifact execution remains part of
Slice 24 acceptance.

Deliverables:

- add a `dinox-webrtc-worker` executable that links the existing native
  wrapper and pinned libwebrtc artifact
- implement the framed binary protocol and Linux local transport
- implement handshake, context/device/session control and clean shutdown
- supervise one worker per DinoX process
- add worker startup timeout, request timeout and process reaping
- retain the direct in-process transport only as a test oracle until parity is
  proven; it must not become a runtime fallback

Security and robustness tests:

- protocol-version and artifact-revision mismatch
- malformed header, oversized payload, truncated message and unknown type
- worker exit during request, worker hang and DinoX exit during worker reply
- confirm logs redact SDP secrets, ICE passwords and TURN credentials

Acceptance:

- a synthetic audio session can be created and closed entirely through IPC
- killing the worker does not crash or freeze DinoX
- no zombie worker remains after normal or abnormal DinoX shutdown

### Slice 17: route audio calls, devices and DTMF through the worker

Status: completed on Linux on 2026-07-11. Audio capture/playout, device
selection, DTMF, local feedback and device tests execute in the worker. No
audio samples cross IPC. Worker crash/hang recovery is covered by the process
smokes; the previously completed Monal live matrix remains the interop
baseline.

Deliverables:

- move offer/answer application, ICE, audio track state, mute, speaker and
  microphone selection, DTMF and local DTMF feedback to worker commands
- keep audio capture, processing and playout exclusively in the worker
- expose bounded diagnostics snapshots instead of unrestricted log streaming
- route speaker and microphone tests through the same device ownership model

Side-bug gate:

- repeat incoming/outgoing Monal calls, two sequential calls and rapid
  accept-end-redial
- test missing/default/changed audio devices and device disappearance
- test DTMF during teardown and repeated dial-pad presses
- verify OMEMO fingerprint gating remains in the DinoX process and unchanged

Acceptance:

- Linux audio interop matches the frozen baseline
- worker crash results in one visible call failure, released devices and a
  usable next call with a newly started worker
- no audio samples or per-10-ms audio messages traverse IPC

### Slice 18: route video through bounded shared memory

Status: Linux implementation reopened for live Monal regression work on
2026-07-11; implemented but not yet live-accepted for Windows. Local preview
and remote BGRA frames use a bounded shared-memory ring v5 with generation,
metadata and atomic per-slot ownership validation; GTK consumes frames only on
its main context. Full Windows worker execution remains in Slice 24.

The 2026-07-11 live Monal regression audit found that the remote video sink was
still installed as a side effect of `session_get_state()`. Calls without debug
queries therefore decoded video without forwarding it to the UI. A first live
retest showed that a post-description scan was still too early for Monal. Sink
attachment now uses libwebrtc's Unified Plan `PeerConnectionObserver::OnTrack`
callback, which fires when the receiving track is actually created;
`session_get_state()` no longer mutates the media path. The direct M150 oracle
and the external-process smoke both require bidirectional remote frames before
the first diagnostics query; the process test covers the shared ring as well as
the wrapper callback.

The following Monal traces isolated two independent frame losses below
decoding. First, portrait frames were rejected by a height limit. A later live
trace then showed Monal actually delivering `1344x1792`: ring v3 allowed those
dimensions but still allocated only `1920x1080x4` bytes per slot, so every such
frame was rejected by the payload-size guard. Ring v4 now makes the dimension
limits and actual slot capacity consistent at `1920x1920x4`. Second, the writer
released a slot before the proxy consumed its IPC event, allowing simultaneous
local and remote producers to overwrite unread frames. Slots now follow the
strict bounded lifecycle `free -> writing -> ready -> reading -> free`.
Ordered recorder traffic and an unmatched full ring drop the new frame instead
of invalidating an event already in flight; live call streams use the safe
same-stream replacement policy described below.
Closed or missing sessions explicitly release their unread slots. The raw-ring
test covers full-ring backpressure and the exact `1344x1792` Monal frame. The
external-worker process smoke injects that source size and verifies the bounded
render-frame result described below. Live Monal acceptance is still pending.

A subsequent live regression trace showed a separate pacing problem: before
the process cutover, the remote sink delivered roughly 122-131 frames in the
first ten seconds at `504x672`; the worker build delivered only 19-32 sink
frames while Monal supplied `1344x1792`. Passing such a frame as BGRA costs
about 9.2 MiB before the additional shared-memory, proxy and Vala copies. The
ring therefore now treats call preview and remote-render frames as
latest-frame-wins mailboxes: a newer unread frame for the same stream replaces
the older ready slot, while recorder frames remain ordered and never use this
replacement policy. The native render callback also scales
oversized decoded I420 frames to an aspect-ratio-independent `640x480` pixel
budget before BGRA conversion, reducing the observed `1344x1792` portrait case
to `480x640`; raw ring support for full portrait frames remains covered. Vala
transfers its owned frame copy into `GBytes` instead of copying the complete
frame again. Worker flow counters are emitted only with
`DINOX_GOOGLE_WEBRTC_CALL_DEBUG=1`. The process-engine and raw-ring tests cover
the scaling, replacement, stale-event and ordered-recorder contracts; live
Monal smoothness remains the acceptance gate.

The 2026-08-02 Windows effects retest exposed a later ring-v4 control-path
regression: each same-stream replacement still emitted a new exact-sequence
event. Local preview and Remote video share the ring, control pipe and serial
proxy reader, so returning from `Grayscale` to `Off` restored the full local
preview rate and could build an unbounded queue of already stale tokens. The
outgoing encoder remained smooth because it receives the camera frame before
the local-preview IPC path. Ring v5 turns those events into real mailbox
wake-ups. Its atomic slot state includes the exact notification token, a
replacement preserves that token, and the worker emits no duplicate event. If
the proxy consumes the token while the replacement is in progress, an atomic
handshake publishes exactly one follow-up token. Exact-token state transitions
also prevent Local, Remote and Recorder from claiming foreign or reused slots.
IPC protocol 6 rejects a ring-v4 worker before media starts. The ring smoke
covers 256 single-stream replacements, 1024 interleaved Local and Remote
replacements, deterministic consume/discard races during replacement,
concurrent dual-stream delivery, bounded notification depth and final full-slot
closure. A second worker is not required for this control-path correction.

Deliverables:

- implement a fixed-slot shared-memory frame ring for remote and local preview
- preserve the current BGRA byte contract between the native engine and GTK
  for the first worker implementation; format changes require their own
  measured copy/CPU comparison
- include generation, dimensions, stride, pixel format, frame ID and slot
  sequence in validated frame metadata
- use bounded drop-on-full backpressure; never overwrite a frame referenced by
  an unread IPC event
- move camera start, selection, pause/resume and stop into the worker
- keep GTK texture creation and widget updates on the main context

Side-bug gate:

- audit first-preview warmup, call teardown during a frame callback, camera
  switching and remote resolution changes
- test invalid metadata, worker death while a slot is mapped and UI window
  close while frames are arriving
- count copies and ensure extraction does not add an unbounded frame queue

Acceptance:

- incoming and outgoing Monal video calls match the frozen Linux baseline
- slow/minimized/closed UI consumers do not grow memory
- stale frames from an old session generation never appear in a new call

### Slice 19: migrate recorders, device tests and settings to worker ownership

Status: completed on Linux on 2026-07-11. Recorders and device tests use the
worker, device enumeration is asynchronous, and stale refresh generations are
discarded. The old main-process GStreamer voice-message noise-suppression
library is no longer built in the Google/libwebrtc release profile.

Deliverables:

- move libwebrtc audio/video message recorder operations behind IPC
- move microphone, speaker and camera tests behind IPC
- make device refresh asynchronous and share one device catalog with calls,
  recorders and tests
- implement explicit call/recorder/test leases; keep the process/context
  long-lived until plugin/application shutdown while releasing active capture
  resources after the final operation (an idle process restart loop would
  recreate the lifecycle churn this migration removes)
- remove all direct `EngineContext` access from GTK/settings and recorder
  provider code

Side-bug gate:

- test simultaneous call plus attempted recorder/test and define deterministic
  busy behavior where hardware cannot be shared
- test final call ending while recorder/test is active
- test first and second video recording, cancellation and application shutdown

Acceptance:

- the context is not repeatedly destroyed/recreated between ordinary media
  operations
- settings and recorder behavior remains GStreamer-free
- no native libwebrtc handle remains owned by the DinoX process

### Slice 20: harden worker recovery and make process mode the only engine path

Status: completed for the production Linux runtime on 2026-07-11. Process mode
is mandatory. The in-process path is compile-gated by
`-Dgoogle-libwebrtc-test-oracle=true`, defaults off, and is unavailable in
release artifacts. Crash/hang injection is test-only and repeated failures do
not trigger an active-call restart loop. The former internal-worker environment
variable is ignored by the parent process; only the worker's process-local C
bootstrap can select direct ownership, and the process smoke covers this bypass
attempt.

Live-call diagnostics are non-destructive: `SESSION_STATE_GET` has a bounded
500 ms client deadline and a late diagnostics reply cannot kill an otherwise
working media process. The production watchdog remains fatal for control
commands that must complete. Worker exit reporting now preserves the timed-out
message type or native exit signal/code, and the reader reaps a terminated Unix
worker before reporting the active-call failure. Process tests cover delayed
diagnostics recovery plus absence of waitable/running child processes after
both abort and hang injection.

The recovery audit also marks the transport stopped immediately after a failed
control write and cancels the blocked reader. A later operation therefore
starts a clean worker instead of spending another full watchdog interval on a
half-dead transport. Event dispatch validates status/SDP enums, candidate
bounds, recorder PCM metadata, empty state-event payloads and embedded NULs.

Deliverables:

- add crash injection and hang injection available only in test builds
- finalize watchdog, shutdown and error mapping
- add bounded restart policy: restart for the next operation, never loop during
  an active failure
- collect only bounded counters and final failure reason in production
- remove the in-process runtime transport after parity and fault gates pass

Acceptance:

- forced abort, segmentation fault simulation and deadlock timeout in the
  worker do not terminate or permanently block DinoX
- active UI state is closed exactly once and input devices are released
- repeated worker failures do not create a restart storm
- audio, video, recorders and device tests have one production engine path

### Slice 21: implement the Opus low-bandwidth policy in the wrapper

Status: completed on 2026-07-11. Low-bandwidth sessions reject video, apply a
typed 16 kbit/s sender cap and adaptive packet duration to the negotiated Opus
sender, and expose policy, target bitrate and RTP counters through diagnostics.
Arbitrary negotiated Opus payload IDs are covered by regression tests.

Deliverables:

- add an explicit `Automatic` / `Low bandwidth (2G)` session policy to the
  command protocol and native wrapper
- make low-bandwidth sessions audio-only before transceiver creation
- obtain the negotiated audio sender and apply a 16 kbit/s maximum through
  typed M150 RTP sender parameters
- enable adaptive packet duration where supported by the pinned artifact
- expose applied mode, cap, actual target bitrate and outbound byte/packet
  counters in diagnostics
- return a hard error if the policy cannot be applied; never claim 2G mode
  while silently running the automatic profile

Tests:

- parameter application before and after local description
- negotiated Opus payload ID other than 111
- no audio sender, multiple transceivers, closed sender and failed
  `SetParameters()`
- prove that `Automatic` produces the existing offer and behavior
- prove that low-bandwidth mode creates no video sender/capture

Acceptance:

- sender diagnostics show the 16 kbit/s cap and Opus remains dynamically
  adapted below it
- debug UI continues to show `opus/48000` while separately showing the actual
  bitrate policy and measured bitrate
- no raw SDP replacement or payload-ID constant is introduced

### Slice 22: extend structured Jingle/SDP policy and settings UI

Status: completed on 2026-07-11. Typed Jingle parameters advertise mono, DTX,
in-band FEC and receiver bitrate constraints, the persisted Audio/Video setting
offers Automatic and Low bandwidth (2G), and 2G mode prevents video initiation.
German strings are updated without mass PO churn.

Deliverables:

- extend the existing typed Opus parameter allowlist, parser and serializer
  tests for the chosen standard low-bandwidth parameters
- advertise mono, DTX and receiver bitrate/bandwidth preferences without
  confusing them with the local sender cap
- add `Call network mode` to Audio/Video settings:
  - `Automatic`
  - `Low bandwidth (2G, audio calls only)`
- explain that changing mode affects new calls
- disable or clearly redirect video-call initiation while 2G mode is active
- add gettext strings without unrelated PO churn

Interop tests:

- remote ignores all optional Opus parameters
- remote supports only a subset of parameters
- remote offers an arbitrary valid Opus payload ID
- Monal, Conversations and monocles offers round-trip without losing accepted
  parameters

Acceptance:

- default `Automatic` UI and signaling remain backward compatible
- 2G mode cannot accidentally start camera capture or advertise video
- user-visible mode matches the policy reported by worker diagnostics

### Slice 23: validate constrained-network behavior and tune from evidence

Status: automated policy coverage and the reproducible Linux shaping harness
are complete. `scripts/test-libwebrtc-constrained-network.sh` applies symmetric
constrained, harsh and burst-loss profiles, supports a restored short outage,
and records `tc`, interface and DinoX diagnostic output. Live intelligibility
and TURN measurements with Monal/Conversations remain an explicit manual
acceptance gate; no unmeasured codec tuning has been added.

The harness keeps only `tc` setup/cleanup privileged. Its `run` mode drops back
to the original sudo user before starting DinoX, so GTK, PipeWire/PulseAudio,
camera access and the user profile are not accidentally tested as root.

Linux network profiles must include at least:

- constrained EDGE-like: 64 kbit/s each direction, 400 ms RTT, 80 ms jitter,
  3 percent loss
- harsh EDGE-like: 40 kbit/s each direction, 700 ms RTT, 150 ms jitter,
  8 percent loss
- burst loss and short network interruption
- direct ICE and TURN-relayed variants

Deliverables:

- reproducible `tc netem`/rate-limiting test script kept local or in dedicated
  test tooling, not normal runtime code
- measurements for encoded audio bitrate, total wire bitrate, RTT, jitter,
  packet loss, concealment, DTX silence traffic and reconnect behavior
- compare adaptive packet duration against fixed 20, 40 and 60 ms in the test
  harness only
- retain or change production packetization/FEC policy only from the measured
  result
- manual live matrix with Monal and monocles/Conversations; do not require two
  DinoX desktop instances from the user

Acceptance:

- speech remains intelligible in the constrained profile without call-state
  failure or unbounded latency growth
- the harsh profile fails gracefully if the link cannot sustain secured RTP
  overhead
- active-speech wire usage and silence usage are reported separately
- Automatic-mode quality and normal Wi-Fi/4G interop do not regress
- every tuning change has a before/after measurement and regression test

### Slice 24: port worker IPC and low-bandwidth mode to Windows

Status: automated Windows artifact, plugin and package acceptance completed on
2026-07-11; the hardware-backed Windows/Monal live gate passed on 2026-07-12.
Named pipes use overlapped I/O on both sides, named shared mappings carry video
rings, a Job Object contains the worker, and the worker initializes WinSock
before creating libwebrtc network threads. The pinned M150 DLL, worker, MinGW
import library, native smokes and notices are staged as a self-contained
runtime. The Vala bindings declare context, session and recorder handles
through an external VAPI, so native objects are destroyed by the wrapper DLL
instead of MinGW-generated local free functions crossing the MSVC/MinGW heap
boundary. Windows Media Foundation M4A/AAC-LC and MP4/H.264 Constrained
Baseline plus AAC-LC writer output has also passed a native Windows 11 smoke
and `ffprobe` validation.

Windows 11 VM evidence for the current implementation:

- native IPC protocol, shared-video-ring and external-process engine smokes:
  3/3 pass
- DinoX Media Foundation, engine, signaling, Jingle, JMI and audio-only Meson
  smokes: 7/7 pass; the former access violations and heap corruption are gone
- `google-webrtc.dll` imports the wrapper DLL and its three native handle
  destructors; it does not define substitute Vala destructors
- the staged `dist/` contains the wrapper DLL, worker executable, plugin and
  license/PATENTS/manifest files and starts far enough to report
  `DinoX 2.2.1` through the packaged executable
- the staged bundle contains neither `rtp.dll` nor GStreamer RTP, SRTP, DTLS,
  WebRTC or NICE live-call plugins
- the final hardware gate passed with bidirectional Windows audio/video calls,
  media-message recording/playback and repeated recorder teardown against Monal

Windows live-test follow-up on 2026-07-11:

- M150's modern Windows Core Audio ADM exposes microphone and speaker volume
  setters as no-ops. DinoX therefore keeps the sliders application-local and
  applies their gain to the 16-bit PCM crossing the libwebrtc `AudioTransport`
  boundary. It does not change the global Windows endpoint volume.
- standalone speaker and microphone-playback tests select libwebrtc's Windows
  `kDefaultDevice` before initializing playout or recording. This removes the
  `not-ready` path caused by starting a fresh test context without a selected
  default device.
- Windows audio/video-message encoding uses Media Foundation exclusively. The
  UI availability probe now asks the same Windows writer factory instead of
  checking for a system `ffmpeg`, and the Linux system-FFmpeg writers are not
  compiled into the Windows plugin.
- the Windows engine smoke asserts that the default AAC/M4A and MP4/H.264
  writers are available and that the recorder provider exposes the Media
  Foundation video writer without `ffmpeg`. The rebuilt VM passes the complete
  7/7 Windows Meson matrix and all three native runtime smokes.
- the staged `dist/` release gate rejects a Windows plugin containing the
  system-FFmpeg failure path and requires the AAC/M4A decoder-to-appsink
  elements (`qtdemux`, `avdec_aac`, `audioconvert`, `audioresample`, `appsink`).
  The external Google/libwebrtc worker owns the speaker output.
- the final hardware run used the freshly rebuilt `dist/dinox.exe`: incoming
  and outgoing audio/video calls work against Monal, and audio/video messages
  record, send and play through the selected libwebrtc devices
- each production Windows message recording now owns a short-lived external
  libwebrtc context. This isolates repeated Core Audio capture startup from the
  long-lived call/playback worker without adding a second media backend
- repeated product-path coverage completed 20/20 audio-message recordings and
  5/5 video-message recordings with audio; the startup envelope is now 250 ms
  muted plus a 50 ms fade-in

Deliverables:

- named-pipe control transport with the same protocol and semantics
- safe worker executable discovery and spawning from the packaged DinoX tree
- Windows shared-memory/handle transfer for video rings
- worker job/process lifetime tied to DinoX so abnormal exit leaves no worker
- bundle worker, wrapper DLL, pinned artifact and license/NOTICE data
- repeat Automatic and 2G audio tests plus video, recorders and device tests

Acceptance:

- protocol fixtures are byte-identical across Linux and Windows
- worker crashes do not terminate DinoX on Windows
- packaged Windows builds require no external libwebrtc installation
- no direct GStreamer live-call path is reintroduced as a Windows fallback

### Slice 25: final cutover and cleanup

Status: Linux cleanup and package integration, automated Windows artifact and
package gates, and the Windows/Monal hardware gate are completed;
constrained-network gates remain. Production package profiles disable the old
RTP plugin and omit
GStreamer RTP/DTLS/SRTP/WebRTC/NICE call plugins and the standalone
webrtc-audio-processing runtime. GStreamer remains only for media-file
demux/decode, playback, metadata and thumbnails. libnice remains because the
separate legacy ICE plugin still provides local-address discovery and
Tor/SOCKS5 policy hooks to direct Jingle-S5B file transfer; Google/libwebrtc
owns call ICE/STUN/TURN.

The cleanup also hardened the static release gate for pre-commit deletion
reviews: shell and hidden-Unicode discovery now skip tracked paths that are
already absent from the worktree. Removing the obsolete audio-processing files
therefore no longer creates a false syntax-check failure before the deletion is
committed. The complete static gate passes 21/21 checks.

Current Linux acceptance evidence:

- source-wrapper matrix: 13/13 Google/libwebrtc tests pass
- prebuilt release-runtime matrix plus GTK call controls: 9/9 tests pass
- crash/hang recovery and ring concurrency stress: 25/25 repetitions each
- staged install contains wrapper, worker, plugin and notices and contains no
  legacy `rtp.so`
- Linux and Windows identify the framed handshake and prepared artifact as
  `dinox-libwebrtc-runtime-v2`; the stale Linux development identity
  `dinox-libwebrtc-proof-v1` has been removed
- deterministic Linux runtime SHA-256 after unifying the Linux and Windows
  handshake identity on `dinox-libwebrtc-runtime-v2` and adding the generated
  transitive WebRTC dependency license inventory:
  `de6241a78b33d9b324d9315e874bc6dc484d2d8726f899b9f5011eceb32af9e6`
- the current Warm-tone video-effects generation preserves all historical
  runtime assets and advances the feature branch to ABI 37 / IPC 7 /
  video-ring 5. Both immutable runtimes are built from the clean DinoX source
  commit `ebe6374b52355e3ff12a952c0db6f63902fd3d65`. The Linux runtime SHA-256
  is `f36f2596cb05e34bf7c28023d7fb6b36c15b2e1900858d9e0464dfbc3d8817c9`;
  the Windows runtime SHA-256 is
  `9183260f736203c85b0bf3c3fe1db54b09a55870cd879970adb71a6fa0b385be`
- the Windows VM passes the ABI 37 / IPC 7 native IPC, video-ring and process
  smokes plus the formal Warm-tone performance profile. Updating and testing
  the portable Windows product distribution is still pending. The previous
  portable distribution built from
  `04da4c363b0a5c3b6164f72af0b831a2d45d7305` passes the complete 288-PE-file
  runtime and license gate; the interactive Windows effect UI remains a manual
  acceptance step
- complete static release gate: 21/21 checks pass
- post-worker Monal regression gate: bidirectional remote video arrives before
  any diagnostics query in both the direct M150 oracle and the external worker
  process smoke; delayed diagnostics are non-fatal, abort/hang leave no zombie,
  and the active-popover GTK runtime test passes with fatal warnings enabled

Deliverables:

- remove transitional in-process executor transport and obsolete direct C-ABI
  access from the plugin
- update package manifests, dependency diagnostics and architecture docs
- review old live-call/GStreamer/libnice/webrtc-audio-processing removal against
  all remaining non-call consumers before deleting dependencies
- final developer review followed by separate lifecycle, IPC, security,
  interop and packaging audit

Acceptance:

- one external libwebrtc worker is the only production audio/video engine
- Automatic and low-bandwidth audio use the same Opus/libwebrtc pipeline
- no known touched-path side-effect bug remains without a regression test or
  an explicit tracked blocker
- Linux and Windows release packages pass the complete media matrix

### Slice 26: Linux VP8 hardware decoding with CPU encoding

Historical acceptance: three configure/decode/release cycles of one solid-colour
320×240 key frame passed on the local Intel HD Graphics 530. That established
basic decoding, not stable real conversations or a performance advantage. The
original production factory probed `VAProfileVP8Version0_3` plus `VAEntrypointVLD`
and selected VA-API before libvpx. That profile-only decision has been
superseded by the qualification below.

Current follow-up: first-use VP8 qualification additionally decodes synthetic
key/delta sequences at 640×480 and 1280×720, verifies usable I420 output against
software and rejects clearly worse full decode/transfer latency. The result is
worker-local, with independent encoder selection and existing runtime software
fallbacks. Querying codec support does not start GPU work. See
[focused diagnostics](DEBUG.md#current-focused-diagnostic-switches) and
[native tests](TESTING.md) for the current checks and their limits.

The qualified Linux runtime was built from clean DinoX commit
`41db6217bde34446dc44773ce2c17b02a654d22f`. Its wrapper and worker passed the
release staging gate. The archive and checksum are published under `vendor-deps`;
all package and source-build consumers pin the new content-addressed asset. WebRTC M152,
FFmpeg and the offline Vision inputs are unchanged. The original M150
architecture notes below are historical.

Architecture:

- libwebrtc remains the call engine and owns codec negotiation, RTP, jitter,
  bandwidth adaptation and decoder lifetime.
- DinoX supplies a Linux `VideoDecoderFactory`, which is the supported
  libwebrtc boundary for a platform decoder.
- Hardware acceleration is receive-only. `CreateBuiltinVideoEncoderFactory()`
  is unchanged, so VP8 encoding remains on the CPU through libwebrtc/libvpx.
- Hardware availability is decided from the runtime VA-API profile and
  entrypoint, never from GPU model names.
- The pinned decoder dependency is FFmpeg 8.1.2 reduced to the VP8 decoder and
  VP8 VA-API hwaccel. It is built LGPL-only and shipped as private dynamic
  `libavcodec.so.62` and `libavutil.so.60` sibling libraries; it contains no
  encoder and no H.264 decoder.
- The M150 artifact build sets `rtc_use_h264=false` and
  `proprietary_codecs=false` explicitly. The VP8 smoke rejects an artifact if
  either its encoder or decoder factory advertises H.264.
- FFmpeg is compiled against pinned libva 2.20 headers so the artifact works on
  the Ubuntu 24.04 baseline and newer compatible libva runtimes. The host still
  supplies the actual Intel, AMD or other VA-API driver.
- VA-API NV12 output is transferred to an I420 libwebrtc frame for the existing
  worker/shared-ring/GTK rendering boundary. This avoids changing the tested
  worker IPC and UI frame ownership in the same slice.
- If capability probing, device creation, decoding or frame transfer fails,
  libwebrtc's `VideoDecoderSoftwareFallbackWrapper` switches to its built-in
  VP8 decoder. No GStreamer call fallback is introduced.

Release and license boundaries:

- the artifact and runtime carry the FFmpeg LGPL and libva MIT notices plus a
  machine-readable dependency manifest
- Deb and AppImage require and bundle the libva core/DRM loader; GPU drivers
  remain host-provided
- Flatpak uses the platform VA-API runtime and its existing device permission
- `DINOX_WEBRTC_DISABLE_VP8_HW_DECODER=1` forces the software path for triage
- `DINOX_WEBRTC_VP8_DECODER_DEBUG=1` prints only focused capability, selection
  and fallback diagnostics; normal calls do not emit per-frame decoder logs

Acceptance:

- the generated VP8 fixture decodes as 320x240 through both libvpx and VA-API
- repeated calls release VA surfaces and decoder contexts cleanly
- a machine without VP8/VLD continues with the built-in software decoder
- outgoing VP8 is still CPU encoded and H.264 remains disabled
- the wrapper resolves its dynamic `libavcodec.so.62` and `libavutil.so.60`
  dependencies only from the packaged sibling runtime, and exports no FFmpeg
  symbols itself
- the complete Google/libwebrtc worker/Jingle regression matrix passes 15/15

### Slice 27: preserve RTP header extensions across SDP and Jingle

Status: implemented on 2026-07-11; focused bridge and worker/Jingle tests pass,
with live Monal startup-pacing revalidation pending.

The startup-pacing diagnostics proved that direct host-to-host Wi-Fi received
only roughly 2-4 remote video frames per second during the first 10-15 seconds
despite zero packet loss, 5-7 ms RTT, 8-16 ms VP8 decode time and no worker-ring
or GTK drops. The SDP fixture already contained transport congestion-control
and absolute-send-time header extensions, but the bridge deliberately tolerated
and discarded every `a=extmap` line. It consequently advertised RTCP
`transport-cc` feedback without preserving the RTP transport sequence-number
extension required to drive that feedback path.

Implementation:

- map SDP `a=extmap` to XEP-0294 `<rtp-hdrext/>` and back
- preserve extension IDs, send/receive direction and extension parameters
- map session-level `a=extmap-allow-mixed` to each Jingle RTP description and
  consolidate it again when rebuilding SDP
- advertise `urn:xmpp:jingle:apps:rtp:rtp-hdrext:0` through service discovery
- keep the mapping role-aware so initiator/responder `senders` values become
  the correct local SDP direction
- expose the mapped Jingle extensions and libwebrtc's active RTP sender and
  receiver extension maps only under `DINOX_GOOGLE_WEBRTC_CALL_DEBUG`

Automated evidence:

- the libwebrtc fixture preserves audio-level, absolute-send-time and
  `extmap-allow-mixed` through SDP and typed Jingle
- role-aware XEP-0294 senders and extension parameters round-trip
- the native loop proves transport-wide congestion control and
  absolute-send-time are present in active libwebrtc `RtpParameters`
- the focused bridge suite passes 29/29 and the engine, Jingle, wire, JMI and
  external-process smoke selection passes 5/5

Live acceptance:

- repeat one bidirectional Monal video-call sequence with the focused startup
  log enabled
- verify the remote offer/answer contains XEP-0294 extensions and the active
  video receiver includes transport-wide congestion control or
  absolute-send-time
- compare the first 3, 10 and 15 second inbound FPS/bitrate snapshots against
  the pre-fix direct-Wi-Fi baseline
- if startup remains slow, retain this standards fix and continue from measured
  sender adaptation state; do not compensate with fixed bitrates or GTK frame
  duplication

### Slice 28: unify audio/video-message playout with the libwebrtc speaker

Status: implemented and Windows live-accepted on 2026-07-12. Chat media files
are still demuxed/decoded by GStreamer, but decoded PCM now crosses a bounded,
batched IPC bridge to the selected Google/libwebrtc speaker in the external
worker. Audio messages, video-message audio and recorded-message test playback
share that provider; no GStreamer/WASAPI output sink remains in these paths.
Focused bridge, worker, plugin and repeated Windows product-path tests pass.

The decoder and the audio device have separate responsibilities. GStreamer may
continue to demux and decode interoperable M4A/MP4 media files to raw PCM and
video frames. It must not select or open the playback device. Decoded PCM from
both audio and video messages must be sent through a neutral DinoX playback
provider to the existing external libwebrtc worker. The worker owns playout and
uses the visible, persisted `msg_audio_output_device` selection. Calls keep
their separate `call_audio_output_device`; both rows enumerate the same
libwebrtc device model and neither opens a second OS audio backend.

Deliverables:

- add a neutral `MediaMessagePlaybackProvider` and playback-session interface
  to the plugin boundary; main/UI code must not depend on Google plugin types
- add a bounded worker-owned PCM queue with explicit start, push, pause, flush,
  finish and stop lifecycle operations
- batch PCM IPC traffic; never send one control message per 10 ms audio frame
- replace `wasapi2sink`, `autoaudiosink` and every other chat media-file audio
  sink with an `appsink` that forwards decoded PCM to the playback provider
- use the same provider for audio-message and video-message audio output
- preserve pause, resume, seek, stop, EOS tail playback and repeated-playback
  cleanup; a stale widget/session must not stop a newer playback session
- preserve the existing 1x, 1.5x and 2x voice-message speeds without allowing
  accelerated decoder delivery to overfill the bounded worker queue
- keep video decoding/rendering independent, but keep bounded audio/video
  timing and never block the GTK main thread on PCM IPC
- block playback with one clear error if the libwebrtc provider/worker is
  unavailable; do not silently fall back to a second output engine

Side-bug and hygiene gate:

- one active playback owner at a time with generation-checked teardown
- bounded queue and payload sizes for malformed or arbitrarily long files
- worker death, conversation switch, widget disposal and seek during teardown
  release the queue and activity lease exactly once
- call and message playback each honor their visible libwebrtc speaker setting
  and do not recreate the long-lived worker context
- no normal-run per-buffer logging and no hidden message-output setting
- Linux and Windows use the same provider/UI code; only the worker ADM remains
  platform-specific

Acceptance:

- call playback honors the call speaker row; audio messages, video-message
  audio and recorded-message test playback honor the message speaker row; both
  use the same libwebrtc worker/device API
- Windows creates no `dinox.exe` GStreamer/WASAPI render session for chat media
  playback; the active render session belongs to `dinox-webrtc-worker.exe`
- audio and video messages remain interoperable with Monal and Android clients
  because file formats and decoding are unchanged
- repeated audio/video playback, pause, seek, EOS and close pass focused tests
  without truncated tails, stale sound, crashes or unbounded memory growth

### Slice 29: private-room MUJI calls and one-capture group video

Status: protocol, Core/UI, native and Google-Vala implementation are complete
in the 2.2.8 source tree. The post-review regression pass is complete after
fixing conference payload-map, direct-leg adoption, per-peer video,
Preparing-liveness and Ready/IQ ordering findings. The focused XEP-0272/
XEP-0482, SDP-adapter, CallState and real-worker process gates pass, as does
the complete 42-test production profile; the independent worker/1:1 and
signaling/lifecycle reviews both returned GO. Immutable ABI 38 / IPC 8
package-artifact integration is complete, including target-platform validation,
public immutable assets, atomic package pins and the complete Windows
distribution gate.

Protocol and policy:

- XEP-0272 owns MUJI room presence, bounded preparing negotiation and exact
  full-JID peer legs. Ready-presence `content` elements remain in the MUJI
  namespace, carry the required `creator='initiator'`, and place only their RTP
  descriptions in the XEP-0167 namespace; XEP-0482 owns invitations and
  terminal actions.
- Existing ready participants select one codec-viable common conference content
  name and payload map per medium. That identity is frozen before peer
  publication and reused by every associated Jingle session. A late peer that
  cannot represent required audio fails closed; a peer that omits optional
  video remains audio-only without changing the room's frozen video presence
  or the video legs of other participants.
- A standards groupchat invite is identified only by the authoritative
  XEP-0359 stanza ID assigned by the source room. The outgoing origin ID is
  correlation data for DinoX's own MUC echo and is never sent as a room action
  reference.
- Incoming and outgoing actions are routed atomically by account, sender,
  message type and the reference owned by that target. Conflicting room IDs,
  foreign resources and MUC private-message confusion fail closed.
- Calls are exposed only for a joined room with a current private-room feature
  snapshot. Async joins and configuration changes carry room-context and call-
  generation ownership across every await boundary.

Media and lifecycle:

- `EngineMujiGroupSession` owns every exact peer session in one logical Google/
  libwebrtc group. Direct-to-MUJI adoption is transactional and restores the
  unchanged direct call if room publication fails.
- The Jingle adapter translates frozen conference names to and from native SDP
  MIDs and payload IDs, including RTX `apt`, for offers, answers, BUNDLE and
  ICE. Unconfigured 1:1 adapters retain their existing MID-as-content-name and
  native payload-ID behavior.
- Direct and private-room calls share the plugin's single `EngineContext` and
  therefore one external media worker. A group creates one PeerConnection per
  exact participant, not one worker per participant; group video adds one
  shared capture/effect pipeline and one camera publisher.
- ABI 38 / IPC 8 with video-ring 6 exposes source-frame diagnostics and enables
  one native capture/effect pipeline to fan the same frame out to every current
  peer. One attachment owns preview; publication tokens fence detach, reattach
  and publisher-handover races.
- Camera selection, camera enablement and codec downgrade are group-owned. A
  video group cannot open one physical capture path per participant, and an
  audio-only direct call cannot gain camera permission through conversion.
- A local participant only leaves a published decentralized MUJI room. DinoX
  never destroys that room on hangup, and one remote reject or left action
  cannot terminate the call for unrelated participants.

Current focused source gates:

- 64/64 focused XEP-0272/XEP-0482 parser, namespace, creator, content-identity,
  membership, Preparing and leave-race tests
- 37/37 focused Jingle/SDP tests, including conference payload-ID/RTX
  translation, legal `xs:string` content names and direct-1:1 isolation
- 41/41 focused CallState lifecycle, policy, invitation and ownership tests
- JMI/MUJI signaling, concurrent direct-plus-group ownership and final-worker-
  retirement smokes pass both in-process and through the real external worker
- complete release source build with legacy RTP disabled, Google/libwebrtc
  enabled and the in-process libwebrtc test oracle disabled
- 42/42 complete production-profile tests, including native wrapper, worker,
  IPC, video-ring, fan-out, Google-Vala engine, Jingle wire, ownership,
  group-session, Core/UI and direct-1:1 regression coverage
- independent worker ownership and direct-1:1 regression review: GO
- final independent signaling and lifecycle review: GO

Release integration evidence:

- Linux and Windows ABI 38 / IPC 8 / video-ring 6 runtimes were built from
  clean source commit `3c662ad2303f8d0fce2778d647e47e74135dba5c`; Linux SHA-256
  is `23141019853e6fb62d63c7476c512116b8f1cc05951b26559d47e5a0d087c146`
  and Windows SHA-256 is
  `d564b7c090375e92747c9b86090deaeeb7143a1ed039a215ba4e3954161c8cf8`
- the Windows VM passes native IPC, video-ring and worker-process smokes with
  the published ABI 38 runtime
- both content-addressed assets and checksum sidecars are published before the
  package URLs, hashes, notices and runtime checkers advance on `master`
- the complete portable Windows distribution gate passes with 288 PE files,
  1,394 license assets, nine DinoX plugins and Google/libwebrtc as the only
  live-call engine
- immutable ABI 37 / IPC 7 assets remain unchanged so 2.2.7 and earlier source
  tags keep their reproducible runtime inputs

### MUJI native conference mapping follow-up (2026-09-12)

A controlled two-peer test reproduced connected sessions with no decoded media
when Jingle used conference payload IDs or content names while the native peer
connection retained its generated defaults. MUJI now prepares the local offer or
answer, projects the frozen conference map into that original SDP, and commits
it natively before publishing the Jingle description. The committed native
result is checked before signaling; packetization times, source identifiers and
transport attributes survive the conversion. The existing automatic direct-call
API remains available.

The new prepare/commit C API and prepared-description callback require wrapper
ABI 39 and control IPC 9; video ring 6 is unchanged. Local ICE waits for a
successful commit. Unsupported native MIDs and inconsistent packetization times
are rejected before READY, and optional RTX may be omitted without discarding a
usable primary codec.

The matching Monocles Test 9 change applies and checks the conference identities
and timing before native offers, answers and ICE-restart descriptions are sent.
Its 85 focused Android JVM tests and APK assembly pass. The DinoX native worker
media regression uses nondefault Opus/VP8 payload IDs, conference MIDs and actual
committed ptime/maxptime, and requires received audio and decoded video in both
directions. This controlled evidence does not replace the outstanding real
DinoX-Monocles device-call matrix or establish the cause of the earlier Android
runtime crash. Runtime archive identities are maintained in
[Google/libwebrtc Release Packaging](GOOGLE_WEBRTC_RELEASE_PACKAGING.md).

## 10. Open technical questions

- Windows artifacts are produced as a pinned native M150 runtime ZIP containing
  the DLL, worker, MinGW import library, IPC/process smokes and notices. Signing
  remains part of the normal DinoX Windows release-signing workflow.
- Flatpak consumes the pinned prepared Linux runtime archive through a fixed
  URL and SHA-256 instead of rebuilding Chromium inside flatpak-builder.
- Which existing call verification code depends on the current DTLS-SRTP layer?
- What total wire-bitrate ceiling is achievable on direct and TURN-relayed
  constrained links without making speech unintelligible?
- Does measured M150 adaptive packet duration outperform a fixed 40 ms profile
  under the selected EDGE-like loss models?

## 11. First concrete next step

Run the final 2.2.8 release-source gate, build and package Windows from the exact
release commit, then push the release tag so the single Forgejo workflow builds
Debian, AppImage and Flatpak. The older network-profile and Slice 27 live-
interoperability measurements remain separate acceptance gates and must not be
replaced by fixed bitrate workarounds.

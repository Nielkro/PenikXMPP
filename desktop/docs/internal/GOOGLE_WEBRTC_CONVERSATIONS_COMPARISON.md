# Google/libwebrtc Conversations Comparison

> Scope: implementation reference review
> Historical milestone: early runtime statements below predate the production cutover on `master`

## Reference checked

Conversations was checked as a current primary implementation reference because
its public project page documents A/V calls as standard Jingle plus WebRTC and
points to the canonical Codeberg repository.

Local reference checkout:

- repository: `https://codeberg.org/iNPUTmice/Conversations.git`
- branch: `master`
- commit: `c46852f`

Relevant Conversations files:

- `src/main/java/eu/siacs/conversations/xmpp/jingle/JingleRtpConnection.java`
- `src/main/java/eu/siacs/conversations/xmpp/jingle/WebRTCWrapper.java`
- `src/main/java/eu/siacs/conversations/xmpp/jingle/RtpContentMap.java`
- `src/main/java/eu/siacs/conversations/xmpp/jingle/SessionDescription.java`

## Architecture observed

Conversations keeps three responsibilities separate:

1. `WebRTCWrapper` owns libwebrtc state: `PeerConnectionFactory`,
   `PeerConnection`, local media tracks, local/remote SDP application, ICE
   callbacks and ICE readiness.
2. `JingleRtpConnection` owns the XMPP/Jingle session state machine:
   `session-initiate`, `session-accept`, `transport-info`, content-add/remove,
   state transitions, termination and verification failure handling.
3. `RtpContentMap` plus `SessionDescription` form the conversion boundary:
   Jingle content nodes are converted to SDP before they are passed into
   libwebrtc, and libwebrtc-generated SDP is parsed back into Jingle content
   nodes before stanzas are sent.

The important point for DinoX is that Conversations does not expose libwebrtc
directly to the UI or to generic Jingle code. It keeps a narrow media-engine
boundary and treats SDP as the adapter format between libwebrtc and XMPP.

## DinoX mapping

DinoX already has the correct first half of this boundary:

- native C ABI: `google-webrtc/include/dinox_webrtc.h`
- native wrapper implementation: `google-webrtc/src/dinox_webrtc.cpp`
- wrapper smoke test: `google-webrtc/tests/wrapper_smoke.cpp`
- existing SDP/Jingle bridge:
  `xmpp-vala/src/module/xep/0167_jingle_rtp/sdp_bridge.vala`

Therefore the next implementation path should not create a parallel
Conversations-style converter. DinoX should reuse and harden
`JingleRtp.SdpBridge` as the single conversion layer:

- libwebrtc local SDP -> `SdpBridge.session_from_sdp()`
- `SdpSession` -> `SdpBridge.jingle_content_node_pairs_from_session()`
- incoming Jingle content pairs -> `SdpBridge.session_from_jingle_content_node_pairs()`
- `SdpSession` -> `SdpBridge.session_to_sdp()`
- resulting SDP -> `dinox_webrtc_session_set_remote_description()`

## Immediate compatibility finding

A real DinoX libwebrtc wrapper offer can contain audio RED in this form:

```text
a=rtpmap:63 red/48000/2
a=fmtp:63 111/111
```

The bare `fmtp` value has no `name=value` shape. XEP-0167 Jingle RTP parameters
are name/value parameters, and Conversations also does not turn such bare SDP
parameters into Jingle parameters. DinoX must tolerate the line while parsing
the SDP, but must not invent an invalid Jingle parameter.

This is now covered by `xmpp-vala/tests/audit_jingle_sdp_bridge.vala`.

## Historical implementation direction

The next code slice at that milestone was a small internal adapter around the
then-existing pieces:

- keep the then-current GStreamer RTP runtime temporarily as the default path
- create a development-only Google/libwebrtc Jingle adapter surface
- feed wrapper-generated SDP into `SdpBridge`
- feed incoming Jingle content into wrapper remote-description calls
- queue/hold ICE until local/remote content maps are known, following the same
  readiness rule Conversations uses
- only after this bridge is tested should any call-start path be wired to it

## Adapter slice status

Implemented in:

- `xmpp-vala/src/module/xep/0167_jingle_rtp/libwebrtc_jingle_adapter.vala`
- `xmpp-vala/src/module/xep/0167_jingle_rtp/sdp_bridge.vala`
- `xmpp-vala/tests/audit_jingle_sdp_bridge.vala`

At that milestone, the adapter was intentionally pure Vala/XMPP code. It did
not link to the native wrapper or change the then-active GStreamer RTP path.

Covered behavior:

- local libwebrtc SDP callback shape to Jingle RTP content descriptions and
  ICE-UDP transports
- incoming Jingle RTP content descriptions and ICE-UDP transports to remote SDP
  suitable for `dinox_webrtc_session_set_remote_description()`
- `offer`/`answer` type names aligned with `dinox_webrtc.h` ABI v7
- SDP media directions preserved and mapped to/from Jingle `senders`
- local libwebrtc ICE callback shape to Jingle candidates
- incoming Jingle candidates to `sdp_mid`, `sdp_mline_index` and candidate
  strings suitable for `dinox_webrtc_session_add_remote_ice_candidate()`
- remote ICE rejected until the remote content map is known

## Development engine proof status

Implemented in:

- `plugins/google-webrtc/src/native.vala`
- `plugins/google-webrtc/src/engine_jmi_session.vala`
- `plugins/google-webrtc/src/engine_jingle_session.vala`
- `plugins/google-webrtc/src/engine_jingle_wire_session.vala`
- `plugins/google-webrtc/src/session_owner.vala`
- `plugins/google-webrtc/src/signaling_session.vala`
- `plugins/google-webrtc/tests/engine_smoke.vala`
- `plugins/google-webrtc/tests/jmi_wire_smoke.vala`
- `plugins/google-webrtc/tests/jingle_engine_smoke.vala`
- `plugins/google-webrtc/tests/jingle_wire_smoke.vala`
- `plugins/google-webrtc/tests/signaling_smoke.vala`

This is the first development-only libwebrtc engine/session owner. It consumes
the native C ABI v7 and the existing `LibwebrtcJingleAdapter`, but it is built
only when both `-Dgoogle-libwebrtc-wrapper=enabled` and
`-Dplugin-google-webrtc=enabled` are set. Default DinoX builds do not compile or
load it.

The smoke test creates two native libwebrtc sessions, maps a generated local
offer to Jingle, maps that Jingle offer back into remote SDP for the answerer,
creates an answer, and maps that answer back into the original offerer. This
proves the current wrapper/Jingle boundary accepts a real libwebrtc
offer/answer roundtrip.

The signaling smoke test exercises the next boundary without opening a real
XMPP stream: outgoing `session-initiate`, incoming `session-accept`, queued
local ICE -> `transport-info`, remote `transport-info` parsing, wrong-state
rejection, end-state rejection and peer-JID validation for `initiator`/
`responder`.

`EngineJingleSession` combines both development-only layers: it owns one native
libwebrtc `EngineSessionOwner`, owns one `JingleSignalingSession`, turns local
libwebrtc offers/answers into outgoing Jingle payloads, applies incoming Jingle
offers/answers to the native engine, and forwards local/remote ICE candidates at
the same boundary. The `google-webrtc-jingle-engine-smoke` test now proves a
full in-process initiator/responder offer-answer handshake across that combined
boundary, still without `XmppStream`, UI, capture devices or the production RTP
plugin.

`EngineJingleWireSession` adds the first real IQ wire boundary around that
session owner. It can emit Jingle payloads as IQ set stanzas, ACK incoming IQ set
stanzas, reject malformed or unexpected peer/SID stanzas, and feed incoming
`session-initiate`, `session-accept`, `transport-info` and `session-terminate`
back into the libwebrtc engine session. The real transport implementation uses
`Xmpp.Iq.Module`, but the class is not registered as a global Jingle namespace
handler yet. The `google-webrtc-jingle-wire-smoke` test proves the full
initiator/responder IQ flow with a recording transport.

`google-webrtc-audio-only-smoke` is now the stronger audio-only wire proof. It
keeps video disabled, validates Opus/48000 in `session-initiate` and
`session-accept`, pumps generated `transport-info` IQs in both directions, and
waits until both native remote audio sinks report non-zero decoded samples. It
also verifies remote `session-terminate` handling over the same wire boundary:
terminate IQ, ACK, `remote_terminated` signal and `ENDED` signaling state on
both sides.

`EngineJmiSession` adds the development-only XEP-0353 gate in front of the IQ
wire session. Outgoing calls now send a JMI `propose` first and only create the
libwebrtc Jingle IQ session after a `proceed` arrives from a concrete full JID.
Incoming calls can accept a proposal by sending the existing DinoX
`accept-to-self` plus peer `proceed` messages, then create the incoming wire
session when the following `session-initiate` IQ arrives. `EngineJmiSessionRouter`
adds the next safety layer by routing only local-full-JID/SID pairs that were
explicitly registered for the libwebrtc proof; unrelated Jingle IQs must remain
available to the production RTP/Jingle stack. The
`google-webrtc-jmi-wire-smoke` test proves this audio-only
`propose` -> `proceed` -> `session-initiate` -> `session-accept` sequence, then
pumps generated `transport-info` IQs, waits for decoded audio samples and
verifies `session-terminate` propagation into JMI `ENDED` state plus router
isolation for the wrong local JID.

Still intentionally out of scope:

- no `VideoCallPlugin` replacement
- no capture device handling
- no audio/video track plumbing
- no production `PeerState`/`CallState` JMI wiring
- no UI changes
- no production `plugins/rtp` call-path switch

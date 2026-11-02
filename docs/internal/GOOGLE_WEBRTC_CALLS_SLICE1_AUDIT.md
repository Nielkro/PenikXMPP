# Google/libwebrtc Calls - Historical Slice 1 Audit

> Scope: audit and build-graph cleanup
> Historical milestone: this audit records the state before Google/libwebrtc
> replaced the GStreamer RTP call engine; it is not the current architecture.

## 1. Summary

At this historical slice, the production call path was still the GStreamer
`rtpbin`-based RTP/Jingle engine.

Before cleanup, there was WebRTC-named code in `plugins/rtp`, but it was not a
real Google/libwebrtc implementation:

- `webrtc_module.vala` is optionally compiled when GStreamer `webrtcbin` headers
  are available, but the runtime plugin does not register it.
- `webrtc_module.vala` says it replaces the legacy `rtpbin` engine, but its
  stream creation calls back into the existing `Stream`/`VideoStream` classes.
- `webrtc_session_manager.vala` is not part of the Meson source set and
  references a missing `WebRTCStream` type.
- `sdp_jingle_converter.vala` is optionally compiled together with
  `webrtc_module.vala`, but it is not used by the production call path.

The follow-up cleanup removed this ambiguity from the build graph without
replacing the production engine.

## 2. Verified active production path

### 2.1 Plugin registration

`plugins/rtp/src/plugin.vala` registers the standard RTP module:

```vala
list.add(new Module(this));
```

It explicitly does not register `WebRTCModule`. The nearby comment says the
standard module is used for Monal compatibility and that `WebRTCModule` had
codec negotiation problems.

### 2.2 Production media engine

The active plugin implements `VideoCallPlugin` and creates one GStreamer call
pipeline with `rtpbin`.

Key active files:

| File | Current role | Slice-1 decision |
|------|--------------|------------------|
| `plugins/rtp/src/plugin.vala` | production call plugin, pipeline/device lifecycle, `VideoCallPlugin` implementation | keep unchanged until replacement is ready |
| `plugins/rtp/src/module.vala` | active XEP-0167 module implementation for current engine | keep unchanged; use as protocol behavior reference |
| `plugins/rtp/src/stream.vala` | active RTP/RTCP appsrc/appsink stream implementation around `rtpbin` | keep unchanged; later replaced by libwebrtc session wrapper |
| `plugins/rtp/src/video_widget.vala` | active GTK video sink/widget for GStreamer video frames | keep unchanged; later replaced or adapted for libwebrtc frames |
| `plugins/rtp/src/device.vala` | active GStreamer device enumeration and source/sink linking | keep unchanged; later replaced/adapted for libwebrtc device control |
| `plugins/rtp/src/codec_util.vala` | active GStreamer codec/payloader/depayloader selection | keep unchanged; later mostly obsolete for libwebrtc calls |
| `plugins/rtp/src/voice_processor*.{vala,cpp}` | active optional voice preprocessing via `webrtc-audio-processing` | keep for now; this is not full Google/libwebrtc |
| `plugins/ice/*` | active Jingle ICE-UDP, libnice, DTLS-SRTP and SRTP handling | keep unchanged; later replaced for live calls by libwebrtc ICE/DTLS/SRTP |

### 2.3 Production signaling path

The current call flow is Jingle-first:

1. `Calls.initiate_call()` creates a `CallState` and `PeerState`.
2. `PeerState.initiate_call()` sends Jingle Message Initiation when available.
3. `PeerState.call_resource()` calls
   `Xep.JingleRtp.Module.start_call()`.
4. `JingleRtp.Module.start_call()` creates separate audio/video Jingle contents,
   selects transports and creates a Jingle session.
5. `JingleRtp.Parameters.accept()` creates the media stream through
   `parent.create_stream(content)`.
6. The active `plugins/rtp/src/module.vala` implementation delegates stream
   creation to `plugin.open_stream(content)`.
7. `plugin.open_stream()` creates `Stream` or `VideoStream`.
8. `Stream.create()` links appsrc/appsink elements to GStreamer `rtpbin`.

This matters for libwebrtc because the current architecture exposes RTP streams
and Jingle content parameters to UI/control code. A libwebrtc `PeerConnection`
does not map one-to-one to this object model.

## 3. WebRTC-named code classification

### 3.1 `plugins/rtp/src/webrtc_module.vala`

Classification before cleanup: misleading active-build / inactive-runtime code.
Cleanup result: removed.

Facts:

- It is included in `plugins/rtp/meson.build` when both
  `gstreamer-webrtc-1.0` and `gstreamer-sdp-1.0` are found.
- The local build graph currently compiles it because both pkg-config modules are
  present locally.
- The production plugin still registers `Module(this)`, not `WebRTCModule`.
- It advertises itself as a `webrtcbin` replacement, but `create_stream()` calls
  `plugin.open_stream(content)`, which creates the existing GStreamer
  `Stream`/`VideoStream` classes.
- It also contains SDES-SRTP crypto generation, while the current production
  module intentionally avoids SDES and relies on DTLS-SRTP through the ICE
  transport.

Decision:

- Do not use this class for the Google/libwebrtc migration.
- Remove it from the RTP plugin build graph.
- Prefer deletion over rename unless a specific part is extracted into a tested
  new converter module.

Risk if left as-is:

- The code name suggests WebRTC support that is not actually active.
- Optional local dependency presence changes the linked binary without changing
  the real runtime call engine.
- Future work could mistakenly build on the wrong abstraction.

### 3.2 `plugins/rtp/src/webrtc_session_manager.vala`

Classification before cleanup: dead/incomplete source file.
Cleanup result: removed.

Facts:

- It is not included in `plugins/rtp/meson.build`.
- Repo-wide search finds no construction or reference to
  `WebRTCSessionManager`.
- It references `WebRTCStream`, but no `WebRTCStream` implementation exists in
  the repository.
- It is GStreamer `webrtcbin` oriented, not Google/libwebrtc oriented.

Decision:

- Remove in the next cleanup slice.
- If historical ideas are needed, this audit is enough to preserve the reason.

Risk if left as-is:

- It looks like an implementation plan, but it is not buildable as-is.
- It creates false confidence that a WebRTC bridge already exists.

### 3.3 `plugins/rtp/src/sdp_jingle_converter.vala`

Classification before cleanup: prototype/reference only.
Cleanup result: removed.

Facts:

- It is included only in the optional GStreamer `webrtcbin` source set.
- The production runtime does not use it.
- It has no visible fixture tests.
- It performs broad string-level SDP/Jingle conversion, but the migration needs
  a strict, fixture-tested bridge for libwebrtc.

Decision:

- Do not keep this as production migration code without tests.
- The future libwebrtc bridge should be a new tested module.
- If any logic is reused, extract it deliberately with fixtures instead of
  carrying the file forward under the old optional GStreamer path.

Risk if left as-is:

- It can become an accidental dependency for the new engine without enough
  protocol proof.
- It couples the future libwebrtc work to the old GStreamer `webrtcbin`
  experiment.

### 3.4 `plugins/rtp/meson.build`

Classification before cleanup: build graph ambiguity.
Cleanup result: removed.

Facts:

- The RTP plugin has an optional `webrtc_sources` block.
- That block adds `gstreamer-webrtc-1.0` and `gstreamer-sdp-1.0` dependencies.
- It compiles `sdp_jingle_converter.vala` and `webrtc_module.vala`.
- It does not compile `webrtc_session_manager.vala`.

Decision:

- Remove the optional GStreamer `webrtcbin` source block from the production RTP
  plugin unless a concrete current use is proven.
- Do not remove `plugin-rtp-webrtc-audio-processing`; that is a different
  dependency and still supports the current audio preprocessing path.

Risk if left as-is:

- Dependency names imply the app is using a WebRTC engine when it is still using
  `rtpbin`.
- Packaging may continue to require `libgstwebrtc.so` even when the active call
  code does not need it.

## 4. Documentation and packaging ambiguity

Before cleanup, several docs and checks mentioned WebRTC elements for calls:

- `README.md` says the media stack uses "GStreamer (RTP/rtpbin + WebRTC
  elements)".
- `docs/internal/BUILD.md` says DinoX does not use full Google WebRTC but uses
  GStreamer RTP/WebRTC-related elements.
- `scripts/package-runtime-matrix.sh` checks `webrtcbin`/`libgstwebrtc.so`.

The current production `VideoCallPlugin.supported()` checks for `rtpbin`, not
`webrtcbin`.

Decision:

- Update docs and runtime matrix to match the real current dependency state.
- During libwebrtc migration, introduce new checks for the pinned libwebrtc
  wrapper/artifacts instead of continuing to use `webrtcbin` as a proxy.

## 5. `VideoCallPlugin` assumptions that affect libwebrtc

The current `VideoCallPlugin` interface exposes:

- `Xmpp.Xep.JingleRtp.Stream?` in device, pause, volume, DTMF and display APIs
- `VideoCallWidget.display_stream(Xmpp.Xep.JingleRtp.Stream? stream, Jid jid)`
- a global plugin pipeline lifecycle through `dispose_pipeline()` and
  `dump_dot()`
- GStreamer-style device lists and per-stream output devices

These assumptions fit the current `rtpbin` engine but not a direct libwebrtc
`PeerConnection` model.

Migration implication:

- The libwebrtc implementation should not pretend that a `PeerConnection` is the
  same thing as `Xmpp.Xep.JingleRtp.Stream`.
- Add or replace the call-media abstraction before deep implementation.
- UI code should eventually depend on call media sessions/tracks, not on
  GStreamer RTP stream objects.
- `dump_dot()` is GStreamer-specific and should become backend-specific debug
  output or disappear from the generic interface.

## 6. Current security/encryption assumptions

The active production path uses DTLS-SRTP at the Jingle ICE-UDP transport layer.

Important current behavior:

- `plugins/rtp/src/module.vala` returns `null` for SDES crypto generation and
  selection.
- `plugins/ice` generates DTLS credentials/fingerprints.
- `plugins/ice` performs DTLS-SRTP and SRTP packet processing.

The removed inactive `webrtc_module.vala` contained SDES-SRTP crypto generation.
That is another reason not to recover or reuse it.

Migration implication:

- The libwebrtc path must stay DTLS-SRTP based.
- Do not introduce SDES-SRTP fallback.
- Fingerprint/setup mapping must be part of the tested Jingle/SDP bridge.

## 7. Slice-1 recommendations

### Completed safe cleanup commit

The cleanup commit is documentation/buildgraph cleanup and does not touch the
active runtime module:

1. Removed `plugins/rtp/src/webrtc_session_manager.vala`.
2. Removed the optional `webrtc_sources` block from `plugins/rtp/meson.build`.
3. Removed `plugins/rtp/src/webrtc_module.vala` from the build graph.
4. Removed `plugins/rtp/src/sdp_jingle_converter.vala`.
5. Keep `plugins/rtp/src/module.vala`, `plugin.vala`, `stream.vala`,
   `video_widget.vala`, `device.vala`, `codec_util.vala` unchanged.
6. Keep `plugins/ice` unchanged.
7. Do not remove `webrtc-audio-processing` yet.

This should reduce ambiguity while preserving the current production engine.

### Do not do yet

- Do not replace `VideoCallPlugin` in the same cleanup commit.
- Do not remove GStreamer live-call code before a libwebrtc call works.
- Do not change codec preference away from VP8 as part of this migration.
- Do not touch audio/video message recording/playback paths.
- Do not update packaging dependency checks before the source/build graph is
  cleaned and verified.

## 8. Acceptance state for Slice 1

Slice 1 is complete when:

- active production call path is documented
- every WebRTC-named source file is classified
- build graph ambiguity is documented
- `VideoCallPlugin` migration pressure is documented
- no runtime code has been changed

This document satisfies the audit part of Slice 1. The actual cleanup commit is
the next slice and should be reviewed separately before code changes are made.

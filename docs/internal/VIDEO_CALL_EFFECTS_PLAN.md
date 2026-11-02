# DinoX Video Call Effects Plan

> Current status (2.3.2 preparation, 2026-10-12): colour presets and picture
> adjustments, backgrounds, person framing, single-face accessories and scene effects
> are integrated into `master` for 1:1 and shared MUJI outgoing video. Package
> consumers are pinned to M152 wrapper ABI 40 / control IPC 10 / video ring 6,
> including the separate offline Vision worker and models.
> Native/runtime checks and the user's initial Linux video-effect checks exist;
> the current Windows application log review, complete user call tests and
> Fisheye/sharpening performance acceptance remain open release gates.
>
> The slices below preserve the August 2026 implementation plan. References to
> the old `feature/video-call-effects` branch, ABI 34-37, only Grayscale/Warm
> tone or effects being unavailable for MUJI describe those earlier stages,
> not the current build instructions or release feature list. Current contracts
> and immutable inputs are documented in [the ABI guide](GOOGLE_WEBRTC_WRAPPER_ABI.md)
> and [runtime packaging](GOOGLE_WEBRTC_RELEASE_PACKAGING.md).

## 1. Goal

Add optional outgoing-camera effects to DinoX calls without weakening call
stability, audio quality, UI responsiveness, interoperability or package
reliability.

The intended product scope is:

- color presets;
- static image overlays;
- background blur;
- background replacement;
- face-anchored accessories such as glasses and hats.

The local preview must show the same processed frame that is sent to remote
participants. Effects are entirely local. They do not add XMPP/Jingle
extensions and remote clients receive ordinary WebRTC video.

## 2. Non-goals and hard boundaries

- Do not change audio capture, processing, playout or device handling.
- Do not change Jingle signaling, codecs, RTP, ICE, DTLS-SRTP or libwebrtc's
  bandwidth and resolution adaptation.
- Do not reintroduce GStreamer into the live-call path.
- Do not process incoming remote video.
- Do not share this implementation with audio/video-message recording without
  a separate design and test cycle.
- Do not download models, backgrounds or accessories at runtime.
- Do not run per-frame work in Vala, GTK or the DinoX main process.
- Do not accept an unbounded frame queue, cache, log stream or asset size.
- Do not advertise background concealment as a privacy feature until its
  fail-closed behavior has passed the gates in this plan.

## 3. Proven current path

The production call engine always uses the external
`dinox-webrtc-worker`. Linux uses a socket pair and shared memory; Windows uses
a named pipe, a named shared mapping and a Job Object.

The current outgoing video path is:

```text
GTK/Vala call controls
    -> Google/libwebrtc session API
    -> typed control IPC
    -> external dinox-webrtc-worker
    -> VideoCaptureModule
    -> LocalVideoCaptureSink::OnFrame()
    -> SyntheticVideoTrackSource
    -> libwebrtc encoder/transport

LocalVideoCaptureSink::OnFrame()
    -> bounded worker video ring, latest frame wins
    -> Vala frame coalescing
    -> Gdk.MemoryTexture local preview
```

Relevant implementation points:

- `plugins/google-webrtc/src/engine_jmi_session.vala`
- `plugins/google-webrtc/src/session_owner.vala`
- `google-webrtc/include/dinox_webrtc.h`
- `google-webrtc/include/dinox_webrtc_ipc.h`
- `google-webrtc/src/dinox_webrtc.cpp`
- `google-webrtc/src/dinox_webrtc_worker_main.cpp`
- `google-webrtc/src/dinox_webrtc_worker_proxy.cpp`
- `google-webrtc/src/dinox_webrtc_video_ring.cpp`
- `main/src/ui/call_window/libwebrtc_video_widget.vala`

The safe effect insertion point is inside the external worker, immediately
before `SyntheticVideoTrackSource::push_frame()`. The processed frame must then
be used for both the send track and the local-preview callback.

```text
camera frame
    -> effect processor
       -> processed frame -> send track
       -> same frame      -> local preview
```

## 4. Required end-state architecture

### 4.1 Main process

The DinoX main process owns only:

- effect UI and translated labels;
- the user's current selection;
- capability and status presentation;
- bounded configuration requests to the worker;
- user-visible degraded/disabled state.

It must never receive masks, landmarks, models or uncompressed camera frames
through control IPC. The existing shared preview ring remains the only video
boundary to GTK.

### 4.2 Worker process

The worker owns:

- camera capture;
- one shared local video pipeline per logical call;
- effect configuration and revision tracking;
- optional model loading and inference;
- frame compositing;
- fan-out to all local send tracks;
- effect timing, load and failure diagnostics;
- bounded teardown of threads, frames, models and assets.

The `NONE` configuration must remain the current direct path. A fresh worker
that has only seen `NONE` must not start an effect thread, load a model, add an
effect-owned frame copy or perform a per-frame effect allocation. The bounded
control-plane pipeline object and its counters are allowed; the existing v2.2.3
preview conversion and shared-ring copy are baseline work, not effect work.
After an ML effect is switched off, processing stops immediately;
an already loaded model may be retained for at most 30 seconds within the same
logical call to avoid toggle thrashing. It must then unload. Call end must stop
effect threads and release all models within two seconds.

### 4.3 MUJI and multi-peer calls

Current MUJI handling is not yet one uniform Google/libwebrtc-worker path.
Depending on peer/resource state, a participant can still enter the classic
Jingle-RTP resource path through `CallState` and `CallPeerState`. Version 1 of
effects is therefore 1:1-only and must be hidden or disabled for MUJI until the
whole active MUJI media path is proven to use the external worker.

Once migrated, MUJI uses a separate engine session for every remote peer. A
naive effect inside each session's `LocalVideoCaptureSink` could therefore run
the same segmentation or face-landmark calculation once per peer.

Before any heavy effect is accepted, DinoX must provide one shared local
capture/effect pipeline per logical call and fan out its result to all peer
tracks. The API needs a stable logical-call or local-video-pipeline identifier;
session IDs alone are not sufficient.

The shared pipeline has explicit `create`, `attach`, `detach` and `destroy`
lifecycle operations, its own generation, subscriber generations and exactly
one preview publisher. The pipeline identity must be part of the first ABI/IPC
contract so MUJI does not require another protocol redesign.

Acceptance rule: with four remote peers, effect invocations per captured frame
may be at most 1.10 times the 1:1 result. Effect-owned memory is measured as
`MUJI(effect on - effect off)` and may be at most 1.10 times
`1:1(effect on - effect off)`. Total worker RSS is not used because additional
PeerConnections and encoders legitimately consume memory.

### 4.4 Effect execution

For active effects:

- the camera callback enqueues a reference-counted frame and returns;
- the composition mailbox capacity is exactly one frame;
- a newer frame replaces an unread older frame;
- one low-latency sequential composition executor processes the latest frame;
- a separate bounded inference stage allows at most one inference in flight;
- slow inference cannot block composition with the latest valid result;
- network, signaling, audio and libwebrtc worker threads never wait for it;
- delayed results carry session generation and configuration revision and are
  discarded when stale;
- segmentation and landmark inference operate on reduced frames at an
  independent rate;
- composition uses the latest valid mask or landmarks on the current camera
  frame;
- models are loaded once per worker, never once per peer.
- model thread-pool size and priority are bounded so ML cannot consume all CPU
  needed by audio, encoding, networking or the UI;
- overlay decoding, scaling, blur kernels and working buffers are allocated or
  prepared outside the per-frame path.

The serial worker control loop must never load a model, decode an asset or
construct an interpreter. A configuration request receives an immediate
revision-bound `accepted/queued` response. A later asynchronous worker event
reports `applied`, `degraded` or `failed`. Only the newest live pipeline
generation and configuration revision may publish a result.

Frame metadata is preserved deliberately. Processing keeps the original
capture and RTP timestamps, color-space metadata and outgoing rotation
semantics. Reduced inference input may be physically normalized, but masks and
landmarks must be transformed back to source coordinates before composition.
A full-frame composition marks the full frame as updated. Mirroring remains a
preview concern unless a later explicit product setting changes the sent
image.

Simple I420/libyuv operations should avoid RGB round-trips. Any unavoidable
conversion must be measured and remain behind the performance gates below.

### 4.5 ABI and IPC contract

The first implementation slice must introduce a typed, versioned contract:

- immutable `VideoEffectConfig` values;
- monotonically increasing configuration revisions;
- logical pipeline create/attach/detach/destroy operations;
- pipeline and subscriber generations plus one preview-publisher identity;
- effect type, preset or built-in asset ID, and quality intent;
- worker effect capabilities;
- bounded aggregate diagnostics;
- immediate `accepted/queued` replies and asynchronous revision-bound
  `applied`, `unavailable`, `degraded` and `failed` events.

The no-op control contract bumped the wrapper from ABI 34 to 35 and IPC 3 to
4. The first frame-processing effect bumps them again to ABI 36 and IPC 5.
Native, worker, proxy, Vala and every packaged vendor-runtime consumer must
change atomically. IPC 6 fences the video-ring-v5 mailbox; the second visible
effect (`WARM_TONE`) adds an enum value and capability bit under ABI 37 / IPC 7
so old and new workers cannot claim the same closed contract. Pixel data and
arbitrary file paths are not part of this control protocol.

## 5. Effect classes

### Tier 0: Off

- Exact present-day 1:1 passthrough path.
- After the MUJI migration, shared fan-out may be new infrastructure but adds
  no effect thread, effect copy or ML allocation when off.
- No effect execution. A cold `NONE` worker has no model allocation; the
  bounded post-ML retention rule in Section 4.2 applies after a live change.
- Always available.

### Tier 1: Basic

- Color-matrix presets.
- Lightweight built-in static overlays.
- No ML dependency.
- Implement directly in the existing native worker with libyuv or small local
  routines.

The first two presets stay directly in I420. `Grayscale` copies Y and sets U/V
to neutral chroma. `Warm tone` copies Y unchanged and applies fixed, clamped
offsets U-8 and V+12. They share the same one-frame mailbox, one executor and
three-buffer pool; switching presets creates no second thread, pool, model or
asset and performs no RGB round-trip.

### Tier 2: Background

- Person segmentation at reduced resolution and 10-15 inference frames per
  second.
- Background blur or replacement composed onto the current full camera frame.
- The first candidate is the TFLite/XNNPACK CPU path already pinned by the
  M150 source checkout, subject to an explicit target, size and license proof.
- The initial candidate model is the official MediaPipe selfie-segmentation
  landscape model; it must not ship before its exact file, digest, model card,
  distribution license and notices are recorded.

### Tier 3: Face accessories

- Face landmarks on reduced frames at an adaptive inference rate.
- Smoothed transforms for glasses, hats and similar built-in assets.
- Rotation, mirroring, cropping, multiple faces and temporary landmark loss
  need explicit behavior.
- Full MediaPipe integration is not assumed. It remains behind a separate
  feasibility gate because its desktop GN targets, transitive size and Windows
  packaging must be proven first.

## 6. Dependency decision

The first release must not add MediaPipe or ONNX Runtime merely to deliver
basic effects.

Decision order:

1. Implement Tier 1 without a new ML runtime.
2. Build an isolated TFLite/XNNPACK segmentation spike from the pinned M150
   source set.
3. Prove Linux and Windows linkage, deterministic offline builds, runtime
   package size, CPU/RAM, model provenance and complete notices.
4. Use ONNX Runtime only if the pinned TFLite route fails the production gates.
   A reduced ONNX build is still a second runtime and creates additional
   Linux/Windows divergence.
5. Evaluate full MediaPipe only for face landmarks. If its gates fail, use a
   small model on the accepted TFLite backend or defer Tier 3.

Tier 0 and Tier 1 stay inside the existing WebRTC worker. A second full-frame
effect worker is rejected because it adds another high-bandwidth frame copy,
memory ring and scheduling boundary. For Tier 2 or Tier 3, the approved design
gate is a separate low-resolution inference worker (for example 256x144 at
10-15 fps) when third-party ML crash or hang isolation is required. The WebRTC
worker keeps full-frame composition and immediate raw-or-neutral fallback.

The dependency spike must produce a written comparison containing:

- exact upstream revision and build target;
- supported Linux and Windows architectures;
- compressed and installed size increase;
- cold model-load time;
- 256x144 inference p50, p95 and p99;
- CPU and RSS after warm-up;
- all direct, transitive, model and asset licenses;
- package and CI build-time impact;
- deterministic offline rebuild instructions;
- proof that telemetry, usage reporting, DNS and outbound sockets are disabled
  for the selected native effect backend;
- crash and malformed-model behavior.

Size deltas must be recorded separately for the vendor runtime, installed
runtime, Deb, AppImage, Flatpak bundle and Windows ZIP. An increase above 5 MiB
compressed in any end-user artifact requires explicit release approval. The
spike must also propose and obtain approval for an installed-size ceiling; no
backend proceeds without that decision.

The exact direct and transitive licenses determine the obligations. Permissive
dependencies still require their applicable license files, existing NOTICE
files and modification notices. No GPL-style source sidecar should be created
without an actual corresponding source obligation.

Any MediaPipe feasibility build must additionally pass a fail-closed offline
test with networking blocked: no telemetry initialization, DNS lookup or
outbound socket is allowed. Failure rejects that backend rather than adding a
runtime exception.

References for the feasibility review:

- MediaPipe selfie segmentation model card:
  <https://storage.googleapis.com/mediapipe-assets/Model%20Card%20MediaPipe%20Selfie%20Segmentation.pdf>
- MediaPipe C++ face-landmarker interface:
  <https://github.com/google-ai-edge/mediapipe/blob/master/mediapipe/tasks/cc/vision/face_landmarker/face_landmarker.h>
- MediaPipe repository privacy information:
  <https://github.com/google-ai-edge/mediapipe>
- ONNX Runtime reduced builds:
  <https://onnxruntime.ai/docs/reference/operators/reduced-operator-config-file.html>
- ONNX Runtime execution providers:
  <https://onnxruntime.ai/docs/execution-providers/>
- LiteRT source and licensing:
  <https://github.com/google-ai-edge/LiteRT>

## 7. Load control and failure behavior

### 7.1 Adaptive quality ladder

The effect pipeline controls only its own inference and composition workload.
It must not replace libwebrtc's transport adaptation.

The initial ladder is:

1. inference at 15 fps;
2. inference at 10 fps;
3. inference at 5 fps and a smaller mask/landmark input;
4. cheaper blur, edge smoothing or accessory composition;
5. the policy-specific terminal fallback in Section 7.2.

The normal camera-frame output cadence is not a quality-ladder control. The
composer continues to use the latest valid inference result on current frames;
libwebrtc alone controls network-driven output adaptation.

Three consecutive two-second windows with either p95 processing above 70% of
the current composition frame budget or more than 5% replaced/dropped effect
frames move one step down. The composition budget is derived from camera FPS
(33.3 ms at 30 fps); inference budgets are 66.7, 100 and 200 ms at 15, 10 and
5 fps. Recovery waits at least ten seconds and moves only one step at a time,
and only after five consecutive two-second windows with p95 below 50% of the
relevant budget and drops below 1%.

If the camera continues but no processed frame completes for 500 ms, the
effect circuit breaker activates immediately.

### 7.2 Fail-safe policy

- Color and accessory failure or terminal overload: send the current raw frame
  and mark the effect degraded.
- Background blur/replacement failure: do not unexpectedly reveal the raw
  background. Use a neutral full-frame replacement or turn local video off,
  depending on the selected product policy, and show a clear warning.
- Effect initialization failure: keep the call usable and audio active.
- Worker crash or hang: preserve the existing behavior; DinoX stays usable,
  the active call fails exactly once, the worker is reaped, and only a later
  operation starts a new worker.
- A cooperatively cancellable effect job must stop within the normal two-second
  teardown deadline. A permanently blocked native inference call cannot be
  joined safely: an independent watchdog forces controlled worker termination,
  the main process stays responsive, and the next call starts a clean worker.
- A native effect-library segmentation fault also kills the WebRTC worker. Any
  reproducible crash or hang with valid supported inputs blocks the affected
  tier from release. It must either move to a second isolated process or remain
  disabled; C++ exception handling cannot make a segmentation fault safe.

## 8. Mandatory metrics and gates

Metrics are aggregated in the worker and exposed at most once per second. No
per-frame production logging is allowed.

### 8.1 Required metrics

Required counters and values:

- `captured`, `enqueued`, `processed`, `bypassed`;
- `queue_replaced`, `failed`, `watchdog_bypass`;
- `quality_downgrade`, active quality tier;
- processing time total, maximum, p95 and p99;
- last completed monotonic timestamp;
- stale mask/landmark age;
- loaded model bytes;
- effect-owned allocated bytes;
- logical-call and fan-out subscriber counts;
- audio `max_capture_gap_us` and `max_playout_gap_us` or an equivalent
  synthetic continuity measurement;
- main-loop delay p50, p95, p99 and maximum during UI tests;
- effect thread, handle/file-descriptor and shared-mapping counts.

The existing camera, RTP, bitrate, audio, shared-ring and worker lifecycle
counters remain part of every comparison.

Preview/send parity is verified before the path branches by attaching the same
effect revision and deterministic test-frame hash to both test observations.
Visual inspection alone is not sufficient.

### 8.2 Measurement profiles

Every report records the exact CPU model, logical/physical core count, RAM,
operating system, power profile, camera/source format and resolution, graphics
backend, hardware acceleration state, build commit and package type.

Two mandatory profiles are used:

- reference: the normal Linux workstation and canonical Windows 11 VM, each
  recorded exactly in the baseline report;
- constrained: a deterministic synthetic 640x480@30 input with DinoX limited
  to two logical CPUs, CPU inference only and a fixed power profile.

Timing gates use a 30-second warm-up followed by at least 60 seconds of
measurement. CPU uses one-logical-core percentage points as reported by the
same sampling tool and interval. Effect-core FPS gates use a deterministic
local process/loopback smoke; live-network tests compare against a no-effect
call under the same conditions because libwebrtc may legitimately adapt FPS.
Call-start timing uses at least 20 controlled signaling-smoke iterations and
compares median and p95, not a single internet call.

### 8.3 Gates

| Gate | Required result |
| --- | --- |
| Effect enqueue overhead in camera callback | Added p95 below 1 ms versus the paired off baseline; existing source push and preview work are measured separately |
| Cold effects off | Direct current path; worker CPU no more than 5 percentage points of one logical core above baseline, RSS no more than +16 MiB, FPS within 1 fps |
| Effects off after ML | No processing immediately; model unloaded within 30 s, and RSS then returns to cold-off baseline +16 MiB |
| Call teardown after ML | Effect threads/models released within 2 s; resource counts return to warm baseline +2 or less |
| Basic at 640x480/30 synthetic input | p95 at most 8 ms, p99 at most 16 ms, `processed/captured >= 0.97`, at least 29 fps only when 30 fps is captured, drops/bypass at most 1% |
| Background/face on reference profile | p95 at most 22 ms, p99 at most 33 ms, `processed/captured >= 0.80`, live encoded FPS no more than 10% below the paired no-effect call, drops at most 5% |
| Constrained two-CPU profile | Automatic reduction within 3 s, `processed/captured >= 0.80`, no main-loop delay above 100 ms |
| Initial segmentation memory | Warm worker RSS increase target at most 50 MiB |
| Absolute ML memory ceiling | Models and work buffers below 250 MiB, loaded once per worker |
| MUJI with four remote peers | Effect calls per captured frame and effect-owned RSS delta at most 1.10 times the corresponding 1:1 values |
| Audio | Measured maximum capture/playout gap at most 100 ms; audio counters remain monotonic |
| Mask/landmark age | Result older than 500 ms is never used; it triggers the tier-specific terminal fallback |
| Preview ring | Replaced plus dropped no more than 2 percentage points worse than the same call without effects |
| Call startup | Controlled median and p95 time to `IN_PROGRESS` each increase by at most 100 ms; model preparation never blocks signaling |
| Resources after 100 changes | Thread, handle/fd and mapping end values at most warm value +2, with no positive trend |

All absolute values are initial acceptance limits. Each measurement report must
also include the no-effect baseline from the same machine and build.

### 8.4 Deterministic baseline helper

`google-webrtc-video-effects-baseline` and
`scripts/measure-video-effects-baseline.py` provide the repeatable external-
worker acceptance baseline for lightweight effects. The helper measures four
separate paths with the same synthetic 640x480@30 input:

- `Direct`: the existing session path without an attached effect pipeline;
- cold `Off`: a `NONE` pipeline with no effect thread, frame copy or owned
  buffer;
- `Grayscale`: the first active basic effect.
- `Warm tone`: the second active basic effect, using the same executor and
  bounded I420 buffer pool.

The helper therefore runs four modes. Both active basic presets must pass the
same frame-ratio, rolling p95/p99, CPU, RSS, watchdog and three-buffer gates;
`Off` remains a separate zero-cost comparison rather than another effect.

The release-acceptance profile uses a 30-second warm-up and at least 60 seconds
of measurement for every path. Short `--quick` or custom profiles are useful
smokes, but the report explicitly marks them as non-acceptance profiles. During
the active-effect run the harness samples the native rolling 128-frame p95 and
p99 every second and gates the maximum observed values, so an early slow window
cannot disappear from the final result. CPU and RSS are sampled every 0.25
seconds for the actual external worker, not only for the small harness process;
acceptance requires at least 95% of the planned process samples so normal
Windows scheduler jitter cannot turn a complete 60-second run into a false
failure.

Example against an immutable vendor runtime:

```bash
meson compile -C build google-webrtc-video-effects-baseline
scripts/measure-video-effects-baseline.py \
  --build-dir build \
  --runtime-root /path/to/libwebrtc-m150-linux-x86_64-runtime \
  --package-type linux-vendor-runtime \
  --report /tmp/dinox-video-effects-baseline.json
```

The deterministic report covers effect-core CPU, RSS, frame ratios, timing,
bounded buffers and executor resources. It does not replace the live 1:1/MUJI,
camera-device, audio-continuity, network-adaptation, UI, soak or package-size
acceptance rows below.

## 9. UI and UX

The first UI belongs in the existing call bottom bar and opens an accessible,
keyboard-usable popover.

Requirements:

- `Off` is always present. Every new call starts with effects off; discovering
  capabilities, opening the popover or selecting a camera must never activate
  an effect.
- Only capabilities reported by the current worker are selectable.
- Applying a selection is asynchronous and never blocks GTK.
- Preview and transmitted video switch at the same accepted configuration
  revision.
- Loading, active, degraded and unavailable states are distinct.
- No raw internal-error strings are shown to users.
- All labels use gettext and remain readable at supported text scaling.
- Built-in assets come first. Arbitrary user background images are a later
  slice with dimension, decoded-memory, format and path validation.
- The first production UI stores the choice only for the active call and does
  not restore it on the next call. Any global, per-account or per-contact
  persistence requires a later explicit product decision.
- A background-concealment choice must visibly explain its fail-closed policy.

Likely attachment points:

- `main/src/ui/call_window/call_bottom_bar.vala`
- `main/src/ui/call_window/call_window_controller.vala`
- `libdino/src/plugin/interfaces.vala`
- `libdino/src/service/call_state.vala`
- `libdino/src/service/call_peer_state.vala`
- `plugins/google-webrtc/src/engine_jmi_session.vala`
- `plugins/google-webrtc/src/session_owner.vala`

## 10. Implementation slices

Each slice is committed, reviewed and tested independently. A failed gate stops
the next slice; it is not deferred to release packaging.

### Slice 0: Freeze and measure the baseline

- [ ] Finish or separate the current unrelated call-duration work.
- [x] Create `feature/video-call-effects` from a clean `master` and fast-forward
      it to the current `master` before each new implementation slice.
- [ ] Record 1:1 and MUJI no-effect CPU, RSS, frame, ring and audio metrics on
      Linux and Windows.
- [x] Add a repeatable metrics collection script that stays local unless it is
      suitable as a deterministic repository test helper.
- [ ] Record package sizes for Deb, AppImage, Flatpak and Windows dist.

Acceptance: reproducible baseline reports exist and no effect code is present.

### Slice 1: Add the no-op effect contract

Implementation note: this control-plane slice landed as ABI 35 / IPC 4. The
subsequent visible-effect work first used ABI 36 / IPC 5, then IPC 6 with ABI
36 for the bounded video-ring-v5 mailbox. The Warmton branch uses ABI 37 / IPC
7 without changing video-ring 5; the checklist below remains the historical
gate definition.

- [ ] Add typed C ABI effect capability, configuration and diagnostics types.
- [ ] Bump wrapper ABI 34 to 35 in C++ and Vala.
- [ ] Add typed IPC messages and bump protocol 3 to 4.
- [ ] Add no-op pipeline create/attach/detach/destroy operations, pipeline and
      subscriber generations, and one preview-publisher identity.
- [ ] Carry pipeline/session generation and configuration revision end to end.
- [ ] Return configuration acceptance immediately and deliver applied/degraded/
      failed state later without blocking the serial worker control loop.
- [ ] Extend IPC, proxy, worker and plugin smoke tests.
- [ ] Prove `NONE` is the old direct path without thread, allocation or copy.
- [ ] Reject wrong ABI/protocol versions, unknown IDs, truncated and oversized
      payloads without affecting an otherwise healthy call.

Acceptance: all existing call tests pass and the effects-off performance gate
passes on Linux and Windows.

### Slice 2: Unify MUJI and share local video across peers

- [ ] Map every current MUJI resource path in `CallState` and `CallPeerState`.
- [ ] Migrate all active MUJI media to the external Google/libwebrtc worker, or
      keep effects explicitly unavailable in MUJI.
- [ ] Use the Slice-1 logical pipeline contract for one shared local call
      pipeline.
- [ ] Acquire the camera once and fan out one local frame to all peer tracks.
- [ ] Preserve per-peer encoding and libwebrtc transport adaptation.
- [ ] Make camera pause, device change and teardown generation-safe.
- [ ] Add 1:1, three-participant and maximum-five-participant smokes.
- [ ] Count capture/effect invocations and subscribers.
- [ ] Prove peer join/leave and two logical-call IDs cannot leak frames,
      configuration or model state between pipelines.
- [ ] Publish local preview from exactly one designated pipeline publisher.

Acceptance: no classic RTP peer remains in an effects-enabled MUJI call, and
the 1.10 MUJI scaling gates pass before any ML integration. Until then, the UI
offers effects only for 1:1 calls.

### Slice 3: Add bounded executor, metrics and circuit breaker

- [ ] Add the one-frame latest-wins mailbox.
- [ ] Add separate bounded low-latency composition and single-inference stages
      per logical local video pipeline.
- [ ] Add all effect timing, replacement, error and quality metrics.
- [ ] Add deterministic delay, failure and permanent-stall fault injection.
- [ ] Implement adaptive downgrade, the policy-specific 500-ms terminal
      fallback and ten-second hysteresis.
- [ ] Prove camera, audio, network and signaling threads never wait on effects.
- [ ] Bound model thread count/priority and prove teardown succeeds while
      inference is in flight.
- [ ] Preserve and test timestamps, color space, update region, rotation and
      preview-only mirroring across the processed-frame branch.

Acceptance: artificial 100-ms processing and a permanent stall degrade or
enter the correct raw-or-neutral fallback without freezing GTK or breaking
audio.

### Slice 4: Implement basic native effects

Implementation note: `Grayscale` established the bounded native path.
`Warm tone` is deliberately the next small preset: fixed I420 chroma offsets
on the same processor resources, with separate pixel, switching and
Direct/Off/active performance gates before any overlay or ML work.

- [ ] Add color presets without a new ML runtime.
- [ ] Add one small built-in overlay with explicit license metadata.
- [ ] Preserve rotation, aspect ratio and local-preview parity.
- [ ] Verify no-effect output and timing remain unchanged.
- [ ] Run 100 live effect changes and 50 camera off/on cycles.
- [ ] Reuse decoded assets and working buffers without per-frame allocation.

Acceptance: Tier 1 gates pass on Linux and Windows.

### Slice 5: Add the call UI

- [ ] Add backend-neutral capability, selection, revision and status DTOs to
      `JmiCallEngineSession`; the UI must not cast to `EngineJmiSession` or use
      plugin-private `Native.*` types.
- [ ] Expose effect changes asynchronously through `CallPeerState`/`CallState`;
      GTK must never perform a synchronous worker IPC request.
- [ ] Add the bottom-bar effects control and accessible popover.
- [ ] Show only worker-advertised capabilities.
- [ ] Keep every control explicitly opt-in: opening the popover, discovering a
      capability, enabling the camera or changing the camera leaves `Off`
      selected until the user chooses an effect.
- [ ] Add translated active, loading, degraded and unavailable states.
- [ ] Coalesce rapid UI changes so obsolete revisions are discarded.
- [ ] Add GTK lifecycle tests for closing the popover/window during updates.

Acceptance: GTK receives no per-frame work and produces no critical warnings in
the effect lifecycle tests.

### Slice 6: Run the segmentation dependency spike

- [ ] Prove the pinned TFLite/XNNPACK target can be built into both vendor
      runtimes without dragging in full MediaPipe.
- [ ] Benchmark the exact pinned model on reference and weak hardware.
- [ ] Complete the dependency, model and license inventory.
- [ ] Measure runtime and package size changes.
- [ ] Set an approved installed-size ceiling and obtain explicit approval for
      any end-user artifact growing by more than 5 MiB compressed.
- [ ] Prove zero telemetry, DNS and outbound sockets with networking blocked.
- [ ] Compare a reduced ONNX Runtime build only if TFLite fails.
- [ ] Record a go/no-go decision; do not merge an unused runtime.

Acceptance: one backend passes every item in Section 6, or background effects
are explicitly deferred.

### Slice 7: Implement background effects

- [ ] Load and warm the model asynchronously.
- [ ] Run at most one reduced-resolution inference at a time.
- [ ] Reuse only a bounded-age mask and reject stale generations.
- [ ] Implement edge smoothing, blur and built-in image replacement.
- [ ] Implement and test the fail-closed concealment policy.
- [ ] Validate preview/send parity and automatic quality reduction.
- [ ] Reject missing, corrupt, digest-mismatched or wrong-shape models and
      simulated OOM without exposing a raw background.

Acceptance: Tier 2 performance, privacy, failure and soak gates pass.

### Slice 8: Evaluate and implement face accessories

- [ ] Run a separate MediaPipe-versus-small-TFLite landmark feasibility gate.
- [ ] Pin the chosen model and full dependency/license closure.
- [ ] Implement stable landmark smoothing and asset transforms.
- [ ] Handle no face, multiple faces, partial face and temporary tracking loss.
- [ ] Ship only explicitly licensed built-in assets.
- [ ] Repeat weak-hardware, MUJI and failure gates.
- [ ] Reject the tier on any reproducible valid-input native crash or hang.

Acceptance: Tier 3 is omitted from the release if it cannot meet the same call
stability gates; background effects remain independently usable.

### Slice 9: Package and license Linux artifacts

- [ ] Extend the libwebrtc vendor-runtime build target and manifest.
- [ ] Extend `check-libwebrtc-linux-runtime.sh` fail-closed checks.
- [ ] Extend Meson install data and package runtime matrix checks.
- [ ] Extend Deb, AppImage and Flatpak manifests and runtime gates.
- [ ] Include model digest, model card, notices and asset licenses.
- [ ] Ensure wrapper-only TFLite/XNNPACK dependencies are inventoried rather
      than relying on the existing `//:webrtc` license target.
- [ ] Confirm package artifacts stay slim and no unnecessary source sidecar is
      attached.
- [ ] Publish a new ABI-37 / IPC-7 Linux vendor archive and atomically update its URL
      and SHA256 in Forgejo workflows, Flatpak and every runtime pin.
- [ ] Make every package gate reject the previous ABI-34 runtime and verify the
      archived models, licenses, notices and reproducible manifest hash.

Acceptance: all three downloadable Linux packages run basic and ML effect
smokes without host dependencies.

### Slice 10: Package and validate Windows

- [ ] Extend `scripts/libwebrtc-windows-runtime/BUILD.gn` and the pinned vendor
      runtime build.
- [ ] Extend Windows runtime manifest and license inventory.
- [ ] Extend `update_dist.sh`, `check-windows-dist.sh` and the distribution
      builder for models and assets.
- [ ] Extend native IPC, ring and process smokes with effect delay/failure/stall
      cases.
- [ ] Publish a new ABI-37 / IPC-7 Windows vendor ZIP and atomically update its URL,
      SHA256 and every Windows runtime pin; reject pre-ABI-37 archives.
- [ ] Run the documented clean Windows build and complete-dist checker.
- [ ] Perform real 1:1 and MUJI calls using the packaged `dist/` tree.

Acceptance: Windows uses the same effect API and behavior; only platform
runtime packaging differs.

### Slice 11: Optional hardware acceleration

- [ ] Profile the accepted CPU implementation before adding another backend.
- [ ] Evaluate a platform-neutral acceleration path or clearly isolated Linux
      and Windows providers.
- [ ] Keep CPU fallback and deterministic capability reporting.
- [ ] Prove GPU loss/reset causes downgrade, not call failure.
- [ ] Repeat package, driver, memory and worker-crash gates.

Acceptance: acceleration is not required for the first release and is rejected
if it makes the CPU path or package closure less reliable.

### Slice 12: Release audit

- [ ] Run the complete matrix in Section 11.
- [ ] Perform developer, reviewer and independent audit passes.
- [ ] Verify no GStreamer live-call dependency was introduced.
- [ ] Verify XMPP/Jingle and remote-client interoperability are unchanged.
- [ ] Verify all models/assets work offline and have pinned licenses/digests.
- [ ] Verify worker, thread, handle, mapping and model teardown.
- [ ] Verify vendor archive URLs, SHA256 values and ABI pins changed atomically
      in every Linux and Windows consumer.
- [ ] Document user-visible effects and known hardware limits.

Acceptance: every Definition of Done item passes; otherwise effects remain
behind a development build option.

## 11. Test matrix

| Platform | Hardware/profile | Call | Effects | Duration |
| --- | --- | --- | --- | ---: |
| Linux local | reference PC | 1:1 | Off, Basic, Background, Face | 5 min each |
| Linux local | constrained to two cores | 1:1 | Background and Face | 15 min each |
| Linux local | reference PC | MUJI with 3 and 5 participants | Off and heaviest effect | 30 min |
| Windows 11 dist | reference PC | 1:1 and maximum MUJI | Off and heaviest effect | 30 min |
| Linux and Windows | reference PC | 1:1 | 100 effect changes, 50 camera cycles | until complete |
| Linux and Windows | reference PC | 1:1 and MUJI | heaviest effect | 60 min soak |
| Deb, AppImage, Flatpak | reference PC | 1:1 | Basic and one ML effect | 10 min each |

Every relevant call is repeated with:

- audio-only;
- camera initially off and enabled later;
- camera device change;
- window hidden, restored and closed during inference;
- constrained network while libwebrtc adapts independently;
- worker crash, delayed command and permanent effect stall;
- DinoX-to-DinoX and interop with Conversations, monocles and Monal where
  supported by the test devices.

### 11.1 Required fault and lifecycle tests

- Unknown effect and asset IDs, wrong ABI/protocol, truncated and oversized
  control payloads.
- Stale generations, out-of-order replies and 100 rapid configuration
  revisions; only the newest accepted revision may publish.
- Missing, corrupt and digest-mismatched model, wrong tensor shape, load error
  and simulated allocation failure.
- Failure every Nth frame, invalid output dimensions/stride/format and
  non-monotonic timestamps.
- Camera resolution, rotation and mirroring changes while inference is active.
- Camera off, call end and peer leave with an in-flight result; the late result
  must publish nothing.
- Cooperatively cancellable jobs stop within the lifecycle deadline. A
  permanently hung composition or inference stage triggers controlled worker
  termination, leaves DinoX responsive and permits a later clean call.
- Effect-configuration timeout that does not kill an otherwise healthy worker
  or active call.
- Background fail-closed behavior during initialization failure, frame failure,
  overload, 500-ms stall, invalid model and simulated OOM.
- MUJI peer join/leave during processing and isolation of two logical call IDs.
- Repeated model changes, 100 sequential calls and repeated worker start/stop.
- Bounded XNNPACK or other ML thread-pool behavior under the two-CPU profile.
- Revision/hash equality for local preview and outbound source before fan-out.

After five minutes of warm-up, the 60-minute soak requires:

- no statistically significant positive worker or DinoX RSS trend after
  warm-up, and end RSS no more than 16 MiB above the post-warm-up value after
  unloading transient models;
- no more than 64 MiB transient growth beyond loaded models;
- thread, handle, file-descriptor and shared-mapping end counts no more than two
  above the post-warm-up values and no positive trend;
- no zombie worker, restart loop, call freeze or audio interruption.

Starting test commands:

```bash
meson test -C build \
  google-webrtc-video-ring-smoke \
  google-webrtc-process-engine-smoke \
  google-webrtc-engine-smoke \
  google-webrtc-process-jmi-wire-smoke \
  --print-errorlogs
```

```bash
G_MESSAGES_DEBUG="google-webrtc libdino xmpp-vala" \
DINOX_GOOGLE_WEBRTC_CALL_DEBUG=1 \
DINOX_GOOGLE_WEBRTC_LIFECYCLE_DEBUG=1 \
./build/main/dinox 2>&1 | tee /tmp/dinox-effects.log
```

Debug output is enabled only for bounded test runs. Normal product builds must
not emit per-frame logs.

## 12. Definition of Done

The feature is complete only when all of the following are true:

- Every new call starts with `Off`; an effect is activated only by an explicit
  selection in that active call's video UI. Capability discovery, opening the
  effects popover, camera enablement or a camera change never counts as such a
  selection, and the choice is not restored in a later call.
- Effects off follows the present direct 1:1 worker path and passes the
  zero-cost gate; migrated MUJI adds no effect work while off.
- Effects switched off after ML stop processing immediately and release the
  bounded model cache on schedule.
- Effects remain unavailable in MUJI until all peers use the external worker;
  after that migration, capture and processing occur once per local frame, not
  once per peer.
- Preview and outgoing video show the same accepted frame revision.
- Audio, XMPP/Jingle, codecs and libwebrtc adaptation are unchanged.
- Overload automatically reduces effect work without freezing the UI or audio.
- Background concealment never silently exposes the raw background on failure.
- All executor, model, asset and shared-frame resources are bounded and released
  after camera stop and call end.
- Linux local, Deb, AppImage, Flatpak and Windows dist pass their package and
  live-call tests.
- Package size growth is measured, justified and explicitly accepted.
- Model and asset provenance, digests, licenses and notices are complete.
- Effects make no telemetry, DNS or network connection and work with networking
  blocked apart from the call itself.
- One-hour 1:1 and MUJI soaks show no meaningful RAM or resource growth.
- Worker fault injection preserves DinoX main-process stability.
- No supported valid effect input reproducibly crashes or hangs the WebRTC
  worker.
- A separate reviewer and auditor find no open release-blocking issue.

## 13. First implementation action

Do not start with segmentation or a large dependency. The first approved work
should be Slices 0 and 1 only: freeze a clean baseline, collect measurements,
then add the typed no-op ABI/IPC contract while preserving the exact existing
video path. This makes every later effect measurable and reversible before any
rendering or ML load is introduced.

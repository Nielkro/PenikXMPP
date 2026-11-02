# DinoX Media Message Recording Plan

> Status: Linux and Windows provider recording is implemented on `master`; package-runtime revalidation is in progress
> Scope: audio messages and video messages recorded from the DinoX chat input
> Non-scope: live audio/video calls; those are covered by `GOOGLE_WEBRTC_CALLS_PLAN.md`

## 1. Decision

DinoX has replaced the GStreamer-based audio/video message recorder with a
Google/libwebrtc capture path plus a platform file encoding/muxing layer.

There must be no GStreamer fallback in the new recorder path.

The old GStreamer recorder path is disconnected and removed. It must not return
as a hidden runtime fallback.

Current `master` result:

- The chat-input audio/video message UI uses the neutral recorder provider.
- The Google/libwebrtc provider records Linux audio messages as M4A/AAC-LC.
- The Google/libwebrtc provider records Linux video messages as MP4/H.264
  Constrained Baseline plus AAC-LC.
- The media-message recorder provider is registered independently from the
  `DINOX_GOOGLE_WEBRTC_CALLS` runtime gate. That gate controls calls only.
- `main/src/ui/chat_input/audio_recorder.vala` and
  `main/src/ui/chat_input/video_recorder.vala` were removed from the build and
  deleted.
- GStreamer remains for file demux/decode, playback, metadata and thumbnails,
  but not as a chat-input recorder fallback.
- Message-device selection is matched conservatively by saved DinoX display
  name against libwebrtc device display names; if no match exists, libwebrtc
  default/first device behavior is used.

Reason:

- The user-visible problem is camera and audio capture instability across Linux
  distributions.
- Keeping GStreamer as fallback would force DinoX to keep packaging and testing
  the same runtime family that caused the recorder problems.
- The libwebrtc call engine follows the same direction: one selected media
  engine, not permanent dual media engines.

## 2. Hard separation from calls

Audio/video calls and audio/video messages are different stacks.

Calls use XMPP/Jingle signaling and libwebrtc live media transport.
Media messages create local files and then send them through the normal file
upload/file-transfer path.

Rules:

1. Do not copy message-recorder logic into the call stack.
2. Do not copy call transport/signaling logic into the message recorder.
3. Recorded audio/video messages keep the normal existing upload path when
   available; they must not force direct Jingle transfer.
4. The message recorder may reuse the same native libwebrtc artifact and device
   access boundary, but not the call session state machine.

## 3. Previous code that was replaced

Current audio message entry path:

- `main/src/ui/chat_input/chat_input_controller.vala`
  - creates `AudioRecorder`
  - writes temporary `dino_voice_*.m4a`
  - emits the existing voice-message recorded signal
- `main/src/ui/chat_input/audio_recorder.vala`
  - builds a GStreamer pipeline
  - uses `create_audio_recording_source()`
  - encodes AAC and muxes MP4/M4A
- `main/src/service/audio_video_device_service.vala`
  - provides GStreamer audio recording sources

Current note: this old path has been disconnected and the old recorder
class was deleted.

Current video message entry path:

- `main/src/ui/chat_input/chat_input_controller.vala`
  - creates `VideoRecorder`
  - writes temporary `dino_video_*.mp4`
  - emits the existing video-message recorded signal after finalization
- `main/src/ui/chat_input/video_recorder.vala`
  - builds a GStreamer pipeline
  - uses `create_video_recording_source()`
  - chooses H.264 encoders through GStreamer factories
  - encodes AAC audio track
  - muxes MP4
  - provides preview frames to the popover
- `main/src/ui/chat_input/video_recorder_popover.vala`
  - talks directly to `VideoRecorder`
- `main/src/service/audio_video_device_service.vala`
  - provides GStreamer video recording sources

Current note: this old path has been disconnected and the old recorder
class was deleted.

Packaging surfaces under current revalidation:

- `scripts/build-appimage.sh`
  - must bundle the required FFmpeg message writer plus file-demux/decode
    runtime without restoring GStreamer recording
- `scripts/build-deb.sh`
  - must keep the FFmpeg executable writer separate from GStreamer file
    playback dependencies
- `scripts/update_dist.sh`
  - must retain only required playback codecs while recording stays on Media
    Foundation
- `im.dinox.dinox.json`
  - must provide the Linux FFmpeg writer and document/validate codec licensing
- `scripts/package-runtime-matrix.sh`
  - must test the libwebrtc/FFmpeg/GStreamer boundaries independently

## 4. Target architecture

The new recorder path should look like this:

```text
ChatInputController
  -> MediaMessageRecorderController
       -> AudioMessageRecorderBackend
       -> VideoMessageRecorderBackend
            -> native libwebrtc capture wrapper
            -> encoder/muxer backend
            -> temporary file
  -> existing send/upload path
```

The native layer should provide a stable C or GObject ABI for Vala:

- enumerate audio input devices
- enumerate video input devices
- start audio capture
- start video capture
- deliver PCM audio frames to the file encoder
- deliver I420/NV12/RGBA video frames to the file encoder and preview UI
- stop capture deterministically
- report device/capture errors with user-actionable error codes

The native layer must not expose libwebrtc API churn directly to Vala.

Important build boundary:

- `main` must not gain a hard compile-time dependency on
  `plugins/google-webrtc`.
- Google/libwebrtc recorder proofs live in the plugin engine first.
- The later chat-input switch needs either a neutral libdino plugin/provider
  interface or a main-owned factory boundary. It must not instantiate
  `Dino.Plugins.GoogleWebrtc.*` directly from UI code.

## 5. File format and interop policy

### 5.1 Audio messages

Primary format:

- container: MPEG-4 audio file
- extension: `.m4a`
- MIME: `audio/mp4`
- codec: AAC-LC

Reason:

- Monal records voice messages as M4A/AAC.
- Monal/iOS playback goes through AVFoundation/AVPlayer behavior.
- Android/Conversations/monocles also handle AAC/MP4 broadly.

There is no automatic second audio format in the first production gate. If AAC
encoding is not available in a safe backend, the UI must show a clear recorder
unavailable message instead of silently producing a less compatible file.

Optional later work:

- explicit Opus/WebM or Opus/Ogg mode for users who choose free codecs knowingly
- only after Monal/Conversations/monocles behavior is tested and the UI labels
  the compatibility tradeoff

### 5.2 Video messages

Primary compatibility format:

- container: MP4
- extension: `.mp4`
- MIME: `video/mp4`
- video codec: H.264 constrained/baseline-compatible profile
- audio codec: AAC-LC

This is the best interoperability target for Monal/iOS plus Android clients.

However, DinoX must not bundle a default self-built H.264 encoder stack.

Allowed H.264 sources:

- Windows Media Foundation encoder on Windows
- operating-system/platform encoder when available
- Linux system encoder installed and maintained by the distribution/user
- a Flatpak runtime/extension path only if the legal and release conditions are
  explicitly accepted and documented

Not allowed as default DinoX-bundled H.264 strategy:

- bundled x264
- bundled FFmpeg/libav with x264-enabled H.264 path
- self-built OpenH264 source module presented as patent-safe
- GStreamer H.264 plugin fallback

Optional explicit alternative format:

- container: WebM
- extension: `.webm`
- MIME: `video/webm`
- video codec: VP8
- audio codec: Opus

This alternative must not be hidden. If offered, the UI must clearly say that it is
not guaranteed to play in Monal/iOS. It may be useful for DinoX-to-DinoX,
Conversations and monocles interoperability.

## 6. License and patent policy

This plan is not legal advice. The engineering policy is conservative:

1. Avoid bundling H.264 encoders in DinoX release artifacts by default.
2. Prefer platform codecs when H.264/MP4 is required for interoperability.
3. Keep the Google/libwebrtc artifact H.264-disabled by default.
4. Keep x264 out of default DinoX bundles.
5. Treat OpenH264 patent coverage as binary/distribution-condition specific, not
   automatically granted to arbitrary self-built source modules.
6. Treat FFmpeg/libav as a separate compliance surface. If used, document build
   flags, dynamic-linking behavior, source availability, and whether GPL/nonfree
   features are disabled.

Relevant primary sources:

- FFmpeg legal notes: https://www.ffmpeg.org/legal.html
- x264 licensing: https://x264.org/licensing/
- OpenH264 FAQ: https://www.openh264.org/faq.html
- GStreamer licensing FAQ: https://gstreamer.freedesktop.org/documentation/frequently-asked-questions/licensing.html
- Apple AVFoundation overview: https://developer.apple.com/av-foundation/
- Android supported media formats: https://developer.android.com/media/platform/supported-formats

## 7. Exact coding plan

### Slice 1: Add neutral recorder interfaces

Files:

- add `main/src/ui/chat_input/media_message_recorder.vala`
- update `main/src/ui/chat_input/meson.build`
- minimally update `main/src/ui/chat_input/chat_input_controller.vala`

Work:

1. Define `MediaMessageRecorderError`.
2. Define `AudioMessageRecorderBackend`.
3. Define `VideoMessageRecorderBackend`.
4. Define common recorder states:
   - `IDLE`
   - `STARTING`
   - `RECORDING`
   - `FINALIZING`
   - `FAILED`
5. Keep the old `AudioRecorder` and `VideoRecorder` wired for now.
6. Do not add a second-backend selector.
7. The first slice is only an abstraction boundary and compile-proof.

Acceptance:

- DinoX compiles.
- No user-visible behavior change.
- Existing recorder classes are still the only active implementation.
- The new interface does not mention GStreamer.

### Slice 2: Add native recorder wrapper skeleton

Files:

- add `plugins/google-webrtc/src/media_message_recorder_native.vala`
- add native C/C++ files under the existing Google WebRTC native wrapper area
  once the current wrapper layout is confirmed
- update `plugins/google-webrtc/meson.build`

Work:

1. Add native create/destroy recorder context.
2. Add start/stop methods for audio capture.
3. Add start/stop methods for video capture.
4. Add callback ABI for:
   - audio PCM frame
   - video raw frame
   - device error
   - capture started/stopped
5. Add smoke test with synthetic capture frames first.

Acceptance:

- Wrapper compiles with `-Dplugin-google-webrtc=enabled`
  and `-Dgoogle-libwebrtc-wrapper=enabled`.
- Synthetic frame smoke test passes.
- No GStreamer dependency is introduced.
- No call-session code is modified except shared native build plumbing if needed.

### Slice 3: Audio message recorder v2

Files:

- add `main/src/ui/chat_input/audio_message_recorder_v2.vala`
- update `main/src/ui/chat_input/chat_input_controller.vala`
- update `main/src/ui/chat_input/voice_recorder_popover.vala` only if the signal
  shape changes
- add native or helper files for AAC/M4A encoding backend

Work:

1. Capture audio through the new libwebrtc-native recorder wrapper.
2. Encode AAC-LC.
3. Mux `.m4a`.
4. Preserve current temp-file naming pattern `dino_voice_*.m4a`.
5. Preserve duration limit and UI level reporting.
6. Preserve existing upload/send behavior after file finalization.
7. If AAC backend is unavailable, fail clearly; do not silently fall back.

Implementation sub-slices:

- Slice 3a: plugin-internal PCM recorder proof, no UI switch.
- Slice 3b: writer interface and AAC/M4A backend selection boundary.
- Slice 3c: first real allowed AAC/M4A writer backend.
- Slice 3d: neutral libdino plugin-provider boundary for the recorder.
- Slice 3e: Linux platform ADM capture path for real microphone frames.
- Slice 3f: audio-message UI switch to the neutral provider.

Current Slice 3b rule:

- The default AAC/M4A writer must report unavailable until a real allowed backend
  exists.
- The recorder may accept an injected writer in tests/proofs.
- The production path must not create invalid `.m4a` files and must not silently
  use a legacy media-pipeline fallback.

Linux Slice 3c direction:

- First Linux backend is a system `ffmpeg` process writer.
- DinoX does not bundle FFmpeg for this proof.
- DinoX does not link against FFmpeg/libav for this proof.
- The writer is available only when the system `ffmpeg` binary reports an AAC
  encoder and an MP4/M4A muxer.
- If unavailable, the writer must explain the missing backend and must not
  create a fake or incompatible file.
- Package decisions for AppImage/Flatpak/Deb remain a separate release-policy
  step; this proof establishes the Linux system-backend behavior first.

Slice 3d provider boundary:

- `main` must discover the new recorder through `Dino.Plugins.Registry`, not by
  importing `Dino.Plugins.GoogleWebrtc`.
- The provider lives in the Google/libwebrtc plugin and creates the current
  Linux AAC/M4A writer-backed audio recorder.
- The provider is registered only while the Google/libwebrtc runtime gate is
  enabled.
- The old chat-input recorder remains active until Slice 3f deliberately switches
  the audio UI.

Slice 3e Linux platform capture:

- The native recorder uses the Google/libwebrtc AudioDeviceModule capture path
  in platform-default mode.
- Synthetic frames remain only for smoke tests and synthetic contexts.
- The wrapper keeps a capture router/tap in the ADM wrapper instead of adding
  GStreamer, PulseAudio, PipeWire or V4L2 code to Vala.
- A gated smoke test with `DINOX_GOOGLE_WEBRTC_PLATFORM_AUDIO_SMOKE=1` can record
  a short real microphone-backed M4A file on machines with a usable audio input.

Slice 3f audio UI switch:

- The voice-message popover talks to the neutral `AudioMessageRecorderBackend`.
- The selected implementation is the registry-provided Google/libwebrtc audio
  recorder.
- If the provider or AAC/M4A writer is unavailable, DinoX shows a clear error and
  does not fall back to the old GStreamer recorder.
- The resulting file is still emitted through `voice_message_recorded(path)`;
  `ConversationViewController` keeps using the existing `FileManager.send_file`
  upload/encryption path.

Current Slice 3 result:

- Implemented for Linux through the neutral provider.
- The provider selects the saved message microphone by display name when
  libwebrtc exposes a matching input device.
- The old GStreamer audio recorder is not built and was removed.
- Gated platform smoke:
  `DINOX_GOOGLE_WEBRTC_PLATFORM_AUDIO_SMOKE=1 ./build-google-webrtc-local/plugins/google-webrtc/google-webrtc-engine-smoke`.

Acceptance:

- Local voice message records and sends.
- MIME stays `audio/mp4`.
- Monal receives and plays it.
- Conversations/monocles receive and play it.
- No GStreamer element is created by this recorder path.

### Slice 4: Video message recorder v2 with synthetic frames

Files:

- add `plugins/google-webrtc/src/video_message_recorder_v2.vala`
- add `plugins/google-webrtc/src/video_message_writer.vala`
- update `main/src/ui/chat_input/video_recorder_popover.vala`
- update `main/src/ui/chat_input/chat_input_controller.vala`
- add native/helper files for video frame delivery and preview

Work:

1. Use synthetic frames first, not the real camera.
2. Prove preview UI updates without GStreamer sinks.
3. Prove file finalization and send path.
4. Use the target video encoder/muxer abstraction, but keep synthetic input.

Acceptance:

- Synthetic video frames are produced and delivered through the writer contract.
- Preview is stable.
- No fake `.mp4` file is produced before a real allowed writer exists.
- No GStreamer element is created by this recorder path.

Implementation sub-slices:

- Slice 4a: plugin-internal BGRA video recorder proof, no UI switch.
- Slice 4b: video writer interface and unavailable default backend.
- Slice 4c: first real allowed Linux video writer backend.
- Slice 4d: preview bridge to the chat-input video popover.

Current Slice 4a-4c state:

- `VideoMessageRecorderV2` receives copied BGRA frames from the native
  Google/libwebrtc recorder ABI.
- The recorder keeps the latest preview frame and emits preview/frame signals
  without creating a GStreamer sink.
- The writer interface exists.
- The Linux default writer uses a system `ffmpeg` binary when it provides a
  supported software H.264 encoder and MP4 muxer.
- DinoX does not bundle ffmpeg, x264 or OpenH264 for this proof.
- If the system writer is unavailable, the writer reports a clear unavailable
  reason and no fake `.mp4` production file is created.
- The Linux writer can write video-only MP4/H.264 or MP4/H.264 plus AAC-LC.
- The chat-input video UI has been switched to the neutral provider.

### Slice 5: Real libwebrtc camera capture for video messages

Files:

- update native recorder wrapper
- update `video_message_recorder_v2.vala`
- update device selection integration as needed

Work:

1. Use libwebrtc-owned camera/device capture.
2. Map DinoX selected camera to native capture device.
3. Normalize frame orientation and pixel format in the native boundary.
4. Feed preview and encoder from the same raw frame path.
5. Avoid V4L2/PipeWire/GStreamer assumptions in Vala.

Acceptance:

- Linux Mint/Ubuntu 24.04 local camera records without stripe output.
- Debian 13 target records without stripe output.
- One Fedora or openSUSE test records without stripe output.
- Camera preview and final file have matching orientation/aspect.
- No GStreamer recorder path is used.

Implementation sub-slices:

- Slice 5a: recorder-native optional `video_device_unique_id` and real
  libwebrtc camera capture smoke.
- Slice 5b: map DinoX selected message-camera device to the recorder provider.
- Slice 5c: add audio track capture/muxing for real video messages.
- Slice 5d: switch chat-input video UI to the new provider.

Current Slice 5a state:

- The native recorder ABI accepts an optional `video_device_unique_id`.
- Without that device id, the recorder remains deterministic/synthetic for
  normal smoke tests.
- With that device id, the recorder uses libwebrtc `VideoCaptureModule` and
  delivers copied BGRA frames through the same preview/writer signal path.
- The Linux writer starts lazily on the first real frame, using the actual
  delivered frame geometry. This is required because cameras/libwebrtc may
  deliver a supported resolution different from the requested one.
- A gated smoke test with `DINOX_GOOGLE_WEBRTC_PLATFORM_VIDEO_SMOKE=1` records
  a short real camera-backed MP4/H.264 file when a usable camera and system
  writer are available.
- Real video-message recordings include a microphone/AAC-LC audio track.
- The provider selects the saved message camera by display name when libwebrtc
  exposes a matching camera; otherwise it uses libwebrtc default/first camera.
- The old GStreamer video recorder is not built and was removed.
- Gated platform smoke:
  `DINOX_GOOGLE_WEBRTC_PLATFORM_VIDEO_SMOKE=1 ./build-google-webrtc-local/plugins/google-webrtc/google-webrtc-engine-smoke`.

### Slice 6: MP4/H.264/AAC compatibility encoder path

Files:

- add encoder backend files under a neutral media-recorder native/helper area
- update packaging checks after implementation direction is chosen

Work:

1. Implement Windows Media Foundation MP4/H.264/AAC path for Windows builds.
2. Implement Linux platform/system encoder detection without bundling x264 or
   self-built OpenH264 as default.
3. If no safe MP4/H.264/AAC path exists, disable compatible video recording with
   a clear UI message.
4. Do not add GStreamer as fallback.

Acceptance:

- Windows creates `.mp4` through Media Foundation.
- Linux creates `.mp4` only when a safe system/platform encoder path is present.
- Monal plays the produced `.mp4`.
- Conversations/monocles play the produced `.mp4`.
- Package artifacts do not gain bundled x264/OpenH264 default encoder payload.

Current Linux result:

- Implemented through system `ffmpeg` only when it reports a supported H.264
  encoder, AAC encoder, and MP4/M4A muxer.
- DinoX does not bundle ffmpeg/x264/OpenH264 for this proof.

Current Windows result:

- `media_foundation_writer.cpp` implements M4A/AAC-LC and MP4/H.264
  Constrained Baseline plus AAC-LC through Windows Media Foundation.
- BGRA camera frames are converted to NV12 before encoding; no GStreamer,
  x264, OpenH264 or bundled FFmpeg recorder fallback is used.
- The native Windows 11 smoke produced both files successfully. `ffprobe`
  confirmed AAC-LC/48 kHz/mono for audio and H.264 Constrained Baseline plus
  AAC-LC/48 kHz/mono for video.
- The remaining gate is the full MSYS2 DinoX/plugin build and chat-input runtime
  test with the completed Windows libwebrtc worker artifact.

### Slice 7: Optional WebM/VP8/Opus explicit mode

Files:

- add WebM encoder backend files if chosen
- update UI copy and settings only if the user-facing choice is introduced

Work:

1. Add WebM/VP8/Opus writer as explicit non-Monal-safe option.
2. Do not use it automatically.
3. Label the UI clearly.

Acceptance:

- DinoX-to-DinoX playback works.
- Conversations/monocles playback works.
- Monal behavior is documented from real test result.
- User cannot mistake this for the primary compatibility mode.

### Slice 8: Switch chat input to recorder v2

Files:

- `main/src/ui/chat_input/chat_input_controller.vala`
- `main/src/ui/chat_input/voice_recorder_popover.vala`
- `main/src/ui/chat_input/video_recorder_popover.vala`
- build files

Work:

1. Instantiate recorder v2.
2. Remove direct dependency on old `AudioRecorder` and `VideoRecorder`.
3. Keep UI state transitions stable:
   - start
   - cancel
   - max duration
   - finalize
   - error
4. Keep temp-file cleanup behavior.
5. Keep existing file upload/send behavior.

Acceptance:

- Audio message record/cancel/send works.
- Video message record/cancel/send works.
- No GStreamer recorder path is reachable.
- UI does not hang during finalization.

Current Linux result:

- Audio and video chat-input recording now use the provider-backed v2 path.
- Finalization is synchronous in the provider path but verified short in local
  smokes; longer manual recordings should still be tested for UI responsiveness.

### Slice 9: Remove old GStreamer recorder implementation

Files:

- remove or disconnect:
  - `main/src/ui/chat_input/audio_recorder.vala`
  - `main/src/ui/chat_input/video_recorder.vala`
  - recorder-specific GStreamer helper code
  - recorder-specific methods in `audio_video_device_service.vala`
- update build files

Work:

1. Delete old recorder classes once recorder v2 is proven.
2. Remove GStreamer recorder source methods if no other code uses them.
3. Remove recorder-only GStreamer plugin requirements from package diagnostics.
4. Keep GStreamer only where still needed by unrelated playback/features until
   those are separately replaced.

Acceptance:

- `rg "AudioRecorder|VideoRecorder|create_video_recording_source|create_audio_recording_source"`
  shows no active old recorder use.
- DinoX compiles.
- Audio/video messages still work through recorder v2.
- No GStreamer fallback exists.

Current `master` result:

- `audio_recorder.vala` and `video_recorder.vala` are deleted.
- `main/meson.build` no longer includes the old recorder classes.
- `rg` shows no active `AudioRecorder`/`VideoRecorder` instantiation in
  chat-input code.
- `audio_video_device_service.vala` still contains GStreamer device helpers for
  unrelated preferences/tests and remaining media surfaces; removing those is a
  separate packaging/runtime cleanup slice.

### Slice 10: Packaging cleanup

Files:

- `scripts/build-appimage.sh`
- `scripts/build-deb.sh`
- `scripts/update_dist.sh`
- `scripts/package-runtime-matrix.sh`
- `im.dinox.dinox.json`
- `.github/workflows/build.yml` if package checks need adjustment

Work:

1. Remove recorder-only GStreamer plugin requirements.
2. Remove default bundled x264/OpenH264 encoder payload.
3. Remove Flatpak self-built OpenH264 module unless a separate explicit release
   decision keeps it.
4. Keep only package media runtime pieces still required by playback or other
   non-recorder features.
5. Add static package checks for the new recorder backend artifacts.

Acceptance:

- AppImage package check passes without recorder GStreamer requirements.
- Deb package check passes without recorder GStreamer requirements.
- Flatpak manifest check passes with the new codec policy.
- Windows dist contains Media Foundation path and not unnecessary x264/OpenH264
  recorder fallback payload.
- Package behavior matches local build behavior.

## 8. Test matrix

Minimum manual/runtime tests before production merge/release:

- audio message DinoX -> Monal
- audio message Monal -> DinoX playback still works
- audio message DinoX -> Conversations or monocles
- video message DinoX -> Monal with MP4/H.264/AAC
- video message Monal -> DinoX playback still works
- video message DinoX -> Conversations or monocles with MP4/H.264/AAC
- optional WebM mode DinoX -> Conversations/monocles if Slice 7 is implemented
- Linux Mint/Ubuntu 24.04 camera capture
- Debian 13 camera capture
- Fedora or openSUSE camera capture
- Windows 11 VM Media Foundation recording
- AppImage static package check
- Deb package check
- Flatpak manifest check

## 9. Stop conditions

Do not merge/release the recorder switch until all of these are true:

1. Audio recorder v2 creates playable M4A/AAC files.
2. Video recorder v2 creates playable MP4/H.264/AAC files where the compatible
   encoder path is available.
3. The UI shows a clear error when the compatible encoder path is unavailable.
4. No new recorder code creates GStreamer elements.
5. Packaging has been audited so removed GStreamer recorder pieces do not break
   unrelated playback features.
6. Manual Monal and Conversations/monocles interoperability has been tested for
   both audio and video messages.

## 10. Next implementation step

The current Linux implementation is beyond Slice 9. The next work should not
restart architecture; continue with focused verification and packaging:

- Manual DinoX -> Monal audio-message test.
- Manual DinoX -> Monal video-message test.
- Manual DinoX -> Conversations/monocles tests if available.
- Longer recording UI responsiveness check.
- Complete the Windows worker runtime, build DinoX in the Windows 11 VM and run
  the same chat-input recording path with the Media Foundation writers.
- Packaging cleanup/static checks for AppImage, Deb, Flatpak and Windows.

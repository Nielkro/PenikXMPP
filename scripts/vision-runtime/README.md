# Isolated vision runtime producer

These new helpers prepare a reproducible payload and build only the isolated CPU vision
worker/JNI library. They do not rebuild WebRTC, publish releases, create an APK, modify the
Windows toolchain, download sources/models, or operate existing jobs automatically.

`vision_runtime.py pack` is safe local preparation: it copies the current DinoX vision sources,
both already downloaded models, the two exact MediaPipe CPU custom-op files and their license.
It freezes byte counts/SHA256, official model URLs, source revisions and generated GN content
in an immutable `payload-manifest.json`. Inputs changing during the copy reject the payload.
The project license is copied separately, preserving explicit source SPDX headers.

Example paths must point to the existing caches; no example command is started automatically:

```sh
python3 scripts/vision-runtime/vision_runtime.py pack \
  --repo /media/linux/SSD128/xmppwin \
  --custom-op-root /path/to/verified/third_party/mediapipe_cpu \
  --segment-model /path/to/selfie_segmenter_landscape-v1.tflite \
  --face-model /path/to/blaze_face_short_range-v1.tflite \
  --model-license /path/to/verified/Apache-LICENSE \
  --output /path/to/ignored/new-payload
```

Only the build server runs `launch-server-build.sh`. Its durable unique systemd unit limits
CPU to100%, memory to6GiB, swap to0 and compiler concurrency to2; Android's four ABIs run
sequentially. The producer verifies the actual cgroup before GN/Siso and stops after18hours.
No polling occurs. Logs and status/manifests remain in the supplied private job directory.

```sh
bash scripts/vision-runtime/launch-server-build.sh --unit dinox-vision-runtime-UNIQUE -- build \
  --payload /server/jobs/verified-payload \
  --platform android --abi all \
  --src /home/cpaneladmin/dinox-libwebrtc-builder/work/src \
  --cached-out /home/cpaneladmin/dinox-libwebrtc-builder/work/src/out/m152-android \
  --out /home/cpaneladmin/dinox-libwebrtc-builder/work/src/out/dinox-vision-runtime-UNIQUE \
  --job /home/cpaneladmin/dinox-libwebrtc-builder/jobs/vision-runtime-UNIQUE
```

For Linux/Windows use `--platform linux|windows`, a single cached output (`m152-linux-x64`
or `m152-win-x64`) and a separate isolated output. Windows inherits the existing prepared
toolchain/environment and restored case-insensitive SDK view. An optional root-owned
`--env-file /absolute/cached/private-toolchain.env` passes it through systemd; values are
never dumped into provenance. The helper does not download, repair or mount a toolchain.
Compilation always occurs on the Linux server; Windows execution requires the VM afterwards.

Each evidence directory accepts one immutable attempt. A kernel flock prevents two jobs
from writing the same isolated output; cancellation releases that lock automatically.
Shipping cached outputs are read-only inputs to the helper. A content-addressed module below
`src/modules/` preserves upstream visibility and is verified/reused without overwriting it.
Git uses exact per-process `-c safe.directory=/that/repository`; global config is untouched.
BoringSSL's exact revision is read from the original `DEPS` Git blob at the fixed WebRTC
revision and compared with its cached HEAD; tracked local DEPS changes cannot redefine the pin.

GN generation clones cached platform args and builds one own target with pinned standalone
TF/XNN/pthreadpool/BoringSSL and the small custom CPU op. Android ARMv7 alone
uses the pinned TFLite single-thread CPU profile because the standalone XNNPACK
GN graph at this revision does not provide ARM32 targets. That profile selects
`BuiltinOpResolverWithoutDefaultDelegates`, never creates an XNNPACK delegate,
and requires `//third_party/pthreadpool:pthreadpool_standalone`. All other ABIs
and desktop targets retain the required XNNPACK profile. Own C++ enables exceptions for JNI
error translation. The reachable dependency graph must contain the standalone targets and
must not include `//:webrtc`, `//sdk/*` or the full MediaPipe framework. Source-file/dependency
hashes, tool hashes/versions, args/compile-command hashes and license copies are recorded.
No source or model is redownloaded when its exact cached pin exists; a missing cache fails
before compilation.

Android discovers declared API argument names from the pinned cached config and checks the
actual generated compiler triples for API23. The library is named
`jni/<abi>/libdinox_vision_inference.so`; its four JNI entry symbols and actual ELF ABI/16KiB
LOAD alignment are checked. Linux checks ELFx64, GLIBC<=2.35 and model-free `--help` startup.
Windows checks PE32+x64 and console subsystem; native VM startup/inference is not claimed.

Output is explicitly `BUILT_STATIC_CHECKS_PASS_RELEASE_REVIEW_REQUIRED`. GN source-component
licenses are collected before heavy compilation; missing license evidence stops the job.
Coverage derives from every actually reachable `third_party/<component>/` and
`buildtools/third_party/<component>/` source root, including libc++ where present, with
tflite/boringssl/pthreadpool required for every profile. XNNPACK is additionally
required for every target except the explicitly checked Android ARMv7 CPU profile. Each original license is checked
against its cached Git source blob, added to the immutable source SHA snapshot, then checked
unchanged after compilation. A license cannot be attributed across source roots or renamed
to impersonate another original. The separately pinned module-local MediaPipe CPU license
is handled independently. Missing declared license files fail before compilation.
Toolchain/system-runtime attribution still needs the normal release license audit. The helper
does not call that audit, model inference, Binder/device/GPU/call testing or artifact publication
complete. Root integrates the matched runtimes/pins and publishes only after those checks.

## Matched runtime packages

`package` consumes existing producer `artifact/` directories containing the exact
`runtime-manifest.json`, `source-provenance.json`, declared binaries/models/licenses and
checksums. It rechecks every declared byte count/hash, dependency pins and native headers.
It rejects mixed sources, missing ABIs, symlinks, unlisted files, mismatched model bytes and
changed inputs. Four Android ABI jobs must share identical dependency revisions/patches.
Every attributed license must match the actual source-root component, original filename,
bundle path and original source-snapshot SHA. Every reachable third-party source root needs
attribution, including a component present in both root namespaces. Rehashing a modified
bundle or removing an inventory entry cannot replace those original-source requirements.
The existing receipts of older one-off jobs need a reviewed manifest adaptation first;
this helper does not invent build or runtime acceptance evidence for them.

```sh
python3 scripts/vision-runtime/vision_runtime.py package \
  --payload /server/jobs/verified-payload --platform linux \
  --artifact /server/jobs/linux-job/linux-x64/artifact \
  --output /server/jobs/new-linux-runtime-package
```

Windows uses `--platform windows` and its own `windows-x64/artifact`. The desktop ZIP and
`runtime-staging/` contain `dinox-vision-worker[.exe]` beside the future `libdinox-webrtc`,
`dinox-vision-models/selfie_segmenter_landscape-v1.tflite`,
`dinox-vision-models/blaze_face_short_range-v1.tflite`, licenses, provenance and checksums.
Those names exactly match the current native `installed_vision_paths()`. Root merges this
staging directory into the existing platform runtime package; the producer does not change
or repack the WebRTC library itself.

```sh
python3 scripts/vision-runtime/vision_runtime.py package \
  --payload /server/jobs/verified-payload --platform android \
  --artifact /server/jobs/android-job/arm64-v8a/artifact \
  --artifact /server/jobs/android-job/armeabi-v7a/artifact \
  --artifact /server/jobs/android-job/x86_64/artifact \
  --artifact /server/jobs/android-job/x86/artifact \
  --output /server/jobs/new-android-runtime-package
```

The Android output `dinox-vision-runtime.aar` contains exactly four
`jni/<abi>/libdinox_vision_inference.so` libraries, API23 manifest, empty `classes.jar`,
the two pinned models under `assets/video-vision/`, and all relevant GN component licenses
under `META-INF/licenses/dinox-vision/`. Android's FACE filename is
`blaze-face-short-range-v1.tflite`, matching `NativeVisionBridge`. The application retains
the Java bridge; the AAR contains no other WebRTC SDK/library or Java client implementation.
Every actual JNI library is checked again for defined public JNI symbols and16KiB LOAD
segments; license texts from all four ABI graphs are combined without silent overwriting.
Additionally, `assets/vision/LICENSES/` preserves every original license file byte-for-byte
and `assets/vision/THIRD_PARTY_NOTICES.md` includes the full license texts, source revisions,
actual dependency patch hashes and model source/hash pins. These survive as APK assets,
analogous to the existing WebRTC AAR's `assets/webrtc/` notices. The current About screen
reads a string resource, so this producer does not claim that screen opens these assets.

ZIP/AAR member order, timestamps and modes are normalized. `package-manifest.json` and
`SHA256SUMS` describe the archive and exploded staging, with source/model/dependency hashes
inside the runtime manifest. Packaging performs no compile, runtime/service launch, network
request or publication; Android symbol inspection invokes only the static `readelf` tool.
It leaves device/call/model tests and complete platform-runtime license
audits explicitly pending. Output paths are new immutable attempts; failures are retained.

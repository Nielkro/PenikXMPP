# DinoX Release Readiness

This is the operational release checklist. A release is complete when source,
metadata and published packages come from the same frozen commit. The public
website is deployed separately and is not changed by a client release unless
that work is requested explicitly.

## Current Release Target

| Item | Decision |
|------|----------|
| Release | **2.3.5 — authorized by the user on 2026-10-31.** |
| Source | `master`, including all ten commits from `v2.3.4` through `627cf9bb`, followed by a test-fixture isolation fix and release documentation/metadata. |
| Changes | OMEMO store replacement when re-enabling an account, background image metadata preparation, new messages from removed contacts, chat controls and compiler-warning cleanup. |
| Metadata | One stable 2.3.5 entry dated `2026-10-31` in CHANGELOG, AppStream and DOAP, with matching VERSION and Meson version. The AppStream summary covers all 33 maintained translations plus English. |
| Local gates | Run static checks, strict production/test builds, all registered Meson groups, database tests and the Linux runtime matrix before tagging. Preserve results outside Git. |
| Windows evidence | Targeted Windows builds and regression tests passed for the changed paths. The final full Windows release build, ZIP and checksum are the maintainer's separate task after the tag is available. |
| Forgejo | Push `v2.3.5` once. Its workflow builds and checks DEB, AppImage and Flatpak sequentially, then publishes the Linux assets and source archive. Do not dispatch a duplicate package run. |
| Known limit | The reporter's particular Windows file-transfer crash has not been reproduced with the original file. The image-preparation fix does not close every reported freeze or crash. |
| Release-test correction | The complete GTK suite exposed two test applications registering the same D-Bus object path. Independent fixtures now use distinct application IDs. Menu assertions and production code remain unchanged; the failing pair was reproduced before the fix and passes afterward. Both affected full UI groups subsequently passed: 270 main UI cases and 19 sidebar accessibility cases. |
| Website | No separate website deployment requested. |

The user's instruction for this release explicitly leaves the final Windows
build to the maintainer. It is not a prerequisite for starting this Linux tag
workflow. Windows must subsequently be built from the exact `v2.3.5` tag.

Local validation passed the strict production and test builds with zero
compiler warnings and all 28 static gates. The complete 68-group run passed
66 groups; the two UI groups passed after the fixture correction described
above. A Hats navigation check also failed during overlapping CPU-throttled
test runs, then passed with the complete UI group running alone. No Hats
production code or assertions were changed. Logs remain outside Git.
Both database suites also passed, and the system runtime matrix passed all
52 checks with zero warnings and zero failures.
Optional live-server, Tor-daemon and configured-key tests retained their
explicit skips; this run does not claim those interoperability checks.
The database CLI suite skipped its WAL-file check because closing the CLI
had already checkpointed that temporary database.

## Release 2.3.3: historical acceptance

| Item | Decision |
|------|----------|
| Release | **2.3.3 — authorized by the user on 2026-10-29.** |
| Source | `master`, including all 48 commits from `v2.3.2` through `b37e9136`, followed by release documentation and metadata only. |
| Windows evidence | User-built and manually tested `3a4e974d`; complete log reviewed, exit status 0, all executed native/backend/package checks passed. See [Windows warning review](WINDOWS_WARNING_TODO.md#release-233-log-review-2026-10-29) for the 228 compiler diagnostics and explicit login UI-test skip. |
| Metadata | Promote the merged notes and localized AppStream summary to one stable 2.3.3 release, dated `2026-10-29`, with matching VERSION, Meson and DOAP. |
| Package order for this release | The user explicitly requested the Forgejo Linux release after review of their Windows log, and will build and upload the final tagged Windows package themselves afterwards. |
| Forgejo | Push `v2.3.3` once; its workflow builds and checks DEB, AppImage and Flatpak sequentially, then publishes the Linux assets and source archive. Do not dispatch a duplicate package run. |
| Windows delivery | Still pending until the maintainer builds from `v2.3.3`, creates the checked ZIP/checksum and uploads both to the matching release. The reviewed 2.3.2-version binary must not be renamed to 2.3.3. |
| Website | No separate website deployment requested. |

The code tested by the user is unchanged by the release-preparation edits.
The Windows warning review is not a claim of a warning-free compilation, and
the final tagged Windows artifact remains a separate delivery step.

## Release 2.3.2: historical acceptance and recovery

| Item | Decision |
|------|----------|
| Release | **2.3.2 — resumed by the user on 2026-10-23.** |
| Canonical repository | `https://git.dinox.im/dinoxim/dinox` |
| Release branch | `master` |
| Code baseline | All changes since `v2.3.1`, including the corrected fresh-profile OMEMO flow, MUJI proposal, DNSSEC/DANE, feeds, SASL and reconnect handling. |
| Package source commit | Freeze the corrected release commit before the Windows build. The replacement `v2.3.2` tag must point to that exact commit. |
| Metadata | One stable 2.3.2 entry dated `2026-10-23` in CHANGELOG, AppStream and DOAP; the earlier draft and Unreleased notes are merged without dropping changes. |
| Approval | The user resumed the release after confirming repeated MITM changes no longer produce warnings or crashes. Complete the Windows gates before starting Forgejo. |
| Linux reference | Local `build/main/dinox` on Ubuntu 24.04 / Linux Mint 22.x with the pinned source dependencies and M152 runtime. |
| Windows reference | Frozen MSYS2/MINGW64 VM, currently `10.0.60.44`; clean build with complete logs outside the checkout. No unrequested MSYS2 system upgrade. |
| Website | Maintained by the user; no deployment in this task. |

### Current verification and remaining gates

- **Final release completion resumed on 2026-10-23:** the user approved keeping
  the verified DinoX video path and completing publication. The clean Windows
  build and package checks for `39b4697f` passed; its ZIP and full logs were
  delivered locally. The final source also retains the corrected payload log
  from `127df4a6` and clarifies Ubuntu/Mint DEB installation versus Debian
  Trixie derivatives. Freeze this final source, rebuild Windows with persistent
  logs, then replace the unpublished tag/draft and run the three Linux package
  jobs sequentially. Do not treat a launched job as completed acceptance.
  The reported `libgpgme11t64` dependency is already declared and exists in
  Trixie; the derivative's exact package sources have not been inspected.
  The Ubuntu-built DEB also requires ICU 74, while Trixie supplies ICU 76, so
  its documented binary alternatives remain AppImage and Flatpak.
- **Camera report resolved on 2026-10-23:** run 282 (database run 409,
  `39b4697f`) was deliberately stopped during AppImage after missing outgoing
  video was reported. The webcam's physical shutter was closed. Direct V4L2
  capture in YUYV and MJPEG also produced black images; opening the shutter
  restored camera image data, and the user confirmed video with Monal.
  The installed DEB already rejected the slower VA-API VP8 decoder and used
  libvpx. No new decoder regression was demonstrated.
  The temporary native codec-preference change from `fdca34b9` and its
  SDP-order assertion were withdrawn: a VP8-first answer did not establish
  the outgoing RTP codec and did not resolve the black camera image. Keep
  the corrected signaling log, which reports the first SDP payload without
  claiming it is the active codec. Native sources again match the published
  runtime; this investigation does not require new native runtime archives.
  The local build was relinked to that published runtime and passed the strict
  build with zero warnings, runtime integrity checks and the original real
  worker/process media smoke, including bidirectional synthetic video.
  **Release completion is still pending:** the successful Monal retest used
  the local diagnostic build before that withdrawal. The stopped AppImage
  and unbuilt Flatpak still need their final package gates. Freeze the final
  source and match Windows and Linux packages before publication.
- Linux strict build after `97b97817`: zero warnings; 206 focused reconnect,
  PubSub, avatar, read-state, blocklist, carbons and OMEMO regressions passed.
  The preceding null-result crash regression reproduced SIGSEGV before its fix.
- The user then repeatedly changed the MITM settings: no further warnings or
  crash, and explicitly resumed release work.
- Release-tree Linux verification on 2026-10-23: strict production/test builds
  with zero compiler warnings, all 28 static gates and both database suites
  passed. The complete 65-group run passed 64 groups; its remaining MQTT
  fixture used an unreliable 75 ms assumption about the TLS handshake phase.
  After binding that fixture to the actual post-certificate phase, all five
  targeted network groups passed, including the additional HTTP/2 SOCKS5
  fixture with its isolated Python h2 dependency. There is no outstanding
  failed group. Earlier obsolete database/menu fixtures were corrected and
  passed in the complete run.
- The reference uses the published Linux runtime archive whose SHA256 starts
  `2479cdb9ab7e`, not the earlier local intermediate runtime. The production
  runtime matrix passed 52 checks, with zero warnings and zero failures.
- The clean Windows build/package log for `39b4697f` was checked successfully.
  Three compiler diagnostics from the previous Windows acceptance log were
  corrected; the ALPN binding also passed a focused compile with the actual
  Windows toolchain. The final source freeze above still needs its own build
  receipt before replacing the tag.
- The first clean Windows compilation of `fe74c82d` completed, and all eight
  DNSSEC/DANE groups plus the backup helper passed. The new SASL fixture then
  exposed OpenSSL CLI Unicode output limitations: relative ASCII generation
  followed by a Unicode-safe Python rename preserves the Cyrillic CA test;
  all 88 real TLS authentication cases passed under Windows after correction.
- The identical login-protection UI executable failed in the SSH service's
  GTK initialization but passed all five cases in the logged-in desktop. GUI
  checks therefore require explicit `DINOX_WINDOWS_UI_TESTS=1` there or a
  separate desktop run. The build reports the default GUI omission as a skip.
  New GTK string-list and dialog-snapshot C type warnings were also corrected.
- The three Linux packages must still pass their own Forgejo gates. An old
  package or historical test result is not acceptance of the corrected tree.
- Disk check before preparation: about 64 GiB free on the server and 47 GiB
  on Windows. Linux packages run sequentially; no duplicate RC/package run.

### Historical stop on 2026-10-15

Forgejo run **274** (database run **393**, tag `v2.3.2`, commit
`793405008387c36853f1eade9bbec8c7f486bb0e`) was stopped during the Flatpak job.
The exact job container was stopped and Forgejo recorded a terminal failure at
**2026-10-15 09:43:39 +02:00**. The release remains a draft; its ten existing
assets were retained. The previously built Windows ZIP has the same affected
source baseline and is not a corrected release package.

Fresh native demo profiles exposed a send waiting for a session to its own
current device. Existing positive fixtures omitted that device's normal
metadata entry; one remote fixture also explicitly created a self-session.
The three-person native group check also exposed premature partial delivery
while another active participant still needed session preparation. That
participant received no wrapped key until first sending a message themselves.
At that stop, the correction had to pass realistic current-device and other-own-device
regressions, actual encrypted delivery after normal restart, and renewed
package checks. Do not reuse the earlier gate results as acceptance of this
correction. That hold was superseded by the renewed user instruction above; the historical results still do not replace the current release gates.

### Correction Verification

The message correction in `043b060b`, before the call follow-up below, was
built on Linux with zero warnings. Its OMEMO plugin SHA256 is
`cdd691156520d92de3892edb8ec44775e34796da4be940bb4b8b96a80b4d5b3c`.
The complete local OMEMO suite passed **374** cases, with the **11** remote
cases skipped in that local invocation; session persistence passed another
**21** cases. Those **11** remote cases were then run separately against the
same correction and all passed, with no skips. Their three temporary accounts,
resources, upload directories, rooms, processes and native profiles were
independently verified absent after cleanup; the tutorial demo profiles were
preserved. All **28** static checks passed. Focused regressions include
current-device metadata, other own devices, equal numeric IDs on another
account, empty recipient payloads, cold group members and scoped key-access
denials. An integration test follows an actual bundle IQ through native session
creation to the automatic retry of the same group message.

Three native DinoX profiles confirmed that the first encrypted private-group
message reached both the established peer and a member with no prior sessions
or messages. The new member did not send first. Normal restarts preserved device
identities and keys, and a previously waiting direct message was delivered.
Independent code review found no further blocker in this correction.

At that historical checkpoint Windows was checked statically only; those
results do not certify the new Windows package. Current acceptance is recorded
separately above.

### Call Fingerprint Follow-up

A separate audit found that the optional legacy-OMEMO DTLS fingerprint
extension could send an ordinary fingerprint while the selected peer's
encryption session was still missing. This affects the signaling shared by
Google/libwebrtc direct calls and private-group MUJI legs; it is not a
GStreamer media-pipeline correction.

The correction waits for actual session preparation, rechecks the exact
account, full peer address, device identity and trust, and rejects stale or
failed preparation before writing the IQ. Once protection is negotiated,
later fingerprints must retain that identity. Direct-to-group conversion
keeps the established direct leg; cancellation applies only to the affected
peer and SID. Peers that do not negotiate the optional extension continue to
use ordinary DTLS-SRTP. An incoming security rejection must also release its
expected group participant without allocating media or leaving a waiting peer.

The corrected Linux tree was built with zero compiler warnings. All **36**
native call-fingerprint cases passed, including real Signal decryption,
missing sessions, rejected/changed keys, cancellation and account-key removal.
All **15** incoming-invitation integration cases passed against the ordinary
conversation and call stores. They cover an authorized first invitation
without an existing direct chat, exact account/connection/resource ownership,
blocked and unknown senders, duplicate delivery, and no acceptance, room join
or media allocation before consent. The three libwebrtc process tests passed,
including synthetic audio/video and direct-call adoption into MUJI.

The complete local suites passed with the following case counts. Environment
gates are shown separately and are not counted as passes.

| Suite | Passed | Environment-gated skips |
|-------|--------|-------------------------|
| XMPP | 953 | 3 |
| Application logic | 277 | 0 |
| libdino | 786 | 8 |
| OMEMO | 410 | 11 |
| OpenPGP | 182 | 29 |
| Legacy OMEMO persistence | 21 | 0 |

The **11** gated external OMEMO cases were then executed separately against
the current product: **11 passed, zero skipped, zero failed**. An independent
server read-back confirmed all three disposable accounts, resources, upload
directories and test rooms absent, with no test processes or profile databases
left behind. Five runtime binaries and 41 source/registration/wrapper files
were unchanged throughout this final remote run. All **28** static checks
also passed.

Three owned native demo profiles confirmed 1:1 audio, adding a third
participant, and bidirectional Opus RTP on all three peer connections. The
original direct SID survived conversion. After the third participant left,
the original pair stayed connected; normal hangup then released all media
workers and the temporary room was server-verified absent. Existing identities,
keys and trust were preserved. Long address entry no longer produced the
contact-selector GTK sizing warning. These GUI profiles already had chats and
encryption sessions; the missing-chat and cold-session cases are proven by
the permanent integration tests, not claimed as fresh-profile GUI coverage.

The GUI used synthetic audio; GUI video, physical devices, Windows and
external-client call interoperability remain unverified. Simultaneous MUJI
hangup can still log remote `unknown-session` termination warnings after the
calls end; this test left no call, worker or temporary room running. This
historical verification alone did not approve a replacement tag or publication.
The renewed user instruction and current gates above govern the resumed release.

## Historical 2.3.2 Baseline and Promotion Procedure

The completed clean Windows build of `32c162ee` was reviewed on 2026-10-15.
All 15 focused native units, 10 backend groups, eight WebRTC groups and the
portable PE/DLL, license, Unicode Tor and backup-helper checks passed. The
compiler log contains 219 existing warnings, with no new diagnostic signatures
compared with `5d2dac2b`, and no compilation errors. These automated checks do
not claim interactive GUI acceptance or compatibility with every remote client
and server. The old `c9df48d2` build and its warning backlog are historical,
not the current release baseline.

Before the later stop, the user's release go authorized promotion of the merged notes and
metadata with `scripts/release.sh 2.3.2 --prepare`, followed by its full local
release gate. The helper retains the existing 2.3.2 descriptions and historical
entries, sets one approved date in CHANGELOG, AppStream and DOAP, and keeps
VERSION and Meson at 2.3.2. It commits and pushes the prepared tree without
creating a tag. After reviewing that exact commit, `--finalize` creates and
pushes the annotated tag that starts the single Linux package workflow.

The old Linux-first sequence below is historical. The current instruction is
Windows first, then the single tag-triggered Linux workflow; use the current
Package Build Order section.

The pinned effect runtime is **M152 ABI 40 / IPC 10 / video ring 6**, including
the matched offline vision worker and models. A previously extracted M152
ABI 39 / IPC 9 directory is not a release-gate dependency. Prepare and validate
the exact pinned runtime before selecting it, even when its directory name
looks current.

Release promotion and Windows ZIP helpers also enforce metadata and output
boundaries: stable metadata is required before publication, and ZIP output must
be outside `dist/` so packaging cannot include its own output.

## Pre-Tag Gates

Do not tag while any of these gates is unresolved. The earlier Windows baseline
and release go are historical; the corrected source requires renewed approval. Linux
package creation is not a pre-tag gate because the tag starts the single audited
Linux package run. The final Windows build, ZIP and checksum use exactly that
same tagged commit and start after the one Forgejo startup check.

| Gate | Required evidence |
|------|-------------------|
| Clean tree | `git status --short` is empty before `--prepare` and before `--finalize`. |
| Release metadata | `VERSION` and Meson agree; changelog, stable AppStream and DOAP have exactly one matching version and approved date. Development or unreleased metadata does not pass this gate. |
| Windows baseline and approval | Review a clean build of the corrected source and obtain renewed release approval. Final Windows build/checks and ZIP use the approved release tag. |
| Static tests | `./scripts/run_all_tests.sh --static` passes. |
| Local Linux build | `./scripts/build.sh --strict` passes and `build/main/dinox` starts. |
| Meson tests | Run `./scripts/run_all_tests.sh --meson` for all registered groups. Preserve the full result, correct any failures and rerun affected groups; every failure must be closed before promotion. |
| Database tests | `./scripts/run_all_tests.sh --db` passes with the `sqlcipher` command installed. |
| Runtime matrix | `./scripts/package-runtime-matrix.sh system` has no release-blocking failure. |
| Docs | README, BUILD, TESTING, DEBUG, CONTRIBUTING and release notes point users to Forgejo, current packages and supported platforms. |

An optional `release_candidate=true` dry run remains available for risky
packaging changes. It is not required for a normal release and must not be
started merely to duplicate the tagged build.

## Publication Gates

The tag workflow enforces these gates before it publishes the Forgejo release.

The clean Windows build, its automated gates and canonical ZIP/checksum now
precede the Linux tag push. The maintainer uploads Windows separately.

| Gate | Required evidence |
|------|-------------------|
| Forgejo tag preflight | Static release checks pass on the exact tagged commit before package upload. |
| Debian package | Package build, clean install and launch gate succeed. |
| AppImage | AppImage, runtime closure, source sidecar and launch gate succeed. |
| Flatpak | Bundle build, clean install and runtime gate succeed. |
| Release assets | Every published Linux package and source archive has its required `.sha256` sidecar. |
| Publish | The draft changes to a published release only after all Linux package jobs succeed. |

Package Windows from the frozen source commit with
`scripts/package-windows-dist.sh`, using an output directory outside `dist/`.
After review, the tag must identify the same commit recorded in
`dist/build-info.txt`. The Forgejo draft stays unpublished until all Linux
jobs succeed; the Windows asset does not start another Linux build.

## Package Build Order

For a new release, use the complete, current procedure in
[WINDOWS_BUILD_EN.md](WINDOWS_BUILD_EN.md#10-publish-a-new-version-as-a-project-maintainer)
or [WINDOWS_BUILD.md](WINDOWS_BUILD.md#10-als-projektbetreuer-eine-neue-version-veröffentlichen).
It includes the Linux preparation, Windows build and ZIP, tag push and Windows
upload in one place. The 2.3.2 tag-recovery instructions below describe that
historical recovery, not the normal procedure for a new release.

Do not start unrelated package workflows in parallel on the Forgejo runner.
The tag-triggered Build workflow is the only Linux package run required for a
normal release.

First install the Linux source-build prerequisites from [BUILD.md](BUILD.md#linux-source-build),
including `sqlcipher` and `xvfb`. From the clean repository root, prepare and
export the exact dependencies consumed by the local release gate:

```bash
(
  set -e
  bash scripts/prepare-linux-source-build-deps.sh
  vendor_root="$(cd "${DINOX_LINUX_VENDOR_ROOT:-$PWD/.vendor-deps}" && pwd -P)"
  export DINOX_LIBWEBRTC_RUNTIME_ROOT="$vendor_root/libwebrtc-m152-linux-x86_64-runtime"
  export DINOX_LOCAL_LIBOMEMO_C_ROOT="$vendor_root/linux-source-deps"
  bash scripts/check-libwebrtc-linux-runtime.sh "$DINOX_LIBWEBRTC_RUNTIME_ROOT" 40 10 6
  read -r -p 'New release version (without v): ' release_version
  ./scripts/release.sh "$release_version" --prepare
)
```

For a new tag, this command changes release metadata and, after its tests and confirmation,
commits and pushes the prepared release commit. It does not create the tag.
The helper configures an optimized Linux build and runs the static, Meson,
database and runtime checks itself; do not manually run the same full gate
again merely to follow the checklist. The abandoned 2.3.2 tag already exists,
so its recovery uses the equivalent gates and guarded replacement below; the
normal helper deliberately refuses to overwrite an existing tag.

1. Finish the merged notes, metadata and build/docs checks; commit and push
   the frozen release tree. Run the local static, Meson, database and runtime
   gates once. An equivalent checked local production configuration may be
   reused; do not wipe a validated tree just to repeat compilation.
2. Pull that exact commit in the frozen Windows VM. Clean-build, run the
   scripted native/package checks and create the ZIP/checksum outside `dist/`.
   Write all output and the final exit status to durable text files; review
   the completed log, with no continuous polling. Correct failures before tagging.
3. For abandoned 2.3.2, first verify the existing release is still a draft and
   no old workflow is active. Record the old tag/object and assets. Remove only
   the superseded draft and its assets, and prepare the corrected annotated
   tag. Never replace a
   published release or unrelated assets through this recovery procedure.
4. Push the annotated tag for the Windows-checked commit, guarding replacement
   with the recorded expected-old tag object. Confirm the new Forgejo run's tag
   and SHA once. It creates the corrected draft, builds Debian, AppImage and
   Flatpak in order, and publishes only after its package checks pass. Refresh
   this replaced tag explicitly in the Windows checkout as well.
5. Hand the matching Windows ZIP and checksum to the maintainer for upload.
   No second Windows build or Linux RC is needed for the same source commit.

Do not start a manual `release_tag` workflow for the same version and do not
publish the Forgejo draft manually while Linux assets are still uploading.
If the tag workflow fails, rerun its failed jobs in Forgejo instead of starting
a separate complete release workflow.

## Manual Smoke Test Matrix

Run this matrix for each package where the feature is supported.

| Area | Smoke test |
|------|------------|
| Startup | Launch from terminal and from desktop/menu where applicable. |
| Icons | App/menu icon and systray icon are DinoX, not a generic fallback. |
| Account | Unlock encrypted databases, add/login account, reconnect after restart. |
| Messaging | 1:1 send/receive, MUC join, MUC message send/receive. |
| File transfer | Receive image/file in 1:1 and MUC, open externally where supported. |
| OMEMO | 1:1 encrypted send/receive and device trust path. |
| OpenPGP | Basic plugin load and no secure-memory warning regression. |
| Calls | 1:1 audio/video call connects and ends cleanly. |
| Audio/video messages | Record, send and play back voice and video messages. |
| Tor/Lyrebird | Enable global Tor with current bridges, connect, disable and verify cleanup. |
| SOCKS5 | Per-account SOCKS5 override still takes precedence over global Tor. |
| Invites | Create invite link, open `xmpp:` invite and register account. |
| Locale | System language default and manual language selection behave as documented. |

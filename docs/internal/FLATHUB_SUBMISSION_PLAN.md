# DinoX Flathub Submission Plan

Status: local maintainer checklist; the final release tag and full commit SHA
must be filled in and all runtime evidence rerun before submission.

This document is a local project plan. It is not a Flathub pull request and
must not be copied verbatim into a submission. Flathub currently requires that
submission pull requests are not generated, opened, or automated using AI tools
or agents. A human maintainer must review the final files and open the Flathub
pull request manually.

## Non-Negotiable Product Boundary

Flathub is an additional distribution channel for DinoX, not the product
authority. DinoX must not lose functionality, reduce security, or introduce
packaging-specific regressions to satisfy a store review.

Acceptable changes:

- AppStream metadata improvements.
- New screenshots and better public presentation.
- A Flathub-specific manifest that builds from a stable public DinoX tag.
- Runtime upgrades when the full Flatpak smoke matrix still passes.
- Permission reductions only when calls, media messages, storage, encryption,
  MQTT, Tor/Lyrebird, notifications, location sharing, and translations still
  work.

Rejected changes:

- Removing Tor/Lyrebird, MQTT, OMEMO, OpenPGP, media messages, calls, local
  encrypted storage, Botmother, or location sharing only to appease review.
- Weakening cryptography or moving secrets into less protected storage.
- Replacing a working package path with a sandbox-only workaround that breaks
  Deb, AppImage, Windows, or the Forgejo Flatpak.
- Using a Flathub review exception as a substitute for understanding runtime
  behavior.

If Flathub requires a change that conflicts with this boundary, the submission
is stopped or withdrawn.

## Current DinoX Baseline

This checklist must be revalidated against the release commit after the
Google/libwebrtc migration. Results recorded for older 2.0.x candidates are
historical and are not acceptance evidence for the current package.

- App ID: `im.dinox.dinox`
- Public domain: `https://dinox.im`
- Source: `https://git.dinox.im/dinoxim/dinox`
- Forgejo manifest: `im.dinox.dinox.json`
- Runtime: `org.gnome.Platform//50`, with the Freedesktop 25.08 SDK extension
  declared by the manifest
- The Forgejo manifest uses local `type: dir`, `path: .`; a Flathub submission
  must replace that with a stable public tag plus its full commit SHA.
- Production media profile: `plugin-google-webrtc=enabled`,
  `google-libwebrtc-wrapper=enabled`, `plugin-rtp=disabled`
- The manifest downloads the public Google/libwebrtc M152 Linux runtime and
  verifies the repository-pinned SHA-256.
- AppStream source: `main/data/im.dinox.dinox.appdata.xml`
- Desktop source: `main/data/im.dinox.dinox.desktop`
- Related Flathub app to avoid confusing with DinoX: `im.dino.Dino`

Re-run these checks for the exact release commit:

```bash
appstreamcli validate --pedantic main/data/im.dinox.dinox.appdata.xml
./scripts/package-runtime-matrix.sh flatpak-manifest im.dinox.dinox.json
flatpak-builder-lint manifest <submission-manifest.json>
flatpak-builder-lint appstream main/data/im.dinox.dinox.appdata.xml
```

The installed candidate must additionally prove that the Google/libwebrtc
wrapper/worker is present, calls and microphone/camera capture work, the Linux
FFmpeg writer creates M4A/MP4 messages, and GStreamer can demux/decode those
files. Old checks for an `rtp` plugin or `libgstnice.so` are not production-call
gates. The DinoX application payload must not add `libgstnice.so`; any copy
provided independently by the base runtime is outside the application module.

Flatpak runtime tests must not be mixed with a running Deb, AppImage, or native
DinoX process using the same app ID. Before `flatpak run im.dinox.dinox`, check
for active DinoX processes and stop them or use an isolated VM/user session.
Installing the Flatpak candidate is low risk, but running it while
`/usr/bin/dinox.real` or another native package is active can collide through
the shared `im.dinox.dinox` application identity and session bus activation.

The current Forgejo manifest is suitable for local and CI package builds, but
is not directly suitable as a Flathub submission because Flathub must build from
public source references rather than the local checkout.

## Official Flathub Requirements To Satisfy

Primary references:

- `https://docs.flathub.org/docs/for-app-authors/requirements`
- `https://docs.flathub.org/docs/for-app-authors/submission`
- `https://docs.flathub.org/docs/for-app-authors/linter`
- `https://docs.flathub.org/docs/for-app-authors/metainfo-guidelines`
- `https://docs.flathub.org/docs/for-app-authors/verification`
- `https://docs.flatpak.org/en/latest/manifests.html`

Hard requirements relevant to DinoX:

- The submitted manifest must be top-level and named `im.dinox.dinox.json`.
- Runtime must be hosted on Flathub and be the latest suitable version at
  submission time.
- Stable Flathub is for stable releases only. Select the final DinoX release
  tag and full commit SHA before creating the submission candidate.
- The repository must not contain application source code or build artifacts in
  the Flathub submission repository.
- Dependencies must be declared as manifest sources with public URLs and hashes,
  so they can be downloaded before the build starts.
- License files for each manifest module must be installed under
  `$FLATPAK_DEST/share/licenses/$FLATPAK_ID` when Flatpak Builder cannot do it
  automatically from standard upstream license filenames.
- Build steps must not require network access.
- Git sources should use `tag` plus `commit`, not a moving branch.
- `type: dir` sources are not accepted for Flathub submissions.
- The main command must be the executable name, not a path.
- The desktop file must have a valid `Exec` and must not include `flatpak run`.
- MetaInfo must validate with Flathub's linter, not just generic AppStream.
- Screenshots must be defined in MetaInfo and mirrored by Flathub's build.
- Submission PR must target Flathub's `new-pr` branch and be opened manually by
  a human maintainer.

## Submission Architecture

Keep two manifest roles:

1. `im.dinox.dinox.json` in the DinoX repository remains the Forgejo package
   manifest used by current CI and release artifacts.
2. A Flathub submission manifest is prepared as a derived artifact for the
   Flathub submission repository. It should have the same filename but replace
   the local DinoX source with a public tagged source reference.

The Flathub-specific manifest must build DinoX from:

```json
{
    "type": "git",
    "url": "https://git.dinox.im/dinoxim/dinox.git",
    "tag": "<release-tag>",
    "commit": "<full release-tag commit SHA>"
}
```

The exact full commit SHA must be written before testing. If Forgejo git clone
over HTTPS is not accepted or unreliable for Flathub, use a public source
archive for the same tag with a fixed `sha256` only after verifying that the
archive content is stable.

Release source decision before submission:

- Every published DinoX release tag stays immutable.
- Submit only the stable release tag selected and fully validated by the human
  maintainer.
- Do not submit a Flathub candidate from moving `master`.
- Do not silently rewrite a public release tag during automation.

## Technical Work Items

### 1. Runtime 50 Probe

Goal: confirm DinoX still works on GNOME Platform/Sdk 50 before opening a
Flathub PR.

Actions:

- Build the exact release manifest with runtime-version `50`.
- Confirm that Runtime 50 is still the current suitable GNOME runtime at
  submission time; update only with a complete runtime regression pass.
- Recheck `codecs-extra` paths for GNOME 50 / Freedesktop runtime alignment.
- Build using `org.flatpak.Builder`, not the Forgejo builder image only.
- Run package matrix and runtime smoke tests.

Go criteria:

- App starts.
- Encrypted local storage unlock works.
- OMEMO and OpenPGP plugins load.
- Voice message recording/playback works.
- Video message recording/playback works.
- 1:1 call setup still reaches media device selection.
- MQTT plugin loads.
- Tor/Lyrebird plugin loads and does not start unexpectedly.
- Location sharing still falls back cleanly if GeoClue is unavailable.
- Translations follow the system language and do not force `LC_ALL=C.UTF-8`.

No-go criteria:

- Media stack regression.
- Plugin load failure.
- SQLCipher/OMEMO storage incompatibility.
- Any permission reduction required before functionality is understood.

### 2. Flathub Source Manifest

Goal: replace local source with the intended stable DinoX release tag and full
public commit reference.

Actions:

- Generate a Flathub candidate manifest from the current Forgejo manifest.
- Replace the `dino` module source from `type: dir`, `path: .` to a public
  `git` source with `tag` and full `commit`.
- Keep DinoX patches minimal and in the submission repository only when they
  are Flathub packaging patches.
- Do not use `branch`.
- Do not use source URLs that require authentication.

Go criteria:

- `flatpak-builder-lint manifest im.dinox.dinox.json` has no hard errors.
- Build works without network access during build steps.
- Built app identifies as the selected release version.

### 3. Vendor Dependency Audit

Goal: make every dependency acceptable and reproducible for Flathub review.

Current vendor source pattern:

- `libcanberra`
- `libnice`
- `tcl`
- `sqlcipher`
- `protobuf`
- `libprotobuf-c`
- `libomemo-c`
- `qrencode`
- `intltool`
- `libevent`
- `tor`
- `lyrebird`
- `cjson`
- `mosquitto`

The `dino` module additionally consumes the pinned public Google/libwebrtc M152
runtime archive. That archive carries the private FFmpeg hardware-provider,
libva and NVIDIA codec-header notices and corresponding sources, plus the
pinned WebRTC FFmpeg/OpenH264 codec sources, notices and GN arguments.
H.264 has software fallback and optional VA-API/NVENC/NVDEC providers; VP8 and
VP9 remain available. The private libraries use `-dinox-hw` names so they do
not replace the Flatpak media stack's full FFmpeg libraries. GPU support must
be exercised inside the sandbox with the actual driver extension and device
permissions. DinoX does not build separate OpenH264 or PipeWire modules in
the Flatpak.

Actions for each module:

- Prefer upstream release URLs when stable and public.
- Keep DinoX Forgejo `vendor-deps` only when it is a deliberate source mirror
  or when upstream assets are not stable enough for CI.
- Document why mirrored sources exist, especially Lyrebird vendored Go sources
  and the pinned Google/libwebrtc runtime archive.
- Keep hashes fixed as `sha256` or `sha512`; never use weak hashes.
- Ensure no module enables build-time network access.

Go criteria:

- Every module has a public URL and a fixed checksum.
- Any mirror choice is explainable in the PR comment.
- No generated dependency bundle is unexplained.
- The installed Google/libwebrtc notices include the exact FFmpeg 8.1.2 and
  libva 2.20.0 source archives and pinned NVIDIA codec headers used for the
  private runtime libraries, including any dependency patches, plus
  the M152 codec source archive and `WEBRTC-CODECS.json`/`WEBRTC-GN-ARGS.gn`.
- The installed package has no legacy `rtp.so`, WebRTC test-oracle binary or
  absolute build RPATH.

### 4. Permission Review

Goal: use the least invasive permissions that preserve DinoX behavior.

Current high-risk permissions to review:

- `--device=all`
- `--share=network`
- `--socket=pulseaudio`
- `--talk-name=org.freedesktop.GeoClue2`
- `--talk-name=org.kde.StatusNotifierWatcher`
- `--filesystem=xdg-run/dinox:create`

There is no direct PipeWire filesystem grant and no custom GStreamer plugin
path. There is also no global `LD_LIBRARY_PATH`: the Google/libwebrtc plugin,
wrapper and worker locate their private libraries through relative `$ORIGIN`
RUNPATH entries.

Required decision for `--device=all`:

- Prove why it is still needed, or replace it with narrower permissions only if
  libwebrtc camera/microphone/calls, video messages, and GStreamer file
  demux/decode still pass.

No permission may be removed just because a linter or reviewer dislikes it. It
must be removed only after functional proof.

Initial Flathub linter result for the older unmodified Runtime 50 candidate:

- `finish-args-portal-talk-name`
- `finish-args-unnecessary-appid-own-name`
- `finish-args-unnecessary-xdg-cache-dinox-create-access`
- `finish-args-unnecessary-xdg-data-dinox-create-access`
- `finish-args-login1-system-talk-name`
- `finish-args-has-socket-gpg-agent`

The repository manifest and local Flathub candidate were made lint-clean by
removing:

- `--talk-name=org.freedesktop.portal.Desktop`
- `--own-name=im.dinox.dinox`
- `--filesystem=xdg-cache/dinox:create`
- `--filesystem=xdg-data/dinox:create`
- `--system-talk-name=org.freedesktop.login1`
- `--socket=gpg-agent`

With those removals, `flatpak-builder-lint manifest` is expected to pass and is
part of the required final check set. `login1` is only used for optional
suspend/resume notification handling, and OpenPGP uses DinoX/GPG subprocess
handling inside the sandbox rather than relying on the host gpg-agent. The
`xdg-run/dinox:create` grant remains until its runtime purpose is traced.

### 5. AppStream And Store Presentation

Current generic validation passes, but Flathub-specific linter still needs to
run from `org.flatpak.Builder`.

Actions:

- Run:

```bash
flatpak run --command=flatpak-builder-lint org.flatpak.Builder appstream main/data/im.dinox.dinox.appdata.xml
```

- Confirm `project_license` is valid and whether `GPL-3.0+` should be changed
  to the modern SPDX expression `GPL-3.0-or-later`.
- Decide whether the installed MetaInfo filename should move from
  `im.dinox.dinox.appdata.xml` to `im.dinox.dinox.metainfo.xml`. The current
  install path is already `/share/metainfo`, but Flathub guidelines prefer the
  modern `%{id}.metainfo.xml` filename.
- Review old translated description paragraphs that still say `Dino` rather
  than `DinoX`. The store listing must not make DinoX look like an accidental
  duplicate of `im.dino.Dino`.
- Confirm screenshots are current, useful, and not misleading.
- Do not use screenshot URLs that track `branch/master`. Flathub review prefers
  stable tag/commit URLs or stable project-hosted website assets.
- Replace screenshots with fresh images from the selected release if needed.
- Confirm screenshot URLs are accessible without authentication.

Screenshot target set:

- Main chat/conversation view.
- Encrypted/private chat indication.
- Voice or video message playback.
- Audio/video call window or device setup.
- Botmother/MQTT/automation UI only if it is polished enough for public store
  presentation.

Screenshots must not expose real private messages, tokens, passwords, invite
links, real contact rosters, or private server state. Use a temporary account or
sanitized local data.

### 6. Flathub Local Build And Lint Gate

Install Flathub builder and GNOME 50 SDK if missing:

```bash
flatpak install -y flathub org.flatpak.Builder
flatpak --system install -y flathub org.gnome.Sdk//50
```

Manifest and AppStream checks:

```bash
appstreamcli validate --pedantic main/data/im.dinox.dinox.appdata.xml
./scripts/package-runtime-matrix.sh flatpak-manifest im.dinox.dinox.json
flatpak run --command=flatpak-builder-lint org.flatpak.Builder manifest im.dinox.dinox.json
flatpak run --command=flatpak-builder-lint org.flatpak.Builder appstream main/data/im.dinox.dinox.appdata.xml
```

Build in two phases. First prove sources are available, then prove the build is
offline after source download:

```bash
flatpak-builder --force-clean --download-only --disable-updates --arch=x86_64 build-dir im.dinox.dinox.json
flatpak-builder --force-clean --disable-updates --disable-download --arch=x86_64 --repo=repo build-dir im.dinox.dinox.json
```

For the final local repo-linter proof, use a builder version that supports full
AppStream media URLs. The `org.flatpak.Builder` Flatpak currently provides this
option. The `--mirror-screenshots-url` argument alone is not enough with older
host `flatpak-builder` versions; the repo must contain a `screenshots/x86_64`
ref and full `https://dl.flathub.org/media/...` URLs.

```bash
flatpak run --filesystem=/tmp --command=flatpak-builder org.flatpak.Builder \
  --force-clean --disable-updates --arch=x86_64 \
  --repo=/tmp/dinox-flathub/repo \
  --compose-url-policy=full \
  --mirror-screenshots-url=https://dl.flathub.org/media \
  /tmp/dinox-flathub/build im.dinox.dinox.json

ostree --repo=/tmp/dinox-flathub/repo refs | grep '^screenshots/x86_64$'
flatpak run --filesystem=/tmp --command=flatpak-builder-lint org.flatpak.Builder repo /tmp/dinox-flathub/repo
flatpak build /tmp/dinox-flathub/build dinox --version
```

If an exception seems necessary, stop and review. Exception requests must be
human-written and justified; do not use AI-generated exception text.

### 7. Human Submission Procedure

The final PR must be opened manually by a human maintainer:

- Fork `flathub/flathub` with all branches.
- Check out `new-pr`.
- Create a submission branch.
- Add only the required submission files.
- Commit manually.
- Open PR against `new-pr`, title: `Add im.dinox.dinox`.
- Answer reviewer questions directly and accurately.
- Trigger test build only after reviewer comments are handled as needed.

After merge:

- Accept Flathub repository invitation within one week.
- Log in to Flathub developer portal.
- Verify the app through the developer portal.
- If website verification is required, place the generated token under
  `https://dinox.im/.well-known/org.flathub.VerifiedApps.txt`.
- Update `https://dinox.im/download/` to prefer Flathub only after the official
  Flathub build is published and verified.

## Regression Gate

The Flathub candidate is acceptable only if the following work:

- startup and encrypted database unlock
- account login
- contact and MUC chat basics
- OMEMO encryption
- OpenPGP plugin load and basic key path
- file upload / receive display
- audio messages
- video messages
- 1:1 call media initialization
- notifications
- systray/background behavior where available
- MQTT plugin load
- Tor/Lyrebird plugin load without unsolicited network start
- location sharing permission/fallback behavior
- language startup and translations

Failure of a non-core Flathub-specific presentation check can be fixed in the
manifest. Failure of DinoX runtime behavior blocks submission.

## First Execution Order

1. Install or update `org.flatpak.Builder` locally.
2. Generate a local Flathub candidate manifest in `/tmp` first.
3. Replace `type: dir` with the selected stable public tag and full commit SHA.
4. Keep runtime 50 in the candidate manifest.
5. Run manifest linter before a full build.
6. Build only after manifest lint is understood.
7. Run runtime smoke and screenshot capture.
8. Bring only generally useful fixes back into the DinoX repo.
9. Keep Flathub-only files outside the DinoX repo until the candidate is proven.

## Current Open Questions

- Does Flathub infrastructure accept `https://git.dinox.im/dinoxim/dinox.git`
  directly as a git source?
- Does the final release candidate still pass the full media/runtime smoke
  matrix on GNOME Platform/Sdk 50?
- Can `--device=all` be reduced without breaking camera/video/call behavior?
- Should the AppStream filename be renamed from `appdata.xml` to
  `metainfo.xml` upstream, or is the current installed `/share/metainfo`
  location sufficient?
- Should public screenshots be replaced with fresh images from the selected
  release before submission?
- Do any vendor-deps URLs need to move back to upstream release URLs for review
  clarity?

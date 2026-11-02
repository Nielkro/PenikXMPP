# Windows build technical details

The [step-by-step guide](WINDOWS_BUILD_EN.md) covers the normal build procedure.
This document contains background information for development and troubleshooting.

## Additional build options

The normal build in step 5 uses the `release` profile with `-O2` and no debug
symbols. Developers can set `DINOX_WINDOWS_BUILD_TYPE=debugoptimized` for
troubleshooting. Both profiles support the application's diagnostic switches.

To use a different log folder, replace the build command in step 5 with:

```bash
DINOX_WINDOWS_LOG_DIR="$HOME/My build logs" DINOX_BUILD_JOBS=2 \
  bash "$HOME/dinox/scripts/build-windows-dist.sh"
```

The log folder must be outside the DinoX source folder. A full rebuild removes
`build/` and `dist/`, but preserves logs stored outside them.

## Architecture

- DinoX and the `google-webrtc.dll` plugin are built in MSYS2/MinGW64.
- The native Google/libwebrtc M152 runtime contains
  `dinox-google-webrtc.dll`, the isolated `dinox-webrtc-worker.exe`, and the
  native smoke tests. The Windows build downloads this validated runtime from
  the public Forgejo `vendor-deps` release.
- The stable DinoX C ABI is the only interface between DinoX and libwebrtc. A
  crash in the separate worker does not terminate the main process.
- Google/libwebrtc captures microphone and camera data for calls and for voice
  and video messages. Windows Media Foundation encodes and muxes M4A/MP4.
- GStreamer demuxes and decodes media files for playback, thumbnails, and
  metadata. The chat audio player sends decoded PCM through an appsink bridge
  to Google/libwebrtc's selected message speaker. GStreamer is neither the
  call backend nor the Windows recording muxer.
- `dinox-backup-tar.exe` is built from DinoX sources against native libarchive.
  It creates and extracts backups using Unicode filesystem paths and archive
  entry names. The portable package includes the helper and its DLL dependencies.
  It supports regular files and directories; links, special files and names
  that Windows cannot represent cause an error without being silently skipped.

## Application-owned GnuPG and native tray

The portable package supplies its complete GnuPG runtime in `dist/bin/`.
DinoX prefers those executables over an installed GnuPG; the build-tree MSYS2
fallback is only for development. The plugin creates and uses
`<DinoX profile>/openpgp/gnupg`, sets its process-local `GNUPGHOME`, and passes
that home explicitly to GnuPG. It does not automatically import or change the
Windows user's default GnuPG keyring. Key-to-account assignments live in the
DinoX profile database: several XMPP accounts share the application keyring,
but selecting a key for one account does not select it for another account.
Passphrase prompts are handled by DinoX's UI. Shutdown stops only the agents
belonging to that application home.

Windows uses `Shell_NotifyIcon` and a native popup menu; its tray does not
require D-Bus. The menu follows DinoX's light/dark style, has colored presence
indicators and action icons, scales to monitor DPI, and exposes its text and
radio/check states to Windows accessibility. High Contrast uses native menu
rendering. GDI drawing links the Windows system import library `gdi32`; no
extra downloadable graphics runtime or bundled `gdi32.dll` is required.
Native notifications keep separate click data for each queued item and are
silent because the existing DinoX notification-sound plugin owns audio.

## Dependencies and automated checks

DNSSEC/DANE requires `mingw-w64-x86_64-unbound` (at least 1.19).
The preparation step also builds a private GIO/GnuTLS module from verified
glib-networking 2.80.1 sources. The bundled patch lets the module read a CA file
under a Windows username containing Unicode characters, without changing
certificate trust checks. The module, patch and license material are stored
under `vendor-deps`; `build-windows-dist.sh` and `update_dist.sh` validate and
copy them into the portable distribution. The installed MSYS2 module is not
replaced. A complete, unchanged cache is reused.

The three Python test packages in the package list are build-machine
dependencies only. The complete builder uses them to run eight DNSSEC/DANE
test groups, including HTTP/1.1 and HTTP/2 through SOCKS5, MQTT cancellation
and client isolation, and XMPP TLS with a Cyrillic CA filename. These tests
use the private GIO module. Test executables, fixture keys and Python packages
are not copied into `dist/`.

The builder also runs the SASL TLS downgrade fixture, account isolation and
the avatar/PubSub/OMEMO reconnect regressions.
These fixtures use isolated profiles and local test servers. No personal
account or production XMPP login is required. A successful build does not
replace an interactive audio/video or Tor/Lyrebird acceptance test.

The five login-protection UI cases require a logged-in Windows desktop. From
its MSYS2 terminal, opt into them with `DINOX_WINDOWS_UI_TESTS=1` for the full
builder, or run them separately after building:

```bash
meson test -C "$HOME/dinox/build" --no-rebuild --print-errorlogs 'Login protection UI runtime'
```

The SSH service lacks a normal desktop session. With GTK 4.22.4 this UI test
crashes during initialization there, while the identical executable passes all
five cases on the desktop. The default SSH build explicitly reports this
additional GUI check as skipped, not passed.

## Pinned dependency versions

The helper downloads the artifacts expected by the repository, verifies their
trust anchors, and prepares exactly this build baseline:

- Pango `1.56.4-3` as one complete matching DLL set; the affected Pango
  1.57/1.58 packages are not approved because of the Win32 color emoji
  regression,
- Tor `0.4.9.12` (signed MSYS2 package mirrored in Forgejo `vendor-deps`),
- `libomemo-c` `0.5.1`,
- Lyrebird `0.8.1`,
- the Google/libwebrtc M152 runtime for Windows x86_64.

The vendor files are then located below `$HOME/vendor-deps`, in particular:

```text
$HOME/vendor-deps/lyrebird-0.8.1/lyrebird.exe
$HOME/vendor-deps/libwebrtc-m152-windows-x86_64/
$HOME/vendor-deps/windows-license-material/
$HOME/vendor-deps/windows-msys2-source-cache/
```

The pinned runtime uses ABI 40, control IPC 10 and video ring 6. M152 is
branch `7977`, source commit `6f37672d358475cd17544121a12494da454d85fb`. Its
SDK and codec sources are unchanged; DinoX's effects and a separate
inference worker are added. The final `dist/` keeps `dinox-vision-worker.exe`,
`dinox-vision-models/`, `dinox-vision-licenses/` and the Vision manifest/checksum
files beside the WebRTC DLL. Calls do not download models. The builder must
execute the native and portable-package smoke tests on Windows; a native
server cross-build or a static manifest check cannot replace them. Physical
device tests and interactive call acceptance are separate release gates.

The libwebrtc runtime comes from the public Forgejo
[`vendor-deps`](https://git.dinox.im/dinoxim/dinox/releases/tag/vendor-deps)
release. The script verifies hashes pinned in the repository and stops on
missing, mismatched, or non-executable components. Do not manually replace
individual files with files from another MSYS2 or DinoX version.
For the Go toolchain version embedded in Lyrebird, it downloads the exact
official Go source using the SHA-256 digest published by `go.dev` and stages
`LICENSE` and `PATENTS`. Source archives and signatures remain outside
`dist/` in the vendor cache.

GStreamer remains installed for demuxing, decoding, playback, thumbnails, and
metadata. The portable directory must not contain GStreamer live-call plugins
for RTP, WebRTC, DTLS, SRTP, or NICE as the DinoX call stack.

### User names containing Unicode characters and spaces

Use the [complete build command in step 5](WINDOWS_BUILD_EN.md#5-build-dinox-from-scratch) for paths such as
`C:/msys64/home/Игорь/dinox` or `C:/msys64/home/Игорь Петров/dinox` too.
The script enables UTF-8 for its Python
helpers and automatically generates `build/windows-compiler-native.ini`.
That file selects
[`windows-compiler-paths.py`](../../scripts/windows-compiler-paths.py) in
front of the existing MinGW compilers. The helper makes recognized absolute
Unicode file paths on the same drive relative to the current working
directory. Meson's and CMake's own compiler probes use this invocation too.
Internal Vala and linker paths are also relative to the build directory on
Windows.

Runtime and package checks also invoke MinGW tools such as `objdump`, `nm`
and `strings` from the corresponding directory with relative file names.
The package check's small C test helpers use relative source and output paths
too. Signature verification uses `gpgv`'s exit status independently of the
encoding of its diagnostic output.

Only the Windows build script applies this setup. It requires no additional
compiler, package or DLL. The generated native file belongs to this checkout
and is recreated by each clean build; do not copy it from another build.
Running `meson setup build` manually does not apply this setup.

If an older build fails with `cannot find` for a path such as
`C:/msys64/home/Игорь/...` or hangs during CMake's compiler check, first stop
that build and its associated child processes. Then update the checkout as
described in [step 3](WINDOWS_BUILD_EN.md#3-get-the-source-and-choose-a-version) and repeat [step 5](WINDOWS_BUILD_EN.md#5-build-dinox-from-scratch). Keep the previous complete log for
diagnosis.

This is the only supported command for a complete Windows development or
release build. The script:

- removes old `build/` and `dist/` directories first,
- validates the pinned Pango, Tor, Lyrebird, and Google/libwebrtc components
  and builds against the prepared `libomemo-c` `0.5.1`,
- runs the native Google/libwebrtc smoke tests,
- sets up Unicode-safe compiler invocations for Meson and CMake,
- configures the fixed production profile and builds every target,
- runs the native backup archive tests, including independent GNU/PAX archive
  compatibility, Unicode filenames and rejection of unsafe entries,
- creates a completely new `dist/`,
- maps every packaged PE file by its SHA-256 digest exactly to DinoX,
  Google/libwebrtc, Lyrebird, `libomemo-c`, or an installed MSYS2 package,
- inventories copied themes, fonts, schemas, runtime translations, Tor data,
  and CA certificates through their exact MSYS2 file owner,
- reads the Go version and every module actually embedded in the finished
  Lyrebird binary, cross-checks them against the pinned vendored source tree,
  and maps each module to its license texts,
- copies actual license, copyright, notice, and patent texts. If an MSYS2
  binary package installs no text, its signed, exact-version source-only
  package is verified and only its license material is copied into `dist/`;
  the large source package remains in the vendor cache,
- validates the portable PE DLL closure and required plugins, executables,
  portable cache templates, data, and the complete license inventory,
- removes an incomplete `dist/` whenever a gate fails.

### Mandatory distribution checker

As its final step, `build-windows-dist.sh` automatically runs the complete
checker:

```bash
bash "$HOME/dinox/scripts/check-windows-dist.sh" "$HOME/dinox/dist"
```

This is not an optional final check. The Windows build succeeds only after
this checker has passed. It:

- loads all nine packaged DinoX plugins, actually calls their
  `register_plugin()` entry points, and validates the returned DinoX plugin
  types,
- requires every catalog listed by the three `LINGUAS` files: currently 30 each
  for DinoX, OMEMO and OpenPGP, for a total of 90 `.mo` files; English uses
  source strings and does not require its own catalog,
- runs additional German and Russian translation smokes from the portable
  package and repeats the real program launch from a temporary installation
  path and with an isolated user profile, both containing spaces and Unicode
  characters,
- validates required GTK/GStreamer runtime data, GnuPG including `gpg-agent`
  and `dirmngr`, the portable DLL closure, and the complete file and license
  inventories.

The checker also requires the built backup helper's UTF-8 process manifest
and runs it with the portable DLL search path. The actual application's
Unicode runtime smoke creates and restores an archive containing a Unicode
filename and compares the restored contents.

Only fully maintained languages are offered. Run
`python3 "$HOME/dinox/scripts/check_translations.py" --syntax-only` to check all three domains
against the current source; this check also runs before commits and in CI.
The Dist checker additionally requires every catalog from `LINGUAS`, generated
by Meson with `msgfmt`, to be present and non-empty in the package. It does not
replace the source coverage check. DinoX uses English for unsupported language
choices.

If the checker fails, the complete build fails and `build-windows-dist.sh`
removes the incomplete `dist/`. The command above can revalidate an existing
tree, but it never replaces the canonical complete build.

A German or Russian runtime-smoke failure is therefore not an ignorable
translation warning. It means that the portable package does not work reliably
from a supported installation or user-profile path. Do not use or distribute
the removed or incomplete `dist/` tree in that case.

Running only `meson setup --reconfigure`, building an individual Ninja target,
or manually copying an EXE into `dist/` does not produce a valid Windows test
build.

The production profile enables Google/libwebrtc, OMEMO, OpenPGP, ICE, HTTP
files, MQTT, and notification sounds. The old GStreamer RTP call stack and
`webrtc-audio-processing` remain disabled.

## Portable package contents and checks

```text
dist/dinox.exe
dist/build-info.txt
dist/dinox-google-webrtc.dll
dist/dinox-webrtc-worker.exe
dist/dinox-vision-worker.exe
dist/dinox-vision-models/{selfie_segmenter_landscape-v1,blaze_face_short_range-v1}.tflite
dist/dinox-vision-licenses/
dist/dinox-vision-runtime-manifest.json
dist/dinox-vision-SHA256SUMS
dist/plugins/google-webrtc.dll
dist/plugins/omemo.dll
dist/plugins/openpgp.dll
dist/plugins/http-files.dll
dist/plugins/ice.dll
dist/plugins/mqtt.dll
dist/plugins/notification-sound.dll
dist/plugins/bot-features.dll
dist/plugins/libtor-manager.dll
dist/bin/{gpg,gpg-agent,gpgconf,gpg-connect-agent,dirmngr,pinentry-w32}.exe
dist/bin/{tor,lyrebird,openssl,dinox-backup-tar,gpgme-w32spawn}.exe
dist/{gspawn-win64-helper,gspawn-win64-helper-console,gpgme-w32spawn}.exe
dist/share/licenses/dinox/google-libwebrtc/{LICENSE,LICENSE.md,PATENTS,manifest.json}
dist/share/licenses/dinox/dinox/{LICENSE,NOTICE,AUTHORS}
dist/share/licenses/dinox/WINDOWS-PE-INVENTORY.tsv
dist/share/licenses/dinox/WINDOWS-ASSET-INVENTORY.tsv
dist/share/licenses/dinox/WINDOWS-STATIC-COMPONENTS.tsv
dist/share/licenses/dinox/WINDOWS-LICENSE-FILES.tsv
dist/share/licenses/dinox/THIRD_PARTY_NOTICES.md
```

The gates execute packaged helper programs with a sanitized search path and
verify that no dependency has to be loaded unnoticed from `/mingw64` or
`build/`. For GnuPG, they start `gpg-agent` and `dirmngr` in an isolated
temporary home, query `dirmngr`, and stop both processes again. The license
gate requires 100 percent coverage of all PE files and bundled third-party
runtime assets, verifies their hashes, rejects missing actual license texts,
and forbids source archives, package archives, or build caches anywhere in
the portable tree. The license tree is limited to 16 MiB. The GdkPixbuf
loader cache contains only a portable marker; DinoX materializes it with the
actual extraction path in the user cache at startup. Forbidden legacy call
components fail the build as well.

## Runtime maintainers only: rebuild the libwebrtc runtime

Regular developers and end users do not need this section. They obtain the
public, validated runtime through `scripts/prepare-windows-build-deps.sh`.

A new native runtime is built on the designated Linux build host using the
pinned WebRTC M152 checkout and the existing Chromium MSVC/SDK toolchain cache.
The dependency helper fetches the validated M152 runtime. A complete Windows
application build and real call tests remain separate acceptance steps. Use a
separate artifact directory for new candidates and preserve older public assets.

```bash
cd /path/to/dinox || exit 1
scripts/build-libwebrtc-windows-runtime.sh \
  --webrtc-src /path/to/webrtc/src \
  --toolchain-cache /path/to/toolchain-cache \
  --runtime-root /path/to/libwebrtc-m152-windows-x86_64-runtime \
  --build-out /path/to/webrtc/src/out/m152-win-x64 \
  --ffmpeg-root /path/to/ffmpeg-windows-hardware \
  --codec-sources /path/to/webrtc-m152-codec-sources-6f37672d3584-sha256-2b17c14cc13b.tar.gz \
  --vision-runtime /path/to/windows-vision-package/runtime-staging \
  --jobs 2 --skip-sync
```

The script verifies the pin, ABI, PE files, and manifest, then creates the ZIP
and SHA-256 file. The Chromium MSVC/SDK toolchain cache is never distributed
to end users. The codec source archive is required and checked against its
published digest. See [runtime packaging](GOOGLE_WEBRTC_RELEASE_PACKAGING.md)
for the exact native pin, codec configuration and publication gates. Do not run
this builder concurrently with another job using the same WebRTC output.

Build the small hardware dependency first with
`scripts/build-libwebrtc-windows-codec-dependency.sh`: Media Foundation hardware
encoding and D3D11VA hardware decoding. Missing capabilities or driver failures
fall back independently to the corresponding WebRTC software codec. The runtime
contains original sources and the exact patch; the portable package contains
notices, patch text and `CODEC-SOURCES.md` with public source URLs and hashes.

The additional Vision build reuses the pinned toolchains and compiles only
the separate inference targets, without rebuilding the full WebRTC SDK. See
[runtime packaging](GOOGLE_WEBRTC_RELEASE_PACKAGING.md#inference-sources-and-licenses)
for preparation and the matching small source companion. Its validated Vision
`runtime-staging` directory is required by the command above.

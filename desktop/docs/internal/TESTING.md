# DinoX Testing Guide

This document describes the test and verification process for DinoX. It intentionally avoids a full static inventory of every individual test case, because those lists become stale quickly. The authoritative source for exact test coverage is the test source tree and Meson itself.

## Automated Test Baseline

Use the project runner for the current automated baseline:

```bash
./scripts/run_all_tests.sh
```

By default this runs cheap static checks, the strict build, Meson-registered
tests and database maintenance tests. For a smaller check,
`./scripts/run_all_tests.sh --static` runs only documentation, translation
syntax, hidden Unicode, Python and shell syntax, test runner self-test, release
script/helper self-tests, AppImage runtime mirror, runtime matrix self-test, package
metadata and Flatpak manifest checks,
`./scripts/run_all_tests.sh --meson` runs only Meson-registered tests and
`./scripts/run_all_tests.sh --db` runs only database maintenance tests. Use
`./scripts/run_all_tests.sh --self-test` to validate only the runner's argument
handling.
The exact test counts are reported by Meson and the
individual test scripts so this guide does not need manual count updates.

Automated tests are useful for protocol, crypto, parser, helper and database behavior. They do not replace real package/runtime testing for audio/video calls, voice messages, video messages, file uploads, MUC behavior or desktop integration.

The [interop lab source snapshot](../../tests/interop/README.md) versions the host,
native-driver and Android UI helpers used for real-server DinoX/monocles checks.
It is separate from the automated baseline: fixed lab paths, source pins and
private configuration/admission records are required, and importing some modules
already validates those inputs. Read the snapshot's execution boundaries before
using it. Runtime records, profiles, credentials, logs, screenshots and binaries
are kept outside Git.

### Isolate desktop services in GUI probes

Run manual GUI probes with a private `XDG_RUNTIME_DIR` owned by the test user
and mode `0700`. Start Xvfb before `dbus-run-session`, so services activated
on the private bus inherit the test display rather than the desktop display.
Separate config/data/cache directories alone do not isolate desktop services.

When accessibility is not under test, use `GTK_A11Y=none` for GTK4 and
`NO_AT_BRIDGE=1` for GTK3. GTK3 does not recognize `GTK_A11Y`. Actual GTK4
accessibility tests use `GTK_A11Y=test`; do not apply these probe flags to
normal DinoX launches. A private D-Bus session with the desktop runtime path
can replace and later remove the desktop's AT-SPI socket.

For release preparation, use [RELEASE_READINESS.md](RELEASE_READINESS.md) as the
operational checklist. It combines the automated gates here with package,
Forgejo, website and manual smoke-test requirements.

## Test Layers

| Layer | Command | Purpose |
|-------|---------|---------|
| Meson tests | `meson test -C build --print-errorlogs` | Runs all Meson-registered test binaries. |
| DinoX test runner | `./scripts/run_all_tests.sh --meson` | Runs the strict build wrapper first, then runs all Meson-registered tests. |
| DinoX test runner self-test | `./scripts/run_all_tests.sh --self-test` | Checks runner help output and invalid argument handling without running suites. |
| DB maintenance CLI tests | `./scripts/test_db_maintenance.sh` | Tests SQLCipher rekey/reset/checkpoint behavior with temporary databases. |
| DB integration tests | `./scripts/run_db_integration_tests.sh` | Compiles and runs Vala tests against `libqlite.so`. |
| Translation syntax and coverage | `./scripts/check_translations.py --self-test && ./scripts/check_translations.py --syntax-only` | Checks UI resources for unmarked labels, PO syntax and every offered language against fresh source extraction in main, OMEMO and OpenPGP, including all plural forms. All three LINGUAS lists must match the UI choices (plus source English and System). Inactive PO files may remain unfinished. Fix regressions in established complete languages instead of removing them from LINGUAS. |
| Windows build session self-test | `bash scripts/build-windows-dist.sh --self-test` | Exercises console/file output, unique Unicode log paths, compiler and log-writer failures, and refusal of simulated elevated/unknown Windows privileges before deleting build artifacts. Does not compile Windows code or prove native Windows ACL behavior. |
| Translation catalog lookup | `./build/libdino/libdino-test -p /LocaleSearchPath` | Verifies main and plugin catalog lookup without an English or German marker file, including stale installed catalogs, portable layouts, per-domain overrides and installed fallback. A directly bound UI-test catalog does not exercise this lookup. |
| Hidden Unicode | `./scripts/scan_unicode.py --self-test && ./scripts/scan_unicode.py` | Self-tests detection of dangerous Unicode control characters, then scans Git-tracked source and PO/POT translation files. |
| Python syntax | `./scripts/check-python-syntax.py --self-test && ./scripts/check-python-syntax.py` | Self-tests py_compile validation, then checks Git-tracked Python files. |
| Shell syntax | `./scripts/check-shell-syntax.sh --self-test && ./scripts/check-shell-syntax.sh` | Self-tests default discovery, then checks Git-tracked shell scripts under `scripts/` by `.sh` suffix or `sh`/`bash` shebang. |
| Local release scripts | `./scripts/release.sh --self-test && ./scripts/release_helper.sh --self-test` | Self-tests release CLI dispatch and version argument validation without editing files, creating tags or pushing. |
| Forgejo release helper | `./scripts/forgejo-release.sh --self-test` | Self-tests release command dispatch, tag, body, asset, paired checksum sidecar and checksum validation without Forgejo API access or uploads. |
| Forgejo release preparation | `./scripts/prepare-forgejo-release.sh --self-test` | Self-tests release CLI dispatch, tag validation and missing local tag handling without Forgejo API access or uploads. |
| Forgejo release-candidate verifier | `./scripts/verify-release-candidate.sh --self-test` | Self-tests the read-only RC proof logic without Forgejo API access. |
| AppImage runtime mirror | `./scripts/mirror-appimage-runtimes.sh --self-test` | Self-tests mirror argument handling and upload token checks without downloading or uploading runtime assets. |
| Runtime matrix | `./scripts/package-runtime-matrix.sh <mode> [target]` | Checks package/runtime media coverage, app metadata, tracked AppStream screenshot asset links, declared screenshot dimensions and its own self-test logic, including packaged GStreamer plugin-list consistency. |
| Manual runtime checks | see below | Verifies behavior that automated tests cannot cover reliably. |

## Quick Start

From the project root:

```bash
# Install the distribution packages from BUILD.md first.
bash scripts/prepare-linux-source-build-deps.sh
export DINOX_LIBWEBRTC_RUNTIME_ROOT="$PWD/.vendor-deps/libwebrtc-m152-linux-x86_64-runtime"
export DINOX_LOCAL_LIBOMEMO_C_ROOT="$PWD/.vendor-deps/linux-source-deps"
export PKG_CONFIG_PATH="$DINOX_LOCAL_LIBOMEMO_C_ROOT/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

meson setup --wipe --prefix=/usr --buildtype=debugoptimized build \
  -Dlocal-libomemo-c-root="$DINOX_LOCAL_LIBOMEMO_C_ROOT" \
  -Dplugin-mqtt=enabled \
  -Dplugin-rtp=disabled \
  -Dplugin-google-webrtc=enabled \
  -Dgoogle-libwebrtc-wrapper=enabled \
  -Dgoogle-libwebrtc-runtime-root="$DINOX_LIBWEBRTC_RUNTIME_ROOT" \
  -Dgoogle-libwebrtc-test-oracle=false \
  -Dgoogle-libwebrtc-tests=false \
  -Dlocation-sharing=enabled

./scripts/build.sh --strict
meson setup --reconfigure build -Dgoogle-libwebrtc-tests=true
./scripts/build.sh --strict
meson test -C build --print-errorlogs
meson setup --reconfigure build -Dgoogle-libwebrtc-tests=false
```

Use the optimized development profile for local video comparisons. A default
unoptimized debug build is not a like-for-like comparison with a release Deb.
Compare the same source commit, runtime manifest and negotiated video codec
before attributing incoming-video stutter to the peer or to M152.

Or use the project runner:

```bash
./scripts/run_all_tests.sh --meson
```

Documentation, translation syntax, hidden Unicode, Python/shell syntax
self-test/check, test runner self-test, local release script/helper self-tests,
Forgejo release helper self-tests, runtime matrix self-test, AppImage runtime mirror
self-test, package metadata and Flatpak manifest checks only:

```bash
./scripts/run_all_tests.sh --static
```

The local `scripts/pre-commit` hook runs the same cheap documentation,
translation syntax, hidden Unicode, Python/shell syntax self-test/check, test
runner self-test, local and Forgejo release helper self-tests, AppImage runtime
mirror self-test, runtime matrix self-test and package metadata gates before the
compiler-warning check.

Full local regression check:

```bash
./scripts/run_all_tests.sh
```

DB-only check:

```bash
./scripts/run_all_tests.sh --db
```

## Meson Test Suites

Meson registers the enabled core/plugin suites and the Google/libwebrtc
protocol, worker and media smokes:

```bash
meson test -C build --list
```

Representative suite names:

```text
Tests for xmpp-vala
Tests for libdino
Tests for main
Tests for http-files
Tests for omemo
Tests for openpgp
bot-features-test
mqtt-test
google-webrtc-engine-smoke
google-webrtc-signaling-smoke
google-webrtc-jingle-engine-smoke
google-webrtc-jingle-wire-smoke
google-webrtc-jmi-wire-smoke
google-webrtc-audio-only-smoke
google-webrtc-process-audio-only-smoke
google-webrtc-process-jmi-wire-smoke
```

Native wrapper builds additionally register `google-webrtc-video-codec-smoke`,
`google-webrtc-h264-call-smoke`, `google-webrtc-vp9-call-smoke`,
`google-webrtc-vp8-call-smoke` and `google-webrtc-muji-sdp-smoke`. The codec
test encodes and decodes key/delta frames through the actual factories;
the call tests exchange Opus audio and the selected video codec between two
worker-backed peers. Hardware encode and decode have separate H.264 smokes;
each requires real output frames and verifies that the active implementation
stays on hardware. An unavailable GPU or unsupported real-time encoder returns
skip status 77, which is not a hardware pass. The Linux VP8 decoder smoke
also checks the private FFmpeg provider without requiring a GPU.

`google-webrtc-vp8-qualification-smoke` checks the automatic-selection policy,
including timing boundaries and invalid measurements, without opening a GPU.
`google-webrtc-vp8-automatic-decoder-smoke` exercises first-use qualification,
cached selection, an explicit software override and real frame decoding. The
hardware-required mode returns 77 when the device is unavailable or hardware
fails qualification; that is not a successful hardware test. Qualification uses
16 synthetic key/delta frames at each of 640×480 and 1280×720, including transfer
to usable I420 and a software reference. It is a short local suitability check,
not proof of all live-network conditions or power savings.

To regenerate the embedded fixtures with the pinned SDK, explicitly build
`google-webrtc-vp8-probe-fixture-generator` in a native wrapper build and pass
the output header path. This developer-only target is not built by default or
installed. The application only decodes its embedded fixtures; it never runs
an encoder or opens a camera to perform qualification.

`google-webrtc-hardware-unavailable-fallback-smoke` exercises automatic
software selection with an unavailable device. The codec test's
`--runtime-failure` mode injects hardware initialization and runtime failures
independently into encoder and decoder wrappers, then checks real H.264
frames, the encoder's new IDR, decoder recovery at the next keyframe and RTP
timestamp wraparound. `google-webrtc-hardware-rate-control-smoke` checks
bounded Linux hardware restarts and software fallback on fast rate reductions.
Windows has an additional private MF/D3D11 provider check without a GPU.

Provider availability, a software fallback pass and GPU execution are separate
results. Record the actual adapter, driver, active encoder/decoder and skip
status; compilation does not prove hardware execution. These checks do not
replace real Monal or Windows interoperability tests. See
[GOOGLE_WEBRTC_WRAPPER_ABI.md](GOOGLE_WEBRTC_WRAPPER_ABI.md).

The project runner executes them as:

| Suite | Area |
|-------|------|
| `Tests for xmpp-vala` | XMPP protocol, XML, JID, XEP parsers, MAM, Stream Management, MUJI and related protocol helpers. |
| `Tests for libdino` | Core data structures, crypto helpers, file transfer and SRTP helper logic. |
| `Tests for main` | UI helper logic and view model behavior that can be tested without a live UI session. |
| `Tests for http-files` | HTTP upload/download, URL/filename/sanitization, cancellation, concurrent requests and preservation of transport error codes. |
| `Tests for omemo` | Native OMEMO helpers, OMEMO 2 crypto/parser behavior and safety checks. |
| `Tests for openpgp` | OpenPGP stream logic, key list parsing and armor parsing. |
| `bot-features-test` | Bot feature utility logic, Botmother API behavior, rate limiting, hashes and JSON escaping. The HTTP API subgroup needs local test sockets; sandboxed environments that deny socket creation report that subgroup as skipped. |
| `mqtt-test` | MQTT topic matching, config validation, aliases and formatting helpers. |

Run a single suite:

```bash
meson test -C build 'Tests for omemo' --print-errorlogs
meson test -C build 'mqtt-test' --print-errorlogs
```

## Direct Test Binaries

The HTTP regression tests use loopback sockets and temporary databases, not real
accounts or upload services. `MetadataHeadCancellation` includes a server that
deliberately withholds the HEAD response and verifies `IOError.TIMED_OUT`.
`HttpDownloadCancellation` checks that both metadata lookup and GET preserve a
connection-refused error. `FileManagerTest/FileManager_localized_timeout_schedules_retry`
uses a Russian timeout message to check retry scheduling, manual retry and the
verified stored payload. Together these cover error propagation and recovery;
they do not prove why a particular remote upload service timed out.

The static AppDir checks in `scripts/package-runtime-matrix.sh` also verify GIO
desktop/TLS modules, the GTK media module, HEIF decoders, libcanberra backends,
NSS software-token modules, OpenSSL providers/engines, proxy schemas and the
fallback sound theme. AppRun must select package-local module paths. The tests
reject the old GIO extra-path-only setup, a GTK media module with no redirected
lookup path, an unpatched libcanberra and missing runtime modules.
`scripts/prepare-canberra-runtime.sh --check PRIVATE_PREFIX` verifies the private
sound library, its source archives, exact build recipe and licenses.

For a module-loader change, test the same AppDir on Ubuntu 24.04, Debian 13,
Fedora, Arch Linux and openSUSE. Use isolated
profiles and inspect loaded paths, not just exit status: exercise GIO TLS and
proxy discovery, GTK media-file creation, HEIF decoder discovery, libcanberra
backends and NSS initialization. Test an HTTPS HEAD/GET against a local test
server, including rejection of a mismatched certificate hostname. Containers
need their normal display-driver libraries and a virtual display for GTK;
they do not prove real GPU, audio-device or full desktop integration.
`AppRun --version` alone does not exercise dynamically loaded modules. Keep
these bounded runtime probes outside Forgejo/DIND; CI uses static checks.

The Linux-only `AppImage system TLS trust` Meson test exercises the production
trust-store setup: native-package handling remains unchanged, the selected CA
bundle is loaded, a trusted localhost certificate passes, a wrong hostname and
an unrelated certificate fail, and invalid bundle paths are rejected without
replacing the active database. The fixtures contain public test certificates,
not private keys. Run it with:

```bash
meson test -C build 'AppImage system TLS trust' --print-errorlogs
```

Also test an HTTPS request using the default GIO database on each distribution.
A SoupSession with an explicitly supplied test database does not exercise this
AppImage startup path. The openSUSE Leap 16.0 check on 2026-11-01 reproduced an
empty default trust store before the fix and a successful HTTPS request after
loading the system's `/etc/ssl/ca-bundle.pem` through the production helper.
The six regression cases passed natively and with the prepared AppDir libraries
on Arch and Leap.

Wayland checks must use `GDK_BACKEND=wayland` and confirm a mapped window, not
an XWayland fallback. Test both the normal renderer and `GSK_RENDERER=cairo`.
On 2026-11-01 the prepared AppDir's GTK, media and TLS modules passed these
checks under Arch/KWin and Leap/Weston. The minimal Leap container first had no
fonts at all; installing its DejaVu font package removed the resulting GTK
layout warnings and Cairo crash. A desktop font installation is part of this
test environment. The locally rebuilt DinoX executable also presented its own
Wayland window using the prepared AppDir libraries in both sessions, with
isolated empty profiles and bounded eight-second runs. The Arch container's
desktop portals reported missing display/FUSE services; portal acceptance was
not established. These checks cover virtual compositor sessions; full Plasma
integration, real graphics hardware, fractional scaling, tray icons, portal
dialogs and audio/video devices still require desktop acceptance tests. A
prepared AppDir is not proof of a newly built release AppImage.

After `./scripts/build.sh --strict`, the regular test binaries are available
under `build/`. Google/libwebrtc smoke binaries additionally require
`-Dgoogle-libwebrtc-tests=true`; `run_all_tests.sh --meson` handles that test
profile and restores the production profile automatically.

Set the library path before running binaries directly:

```bash
export LD_LIBRARY_PATH=build/libdino:build/xmpp-vala:build/qlite:build/crypto-vala:${LD_LIBRARY_PATH:-}
```

Common direct runs:

```bash
build/xmpp-vala/xmpp-vala-test
build/libdino/libdino-test
build/main/main-test
build/plugins/omemo/omemo-test
build/plugins/openpgp/openpgp-test
build/plugins/http-files/http-files-test
build/plugins/bot-features/bot-features-test
build/plugins/mqtt/mqtt-test
```

List tests inside a binary:

```bash
build/plugins/omemo/omemo-test -l
```

Run one test by path:

```bash
build/plugins/omemo/omemo-test -p /Omemo2Crypto/encrypt_decrypt_roundtrip
```

## Archive retractions and custom-emoji fallback

After the strict build, run the focused receive-path regressions:

```sh
build/xmpp-vala/xmpp-vala-test -p /EmojiMarkup
meson test -C build --no-rebuild 'Tests for libdino' --test-args='-p /ArchiveRetractions'
meson test -C build --no-rebuild 'Tests for libdino' --test-args='-p /EmojiFallback'
meson test -C build --no-rebuild 'Tests for libdino' --test-args='-p /MessageCorrection'
```

`ArchiveRetractions` uses isolated SQLCipher databases and the production receive
pipeline. It covers XEP-0425 room-archive authority, correction ordering,
duplicate tombstones, sender/occupant collisions, account/room/PM separation,
room-stable IDs, and the schema-59 upgrade plus persistent schema-60 marker.
Tombstones retain identity and correction references without creating visible
empty messages. They follow the normal message history/account deletion rules.
Live XEP-0424 retractions continue through the existing handler.

The Meson commands also isolate the file and cache directories from the user's
profile. Keep that environment when running the file-transfer tests directly.

`EmojiMarkup` checks namespace handling, Unicode ranges, fallback text and
hash-referenced XEP-0514 resources. `EmojiFallback` runs the complete core receive
pipeline for emoji-only and mixed emoji/file messages. These tests do not fetch
emoji URLs, join a room, use a real account, or claim custom-image rendering.
The compatibility path does not advertise `urn:xmpp:markup:emoji:0`.

## Test Source Locations

Primary test directories:

```text
xmpp-vala/tests/
libdino/tests/
main/tests/
plugins/omemo/tests/native/
plugins/openpgp/tests/
plugins/http-files/tests/
plugins/bot-features/tests/
plugins/mqtt/tests/
tests/
```

Use `rg` to find tests for a feature:

```bash
rg -n "MAM|OMEMO|MUJI|srtp|http upload|mqtt|rekey" \
  xmpp-vala/tests libdino/tests main/tests plugins tests
```

## Optional Remote XMPP Smokes

Remote smokes are disabled by default and must never run from CI or a normal
developer test pass without explicit credentials. The private-MUC affiliation
smoke verifies the real server side of the file-transfer recipient gate without
sending a file, requesting an HTTP slot or changing OMEMO/OpenPGP wire formats.

It requires an externally prepared members-only and non-anonymous MUC where the
test account may query the `member`, `admin` and `owner` affiliation lists.
Run only with disposable test accounts:

```bash
export DINOX_REMOTE_MUC_SMOKE=1
export DINOX_REMOTE_MUC_JID='alice@example.test'
export DINOX_REMOTE_MUC_PASSWORD='...'
export DINOX_REMOTE_MUC_ROOM='room@conference.example.test'
export DINOX_REMOTE_MUC_EXPECTED_MEMBERS='alice@example.test,bob@example.test'

build/libdino/libdino-test \
  -p /RemotePrivateMucSmoke/private_muc_affiliation_snapshot_env
```

Optional variables:

```text
DINOX_REMOTE_MUC_HOST
DINOX_REMOTE_MUC_PORT
DINOX_REMOTE_MUC_NICK
DINOX_REMOTE_MUC_ROOM_PASSWORD
DINOX_REMOTE_MUC_JOIN=1
DINOX_REMOTE_MUC_TIMEOUT_SECONDS
```

Without `DINOX_REMOTE_MUC_SMOKE=1`, this test must skip and open no network
connection.

The private-MUC bootstrap smoke creates and destroys a generated room on a real
MUC service. It logs in one disposable owner account, configures the generated
room as members-only and non-anonymous, assigns the configured member bare JIDs,
then runs the same affiliation snapshot/cache assertions through
`MucManager.query_private_muc_affiliation_snapshot()`.

```bash
export DINOX_REMOTE_MUC_BOOTSTRAP=1
export DINOX_REMOTE_MUC_JID='owner@example.test'
export DINOX_REMOTE_MUC_PASSWORD='...'
export DINOX_REMOTE_MUC_SERVICE='conference.example.test'
export DINOX_REMOTE_MUC_MEMBER_JIDS='member1@example.test,member2@example.test'

build/libdino/libdino-test \
  -p /RemotePrivateMucSmoke/private_muc_bootstrap_affiliation_snapshot_env
```

The same bootstrap smoke can be run through the small wrapper, which validates
the required environment, compiles `libdino/libdino-test` with remote MUC env
unset, and prints only a short pass marker on success:

```bash
./scripts/run-remote-private-muc-smoke.sh --bootstrap --preflight
./scripts/run-remote-private-muc-smoke.sh --bootstrap
```

Optional variables:

```text
DINOX_REMOTE_MUC_HOST
DINOX_REMOTE_MUC_PORT
DINOX_REMOTE_MUC_NICK
DINOX_REMOTE_MUC_BOOTSTRAP_ROOM_PREFIX
DINOX_REMOTE_MUC_TIMEOUT_SECONDS
```

Use `--prepared-room` with `DINOX_REMOTE_MUC_SMOKE`-style environment when an
externally prepared members-only, non-anonymous room should be queried instead
of creating a temporary room. On 2026-05-25 the wrapper bootstrap mode passed
against `dinox.im`/`conference.dinox.im` with redacted disposable DinoX test
accounts.

Without `DINOX_REMOTE_MUC_BOOTSTRAP=1`, this test must skip and open no network
connection. This smoke does not send files, request XEP-0363 slots, prove
foreign-client behavior, or prove Windows/runtime UI behavior.

The private-MUC HTTP file smoke creates and destroys a generated members-only,
non-anonymous room on a real MUC service, joins two disposable DinoX accounts,
queries the complete private-room affiliation snapshot, sends one tiny
unencrypted file through the public `FileManager.send_file()` path, requests a
real XEP-0363 slot, performs a real HTTPS `PUT`, receives the SFS/HTTP transfer
on the second account, downloads it and verifies the stored payload hash. When
the optional extra-receiver environment is set, the same generated private MUC
also adds, joins and verifies a third DinoX account.

```bash
export DINOX_REMOTE_MUC_FILE_SENDER_JID='sender@example.test'
export DINOX_REMOTE_MUC_FILE_SENDER_PASSWORD='...'
export DINOX_REMOTE_MUC_FILE_RECEIVER_JID='receiver@example.test'
export DINOX_REMOTE_MUC_FILE_RECEIVER_PASSWORD='...'
export DINOX_REMOTE_MUC_SERVICE='conference.example.test'

./scripts/run-remote-private-muc-http-smoke.sh --preflight
./scripts/run-remote-private-muc-http-smoke.sh
```

Optional variables:

```text
DINOX_REMOTE_MUC_HOST
DINOX_REMOTE_MUC_PORT
DINOX_REMOTE_MUC_FILE_SENDER_NICK
DINOX_REMOTE_MUC_FILE_RECEIVER_NICK
DINOX_REMOTE_MUC_FILE_EXTRA_RECEIVER_JID
DINOX_REMOTE_MUC_FILE_EXTRA_RECEIVER_PASSWORD
DINOX_REMOTE_MUC_FILE_EXTRA_RECEIVER_NICK
DINOX_REMOTE_MUC_BOOTSTRAP_ROOM_PREFIX
DINOX_REMOTE_MUC_TIMEOUT_SECONDS
DINOX_REMOTE_MUC_FILE_NAME
DINOX_REMOTE_MUC_FILE_PAYLOAD_TEXT
```

Without `DINOX_REMOTE_MUC_HTTP_FILE_SMOKE=1`, the focused test must skip and
open no network connection. The wrapper sets that flag only for the real run
after validating the environment and compiling `plugins/http-files/http-files-test`
with all remote env unset. On 2026-05-25 the wrapper passed against
`dinox.im`/`conference.dinox.im` with redacted disposable DinoX test accounts;
the optional third-account fanout mode also passed on that date.
On 2026-05-26 the same runner also passed on the Windows MSYS2 build-tree
checkout with two redacted disposable DinoX test accounts.
This smoke proves unencrypted DinoX-to-DinoX private-MUC HTTP/SFS send and
receive runtime only. It does not prove OMEMO/OpenPGP private-MUC sends,
foreign-client behavior, public MUCs, packaged Windows GUI file-send behavior,
server-side upload
retention/deletion, durable jobs or server-ack/MAM retention.

The foreign terminal-client HTTP upload smoke starts DinoX as the receiver and
then drives a real `go-sendxmpp --http-upload` sender. It uses two disposable
one-to-one accounts, waits until the DinoX receiver account has negotiated its
stream, uploads a small payload through the sender account's XEP-0363 service,
sends the resulting OOB/body URL to the DinoX receiver, and verifies that
`FileProvider` plus `FileManager` receive-store persists `COMPLETE` with the
expected payload size and SHA-256 after at-rest decryption.

```bash
export DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_RECEIVER_JID='receiver@example.test'
export DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_RECEIVER_PASSWORD='...'
export DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_SENDER_JID='sender@example.test'
export DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_SENDER_PASSWORD='...'

./scripts/run-remote-foreign-http-upload-smoke.sh --preflight
./scripts/run-remote-foreign-http-upload-smoke.sh
```

Optional variables:

```text
DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_HOST
DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_PORT
DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_TIMEOUT_SECONDS
DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_NAME
DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_PAYLOAD_FILE
DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_GO_SENDXMPP
```

The wrapper writes a temporary `go-sendxmpp` config file with mode `0600` so
the sender password is not passed on the command line. It sets
`DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_SMOKE=1` only for the real receiver test run
after validating the environment, checking that `go-sendxmpp` advertises
`--http-upload`, and compiling `plugins/http-files/http-files-test` with all
remote env unset. Without that smoke flag, the focused test must skip and open
no network connection. This smoke proves terminal-client XEP-0363 HTTP-upload
receive interop into DinoX; it does not prove XEP-0234/XEP-0260 Jingle S5B,
OMEMO/OpenPGP encryption, private-MUC fanout, Windows runtime, server-side
retention/deletion, durable jobs or server-ack/MAM retention.

On 2026-05-26 this wrapper passed against `dinox.im` with redacted disposable
test accounts, using a temporarily extracted `go-sendxmpp` 0.8.3 binary. The
observed sender path was terminal-client HTTP upload with OOB/body URL delivery
into DinoX's one-to-one receive path, not packaged third-party Jingle S5B.

The private-MUC OpenPGP HTTP file-send/receive smoke creates and destroys a
generated members-only, non-anonymous room on a real MUC service, joins two
disposable DinoX accounts, queries the complete private-room affiliation
snapshot, creates isolated temporary XMPP OpenPGP keys, and either seeds the
local OpenPGP test DB as if XEP-0373 had refreshed both account keys this
session or, with `--pubsub-discovery`, publishes and fetches both temporary keys
through real remote XEP-0373 PubSub before sending. It keeps the receiver
online, sends one tiny file through public `FileManager.send_file()` with
`Encryption.PGP`, requests a real XEP-0363 slot, performs a real HTTPS `PUT`,
captures the outgoing XEP-0374 body-url stanza before send, downloads the
uploaded `.pgp` body for sender-side verification, and waits for the receiver to
decrypt/download/store the transfer through the normal HTTP provider path. The
PubSub-discovery path retracts the temporary published keys during cleanup. The
proof checks that the uploaded body decrypts to the original payload and
filename, carries the sender signature, includes sender and receiver recipient
packets, that the HTTP download URL appears only inside the decrypted XEP-0374
signcrypt payload rather than as outer OOB/SFS/attachment metadata, and that the
receiver-side stored file matches the plaintext size/SHA-256 after at-rest
decryption.

```bash
export DINOX_REMOTE_OPENPGP_MUC_FILE_SENDER_JID='sender@example.test'
export DINOX_REMOTE_OPENPGP_MUC_FILE_SENDER_PASSWORD='...'
export DINOX_REMOTE_OPENPGP_MUC_FILE_RECEIVER_JID='receiver@example.test'
export DINOX_REMOTE_OPENPGP_MUC_FILE_RECEIVER_PASSWORD='...'
export DINOX_REMOTE_OPENPGP_MUC_SERVICE='conference.example.test'

./scripts/run-remote-openpgp-private-muc-http-smoke.sh --preflight
./scripts/run-remote-openpgp-private-muc-http-smoke.sh
./scripts/run-remote-openpgp-private-muc-http-smoke.sh --pubsub-discovery
```

The same wrapper also owns the Gate 4 direct one-to-one OpenPGP sender paths
for a separately controlled packaged GUI receiver:

```bash
./scripts/run-remote-openpgp-private-muc-http-smoke.sh --preflight --direct-sender-only
./scripts/run-remote-openpgp-private-muc-http-smoke.sh --direct-sender-only
./scripts/run-remote-openpgp-private-muc-http-smoke.sh --preflight --direct-legacy-xep0027-sender-only
./scripts/run-remote-openpgp-private-muc-http-smoke.sh --direct-legacy-xep0027-sender-only
```

That mode is intentionally not a Jingle/JET path. OpenPGP file transfer uses
HTTP/SFS: the `.pgp` upload is sent through XEP-0363/HTTP, and the HTTP body URL
is kept inside the selected OpenPGP-encrypted XEP-0374 or XEP-0027 message body
rather than exposed as outer SFS/OOB metadata. The direct sender-only gates are
for DinoX-to-DinoX one-to-one OpenPGP only; OMEMO2/JET pipeline gates stay
DinoX-to-DinoX.

For the direct sender-only mode, keep all credentials process-scoped. Required
environment includes the sender and receiver JIDs, the sender password, and
the sender OpenPGP secret-key file path, receiver OpenPGP public-key file path
and their expected fingerprints. Do not store secret-key contents, passwords or
full runtime logs in the docs or repo. If a GUI orchestration keeps the sender
XEP-0373 key published for the receiver fetch window, use only disposable test
accounts and set `DINOX_REMOTE_OPENPGP_HTTP_FILE_ALLOW_PEP_MUTATION=1` in that
process. For XEP-0027, use legacy email-UID key material and account/contact
legacy state; for XEP-0374, use XMPP-UID key material and XEP-0373/XEP-0374
state. The XEP-0027 sender waits for live verified signed-presence activity from
the receiver before sending. The packaged receiver must persist the conversation
as OpenPGP-selected with `encryption=PGP`; an unencrypted receiver chat is not a
valid gate.
On 2026-06-01 the packaged Windows GUI receiver was driven through receive,
default-open and Save-as export with `provider=0`, `encryption=PGP`, protocol
`openpgp:xep0374` and marker
`remote-openpgp-packaged-windows-gui-receiver-open-export-ok`, so the
DinoX-to-DinoX OpenPGP HTTP/SFS receiver/open/export gate is closed for the
XEP-0374 path. XEP-0027 direct receiver/open/export remains a separate follow-up
gate.

Optional variables:

```text
DINOX_REMOTE_OPENPGP_MUC_HOST
DINOX_REMOTE_OPENPGP_MUC_PORT
DINOX_REMOTE_OPENPGP_MUC_FILE_SENDER_NICK
DINOX_REMOTE_OPENPGP_MUC_FILE_RECEIVER_NICK
DINOX_REMOTE_OPENPGP_MUC_BOOTSTRAP_ROOM_PREFIX
DINOX_REMOTE_OPENPGP_MUC_TIMEOUT_SECONDS
DINOX_REMOTE_OPENPGP_MUC_FILE_NAME
DINOX_REMOTE_OPENPGP_MUC_FILE_PAYLOAD_TEXT
```

Without `DINOX_REMOTE_OPENPGP_MUC_HTTP_FILE_SMOKE=1`, the focused test must skip
and open no network connection. The wrapper sets that flag only for the real run
after validating the environment and compiling `plugins/openpgp/openpgp-test`
with all remote env unset. On 2026-05-25 the wrapper passed the send/receive
smoke against `dinox.im`/`conference.dinox.im` with two redacted disposable
DinoX test accounts. On 2026-05-26 the `--pubsub-discovery` mode also passed
against the same server, proving remote XEP-0373 key-data and metadata
publication plus remote fetch/import/fresh-session readiness before the same
private-MUC HTTP send/receive path. These smokes prove DinoX-to-DinoX
private-MUC OpenPGP/XEP-0374 HTTP upload, encrypted body-url containment,
receiver-client decrypt/store and, in the discovery mode, real remote XEP-0373
PubSub key discovery. On 2026-05-26 the seeded default runner also passed on the
Windows MSYS2 build-tree checkout with two redacted disposable DinoX test
accounts, proving the same headless seeded OpenPGP/XEP-0374 private-MUC HTTP
send/receive boundary on Windows. On the same date the `--pubsub-discovery`
mode also passed on the Windows MSYS2 build-tree checkout with the same
redacted disposable accounts, proving the remote XEP-0373 PubSub discovery path
on Windows. The `--legacy-xep0027` mode also passed on Linux and the Windows
MSYS2 build-tree checkout, proving the legacy OpenPGP/XEP-0027 signed-presence
private-MUC HTTP send/receive path. These smokes do not prove public Internet
keyserver behavior, Gajim or other foreign-client behavior, public MUCs,
packaged Windows GUI file-send behavior,
server-side upload retention/deletion, durable jobs or server-ack/MAM retention.

The private-MUC OMEMO HTTP file-send/receive smoke creates and destroys a
generated members-only, non-anonymous room on a real MUC service, joins two
disposable DinoX accounts, queries the complete private-room affiliation
snapshot, seeds an isolated OMEMO1 sender-to-receiver session in the temporary
test stores, sends one tiny file through public `FileManager.send_file()` with
`Encryption.OMEMO`, requests a real XEP-0363 slot, performs a real HTTPS `PUT`,
receives the encrypted body-url message on the second DinoX account, downloads
the file through the normal HTTP provider path and verifies the decrypted stored
payload hash. When the optional extra-receiver environment is set, the same
generated private MUC also adds, joins, keys and verifies a third DinoX receiver.
The proof checks that the outgoing private-MUC stanza is body-only OMEMO: no
outer OOB, SFS source, source list or attachment metadata may carry the URL, and
the fallback body must not contain the `aesgcm://` secret or HTTP download URL.
The runner defaults to the legacy OMEMO1 path. Use `--omemo2` for the seeded
OMEMO2/SCE runtime path, which keeps the same real room, XEP-0363, HTTPS upload
and receiver download/store checks but requires a v2-only seeded sender state.
Use `--pubsub-discovery` for the legacy OMEMO1 path without seeded
sender-to-receiver sessions or trusted-device rows; that mode waits for real
remote PubSub device-list and bundle discovery, asserts identity-key plus
libomemo session state for every configured receiver and sender-receiver reverse
lookup, then sends through the same body-only private-MUC HTTP path.
Use `--omemo2-pubsub-discovery` for the OMEMO2/SCE path without seeded
sender-to-receiver sessions or trusted-device rows. That mode temporarily
publishes controlled v2-only OMEMO PEP device-list and bundle state for
disposable accounts, waits for real remote v2 PubSub discovery and libomemo
session state in both directions, sends through the same private-MUC HTTP path,
then restores and verifies normal v1+v2 current-device PEP state. It requires
`DINOX_REMOTE_OMEMO_MUC_ALLOW_PEP_MUTATION=1`.

```bash
export DINOX_REMOTE_OMEMO_MUC_FILE_SENDER_JID='sender@example.test'
export DINOX_REMOTE_OMEMO_MUC_FILE_SENDER_PASSWORD='...'
export DINOX_REMOTE_OMEMO_MUC_FILE_RECEIVER_JID='receiver@example.test'
export DINOX_REMOTE_OMEMO_MUC_FILE_RECEIVER_PASSWORD='...'
export DINOX_REMOTE_OMEMO_MUC_SERVICE='conference.example.test'

./scripts/run-remote-omemo-private-muc-http-smoke.sh --preflight
./scripts/run-remote-omemo-private-muc-http-smoke.sh
./scripts/run-remote-omemo-private-muc-http-smoke.sh --pubsub-discovery
./scripts/run-remote-omemo-private-muc-http-smoke.sh --omemo2
DINOX_REMOTE_OMEMO_MUC_ALLOW_PEP_MUTATION=1 \
  ./scripts/run-remote-omemo-private-muc-http-smoke.sh --omemo2-pubsub-discovery
```

Optional variables:

```text
DINOX_REMOTE_OMEMO_MUC_HOST
DINOX_REMOTE_OMEMO_MUC_PORT
DINOX_REMOTE_OMEMO_MUC_FILE_SENDER_NICK
DINOX_REMOTE_OMEMO_MUC_FILE_RECEIVER_NICK
DINOX_REMOTE_OMEMO_MUC_FILE_EXTRA_RECEIVER_JID
DINOX_REMOTE_OMEMO_MUC_FILE_EXTRA_RECEIVER_PASSWORD
DINOX_REMOTE_OMEMO_MUC_FILE_EXTRA_RECEIVER_NICK
DINOX_REMOTE_OMEMO_MUC_BOOTSTRAP_ROOM_PREFIX
DINOX_REMOTE_OMEMO_MUC_TIMEOUT_SECONDS
DINOX_REMOTE_OMEMO_MUC_FILE_NAME
DINOX_REMOTE_OMEMO_MUC_FILE_PAYLOAD_TEXT
DINOX_REMOTE_OMEMO_MUC_ALLOW_PEP_MUTATION=1
```

Without `DINOX_REMOTE_OMEMO_MUC_HTTP_FILE_SMOKE=1`, the focused test must skip
and open no network connection. The wrapper sets that flag only for the real run
after validating the environment and compiling `plugins/omemo/omemo-test` with
all remote env unset. On 2026-05-25 the OMEMO1 wrapper passed against
`dinox.im`/`conference.dinox.im` with two redacted disposable DinoX test
accounts; the optional third-account fanout mode also passed on that date. On
2026-05-25 the OMEMO2/SCE mode also passed against the same server with two
redacted disposable DinoX test accounts and again with the optional third
receiver fanout. This smoke proves DinoX-to-DinoX private-MUC HTTP send and
receive runtime for OMEMO1, seeded OMEMO2/SCE and both PubSub-discovered OMEMO
modes with a real XEP-0363 slot, HTTPS upload, body-only encrypted URL
containment, receiver download/decrypt/store, optional third-receiver fanout
and payload-hash verification. On 2026-05-25 the `--pubsub-discovery` mode also
passed against the same server with redacted disposable DinoX test accounts and
optional third-receiver fanout, proving legacy OMEMO1 remote device-list/bundle
discovery before the same private-MUC HTTP send/receive path. On 2026-05-26
the `--omemo2-pubsub-discovery` mode passed against the same server with
redacted disposable DinoX test accounts, first with two accounts and then with
optional third-receiver fanout, proving controlled v2-only OMEMO2 remote
device-list/bundle discovery before the same private-MUC HTTP send/receive
path. On 2026-05-26 the default OMEMO1 and seeded OMEMO2/SCE runners also
passed on the Windows MSYS2 build-tree checkout with two redacted disposable
DinoX test accounts, proving the same headless seeded OMEMO private-MUC HTTP
send/receive boundaries on Windows. On the same date the `--pubsub-discovery`
and `--omemo2-pubsub-discovery` modes also passed on the Windows MSYS2
build-tree checkout with the same redacted disposable accounts, proving the
remote OMEMO1 and controlled remote OMEMO2/SCE PubSub discovery paths on
Windows. These smokes do not prove Gajim or other foreign-client behavior,
public MUCs, packaged Windows GUI file-send behavior, server-side upload
retention/deletion, durable jobs or server-ack/MAM retention.

The remote Jingle S5B smokes verify real-server incoming XEP-0234 offers that
use XEP-0260 S5B. The default, raw-sender, standalone-sender and DinoX-pair
modes are receive-store interop smokes: they do not prove firewall/no-leak
behavior, Windows runtime, encrypted Jingle payloads or durable jobs. The
standalone-sender proxy no-direct mode below is a negative privacy-routing
smoke, not a successful receive-store smoke.

The foreign-client mode waits for an external sender implementation. Use a
disposable receiver account and a disposable sender account with one active
sender resource. Prepare a small payload on the sender side, compute the
expected SHA-256, start the receiver smoke, wait for the ready message or ready
file, then send the payload from the foreign client to the printed receiver
`bound_jid`.

Prepare the expected sender in the receiver's **server-side roster** before
running any Jingle smoke. For the paired modes, give both disposable accounts
each other as roster contacts. The full roster response from a real server
replaces local cached entries; the test's local seed does not substitute for
this setup. Keep these contacts confined to the disposable test accounts.

```bash
sha256sum ./payload.bin

export DINOX_REMOTE_JINGLE_S5B_JID='receiver@example.test'
export DINOX_REMOTE_JINGLE_S5B_PASSWORD='...'
export DINOX_REMOTE_JINGLE_S5B_SENDER_JID='sender@example.test'
export DINOX_REMOTE_JINGLE_S5B_EXPECTED_NAME='payload.bin'
export DINOX_REMOTE_JINGLE_S5B_EXPECTED_SIZE="$(wc -c < ./payload.bin)"
export DINOX_REMOTE_JINGLE_S5B_EXPECTED_SHA256='...'
export DINOX_REMOTE_JINGLE_S5B_READY_FILE=/tmp/dinox-remote-jingle-s5b.ready

./scripts/run-remote-jingle-s5b-smoke.sh --preflight
./scripts/run-remote-jingle-s5b-smoke.sh
```

Optional variables:

```text
DINOX_REMOTE_JINGLE_S5B_HOST
DINOX_REMOTE_JINGLE_S5B_PORT
DINOX_REMOTE_JINGLE_S5B_TIMEOUT_SECONDS
DINOX_REMOTE_JINGLE_S5B_READY_FILE
```

The runner checks required env names and local value ranges without printing
passwords or full expected values. Without `DINOX_REMOTE_JINGLE_S5B_SMOKE=1`,
the underlying libdino test must skip and open no network connection. A no-env
skip or failed preflight is not a remote interop pass. The Jingle remote-smoke
account rows are stored in the temporary DB without passwords; credentials come
from env and stay process-local.

The scripted-raw sender mode also uses two accounts, but the sender side does
not call DinoX `offer_file_stream()`. It connects the sender account, detaches
the normal DinoX Jingle handlers on that stream, builds the Jingle/S5B IQs
directly, exposes a small loopback S5B listener and writes a generated payload
after the receiver selects that candidate:

```bash
export DINOX_REMOTE_JINGLE_S5B_JID='receiver@example.test'
export DINOX_REMOTE_JINGLE_S5B_PASSWORD='...'
export DINOX_REMOTE_JINGLE_S5B_SENDER_JID='sender@example.test'
export DINOX_REMOTE_JINGLE_S5B_SENDER_PASSWORD='...'

./scripts/run-remote-jingle-s5b-smoke.sh --raw-sender --preflight
./scripts/run-remote-jingle-s5b-smoke.sh --raw-sender
```

Optional variables are the same as above, plus
`DINOX_REMOTE_JINGLE_S5B_RAW_NAME` to override the generated filename. This
mode proves real-server incoming Jingle/S5B receive-store against a raw,
scripted sender path through `JingleFileProvider` and `FileManager`; it is still
not the standalone stdlib sender path or a packaged third-party client, not
normal UI sender selection, not the standalone proxy no-direct smoke, not
Windows runtime and not encrypted Jingle payload behavior.

The standalone-sender mode starts the receiver harness and then drives a
stdlib-only Python XMPP/Jingle/S5B sender from
`scripts/foreign-jingle-s5b-sender.py`. The sender intentionally does not import
DinoX or `xmpp-vala` code. Direct helper invocation requires `--run`; the smoke
runner passes it explicitly:

```bash
export DINOX_REMOTE_JINGLE_S5B_JID='receiver@example.test'
export DINOX_REMOTE_JINGLE_S5B_PASSWORD='...'
export DINOX_REMOTE_JINGLE_S5B_SENDER_JID='sender@example.test'
export DINOX_REMOTE_JINGLE_S5B_SENDER_PASSWORD='...'

./scripts/run-remote-jingle-s5b-smoke.sh --standalone-sender --preflight
./scripts/run-remote-jingle-s5b-smoke.sh --standalone-sender
```

Optional variables are the same as above, plus
`DINOX_REMOTE_JINGLE_S5B_STANDALONE_NAME` and
`DINOX_REMOTE_JINGLE_S5B_STANDALONE_PAYLOAD_FILE`. This mode proves real-server
incoming S5B receive-store against an independent stdlib test sender; it is not
a packaged third-party client proof, not the standalone proxy no-direct smoke,
not packaged GUI runtime and not encrypted Jingle payload behavior. On Windows
MSYS2 the runner protects `/RemoteJingleS5bSmoke/...` test paths from MSYS2
argument conversion through `MSYS2_ARG_CONV_EXCL`; on 2026-05-26 the
`--standalone-sender` mode passed from the Windows VM build-tree checkout
against `dinox.im` with redacted disposable accounts.

The standalone-sender proxy no-direct mode starts the receiver account with a
local SOCKS5 guard proxy as its per-account proxy. The stdlib sender offers only
a direct loopback S5B candidate. A pass requires the sender's direct listener to
remain untouched, the receiver `session-accept` to publish no direct
candidates, the receiver to fail the incoming transfer without publishing a
verified file path, and the guard proxy to record a rejected local S5B CONNECT
for the exact direct candidate host/port offered by the sender:

```bash
export DINOX_REMOTE_JINGLE_S5B_JID='receiver@example.test'
export DINOX_REMOTE_JINGLE_S5B_PASSWORD='...'
export DINOX_REMOTE_JINGLE_S5B_SENDER_JID='sender@example.test'
export DINOX_REMOTE_JINGLE_S5B_SENDER_PASSWORD='...'

./scripts/run-remote-jingle-s5b-smoke.sh --standalone-sender-proxy-no-direct --preflight
./scripts/run-remote-jingle-s5b-smoke.sh --standalone-sender-proxy-no-direct
```

Optional variables are the same as standalone-sender mode. This mode proves
real-server per-account SOCKS no-direct behavior for incoming Jingle S5B from
the independent stdlib sender. It does not prove packaged third-party client
behavior, the proxy-success receive-store mode, Tor exit-to-public-candidate success/onion remote-candidate byte-flow,
encrypted Jingle payload behavior or durable jobs. A Windows-MSYS2 run for this
mode passed on 2026-05-26 and is tracked in the pipeline TODO.

The standalone-sender real-Tor no-direct mode runs the same negative boundary
with the receiver account configured for the Tor account-proxy path and an
isolated local Tor SOCKS daemon instead of the guard proxy. A pass requires no
direct candidates in `session-accept`, no sender direct listener connection and
failed receive-store without verified file publication:

These real-Tor Jingle S5B modes exercise the account-proxy SOCKS routing path
with an isolated or externally started Tor SOCKS daemon. They are not an
integrated Tor Manager, Lyrebird bridge-bootstrap or bridge-selection proof
unless a gate explicitly says so; standalone `socks5` account proxy rows and
`proxy_type='tor'` rows are intentionally kept as separate runtime states.

```bash
export DINOX_REMOTE_JINGLE_S5B_JID='receiver@example.test'
export DINOX_REMOTE_JINGLE_S5B_PASSWORD='...'
export DINOX_REMOTE_JINGLE_S5B_SENDER_JID='sender@example.test'
export DINOX_REMOTE_JINGLE_S5B_SENDER_PASSWORD='...'

./scripts/run-remote-jingle-s5b-smoke.sh --standalone-sender-real-tor-no-direct --preflight
./scripts/run-remote-jingle-s5b-smoke.sh --standalone-sender-real-tor-no-direct
```

For stricter diagnostics, set `DINOX_REMOTE_JINGLE_S5B_REQUIRE_TOR_REJECT_LOG=1`
to additionally require Tor's private-address rejection log line. That log
check can false-negative on Tor log wording, level, or flush timing, so it is
not the default pass criterion.

On 2026-05-25 this boundary was first executed manually and later promoted to
the scriptable runner mode above. It proves the real-server receiver no-direct
path with the receiver configured for real Tor SOCKS in the private-candidate
case; it still does not prove packaged third-party client behavior, Tor
exit-to-public-candidate success, onion remote-candidate byte-flow, encrypted
Jingle payload behavior or durable jobs. A Windows-MSYS2 run for this mode passed
on 2026-05-26 and is tracked in the pipeline TODO.

The standalone-sender real-Tor onion success mode uses the same receiver Tor
account-proxy path, but maps the sender's local S5B listener through a temporary
Tor hidden service. The stdlib sender advertises the `.onion` host and virtual
port as its remote S5B candidate while listening on the mapped loopback target.
A pass requires no receiver direct candidates in `session-accept` and the
normal receive-store assertions through persisted `COMPLETE`:

```bash
export DINOX_REMOTE_JINGLE_S5B_JID='receiver@example.test'
export DINOX_REMOTE_JINGLE_S5B_PASSWORD='...'
export DINOX_REMOTE_JINGLE_S5B_SENDER_JID='sender@example.test'
export DINOX_REMOTE_JINGLE_S5B_SENDER_PASSWORD='...'

./scripts/run-remote-jingle-s5b-smoke.sh --standalone-sender-real-tor-onion-success --preflight
./scripts/run-remote-jingle-s5b-smoke.sh --standalone-sender-real-tor-onion-success
```

Optional `DINOX_REMOTE_JINGLE_S5B_TOR_BOOTSTRAP_TIMEOUT_SECONDS`,
`DINOX_REMOTE_JINGLE_S5B_TIMEOUT_SECONDS` and
`DINOX_REMOTE_JINGLE_S5B_ONION_VIRTUAL_PORT` can be used for slow Tor
bootstrap or a different virtual S5B port. On 2026-05-25 this mode passed
against `dinox.im` with two redacted DinoX test accounts. It proves real-server
incoming S5B receive-store through a real local Tor SOCKS daemon to a controlled
temporary onion candidate from the independent stdlib sender; it still does not
prove packaged third-party client behavior, Tor exit-to-public-candidate
success, encrypted Jingle payload behavior or durable jobs. On 2026-05-27 the
same mode also passed on the Windows MSYS2 VM with `/mingw64/bin/tor`, after the
stdlib sender was hardened for hidden-service warmup races, XMPP polling timeouts
and early closed post-warmup hidden-service target connections. The final marker
was `WINDOWS_TOR_ONION_FINAL_HARNESS_EXIT 0 2026-05-27T00:20:36+02:00`. This
proves the corresponding Windows build-tree/headless onion receive-store
boundary; it still is not packaged GUI `dist\dinox.exe`, Gajim/manual GUI,
public-candidate or stable endpoint proof.

The standalone-sender real-Tor public success mode is the opt-in
exit-to-public-candidate gate. It starts the receiver account through an
isolated local Tor SOCKS daemon, advertises
`DINOX_REMOTE_JINGLE_S5B_PUBLIC_CANDIDATE_HOST` from the stdlib sender as the
remote S5B candidate, and requires the normal receive-store assertions through
persisted `COMPLETE`:

```bash
export DINOX_REMOTE_JINGLE_S5B_JID='receiver@example.test'
export DINOX_REMOTE_JINGLE_S5B_PASSWORD='...'
export DINOX_REMOTE_JINGLE_S5B_SENDER_JID='sender@example.test'
export DINOX_REMOTE_JINGLE_S5B_SENDER_PASSWORD='...'
export DINOX_REMOTE_JINGLE_S5B_PUBLIC_CANDIDATE_HOST='public-host.example.test'
export DINOX_REMOTE_JINGLE_S5B_PUBLIC_CANDIDATE_PORT=7777

./scripts/run-remote-jingle-s5b-smoke.sh --standalone-sender-real-tor-public-success --preflight
./scripts/run-remote-jingle-s5b-smoke.sh --standalone-sender-real-tor-public-success
```

The public candidate host and port must be reachable from Tor exits. The runner
rejects obvious local/private/onion hosts during preflight and monitors Tor's
local ControlPort for a `SENTCONNECT` or `SUCCEEDED` STREAM event to the exact
advertised host/port. A pass requires both that Tor event and
`JingleFileProvider`/`FileManager` receive-store completion. Optional
`DINOX_REMOTE_JINGLE_S5B_PUBLIC_LISTEN_HOST` and
`DINOX_REMOTE_JINGLE_S5B_PUBLIC_LISTEN_PORT` support NAT or tunnel mappings; if
no local listen port is set, the sender listener binds the advertised public
port. On 2026-05-26 this mode passed once with a generated Pinggy raw TCP public
candidate. On 2026-05-27 the same mode passed on the Windows MSYS2 VM with
`/mingw64/bin/tor`, advertising public candidate `45.84.199.125:47777` through a
temporary self-controlled DinoX-server TCP forward to the Windows listener. The
final marker was `WINDOWS_TOR_PUBLIC_HARNESS_EXIT 0` at
`2026-05-27T00:35:51+02:00`; cleanup verified no `:47777`/`:47778` server
listener, no temporary firewall rule, and no Windows harness/Tor process. Do not
count preflight or a blocked
reachability attempt as Tor exit-to-public-candidate success, and do not treat a
temporary forward as permanent stable self-owned S5B endpoint proof.

For the permanent stable self-owned endpoint gate, use the stricter stable
variant instead of reusing the temporary public-candidate mode:

```bash
export DINOX_REMOTE_JINGLE_S5B_JID='receiver@example.test'
export DINOX_REMOTE_JINGLE_S5B_PASSWORD='...'
export DINOX_REMOTE_JINGLE_S5B_SENDER_JID='sender@example.test'
export DINOX_REMOTE_JINGLE_S5B_SENDER_PASSWORD='...'
export DINOX_REMOTE_JINGLE_S5B_PUBLIC_CANDIDATE_HOST='stable-public-host.example.test'
export DINOX_REMOTE_JINGLE_S5B_PUBLIC_CANDIDATE_PORT=7777
export DINOX_REMOTE_JINGLE_S5B_STABLE_PUBLIC_ENDPOINT=1

./scripts/run-remote-jingle-s5b-smoke.sh --standalone-sender-real-tor-stable-public-success --preflight
./scripts/run-remote-jingle-s5b-smoke.sh --standalone-sender-real-tor-stable-public-success
```

This direct-listener mode still requires the same Tor ControlPort STREAM
evidence and receive-store completion as the public-candidate runner, but adds
an explicit stable-endpoint opt-in, rejects obvious temporary tunnel provider
hostnames and does not allow a remapped local listen port. The local listener
must bind the advertised public candidate port, optionally on `0.0.0.0` or the
advertised public host. A same-host runner pass prints
`remote-jingle-s5b-stable-public-endpoint-ok`; do not count preflight or a
temporary tunnel as this proof.

On 2026-06-01 the same raw direct-listener boundary was closed with a
self-owned server-side split against `mail.dinox.im` / `45.84.199.125:47777`.
The public port was opened through UFW with rule comment
`dinox-raw-direct-gate`; the independent stdlib sender ran on that server, bound
`0.0.0.0:47777`, advertised the exact public candidate
`45.84.199.125:47777`, required no direct candidates in the receiver
`session-accept`, accepted the S5B connection and completed with
`foreign-s5b-listener-connected` plus `foreign-jingle-s5b-sender-ok`. The local
DinoX receiver harness used an isolated Tor SOCKS account proxy and completed
`/RemoteJingleS5bSmoke/incoming_foreign_client_s5b_env` as a real `ok`, not a
skip. Tor ControlPort evidence recorded `SENTCONNECT` for
`45.84.199.125:47777`, and the orchestration marker was
`REMOTE_STABLE_PUBLIC_DIRECT_GATE_OK host=45.84.199.125 port=47777`. This closes
the headless stable self-owned raw direct endpoint receive-store boundary. It
does not close integrated Tor Manager behavior, encrypted receiver/open/export
variants, additional-client interop, or durable/server-ack/MAM semantics. The
packaged Windows GUI raw-direct receiver/open/export boundary is recorded
separately below.

For a permanent self-owned XEP-0065 proxy endpoint, use the stable proxy variant
instead:

```bash
export DINOX_REMOTE_JINGLE_S5B_JID='receiver@example.test'
export DINOX_REMOTE_JINGLE_S5B_PASSWORD='...'
export DINOX_REMOTE_JINGLE_S5B_SENDER_JID='sender@example.test'
export DINOX_REMOTE_JINGLE_S5B_SENDER_PASSWORD='...'
export DINOX_REMOTE_JINGLE_S5B_PUBLIC_CANDIDATE_HOST='45.84.199.125'
export DINOX_REMOTE_JINGLE_S5B_PUBLIC_CANDIDATE_PORT=7777
export DINOX_REMOTE_JINGLE_S5B_PUBLIC_CANDIDATE_JID='proxy.dinox.im'
export DINOX_REMOTE_JINGLE_S5B_STABLE_PUBLIC_ENDPOINT=1

./scripts/run-remote-jingle-s5b-smoke.sh --standalone-sender-real-tor-stable-proxy-success --preflight
./scripts/run-remote-jingle-s5b-smoke.sh --standalone-sender-real-tor-stable-proxy-success
```

The stable proxy mode advertises a `type='proxy'` S5B candidate, requires a bare
proxy service JID, disallows local listen host/port overrides and activates the
proxy through XEP-0065 before sending bytes. It keeps the same receiver-side Tor
STREAM evidence and receive-store completion requirement as the public-candidate
runner. On 2026-06-01 this mode passed against the DinoX public S5B proxy
`45.84.199.125:7777` / `proxy.dinox.im` with redacted disposable accounts. The
proof printed `foreign-jingle-s5b-sender-ok` and
`remote-jingle-s5b-stable-public-proxy-ok`. This closes the headless stable
self-owned public XEP-0065 proxy endpoint proof; it does not close a raw public
direct-listener endpoint, packaged GUI Tor-routed Jingle behavior, encrypted
Jingle payload variants or durable jobs. The separate packaged Windows GUI
stable-proxy receiver/open/export proof is recorded below.

The standalone-sender proxy success mode uses the same receiver account proxy
setup but allows the guard proxy to forward exactly the direct S5B candidate
offered by the stdlib sender. A pass requires the receiver `session-accept` to
publish no direct candidates, the guard proxy to record a successful CONNECT to
the exact offered candidate host/port, no rejected guard CONNECTs, and the
normal receiver receive-store assertions through persisted `COMPLETE`:

```bash
export DINOX_REMOTE_JINGLE_S5B_JID='receiver@example.test'
export DINOX_REMOTE_JINGLE_S5B_PASSWORD='...'
export DINOX_REMOTE_JINGLE_S5B_SENDER_JID='sender@example.test'
export DINOX_REMOTE_JINGLE_S5B_SENDER_PASSWORD='...'

./scripts/run-remote-jingle-s5b-smoke.sh --standalone-sender-proxy-success --preflight
./scripts/run-remote-jingle-s5b-smoke.sh --standalone-sender-proxy-success
```

Optional variables are the same as standalone-sender mode. This mode proves
successful real-server per-account SOCKS routing for incoming Jingle S5B from
the independent stdlib sender. It does not prove packaged third-party client
behavior, Tor exit-to-public-candidate success/onion remote-candidate byte-flow,
encrypted Jingle payload behavior or durable jobs. A Windows-MSYS2 run for this
mode passed on 2026-05-26 and is tracked in the pipeline TODO.

Packaged third-party note: the locally available Gajim Flatpak was checked on
2026-05-25 as `org.gajim.Gajim` 2.4.6. `gajim-remote` exposes roster, account,
status and text-message commands, but no file-transfer command. The active GUI
file-send path in that package is HTTP upload, while its Jingle file-transfer
code is not exposed as a stable non-GUI sender API. Do not count Gajim 2.4.6
Flatpak as an automated XEP-0234/XEP-0260 packaged-client S5B proof unless a
future package exposes a supported send-file path or a separate manual GUI run
is recorded with evidence.

Kaidan Flatpak was checked on 2026-06-01 as `im.kaidan.kaidan` 0.15.0. The
installed CLI exposes `--multiple`, `--unencrypted-keychain` and one optional
`xmpp-uri` argument only; no login, trust, receive/open/export or send-file API
is available, and the package installs no public D-Bus service/interface for
test control. The current XMPP client feature page also lists XEP-0234 and
XEP-0261 as missing for Kaidan, so this Flatpak must not be counted as an
automated XEP-0234/XEP-0260 Jingle S5B or OMEMO2/JET runtime proof. It is not a
current pipeline gate in this workspace.

The DinoX-pair mode uses two DinoX accounts and drives the sender inside the
same libdino smoke with `offer_file_stream()` to the receiver's bound full JID.
It sends a generated payload named `dinox-remote-jingle-s5b-pair.txt` by
default, so filename, size and SHA-256 env vars are not required:

```bash
export DINOX_REMOTE_JINGLE_S5B_JID='receiver@example.test'
export DINOX_REMOTE_JINGLE_S5B_PASSWORD='...'
export DINOX_REMOTE_JINGLE_S5B_SENDER_JID='sender@example.test'
export DINOX_REMOTE_JINGLE_S5B_SENDER_PASSWORD='...'

./scripts/run-remote-jingle-s5b-smoke.sh --dinox-pair --preflight
./scripts/run-remote-jingle-s5b-smoke.sh --dinox-pair
```

Optional variables are the same as above, plus
`DINOX_REMOTE_JINGLE_S5B_PAIR_NAME` to override the generated filename. This
mode proves real-server DinoX-to-DinoX Jingle S5B receive-store through
`JingleFileProvider` and `FileManager`; it does not prove foreign-client
delivery, normal UI sender selection, standalone proxy no-direct behavior,
Windows runtime or encrypted Jingle payload behavior.

## Database Tests

Database tests cover the local encrypted database maintenance paths: rekey, reset, WAL checkpoint and Qlite integration.

Requirements:

- `sqlcipher` in `PATH`
- configured and compiled `build/`
- `valac` for integration tests

Commands:

```bash
./scripts/test_db_maintenance.sh
./scripts/run_db_integration_tests.sh
```

Important behavior covered:

- `dino.db`, `pgp.db` and `bot_registry.db` rekey with the main database password.
- `omemo.db` is not rekeyed with the main database password because it uses its own key.
- reset removes local database files and related WAL/SHM files.
- checkpoint/backup logic handles all relevant local database files.

## Package Runtime Matrix

The runtime matrix is the first automated check after building a package. It
verifies that key libraries, plugins and media elements are present. Missing
bundled Deb/AppImage core libraries for SQLCipher, libomemo-c, libnice or
libmosquitto, the private Google/libwebrtc wrapper, worker and FFmpeg/libva
runtime libraries, bundled Dino plugin libraries, bundled
Tor/Lyrebird binaries, Dino gettext translations, desktop integration files and
media plugins for GStreamer file playback, type detection, MP4/WebM demuxing,
AAC/H.264/Opus/VP8/VP9 decoding, conversion and app sinks are package blockers.
Google/libwebrtc owns calls, microphone/camera capture and speaker output; an
installed GStreamer WebRTC/RTP/capture stack is therefore not a package gate.
The Deb mode checks the `.deb` contents for bundled runtime files and then
checks the host GStreamer reference. It also checks that the Deb wrapper wires
the private library, GStreamer, Tor and Lyrebird paths and that
the process-local `LD_LIBRARY_PATH` contains the private library directory;
a global `ld.so.conf.d/dinox.conf` entry must be absent. The AppDir
mode keeps GStreamer checks static against bundled plugin files so CI does not
spawn plugin scanners. It also checks that `AppRun` wires the private library,
GStreamer, Dino plugin and translation paths. For Flatpak, the manifest check
is static: it validates JSON syntax, app/runtime identity, sandbox permissions,
codec paths, locale behavior and enabled DinoX service features such as
SQLCipher with FTS5, OMEMO, MQTT, Tor/Lyrebird, the Google/libwebrtc
wrapper/worker and GeoClue2 location sharing. The installed-layout gate checks
every ELF for absolute RPATH/RUNPATH entries and unresolved dependencies,
proves the `bot-features.so` sibling dependency on `omemo.so`, requires the
matching FFmpeg/libva source archives and rejects legacy `rtp.so` or a WebRTC
test oracle. It also proves that the Google WebRTC plugin, wrapper, worker and
private FFmpeg libraries resolve through relative `$ORIGIN` paths, without a
global Flatpak library-path override. Forgejo/DIND runs only scanner-free
layout, writer and static GStreamer file checks; dynamic
`gst-inspect`/`gst-launch` probes remain local tests.

Local reference:

```bash
./scripts/package-runtime-matrix.sh system
```

`local` is accepted as an alias for the same local reference check.

Debian package:

```bash
./scripts/package-runtime-matrix.sh deb
```

Pass a package path when multiple local `.deb` files exist:

```bash
./scripts/package-runtime-matrix.sh deb dinox_<version>_amd64.deb
```

AppImage AppDir before packaging:

```bash
./scripts/package-runtime-matrix.sh appdir AppDir
```

Flatpak manifest:

```bash
./scripts/package-runtime-matrix.sh flatpak-manifest im.dinox.dinox.json
```

App metadata:

```bash
./scripts/package-runtime-matrix.sh metadata
```

Matrix script self-test:

```bash
./scripts/package-runtime-matrix.sh self-test
```

The matrix self-test covers helper logic such as GStreamer plugin mapping,
packaged GStreamer plugin-list consistency, static package lookup, AppStream
screenshot asset tracking and dimension validation, argument validation and
missing target failures.

Treat the local reference as the baseline. Deb/AppImage/Flatpak should match the critical runtime capabilities unless there is a deliberate packaging difference.

## Language-independent boundaries

The maintained matrix covers every offered application language, including
existing application and plugin behavior. See [LANGUAGE_TESTING.md](LANGUAGE_TESTING.md)
for the exact coverage, native system-locale mappings, commands and limits.

```bash
meson test -C build --no-rebuild --num-processes 2 --timeout-multiplier 3 \
  --print-errorlogs --suite languages --suite locale-boundaries --suite systray
```

Missing locale data is an explicit skip. Catalog loading, real widget text,
behavioral tests and native platform validation are separate results.

## Manual Runtime Verification

### Tray protocol, Unicode and lifecycle

After building, run `meson test -C build --no-rebuild --suite systray --num-processes 1 --print-errorlogs`.
On Linux this compiles the real SNI and DBusMenu implementation with an isolated
application fixture. Sixteen runs cover German, Russian, Arabic, Hebrew, Urdu,
Turkish, Japanese and simplified Chinese, using both watcher names. They check
translated labels, RTL direction, status actions, notification toggles, literal
underscores, Unicode AppDir paths, both packaged icon sizes, watcher restart and
cleanup while a registration reply is pending. The private bus has no desktop
service activation. When `xdg-dbus-proxy` is available, the test reads the current
Flatpak manifest and applies its D-Bus talk permissions.

Linux needs Xvfb, `dbus-run-session`, Python GObject bindings and built main
catalogs. The fixture verifies a non-C UTF-8 base locale; missing locale sources
produce a skip, not a successful translation check. These are desktop protocol
and package-layout checks, not tests of every panel implementation or a complete
new AppImage/Flatpak release artifact.

On Windows, six native tests cover UTF-8/UTF-16 round trips, emoji boundaries in
tooltips and notifications, Unicode log paths, multilingual menu/accessibility
text, high contrast, DPI rendering, notification ownership/cancellation and
Explorer restart. Shell notification delivery and the high-contrast setting are
substituted; the menu, queue and conversion code is the production implementation. Run these tests as
a normal user. They do not call tray initialization, alter Jump Lists, register
the XMPP handler or open a real account. Render captures remain temporary unless
`DINOX_TRAY_TEST_ARTIFACT_DIR` points to a local diagnostics folder.

The `VideoPlayerRuntime` suite in `main/main-ui-runtime-test` exercises the real
video widget with generated WebM/VP8 and MP4/H.264/AAC files, encrypted local
storage and a fake audio output provider. It checks delayed first mapping,
immediate cached previews on chat reentry, stable portrait height, Unicode file
paths and restoring the poster after unmapping during playback. Fixture generation requires
`videotestsrc`, `vp8enc` and `webmmux`; the MP4 case also requires `x264enc` and
`avenc_aac`. Missing fixture encoders produce an explicit skip, not a pass.
Run `-p /VideoPlayerRuntime` through the existing isolated GTK runtime harness.
In MSYS2, set `MSYS2_ARG_CONV_EXCL='*'` for this invocation so the suite path
is not rewritten into a Windows filesystem path. Check that all six tests run;
an empty `1..0` result does not validate the widget.
After changes, also run `AudioPlayerRuntime`, `ChatPreviewLayoutRuntime` and
`FileWidgetControllerRuntime` to cover the adjacent players, image/link layout
and transfer UI. These tests use no live account, camera or physical speaker.

The automated matrix in [LANGUAGE_TESTING.md](LANGUAGE_TESTING.md) runs every
offered UI language in a fresh process with a verified regional system locale.
It checks actual catalog discovery separately from widget behavior. For a
focused manual diagnosis, `DINOX_UI_TEST_LOCALE_DIR` can still force a catalog
path, but that override is not evidence for the normal application loader.

`HatsCommandDialogRuntime` waits for the overview's completed queries before
requesting an action, and for the actual return, confirmation or error dialog
when saving or canceling. Its late-response case holds an actual command response,
closes the overview, releases the response and requires exactly one session
cancellation without reopening the dialog. Fixed sleeps must not replace those
state checks. Before simulating clicks or closes, wait for presentation frames:
libadwaita 1.5 exposes a dialog before its sheet has opened on the next map ticks.
Thumbnail pixel checks likewise wait for the first non-empty GTK
snapshot before checking the image borders; initial native-window painting can
take longer than a fixed delay. The `FileManager_localized_timeout_schedules_retry` case uses six
different error texts with the same GIO timeout code and verifies retry and
subsequent download completion for each.

The matrix includes a real Turkish **system locale**, not only `LANGUAGE=tr`:
`Stickers/technical_mime_and_extensions_ignore_system_case_rules`,
`FileDefaultWidgetRuntime/uppercase_mime_selects_media_player_in_system_locale`
and the OpenPGP `detects_pgp_mime_type` case cover ASCII MIME identifiers and
uppercase extensions. Turkish Unicode lowercasing changes ASCII `I` to `ı`;
technical identifiers and file extensions must use `ascii_down()` instead.
User-visible text and contact-name comparisons must retain their Unicode rules.

Manual testing is required for user-visible behavior and desktop/media integration.

Minimum smoke test for every package type:

1. Start DinoX in the system language.
2. Unlock an existing encrypted database.
3. Verify OMEMO is available.
4. Open a 1:1 chat.
5. Open a MUC.
6. Send and receive a text message.
7. Upload and send an image.
8. Send and play a voice message.
9. Send and play a video message.
10. Check video preview loading after leaving and reopening a chat.
11. Start a 1:1 audio/video call.
12. Check systray icon, systray menu, status changes and quit/background behavior.
13. Restart DinoX and verify the previously active chat is restored.
14. Trigger Panic Wipe only on disposable test data.

Extra MUC checks:

- Join a bookmarked MUC.
- Leave and re-enter the MUC.
- Verify own presence/status is still correct.
- Verify role/affiliation display.
- Verify joining does not depend on MAM being enabled in the room.
- Verify behavior when the same account is connected from another client.

Extra media checks:

- Long chat with images near the beginning.
- Long chat with visible video preview.
- Chat switch between text-only, image-heavy and video-heavy chats.
- Window resize while media previews are visible.
- App restart into a media-heavy active chat.

## Package-Specific Checks

### Local Build

```bash
./build/main/dinox
```

Use this as the behavioral reference.

### Debian Package

Install on a clean test system or disposable profile:

```bash
sha256sum -c dinox_*.deb.sha256
sudo apt install ./dinox_*.deb
dinox
```

Check that runtime paths, translations, OMEMO and media behavior match the local reference.

### AppImage

```bash
sha256sum -c DinoX-*.AppImage.sha256
chmod +x DinoX-*.AppImage
./DinoX-*.AppImage
```

If media behavior differs, inspect the AppDir:

```bash
./DinoX-*.AppImage --appimage-extract
find squashfs-root -maxdepth 5 -name 'libgst*.so' | sort
find squashfs-root -maxdepth 5 -name 'libnice*.so*' -print
```

### Flatpak

```bash
sha256sum -c dinox-*.flatpak.sha256
flatpak install --user ./dinox-*.flatpak
flatpak run im.dinox.dinox
```

Useful sandbox checks:

```bash
flatpak info im.dinox.dinox
flatpak run --command=sh im.dinox.dinox -c \
  "test -x /app/lib/dinox/dinox-webrtc-worker && test -f /app/lib/dinox/libdinox-google-webrtc.so"
flatpak run --command=sh im.dinox.dinox -c \
  "for element in uridecodebin appsink qtdemux matroskademux avdec_aac avdec_h264; do gst-inspect-1.0 \"\$element\" >/dev/null || exit 1; done"
flatpak run --command=sh im.dinox.dinox -c \
  "ffmpeg -hide_banner -encoders | grep -E ' (aac|libx264) '"
```

These checks follow the production boundary: Google/libwebrtc owns calls,
capture and speaker output; FFmpeg writes Linux message files; GStreamer only
demuxes/decodes files and extracts media data. Do not use `rtpbin`, `webrtcbin`
or `gstnice` presence as a release-call gate. DinoX-built package payloads must
not bundle the unused `libgstnice.so`, although a host or base runtime can
provide its own copy independently.

Flatpak data paths:

```text
Data and databases: ~/.var/app/im.dinox.dinox/data/dinox
Configuration:      ~/.var/app/im.dinox.dinox/config/dinox
Cache:              ~/.var/app/im.dinox.dinox/cache/dinox
```

### Windows

Use the MSYS2 build and distribution process from:

- [WINDOWS_BUILD.md](WINDOWS_BUILD.md)
- [WINDOWS_BUILD_EN.md](WINDOWS_BUILD_EN.md)

Windows runtime checks should include:

- first launch after extraction
- second launch after Windows Defender has had a chance to scan the extracted files
- OMEMO availability
- audio/video calls
- voice messages
- video messages
- headless build-tree private-MUC HTTP smokes for unencrypted, seeded/PubSub OMEMO1,
  seeded/PubSub OMEMO2/SCE and seeded/PubSub/legacy OpenPGP
- packaged `dist` runtime OMEMO1/JET and OMEMO2/JET Jingle-S5B smokes via
  `run-remote-omemo-jingle-s5b-smoke.sh --dist-runtime` and
  `run-remote-omemo-jingle-s5b-smoke.sh --omemo2 --dist-runtime`, proving
  copied test binaries resolve DinoX core and plugin DLLs from `dist`
- packaged `dist\dinox.exe` GUI file-send smoke for the native Windows picker,
  send overlay, HTTP/SFS sender DB state and post-quit process cleanup
- packaged `dist\dinox.exe` GUI Jingle-S5B receiver smoke for receive-store,
  default-app open handoff, native Save dialog export and post-quit cleanup
- packaged `dist\dinox.exe` GUI OpenPGP HTTP/SFS receiver/open/export runtime
  gate, driven by the OpenPGP `--direct-sender-only` sender; the 2026-06-01
  pass requires the receiver conversation to be OpenPGP-selected and records
  `provider=0`, `encryption=PGP`, default-open and native Save-as export
- Tor/Lyrebird startup
- systray behavior

On 2026-05-26 the packaged `dist\dinox.exe` GUI file-send smoke passed in the
Windows VM interactive desktop session. It unlocked the existing encrypted
profile, selected a generated payload through the native Windows file picker,
activated the DinoX send overlay, persisted an unencrypted HTTP/SFS sender row
with `state=COMPLETE`, restored the conversation encryption setting, exited via
Ctrl+Q and left no DinoX/GPG helper processes. This proof does not cover
receiver GUI behavior, OMEMO/OpenPGP GUI sends, Jingle S5B or foreign clients.

On 2026-05-27 the Windows VM also passed the packaged `dist` runtime
OMEMO1/JET Jingle-S5B smoke. `scripts/update_dist.sh` refreshed the package
tree, `--preflight --dist-runtime` verified runtime dependency resolution from
`dist`/`dist/plugins`, and the real remote smoke passed with
`remote-omemo1-jingle-s5b-dist-runtime-send-receive-ok`. This is a packaged DLL
and plugin runtime proof for the headless Jingle path, not a GUI sender
selection proof.

On 2026-05-31 the same Windows VM passed the packaged `dist` runtime OMEMO2/JET
Jingle-S5B smoke from the clean gate checkout at `3c1c1a4d`.
`scripts/update_dist.sh` refreshed the package tree, `--preflight --omemo2
--dist-runtime` verified runtime dependency resolution from `dist` and
`dist/plugins`, and the real env-backed remote smoke passed with
`remote-omemo2-jingle-s5b-dist-runtime-send-receive-ok`. This closes packaged
DLL/plugin runtime for the headless OMEMO2/JET Jingle path only; it is not a
Windows GUI file-picker/send-overlay or product v2-only receiver-mode proof.

Later on 2026-05-31 the Windows VM passed the packaged `dist\dinox.exe` GUI
OMEMO2/JET Jingle-S5B sender smoke. The interactive scheduled-task harness
unlocked the existing encrypted profile, selected
`dinox-gui-omemo2-jingle-proof-20260531-133355.txt` through the native Windows
file picker, selected `Direct transfer`, and sent to a Linux
`--receive-only --omemo2` harness. The sender row persisted `state=COMPLETE`,
`provider=1`, `encryption=OMEMO`, matching size and no SFS `file_sharing_id`;
the receiver completed with `remote-omemo2-jingle-s5b-receive-ok`. This closes
the DinoX-to-DinoX Windows packaged GUI sender path for OMEMO2/JET Direct
Jingle-S5B. It does not cover additional external clients or Tor-routed GUI
Jingle. At the time of that run it
also did not cover encrypted receiver open/export behavior beyond the OMEMO1/JET
receiver proof below; the later OpenPGP HTTP/SFS receiver/open/export proof is
recorded separately.

Later on 2026-05-31 the Windows VM passed the packaged `dist\dinox.exe`
unencrypted Jingle-S5B receiver/open/export smoke. An independent stdlib sender
completed S5B byte-flow into the packaged receiver, the receiver row persisted
`state=COMPLETE`, `provider=1`, `encryption=NONE`, matching size and no SFS
`file_sharing_id`, the GUI opened the stored file through the Windows default
app, and native Save-as export wrote bytes with matching size/SHA-256. The
harness exited DinoX, restored its temporary DB backup, removed its scheduled
task and left no DinoX/GPG helper or default-app processes. This does not cover
encrypted raw-direct/Tor-onion receiver variants, additional external clients or durable job/retry semantics.

On 2026-06-01 the Windows VM passed the packaged `dist\dinox.exe` stable public
XEP-0065 proxy receiver/open/export smoke. The independent stdlib sender
advertised `type='proxy'` with `45.84.199.125:7777` /
`proxy.dinox.im`, completed proxy activation and printed
`foreign-jingle-s5b-sender-ok`. The real packaged receiver persisted
`state=COMPLETE`, `provider=1`, `encryption=NONE`, the GUI opened the stored
file through the Windows default app, native Save-as exported bytes with the
expected SHA-256, and the local harness printed
`remote-jingle-s5b-packaged-gui-stable-public-proxy-open-export-ok`. This closes
the packaged Windows GUI unencrypted receiver/open/export boundary for the
stable public DinoX S5B proxy. The OMEMO1/JET stable-proxy receiver proof below
closes the matching encrypted stable-proxy GUI surface; encrypted raw-direct/Tor-onion
receiver variants, additional external clients or durable job/retry semantics
remain separate.

On 2026-06-02 the Windows VM passed the packaged `dist\dinox.exe` stable public
raw-direct receiver/open/export smoke. The receiver account was explicitly
unproxied (`ProxyType none`), while the independent stdlib sender ran on
`mail.dinox.im`, bound `0.0.0.0:47777` and advertised the direct candidate
`45.84.199.125:47777`. The sender printed `foreign-s5b-listener-connected` and
`foreign-jingle-s5b-sender-ok`, the candidate info recorded `type=direct`,
`host=45.84.199.125` and `port=47777`, the packaged receiver persisted
`state=COMPLETE`, `provider=1`, `encryption=NONE`, an empty protocol column and
no SFS `file_sharing_id`, and native Save-as exported bytes with the expected
SHA-256. The strict local row check printed `TRANSFER_ROW_STRICT_RAW_DIRECT=True`
and the local marker was
`remote-jingle-s5b-packaged-gui-stable-public-direct-open-export-ok`. This
closes the packaged Windows GUI unencrypted receiver/open/export boundary for
the stable public raw-direct S5B endpoint.

On 2026-06-02 the Windows VM passed the packaged `dist\dinox.exe` OMEMO1/JET
stable public XEP-0065 proxy receiver/open/export smoke. The packaged receiver
conversation was OMEMO-selected and its account used a standalone SOCKS5 proxy
to Windows Tor. Linux drove `scripts/run-remote-omemo-jingle-s5b-smoke.sh
--sender-only` with the sender account routed through local Tor and with
fail-closed S5B assertions for no sender direct candidates, the expected proxy
candidate `type=proxy` at `45.84.199.125:7777` / `proxy.dinox.im`, and no
receiver direct candidates in `session-accept`. The sender printed
`remote-omemo1-jingle-s5b-external-receiver-sender-ok`; the packaged receiver
persisted `state=COMPLETE`, `provider=1`, `encryption=OMEMO`, an empty protocol
column and no SFS `file_sharing_id`; default-app open and native Save-as export
both produced bytes with SHA-256
`736e48961a0ec5f5769846d862dfc6416053d45867ce774b1e0d18d42bdeb5a3`. The local
marker was
`remote-omemo1-jingle-s5b-packaged-gui-stable-public-proxy-open-export-ok`.
This closes the packaged Windows GUI OMEMO1/JET receiver/open/export boundary
for the stable public DinoX XEP-0065 proxy transport.

Later on 2026-05-31 the Windows VM passed the packaged `dist\dinox.exe`
OMEMO1/JET Jingle-S5B receiver/open/export smoke. Linux drove the sender side
with `scripts/run-remote-omemo-jingle-s5b-smoke.sh --sender-only`, using the
receiver's live full JID and the existing opt-in env gate. The sender-only
runner printed `remote-omemo1-jingle-s5b-external-receiver-sender-ok` after
validating sender `provider=1`, `encryption=OMEMO`, no SFS `file_sharing_id`,
phase order and the local stored payload. The packaged Windows receiver row
persisted `state=COMPLETE`, `provider=1`, `encryption=OMEMO`, matching size and
no SFS `file_sharing_id`; default-app open and native Save-as export both
produced bytes with the expected SHA-256. This closes the normal DinoX-to-DinoX
packaged Windows encrypted-Jingle receiver open/export boundary: a mixed
OMEMO1/OMEMO2 DinoX receiver is intentionally served through OMEMO1/JET.
Tor-routed GUI Jingle, a product-supported
DinoX-to-DinoX v2-only OMEMO2/JET receiver mode and durable job/retry semantics
remain separate gates.
OpenPGP HTTP/SFS receiver/open/export is tracked by the separate packaged GUI
pass below. OpenPGP is intentionally routed through the
HTTP sender for file transfers because the encrypted body-url must remain inside
the OpenPGP-encrypted message body; it is not a Jingle/JET receiver gate.

For OMEMO/JET sender-only transport assertions, the runner accepts these
additional opt-in environment variables. They are intended for packaged receiver
transport gates and are not required for ordinary OMEMO send/receive smokes:

```bash
DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_PROXY_TYPE=tor
DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_PROXY_HOST=127.0.0.1
DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_PROXY_PORT=9050
DINOX_REMOTE_OMEMO_JINGLE_S5B_EXPECT_SENDER_NO_DIRECT_CANDIDATES=1
DINOX_REMOTE_OMEMO_JINGLE_S5B_EXPECT_SENDER_CANDIDATE_TYPE=proxy
DINOX_REMOTE_OMEMO_JINGLE_S5B_EXPECT_SENDER_CANDIDATE_HOST=45.84.199.125
DINOX_REMOTE_OMEMO_JINGLE_S5B_EXPECT_SENDER_CANDIDATE_PORT=7777
DINOX_REMOTE_OMEMO_JINGLE_S5B_EXPECT_SENDER_CANDIDATE_JID=proxy.dinox.im
DINOX_REMOTE_OMEMO_JINGLE_S5B_EXPECT_RECEIVER_NO_DIRECT_CANDIDATES=1
DINOX_REMOTE_OMEMO_JINGLE_S5B_EXPECT_RECEIVER_SELECTED_SENDER_CANDIDATE=1
```

The sender-only harness applies the account proxy policy to the test stream,
observes outgoing `session-initiate` and incoming `session-accept`/`transport-info`
IQs, and fails if the advertised candidates do not match the configured boundary
or if an expected sender candidate is not selected by receiver `candidate-used`.
Do not use those assertions to claim OMEMO2 receiver support; product v2-only
OMEMO2/JET receiver mode remains a separate gate.

On 2026-06-01 the Windows VM passed the packaged `dist\dinox.exe` OpenPGP
HTTP/SFS receiver/open/export smoke. Linux drove the sender side with
`scripts/run-remote-openpgp-private-muc-http-smoke.sh --direct-sender-only`.
The receiver conversation was OpenPGP-selected, and the receiver DB recorded
`provider=0`, `encryption=PGP`, protocol
`openpgp:xep0374`, restored filename/size/path and no SFS `file_sharing_id`.
The GUI opened the verified plaintext through the Windows default app and
exported matching bytes through the native Save dialog. The harness restored
DB/OMEMO/OpenPGP/GnuPG backups and printed
`remote-openpgp-packaged-windows-gui-receiver-open-export-ok`. Runtime
credentials and generated keys remain process-scoped and are not documented.

On 2026-06-01 the attempted packaged Windows GUI OMEMO2/JET receiver/open/export
smoke failed closed before sending. The helper mode
`run-remote-omemo-jingle-s5b-smoke.sh --omemo2 --external-receiver-v2-only`
requires disposable-account opt-in with
`DINOX_REMOTE_OMEMO_JINGLE_S5B_ALLOW_PEP_MUTATION=1`, a target
`DINOX_REMOTE_OMEMO_JINGLE_S5B_RECEIVER_OMEMO2_DEVICE_ID`, distinct
`DINOX_REMOTE_OMEMO_JINGLE_S5B_READY_FILE` and
`DINOX_REMOTE_OMEMO_JINGLE_S5B_DONE_FILE`, pre-existing OMEMO1/OMEMO2 `current`
PEP items, no PubSub node reconfiguration and restore readback. The sender-only
side now waits for sender-visible empty OMEMO1 plus exactly the expected OMEMO2
device and bundle before sending. With real packaged DinoX as the online
receiver, that condition did not stabilize because the GUI receiver republished
its legacy OMEMO1 device list. This is not a Windows GUI OMEMO2 receiver pass
and it is not a current DinoX-to-DinoX pipeline blocker: normal DinoX receivers
are mixed OMEMO1/OMEMO2 and use the already recorded OMEMO1/JET receiver
open/export product path. A future OMEMO2 receiver test needs a
product-supported DinoX-to-DinoX v2-only receiver mode.

For a native receive-only harness paired with the separate v2-only guard, set
`DINOX_REMOTE_OMEMO_JINGLE_S5B_RECEIVE_RELEASE_FILE` to a fresh, absent path
in the receiver process. After the sender and receiver have verified the
transfer, create the guard's `DONE_FILE`, wait for the guard to finish and
restore its snapshots, then create `RECEIVE_RELEASE_FILE`. The receiver waits
at most its configured timeout before cleaning up its own temporary PEP state.
This prevents receiver cleanup from removing the bundle while the guard still
checks it. The option is test-only and does not establish packaged GUI support.

The same 2026-06-01 refresh first confirmed that the raw direct-listener stable
public endpoint gate could not be closed from the Linux/Windows LAN alone: the
gateway exposed no usable UPnP/NAT-PMP mapping path, gateway SSH rejected the
available keys and Forgejo Git SSH disables remote port forwarding. The gate was
then rerun with the listener placed on the self-owned public server
`mail.dinox.im` / `45.84.199.125:47777` behind a UFW rule. That run produced
Tor `SENTCONNECT` evidence for the advertised raw TCP candidate, a real public
S5B listener connection, `candidate-used`, receiver receive-store completion and
`REMOTE_STABLE_PUBLIC_DIRECT_GATE_OK`. This closes the headless raw direct
stable endpoint boundary; the stable public XEP-0065 proxy and Tor-onion proofs
remain separate boundaries. The OMEMO1/JET proxy proof above closes only that
encrypted stable-proxy receiver/open/export surface; encrypted raw-direct/Tor-onion
receiver/open/export remains separate. The 2026-06-02 packaged Windows GUI
raw-direct proof above closes the same public endpoint at the GUI/default-open/native-export surface.

GeoClue2 location sharing is not available on Windows.

## Forgejo Actions Verification

The active workflow is:

```text
.github/workflows/build.yml
```

Manual checks:

1. Run with `build_deb=true`, `build_appimage=false`, `build_flatpak=false`.
2. Run with `build_deb=false`, `build_appimage=true`, `build_flatpak=false`.
3. Run with `build_deb=false`, `build_appimage=false`, `build_flatpak=true`.
4. Run with `mirror_appimage_runtimes=true` and package build inputs disabled.

The package-only AppImage and Flatpak paths should still run documentation
links, translation syntax, hidden Unicode and Python syntax checks when the
core Debian build job is skipped. The runtime mirror-only path should still run
documentation links, hidden Unicode and Python syntax checks.
All three paths should also run the AppImage runtime mirror self-test alongside
the release helper self-tests.

Tag release checks:

- Tags matching `v*.*.*` and `v*.*.*.*` should run package builds.
- The workflow should create or update the Forgejo Release.
- Source tarball, package assets and `.sha256` files should be uploaded.
- Manual package selection must continue to work after any release workflow change.

## Pre-Commit Recommendation

For local parity with the cheap pre-commit gates:

```bash
./scripts/run_all_tests.sh --static
./scripts/build.sh --strict
```

The pre-commit hook runs the static documentation, translation, Unicode, Python,
shell, release-helper and package-metadata checks, then checks compiler warnings
when an existing `build/` directory is available. It does not replace the full
Meson test suite.

For normal code changes:

```bash
./scripts/build.sh --strict
./scripts/run_all_tests.sh --meson
```

For database or encryption changes:

```bash
./scripts/run_all_tests.sh
```

For packaging changes:

```bash
./scripts/package-runtime-matrix.sh system
./scripts/package-runtime-matrix.sh deb dinox_<version>_amd64.deb
./scripts/package-runtime-matrix.sh appdir AppDir
./scripts/package-runtime-matrix.sh flatpak-manifest im.dinox.dinox.json
./scripts/package-runtime-matrix.sh metadata
./scripts/package-runtime-matrix.sh self-test
```

For documentation changes:

```bash
./scripts/check-doc-links.py
```

When changing the link checker itself, also run:

```bash
./scripts/check-doc-links.py --self-test
```

The self-test covers Markdown parser edge cases such as link titles, reference
links, image-wrapper links, inline code, fenced code blocks and embedded HTML
attributes, plus local HTML `href`, `src`, refresh links, HTML `id`/`name`
anchors, DinoX Forgejo file links that should resolve to local repository paths
and issue-template links that should resolve to `.github/ISSUE_TEMPLATE`.

When changing the shell syntax checker itself, also run:

```bash
./scripts/check-shell-syntax.sh --self-test
```

The self-test covers default discovery of Git-tracked `.sh` files, including
suffix-only scripts without a shebang, extensionless `sh`/`bash` shebang
scripts and non-shell files that should be ignored by the default scan.

For Forgejo release helper validation:

```bash
./scripts/release.sh --self-test
./scripts/release_helper.sh --self-test
./scripts/forgejo-release.sh --self-test
./scripts/prepare-forgejo-release.sh --self-test
./scripts/verify-release-candidate.sh --self-test
./scripts/mirror-appimage-runtimes.sh --self-test
```

These self-tests cover release CLI dispatch, version/tag validation, release
body, asset, paired checksum sidecar and checksum validation, release-candidate
proof validation plus AppImage runtime mirror argument/token validation without
editing release files, creating tags, calling the Forgejo API or uploading
assets.

For UI/media behavior changes, automated tests are not enough. Run the manual runtime checklist on at least the local build and the package type affected by the change.

## Reading Failures

Meson writes detailed logs to:

```text
build/meson-logs/testlog.txt
```

Use verbose output for deeper inspection:

```bash
meson test -C build -v --print-errorlogs
```

For a failing GLib test binary, list paths with `-l` and run the failing path directly with `-p`.

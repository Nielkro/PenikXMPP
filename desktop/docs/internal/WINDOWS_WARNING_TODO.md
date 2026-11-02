# Windows warning cleanup TODO

## Generated helper cleanup: 2026-10-31

The image-metadata rebuild exposed 45 of the previously recorded unused-code
warnings: 27 closure-reference helpers, nine mutex-related cleanup helpers,
five finally labels and four asynchronous finish helpers. This follow-up
removes that bounded set at the Vala source/binding level:

- Test callbacks explicitly own the closures they receive.
- Four test capture objects use a test-only view of `GMutex`, initialized
  once and finalized with `g_mutex_clear`. They never copy or reassign it.
- Nonthrowing paths retain one explicit cleanup point instead of redundant
  `finally` blocks. Tor's transition flag is still cleared within the same
  coroutine, without adding an asynchronous boundary.
- Tor background operations explicitly finish their async results. The
  rebuild also exposed four analogous warnings in the Tor settings page;
  those call sites now finish their results too.

The affected Windows rebuild passes `scripts/build.sh --strict` with zero
warnings. A separate compiler check emits temporary assembly for 17 affected
generated C units, with unused functions and labels treated as errors. All
17 pass without diagnostics. No warning suppression or generated-C patch was
added. This is **not a new full clean build** and does not establish that all
200 warnings from October 30 have disappeared.

The Windows HTTP suite, both Tor lifecycle groups, five Bot lifecycle cases
and 58 selected OMEMO cases pass. Two HTTP cases explicitly skip external
interoperability tests. The Bot subprocess test initially exceeded its fixed
15-second deadline under a half-core CPU cap; the unchanged binary passes
with a one-core cap. Other checks retain the half-core cap.

The real-GPG upload cancellation tests also exposed a test-harness defect:
their five-second outer timeout included GPG startup and encryption. Under
the CPU cap, it could expire before an upload stream existed; subsequent
assertions then dereferenced that missing stream. Failed prerequisites now
terminate the case cleanly, and the outer safety guard allows 30 seconds.
The controlled stream must still trigger cancellation after HTTP headers
arrive, before the body completes. These assertions and its one-second
cancellation checks are unchanged. Test keys use disposable, explicitly
selected GnuPG homes with synthetic XMPP identities.

Both real-GPG cancellation cases now pass on Windows (16.34 s together) and
Linux, with neither case skipped. The final OpenPGP rebuild is strict-clean
on both platforms, and its regenerated C unit again passes the explicit
unused-function/label check. The corresponding HTTP, Bot, Tor and selected
OMEMO checks also pass on Linux. The local Vala 0.56.16 generator's existing
volatile GOnce diagnostics remain visible when removing its C `-w` flag;
they are not included in a claim of complete Linux C warning cleanliness.
All 21 changed source/binding/build files match the isolated Windows checkout
by SHA-256. Logs remain local; no test profiles or generated keys belong in
the repository.

The startup CPU spike and the reporter's specific Windows image freeze remain
separate investigations. These compiler and fixture checks do not demonstrate
the cause of either user-visible problem. The user's Windows release checkout
and running Linux profile were not changed by this isolated audit.

## Native binding cleanup: 2026-10-30

The user-provided Windows log for `3512d6bb` completed successfully with
231 compiler warnings: 31 incompatible-pointer diagnostics, 163 unused
functions and 37 unused labels. Compared with the October 29 log, three
occurrences were new: the window-control selector in the application and UI
test, and the chat input test's subprocess argument vector.

The cleanup addresses the native boundaries without changing message,
encryption or file-transfer algorithms:

- Build GTK choice lists with `append`, retaining their order and settings
  indices. Copy GLib's borrowed const language vector into an owned string
  vector before passing it to Vala.
- Declare subprocess and icon-search-path string arrays with their actual C
  types. The icon test retains a non-null empty vector; a null pointer crashes
  the tested GTK 4.14 implementation.
- Use opt-in VAPI views for GDK clipboard/drop reads and GIO stream overrides.
  These views name the existing C types and GTypes; they register no new
  runtime class. GDK keeps its instance-bearing finish call and result
  ownership. Stream implementations and vtable declarations both use GIO's
  `void *` / `const void *` buffer types and `gsize` length. The normal GLib/GDK
  bindings are not replaced. Only the affected targets load these views.
- Add a native stream regression that calls the implementations through
  ordinary `GLib.InputStream` / `GLib.OutputStream` references, checks the
  runtime parent type, and exercises sync/async buffers, cancellation and
  closed-stream errors.

All 200 unused-code occurrences in the original log are classified:

| Generated code | Occurrences |
|---|---:|
| Async `_finish` helpers | 82 |
| Closure `blockN_data_ref` helpers | 49 |
| GLib `_vala_clear_*` helpers | 28 |
| `__finallyN` labels | 37 |
| Private GPG result-property setters | 4 |

These diagnostics name generated C helpers/labels, not missing async
operations or skipped cleanup blocks. The GPG result lists are initialized and
mutated in place, leaving generated private setters unused. Removing source
operations or altering their ownership to avoid those helpers would change
working code solely for a diagnostic count. This group stays visible. No
warning suppression was added and no generated C files were patched.

`build-windows-dist.sh` now reports `WINDOWS_COMPILER_WARNING_COUNT` across the
entire session, including failures, and writes the diagnostic occurrences to
`compile-*.warnings.txt`. The later incremental build explicitly labels its
count as applying to that invocation only. Parser and logger tests cover
multi-phase counts, decorated duplicate summaries, Unicode/space paths, failed
compilers and failed log writers.
The shared parser also replaces the C/Vala-only filter in `build.sh`, so
`--strict` now detects C++ and header diagnostics as well. A simulated C++
compiler warning fails the wrapper, while a clean invocation clears the old
warning file and succeeds.

Linux validation passes the strict wrapper build, the full main, HTTP-file,
OMEMO and OpenPGP suites, the new native stream test, and the focused GTK
interface-style, language and chat-input cases. The dedicated Xvfb keyboard
test also passes with real Enter/Ctrl+Enter injection through the corrected
subprocess binding. An isolated Xvfb clipboard
probe returns the advertised MIME type and the exact URI-list payload through
the new async binding. Two initial test failures (a null zero-length stream
buffer and a null icon search vector) were corrected and the affected tests
rerun successfully.

The isolated Windows build of `5cbe1b1d` plus this cleanup completed as a
standard user from 21:30:42 to 22:25:20 CET on October 30. Its full log,
`compile-20261030-213042-wGJVvn.log`, records `WINDOWS_BUILD_EXIT_CODE=0`,
22 passing test groups and a validated portable distribution with 296 PE
files. The whole-session report and an independent raw-log count both give
**200 warnings: 163 unused functions and 37 unused labels**. Comparing the
diagnostics with the original log, ignoring source line-number changes,
removes exactly all 31 pointer warnings and adds none. The interactive login
UI test was explicitly skipped; this build does not establish manual Windows
UI or device acceptance.

The additional complete Windows OMEMO and OpenPGP suites pass (486.65 s and
55.70 s). The HTTP suite initially exposed three pre-existing assertions that
looked for the English word "cancel" in GIO's translated cancellation message;
Windows returned "Vorgang wurde abgebrochen". Those tests now verify the
cancelled state and the preserved native error message in the current locale.
The blocked-stream fixture uses GIO's own cancellation error as well. No
production transfer code changed for this correction. The complete HTTP suite
then passes on Windows (18.31 s) and Linux (12.37 s). Its recompiled C unit
retains exactly the same four generated-helper warnings, with no additions.
The first combined transfer-run log therefore retains its HTTP failure; the
successful correction is recorded separately in `warning-http-audit.txt`.

The Linux wrapper's strict result alone does not prove C warning cleanliness:
its generated C uses `-w`. An additional local C check found only the installed
Vala 0.56.16 generator's existing volatile GOnce/GLib atomic diagnostics. The
full Windows count above comes from Vala 0.56.19 and GCC 16.1.0.

## Release 2.3.3 log review: 2026-10-29

The user completed and manually tested a clean Windows build of
`3a4e974dd8ffdc4233ec101f262a3bd39fd40e5a`. The complete log
`compile-20261029-133546-i5Mj7I.log` records a normal-user release build from
13:35:47 to 14:32:34 CET, `WINDOWS_BUILD_EXIT_CODE=0`, successful native
WebRTC, backup, DNSSEC/DANE, SASL, XMPP, libdino and OMEMO checks, and a
validated portable distribution with 296 PE files. The additional login UI
runtime test was explicitly skipped because its interactive-desktop option
was not enabled; this is not an automated GUI-test pass.

The full compilation emitted **228 warning occurrences**, all in
Vala-generated C:

| Compiler diagnostic | Occurrences |
|---|---:|
| `-Wunused-function` | 163 |
| `-Wunused-label` | 37 |
| `-Wincompatible-pointer-types` | 28 |

Nineteen pointer warnings match the deferred stream/async signatures below.
The nine additional occurrences are string-array `const` qualification
differences: six in `interface_language` across application and UI-test
targets, two in the design-choice model, and one in the icon-resource test's
empty search path. The inspected language code only reads GLib's borrowed
language names and duplicates the selected string; it neither modifies nor
frees that borrowed array. GTK's list constructor and icon search-path setter
receive read-only inputs. These diagnostics do not demonstrate a runtime
failure, but remain visible cleanup work; no warning suppression or application
code change was introduced for this release review.

The VM reports no Media Foundation/D3D11 H.264 hardware codec. The native
codec suite explicitly passes its software fallback and encode/decode cycles;
the preceding hardware-probe messages are not failed package gates.
The later strict test-build phase reports zero warnings, which does not erase
the 228 diagnostics from full compilation.

Only documentation changed between the tested commit and `b37e9136`. The
final versioned Windows 2.3.3 package is built and uploaded by the maintainer
after the release tag; this log does not certify that future ZIP.

## Unicode test follow-up: 2026-10-17

The October 15 Unicode build/link, portable-package and native test-argument
fixes are already included in master. A remaining `bot-features-test -l`
failure was fixture cleanup: GLib can tear down listed cases without running
their setup, leaving the database path unset. Cleanup now accepts that state
and consumes the path once; a registered listing regression requires exit 0.
The next clean Windows build must establish its Windows result.

The separate `main-ui-runtime-test -l` extra probe exited with `0xC0000005`
before registering cases. This GUI executable was not a registered Windows
test; its startup failure remains unexplained and is not evidence that the
Unicode linker or package fixes failed. No GUI-startup fix or Windows UI
acceptance is claimed here. Obtain a native stack before changing that path.

## Native type follow-up: 2026-10-14

The clean Windows build of `5ee901b9` completed at 22:12 CEST with no compiler
errors. All ten backend regression groups, eight WebRTC smoke suites, the
backup archive test and portable distribution checks passed. Its full compiler
log contains **237 warning occurrences**: 200 generated unused helpers/labels,
31 native pointer conversions, four deprecation occurrences and two unchecked
layout-query results. These are occurrences across all targets, not distinct
defects. The previous `4ecbb26a` clean build recorded 207 occurrences.

This follow-up targets the new native diagnostics:

- One generic string-array conversion in the OMEMO historical trust update.
- Four generic string-array conversions when displaying live and cached hat
  titles, compiled into both the application and UI test target.
- One image-output buffer and two menu-button/popover bindings in UI tests.
- Two deprecated test texture constructors, each reported by Vala and C.
- Two unchecked `compute_bounds()` results in the hat-layout test.

Use explicit typed arrays and the APIs' declared native types; do not suppress
warnings or change account ownership, trust decisions, list order or hat
display behavior. The image fixtures must retain their pixel dimensions and
work with GTK 4.14. The 19 historical native signatures below and unused Vala
code-generation helpers remain separate from this bounded cleanup.

The strict Linux build, 24 affected UI runtime cases and 374 local OMEMO cases
pass. A separate generated-C comparison without `-w` removes twelve pointer
diagnostics and introduces none. The remaining local Vala generator diagnostics
match the unchanged baseline; the full extra Linux C check is not warning-free.
The seven affected Windows C units must also pass with incompatible pointers,
deprecations and unchecked results treated as errors. A new clean build will establish
the resulting full warning count. Do not infer it by subtracting corrected
occurrences from 237. Automated package tests do not establish interactive
Windows UI, device/call or profile-unlock acceptance.

## Release 2.3.2 follow-up: 2026-10-12

The clean Windows build of `c9df48d2` completed compilation without errors,
all eight WebRTC smoke suites, and the portable distribution checks. Its full
compilation produced **205 warnings**: 176 unused generated helpers/labels,
the same 19 deferred native signatures as the earlier measured baseline,
and ten new native type occurrences at eight source locations. The later
backend run passed seven suites but failed three sticker folder-import cases
inside libdino; profile locking/storage and OMEMO passed.

The release follow-up fixes those ten new occurrences with typed fingerprint
and retry-delay arrays, the existing GTK widget/popover binding, and explicit
string/byte-length Soup bindings. The sticker import now converts Windows
extension content types through GIO before applying the existing MIME fallback.
Focused MIME, exact binary-response, webhook shutdown and audio-player tests
cover these changes. No dependencies or warning flags were changed, and the
19 deferred native signatures remain visible. A new full Windows warning count
and the complete sticker regression result must come from the final tagged
release build; do not derive them by subtracting ten from this earlier log.

The Windows tray C boundary and light/dark/144-DPI GDI drawing were tested in
an isolated native harness. This does not establish a full Windows application,
interactive tray or physical-device pass. A release still requires the clean
application build, complete portable checker, relevant regression suites and
manual UI/device checks documented in the Windows build guides. New unexplained
warnings or failed gates are not covered by the historical deferrals below.

## Background-image follow-up: 2026-10-11

The clean Windows build of `403c5d2a` passes all package gates and eight selected
test suites: 2076 passed executions and 33 explicit environment/platform skips.
Its complete log contains **188 warnings**, exactly six fewer than `b324fcd6`:
165 generated unused helpers/labels, the 19 deferred native signatures, and the
four remaining GdkPixbuf deprecations. All six corrected generated-C units also
pass strict pointer-type checks. The Windows GdkPixbuf 2.44.6 probe confirms
that its native PNG loader reports valid APNG files as static fallback images.

Background-file validation now checks the already bounded PNG bytes at actual
chunk boundaries before using the existing pixel decoder. It rejects `acTL`,
`fcTL` and `fdAT`, requires a complete initial `IHDR` and a zero-length `IEND`,
and checks unsigned chunk lengths against the remaining input before reading
or advancing. Cancellation remains observable during the scan. It stops at
`IEND`, preserving the existing handling of trailing bytes and of animation
names occurring only inside textual metadata.

The PNG/JPEG pixel decoder, encoded/decoded limits, downscaling, orientation,
background thread and call-choice fences are unchanged. The loader's two
deprecated animation calls are removed rather than suppressed. These changes
apply only to background images explicitly selected for video effects; they
do not change stickers or add animated-background playback.

Linux passes all 256 main and 44 GTK runtime tests. The runtime test opens the
real effects popover with image-capable backend capabilities and checks that
the manual image entry is visible and active, that opening it requests no
file, and that selecting it emits the manual image request. This verifies the
component, not the currently displayed controls of a user's active call.

Real loader tests cover one-/two-frame APNG, APNG with a separate default image,
misleading filename suffixes, orphan frame chunks, malformed/truncated unsigned
chunk lengths, static/indexed/interlaced PNG, metadata false positives, trailing
data, baseline/progressive JPEG, EXIF pixel rotation, cancellation and the
8-MiB input bound. The three affected generated-C units also pass strict type
and deprecation checks without the normal generated-C `-w` flag. A new full
Windows warning count must come from the build of this follow-up, not by
subtracting four from the preceding build's measured total.

Matching loader, image-value class and file-test source spans also pass four
headless groups on Windows with GCC 16.1.0, Vala 0.56.19 and GdkPixbuf 2.44.6.
The standalone probe compiles with incompatible-pointer, deprecation and
discarded-qualifier diagnostics treated as errors and reports no warnings.
Its GLib 2.80 code-generation target avoids obsolete type-registration
boilerplate on the installed GLib 2.88.1; this setting is confined to the
temporary probe. No application compiler flags or dependencies changed.
This proves file loading on Windows, not Windows GTK rendering or calls.

## Follow-up: 2026-10-11

The clean Windows build of master `b324fcd6` emitted **194 compiler diagnostic
occurrences**: 165 unused generated helpers/labels, the 19 deferred native
signatures below, six new pointer-type warnings and four GdkPixbuf deprecation
warnings. A source file built into both the application and a test target
accounts for two occurrences; these are not ten separate defects.

The six new pointer-type occurrences are corrected at three UI boundaries:

- Video-effect choices use `Gtk.StringList` and the normal `Gtk.DropDown`
  constructor, preserving choice order, initial selection and index mapping.
- Server-administration labels use a typed string array with exactly one
  entry per interface. Vala supplies its native terminator outside the logical
  length, so joining retains the original output without a trailing separator.
- Field-help popovers use the existing `set_menu_button_popover` binding with
  GTK's actual `GtkWidget*` parameter and unchanged widget ownership.

These APIs work with GTK 4.14 on the supported Linux baseline and do not raise
the GTK minimum version. Linux validation passes all 256 main and 41 UI runtime
tests, including exact administration labels and effect selection/lifecycle
coverage. All six affected generated-C units also pass pointer-type,
pointer-sign and attribute checks without the normal generated-C `-w` flag.
The subsequent clean Windows result is recorded above; no full-build warning
total was inferred from the incremental Linux checks.

At this stage the four deprecation occurrences remained visible. GdkPixbuf does not provide a
direct non-deprecated replacement for
[`PixbufAnimation.is_static_image()`](https://docs.gtk.org/gdk-pixbuf/method.PixbufAnimation.is_static_image.html).
Its documentation recommends a different library for animated assets. Moving
the same calls behind a warning-suppression wrapper is not an API replacement.

The background path admits only PNG and JPEG and already bounds encoded size,
source dimensions and decoded pixels. Direct probes on Linux GdkPixbuf 2.42.10
show that the native PNG loader reports ordinary PNG, valid one-frame APNG and
valid two-frame APNG as static. Thus the existing animation check must not be
described as reliable APNG rejection. A newer header does not establish that
the decoder recognizes animations; check the installed Windows loader too.

A narrowly scoped alternative is a bounded PNG chunk check before the
existing pixel decoder. Every valid APNG contains an
[`acTL` chunk](https://www.w3.org/TR/png-3/#11acTL), including one-frame APNGs.
Rejecting that chunk is a deliberately stronger format policy, not identical
behavior to the old native loader. Before adopting it, verify ordinary PNG
and JPEG, APNG with and without a default-image frame, one-frame APNG,
truncated/oversized chunk lengths, and metadata containing the text `acTL`.
Check actual chunk boundaries rather than searching arbitrary image bytes.
Retain size limits, orientation, cancellation and asynchronous completion on
both Linux and Windows. The background-image follow-up above implements this
check and removes the four deprecation occurrences at their two source calls.

## Measured baseline: 2026-09-27

The full Windows/MSYS2 compilation of commit `892b2ae1`, using the M152
runtime, emitted **204 compiler warnings**. These are diagnostic occurrences,
including files compiled into more than one target, not 204 distinct bugs.
Two additional Pacman messages about reinstalling the pinned Pango and Tor
packages are not compiler warnings.

| Compiler diagnostic | Occurrences |
|---|---:|
| `-Wincompatible-pointer-types` | 38 |
| `-Wpointer-sign` | 1 |
| `-Wattributes` | 3 |
| `G_LOG_DOMAIN` redefined | 1 |
| `-Wunused-function` in generated C | 138 |
| `-Wunused-label` in generated C | 23 |

The older `df2eb148` cleanup reduced its then-current count from 248 to 191.
That is historical evidence, not the M152 baseline. The former recommendation
to fix legacy RTP first no longer applies: the current Windows profile disables
that target, and those RTP warnings are absent from this log.

## Current bounded cleanup

The current changes target 24 diagnostic occurrences:

- Three `gtk_drop_target_async_get_formats` redeclarations: use GTK's header
  declaration while preserving the borrowed (`unowned`) return value. Keep the
  corresponding runtime-test binding consistent.
- Three `GtkCustomFilter` callback mismatches: match the C `gpointer` parameter
  without changing the Vala object checks, weak owner reference or delegate
  destruction.
- One duplicate `G_LOG_DOMAIN` definition in the ICE test target.
- Fourteen synchronous array argument mismatches at native API boundaries.
- Two Gee array conversions.
- One ICE/Nice receive-buffer signedness mismatch, preserving the buffer's
  bytes, length and lifetime.

The updated Windows application, plugin and test targets compile successfully.
That incremental rebuild emitted 20 diagnostics: 19 unused generated functions
and one of the deferred stream virtual-function mismatches below. This is not
a new full-build warning count: unchanged compilation units were not rebuilt.
Local probes and focused tests do not establish a portable-package or
interactive runtime pass.

The affected Linux application/plugin/test targets compile successfully, and
seven focused Meson test groups pass (main, main UI runtime, contact-list
virtualization, ICE, OMEMO, legacy OMEMO persistence and Tor transport commands).
Small native Windows probes with Vala 0.56.19 and GCC 16.1.0 also pass: the
corrected boundary types are compiled with incompatible-pointer, pointer-sign
and attribute diagnostics treated as errors, then ownership, byte contents and
subprocess argument/error handling are exercised. Those probes were followed
by compilation of the updated application targets on Windows.

The inspected local Linux build invokes the C compiler with `-w` for Vala's
generated C. Its normal log therefore cannot establish the absence of these
warnings. The nine changed generated-C units were also checked separately
without `-w`, with incompatible-pointer, pointer-sign and attribute diagnostics
enabled; all nine passed without those warnings. No project warning flags were
changed by this cleanup.

Two failures in the subsequent Windows regression run were in test setup:

- The main test target did not declare `dep_crypto_vala`. Its indirect
  `libdino-0.dll` import therefore could not locate `libcrypto-vala-0.dll` in
  Meson's Windows test PATH. Declare this dependency for both main test targets.
- The Jingle S5B OMEMO fixture left PREKEY device-list IQs unanswered. Reply
  with the actual sender device using the selected legacy or OMEMO2 schema,
  and require the real completion callback before closing fixture databases.
  An incompatible PREKEY must leave the session unchanged and send no refresh.

A later Windows run also exposed an existing registration-fixture scheduling
race: after synchronous key generation and database writes, its three-second
watchdog could run before an already-answered IQ's queued continuation. Fixture
watchdogs must allow those ready continuations to complete before reporting a
stall. The production IQ timeout is independent of this fixture guard.
The regression covers an unanswered IQ and an acknowledged reply chain with
an already-due watchdog. Restoring the old watchdog priority in generated C
reproduces the failure; restoring the fix passes the complete Linux OMEMO suite.

These corrections change test setup only. Production encryption, IQ timeouts
and the disabled-by-default OMEMO2 runtime flag are unchanged. After these
corrections the Linux main, UI-runtime and complete OMEMO test groups pass.
The final Windows run also passes all nine selected groups: main, contact-list
virtualization, XMPP, ICE, OMEMO, legacy session persistence, profile process
locking, profile durable storage and Tor transport commands. This establishes
the regression-test result, not interactive audio/video-call behavior.

## Native signatures deferred in the September baseline: 19 occurrences

The October 30 cleanup above addresses these boundaries. The following records
why they were previously deferred and the behavior that must stay unchanged.

- Sixteen `InputStream` / `OutputStream` virtual-function mismatches in OMEMO,
  OpenPGP and file-transfer test streams. Local parameter annotations do not
  reliably correct the virtual declarations emitted by the current Vala
  compiler.
- Three GDK asynchronous array argument mismatches. A correction must cover the
  generated async state and its ownership, not just the initiating call.

Keep these warnings visible. A safe follow-up needs its own generated-C review
and stream/async lifetime tests. Do not replace working stream classes, rewrite
async control flow, change broad VAPI/compiler behavior or add blind function
pointer casts merely to remove these diagnostics.

## Generated helpers in the September baseline: 161 occurrences

The remaining generated-code group comprises 80 async `_finish` functions,
28 `_vala_clear_*` helpers, 27 closure `block*_data_ref` helpers, three private
GPG property setters and 23 `__finally` labels. An unused generated helper or
label alone does not show that the Vala operation or its cleanup is missing.

Leave this group visible and separately counted. Do not add global
`-Wno-unused-function` / `-Wno-unused-label` flags: they would also hide new
warnings in handwritten C. Do not alter async completion, closure ownership or
cleanup paths only to reach a zero-warning total.

## Focused validation and logs

- Inspect generated C for the corrected native signatures, array lengths,
  reference handling and destroy callbacks; retain the existing runtime logic.
- Use `Tests for main`, particularly `ContactListSelectionModel` filtering,
  selection and `projection_releases_callbacks`, plus `FileTransferInputTest`
  for the borrowed GTK formats pointer.
- Use `Tests for main UI runtime` for the GTK controller workaround; its X11
  case may legitimately skip on a different backend or unaffected GTK version.
- Use `Tests for ice`, `Tests for xmpp-vala`, `Tests for omemo`,
  `Legacy OMEMO session persistence` and `Tests for openpgp` as relevant to the
  changed native boundaries. Receive-buffer changes also need the corresponding
  transfer/runtime checks before claiming functional acceptance.
- Compile the affected Windows targets and inspect their complete output.
  Capture the full build's stdout and stderr as described in
  [WINDOWS_BUILD.md](WINDOWS_BUILD.md) and
  [WINDOWS_BUILD_EN.md](WINDOWS_BUILD_EN.md). The later strict test-build phase
  and its `build_log.txt` cover only that phase; passing it does not make the
  earlier full compilation warning-free.
- Keep compilation, portable-package checks and interactive runtime results
  separate. Do not repeat a full build solely to recount unchanged diagnostics.

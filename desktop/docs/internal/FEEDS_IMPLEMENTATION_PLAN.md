# Feeds implementation plan

Scope: readable RSS/Atom articles in direct chats and MUCs, optional automatic
posting while DinoX runs, and native XMPP social feeds (XEP-0472 base and
microblog profiles). No server daemon. Linux and Windows share the implementation.

## Work order and acceptance

- [x] Parse RSS 2.0, RSS 1.0 and Atom into bounded Unicode text, preserving
  article links and handling `content:encoded`. Reject unsafe XML and URLs.
- [x] Fetch asynchronously through the selected account's network route, with
  cancellation, response limits, conditional requests and no hidden direct fallback.
- [x] Add an embedded Feeds dialog: account selection, article preview, explicit target
  chat selection and ordinary encrypted chat dispatch.
- [x] Persist opt-in automatic subscriptions and deduplication in the encrypted
  profile database. New subscriptions skip existing articles. Pause/remove
  controls, restart safety, fixed account/target and visible failures are required.
- [x] Read and subscribe to XMPP social nodes; handle notifications without
  payload, retractions and reconnection. Publish text posts and replies with
  acknowledged results, stable item IDs and explicit access policy.
- [x] Add German translations and English/German usage documentation; include
  common build sources without introducing platform-specific dependencies.
- [x] Run focused parser, storage, protocol and isolated UI checks; build the
  Linux application with at most two jobs. Record Windows and live cross-client
  checks separately from checks actually performed.

## Boundaries

Chat sharing uses the existing message storage/encryption pipeline. Native
PubSub posts are not end-to-end encrypted. Feed HTML is converted to text;
scripts and external images are not loaded. No live chat sends or public posts
are made during development without a designated test destination.

Automatic delivery deduplicates the local outgoing queue, not remote delivery
receipts. Failed outgoing messages remain visible in the chat and use its normal
retry behavior. Disconnected accounts and departed/read-only rooms do not cause
automatic sends or joins. A changed encryption selection pauses an automatic
subscription until the user explicitly approves its current target settings.

## Validation record

Validated locally on 2026-10-22:

- Strict Linux build through `scripts/build.sh --strict`, limited to two jobs:
  passed with zero compiler warnings. Updated executable: `build/main/dinox`.
- `build/libdino/libdino-test -p /Feeds`: all twelve tests passed, including
  RSS/Atom/Unicode/XML encodings, unsafe XML and URL rejection, encrypted schema
  migration from version 57, account-scoped persistence, deduplication and
  encryption fencing, PubSub publish/read/reply/retract and visibility checks,
  notification handling across reconnects, HTTP limits/redirects/304/cancellation,
  and no direct request after SOCKS5 failure.
- Unicode follow-up: reproduced the old cut dropping combining accents and
  splitting emoji/flags. Pango grapheme boundaries now preserve decomposed
  Latin/Cyrillic letters, skin-tone/ZWJ emoji, flags and CRLF. Verified UTF-8,
  UTF-16LE/BE and UTF-32LE/BE with/without BOM, plus declared Windows-1251.
  Malformed/truncated encodings and NUL input fail; invalid outgoing text is
  rejected before a queue row/dedup key or a PubSub publication is created.
  Pango is explicitly linked by the core and already belongs to the GTK runtime
  on Linux and Windows. These are local tests of the shared implementation.
- `build/main/main-ui-runtime-test -p /FeedsRuntime`: passed in isolated
  Xvfb/D-Bus with German translations and fatal GTK warnings enabled. All three
  tabs fit while resizing the actual host from 960 to 430 pixels, including a
  long Unicode node label. Feeds and its composer remain inside the application;
  neither creates a separate top-level window. The German catalog is asserted
  after locale initialization. Closing also closes child dialogs and disconnects
  callbacks. Screenshots were visually checked. The headless X server reported
  its unrelated DRI3 availability notice.
- The real Monocles releases RSS URL parsed into 13 readable articles, including
  HTML release descriptions in `content:encoded`; no article was sent.
- German gettext catalog validation and `git diff --check`: passed.
- Feed/OMEMO retry regression: passed through the real feed queue,
  MessageProcessor and native legacy encryption with an isolated IQ transport.
  A direct record and a group record share the room address; a pending group
  send stays a group on device-list callbacks. Only the missing member's list
  is requested, concurrent requests coalesce, and a successful empty list
  terminates the attempt instead of looping. After devices and sessions are
  available, explicit retry writes exactly one encrypted group stanza.
- Existing OMEMO suites `MultiAccountMessageState` (9),
  `OutgoingCurrentDevice` (14) and `OmemoSendState` (8): all passed.
  Together with the new regression, twelve feed tests and one UI test: 45 passed.
  The OMEMO German catalog is valid; `msgfmt -c` also reports its pre-existing
  missing `Last-Translator` header. No compiler warnings were emitted.
- Checked generated GMarkup callback declarations against GLib's const-qualified
  C signature; this is a portability check, not a Windows build result.

Reproduction: use the normal vendor dependency environment documented in BUILD.md
and set `DINOX_BUILD_JOBS=2` for the strict build. Run the core test command above.
For the UI test use an isolated display/session, `LANGUAGE=de`, a compiled `dino.mo`
in `DINOX_UI_TEST_LOCALE_DIR`, `GSETTINGS_BACKEND=memory`, `GTK_A11Y=none`,
`ADW_DISABLE_PORTAL=1`, `GTK_USE_PORTAL=0`, `GIO_USE_VFS=local`,
`GSK_RENDERER=cairo`, and `G_DEBUG=fatal-warnings,fatal-criticals`. The feed-only
UI fixture needs no media plugins or live profile.
Not run: a Windows build, live Tor/Lyrebird transport, and live interoperability
with Gajim, Monocles or Movim. The supplied repeated-warning excerpt does not
establish which of the reproduced retry defects triggered that particular run.
No real chats received test messages and no real social
posts were published. Do not infer these results from fixture tests.

### Focus follow-up, 2026-10-23

- Reproduced the exact `GtkText - did not receive a focus-out event` warning
  when disabling a container whose entry owns keyboard focus. Clear that focus
  while the controls are still sensitive, before starting a feed operation.
  Clear focus in replaced result/subscription rows before detaching them as well;
  refreshing an unrelated page must preserve the current input focus.
- Strict Linux build: zero compiler warnings. Both `/FeedsRuntime` tests pass
  with fatal GTK warnings. The real feed dialog loads one loopback RSS response
  from one activation, releases the native text focus controller synchronously,
  displays the result and re-enables its inputs. The tests also cover removing
  a focused editor, unrelated-page focus, and Unicode clipboard behavior.
- Separate open case: after loading, focus the URL with the caret at its end,
  then programmatically resize the host from 960x760 to 430x640. The isolated
  GTK fixture reports `GtkText - unexpected blinking selection. Removing`.
  This change does not fix that case. Layout checks explicitly end the focused
  editing scenario before resizing; passing them does not prove resizing with
  an active editor. This warning has not been reproduced with a manual resize.
- The focus changes use shared GTK APIs. Windows execution remains untested.

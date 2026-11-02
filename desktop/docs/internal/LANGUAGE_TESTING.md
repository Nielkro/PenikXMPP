# Language-independent application behavior

The language matrix covers existing DinoX code as well as new features. It reads
the offered languages from `main/po/LINGUAS`; the catalog test checks agreement
with both plugin lists and the native language selector. English is the source
language and does not require an `en.mo` file.

## Running the checks

Build with `./scripts/build.sh --strict`, using the normal dependency environment
described in BUILD.md. Then run:

```sh
meson test -C build --no-rebuild --num-processes 2 --timeout-multiplier 3 \
  --print-errorlogs --suite languages --suite locale-boundaries --suite systray
```

For a machine-readable catalog report:

```sh
python3 scripts/check-runtime-languages.py --build-dir build \
  --report /tmp/dinox-catalog-languages.json
```

Tests use temporary profiles, local fixtures and synthetic messages. They do
not log in to an account, contact a broker, send messages, open a camera or start
Tor. The tray checks use an isolated D-Bus session.

## What is checked in every offered language

| Area | Production boundary exercised |
| --- | --- |
| All application and plugin strings | Fresh POTFILES extraction, including `n()` plurals; all current keys in `dino`, `dino-omemo`, `dino-openpgp`; actual native catalog discovery and gettext lookup against freshly compiled PO references |
| Language selection | Packaged/selected languages agree, regional variants, unsupported-language fallback, actual GTK reading direction, UI language does not replace system number/date formats |
| Settings and dialogs | Real general and audio/video page constructors; actual account, login and password templates; current translated titles, help text and option labels |
| Chat, groups and forms | Unicode draft ranges and input, Enter/Ctrl+Enter, server-form labels/help, Hats color/form values, login-protection controls, feed text menus |
| XMPP | Location numbers/timestamps, SDP parameters, fixed XEP-0115 capability-hash vector using byte ordering |
| Files and previews | MIME types/extensions, ESFS cipher identifiers, download error codes, HTML offsets, native media widget selection, raster sticker filtering |
| Calls/media | RTP identifiers reach GStreamer caps unchanged; audio/video settings preserve device identity independently of display names |
| Botmother | Command/provider permission keys and the actual provider selection mapping |
| MQTT | Priorities, numeric JSON thresholds through alert evaluation/persistence, M3U/PLS tokens and Unicode URLs |
| OMEMO | Existing decryption byte/UTF-8 handling, error classification and send-safety tests; no changes to keys or sessions |
| OpenPGP | MIME detection and Windows drive/Unicode path parsing |
| Tor | Quoting and Unicode in native helper command paths |
| Linux tray | Both status-notifier watchers, translated menus, direction, Unicode, isolated proxy/lifecycle checks |

These are targeted behavioral contracts, not every test repeated for every
language. Run the full normal test suite as well when changing shared behavior.
The native settings fixture verifies templates without attaching a real account;
it does not prove that account registration, certificate acceptance or password
changes succeed against a live server.

## UI language and system locale

`scripts/language_test_support.py` records the system-region mapping explicitly.
Each boundary process receives both a verified native system locale and the
selected application language. Missing Linux locale data can be generated in a
temporary directory; nothing is installed or changed system-wide. Missing
locales exit 77 and remain visible as skipped tests. A skipped language is not a
passed language.

Egyptian Arabic uses `ar_EG` regional formats with the **arz** UI catalog; Nigerian
Pidgin uses `en_NG` formats with **pcm** UI. These are regional-format mappings,
not substitutions of the UI translation. Windows uses native CRT locale names.
If a new offered language lacks a reviewed mapping, the matrix fails rather
than quietly running it with C settings.

Catalog tests use a verified non-C base locale and a fresh native process for
each UI language. They verify `SearchPathGenerator` results from their own
executable. Neither forced catalog paths nor old installed catalogs can stand
in for current build catalogs. Translations of valid source Pango templates must
also parse with the native Pango parser, including templates outside the opened
widget fixtures. Literal plain-text angle brackets are not classified as markup.

Plural checks include 0, 1, 2, 3, 5, 11, 21, 101,
200 and one million, as well as intermediate boundary values.

## Rules established by the source audit

- Technical ASCII identifiers use `ascii_down()`/`ascii_up()` where comparisons
  are already case-insensitive. Do not apply this to message text, usernames,
  translated labels, passwords or arbitrary Unicode paths.
- XEP-0115 hash inputs use `strcmp` byte ordering, as required by
  [XEP-0115 section 5.1](https://xmpp.org/extensions/xep-0115.html#ver-gen).
  Display-name lists may still use locale-aware collation.
- Protocol numbers use ASCII serialization/parsing. Localized display strings
  are not protocol values. Location and Hats tests exercise this separation;
  MQTT tests follow actual JSON values into stored threshold evaluation.
- Technical error codes decide retries. Translated error messages remain
  presentation text; existing fallback text handling is secondary.
- The remaining Unicode case conversions were reviewed separately: human
  searches/mentions and avatar initials keep Unicode behavior; valid hexadecimal
  fingerprints/hashes contain no locale-sensitive I/i characters. Do not rewrite
  historical passphrase normalization as a cosmetic case cleanup.
- Settings persist identifiers/indexed choices, not translated labels. GTK text
  and real option models are covered independently of catalog-file completeness.

## Validation recorded on 2026-11-01

The native Linux build passed `./scripts/build.sh --strict` with zero compiler
warnings in the changed sources. The language run covered English and all 37
translated variants:

- 495 unique language test groups passed: 418 boundary groups, 76 tray groups
  and the all-language catalog group. No language group was skipped. The first
  run exposed two English tray-fixture failures because it required `en.mo`;
  both passed after correcting that test assumption.
- Each variant passed 3,945 native gettext lookups across the three domains,
  including context/plural handling and valid Pango templates. The settings
  fixture verified 211 actual widget texts per variant.
- The additional normal regression passed all 61 groups. Its 55 initially
  skipped opt-in cases were subsequently run with disposable server accounts,
  generated OpenPGP keys, real Tor and isolated Xvfb input. See the breakdown
  below; group success alone is not evidence that an opt-in case ran.
- Catalog/metadata completeness, AppStream and desktop-file validation passed.

Two old defects were reproduced through production functions before the fix:
an uppercase ESFS cipher identifier was accepted under German but rejected
under Turkish settings, and identical XEP-0115 forms produced different hashes
under C and German collation. Both now produce the same result across the
language matrix. Test commands and the coverage table above define the scope;
this run does not establish Windows or package-runtime results.

### Additional opt-in checks

All 55 formerly skipped cases passed after setup and fixture corrections. The
final complete `/LiveGPGHelper` run passed all 58 cases, including the 24 that
had required external key setup. The strict rebuild of the changed test sources
reported zero warnings. Disposable accounts, rooms and their upload directories
were removed from the server and their absence checked. Temporary key material
and test-owned GnuPG/Tor processes were cleaned up locally.

Missing accounts, keys, Tor opt-in or a virtual display are setup requirements,
not reasons to leave an authorized integration run untested. Keep the ordinary
test suite offline by default and explicitly prepare these separate runs:

| Cases | Setup and coverage |
| --- | --- |
| 25 remote cases | Three disposable accounts with mutual roster subscriptions, a prepared private room and generated temporary rooms. XEP-0490 across two resources; room affiliations; plain, legacy OMEMO, OMEMO 2, XEP-0027 and XEP-0374 file transfers; separate Jingle senders/receivers; XEP-0373 key discovery. The independent senders were the Python XMPP/S5B harness and `go-sendxmpp`. |
| 24 live-GPG cases | A private `GNUPGHOME`, two generated signing/encryption keys with matching email and `xmpp:` UIDs, and isolated data/cache directories. Includes real encryption/decryption, archive rejection cases, signed presence, key discovery, HTTPS upload and all four cancellation cases. |
| 4 Tor cases | Real Tor bootstrap and onion services, S5B byte transfer with and without JET, receive/store through FileManager, and rejection of a loopback candidate without a direct connection. |
| 2 native-input cases | Actual Enter/Ctrl+Enter and file-menu right-click injection on Xvfb. Both were exercised in English and all 37 translated variants. |

The server runs use the `run-remote-*-smoke.sh` entrypoints documented in
[TESTING.md](TESTING.md). Grant contact subscriptions only between the test
accounts; automatic downloads deliberately require a trusted sender. OpenPGP
fixtures verify the generated/imported fingerprint before marking it trusted.
Fetched keys must not become automatically trusted in application code.

For the real local GPG group, supply full fingerprints in
`DINOX_OPENPGP_TEST_SIGNER` and `DINOX_OPENPGP_TEST_RECIPIENT`, set
`DINOX_OPENPGP_TEST_ISOLATED_GNUPGHOME=1` and
`DINOX_OPENPGP_TEST_REQUIRE_LIVE=1`, then run
`build/plugins/openpgp/openpgp-test -p /LiveGPGHelper` with the build libraries
on `LD_LIBRARY_PATH`. Generate keys in a new mode-0700 temporary home; never
point this run at the user's keyring. Stop that home's GnuPG helpers with
`gpgconf --homedir "$test_key_home" --kill all` before removing it.

The four native Tor cases require `DINOX_TEST_REAL_TOR_S5B=1`,
`DINOX_TEST_REAL_TOR_HIDDEN_SERVICE_S5B=1`, a valid `DINOX_TEST_TOR_PATH`
and GLib thorough mode (`-m thorough`). Run them sequentially with generous
outer timeouts and clean up only the Tor processes owned by the test. Two
initial onion runs timed out during connection setup; both passed on retry
without a production-code change. These retries remain part of the result.

Use `DINOX_TEST_NATIVE_KEYS=1` for the input cases and follow the isolated
desktop-service setup in [TESTING.md](TESTING.md#isolate-desktop-services-in-gui-probes).
Check individual TAP results for `SKIP`, not only the process exit code.

The additional run exposed outdated test assumptions: an invalid upload slot
is now rejected before upload; private group conversations need an enabled,
registered account, their parent room and a current occupant identity; and
OpenPGP send tests need explicit fingerprint verification. These fixtures were
corrected without weakening the application's checks. A bounded receiver
cleanup gate also lets the separate OMEMO-2 guard finish before test PEP state
is restored. These remote checks ran once per protocol scenario, not once per
language. The all-language boundary matrix remains the language-specific proof.

## Limits of this evidence

Passing this matrix is reproducible evidence for the listed contracts. It does
not prove linguistic quality, every possible screen size, every plugin dialog,
all live-server interactions or every hardware/desktop combination. Linux runs
do not prove Windows, AppImage or Flatpak runtime behavior. Those platforms need
their native build/package checks; unavailable checks must remain explicit.
Any newly found language-sensitive boundary should get a production-path test
and join this matrix, rather than adding one temporary language-only check.

# Account login downgrade protection

DinoX implements XEP-0474 0.5.0 and XEP-0515 0.1.1 in its production SASL1
SCRAM path. These XEPs are experimental. SASL2/Bind2/FAST development remains
on a separate branch and is not enabled by this change.

## Behaviour

- Prefer mutually usable SCRAM-PLUS, then SCRAM. SHA-512, SHA-256 and SHA-1
  use their respective hash for the XEP-0474 `h` attribute.
- Hash the complete advertised SASL1 mechanism list (including unknown methods)
  and XEP-0440 binding types, sorted by octet, with the specified separators.
- Validate `h` and `t` when supplied. `t` is compared with the protocol actually
  negotiated by GIO, not a configured minimum. Both attributes remain in the
  authenticated SCRAM transcript. A missing optional attribute on an older
  server does not by itself prevent login.
- If SCRAM-PLUS and binding types are advertised but no binding can be used,
  bare SCRAM may continue only with a matching `h`. The explicit per-account
  channel-binding requirement still prohibits that fallback.
- Reject malformed/duplicate SCRAM attributes, a nonce without a server suffix,
  invalid server proofs and iteration counts outside 4,096–1,000,000. Rejected
  challenges never receive a client proof and cannot trigger a PLAIN retry.
- Only a verified server proof confirms SCRAM use. The account remembers this
  across reconnects, password changes and restarts. Later PLAIN use is blocked
  even if the compatibility option was previously enabled. A failed database
  update stops authentication instead of silently losing this protection.
- Password login (PLAIN) is disabled by default, including existing accounts
  migrating to this version. Users of a PLAIN-only server must explicitly
  allow it for that account. It still requires TLS and cannot override a
  confirmed SCRAM history or the channel-binding requirement.

## UI

Account preferences → Advanced Settings → **Allow password login (PLAIN)**.
The same option is in the advanced settings when signing in to an existing
account. A confirmed SCRAM history disables the option with an explanation.
The **Login protection** group appears near the top of account preferences,
directly after the connection status. It provides two explicit choices:
**Use when available** prefers SCRAM-PLUS but allows a login without channel
binding; **Require for sign-in** requires usable SCRAM-PLUS. Existing account
settings retain their meaning. TLS remains required in either case. Both choices
are enabled only after a successful SCRAM-PLUS login confirms availability for
this account. **Server support** shows a green check for confirmed availability,
a red cross for unavailable/incompatible protection, a spinner while checking,
and an unknown state before checking. Connection failures show a warning rather
than falsely claiming that the server lacks support. Icons have plain-text and
accessible descriptions; they do not depend on Unicode glyphs or colour alone.
Changing the policy rechecks the current account's proof at activation, saves
the selection and automatically reconnects only that account. Pending choices
are disabled; the new connection supplies the success/failure feedback. The
normal ConnectionManager path preserves Tor/proxy/DNSSEC/certificate policy and
does not remove OMEMO identities. The native selection popover closes before
its model is replaced. Account switches/disposal invalidate pending UI updates.
**Check now** explicitly reconnects when a fresh check is needed. If a previously
required policy becomes unusable, an explicit **Allow sign-in without extra
protection** action permits recovery; failure never relaxes that policy itself.
The server's SCRAM-PLUS offer is retained from the pre-authentication features
to distinguish absence from an offer that could not actually be used.
**Current connection** separately reports verified SCRAM-PLUS use, an encrypted
login without it, or an unknown/pending result. An advertised offer does not
prove successful use, and neither the selected policy nor remembered SCRAM use
is a live status. Reconnects and account switches cannot reuse a previous
connection's displayed result. A required-protection failure explains
that sign-in was not continued, without labelling an ordinary encrypted
connection as unsafe. No security setting is automatically relaxed.
Security failures have distinct translated messages in account setup, account
preferences and Linux/Windows notifications; they are not labelled as an
incorrect password.

The policy belongs to an account, not its server domain: two accounts at the
same provider can have different compatibility settings and SCRAM histories.
No history is inferred from old logs. Existing accounts acquire the persistent
SCRAM marker on their next verified SCRAM login. Removing and recreating an
account removes its history; PLAIN is still disabled by default.

## Platforms and scope

Linux and Windows share the same Vala implementation. The negotiated TLS
version comes from GIO 2.70+. Older GIO builds can continue with servers without
`t`; if `t` is supplied but the local version cannot be determined, login fails
closed. Current packaged Linux and Windows runtimes provide this API.

The account-level PLAIN exception is not inherited by dedicated Botmother
sessions: those use the shared SCRAM checks and require SCRAM.

This protects account login, independently of OMEMO/OpenPGP message encryption.
TLS certificate validation and DNSSEC/DANE remain in the existing connection
layer. Proxy/Tor routing is unchanged. No external login service is used.

## Repeatable tests

After `DINOX_BUILD_JOBS=2 ./scripts/build.sh --strict`:

```sh
build/xmpp-vala/xmpp-vala-test -p /SaslSecurity
build/xmpp-vala/xmpp-vala-test -p '/SASL channel binding'
build/libdino/libdino-test -p /ConnectionManagerAudit/sasl_policy_survives_restart_and_is_account_scoped
meson test -C build --no-rebuild 'SASL TLS downgrade protection' --print-errorlogs
build/xmpp-vala/xmpp-vala-test -p /AvatarProtocolAudit
build/xmpp-vala/xmpp-vala-test -p /MessageDisplayedSync
build/xmpp-vala/xmpp-vala-test -p /ReconnectStartup
build/xmpp-vala/xmpp-vala-test -p /PubSubAudit
build/plugins/omemo/omemo-test -p /LegacyBundlePubSub
```

The TLS fixture uses temporary self-signed certificates trusted only by the
probe, loopback TCP sockets, Unicode paths/usernames/passwords and an independent
Python hashlib/hmac SCRAM server. It exercises direct TLS and STARTTLS with
TLS 1.2 and 1.3, all six SCRAM variants, old-server compatibility, tampered h/t,
invalid server proofs, PLAIN consent/pinning and required channel binding.
It neither reads a user profile nor sends credentials to a real server.

Changing login protection reconnects the selected account and cancels pending
avatar and read-state synchronization. The cancellation regressions exercise
the real IQ/PubSub async chain before sending, during a request, after a reply
and during stream detach, followed by a fresh avatar fetch. Cancellation must
not confirm empty remote state or a successful mutation. In particular, Vala's
GTask can return null from a non-throwing method with a cancelled token even
when its body returned a failure object. Consumers check that result before
reading its fields; uncertain avatar writes still require reconciliation.

Repeated checks can also cancel post-login blocklist, carbons and OMEMO
device-list requests. Those local cancellations are logged at debug level.
PubSub retains typed local cancellation separately from remote errors: an
XMPP error with `type="cancel"` is still a server failure. OMEMO must not emit
a loaded-empty or failed-list signal for a locally cancelled request, even
when the IQ waiter resumes before OMEMO's own detach handler. The replacement
stream fetches current device lists normally; no trust or key state is reset.

References: [XEP-0474](https://xmpp.org/extensions/xep-0474.html),
[XEP-0515](https://xmpp.org/extensions/xep-0515.html).

## Verification on 2026-10-23

- Strict local Linux build: passed, zero compiler warnings.
- Repeated reconnect follow-up: 206 focused startup, PubSub, blocklist,
  carbons, IQ-lifecycle, avatar, read-state and OMEMO tests passed. New cases
  cover cancellation before the OMEMO detach handler, fresh own/contact
  device-list retrieval on the replacement stream, late old replies, and
  remote errors with `type="cancel"` that must remain failures. Existing
  registration, publication and multi-account error-scope tests also passed.
- Reconnect follow-up: a production core identified a null PubSub result in
  `fetch_current_avatar`. The new cancellation test reproduced SIGSEGV before
  the fix. Afterwards, 171 focused avatar, read-state, PubSub, IQ-lifecycle and
  OMEMO publication/maintenance tests passed, including 26 new cancellation
  scenarios. The Linux strict rebuild completed with zero warnings. This is
  automated lifecycle coverage, not a new interactive Windows result.
- Initial XMPP suite: 973 tests passed, including the new SASL security cases.
  After adding server-support display, all six focused SASL security groups
  passed, including connection-local offer snapshots and feature resets.
- Connection manager: 9 tests passed, including account isolation, durable
  reload, schema-58 migration and an injected pin-write failure.
- Real TLS fixture: 88 cases passed, including removed transcript attributes
  and a rejected persistence callback after a valid server proof. Re-run after
  adding server-support display also checks each offer snapshot against the
  fixture's actual advertised mechanisms.
- Existing DANE/ordinary TLS gate: 26 cases passed; rejected connections sent
  no XMPP header or credentials.
- Native GTK builder: account setup and the new preference row loaded with
  German translations and the compatibility option disabled by default.
- Login-protection feedback: five runtime test groups passed in German and
  English. Unfinished/failed proofs, reconnects, disabled accounts and streams
  without fresh SASL evidence cannot be shown as confirmed additional
  protection. A server offer without actual use is displayed distinctly.
  Native icon/selection tests verify the green check, red cross, pending state,
  connection failures, both policy gates, account isolation and a connection
  disappearing after opening the selector. Both policy choices and positive/negative server results pass native GTK
  sizing checks at 300, 430 and 600 pixels in German and English.
- Windows runtime execution: not performed in this change. The common Vala
  path, Windows notifications and Unicode-safe probe arguments were updated.

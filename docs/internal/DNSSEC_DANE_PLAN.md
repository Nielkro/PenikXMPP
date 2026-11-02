# DNSSEC and DANE implementation plan

Status on 2026-10-22: XMPP and MQTT enforcement, per-account/per-broker settings,
DE/EN text and network-account diagnostics are integrated on master. Component
fixtures run on Linux and native Windows. Package wiring is committed and static
checks pass. The updated Forgejo image and clean Windows distribution build have
started; package completion and authenticated account/UI acceptance are not yet
confirmed. Isolated application-controller Tor/WebTunnel checks passed below.
Package acceptance remains a release prerequisite; source integration alone
does not certify the portable application or distributable packages.
Requested on 2026-10-21. The unrelated Windows GTK measurement warning is out
of scope. Implementation must not change the user's active accounts or DNS
configuration while developing or testing this feature.

## User decisions and UI

Users choose whether to enable DNSSEC/DANE. Existing accounts retain their
current TLS verification unless they explicitly opt in. There is no automatic
conversion to a stricter mode after a successful connection.

Place a **Connection security / Verbindungssicherheit** group in
**Preferences → Accounts → selected account**, next to the existing server
certificate and connection settings. Do not put it in chat encryption settings:
OMEMO and OpenPGP protect messages; this feature authenticates the server
connection.

The group contains:

- **DNSSEC and DANE / DNSSEC und DANE**: off by default.
- When enabled, **Check supporting domains / Unterstützende Domains prüfen**
  or **Require DNSSEC and DANE / DNSSEC und DANE voraussetzen**. Explain that
  the first mode allows unsigned domains, but does not bypass DNS failures. Do
  not imply that an unreachable resolver counts as an unsupported domain.
- The DNS resolver configuration for this account, including an explicit
  protected resolver transport for proxy connections. No unsolicited third-party
  DNS service or operating-system-wide DNS changes.
- Current result, last failure and a retry action. Clearly distinguish
  certificate verification, DNSSEC verification and successful DANE binding.
- Save and apply changes as one coherent configuration, then reconnect only the
  affected connection. Do not reconnect on each keystroke.

The existing network overview shows a short result per account and links to
that account's settings. Do not reuse the green OMEMO/OpenPGP verification badge.
MQTT has corresponding settings next to each broker's TLS configuration.
Standalone MQTT is configured independently of XMPP accounts.

## Account and route isolation

This is a mandatory boundary, not just a UI preference:

- Persist XMPP mode and resolver configuration in `account_settings`, keyed by
  account ID. Do not store them as one global switch or key them only by domain.
- Two accounts on the same domain may use different policies and proxies.
- Each connection attempt captures account ID, policy, service domain, custom
  host/port, effective route and configuration generation before awaiting DNS.
- Ignore late results after account removal, policy/host/proxy changes,
  disconnect, Tor restart or a newer connection attempt.
- Validation contexts and caches are partitioned by account, resolver, route
  and configuration generation. Never reuse results obtained directly for a Tor
  connection, or use a result from account A to authorize account B.
- Follow the existing route precedence: account SOCKS5 override, otherwise
  integrated Tor when selected, otherwise direct. An unavailable proxy must not
  result in a direct query or connection.
- Per-account MQTT retains the owning account and its effective routing. Its
  broker-specific policy and TLSA name are distinct from the XMPP endpoint.
  Standalone MQTT has a separate configuration and lifetime.
- Failure of one account or broker must not block or modify other accounts.

## Verification and outage policy

| Situation | Off | Use when available | Require verification |
| --- | --- | --- | --- |
| DNSSEC-authenticated usable TLSA records | Existing TLS | Enforce TLSA | Enforce TLSA |
| Proven unsigned delegation, or authenticated absence of TLSA | Existing TLS | Existing TLS, no DANE success claim | Do not connect |
| Only unsupported TLSA records | Existing TLS | Follow RFC usability rules; ordinary TLS, explicit status | Do not connect |
| Invalid DNSSEC signature / authenticated TLSA mismatch | Existing TLS | Reject affected service/endpoint | Reject affected service/endpoint |
| DNS timeout, SERVFAIL, unavailable validator or unresolved validation state | Existing DNS/TLS behavior | Retry within bounded limits; no silent downgrade | Retry within bounded limits; no silent downgrade |

An outage is not proof that a domain is unsigned. A failure at one endpoint may
allow another independently validated endpoint from the same authenticated SRV
answer; it must not introduce an unvalidated fallback. Bogus SRV discovery
rejects that service discovery attempt (RFC 7673 section 3.1).

Resolver failover may use only resolvers configured for that account and the
same permitted route. It must retain validation requirements. No public fallback
resolver, permanent bypass, automatic disabling, or automatic DANE pinning.
Explain an outage in plain language and leave the chosen mode unchanged.

## Existing implementation and integration points

Reviewed DinoX base: `cbbb94e8`.

- `xmpp-vala/src/core/stream_connect.vala`: SRV discovery, endpoint ordering,
  custom target, proxy bypass of local SRV queries and retry loop.
- `direct_tls_xmpp_stream.vala`, `starttls_xmpp_stream.vala` and
  `tls_xmpp_stream.vala`: GIO TLS, certificate callbacks and channel binding.
- `libdino/src/service/connection_manager.vala`: account lifetime, reconnect
  generation, pinned certificates, TLS errors and certificate prompt.
- `main/src/windows/preferences_window/account_preferences_subpage.vala` and its
  UI file: per-account settings and certificate display.
- `plugins/tor-manager/src/ui_indicator.vala`: existing network overview;
  diagnostics only, not owner of connections or reconnection policy.
- `plugins/mqtt/src/plugin.vala`: account and standalone broker configuration.
- `plugins/mqtt/src/mqtt_client.vala`: libmosquitto/OpenSSL TLS and reconnects.
  XMPP's GIO TLS hook cannot enforce MQTT's TLS connection.

Monocles upstream `7dc0a7c` has MiniDNS validation and a DANE trust manager.
Its selected SRV hostname, usable TLSA records and enforcement preference affect
trust evaluation. It also pins DANE after success. That automatic pinning is not
part of DinoX's user-selected policy. Its fallback behavior must not be copied
without evaluating the failure type and proxy route.

In Monal develop `26e8d04326119af400f2fafb2a412c6c28d0f62b`, the reviewed
`MLDNSLookup.m` leaves `kDNSServiceFlagsValidate` commented out. Its `isSecure`
field in that path distinguishes direct TLS from STARTTLS, not DNSSEC. This is
not a complete audit of Monal or a claim about all branches/releases.

## Technical implementation sequence

### 1. Policy and ownership contract

- Implement explicit validation states: secure, insecure, bogus, indeterminate.
  Keep no-data, unsupported TLSA, transport failure and cancellation distinct.
- Define decisions before opening an authenticated application stream.
- Define immutable per-attempt configuration and result ownership.
- Add deterministic tests of the decision table, account separation, timeout
  behavior and invalid persisted values. No public network needed.

### 2. DNSSEC resolver and permitted transports

- Use `libunbound` for local DNSSEC chain validation, not a new signature
  implementation and not an untrusted resolver's AD bit.
- Use an asynchronous wrapper with bounded requests, cancellation and cache TTLs.
  Do not block GTK's main thread or run a system DNS daemon.
- Direct mode may use the system's configured resolvers, with local validation.
  Reading resolver configuration must work natively on Linux and Windows.
- Proxy mode needs a restricted forwarding adapter: local validation receives
  DNS messages through an account-scoped transport over that account's proxy.
  DNS-over-HTTPS is a candidate transport using existing libsoup support. Its
  resolver must be selected/configured explicitly; validate HTTPS certificates,
  bootstrap through the proxy and reject redirects that escape the route.
- The validator must use only that forwarding path, including DNSKEY/DS and
  negative-proof queries. Disable direct recursive fallback, stale answers and
  permissive validation. Prove this with intercepted outbound traffic.
- Ship documented IANA root trust anchors and define a signed/validated update
  and rollover process. Include both relevant anchors for the current rollover;
  never download a replacement trust anchor over unauthenticated DNS.
- Normalize IDNA names, preserve certificate reference identities, reject
  malformed names and bound CNAME/DNAME chains, response size and query count.

### 3. XMPP DANE enforcement

- Validate SRV discovery, authenticated delegation, A/AAAA and TLSA according to
  RFC 7673. Construct TLSA names from the actual selected target/port, not always
  the bare JID domain. Preserve SRV priority/weight semantics.
- Specify custom-host handling explicitly: a manually configured target is an
  explicit user delegation; do not infer that an arbitrary discovered target is
  authenticated. Treat DNSSEC absence and discovery errors separately.
- Validate the certificate of the actual live TLS connection, before any SASL
  authentication or stream resumption. Cover both direct TLS and STARTTLS.
- The current inner STARTTLS setup catch only logs an error. The new security
  gate must propagate its failure and close the stream; it must never flow
  through that warning-only catch into negotiation. Exercise this control path
  with a failing TLS fixture before enabling the feature.
- Handle supported TLSA usages/selectors/matching types and certificate rollover
  as a record set. PKIX-constrained records still require PKIX validation;
  DANE trust anchors need actual chain validation, not a hash somewhere in an
  unverified presented chain. Unsupported records are not successful matches.
- A DANE failure must bypass neither via the certificate-pin prompt nor via
  `.onion` exceptions, retries or a different stream constructor.
- Keep TLS channel binding and normal TLS validation intact when DANE is off or
  legitimately unavailable. Never advertise successful DANE before verification.

### 4. Tor, Lyrebird, SOCKS5 and special addresses

- Resolve public XMPP/MQTT domains only through the configured route when a
  proxy is active. Guard proxy/resolver bootstrap as well as TLSA queries.
- Do not query public DNS for `.onion`, IP literals or local-only broker names.
  Show DANE as not applicable there. A required mode must explain why that
  target cannot satisfy it instead of silently granting an exception.
- Tor/Lyrebird authenticate their own transport infrastructure. Do not apply
  XMPP TLSA rules to bridge lines, Tor relays or WebTunnel endpoints, and do not
  introduce a dependency cycle in Tor startup.
- Preserve the existing intentional local MQTT bypass. Do not export local
  broker names to public resolvers. This is independent of account XMPP routing.

### 5. MQTT enforcement

- Use the selected broker hostname and actual TLS port for TLSA; plain MQTT
  cannot have a DANE-verified TLS connection.
- Integrate with libmosquitto's OpenSSL verification for the same connection,
  before MQTT CONNECT credentials or subscriptions are sent. A separate
  certificate probe is insufficient.
- Verify the installed libmosquitto/OpenSSL callback API and ownership on both
  platforms. DNS lookup must finish before the synchronous verification hook.
- Reconnects obtain fresh, correctly scoped validation data; disconnect and
  configuration changes cancel pending work. Do not reuse an old SSL context's
  accepted certificate decision for a new peer.
- Check evidence expiry before accepting the TLS peer, including when a slow
  proxy handshake outlives the DNS response's TTL. No blocking DNS query inside
  a certificate-verification callback.

### 6. UI, persistence and localization

- Add per-account and per-broker controls only when enforcement is connected.
  Do not ship a switch that merely changes a badge or silently does nothing.
- Apply settings atomically; show pending changes and preserve the chosen mode
  across failures/restarts. Existing accounts migrate to off.
- Add DE/EN strings, accessible textual status alongside icons, narrow-window
  layout, keyboard navigation and Unicode/IDNA coverage on Linux and Windows.
- Keep the existing account certificate details useful; link from network
  status to the exact account/broker rather than whichever account is selected.

### 7. Packages and acceptance

- Add required build/runtime dependencies and trust-anchor data consistently to
  DEB, AppImage, Flatpak and Windows portable builds, manual and release paths.
- Linux baseline remains Ubuntu 24.04; no GTK baseline change. MSYS2 provides
  `mingw-w64-x86_64-unbound`; verify the actual frozen VM package/dependencies
  before adding it. No whole-system Windows package upgrade.
- Check all needed DLLs and data files in the portable directory; runtime must
  not depend on an MSYS2 install. Cover Cyrillic/spaced Windows user paths.
- Run deterministic signed-zone/TLS fixture tests first: positive DANE, ordinary
  TLS fallback, broken signatures, authenticated absence, mismatch, expiration,
  alias chains, certificate rollover, both XMPP TLS modes, MQTT and cancellation.
- Test two simultaneous accounts with different policies and routes, including
  the same server domain; break one resolver and verify the other stays usable.
- Assert that no credentials leave before verification and no direct DNS/TCP
  escapes a proxy. Test Tor unavailable/restarting and DNS resolver outages.
- Then a bounded live smoke test on Linux and Windows. Keep live results
  distinct from unit-test coverage. Limit compilation parallelism and keep
  artifacts small; no full container downloads to the user's workstation.

## Completion checklist

- [x] Read current connection, TLS, proxy, MQTT and per-account settings paths.
- [x] Record user control and separate-account requirements.
- [x] Check upstream Monocles and the relevant Monal DNS path.
- [x] Implement initial policy/attempt-ownership contract and focused tests.
      Account settings snapshots and connection-manager integration are now present.
- [x] Prove validator, trust anchors and transport on Linux and Windows in fixtures.
      Full application/route acceptance remains a separate item below.
- [x] Enforce XMPP DANE before authentication (direct TLS and STARTTLS fixtures).
- [ ] Prove proxy privacy and cancellation.
- [x] Enforce MQTT DANE before CONNECT (native libmosquitto/TLS fixtures).
- [x] Implement per-account/per-broker UI, persistence and DE/EN text.
      Live UI acceptance and complete broker configuration/lifecycle integration
      fixtures remain outstanding; see the evidence below.
- [ ] Update all packaging paths and validate portable Windows output.
- [ ] Complete negative tests and bounded live acceptance; document remaining
      unsupported cases honestly before describing the feature as finished.

## Initial implementation evidence

`xmpp-vala/src/core/dns_security_policy.vala` defines mode parsing, discovery
and endpoint decisions, and a cancellable capability for exactly one connection
attempt. It does not resolve DNS, verify a certificate or alter existing
connections. Unknown persisted mode values produce an error instead of silently
disabling verification.

The eight test cases in `xmpp-vala/tests/dns_security_policy.vala` passed in the
Linux `xmpp-vala-test` binary and in a native MinGW/Vala test executable on the
Windows VM. They cover bogus versus indeterminate results, secure delegation,
missing/unsupported TLSA records, separate attempt ownership and stale results.
This is policy coverage, not proof of end-to-end account or proxy isolation.

Run the integrated suite with:

```sh
./build/xmpp-vala/xmpp-vala-test -p /DnsSecurityPolicy
```

In MSYS2, prevent conversion of the GLib test-path argument:

```sh
MSYS2_ARG_CONV_EXCL='*' ./build/xmpp-vala/xmpp-vala-test.exe -p /DnsSecurityPolicy
```

A temporary Linux `libunbound` 1.19.2 probe, using the existing local resolver and
the installed root DS anchors, returned `SECURE` for `www.nic.cz` and `BOGUS`
for `dnssec-failed.org`. The probe used a ten-second deadline. The development
header was extracted into an ignored local directory; no system package or DNS
setting was changed. This checks the candidate library on this host only. The
Windows VM's installed application environment was not changed. Native component
tests now use temporarily extracted MSYS2 Unbound/ldns packages; live account/TLS
integration is still pending.

## Resolver and certificate component evidence

The new `dns-security/` component is built with `-Ddnssec=enabled`. This build
option defaults to disabled for generic builds. The documented production
build profiles enable it explicitly. Individual accounts/brokers still default
to off; opting in activates the connection checks.

- 13 native resolver cases pass on Linux (Unbound 1.19.2) and Windows (Unbound
  1.24.2): actual signed answers/absence, broken signatures, forged AD and alias
  chains, timeouts, SERVFAIL, cancellation, IPv6 forwarder configuration and
  isolated caches with different trust anchors. The latter proves separate
  resolver contexts, not application account integration.
- Eight native certificate cases cover selectors, full values and hashes,
  digest agility, rollover, PKIX-EE requirements, a full DANE-TA absent from the
  peer chain, unrelated appended CA rejection, evidence/certificate expiry and
  unsupported records. These use generated X.509 chains and OpenSSL verification.
- A real local HTTPS/SOCKS5 fixture exercises the Vala transport and native
  validator. It observes DNSKEY as well as address/TLSA queries at the proxy.
  Redirects, oversized/wrong-ID responses, an invalid HTTPS identity and a closed
  forwarding route are rejected. This is not a live integrated-Tor test.
- Linux network tracing of this fixture observed only loopback IP destinations
  for outbound connect/send operations, including libunbound's TCP Fast Open
  sendmsg operations. No outbound port 53 or public DNS destination was observed.
- The native resolver suite also passes AddressSanitizer/UndefinedBehaviorSanitizer
  with leak checking disabled. Native C builds use `-Wall -Wextra -Werror`;
  generated Vala C uses the project's existing qualifier-warning settings.

The Windows native resolver and TLS tests run from directories containing
Cyrillic characters and spaces. The initially observed CA-loader problem is
fixed in the private GIO module described below. The system MSYS2 installation
and the user's running application were not changed.

## Primary references

- [RFC 4035: DNSSEC validation](https://www.rfc-editor.org/rfc/rfc4035.html)
- [RFC 6698: DANE TLSA](https://www.rfc-editor.org/rfc/rfc6698.html)
- [RFC 7671: DANE updates](https://www.rfc-editor.org/rfc/rfc7671.html)
- [RFC 7673: TLSA with SRV](https://www.rfc-editor.org/rfc/rfc7673.html)
- [RFC 7590: XMPP TLS](https://www.rfc-editor.org/rfc/rfc7590.html)
- [RFC 7712: XMPP domain-name associations](https://www.rfc-editor.org/rfc/rfc7712.html)
- [libunbound API](https://www.nlnetlabs.nl/documentation/unbound/libunbound/)
- [MSYS2 Unbound package](https://packages.msys2.org/packages/mingw-w64-x86_64-unbound)
- [libmosquitto API](https://mosquitto.org/api/files/mosquitto-h.html)
- [Monocles original source](https://codeberg.org/monocles/monocles_chat)
- [Monal DNS source at reviewed revision](https://github.com/monal-im/Monal/blob/26e8d04326119af400f2fafb2a412c6c28d0f62b/Monal/Classes/MLDNSLookup.m)

## 2026-10-22 integration evidence and remaining acceptance

- Linux: full canonical `DINOX_BUILD_JOBS=2 ./scripts/build.sh --strict` and the
  final incremental pass completed with zero warnings. The application is at
  `build/main/dinox`. Disabled-feature XMPP Vala generation also passes.
- All six registered native/integration fixture suites pass on Linux: resolver,
  DANE certificates, HTTPS/SOCKS5, XMPP TLS, XMPP discovery and MQTT TLS.
- XMPP: 26 real direct-TLS/STARTTLS cases pass on Linux and native Windows;
  14 negative cases emit no encrypted stream header or SASL packet. Matching
  DANE, valid-CA/TLSA mismatch, PKIX-EE, untrusted DANE-EE, wrong names, expiry,
  cancellation and ordinary TLS/pin compatibility are covered.
- Discovery: signed SRV/target/address/TLSA, authenticated absence, rejected
  bogus delegation, explicit no-service, SRV/address aliases and IDNA/special
  names pass. Actual ports are checked. Per RFC 7673 section 3.2, either secure
  address family permits TLSA lookup; bogus/failed answers remain fatal for that
  target even when the other family is secure.
- Seven account-lifecycle tests pass, including a two-account temporary database:
  policies/resolvers remain separate after reopen, only the changed account
  reconnects, and invalid input preserves saved settings.
- MQTT: all 11 native cases pass with Linux Mosquitto 2.0.18, Windows 2.0.22 and
  the actual library extracted from the pinned Forgejo image (package metadata:
  Mosquitto 2.1.2). Three accepted connections send CONNECT; eight rejected
  connections send none. Two cases cross expiry/cancellation after certificate
  verification by delaying the server Finished. The original broker SNI is
  checked. Windows loads the CA from a Cyrillic/spaced filename.
  The package's `mosquitto_lib_version()` reports 2.1.0, whereas its pkg-config
  and pinned source metadata report 2.1.2; the test uses the actual image binary,
  not an assumption based solely on either version string.
- The MQTT utility/config suite passes 113 tests, including Unicode resolver
  persistence, independent copies and malformed-JSON rejection. This is not
  yet a live application broker/account reconnect test.
- XMPP settings and the actual MQTT settings widget were checked at 420 px;
  MQTT was rendered in English and German with a Cyrillic URL. No GTK layout
  warnings occurred. These are isolated widget tests, not live-profile changes.
- A no-authentication probe through `Xmpp.establish_stream` to `dinox.im`
  connects in `when-available` mode with ordinary TLS. Required mode rejects
  the endpoint for lack of usable authenticated TLSA evidence. No SASL module,
  password, stored account or settings change was involved.
- The private glib-networking 2.80.1 GIO patch reads Windows CA filenames through
  GLib and imports the same PEM in memory. All 26 native XMPP cases pass with
  both the module and CA under Cyrillic paths. Its build helper also succeeds
  with a Cyrillic/spaced vendor directory, then validates/reuses the cache.
  The build/preparation/copy scripts and exact-source license inventory now
  include it. No installed MSYS2 module was overwritten.
- Static packaging validation passes: 68 Flatpak manifest checks, 39 package
  matrix checks, Flatpak layout/manifest self-tests, DEB build-flow regression
  (including a missing-Unbound rejection), and Windows packaging/license tests.
  A test explicitly rejects an unpatched replacement GIO module.

### Package rollout still required

- DEB: `libunbound8 (>= 1.19)` dependency plus an ELF link check.
- AppImage: bundle libunbound, its dependency closure and distribution notices;
  the existing static closure/provenance gates apply.
- Flatpak: build pinned Unbound 1.24.2 as a client library only; stage its
  original license files. Source archive SHA-256 was verified locally.
- Windows: install the documented MSYS2 Unbound prerequisite; package its DLL
  closure and the private GIO module. Full portable-app acceptance is still due.
- All four profiles use `-Ddnssec=enabled`; individual policies remain off.
- The current Forgejo image was checked on the server: it has runtime
  `libunbound8 1.19.2-1ubuntu3.9`, but lacks the development package. The Dockerfile
  now adds `libunbound-dev` and both image checks require it. Publishing these
  inputs to master triggers the existing package-builder-image workflow; that
  workflow must finish and update the three pinned image digests before DEB or
  AppImage package jobs use the new code. No stale-image bypass is added.
  Manual and release packages already use the same build scripts in `build.yml`.
- No large image was downloaded to the workstation, no image/package published,
  and no full package build started during this step. Server free space was
  about 21 GiB; workstation SSD free space remained about 5.9 GiB.

## 2026-10-22 live proxy and product-client acceptance

- Initial integration and packaging are committed as `c9992c39` and `2e3e75ec`.
  Forgejo image run 277 started from that source. DEB, AppImage and Flatpak
  acceptance is queued sequentially behind successful image verification and
  replacement of all three digest pins. No release tag or publication is requested.
- A real Tor-controller run exposed a DoH compatibility problem: forcing
  HTTP/1.1 rejects HTTP/2-only resolvers; libsoup 3.4 also omits HTTP/2 ALPN for
  SOCKS5. The forwarding session now negotiates HTTP/2 and advertises it on the
  end-to-end SOCKS5 TLS stream before the handshake. HTTPS identity/trust and
  redirect checks remain enabled. The separate bridge-fetch workaround stays.
- Both local HTTP/1.1 and HTTP/2-only fixtures pass with fatal GLib warnings.
  DNSKEY/TLSA requests traverse SOCKS5; malformed/oversized responses, redirects,
  wrong HTTPS identities and a closed route are rejected.
- The actual `TorController`, `BridgeClient` and `Xmpp.establish_stream` were
  exercised in isolated data directories, with the bundled Tor/Lyrebird runtime.
  Ordinary Tor and fetched WebTunnel bridges both reached bootstrap 100%.
  Optional verification connected to dinox.im using normal TLS. Required mode
  rejected missing usable authenticated TLSA records. Stopped Tor did not permit
  a direct connection. No account password, SASL module or user profile was used;
  these results do not claim an authenticated account login or positive DANE for
  dinox.im.
- The real `MqttClient` is tested against isolated loopback broker/proxy sockets.
  Invalid policy, required verification for a local target, cleartext with
  verification enabled and missing proxy-resolver configuration send no CONNECT.
  Cancelling pending DNS leaves a second client connected; the cancelled client
  can then connect afresh without a stale security error. Wire counts assert
  exactly the two explicitly unprotected fixture connections.
- Eight DNSSEC/DANE suites pass locally without skips; the final strict Linux
  build has zero warnings. The existing Tor readiness/owned-process suites also
  pass. Native Windows package completion is still pending, including the added
  HTTP/2 and product-client tests. The Windows build documents and requires their
  small MSYS2 Python dependencies, which do not ship in the portable package.

Remaining acceptance: review the completed Windows/package logs, then exercise
authenticated account/UI changes with a deliberately selected test profile.
No live user account settings have been changed.

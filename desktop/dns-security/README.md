# DNSSEC/DANE components

The components now enforce the selected policy on XMPP (direct TLS and STARTTLS)
and MQTT connections, before protocol authentication. Settings are separate for
each account and each MQTT broker; existing connections default to off.
The `dnssec` Meson option still defaults to disabled pending package and portable
Windows acceptance. Enabling the build option exposes opt-in account/broker
settings; it does not enable DANE for any account. Remaining work is tracked in
[the implementation plan](../docs/internal/DNSSEC_DANE_PLAN.md).

## Ownership and trust boundaries

- Create one `DinoDnsResolver` per account, route and connection attempt. Its
  libunbound context and cache are private. Never share one merely because two
  accounts have the same domain. Close it when the attempt is superseded.
- Methods belong to the creating thread and its thread-default main context.
  Validation runs in libunbound's worker. The GLib source only checks results
  while requests exist. Closing inside an async continuation waits until the
  current libunbound callback returns before deleting its context.
- Forwarders must be explicit numeric addresses. There is no recursive fallback,
  public fallback, unbound configuration import or hosts-file override. System
  DNS configuration is read only on request: `/etc/resolv.conf` on Linux, native
  `GetAdaptersAddresses` on Windows, including IPv6 interface scopes. This reads
  forwarders; it does not reproduce OS split-DNS routing policies.
- For HTTPS forwarding, construct `DohForwarder` with an explicit HTTPS endpoint
  and route. Pass only its loopback address to the validator, with TCP-only
  enabled. A SOCKS5 proxy must have a numeric endpoint to avoid local bootstrap
  DNS. DNSKEY/DS queries use the same route. Redirects, invalid HTTPS certificates,
  oversized responses and invalid transaction IDs are rejected.
- Close both resolver and forwarder after use and on route changes. The
  forwarder has an explicit lifetime; do not leave it listening after the attempt.
- Transport errors are errors, never INSECURE answers. BOGUS results expose no
  RDATA. Account owners must also discard late results after cancellation even
  if the worker completed immediately before the account changed.
- The certificate verifier requires an authenticated endpoint's SECURE TLSA
  record set. It does not establish DNS provenance itself. Pass the earliest
  expiry of authenticated delegation/address/TLSA evidence and the certificate
  chain from the actual TLS connection, never from an earlier probe.
- Supported usages: DANE-EE (3), DANE-TA (2), PKIX-EE (1); selectors certificate
  and SPKI; full data, SHA-256 and SHA-512. PKIX-TA (0) remains unsupported.
  PKIX-EE requires successful normal PKIX verification, not a user certificate
  exception. DANE-TA verifies the chain and reference identity; a matching extra
  CA in an unrelated chain is insufficient. A full `2 0 0` anchor may be absent
  from the handshake. DANE-EE follows RFC 7671's key-binding semantics.

## Root trust anchors

`dino_dns_root_trust_anchors()` embeds IANA root DS records 20326 and 38696,
checked against [IANA's HTTPS XML](https://data.iana.org/root-anchors/root-anchors.xml)
on 2026-10-21. Neither has a `validUntil`; retired key 19036 is excluded.
Loading these anchors does not depend on a user's path encoding or portable
data-file lookup.

Updates require review of IANA's anchor/rollover information and a normal reviewed
source/package update. Never replace anchors using unauthenticated DNS or a
download on the login path. Automatic RFC 5011 maintenance is not implemented.

## Tests

Build dependencies: GLib/GIO, libunbound >= 1.19, OpenSSL >= 3.0, libsoup >= 3.4
and Vala. Python `dnspython`, `cryptography` and `h2` run the local signed-DNS and
HTTP/1.1 and HTTP/2-only HTTPS/SOCKS5 fixtures. Their deliberately public test keys and temporary
certificates are not production credentials. No real accounts/public DNS are used.

```sh
meson setup --reconfigure build -Ddnssec=enabled
meson compile -C build -j 2 dns-resolver-test dns-doh-test dns-dane-test \
  xmpp-dane-test dns-discovery-test dns-mqtt-tls-test
meson test -C build --no-rebuild --print-errorlogs \
  'DNSSEC signed-zone resolver' \
  'DNSSEC HTTPS SOCKS5 transport' \
  'DNSSEC HTTP2 SOCKS5 transport' \
  'DANE certificate verification' \
  'XMPP DANE pre-authentication gate' \
  'DNSSEC XMPP service discovery' \
  'MQTT DANE before CONNECT'
```

The root build's existing dependency pins still apply, including the pinned
libomemo-c pkg-config environment. Missing Python dependencies mean fixture tests
are not registered; Meson reports this explicitly. That is not a passing test.

The native C and Vala tests also run on Windows. Fixture servers can run on
another host with TCP ports forwarded to the Windows test process; validation,
TLS and SOCKS5 still run in the native EXE. Do not package test executables,
Python packages, fixture keys or logs with DinoX. The Windows preparation helper supplies a pinned GIO patch for CA files in
Cyrillic paths; native TLS fixtures cover this path. Full portable-app acceptance
remains tracked in the plan.

## Connection integration

`xmpp-vala/src/core/dns_security_connection.vala` checks SRV delegation, address
answers, the target's real port and TLSA. The actual TLS socket is checked before
SASL, stream resumption or encrypted XMPP headers. A DANE failure never reaches
the certificate-pin dialog. The connection manager persists mode/resolver
atomically per account and invalidates attempts on account/route changes.

`plugins/mqtt/src/mqtt_client.vala` obtains fresh broker evidence for each
connection/reconnection. `openssl-context.c` installs a certificate verifier on
libmosquitto's actual SSL context; the original broker name remains the SNI and
PKIX reference even when the socket uses a validated numeric address. Contexts
are private per attempt, have no session reuse and check expiry/cancellation at
certificate verification and completion of the handshake. CA PEM loading uses
GLib's UTF-8-aware file reader, including on Windows.

The selected policy applies to public domains. Required mode rejects local/IP/
onion targets; opportunistic mode preserves ordinary TLS without public TLSA
queries for those targets. Per-account MQTT keeps its existing local-broker
proxy bypass. Standalone MQTT retains its own existing direct route; it does not
inherit an arbitrary XMPP account's settings or proxy.

The test servers count actual XMPP authentication and MQTT CONNECT packets.
Negative tests are not satisfied merely by a client-side error. The MQTT delayed
Finished tests specifically cross the DNS TTL or cancel *after* the peer
certificate was checked, and assert that no CONNECT is sent.

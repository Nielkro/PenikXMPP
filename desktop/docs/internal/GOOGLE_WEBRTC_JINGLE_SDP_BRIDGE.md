# Google/libwebrtc Jingle/SDP Bridge

> Scope: Slice 27 XEP-0294 congestion-control signaling
> Runtime behavior: RTP header extensions are preserved for live libwebrtc calls

## 1. Purpose

Google/libwebrtc consumes and produces SDP. DinoX currently represents call
signaling as Jingle XML objects from XEP-0166, XEP-0167 and XEP-0176.

The migration needs an explicit bridge between those two shapes. This must be a
tested boundary, not string construction hidden inside call-session code.

The initial bridge lives in:

- `xmpp-vala/src/module/xep/0167_jingle_rtp/sdp_bridge.vala`
- `xmpp-vala/tests/audit_jingle_sdp_bridge.vala`

## 2. Current mapping

This bridge maps stable Jingle attributes to SDP session and media lines and
parses the same SDP shape back into Jingle-compatible data objects:

- session header lines with `v=0`, `o=`, `s=` and `t=0 0`
- BUNDLE groups with `a=group:BUNDLE`
- media sections with `m=`
- media IDs with `a=mid`
- ICE credentials with `a=ice-ufrag` and `a=ice-pwd`
- RTCP mux with `a=rtcp-mux`
- RTP payload type to `a=rtpmap`
- RTP payload parameters to deterministic `a=fmtp`
- RTP feedback to `a=rtcp-fb`
- XEP-0294 RTP header extensions to `a=extmap`, including direction and
  extension parameters
- XEP-0294 `extmap-allow-mixed`, including expansion of a session-level SDP
  attribute to every Jingle RTP description
- ICE-UDP candidates to `a=candidate`
- DTLS fingerprint to `a=fingerprint`
- DTLS setup role to `a=setup`
- XEP-0167 `description` nodes to/from `SdpMediaSection`
- XEP-0176 `transport` nodes to/from `SdpMediaSection`
- content-name plus description/transport node pairs to/from `SdpSession`
- explicit `SdpBundlePolicy` application for `NONE` and
  `ALL_MEDIA_SECTIONS`

The content-name is used as the SDP media ID (`a=mid`) when collecting Jingle
node pairs. The bridge does not invent a BUNDLE policy from plain Jingle
contents; BUNDLE remains explicit through `SdpSession.bundle_mids`.
`SdpBundlePolicy.ALL_MEDIA_SECTIONS` sets the BUNDLE group from every media
section MID and rejects missing or duplicate MIDs. `SdpBundlePolicy.NONE`
clears the BUNDLE group and serializes no `a=group:BUNDLE` line.

The test suite now includes a libwebrtc-style BUNDLE fixture with common
session/media attributes. `a=extmap` and `a=extmap-allow-mixed` are first-class
XEP-0294 bridge data. Other attributes that DinoX does not need to preserve in
Jingle yet include `a=msid-semantic`, `c=`, `a=rtcp`, `a=ice-options`, `a=msid`,
`a=rtcp-rsize`, `a=ssrc` and `a=end-of-candidates`.

The test suite also includes manually-built Jingle node-pair fixtures:

- a DinoX-style audio/video fixture with content names `audio` and `video`,
  Opus, VP8, rtcp-mux, DTLS fingerprints and already-present ICE candidates;
- a mobile/trickle-style fixture with numeric content names `0` and `1`, Opus,
  VP8 plus H264 as an alternative video payload, DTLS `active` setup and no
  initial ICE candidates.

These fixtures are compatibility-shape tests, not captured live stanzas from a
specific client version.

The helper rejects newline characters in generated SDP fields. That prevents
remote stanza values from becoming injected additional SDP attributes.

## 3. Non-goals for this slice

- no conversion from live XEP-0166 `Content` instances into `SdpSession` yet
- no claim that ignored libwebrtc-only media attributes are semantically mapped
  into Jingle yet
- no MSID lines
- no codec preference change away from VP8
- no libwebrtc session objects
- no production `VideoCallPlugin` replacement

## 4. Validation

The focused test group is:

```bash
build/xmpp-vala/xmpp-vala-test -p /JingleSdpBridgeAudit
```

It covers Opus, VP8 RTCP feedback, XEP-0294 header-extension direction,
parameters and mixed-mode mapping, ICE candidates, DTLS fingerprint/setup,
media-section fixtures, session-level audio/video BUNDLE fixtures, explicit
BUNDLE policy application and invalid-MID rejection, Jingle description/
transport node roundtrips, content-node-pair session roundtrips,
libwebrtc-style SDP fixture parsing, DinoX-style and mobile/trickle-style Jingle
fixtures, reverse parsing and invalid-value/newline-injection rejection.

## 5. Next bridge work

The next safe step is to decide which tolerated SDP-only attributes must become
first-class bridge data before wiring live call state:

- decide which SDP-only attributes must become first-class bridge data instead
  of tolerated/ignored input
- map live `Jingle.Content` instances only after fixture coverage is strong
- keep this parser independent from the call UI and runtime plugin switch

# MUJI interoperability

## Protocol and encryption boundaries

DinoX uses Google/libwebrtc for direct calls, calls in private non-anonymous
rooms, and direct calls extended by inviting another participant. Its enabled
OMEMO call verification uses legacy OMEMO v1. PQ is not enabled in DinoX.
Monocles retains separate legacy and PQ paths; mixed calls use legacy OMEMO.

Pair initiation follows the [Monocles MUJI profile proposal](https://codeberg.org/monocles/monocles_chat/src/commit/c24e8b715477b3ec6ae71b6ad179f6db994d9fa2/docs/xep-0272-muji-monocles.xml):
the participant with the greater nick in UTF-16 code-unit order initiates.
Only the resource part is compared, without locale sorting or case folding.
The initial and late-participant paths use the same rule. An adopted direct
call remains owned by its original session.

The former joiner-first rule and the mutual-preparation timeout exception are
removed. A participant still waits for its own preparation presence, checks
the current room/account generation and selects the common media map. It no
longer waits for another participant to finish preparation before advertising
its own READY state.

After publishing READY, only new outgoing peer sessions wait for the room to
reflect that presence. The wait uses the current call generation (or the exact
stanza ID when the room omits the generation). After five seconds without an
echo, the current live room call may initiate, as specified by the profile.
Incoming expectations and group publication remain available during the wait;
an adopted direct session continues unchanged. Cancellation, stream detach or
own unavailability revoke the wait, and a stale timer cannot release a successor.
Both initial and later outgoing peers use this gate and recheck their ownership
before creating a native session.

This changes connection ownership, not peer authentication: the current room's
disclosed full JID, device identity, trust and encrypted DTLS fingerprint remain
the relevant security boundaries. A nick does not substitute for an OMEMO key.
Direct 1:1 JMI signaling remains separate from MUJI peer creation.

The Monocles document is a proposal, not an approved replacement of the
[published XEP-0272](https://xmpp.org/extensions/xep-0272.html), which remains
Experimental version 0.2.0. This note does not claim complete implementation of
every extension in that proposal.

## Validation for the October 21 change

- `DINOX_BUILD_JOBS=2 ./scripts/build.sh --strict`: Linux build, zero warnings.
- All 960 XMPP tests pass, including nick election for all six three-participant join orders,
  Cyrillic, supplementary Unicode characters and equal/prefix nicks.
- READY tests cover rewritten/idless stanza IDs, stale/wrong-room echoes,
  incoming peer admission during the wait, immediate cancellation and the
  five-second fallback with a replaced call owner.
- All 91 targeted `CallStateAudit`, `CallInviteIngressAudit` and `JmiLifecycleAudit`
  tests pass, retaining direct-call, invitation and cancellation coverage.
- All four Google/libwebrtc engine, wire, JMI and plugin-capability smoke tests
  pass, retaining the native call-boundary checks.

These are code/runtime checks, not a new Android interoperability result.
Historical live results are recorded in the [Monocles result table](https://git.dinox.im/dinoxim/monocles-chat/src/branch/master/docs/interop-status-2026-10-18.md).
They must not be relabelled as results of a newer binary. New media acceptance
must bind the tested builds, participant identities and actual received media.
The [existing interop sources](../../tests/interop/README.md) include the mixed
three-party audio/video cases; Android-only PQ cases belong to the Monocles fork.

The same Vala protocol logic builds on Linux and Windows. Windows runtime
acceptance is separate; no native WebRTC ABI or dependency pin changes here.

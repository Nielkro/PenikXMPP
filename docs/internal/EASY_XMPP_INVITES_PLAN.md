# Easy XMPP Invites Implementation Plan

## Goal

Add Easy XMPP Invitation support to DinoX without weakening the existing
CloudBot registration and abuse-control boundaries.

The feature is split into three surfaces:

- DinoX client: open, validate, explain and act on `xmpp:` invitation URIs.
- ejabberd: create and validate invite tokens through `mod_invites`.
- CloudBot: provide policy, admin UI, audit logging and optional public landing
  page integration for `dinox.im` invites.

Bot provisioning remains CloudBot-specific. Easy XMPP Invitation links may invite
humans to an account, contact or room; they must not replace hosted bot account
creation, owner verification, bot management tokens, rollout, rollback or audit.

## Current Evidence

- ejabberd 26.04 documents `mod_invites` for out-of-band links implementing
  XEP-0379, XEP-0401 and XEP-0445.
- `mod_invites` can create XMPP URIs via ad-hoc commands or API commands such
  as `generate_invite` and `generate_invite_with_username`.
- The module can use a built-in landing page, a template URL, or an external
  landing page such as Easy XMPP Invitation.
- ejabberd `master` after 26.04 continues to change `mod_invites`: the current
  commit list contains fixes and additions for reset tokens, uppercase inviter
  handling, public invite creation pages, WebAdmin integration, CSRF token
  generation and register-form handling. Treat ejabberd's own invite web UI as
  moving upstream code until the next release is tested.
- The DinoX server currently runs ejabberd 26.4.0.
- The DinoX server uses `mod_invites` with CloudBot-generated landing pages and
  `mod_register.allow_modules: [mod_invites]` for invite-only registration.
- The CloudBot ejabberd API account is allowed to call `check_account`,
  `register`, `unregister`, `generate_invite` and
  `generate_invite_with_username`.
- DinoX already registers `x-scheme-handler/xmpp` and handles simple `xmpp:`
  URIs for message, join and sticker import flows.

## Security Model

- Invite links are bearer secrets when they contain `preauth`; never log full
  invite URIs in DinoX, CloudBot or server automation.
- UI must show the target domain/JID/room and action before mutating state.
- Account creation by invite must not reopen public in-band registration.
- Public registration remains CloudBot-gated: policy switches, rate limits,
  persistent abuse counters, Turnstile where required, login verification and
  audit logging stay in force.
- CloudBot may be allowed to create invite tokens only through a narrowly scoped
  ejabberd API permission.
- Token lifetime, maximum invite count and invite scope must be explicit server
  configuration, not client defaults.
- Do not give normal DinoX clients ejabberd admin/API credentials. If end-user
  invite creation is supported later, route it through a scoped CloudBot policy
  endpoint or through XEP-0401 only when the server explicitly grants that
  right.
- Account invites, contact invites and MUC invites are separate permission
  surfaces. Do not mix their UI or authorization rules.
- Landing pages must avoid token leakage through logs, analytics, referrer
  headers, browser history beyond the URL itself, copied debug output and audit
  records.

## Architecture Target

The invite system has three hard boundaries:

1. **CloudBot/server is the invite authority.** It creates account invites,
   enforces policy, records redacted audit evidence, exposes operator UI and
   serves the branded landing page.
2. **DinoX is the invite consumer.** It opens `xmpp:` invite links, performs the
   XMPP preauth/registration flow, shows precise errors and connects the created
   account. It must not own server policy.
3. **The landing page is the public onboarding surface.** Users should share
   `https://` invite links, not raw `xmpp:` URIs. The page should offer DinoX
   downloads, an "Open in DinoX" button, copy actions and a QR code.

Future "invite someone from DinoX" support should call a policy-controlled
CloudBot endpoint or XEP-0401 command and then show/copy/share the landing URL.
It should not bypass CloudBot audit or ejabberd abuse limits.

## Phase 1: DinoX URI Foundation

Status: implemented in `libdino/src/util/xmpp_uri.vala` and covered by main
tests.

1. Add a pure parser/classifier for `xmpp:` URIs:
   - `message` or empty query: contact/chat invite.
   - `join`: MUC invite.
   - `register`: account invite.
   - preserve unknown query types as unknown instead of mis-handling them.
   - parse semicolon options including `preauth`.
2. Add tests for:
   - contact invite.
   - MUC invite.
   - account registration invite with `preauth`.
   - percent-decoded JIDs/options.
   - malformed or non-`xmpp:` inputs.
3. Integrate the parser into the locked and unlocked URI handling paths after
   tests pass.

## Phase 2: DinoX Accept Flows

Status: partially implemented.

Done:

- Pre-authorized contact and MUC links show a confirmation dialog without
  displaying the token.
- Account-registration invites open the account creation dialog directly.
- XEP-0445 preauth is used before fetching and submitting the registration
  form.
- Reserved usernames from `xmpp:username@example.org?register;preauth=...` are
  prefilled and enforced.
- The account invite dialog no longer flashes the generic server selector and
  no longer reopens after successful `Finish`.

Remaining:

1. Add/finish an invite confirmation dialog for non-account invite types:
   - action type.
   - server/domain.
   - target JID or room.
   - whether the invite contains a preauth token.
2. Wire contact invites to existing add-chat/roster flows.
3. Wire MUC invites to the existing join MUC flow.
4. Add user-visible errors for unsupported invite types rather than silently
   doing nothing.
5. Implement real roster subscription handling for pre-authenticated contact
   invites instead of only opening the chat/add-contact surface.
6. Add runtime smoke tests for locked and unlocked URI delivery.
7. Add a dedicated local test script for account invite URI handling with a
   fake/preconfigured invite or a staging token, so dialog regressions are not
   found manually only.

## Phase 3: ejabberd Server Enablement

Status: configured enough for current DinoX account-invite tests, but not final.

1. Add a staging `mod_invites` configuration:
   - `db_type: sql`.
   - `access_create_account` restricted to admins or a dedicated CloudBot ACL.
   - finite `token_expire_seconds`.
   - conservative `max_invites`.
   - landing page set deliberately, not left accidental.
2. Extend `api_permissions` only for the exact invite command(s) CloudBot needs.
3. Verify with `ejabberdctl` and HTTP API using redacted logs.
4. Do not use `mod_register: access: none` for invite registration; keep
   `mod_register.allow_modules: [mod_invites]` so valid preauth registration can
   submit after the token check.
5. Track ejabberd master until the next release because post-26.04 commits touch
   invite creation pages, WebAdmin, reset-token generation, CSRF handling and
   registration-form behavior.
6. Before relying on a new ejabberd release, test:
   - `generate_invite`
   - `generate_invite_with_username`
   - preauth feature advertisement
   - username conflict
   - expired/used token
   - rate-limit response
   - server logs for token leakage

## Phase 4: CloudBot Invite Administration

Status: basic account invite creation exists in the CloudBot admin UI and API.

1. Add CloudBot database records for issued invites:
   - invite id/token hash or redacted token fingerprint.
   - issuer/admin.
   - invite type.
   - target domain/JID/room.
   - expiry.
   - status.
   - audit trail.
2. Add server-side invite creation through the limited ejabberd API account.
3. Add admin UI to create/list/revoke/expire invites.
4. Add rate limits and abuse counters for public invite request flows if they
   are ever exposed beyond admins.
5. Keep bot registration and bot account lifecycle separate.

Remaining CloudBot work:

- Remove duplicate/confusing create-account vs invite surfaces. The operator
  flow should have one account-invite page with clear segmentation.
- Show created invite material only in the invite page, only once, with copy
  actions.
- Add invite list/status when server-side state is available or clearly mark
  stored rows as redacted audit records only.
- Add revocation/expiry support only if ejabberd exposes a reliable command or
  CloudBot can enforce it before handing out links.
- Keep external bot-owner accounts separate from real local XMPP accounts in
  account views.

## Phase 5: Landing Page Decision

Status: CloudBot serves a minimal `/invites/<token>` page. It is not final UX.

Options:

- Use ejabberd built-in landing page initially for server-only validation.
- Host a branded fork/static deployment of Easy XMPP Invitation.
- Serve a DinoX/CloudBot landing page under a dedicated host such as
  `invite.dinox.im`.

Preferred path:

1. Keep CloudBot as the public DinoX landing page owner, not ejabberd's moving
   built-in web UI.
2. Put the public URL on a clean HTTPS endpoint without ejabberd ports, e.g.
   `https://invite.dinox.im/<token>` or `https://cloud.dinox.im/invites/<token>`.
3. The page must include:
   - primary "Open in DinoX" action.
   - copy invite link / copy XMPP URI.
   - QR code for the landing URL.
   - DinoX download choices for Windows, Linux AppImage, Deb and Flatpak.
   - a small "other compatible XMPP clients" section without making unsupported
     clients look first-class.
   - no third-party JS/CSS except Turnstile where explicitly required.
4. Keep the page stateless for invite fragments where possible, and never
   persist full `xmpp:` URIs with `preauth`.
5. Add security headers: CSP, Referrer-Policy, X-Content-Type-Options and
   noindex unless public indexing is explicitly wanted.

## Phase 6: DinoX Invite Creation

After server and CloudBot admin controls are stable:

1. Define which user roles may create which invite type:
   - account invite: operator/admin first; end-user later only through policy.
   - contact invite: normal user if server supports roster preauth.
   - MUC invite: room owner/admin/member depending on room/server rules.
2. Discover invite support via service discovery/ad-hoc availability or a
   DinoX/CloudBot capability endpoint.
3. Add "Create invitation" actions where they belong:
   - contact details for contact invites.
   - room details for MUC invites.
   - account/admin settings only for account invites.
4. Use server-generated invites when available.
5. Transform raw `xmpp:` URIs to the configured landing page URL.
6. Provide copy/share UI and QR code only after token redaction rules are in
   place.
7. Do not implement client-side invite generation with local random tokens.
   Tokens must come from the server authority.

## Immediate Roadmap

1. Finalize CloudBot landing page UX and tests.
2. Verify live ejabberd config against this document and record the exact
   deployed shape.
3. Add CloudBot admin invite copy/QR UX and remove duplicate operator surfaces.
4. Add DinoX runtime smoke test for account-invite links.
5. Add contact-invite and MUC-invite support only after account-invite and
   landing page are stable.
6. Re-check ejabberd release notes before upgrading beyond 26.04; post-26.04
   invite commits are relevant to this feature.

## Validation Checklist

- `meson test -C build "Tests for main" --print-errorlogs`
- `meson compile -C build main/dinox`
- CloudBot API tests for invite admin endpoints.
- Server staging test:
  - generated contact invite opens in DinoX.
  - generated MUC invite opens in DinoX.
  - generated account invite creates exactly one account, expires correctly and
    cannot be reused if configured as one-time.
- Logs checked for full-token leakage.

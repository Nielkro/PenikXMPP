# MUC Invite Test Plan

This plan covers DinoX MUC invitation behavior for inbound external invites, inbound DinoX-to-DinoX invites, outbound invites from DinoX MUC UI, and regression checks around pending invite state, notifications, bookmarks, and conversation creation.

## Test accounts

Runtime test JIDs:

- `testuser@dinox.im`
- `testuser1@dinox.im`
- `testuser2@dinox.im`

Credentials are intentionally not stored here. Pass test passwords only through the active terminal/session, an ephemeral environment variable, or manual UI entry. Never write passwords to repo files, memory, logs, screenshots, command history snippets, or committed scripts.

## Global test rules

- Use a fresh room JID per scenario, for example `invite-test-YYYYMMDD-HHMM-<case>@conference.dinox.im`.
- Before each scenario, verify the receiver is not already joined to the room and has no bookmark/autojoin entry for that room.
- Capture the sender account, receiver account, room JID, invite type, expected stanza family, and final UI state.
- Keep all helper scripts and raw logs under `/tmp` if needed.
- Do not stage screenshots, helper scripts, raw XML logs, or credential-bearing output.
- After code changes, run `meson compile -C build main/dinox` before runtime tests.

## Required instrumentation

For each runtime scenario, record these facts manually or from targeted logs:

- `invite_received`: whether DinoX received XEP-0045 mediated or XEP-0249 direct invite.
- `pending_invite`: whether a pending invite object was created with the expected account and room.
- `conversation_created_before_accept`: must be `false` after the new pending-invite implementation.
- `bookmark_created_before_accept`: must be `false`.
- `autojoin_enabled_before_accept`: must be `false`.
- `password_visible_in_notification`: must be `false`.
- `reason_visible_in_dialog`: expected `true` when reason is present.
- `accept_result`: joined, failed with visible error, or cancelled.
- `decline_result`: dismissed locally, and for mediated invites, decline stanza sent.

## Baseline before code changes

Purpose: reproduce the current broken/confusing behavior before implementing slices.

Actors:

- Sender: `testuser@dinox.im`
- Receiver: `testuser1@dinox.im`
- Observer/optional second receiver: `testuser2@dinox.im`

Steps:

1. Start DinoX with sender and receiver accounts available.
2. Create or join a fresh MUC as sender.
3. From DinoX MUC UI, invite receiver.
4. Observe receiver DinoX.
5. Record whether receiver gets a notification, a visible pending invite, a join dialog, or is immediately shown as joined/in the MUC.
6. Check whether a GROUPCHAT conversation row appears before user acceptance.
7. Check whether a bookmark/autojoin state appears before user acceptance.

Expected current baseline:

- The old implementation may create a conversation row before explicit acceptance.
- The old implementation may lose reason/password metadata.
- `deny-invite` may not work.
- If the receiver appears immediately joined, capture exact steps and account/room state.

This baseline is not a pass/fail gate. It documents the regression target.

## Scenario A: inbound XEP-0045 mediated invite

Purpose: external or DinoX sender invites receiver through the room.

Actors:

- Sender: `testuser@dinox.im`
- Receiver: `testuser1@dinox.im`

Setup:

1. Sender is joined to a fresh MUC.
2. Receiver is online in DinoX but not joined to the room.
3. Receiver has no bookmark/autojoin entry for the room.

Steps:

1. Send a mediated invite from sender to receiver.
2. Verify receiver gets a `PendingMucInvite` with source `MEDIATED_XEP0045`.
3. Verify no GROUPCHAT conversation is created before accept.
4. Verify no bookmark/autojoin is created before accept.
5. Verify OS notification, if enabled, points to `invite_id`, not `conversation_id`.
6. Open the invite dialog.
7. Verify dialog shows target account, room JID, inviter, and reason if present.
8. Accept the invite.
9. Verify receiver joins the room.
10. Verify conversation is created only after successful join.
11. Verify bookmark/autojoin policy follows the selected user option or `NO_BOOKMARK_CHANGE` default.

Pass criteria:

- Pending invite appears.
- No pre-accept conversation/bookmark/autojoin.
- Accept joins the correct account into the correct room.
- Metadata is not lost.

## Scenario B: inbound XEP-0249 direct invite

Purpose: direct invite from another client or helper sender to DinoX receiver.

Actors:

- Sender: `testuser@dinox.im`
- Receiver: `testuser1@dinox.im`

Setup:

1. Sender knows the room JID.
2. Receiver is online in DinoX and not joined.
3. Use an external helper client or temporary script to send `<x xmlns='jabber:x:conference'>`.

Steps:

1. Send direct invite with room JID and reason.
2. Verify receiver gets `PendingMucInvite` with source `DIRECT_XEP0249`.
3. Verify reason appears in invite dialog as plain text.
4. Decline the invite.
5. Verify invite is removed locally.
6. Verify no XEP-0045 decline stanza is sent for direct invite.
7. Repeat and accept the invite.
8. Verify successful join.

Pass criteria:

- Direct invite is shown as pending invite.
- Decline is local only.
- Accept joins only after explicit user action.

## Scenario C: password-protected room

Purpose: invite password must survive protocol-to-UI flow without leaking.

Actors:

- Sender: `testuser@dinox.im`
- Receiver: `testuser1@dinox.im`

Setup:

1. Create a password-protected MUC.
2. Sender has permission to invite receiver.
3. Receiver is not joined and does not know the password manually.

Steps:

1. Send invite with password through mediated invite or direct invite.
2. Verify OS notification does not show password.
3. Verify logs do not show password.
4. Open invite dialog.
5. Verify dialog indicates password is available without displaying it in clear text by default.
6. Accept invite.
7. Verify join succeeds without manual password entry.
8. Decline another invite and verify runtime password is cleared with pending state.

Pass criteria:

- Password is used for join.
- Password is not exposed in notification, action variant, logs, screenshots, or persistent storage.

## Scenario D: notifications disabled

Purpose: OS notifications must not be the only invite surface.

Actors:

- Sender: `testuser@dinox.im`
- Receiver: `testuser1@dinox.im`

Setup:

1. Disable DinoX notifications or OS-level notifications for DinoX.
2. Receiver remains online.

Steps:

1. Send mediated invite.
2. Verify no OS notification is required for test success.
3. Verify in-app pending invite is visible.
4. Accept invite from in-app UI.
5. Repeat and decline invite from in-app UI.

Pass criteria:

- Invite remains discoverable and actionable in DinoX with notifications disabled.

## Scenario E: deny/decline behavior

Purpose: reject path must work and must not create side effects.

Actors:

- Sender: `testuser@dinox.im`
- Receiver: `testuser1@dinox.im`

Steps for mediated invite:

1. Send XEP-0045 mediated invite.
2. Click decline from notification if available.
3. Verify `dismiss/deny-invite` action exists and receives the correct invite ID.
4. Verify pending invite is removed.
5. Verify XEP-0045 decline stanza is sent to room/inviter.
6. Verify no conversation/bookmark/autojoin is created.

Steps for direct invite:

1. Send XEP-0249 direct invite.
2. Decline it.
3. Verify pending invite is removed locally.
4. Verify no XEP-0045 decline stanza is sent.
5. Verify no conversation/bookmark/autojoin is created.

Pass criteria:

- Decline behavior matches invite source.
- Reject path is available on GNotification, Freedesktop, Windows, and in-app UI where applicable.

## Scenario F: multi-account routing

Purpose: same room invited on multiple local accounts must stay separated.

Actors:

- Sender: `testuser@dinox.im`
- Receiver A: `testuser1@dinox.im`
- Receiver B: `testuser2@dinox.im`

Steps:

1. Add both receiver accounts to the same DinoX profile.
2. Invite both receivers to the same room.
3. Verify two pending invites exist or one per account is shown clearly.
4. Verify each invite dialog shows the target account.
5. Accept receiver A only.
6. Verify receiver A joins and receiver B remains pending.
7. Decline receiver B.
8. Verify no cross-account conversation/bookmark/autojoin is created.

Pass criteria:

- Invite action routes by account plus invite ID, not room JID alone.

## Scenario G: already joined room

Purpose: receiving an invite for a room already joined must not create duplicate state.

Actors:

- Receiver: `testuser1@dinox.im`
- Sender: `testuser@dinox.im`

Steps:

1. Receiver joins fresh room manually.
2. Sender sends mediated invite to receiver for same room.
3. Verify DinoX ignores it or routes to existing room without new pending invite.
4. Verify no duplicate conversation row.
5. Verify no bookmark/autojoin change.

Pass criteria:

- Already-joined invite does not create duplicate pending invite or duplicate conversation.

## Scenario H: outbound DinoX-to-DinoX invite

Purpose: sending from DinoX MUC UI should produce correct inbound pending invite on another DinoX account.

Actors:

- Sender: `testuser@dinox.im`
- Receiver: `testuser1@dinox.im`

Steps:

1. Sender joins fresh MUC in DinoX.
2. Use MUC header `Invite People...`.
3. Enter receiver JID and optional reason.
4. Send invite.
5. Verify sender UI shows clear status: sent, failed, or server may not confirm delivery.
6. Verify receiver gets pending invite, not immediate join.
7. Verify reason survives to receiver dialog.
8. Accept receiver invite.
9. Verify receiver joins.

Repeat through participant/occupant popover invite entry.

Pass criteria:

- Both UI entry points use the same outbound invite service.
- Receiver behavior is identical for both entry points.

## Scenario I: replay, MAM, carbon, and self-copy hardening

Purpose: old or mirrored invite messages must not create fresh pending invites.

Actors:

- Sender: `testuser@dinox.im`
- Receiver: `testuser1@dinox.im`

Steps:

1. Send invite while receiver is offline.
2. Start receiver and observe MAM/offline delivery behavior.
3. Verify only genuinely current invite creates pending state.
4. Trigger account reconnect.
5. Verify same archived invite does not reappear repeatedly.
6. Send direct invite from same account/resource if possible and verify self-copy/carbon does not create local pending invite for sender.

Pass criteria:

- No repeated stale invites after restart/reconnect.
- No self-invite generated by carbon/self-copy.

## Scenario J: outbound permission and failure handling

Purpose: inviting from rooms where sender lacks permission must show useful errors.

Actors:

- Sender: `testuser@dinox.im`
- Receiver: `testuser1@dinox.im`

Steps:

1. Join or create a room where sender lacks invite permission, if server configuration allows.
2. Try mediated invite.
3. Verify UI does not claim guaranteed success if stanza delivery is not confirmed.
4. Capture server error if returned, for example `forbidden`.
5. Verify error is shown to user.

Pass criteria:

- Failures are visible.
- UI wording distinguishes sent/no-confirmation from accepted/joined.

## Per-slice regression set

After each implementation slice, run at minimum:

1. Scenario A accept.
2. Scenario E decline mediated.
3. Scenario H outbound DinoX-to-DinoX.
4. Scenario F account routing if changed code touches action routing or notification payloads.
5. Scenario C if changed code touches password, invite model, notification, or join dialog.

## Full acceptance gate

The MUC invite feature is complete only when all are true:

- Inbound mediated invite produces pending invite and no pre-accept conversation.
- Inbound direct invite produces pending invite and no pre-accept conversation.
- Reason survives to dialog.
- Password survives to join and does not leak.
- Decline works for mediated and direct semantics.
- Notifications disabled still leaves in-app invite visible.
- Multi-account routing is correct.
- Already-joined rooms do not duplicate state.
- DinoX outbound invite arrives at another DinoX as pending invite.
- Join from invite does not set bookmark/autojoin unless user explicitly chooses that policy.

## Implementation progress

### Phase 1: protocol foundation - completed 2026-06-13

Files changed:

- `xmpp-vala/src/module/xep/0045_muc/module.vala`
- `xmpp-vala/src/module/xep/0249_direct_muc_invitations.vala`
- `libdino/src/service/muc_manager.vala`

Implemented:

- XEP-0045 mediated outbound invites can include optional `reason`.
- XEP-0045 mediated outbound invites can include optional `<continue thread='...'/>` context.
- XEP-0045 mediated invite decline send-path was added via `decline_invite(...)`.
- XEP-0045 inbound invite context is exposed through `invite_received_with_context` while preserving the legacy `invite_received` signal.
- XEP-0249 direct outbound invites can include optional `password`, `reason`, `continue`, and `thread` attributes.
- XEP-0249 direct invite `thread` is normalized to require continuation context: outbound sets `continue='true'` when `thread` is present, inbound discards `thread` when `continue` is absent.
- XEP-0249 `jabber:x:conference` is advertised through service discovery.
- XEP-0249 direct inbound invites ignore MAM replays and self bare-JID copies.
- `MucManager` now receives invite context from both XMPP modules and re-emits both the legacy metadata signal and an additive context signal.

Validation:

- `meson compile -C build main/dinox` completed successfully after the Phase 1 patch.
- Developer re-review: GO.
- XEP auditor re-review: GO.

Explicitly not done in Phase 1:

- No `PendingMucInvite` state yet.
- No notification routing change yet.
- No in-app pending invite surface yet.
- No removal of pre-accept `GROUPCHAT` conversation creation yet.
- No `deny-invite` UI/action fix yet.
- No join policy/autojoin/bookmark separation yet.

Next phase:

- Phase 2 must introduce the pending invite state/model and route inbound XEP-0045/XEP-0249 invites through it without creating conversations, bookmarks, or autojoin state before user acceptance.

### Phase 2: runtime pending invite state - completed 2026-06-13

Files changed:

- `libdino/src/service/muc_invite_manager.vala`
- `libdino/meson.build`
- `libdino/src/application.vala`

Implemented:

- Added `MucInviteManager` as a runtime-only pending invite service.
- Added `PendingMucInvite` with account, room, inviter, source, password, reason, continue/thread, timestamps, and state.
- Preserved protected-room passwords only in memory and cleared them on accept, decline, dismiss, and account removal.
- Dedupe inbound invites by account and room; newer invites refresh the pending entry.
- Ignored inbound invites for rooms that are already joined.
- Added accept, decline, and dismiss service operations.
- Invite accept now uses a transient MUC join with bookmark/autojoin side effects suppressed.
- Join failures keep the pending invite so the user can retry.
- External room joins remove stale pending invites.
- Duplicate merge preserves an existing password and prefers mediated source semantics.
- Reconnects do not stack duplicate invite handlers.
- Sent XEP-0045 mediated decline only for mediated invites; direct XEP-0249 decline is local dismiss semantics.
- Started the service immediately after `MucManager`.
- Moved invite notifications from the legacy `MucManager.invite_received` path to `MucInviteManager.invite_received`.
- Changed FreeDesktop, GNotifications, and Windows invite notification actions to route by `invite_id`.
- Removed pre-accept `GROUPCHAT` conversation creation from invite notifications.
- Added `open-muc-invite`, `accept-muc-invite`, and `deny-muc-invite` app actions.
- Added a minimal pending-invite confirmation dialog that joins through `MucInviteManager`, not `AddGroupchatDialog`.

Validation:

- `meson compile -C build main/dinox` completed successfully after the Phase 2 patch.
- Developer/regression reaudit initially returned NO-GO for bookmark/password persistence, stale pending state, duplicate merge, reconnect handler stacking, and legacy notification routing.
- Those NO-GO findings were fixed and rebuilt successfully.
- Final focused reaudit returned GO after GNotifications invite action variants were corrected.

Explicitly not done in Phase 2:

- Outbound invite UX and error reporting are still pending.
- Rich in-app pending invite inbox/list is still pending; Phase 2 only adds notification-driven confirmation.
- Optional post-join "remember room" policy is still pending and must stay separate from invite accept.

## Phase 3 completed - outgoing MUC invitations (2026-06-13)

Status: completed and build-checked.

Implemented:

- Outgoing MUC invitations now use one shared UI flow via `Util.show_muc_invite_dialog`.
- The dialog asks for a contact JID, an optional reason, and an explicit delivery method.
- Delivery methods are intentionally exclusive: XEP-0045 mediated invite or XEP-0249 direct invite. There is no send-both path and no silent fallback.
- Direct invites deliberately pass `password = null`; no outbound password UI or password persistence was added.
- `MucManager.invite` now returns `MucInviteSendResult` with concrete local failure codes.
- XEP-0045 and XEP-0249 invite sends are async/throws so local send failures can surface as `send-failed`.
- The active invite UI call sites now route through the shared helper: conversation selector row, titlebar menu action, and occupant menu.
- Notification accept actions now open the pending-invite dialog instead of directly joining.
- The latent `accept-muc-invite` app action is guarded to open the dialog as well, not directly join.
- If desktop notifications are disabled, newly received pending invites open an in-app confirmation dialog.
- Direct+mediated duplicate inbound invites now keep the single visible pending invite but allow a later mediated invite to upgrade the pending source. Decline can then send XEP-0045 decline when appropriate.

Validation performed:

- `meson compile -C build main/dinox` completed successfully after the final patches.
- Developer review: GO.
- XEP/UX audit: GO after fixing mediated source upgrade and the latent accept action.

Still pending for manual/runtime testing:

- Send XEP-0045 mediated invite from a DinoX MUC to another DinoX account and verify explicit pending dialog before join.
- Send XEP-0249 direct invite from a DinoX MUC to another DinoX account and verify explicit pending dialog before join.
- Verify decline sends mediated decline only for mediated invites and stays local for direct invites.
- Verify disabled desktop notifications still show an in-app pending invite dialog.
- Verify server/room rejection behavior remains a local send limitation: `MucInviteSendResult.sent` only means the stanza was sent/queued locally, not accepted by the server or recipient.

## Phase 4 implemented - block invite-triggered autojoin/open side effects (2026-06-13)

Status: implemented, pending compile/runtime validation.

Implemented:

- Invite-only XEP-0249 and XEP-0045 stanzas are filtered before the normal message/conversation pipeline.
- Unknown `GROUPCHAT` messages no longer create a persisted groupchat conversation unless DinoX already knows the room as joined or joining.
- Active local room restore joins no longer write autojoin/bookmark state implicitly.
- Pending invites are no longer silently removed when the same room is joined through a non-invite-accept path.
- Incoming pending invites always show a DinoX in-app dialog, independent of desktop notification settings.
- The in-app invite dialog now defaults to `Later`, not `Join`, and shows the target account plus room-password presence without exposing the password.

Expected invariant:

- Receiving an invite for a room that did not previously exist in DinoX must not create/open a `GROUPCHAT` conversation or send MUC join presence before explicit user accept.

Still pending:

- Compile validation.
- Reviewer and XEP/UX auditor pass.
- Manual Gajim-to-DinoX runtime test for a fresh room with no previous DinoX conversation/bookmark.
- Rich persistent invite inbox/list beyond the current in-app dialog.
- Full join-policy enum refactor if coalesced join/autojoin edge cases remain.

### Phase 4 review fixes

Implemented after architecture/developer/reviewer/auditor NO-GO findings:

- Added `MucInviteState.ALREADY_JOINED` for pending invites that are superseded by a non-invite-accept join.
- Invites received while the room is already joined or joining are ignored instead of creating pending UI.
- `on_room_joined` no longer leaves a stale `PENDING` invite; it clears runtime secrets and updates the invite to `ALREADY_JOINED`.
- The in-app invite dialog is deduplicated per `invite_id`.
- The legacy `open-muc-join` action is guarded to groupchat conversations only.
- New nullable `ConversationManager.get_conversation_for_message()` behavior is handled in search and reactions consumers.

Remaining caveats:

- A richer persistent invite inbox/list is still pending; the current implementation provides an in-app dialog plus runtime pending state.
- The full join-policy enum refactor remains pending for future coalesced-join edge cases.

### Phase 4 final review fixes

Implemented after the second reviewer pass:

- Reactions now handle nullable MUC conversation lookup in both affected places.
- Old `ALREADY_JOINED` invite entries can be reactivated by a later real invite after the user has left the room; this emits `invite_received` again instead of a silent update.
- `ALREADY_JOINED` dialogs are deduplicated like pending invite dialogs.

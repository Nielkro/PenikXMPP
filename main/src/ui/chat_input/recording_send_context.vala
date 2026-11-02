/*
 * Copyright (C) 2026 Ralf Peter <dinox@handwerker.jetzt>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

using Dino.Entities;

namespace Dino.Ui.ChatInput {

// A MUC nickname and a mutable Conversation object are not a person identity.
// Keep the original account/address and use the thread-clear boundary to
// distinguish a peer replacement from stronger evidence for the same occupant.
internal class InputTargetSnapshot : Object {
    public Account account { get; private set; }
    private int account_id;
    private string account_jid;
    private int conversation_id;
    private Conversation.Type conversation_type;
    private string counterpart;
    private string? peer_identity;
    private DateTime? history_cleared_at;
    private bool invalidated = false;

    public InputTargetSnapshot(Conversation target) {
        account = target.account;
        account_id = account.id;
        account_jid = account.bare_jid.to_string();
        conversation_id = target.id;
        conversation_type = target.type_;
        counterpart = target.counterpart.to_string();
        peer_identity = target.muc_pm_peer_identity;
        history_cleared_at = target.history_cleared_at;
        if (conversation_type == Conversation.Type.GROUPCHAT_PM) {
            target.notify["muc-pm-peer-identity"].connect(on_peer_identity_changed);
        }
    }

    private void on_peer_identity_changed(Object source, ParamSpec property) {
        Conversation target = (Conversation) source;
        if (matches(target)) {
            // Record stronger evidence immediately. A later ordinary history
            // clear must not turn this harmless promotion into a peer change.
            peer_identity = target.muc_pm_peer_identity;
        } else {
            // A later return to the old identity cannot revive a discarded
            // draft or recording after another occupant owned this nickname.
            invalidated = true;
        }
    }

    public bool matches(Conversation target) {
        if (invalidated || target.account != account || target.account.id != account_id ||
                target.account.bare_jid.to_string() != account_jid ||
                target.id != conversation_id || target.type_ != conversation_type ||
                target.counterpart.to_string() != counterpart) return false;
        if (conversation_type != Conversation.Type.GROUPCHAT_PM ||
                target.muc_pm_peer_identity == peer_identity) return true;
        // ConversationManager clears the thread before a real peer rebind.
        // Identity promotion for a continuously live occupant keeps it intact.
        if (history_cleared_at == null || target.history_cleared_at == null) {
            return history_cleared_at == target.history_cleared_at;
        }
        return ((!) history_cleared_at).compare((!) target.history_cleared_at) == 0;
    }
}

internal class RecordingSendContext : Object {
    private Conversation? target_conversation = null;
    private InputTargetSnapshot? target_snapshot = null;

    public bool try_bind(Conversation conversation) {
        if (target_conversation != null) return false;
        target_conversation = conversation;
        target_snapshot = new InputTargetSnapshot(conversation);
        return true;
    }

    public Conversation? take() {
        Conversation? result = target_conversation;
        if (result != null && (target_snapshot == null ||
                !((!) target_snapshot).matches((!) result))) result = null;
        clear();
        return result;
    }

    public void clear() {
        target_conversation = null;
        target_snapshot = null;
    }
}

}

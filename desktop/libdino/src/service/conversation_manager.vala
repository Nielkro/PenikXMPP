/*
 * Copyright (C) 2025 Ralf Peter <dinox@handwerker.jetzt>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

using Gee;

using Xmpp;
using Dino.Entities;

namespace Dino {
public class ConversationManager : StreamInteractionModule, Object {
    public static ModuleIdentity<ConversationManager> IDENTITY = new ModuleIdentity<ConversationManager>("conversation_manager");
    public string id { get { return IDENTITY.id; } }

    public signal void conversation_activated(Conversation conversation);
    public signal void conversation_deactivated(Conversation conversation);
    public signal void conversation_hidden(Conversation conversation);
    public signal void conversation_cleared(Conversation conversation);

    private StreamInteractor stream_interactor;
    private Database db;
    private Dino.Entities.Settings settings;
    private bool muc_manager_signals_bound = false;

    private HashMap<Account, HashMap<Jid, Gee.List<Conversation>>> conversations = new HashMap<Account, HashMap<Jid, Gee.List<Conversation>>>(Account.hash_func, Account.equals_func);
    private HashMap<int, Conversation> conversations_by_id = new HashMap<int, Conversation>();

    public static void start(StreamInteractor stream_interactor, Database db) {
        ConversationManager m = new ConversationManager(stream_interactor, db);
        stream_interactor.add_module(m);
    }

    private ConversationManager(StreamInteractor stream_interactor, Database db) {
        this.db = db;
        this.settings = new Dino.Entities.Settings.from_db(db);
        this.stream_interactor = stream_interactor;
        stream_interactor.account_added.connect(on_account_added);
        stream_interactor.account_removed.connect(on_account_removed);
        stream_interactor.get_module<MessageProcessor>(MessageProcessor.IDENTITY).received_pipeline.connect(new MessageListener(stream_interactor));
        stream_interactor.get_module<MessageProcessor>(MessageProcessor.IDENTITY).message_sent.connect(handle_sent_message);
        stream_interactor.get_module<Calls>(Calls.IDENTITY).call_incoming.connect(handle_new_call);
        stream_interactor.get_module<Calls>(Calls.IDENTITY).call_outgoing.connect(handle_new_call);
    }

    internal void bind_muc_manager(MucManager muc_manager) {
        if (muc_manager_signals_bound) return;
        muc_manager_signals_bound = true;

        muc_manager.room_info_updated.connect((account, room) => {
            Conversation? conversation = get_conversation(room.bare_jid,
                account, Conversation.Type.GROUPCHAT);
            if (conversation != null) {
                synchronize_groupchat_encryption_from_room_info(muc_manager,
                    (!) conversation);
            }
        });
    }

    private void synchronize_groupchat_encryption_from_room_info(
            MucManager muc_manager, Conversation conversation) {
        if (conversation.type_ != Conversation.Type.GROUPCHAT ||
                !muc_manager.has_current_room_features(conversation.account,
                    conversation.counterpart)) {
            return;
        }

        if (muc_manager.is_private_room(conversation.account,
                conversation.counterpart)) {
            if (conversation.encryption == Encryption.NONE) {
                conversation.encryption = settings.get_default_encryption(
                    conversation.account);
            }
        } else if (conversation.encryption != Encryption.NONE) {
            conversation.encryption = Encryption.NONE;
        }
    }

    public Conversation create_conversation(Jid jid, Account account,
            Conversation.Type? type = null,
            string? muc_pm_peer_identity = null) {
        if (!conversations.has_key(account)) {
            critical("Attempted to create conversation for untracked account: %s", account.id.to_string());
            // Recover by initializing the map entry to avoid crash, though this indicates logic error elsewhere
            conversations[account] = new HashMap<Jid, Gee.List<Conversation>>();
        }
        
        Jid store_jid = get_conversation_key(jid, type);
        string? resolved_pm_identity = muc_pm_peer_identity != null
            ? ((!) muc_pm_peer_identity).dup() : null;
        if (type == Conversation.Type.GROUPCHAT_PM &&
                resolved_pm_identity == null) {
            resolved_pm_identity = stream_interactor.get_module<MucManager>(
                MucManager.IDENTITY).get_private_message_peer_identity(account,
                    store_jid);
        }

        // Do we already have a conversation for this jid?
        if (conversations[account].has_key(store_jid)) {
            foreach (var conversation in conversations[account][store_jid]) {
                if (conversation.type_ == type) {
                    if (type == Conversation.Type.GROUPCHAT_PM &&
                            resolved_pm_identity != null) {
                        MucManager muc_manager = stream_interactor.get_module<
                            MucManager>(MucManager.IDENTITY);
                        if (conversation.muc_pm_peer_identity != null &&
                                muc_manager.private_message_peer_identity_matches(
                                    account, store_jid,
                                    (!) conversation.muc_pm_peer_identity)) {
                            // Stronger evidence for the same continuously-live
                            // occupant: preserve the thread and only promote
                            // its persisted identity.
                            conversation.muc_pm_peer_identity =
                                resolved_pm_identity;
                        } else {
                            bind_groupchat_pm_identity(conversation,
                                (!) resolved_pm_identity);
                        }
                    }
                    if (conversation.type_ == Conversation.Type.GROUPCHAT) {
                        synchronize_groupchat_encryption_from_room_info(
                            stream_interactor.get_module<MucManager>(
                                MucManager.IDENTITY), conversation);
                    }
                    return conversation;
                }
            }
        }

        // Create a new converation
        Conversation conversation = new Conversation(store_jid, account, type);
        if (type == Conversation.Type.GROUPCHAT_PM) {
            conversation.muc_pm_peer_identity = resolved_pm_identity;
        }
        // Set encryption for conversation
        if (type == Conversation.Type.CHAT ||
                (type == Conversation.Type.GROUPCHAT && stream_interactor.get_module<MucManager>(MucManager.IDENTITY).is_private_room(account, store_jid))) {
            conversation.encryption = settings.get_default_encryption(account);
        } else {
            conversation.encryption = Encryption.NONE;
        }

        conversation.persist(db);
        add_conversation(conversation);
        return conversation;
    }

    public Conversation? get_conversation_for_message(Entities.Message message) {
        if (conversations.has_key(message.account)) {
            if (message.type_ == Entities.Message.Type.CHAT) {
                return create_conversation(message.counterpart.bare_jid, message.account, Conversation.Type.CHAT);
            } else if (message.type_ == Entities.Message.Type.GROUPCHAT) {
                Conversation? existing = get_conversation(message.counterpart.bare_jid, message.account, Conversation.Type.GROUPCHAT);
                if (existing != null) return existing;

                MucManager muc_manager = stream_interactor.get_module<MucManager>(MucManager.IDENTITY);
                if (!muc_manager.is_joined_or_joining(message.counterpart.bare_jid, message.account)) return null;

                return create_conversation(message.counterpart.bare_jid, message.account, Conversation.Type.GROUPCHAT);
            } else if (message.type_ == Entities.Message.Type.GROUPCHAT_PM) {
                return create_conversation(message.counterpart, message.account, Conversation.Type.GROUPCHAT_PM);
            }
        }
        return null;
    }

    public Gee.List<Conversation> get_conversations(Jid jid, Account account) {
        Gee.List<Conversation> ret = new ArrayList<Conversation>(Conversation.equals_func);
        Conversation? bare_conversation = get_conversation(jid, account);
        if (bare_conversation != null) ret.add(bare_conversation);
        Conversation? full_conversation = get_conversation(jid.bare_jid, account);
        if (full_conversation != null) ret.add(full_conversation);
        return ret;
    }

    public Conversation? get_conversation(Jid jid, Account account, Conversation.Type? type = null) {
        if (conversations.has_key(account)) {
            Jid lookup_jid = get_conversation_key(jid, type);
            if (conversations[account].has_key(lookup_jid)) {
                foreach (var conversation in conversations[account][lookup_jid]) {
                    if (type == null || conversation.type_ == type) {
                        return conversation;
                    }
                }
            }
        }
        return null;
    }

    public Conversation? approx_conversation_for_stanza(Jid from, Jid to, Account account, string msg_ty) {
        if (msg_ty == Xmpp.MessageStanza.TYPE_GROUPCHAT) {
            return get_conversation(from.bare_jid, account, Conversation.Type.GROUPCHAT);
        }

        Jid counterpart = from.equals_bare(account.bare_jid) ? to : from;

        if (msg_ty == Xmpp.MessageStanza.TYPE_CHAT && counterpart.is_full() &&
                get_conversation(counterpart.bare_jid, account,
                    Conversation.Type.GROUPCHAT) != null) {
            Conversation? pm = get_conversation(counterpart, account,
                Conversation.Type.GROUPCHAT_PM);
            if (pm != null) {
                MucManager muc_manager = stream_interactor.get_module<
                    MucManager>(MucManager.IDENTITY);
                // Control stanzas must never bind or replace a private-MUC
                // peer identity. Only an actual message may do that through
                // create_conversation() and bind_groupchat_pm_identity().
                if (((!) pm).muc_pm_peer_identity == null) return null;
                if (muc_manager.private_message_peer_identity_matches(account,
                        counterpart, (!) ((!) pm).muc_pm_peer_identity)) {
                    return pm;
                }
                return null;
            }
        }

        return get_conversation(counterpart.bare_jid, account, Conversation.Type.CHAT);
    }

    public Conversation? get_conversation_by_id(int id) {
        if (conversations_by_id.has_key(id)) {
            return conversations_by_id[id];
        }
        return null;
    }

    public Gee.List<Conversation> get_active_conversations(Account? account = null) {
        Gee.List<Conversation> ret = new ArrayList<Conversation>(Conversation.equals_func);
        foreach (Account account_ in conversations.keys) {
            if (account != null && !account_.equals(account)) continue;
            foreach (Gee.List<Conversation> list in conversations[account_].values) {
                foreach (var conversation in list) {
                    if(conversation.active) ret.add(conversation);
                }
            }
        }
        return ret;
    }

    public Gee.List<Conversation> get_groupchat_conversations(Account? account = null) {
        Gee.List<Conversation> ret = new ArrayList<Conversation>(Conversation.equals_func);
        foreach (Account account_ in conversations.keys) {
            if (account != null && !account_.equals(account)) continue;
            foreach (Gee.List<Conversation> list in conversations[account_].values) {
                foreach (var conversation in list) {
                    if (conversation.type_ == Conversation.Type.GROUPCHAT) ret.add(conversation);
                }
            }
        }
        return ret;
    }

    public void start_conversation(Conversation conversation) {
        if (conversation.last_active == null) {
            conversation.last_active = new DateTime.now_utc();
            if (conversation.active) conversation_activated(conversation);
        }
        if (!conversation.active) {
            conversation.active = true;
            conversation_activated(conversation);
        }
    }

    public void close_conversation(Conversation conversation) {
        if (!conversation.active) return;

        conversation.active = false;
        conversation_deactivated(conversation);

        // Release cached messages for this conversation to free RAM
        stream_interactor.get_module<MessageStorage>(MessageStorage.IDENTITY).clear_conversation_cache(conversation);
    }

    // Removing a contact and its local history is one user operation. Keep
    // the history if the server rejects the roster change, and never apply a
    // delayed reply to a replacement account/stream/conversation.
    public async RosterRemoveResult remove_contact_and_history(Account account, Jid jid) {
        XmppStream? stream = stream_interactor.get_stream(account);
        RosterManager? roster = stream_interactor.get_module<RosterManager>(RosterManager.IDENTITY);
        if (stream == null || roster == null || !is_current_contact_account(account) ||
                stream.get_module<Xmpp.Roster.Module>(Xmpp.Roster.Module.IDENTITY) == null)
            return RosterRemoveResult.UNAVAILABLE;
        Conversation? target = get_conversation(jid.bare_jid, account, Conversation.Type.CHAT);
        RosterRemoveResult result = yield roster.remove_jid_async(account, jid.bare_jid);
        if (result != RosterRemoveResult.SUCCESS) return result;
        if (stream_interactor.get_stream(account) != stream || !is_current_contact_account(account) ||
                get_conversation(jid.bare_jid, account, Conversation.Type.CHAT) != target)
            return RosterRemoveResult.UNAVAILABLE;
        if (target != null) {
            clear_conversation_history(target);
            // Clearing emits a signal; a callback may have replaced the chat.
            if (get_conversation(jid.bare_jid, account, Conversation.Type.CHAT) == target)
                close_conversation(target);
        }
        return RosterRemoveResult.SUCCESS;
    }

    private bool is_current_contact_account(Account account) {
        if (!account.enabled) return false;
        foreach (Account managed in stream_interactor.get_accounts()) {
            if (managed == account && managed.enabled) return true;
        }
        return false;
    }

    /**
     * Permanently remove a 1:1 conversation from the in-memory maps.
     * After this call, incoming messages will create a fresh Conversation
     * object instead of reactivating the old one.
     * Call close_conversation() / clear_conversation_history() first.
     */
    public void forget_conversation(Conversation conversation) {
        if (!conversations.has_key(conversation.account)) return;
        Jid key = get_conversation_key(conversation.counterpart, conversation.type_);
        if (!conversations[conversation.account].has_key(key)) return;

        var list = conversations[conversation.account][key];
        list.remove(conversation);
        if (list.size == 0) {
            conversations[conversation.account].unset(key);
        }
        conversations_by_id.unset(conversation.id);
    }

    // Hide conversation from sidebar without leaving MUC rooms.
    // For 1:1 chats this is identical to close_conversation().
    // For MUC: the room stays joined, autojoin stays set, only the UI is closed.
    public void hide_conversation(Conversation conversation) {
        if (!conversation.active) return;

        conversation.active = false;
        conversation_hidden(conversation);
    }

    private void on_account_added(Account account) {
        conversations[account] = new HashMap<Jid, ArrayList<Conversation>>(Jid.hash_func, Jid.equals_func);
        foreach (Conversation conversation in db.get_conversations(account)) {
            // A room nickname can belong to a different person after restart.
            // Reopen PMs only after a live occupant identity has been bound.
            if (conversation.type_ == Conversation.Type.GROUPCHAT_PM &&
                    conversation.active) {
                conversation.active = false;
            }
            add_conversation(conversation);
        }
    }

    private void bind_groupchat_pm_identity(Conversation conversation,
            string identity) {
        if (conversation.type_ != Conversation.Type.GROUPCHAT_PM) return;
        if (conversation.muc_pm_peer_identity == identity) return;
        if (conversation.counterpart.resourcepart == null) {
            warning("Refusing to bind a private MUC conversation without a nickname");
            return;
        }

        // A legacy unbound row is treated exactly like an identity change: it
        // is impossible to prove that its room/nick still denotes the same
        // person. Drop only this PM resource's local thread before rebinding.
        stream_interactor.get_module<MessageStorage>(MessageStorage.IDENTITY)
            .clear_conversation_cache(conversation);
        db.content_item.delete()
            .with(db.content_item.conversation_id, "=", conversation.id)
            .perform();
        var delete_messages = db.message.delete()
            .with(db.message.account_id, "=", conversation.account.id)
            .with(db.message.counterpart_id, "=",
                db.get_jid_id(conversation.counterpart))
            .with(db.message.type_, "=",
                Util.get_message_type_for_conversation(conversation))
            .with(db.message.counterpart_resource, "=",
                conversation.counterpart.resourcepart);
        delete_messages.perform();
        conversation.read_up_to = null;
        conversation.read_up_to_item = -1;
        conversation.history_cleared_at = new DateTime.now_utc();
        conversation.muc_pm_peer_identity = identity;
        conversation_cleared(conversation);
    }

    private void on_account_removed(Account account) {
        if (!conversations.has_key(account)) return;

        foreach (Gee.List<Conversation> list in conversations[account].values) {
            foreach (var conversation in list) {
                if(conversation.active) conversation_deactivated(conversation);
            }
        }
        conversations.unset(account);
    }

    private class MessageListener : Dino.MessageListener {

        public string[] after_actions_const = new string[]{ "DEDUPLICATE", "FILTER_EMPTY" };
        public override string action_group { get { return "MANAGER"; } }
        public override string[] after_actions { get { return after_actions_const; } }

        private StreamInteractor stream_interactor;

        public MessageListener(StreamInteractor stream_interactor) {
            this.stream_interactor = stream_interactor;
        }

        public override async bool run(Entities.Message message, Xmpp.MessageStanza stanza, Conversation conversation) {
            conversation.last_active = message.time;

            if (stanza != null) {
                bool is_mam_message = Xmpp.MessageArchiveManagement.MessageFlag.get_flag(stanza) != null;
                bool is_recent = message.time.compare(new DateTime.now_utc().add_days(-3)) > 0;
                if (is_mam_message && !is_recent) return false;
            }

            // Roster removal does not block new messages. Old cleared archive
            // entries are rejected by MessageProcessor's history policy before
            // this listener; accepted messages must make their chat visible.
            stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY).start_conversation(conversation);
            return false;
        }
    }

    private void handle_sent_message(Entities.Message message, Conversation conversation) {
        conversation.last_active = message.time;

        bool is_recent = message.time.compare(new DateTime.now_utc().add_hours(-24)) > 0;
        if (is_recent) {
            start_conversation(conversation);
        }
    }

    private void handle_new_call(Call call, CallState state, Conversation conversation) {
        conversation.last_active = call.time;
        start_conversation(conversation);
    }

    // Only an explicit history request may lift this conversation's local
    // clear boundary. A newer clear, including one during feature discovery,
    // still wins. Normal startup/join synchronization never calls this.
    internal bool prepare_history_restore(Conversation conversation,
            DateTime requested_at) {
        Conversation? canonical = get_conversation_by_id(conversation.id);
        if (canonical == null ||
                !conversation.matches_persisted_identity(db) ||
                !((!) canonical).matches_persisted_identity(db) ||
                ((!) canonical).account.id != conversation.account.id ||
                ((!) canonical).type_ != conversation.type_ ||
                !((!) canonical).counterpart.equals(conversation.counterpart) ||
                (conversation.type_ != Conversation.Type.CHAT &&
                 conversation.type_ != Conversation.Type.GROUPCHAT)) return false;
        int expected_id = conversation.id;
        Account expected_account = conversation.account;
        DateTime? cleared = ((!) canonical).history_cleared_at;
        if (cleared != null && ((!) cleared).compare(requested_at) <= 0) {
            ((!) canonical).history_cleared_at = null;
        }
        // Property notifications can invalidate a dialog clone or clear the
        // conversation again. Mirror the current canonical value, not null.
        if (conversation.id != expected_id ||
                conversation.account != expected_account ||
                !conversation.matches_persisted_identity(db) ||
                !((!) canonical).matches_persisted_identity(db)) return false;
        if (canonical != conversation) {
            conversation.history_cleared_at = ((!) canonical).history_cleared_at;
        }
        return true;
    }

    public void clear_conversation_history(Conversation conversation, bool global = false) {
        if (conversation.type_ == Conversation.Type.GROUPCHAT_PM &&
                conversation.counterpart.resourcepart == null) {
            warning("Refusing to clear a private MUC conversation without a nickname");
            return;
        }

        // Delete all content items globally (server + local) in batches
        var content_item_store = stream_interactor.get_module<ContentItemStore>(ContentItemStore.IDENTITY);
        var message_deletion = stream_interactor.get_module<MessageDeletion>(MessageDeletion.IDENTITY);
        
        if (global) {
            // Get items in batches and retract our own messages using XEP-0424.
            int batch_size = 100;
            while (true) {
                var items = content_item_store.get_n_latest(conversation, batch_size);
                if (items.size == 0) break;
                
                foreach (ContentItem item in items) {
                    // Bulk history clearing must not wait on asynchronous
                    // XEP-0424 results for foreign messages. Retract only our
                    // own rows globally; remove received rows locally.
                    if (ContentItem.is_own(item) &&
                            message_deletion.is_deletable(conversation, item) &&
                            message_deletion.can_delete_for_everyone(
                                conversation, item) &&
                            message_deletion.delete_globally(conversation,
                                item)) {
                        // delete_globally() calls delete_locally() internally for all conversation types
                    } else {
                        // Non-deletable items (e.g. empty body): only delete locally
                        message_deletion.delete_locally(conversation, item, conversation.account.bare_jid);
                    }
                }
                
                if (items.size < batch_size) break;
            }
        }
        
        // Clear message storage caches
        stream_interactor.get_module<MessageStorage>(MessageStorage.IDENTITY).clear_conversation_cache(conversation);
        
        // Delete all remaining local data from database
        var delete_messages = db.message.delete()
            .with(db.message.account_id, "=", conversation.account.id)
            .with(db.message.counterpart_id, "=", db.get_jid_id(conversation.counterpart))
            .with(db.message.type_, "=", Util.get_message_type_for_conversation(conversation));
        if (conversation.type_ == Conversation.Type.GROUPCHAT_PM) {
            delete_messages.with(db.message.counterpart_resource, "=",
                conversation.counterpart.resourcepart);
        }
        delete_messages.perform();
                
        db.content_item.delete()
            .with(db.content_item.conversation_id, "=", conversation.id)
            .perform();
        
        // Keep archive coverage to avoid unnecessary replay during normal
        // history clearing. Repairs may rebuild that metadata independently;
        // history_cleared_at then blocks old archived content before decryption,
        // without suppressing other conversations in the account archive.
        
        // Mark this conversation as "cleared" with current timestamp
        // This will filter out old messages during MAM re-sync (both in-memory and after restart)
        var clear_timestamp = new DateTime.now_utc();
        conversation.history_cleared_at = clear_timestamp;
        
        // Persist the clear timestamp to database
        db.conversation.update()
            .with(db.conversation.id, "=", conversation.id)
            .set(db.conversation.history_cleared_at, (long) conversation.history_cleared_at.to_unix())
            .perform();
        
        // Clear OMEMO bad message warnings through this signal.
        // OMEMO cryptographic state (sessions, device knowledge and trust)
        // must remain intact: local history deletion is not an encryption reset.
        conversation_cleared(conversation);

    }

    private void add_conversation(Conversation conversation) {
        Jid key = get_conversation_key(conversation.counterpart, conversation.type_);
        if (!conversations[conversation.account].has_key(key)) {
            conversations[conversation.account][key] = new ArrayList<Conversation>(Conversation.equals_func);
        }

        foreach (var existing in conversations[conversation.account][key]) {
            if (existing.type_ == conversation.type_) {
                conversations_by_id[conversation.id] = existing;
                if (conversation.active && !existing.active) {
                    existing.active = true;
                    conversation_activated(existing);
                }
                return;
            }
        }

        conversations[conversation.account][key].add(conversation);
        conversations_by_id[conversation.id] = conversation;

        if (conversation.active) {
            conversation_activated(conversation);
        }
    }

    private Jid get_conversation_key(Jid jid, Conversation.Type? type) {
        return type == Conversation.Type.GROUPCHAT ? jid.bare_jid : jid;
    }
}

}

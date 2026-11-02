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
using Xmpp.Xep;
using Dino.Entities;
using Qlite;

namespace Dino {

public class MessageProcessor : StreamInteractionModule, Object {
    public static ModuleIdentity<MessageProcessor> IDENTITY = new ModuleIdentity<MessageProcessor>("message_processor");
    public string id { get { return IDENTITY.id; } }
    private const string NS_OMEMO_LEGACY = "eu.siacs.conversations.axolotl";
    private const string NS_OMEMO_2 = "urn:xmpp:omemo:2";
    private const string NS_OPENPGP = "urn:xmpp:openpgp:0";
    private const string NS_OPENPGP_LEGACY = "jabber:x:encrypted";
    private const string NS_DINOX_ENCRYPTION_POLICY = "im.dinox:errors:encryption-policy:0";
    private const string GROUPCHAT_PM_INVALID_TARGET_ERROR = "This private group chat target is invalid. Open the current member list and start a new private conversation.";
    private const string GROUPCHAT_PM_NOT_JOINED_ERROR = "You are no longer in this group chat. Rejoin it before sending a private message.";
    private const string GROUPCHAT_PM_RECIPIENT_GONE_ERROR = "This participant is no longer in the group chat. Open the current member list and start a new private conversation.";

    public signal void message_received(Entities.Message message, Conversation conversation);
    public signal void build_message_stanza(Entities.Message message, Xmpp.MessageStanza message_stanza, Conversation conversation);
    public signal void pre_message_send(Entities.Message message, Xmpp.MessageStanza message_stanza, Conversation conversation);
    public signal void message_sent(Entities.Message message, Conversation conversation);
    public signal void message_sent_or_received(Entities.Message message, Conversation conversation);
    public signal void history_synced(Account account);

    public HistorySync history_sync;
    public MessageListenerHolder received_pipeline = new MessageListenerHolder();

    private StreamInteractor stream_interactor;
    private Database db;
    private MessageSnapshotGate snapshot_gate = new MessageSnapshotGate();

    public async void pause_for_snapshot(Cancellable? cancellable = null) throws Error {
        yield snapshot_gate.pause(cancellable);
    }

    public void resume_after_snapshot() {
        snapshot_gate.resume();
    }

    public static void start(StreamInteractor stream_interactor, Database db) {
        MessageProcessor m = new MessageProcessor(stream_interactor, db);
        stream_interactor.add_module(m);
    }

    private MessageProcessor(StreamInteractor stream_interactor, Database db) {
        this.stream_interactor = stream_interactor;
        this.db = db;
        this.history_sync = new HistorySync(db, stream_interactor);

        received_pipeline.connect(new StableIdDeduplicateMessageListener(this));
        received_pipeline.connect(new ArchiveRetractionListener(stream_interactor, db));
        received_pipeline.connect(new DeduplicateMessageListener(this));
        received_pipeline.connect(new FilterMessageListener());
        received_pipeline.connect(new EncryptionPolicyListener(this));
        received_pipeline.connect(new ClearedConversationFilterListener(stream_interactor));
        received_pipeline.connect(new StoreMessageListener(this, stream_interactor));
        received_pipeline.connect(new StoreContentItemListener(stream_interactor));
        received_pipeline.connect(new MarkupListener(stream_interactor));
        received_pipeline.connect(new MentionListener(stream_interactor));

        stream_interactor.account_added.connect(on_account_added);

        stream_interactor.stream_negotiated.connect(send_unsent_chat_messages);
        stream_interactor.stream_resumed.connect(send_unsent_chat_messages);
    }

    private void convert_sending_to_unsent_msgs(Account account) {
        db.message.update()
                .with(db.message.account_id, "=", account.id)
                .with(db.message.marked, "=", Message.Marked.SENDING)
                .set(db.message.marked, Message.Marked.UNSENT)
                .perform();
    }

    private void send_unsent_chat_messages(Account account) {
        var select = db.message.select()
                .with(db.message.account_id, "=", account.id)
                .with(db.message.marked, "=", (int) Message.Marked.UNSENT)
                .with(db.message.type_, "=", (int) Message.Type.CHAT);
        send_unsent_messages(account, select);
    }

    public void send_unsent_muc_messages(Account account, Jid muc_jid) {
        var select = db.message.select()
                .with(db.message.account_id, "=", account.id)
                .with(db.message.marked, "=", (int) Message.Marked.UNSENT)
                .with(db.message.counterpart_id, "=", db.get_jid_id(muc_jid));
        send_unsent_messages(account, select);
    }

    public void send_unsent_plaintext_muc_messages(Account account,
            Jid muc_jid) {
        var select = db.message.select()
                .with(db.message.account_id, "=", account.id)
                .with(db.message.marked, "=", (int) Message.Marked.UNSENT)
                .with(db.message.counterpart_id, "=",
                    db.get_jid_id(muc_jid))
                .with(db.message.encryption, "=", (int) Encryption.NONE);
        send_unsent_messages(account, select);
    }

    private void send_unsent_messages(Account account, QueryBuilder select) {
        foreach (Row row in select) {
            try {
                Message message = new Message.from_row(db, row);
                Conversation? msg_conv = stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY).get_conversation(message.counterpart, account, Util.get_conversation_type_for_message(message));
                if (msg_conv != null) {
                    Message cached_msg = stream_interactor.get_module<MessageStorage>(MessageStorage.IDENTITY).get_message_by_id(message.id, msg_conv);
                    send_xmpp_message(cached_msg ?? message, msg_conv, true);
                }
            } catch (InvalidJidError e) {
                warning("Ignoring message with invalid Jid: %s", e.message);
            }
        }
    }

    private void on_account_added(Account account) {
        stream_interactor.module_manager.get_module<Xmpp.MessageModule>(account, Xmpp.MessageModule.IDENTITY).received_message.connect( (stream, message) => {
            on_message_received(account, stream, message);
        });

        stream_interactor.module_manager.get_module<Xmpp.MessageModule>(account, Xmpp.MessageModule.IDENTITY).received_error.connect((stream, message_stanza, error_stanza) => {
            if (stream_interactor.get_stream(account) != stream) return;

            Message? message = null;

            Gee.List<Conversation> conversations = stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY).get_conversations(message_stanza.from, account);
            foreach (Conversation conversation in conversations) {
                message = stream_interactor.get_module<MessageStorage>(MessageStorage.IDENTITY).get_message_by_stanza_id(message_stanza.id, conversation);
                if (message != null) break;
            }
            if (message == null) return;
            // We don't care about delivery errors if our counterpart already ACKed the message.
            if (message.marked in Message.MARKED_RECEIVED) return;

            warning("Message delivery error from %s. Type: %s, Condition: %s, Text: %s", message_stanza.from.to_string(), error_stanza.type_ ?? "-", error_stanza.condition, error_stanza.text ?? "-");
            apply_delivery_error(message, error_stanza);
        });

        convert_sending_to_unsent_msgs(account);
    }

    private void on_message_received(Account account, XmppStream stream,
            Xmpp.MessageStanza message_stanza) {
        if (stream_interactor.get_stream(account) != stream) return;

        // If it's a message from MAM, it's going to be processed by HistorySync which calls run_pipeline_announce later.
        if (history_sync.process(account, stream, message_stanza)) return;

        run_pipeline_announce_on_stream.begin(account, stream, message_stanza, null,
                (_, res) => {
            run_pipeline_announce_on_stream.end(res);
        });
    }

    public async void run_pipeline_announce(Account account, Xmpp.MessageStanza message_stanza) {
        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream == null) return;

        yield run_pipeline_announce_on_stream(account, (!) stream,
            message_stanza);
    }

    internal async void run_pipeline_announce_on_stream(Account account,
            XmppStream stream, Xmpp.MessageStanza message_stanza,
            owned MessagePipelineAdmission? admission = null) {
        yield snapshot_gate.enter();
        try {
            var guard = new MessagePipelineGuard(stream_interactor, account,
                stream, (owned) admission);
            if (!guard.is_current()) return;
            if (Xmpp.MessageArchiveManagement.MessageFlag.get_flag(message_stanza) == null) {
                // Snapshot admission now owns both the live archive cursor
                // and the full decrypt/store pipeline. MAM page cursors are
                // still committed by HistorySync after its awaited pipelines.
                history_sync.update_latest_db_range(account, message_stanza);
            }
            if (is_muc_invite_only_stanza(message_stanza)) return;

            Entities.Message message = yield parse_message_stanza(account, message_stanza);
            guard.message = message;
            if (!guard.is_current()) return;

            Conversation? conversation = stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY).get_conversation_for_message(message);
            if (conversation == null) return;
            guard.conversation = conversation;
            if (!guard.is_current()) return;

            // Rebuilding archive coverage can replay previously cleared or
            // expired ciphertext. Reject it before decrypting or consuming
            // session keys, using this conversation's own history policy.
            if (archive_replay_is_outside_history_policy(message_stanza,
                    conversation)) {
                HistoryDiagnostics.received("discard-history-policy", message, message_stanza, conversation);
                return;
            }
            HistoryDiagnostics.received("admit-archive", message, message_stanza, conversation);

            bool abort = yield received_pipeline.run(message, message_stanza,
                conversation, guard);
            HistoryDiagnostics.received(abort ? "pipeline-stopped" : "pipeline-completed",
                message, message_stanza, conversation);
            if (abort) return;
            if (!guard.is_current()) return;

            if (message.direction == Entities.Message.DIRECTION_RECEIVED) {
                message_received(message, conversation);
            } else if (message.direction == Entities.Message.DIRECTION_SENT) {
                message_sent(message, conversation);
            }

            message_sent_or_received(message, conversation);
        } finally {
            snapshot_gate.leave();
        }
    }

    private bool is_muc_invite_only_stanza(Xmpp.MessageStanza message_stanza) {
        bool has_direct_invite = message_stanza.stanza.get_subnode("x", "jabber:x:conference") != null;
        bool has_mediated_invite = false;

        StanzaNode? muc_user_node = message_stanza.stanza.get_subnode("x", "http://jabber.org/protocol/muc#user");
        if (muc_user_node != null) {
            has_mediated_invite =
                muc_user_node.get_subnode("invite", "http://jabber.org/protocol/muc#user") != null ||
                muc_user_node.get_subnode("decline", "http://jabber.org/protocol/muc#user") != null;
        }

        if (!has_direct_invite && !has_mediated_invite) return false;

        string? body = message_stanza.body;
        return body == null || body.strip() == "";
    }

    public async Entities.Message parse_message_stanza(Account account, Xmpp.MessageStanza message) {
        string? body = message.body;
        if (body != null) body = body.strip();
        Entities.Message new_message = new Entities.Message(body);
        new_message.account = account;
        assign_sender_ids(new_message, message);

        Jid? counterpart_override = null;
        if (message.from.equals(stream_interactor.get_module<MucManager>(MucManager.IDENTITY).get_own_jid(message.from.bare_jid, account))) {
            new_message.direction = Entities.Message.DIRECTION_SENT;
            counterpart_override = message.from.bare_jid;
        } else if (account.bare_jid.equals_bare(message.from)) {
            new_message.direction = Entities.Message.DIRECTION_SENT;
        } else {
            new_message.direction = Entities.Message.DIRECTION_RECEIVED;
        }
        new_message.counterpart = counterpart_override ?? (new_message.direction == Entities.Message.DIRECTION_SENT ? message.to : message.from);
        new_message.ourpart = new_message.direction == Entities.Message.DIRECTION_SENT ? message.from : message.to;

        // Preserve the historical scalar for deduplication while separately
        // recording the exact XEP-0359/MAM authority used by XEP-0490.
        Xmpp.MessageArchiveManagement.MessageFlag? mam_message_flag = Xmpp.MessageArchiveManagement.MessageFlag.get_flag(message);
        EntityInfo entity_info = stream_interactor.get_module<EntityInfo>(EntityInfo.IDENTITY);
        yield parse_server_references(account, message, new_message,
            mam_message_flag, entity_info);

        // Parse times
        if (mam_message_flag != null) new_message.local_time = mam_message_flag.server_time;
        DateTime? now_utc = new DateTime.now_utc();
        int64 now_epoch = (now_utc != null) ? now_utc.to_unix() : 0;
        DateTime now = new DateTime.from_unix_utc(now_epoch); // Remove milliseconds. They are not stored in the db and might lead to ordering issues when compared with times from the db.
        if (new_message.local_time == null || new_message.local_time.compare(now) > 0) new_message.local_time = now;

        Xep.DelayedDelivery.MessageFlag? delayed_message_flag = Xep.DelayedDelivery.MessageFlag.get_flag(message);
        if (delayed_message_flag != null) new_message.time = delayed_message_flag.datetime;
        if (new_message.time == null || new_message.time.compare(new_message.local_time) > 0) new_message.time = new_message.local_time;

        new_message.type_ = yield determine_message_type(account, message, new_message);

        // Parse occupant ids (in MUCs)
        if (message.type_ == Xmpp.MessageStanza.TYPE_GROUPCHAT) {
            bool muc_supports_occupant_ids = entity_info.has_feature_cached(account, message.from.bare_jid, Xmpp.Xep.OccupantIds.NS_URI);
            string? occupant_id = OccupantIds.get_occupant_id(message.stanza);
            if (muc_supports_occupant_ids && occupant_id != null) {
                new_message.occupant_db_id = stream_interactor.get_module<OccupantIdStore>(OccupantIdStore.IDENTITY).cache_occupant_id(account, occupant_id, message.from);
            }
        }

        return new_message;
    }

    private async void parse_server_references(Account account,
            Xmpp.MessageStanza stanza, Entities.Message message,
            Xmpp.MessageArchiveManagement.MessageFlag? mam_flag,
            EntityInfo entity_info) {
        string? mam_id = mam_flag != null
            ? normalized_id(((!) mam_flag).mam_id) : null;
        if (mam_id != null) message.server_id = (!) mam_id;

        Jid? authority = null;
        if (stanza.type_ == Xmpp.MessageStanza.TYPE_GROUPCHAT) {
            if (message.counterpart == null) return;
            authority = ((!) message.counterpart).bare_jid;
        } else if (stanza.type_ == Xmpp.MessageStanza.TYPE_CHAT) {
            authority = account.bare_jid;
        } else {
            return;
        }

        bool supports_sid = yield entity_info.has_feature(account,
            (!) authority, Xep.UniqueStableStanzaIDs.NS_URI);
        string? stanza_id = supports_sid ? normalized_id(
            Xep.UniqueStableStanzaIDs.get_stanza_id(stanza,
                (!) authority)) : null;
        Jid? mam_sender = mam_flag != null
            ? ((!) mam_flag).sender_jid : null;
        string? stable_id = select_authoritative_stable_id(stanza_id,
            supports_sid, mam_id, mam_sender, (!) authority);
        if (stable_id == null) return;

        if (mam_id == null) message.server_id = (!) stable_id;
        set_stable_reference(message, (!) stable_id, (!) authority);
    }

    internal static string? select_authoritative_stable_id(
            string? stanza_id, bool server_supports_sid, string? mam_id,
            Jid? mam_sender, Jid expected_authority) {
        string? normalized_stanza_id = normalized_id(stanza_id);
        if (server_supports_sid && normalized_stanza_id != null) {
            return normalized_stanza_id;
        }

        string? normalized_mam_id = normalized_id(mam_id);
        if (normalized_mam_id == null || mam_sender == null ||
                !((!) mam_sender).is_bare() ||
                !((!) mam_sender).equals(expected_authority)) {
            return null;
        }
        return normalized_mam_id;
    }

    private static void set_stable_reference(Entities.Message message,
            string id, Jid by) {
        message.set_stable_reference(id, by.bare_jid);
    }

    private static string? normalized_id(string? id) {
        if (id == null) return null;
        return ((!) id).strip().length > 0 ? (!) id : null;
    }

    internal static void assign_sender_ids(Entities.Message message,
            Xmpp.MessageStanza stanza) {
        message.sender_stanza_id = stanza.id;
        message.stanza_id = Xep.UniqueStableStanzaIDs.get_origin_id(stanza) ??
            stanza.id;
    }

    private async Entities.Message.Type determine_message_type(Account account, Xmpp.MessageStanza message_stanza, Entities.Message message) {
        if (message_stanza.type_ == Xmpp.MessageStanza.TYPE_GROUPCHAT) {
            return Entities.Message.Type.GROUPCHAT;
        }
        if (message_stanza.type_ == Xmpp.MessageStanza.TYPE_CHAT) {
            ConversationManager conversation_manager = stream_interactor.get_module<
                ConversationManager>(ConversationManager.IDENTITY);

            // A MUC PM and a stale normal chat can share the same bare room JID.
            // Preserve the full room/nick identity before considering that bare
            // CHAT, otherwise the reply is routed into room@conference and picks
            // up the account's normal-chat encryption setting.
            if (message.counterpart.is_full()) {
                Conversation? exact_pm = conversation_manager.get_conversation(
                    message.counterpart, account, Conversation.Type.GROUPCHAT_PM);
                if (exact_pm != null) return Entities.Message.Type.GROUPCHAT_PM;

                Conversation? room = conversation_manager.get_conversation(
                    message.counterpart.bare_jid, account,
                    Conversation.Type.GROUPCHAT);
                if (room != null) return Entities.Message.Type.GROUPCHAT_PM;

                bool has_muc_user_marker = message_stanza.stanza.get_subnode(
                    "x", "http://jabber.org/protocol/muc#user") != null;
                MucManager muc_manager = stream_interactor.get_module<MucManager>(
                    MucManager.IDENTITY);
                if (has_muc_user_marker && muc_manager.is_joined_or_joining(
                        message.counterpart.bare_jid, account)) {
                    return Entities.Message.Type.GROUPCHAT_PM;
                }
            }

            Conversation? chat = conversation_manager.get_conversation(
                message.counterpart.bare_jid, account, Conversation.Type.CHAT);
            if (chat != null) return Entities.Message.Type.CHAT;

            XmppStream? stream = stream_interactor.get_stream(account);
            if (stream != null) {
                Gee.Set<Xep.ServiceDiscovery.Identity>? identities = yield ((!) stream)
                    .get_module<Xep.ServiceDiscovery.Module>(
                        Xep.ServiceDiscovery.Module.IDENTITY)
                    .get_entity_identities((!) stream,
                        message.counterpart.bare_jid);
                if (identities != null) {
                    foreach (Xep.ServiceDiscovery.Identity identity in
                            (!) identities) {
                        if (identity.category ==
                                Xep.ServiceDiscovery.Identity.CATEGORY_CONFERENCE) {
                            return Entities.Message.Type.GROUPCHAT_PM;
                        }
                    }
                }
            }
        }
        return Entities.Message.Type.CHAT;
    }

    internal bool is_stable_id_duplicate(Entities.Message message, Xmpp.MessageStanza stanza, Conversation conversation, out bool has_stable_id) {
        Account account = conversation.account;
        has_stable_id = false;

        // Deduplicate by server_id
        if (message.server_id != null) {
            has_stable_id = true;
            QueryBuilder builder =  db.message.select()
                    .with(db.message.server_id, "=", message.server_id)
                    .with(db.message.counterpart_id, "=", db.get_jid_id(message.counterpart))
                    .with(db.message.account_id, "=", account.id)
                    .with(db.message.type_, "=", (int) message.type_);
            if (message.type_ == Message.Type.GROUPCHAT_PM) {
                if (message.counterpart.resourcepart != null) {
                    builder.with(db.message.counterpart_resource, "=",
                        message.counterpart.resourcepart);
                } else {
                    builder.with_null(db.message.counterpart_resource);
                }
            }

            // Room and account archives assign ids independently. A scalar
            // match cannot override contradictory authoritative references.
            if (message.stable_id != null && message.stable_id_by != null) {
                builder.where("(message.stable_id IS NULL OR message.stable_id_by IS NULL OR (message.stable_id = ? AND message.stable_id_by = ?))",
                    { (!) message.stable_id,
                      ((!) message.stable_id_by).to_string() });
            }

            // If the message is a duplicate
            var duplicate_ids = new ArrayList<int>();
            foreach (Row row in builder) {
                duplicate_ids.add(row[db.message.id]);
            }
            if (!duplicate_ids.is_empty) {
                history_sync.on_server_id_duplicate(account, stanza, message);
                if (duplicate_ids.size == 1) {
                    Entities.Message? canonical = stream_interactor
                        .get_module<MessageStorage>(MessageStorage.IDENTITY)
                        .get_message_by_id(duplicate_ids[0], conversation);
                    if (canonical != null) {
                        merge_wire_references((!) canonical, message,
                            conversation);
                        resolve_pending_replies_for_duplicate(stanza,
                            conversation, (!) canonical);
                    }
                }
                return true;
            }
        }

        // Deduplicate messages by uuid
        bool is_uuid = message.stanza_id != null && Regex.match_simple("""[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}""", message.stanza_id);
        if (is_uuid) {
            has_stable_id = true;
            QueryBuilder builder =  db.message.select()
                    .with(db.message.stanza_id, "=", message.stanza_id)
                    .with(db.message.counterpart_id, "=", db.get_jid_id(message.counterpart))
                    .with(db.message.account_id, "=", account.id)
                    .with(db.message.type_, "=", (int) message.type_);
            if (message.type_ == Message.Type.GROUPCHAT_PM) {
                if (message.counterpart.resourcepart != null) {
                    builder.with(db.message.counterpart_resource, "=",
                        message.counterpart.resourcepart);
                } else {
                    builder.with_null(db.message.counterpart_resource);
                }
            }
            if (message.direction == Message.DIRECTION_RECEIVED) {
                if (message.counterpart.resourcepart != null) {
                    builder.with(db.message.counterpart_resource, "=", message.counterpart.resourcepart);
                } else {
                    builder.with_null(db.message.counterpart_resource);
                }
            } else if (message.direction == Message.DIRECTION_SENT) {
                if (message.ourpart.resourcepart != null) {
                    builder.with(db.message.our_resource, "=", message.ourpart.resourcepart);
                } else {
                    builder.with_null(db.message.our_resource);
                }
            }
            var duplicate_ids = new ArrayList<int>();
            foreach (Row row in builder) {
                duplicate_ids.add(row[db.message.id]);
            }
            if (!duplicate_ids.is_empty) {
                if (duplicate_ids.size != 1) return true;
                Message? canonical_message = null;
                if (message.server_id != null) {
                    canonical_message = stream_interactor
                        .get_module<MessageStorage>(MessageStorage.IDENTITY)
                        .update_server_id(duplicate_ids[0], message.server_id,
                            conversation);
                } else {
                    canonical_message = stream_interactor
                        .get_module<MessageStorage>(MessageStorage.IDENTITY)
                        .get_message_by_id(duplicate_ids[0],
                            conversation);
                }
                if (canonical_message != null) {
                    merge_wire_references((!) canonical_message, message,
                        conversation);
                    resolve_pending_replies_for_duplicate(stanza,
                        conversation, (!) canonical_message);
                }
                return true;
            }
            return false;
        }
        return false;
    }

    private bool is_duplicate(Entities.Message message, Xmpp.MessageStanza stanza, Conversation conversation) {
        bool has_stable_id;
        if (is_stable_id_duplicate(message, stanza, conversation, out has_stable_id)) return true;
        if (has_stable_id) return false;

        Account account = conversation.account;

        // Deduplicate messages based on content and metadata
        QueryBuilder builder = db.message.select()
                .with(db.message.account_id, "=", account.id)
                .with(db.message.counterpart_id, "=", db.get_jid_id(message.counterpart))
                .with(db.message.type_, "=", (int) message.type_)
                .with(db.message.body, "=", message.body)
                .with(db.message.time, "<", (long) message.time.add_minutes(1).to_unix())
                .with(db.message.time, ">", (long) message.time.add_minutes(-1).to_unix());
        if (message.stanza_id != null) {
            builder.with(db.message.stanza_id, "=", message.stanza_id);
        } else {
            builder.with_null(db.message.stanza_id);
        }
        if (message.counterpart.resourcepart != null) {
            builder.with(db.message.counterpart_resource, "=", message.counterpart.resourcepart);
        } else {
            builder.with_null(db.message.counterpart_resource);
        }
        var duplicate_ids = new ArrayList<int>();
        foreach (Row row in builder) {
            duplicate_ids.add(row[db.message.id]);
        }
        bool duplicate = !duplicate_ids.is_empty;
        if (duplicate) {
            if (duplicate_ids.size == 1) {
                Entities.Message? canonical = stream_interactor
                    .get_module<MessageStorage>(MessageStorage.IDENTITY)
                    .get_message_by_id(duplicate_ids[0], conversation);
                if (canonical != null) {
                    merge_wire_references((!) canonical, message,
                        conversation);
                    resolve_pending_replies_for_duplicate(stanza,
                        conversation, (!) canonical);
                }
            }
        }
        return duplicate;
    }

    private void merge_wire_references(Entities.Message canonical,
            Entities.Message incoming, Conversation conversation) {
        MessageStorage storage = stream_interactor.get_module<MessageStorage>(
            MessageStorage.IDENTITY);
        if (incoming.sender_stanza_id != null) {
            storage.update_sender_stanza_id(canonical.id,
                (!) incoming.sender_stanza_id, conversation);
        }
        if (incoming.stable_id != null && incoming.stable_id_by != null) {
            storage.update_stable_reference(canonical.id,
                (!) incoming.stable_id, (!) incoming.stable_id_by,
                conversation);
        }
    }

    internal bool is_duplicate_for_tests(Entities.Message message,
            Xmpp.MessageStanza stanza, Conversation conversation) {
        return is_duplicate(message, stanza, conversation);
    }

    /**
     * A duplicate target stanza does not reach the later Replies listener.
     * Resolve raw XEP-0461 edges against the canonical stored message here,
     * especially after a MUC echo has just supplied its room stanza-id.
     */
    private void resolve_pending_replies_for_duplicate(
            Xmpp.MessageStanza stanza, Conversation conversation,
            Entities.Message canonical_message) {
        Replies? replies = stream_interactor.get_module<Replies>(
            Replies.IDENTITY);
        if (replies != null) {
            ((!) replies).process_duplicate_message(canonical_message, stanza,
                conversation);
        }
    }

    private class StableIdDeduplicateMessageListener : MessageListener {

        // A live MUC self-echo is both the delivery acknowledgement and a
        // stable-ID duplicate of the locally stored outgoing message. Let the
        // MUC listener advance the live object before duplicate processing
        // deliberately stops the remaining receive pipeline.
        public string[] after_actions_const = new string[]{ "MUC", "ARCHIVE_RETRACTION" };
        public override string action_group { get { return "DEDUPLICATE_STABLE"; } }
        public override string[] after_actions { get { return after_actions_const; } }

        private MessageProcessor outer;

        public StableIdDeduplicateMessageListener(MessageProcessor outer) {
            this.outer = outer;
        }

        public override async bool run(Entities.Message message, Xmpp.MessageStanza stanza, Conversation conversation) {
            bool has_stable_id;
            return outer.is_stable_id_duplicate(message, stanza, conversation, out has_stable_id);
        }
    }

    private class DeduplicateMessageListener : MessageListener {

        public string[] after_actions_const = new string[]{ "DEDUPLICATE_STABLE", "FILTER_EMPTY", "MUC" };
        public override string action_group { get { return "DEDUPLICATE"; } }
        public override string[] after_actions { get { return after_actions_const; } }

        private MessageProcessor outer;

        public DeduplicateMessageListener(MessageProcessor outer) {
            this.outer = outer;
        }

        public override async bool run(Entities.Message message, Xmpp.MessageStanza stanza, Conversation conversation) {
            return outer.is_duplicate(message, stanza, conversation);
        }
    }

    private class FilterMessageListener : MessageListener {

        public string[] after_actions_const = new string[]{ "DECRYPT", "DELETE" };
        public override string action_group { get { return "FILTER_EMPTY"; } }
        public override string[] after_actions { get { return after_actions_const; } }

        public override async bool run(Entities.Message message, Xmpp.MessageStanza stanza, Conversation conversation) {
            return message.body == null &&
                    Xep.StatelessFileSharing.get_file_shares(stanza) == null;
        }
    }

    private class EncryptionPolicyListener : MessageListener {

        public string[] after_actions_const = new string[]{ "DECRYPT" };
        public override string action_group { get { return "FILTER_ENCRYPTION_POLICY"; } }
        public override string[] after_actions { get { return after_actions_const; } }

        private MessageProcessor outer;

        public EncryptionPolicyListener(MessageProcessor outer) {
            this.outer = outer;
        }

        public override async bool run(Entities.Message message, Xmpp.MessageStanza stanza, Conversation conversation) {
            // Verified XEP-0374 history from this account's archive retains
            // its original protocol without changing the live selection.
            // Legacy PGP and MUC policies do not gain this exception.
            if (conversation.type_ == Conversation.Type.CHAT &&
                    message.account.id == conversation.account.id &&
                    message.account.equals(conversation.account) &&
                    message.encryption == Encryption.PGP &&
                    message.encryption_protocol == "openpgp:xep0374" &&
                    is_account_archive_message(conversation.account, stanza)) {
                return false;
            }
            string reason;
            if (!incoming_message_matches_conversation_encryption(message.encryption,
                    conversation.encryption, out reason, conversation.type_)) {
                // enter() starts room disco and self-presence in parallel. A
                // historical private-MUC stanza may decrypt after the join is
                // visible but before ConversationManager receives the room-
                // info result and restores the room's encryption mode. Join
                // the already-owned disco flight before enforcing the strict
                // policy; never infer room privacy from the ciphertext.
                yield outer.reconcile_pending_groupchat_encryption(
                    message, conversation);
            }
            if (!incoming_message_matches_conversation_encryption(message.encryption,
                    conversation.encryption, out reason, conversation.type_)) {
                warning("MessageProcessor: dropping incoming encrypted message because it does not match the conversation encryption mode: %s (stanza_id=%s, message_encryption=%d, conversation_encryption=%d)",
                        reason, message.stanza_id ?? "-", (int) message.encryption, (int) conversation.encryption);
                outer.send_encryption_policy_error(message, stanza, conversation);
                return true;
            }
            return false;
        }
    }

    internal async bool reconcile_pending_groupchat_encryption(
            Entities.Message message, Conversation conversation) {
        if (conversation.type_ != Conversation.Type.GROUPCHAT ||
                conversation.encryption != Encryption.NONE ||
                message.encryption == Encryption.NONE ||
                message.encryption == Encryption.UNKNOWN) {
            return false;
        }

        MucManager muc_manager = stream_interactor.get_module<MucManager>(
            MucManager.IDENTITY);
        if (!muc_manager.has_pending_muc_room_info(conversation.account,
                conversation.counterpart)) {
            return false;
        }

        bool room_info_ready = yield muc_manager
            .wait_for_pending_muc_room_info(conversation.account,
                conversation.counterpart);
        if (!room_info_ready) return false;

        string reason;
        return incoming_message_matches_conversation_encryption(
            message.encryption, conversation.encryption, out reason,
            conversation.type_);
    }

    private class MentionListener : MessageListener {

        public string[] after_actions_const = new string[]{ "DECRYPT", "FILTER_ENCRYPTION_POLICY" };
        public override string action_group { get { return "MENTION"; } }
        public override string[] after_actions { get { return after_actions_const; } }

        private StreamInteractor stream_interactor;

        public MentionListener(StreamInteractor stream_interactor) {
            this.stream_interactor = stream_interactor;
        }

        public override async bool run(Entities.Message message, Xmpp.MessageStanza stanza, Conversation conversation) {
            MessageMentions.classify(stream_interactor, conversation,
                message, stanza);
            return false;
        }
    }

    internal static bool archive_replay_is_outside_history_policy(
            Xmpp.MessageStanza stanza, Conversation conversation) {
        var mam_flag = Xmpp.MessageArchiveManagement.MessageFlag.get_flag(stanza);
        if (mam_flag == null || (conversation.history_cleared_at == null &&
                conversation.message_expiry_seconds <= 0)) return false;

        // Message parsing falls back to the current time if an archive time
        // is absent. That fallback must never bypass a user's deletion limit.
        DateTime? archive_time = mam_flag.server_time;
        if (archive_time == null) return true;
        if (conversation.history_cleared_at != null &&
                ((!) archive_time).compare((!) conversation.history_cleared_at) <= 0) {
            return true;
        }
        return conversation.message_expiry_seconds > 0 &&
            ((!) archive_time).compare(new DateTime.now_utc().add_seconds(
                -conversation.message_expiry_seconds)) < 0;
    }

    private class ClearedConversationFilterListener : MessageListener {
        private StreamInteractor stream_interactor;

        public ClearedConversationFilterListener(StreamInteractor stream_interactor) {
            this.stream_interactor = stream_interactor;
        }

        public string[] after_actions_const = new string[]{ "FILTER_EMPTY" };
        public override string action_group { get { return "FILTER_CLEARED"; } }
        public override string[] after_actions { get { return after_actions_const; } }

        public override async bool run(Entities.Message message, Xmpp.MessageStanza stanza, Conversation conversation) {
            // Keep the guard in the pipeline too: deletion settings may
            // change while earlier asynchronous listeners are running.
            return MessageProcessor.archive_replay_is_outside_history_policy(
                stanza, conversation);
        }
    }

    private class StoreMessageListener : MessageListener {

        public string[] after_actions_const = new string[]{ "DEDUPLICATE", "DECRYPT", "FILTER_EMPTY", "FILTER_ENCRYPTION_POLICY", "MENTION" };
        public override string action_group { get { return "STORE"; } }
        public override string[] after_actions { get { return after_actions_const; } }

        private MessageProcessor outer;
        private StreamInteractor stream_interactor;

        public StoreMessageListener(MessageProcessor outer, StreamInteractor stream_interactor) {
            this.outer = outer;
            this.stream_interactor = stream_interactor;
        }

        public override async bool run(Entities.Message message, Xmpp.MessageStanza stanza, Conversation conversation) {
            if (Xmpp.MessageArchiveManagement.MessageFlag.get_flag(stanza) !=
                    null && !outer.history_sync.is_account_ready(
                        message.account)) {
                warning("MAM: refusing to persist a partially processed archive message while required account state is unavailable (stanza_id=%s)",
                    message.stanza_id ?? "-");
                return true;
            }
            stream_interactor.get_module<MessageStorage>(MessageStorage.IDENTITY).add_message(message, conversation);
            return false;
        }
    }

    private class MarkupListener : MessageListener {

        public string[] after_actions_const = new string[]{ "STORE" };
        public override string action_group { get { return "Markup"; } }
        public override string[] after_actions { get { return after_actions_const; } }

        private StreamInteractor stream_interactor;

        public MarkupListener(StreamInteractor stream_interactor) {
            this.stream_interactor = stream_interactor;
        }

        public override async bool run(Entities.Message message, Xmpp.MessageStanza stanza, Conversation conversation) {
            Gee.List<MessageMarkup.Span> markups = MessageMarkup.get_spans(stanza);
            message.persist_markups(markups, message.id);
            return false;
        }
    }

    private class StoreContentItemListener : MessageListener {

        public string[] after_actions_const = new string[]{ "DEDUPLICATE", "DECRYPT", "FILTER_EMPTY", "FILTER_ENCRYPTION_POLICY", "STORE", "CORRECTION", "MESSAGE_REINTERPRETING", "MENTION" };
        public override string action_group { get { return "STORE_CONTENT_ITEM"; } }
        public override string[] after_actions { get { return after_actions_const; } }

        private StreamInteractor stream_interactor;

        public StoreContentItemListener(StreamInteractor stream_interactor) {
            this.stream_interactor = stream_interactor;
        }

        public override async bool run(Entities.Message message, Xmpp.MessageStanza stanza, Conversation conversation) {
            if (message.body == null) return true;
            stream_interactor.get_module<ContentItemStore>(ContentItemStore.IDENTITY).insert_message(message, conversation);
            return false;
        }
    }

    public Entities.Message create_out_message(string? text, Conversation conversation) {
        Entities.Message message = new Entities.Message(text);
        message.type_ = Util.get_message_type_for_conversation(conversation);
        message.stanza_id = random_uuid();
        message.sender_stanza_id = message.stanza_id;
        message.account = conversation.account;
        message.body = text;
        DateTime? now_utc_out = new DateTime.now_utc();
        int64 now_epoch_out = (now_utc_out != null) ? now_utc_out.to_unix() : 0;
        DateTime now = new DateTime.from_unix_utc(now_epoch_out); // Remove milliseconds. They are not stored in the db and might lead to ordering issues when compared with times from the db.
        message.time = now;
        message.local_time = now;
        message.direction = Entities.Message.DIRECTION_SENT;
        message.counterpart = conversation.counterpart;
        if (conversation.type_ == Conversation.Type.GROUPCHAT) {
            message.ourpart = stream_interactor.get_module<MucManager>(MucManager.IDENTITY).get_own_jid(conversation.counterpart, conversation.account) ?? conversation.account.bare_jid;
            message.real_jid = conversation.account.bare_jid;
        } else {
            message.ourpart = conversation.account.full_jid;
        }
        message.marked = Entities.Message.Marked.UNSENT;
        message.encryption = conversation.encryption;

        stream_interactor.get_module<MessageStorage>(MessageStorage.IDENTITY).add_message(message, conversation);

        return message;
    }

    internal bool add_reply_payload(Entities.Message message,
            MessageStanza stanza, Conversation conversation,
            out string error_text) {
        error_text = "";
        if (message.quoted_item_id == 0) return true;

        ContentItemStore content_item_store = stream_interactor
            .get_module<ContentItemStore>(ContentItemStore.IDENTITY);
        ContentItem? quoted_content_item = content_item_store.get_item_by_id(
            conversation, message.quoted_item_id);
        if (quoted_content_item == null) {
            error_text = "The replied-to message is no longer available.";
            return false;
        }

        string? quoted_stanza_id;
        Jid? quoted_sender;
        if (!content_item_store.try_get_message_reference_for_content_item(
                conversation, (!) quoted_content_item,
                out quoted_stanza_id, out quoted_sender)) {
            error_text = conversation.type_ == Conversation.Type.GROUPCHAT
                ? "The replied-to groupchat message has no room-assigned stanza ID yet."
                : "The replied-to message cannot be referenced safely.";
            return false;
        }

        // Keep persisted provenance and the wire payload on the exact same
        // protocol reference. This also repairs a transient pre-echo row when
        // the room stanza-id became available before a retry.
        message.set_quoted_item(((!) quoted_content_item).id,
            (!) quoted_stanza_id, (!) quoted_sender);
        Xep.Replies.set_reply_to(stanza, new Xep.Replies.ReplyTo(
            (!) quoted_sender, (!) quoted_stanza_id));

        foreach (var fallback in message.get_fallbacks()) {
            Xep.FallbackIndication.set_fallback(stanza, fallback);
        }
        return true;
    }

    public void send_xmpp_message(Entities.Message message, Conversation conversation, bool delayed = false) {
        message.marked = Entities.Message.Marked.SENDING;

        if (conversation.type_ == Conversation.Type.GROUPCHAT_PM) {
            string target_error;
            if (!validate_groupchat_pm_send_target(message, conversation, out target_error)) {
                debug("MessageProcessor: blocking private MUC message to stale or invalid occupant %s: %s",
                    message.counterpart != null ? ((!) message.counterpart).to_string() : "-",
                    target_error);
                message.delivery_error_text = target_error;
                message.marked = Entities.Message.Marked.ERROR;
                return;
            }
        }

        XmppStream stream = stream_interactor.get_stream(conversation.account);

        if (stream == null) {
            message.marked = Entities.Message.Marked.UNSENT;
            return;
        }

        MessageStanza new_message = new MessageStanza(message.stanza_id);
        new_message.to = message.counterpart;
        new_message.body = message.body;
        if (conversation.type_ == Conversation.Type.GROUPCHAT) {
            new_message.type_ = MessageStanza.TYPE_GROUPCHAT;
        } else {
            new_message.type_ = MessageStanza.TYPE_CHAT;
        }

        string reply_error;
        if (!add_reply_payload(message, new_message, conversation,
                out reply_error)) {
            message.delivery_error_text = reply_error;
            message.marked = Entities.Message.Marked.ERROR;
            return;
        }

        MessageMarkup.add_spans(new_message, message.get_markups());

        build_message_stanza(message, new_message, conversation);
        pre_message_send(message, new_message, conversation);
        if (message.marked == Entities.Message.Marked.UNSENT || message.marked == Entities.Message.Marked.WONTSEND) return;
        string encryption_guard_reason;
        if (!outgoing_stanza_matches_encryption(message.encryption, new_message, out encryption_guard_reason)) {
            warning("MessageProcessor: blocking outgoing stanza because encryption selection and payload differ: %s (stanza_id=%s, encryption=%d)",
                    encryption_guard_reason, message.stanza_id, (int) message.encryption);
            message.delivery_error_text = get_outgoing_encryption_error_text(message.encryption, encryption_guard_reason);
            message.marked = Entities.Message.Marked.ERROR;
            return;
        }
        if (delayed && message.time != null) {
            DelayedDelivery.Module.set_message_delay(new_message, message.time);
        }

        // Set an origin ID if a MUC doen't guarantee to keep IDs
        if (conversation.type_ == Conversation.Type.GROUPCHAT) {
            Xep.Muc.Flag? flag = stream.get_flag(Xep.Muc.Flag.IDENTITY);
            if (flag == null) {
                message.marked = Entities.Message.Marked.UNSENT;
                return;
            }
            if(!flag.has_room_feature(conversation.counterpart, Xep.Muc.Feature.STABLE_ID)) {
                UniqueStableStanzaIDs.set_origin_id(new_message, message.stanza_id);
            }
        }

        if (conversation.get_send_typing_setting(stream_interactor) == Conversation.Setting.ON) {
            ChatStateNotifications.add_state_to_message(new_message, ChatStateNotifications.STATE_ACTIVE);
        }

        debug("DEBUG: MessageProcessor: calling send_message.begin");
        stream.get_module<MessageModule>(MessageModule.IDENTITY).send_message.begin(stream, new_message, (_, res) => {
            try {
                stream.get_module<MessageModule>(MessageModule.IDENTITY).send_message.end(res);
                debug("DEBUG: MessageProcessor: send_message.end returned");
                debug("MessageProcessor: Message sent successfully (stanza_id: %s)", message.stanza_id);
                if (message.marked == Message.Marked.SENDING) {
                    message.marked = Message.Marked.SENT;
                }

                // The server might not have given us the resource we asked for. In that case, store the actual resource the message was sent with. Relevant for deduplication.
                Jid? current_own_jid = stream.get_flag(Bind.Flag.IDENTITY).my_jid;
                if (!conversation.type_.is_muc_semantic() && current_own_jid != null && !current_own_jid.equals(message.ourpart)) {
                    message.ourpart = current_own_jid;
                }
            } catch (IOError e) {
                warning("MessageProcessor: Failed to send message: %s", e.message);
                message.marked = Entities.Message.Marked.UNSENT;

                if (stream != stream_interactor.get_stream(conversation.account)) {
                    Timeout.add_seconds(3, () => {
                        send_unsent_chat_messages(conversation.account);
                        return false;
                    });
                }
            }
        });
    }

    private bool validate_groupchat_pm_send_target(Entities.Message message,
            Conversation conversation, out string error_text) {
        if (message.counterpart == null || !((!) message.counterpart).is_full() ||
                !conversation.counterpart.equals((!) message.counterpart)) {
            error_text = GROUPCHAT_PM_INVALID_TARGET_ERROR;
            return false;
        }

        return validate_groupchat_pm_conversation_target(conversation,
            out error_text);
    }

    // Compose/attachment controls need the same live occupant binding check
    // as the final send path, without duplicating its private error protocol.
    public bool is_groupchat_pm_send_target_valid(Conversation conversation) {
        string error_text;
        return validate_groupchat_pm_conversation_target(conversation, out error_text);
    }

    internal bool validate_groupchat_pm_conversation_target(
            Conversation conversation, out string error_text) {
        if (conversation.type_ != Conversation.Type.GROUPCHAT_PM ||
                !conversation.counterpart.is_full()) {
            error_text = GROUPCHAT_PM_INVALID_TARGET_ERROR;
            return false;
        }

        Jid target = conversation.counterpart;
        MucManager muc_manager = stream_interactor.get_module<MucManager>(
            MucManager.IDENTITY);
        if (!muc_manager.is_joined(target.bare_jid, conversation.account)) {
            error_text = GROUPCHAT_PM_NOT_JOINED_ERROR;
            return false;
        }

        string? current_peer_identity =
            muc_manager.get_private_message_peer_identity(
                conversation.account, target);
        if (current_peer_identity == null ||
                conversation.muc_pm_peer_identity == null ||
                !muc_manager.private_message_peer_identity_matches(
                    conversation.account, target,
                    (!) conversation.muc_pm_peer_identity)) {
            error_text = GROUPCHAT_PM_RECIPIENT_GONE_ERROR;
            return false;
        }

        Gee.List<Jid>? occupants = muc_manager.get_occupants(target.bare_jid,
            conversation.account);
        if (occupants == null || !((!) occupants).contains(target)) {
            error_text = GROUPCHAT_PM_RECIPIENT_GONE_ERROR;
            return false;
        }

        error_text = "";
        return true;
    }

    internal static void apply_delivery_error(Entities.Message message,
            Xmpp.ErrorStanza error_stanza) {
        // A normal one-to-one chat may still be stored for an offline recipient.
        // A MUC private-message target is an online room session and must surface
        // recipient-unavailable instead of looking successfully sent.
        if (message.type_ == Entities.Message.Type.CHAT &&
                error_stanza.condition == Xmpp.ErrorStanza.CONDITION_RECIPIENT_UNAVAILABLE &&
                error_stanza.type_ == Xmpp.ErrorStanza.TYPE_CANCEL) return;

        message.delivery_error_text = get_delivery_error_text(error_stanza);
        message.marked = Entities.Message.Marked.ERROR;
    }

    public static bool outgoing_stanza_matches_encryption(Encryption expected_encryption, MessageStanza stanza, out string reason) {
        bool has_omemo = stanza.stanza.get_subnode("encrypted", NS_OMEMO_LEGACY) != null ||
            stanza.stanza.get_subnode("encrypted", NS_OMEMO_2) != null;
        bool has_openpgp = stanza.stanza.get_subnode("openpgp", NS_OPENPGP) != null ||
            stanza.stanza.get_subnode("x", NS_OPENPGP_LEGACY) != null;

        if (has_omemo && has_openpgp) {
            reason = "stanza contains both OMEMO and OpenPGP encryption payloads";
            return false;
        }

        switch (expected_encryption) {
            case Encryption.NONE:
                if (has_omemo || has_openpgp) {
                    reason = "conversation is unencrypted but stanza contains encrypted payload";
                    return false;
                }
                reason = "";
                return true;
            case Encryption.PGP:
                if (!has_openpgp) {
                    reason = "OpenPGP was selected but stanza contains no OpenPGP payload";
                    return false;
                }
                reason = "";
                return true;
            case Encryption.OMEMO:
                if (!has_omemo) {
                    reason = "OMEMO was selected but stanza contains no OMEMO payload";
                    return false;
                }
                reason = "";
                return true;
            default:
                reason = "";
                return true;
        }
    }

    public static bool incoming_message_matches_conversation_encryption(
            Encryption message_encryption, Encryption conversation_encryption,
            out string reason, Conversation.Type? conversation_type = null) {
        if (message_encryption == Encryption.NONE || message_encryption == Encryption.UNKNOWN) {
            reason = "";
            return true;
        }

        // NONE selects plaintext for outgoing 1:1 messages. It must still
        // allow received content processed by the OMEMO/OpenPGP decryptors,
        // including OMEMO's safe local failure diagnostic. MUC policy and
        // explicitly selected encrypted modes remain strict.
        if (conversation_type == Conversation.Type.CHAT &&
                conversation_encryption == Encryption.NONE &&
                (message_encryption == Encryption.OMEMO ||
                 message_encryption == Encryption.PGP)) {
            reason = "";
            return true;
        }

        if (message_encryption != conversation_encryption) {
            reason = "incoming encrypted message uses %d but conversation expects %d".printf((int) message_encryption, (int) conversation_encryption);
            return false;
        }

        reason = "";
        return true;
    }

    public static bool is_account_archive_message(Account account,
            Xmpp.MessageStanza stanza) {
        // This flag is assigned by the MAM parser after query validation;
        // a delay element or Carbon alone is not archive provenance. Room
        // archives must not grant the exception for a direct conversation.
        var archive = Xmpp.MessageArchiveManagement.MessageFlag.get_flag(stanza);
        if (archive == null ||
                !archive.sender_jid.equals(account.bare_jid) ||
                stanza.from == null || stanza.to == null) {
            return false;
        }
        return stanza.from.equals_bare(account.bare_jid) ||
            stanza.to.equals_bare(account.bare_jid);
    }

    private void send_encryption_policy_error(Entities.Message message, MessageStanza incoming_stanza, Conversation conversation) {
        if (message.direction != Entities.Message.DIRECTION_RECEIVED) return;
        if (conversation.type_ != Conversation.Type.CHAT && conversation.type_ != Conversation.Type.GROUPCHAT_PM) return;
        if (incoming_stanza.from == null) return;

        XmppStream? stream = stream_interactor.get_stream(conversation.account);
        if (stream == null) return;

        MessageStanza error_message = new MessageStanza(incoming_stanza.id);
        error_message.to = incoming_stanza.from;
        error_message.type_ = Xmpp.Stanza.TYPE_ERROR;

        string text = get_incoming_encryption_error_text(conversation.encryption);
        StanzaNode app_condition = new StanzaNode.build("encryption-policy", NS_DINOX_ENCRYPTION_POLICY)
            .add_self_xmlns()
            .put_attribute("expected", encryption_protocol_name(conversation.encryption))
            .put_attribute("received", encryption_protocol_name(message.encryption));

        error_message.stanza.put_node(new Xmpp.ErrorStanza.build(
                Xmpp.ErrorStanza.TYPE_MODIFY,
                Xmpp.ErrorStanza.CONDITION_NOT_ACCEPTABLE,
                text,
                app_condition).error_node);

        stream.get_module<MessageModule>(MessageModule.IDENTITY).send_message.begin(stream, error_message, (_, res) => {
            try {
                stream.get_module<MessageModule>(MessageModule.IDENTITY).send_message.end(res);
            } catch (IOError e) {
                warning("MessageProcessor: failed to send encryption policy error for stanza=%s: %s", incoming_stanza.id ?? "-", e.message);
            }
        });
    }

    public static string get_delivery_error_text(Xmpp.ErrorStanza error_stanza) {
        StanzaNode? policy_node = error_stanza.error_node.get_subnode("encryption-policy", NS_DINOX_ENCRYPTION_POLICY);
        if (policy_node != null) {
            string expected = policy_node.get_attribute("expected", NS_DINOX_ENCRYPTION_POLICY) ?? policy_node.get_attribute("expected") ?? "unknown";
            return get_incoming_encryption_error_text(encryption_from_protocol_name(expected));
        }
        string? text = error_stanza.text;
        if (text != null && text != "") {
            return text;
        }
        return "Delivery failed. No reason was provided.";
    }

    private static string get_outgoing_encryption_error_text(Encryption expected_encryption, string reason) {
        switch (expected_encryption) {
            case Encryption.OMEMO:
                return "OMEMO is selected, but this message was not encrypted with OMEMO. Switch the chat encryption mode or send unencrypted.";
            case Encryption.PGP:
                return "OpenPGP is selected, but this message was not encrypted with OpenPGP. Switch the chat encryption mode or send unencrypted.";
            case Encryption.NONE:
                return "Unencrypted messages are selected, but this message still contains encrypted data. Switch the chat encryption mode before sending.";
            default:
                return reason != "" ? reason : "The message encryption mode does not match the outgoing payload.";
        }
    }

    private static string get_incoming_encryption_error_text(Encryption expected_encryption) {
        switch (expected_encryption) {
            case Encryption.OMEMO:
                return "The recipient is using OMEMO. Switch this chat to OMEMO or send unencrypted.";
            case Encryption.PGP:
                return "The recipient is using OpenPGP. Switch this chat to OpenPGP or send unencrypted.";
            case Encryption.NONE:
                return "The recipient is using unencrypted messages. Switch this chat to unencrypted.";
            default:
                return "The recipient uses a different encryption mode.";
        }
    }

    private static Encryption encryption_from_protocol_name(string protocol_name) {
        switch (protocol_name) {
            case "omemo":
                return Encryption.OMEMO;
            case "openpgp":
                return Encryption.PGP;
            case "none":
                return Encryption.NONE;
            default:
                return Encryption.UNKNOWN;
        }
    }

    private static string encryption_protocol_name(Encryption encryption) {
        switch (encryption) {
            case Encryption.NONE:
                return "none";
            case Encryption.PGP:
                return "openpgp";
            case Encryption.OMEMO:
                return "omemo";
            default:
                return "unknown";
        }
    }

}

public abstract class MessageListener : Xmpp.OrderedListener {

    public abstract async bool run(Entities.Message message, Xmpp.MessageStanza stanza, Conversation conversation);
}

internal delegate bool MessagePipelineAdmission(Entities.Message? message,
    Conversation? conversation);

internal class MessagePipelineGuard : Object {
    private StreamInteractor stream_interactor;
    private Account account;
    private XmppStream stream;
    private MessagePipelineAdmission? admission;
    public Entities.Message? message { get; set; default = null; }
    public Conversation? conversation { get; set; default = null; }

    public MessagePipelineGuard(StreamInteractor stream_interactor,
            Account account, XmppStream stream,
            owned MessagePipelineAdmission? admission = null) {
        this.stream_interactor = stream_interactor;
        this.account = account;
        this.stream = stream;
        this.admission = (owned) admission;
    }

    public bool is_current() {
        return stream_interactor.get_stream(account) == stream &&
            (admission == null || ((!) admission)(message, conversation));
    }
}

public class MessageListenerHolder : Xmpp.ListenerHolder {

    internal async bool run(Entities.Message message,
            Xmpp.MessageStanza stanza,
            Conversation conversation, MessagePipelineGuard? guard = null) {
        foreach (OrderedListener ol in listeners) {
            if (guard != null && !((!) guard).is_current()) return true;
            if (MessageProcessor.archive_replay_is_outside_history_policy(
                    stanza, conversation)) return true;
            MessageListener l = ol as MessageListener;
            bool stop = yield l.run(message, stanza, conversation);
            if (stop || l.action_group == "DECRYPT" || l.action_group == "STORE") {
                HistoryDiagnostics.received(stop ? "listener-stopped" : "listener-completed",
                    message, stanza, conversation, l.action_group);
            }
            if (stop) return true;
            if (guard != null && !((!) guard).is_current()) return true;
            // A clear/expiry setting can change while an earlier listener
            // awaits. Recheck before the next listener can decrypt or store.
            if (MessageProcessor.archive_replay_is_outside_history_policy(
                    stanza, conversation)) return true;
        }
        return false;
    }
}

}

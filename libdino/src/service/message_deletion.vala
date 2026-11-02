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

    public enum MessageDeletionGlobalMode {
        RETRACTION,
        MODERATION
    }

    public enum MessageDeletionItemStatus {
        SUCCEEDED,
        PREFLIGHT_REJECTED,
        REVALIDATION_REJECTED,
        DISPATCH_REJECTED,
        SERVER_REJECTED,
        CONTEXT_CHANGED,
        LOCAL_STATE_FAILED,
        NOT_ATTEMPTED
    }

    /**
     * Terminal result for one global-delete operation.
     *
     * XEP-0424 sending has no server acknowledgement, so a successful own
     * retraction reports dispatch_accepted=true and server_confirmed=null.
     * XEP-0425 moderation only succeeds after the room's IQ result and reports
     * server_confirmed=true.
     */
    public class MessageDeletionItemResult : Object {
        public ContentItem content_item { get; private set; }
        public int content_item_id { get; private set; }
        public MessageDeletionGlobalMode mode { get; private set; }
        public MessageDeletionItemStatus status { get; private set;
            default = MessageDeletionItemStatus.NOT_ATTEMPTED; }
        public bool success { get {
            return status == MessageDeletionItemStatus.SUCCEEDED;
        } }
        public bool preflight_eligible { get; private set; default = false; }
        public bool dispatch_attempted { get; private set; default = false; }
        public bool dispatch_accepted { get; private set; default = false; }
        // A nullable field is intentional here: XEP-0424 has no IQ result,
        // while XEP-0425 has a definite positive/negative confirmation.
        // Vala does not support nullable value types as GObject properties.
        public bool? server_confirmed = null;
        public bool locally_hidden { get; private set; default = false; }
        public int planned_request_count { get; private set; default = 0; }
        public int attempted_request_count { get; private set; default = 0; }
        public int accepted_request_count { get; private set; default = 0; }
        public int confirmed_request_count { get; private set; default = 0; }
        public bool partial_dispatch { get {
            return accepted_request_count > 0 &&
                accepted_request_count < planned_request_count;
        } }

        internal MessageDeletionItemResult(ContentItem content_item) {
            this.content_item = content_item;
            this.content_item_id = content_item.id;
            this.mode = ContentItem.is_own(content_item)
                ? MessageDeletionGlobalMode.RETRACTION
                : MessageDeletionGlobalMode.MODERATION;
        }

        internal void accept_preflight(MessageDeletionGlobalMode mode,
                int planned_request_count) {
            this.mode = mode;
            this.preflight_eligible = true;
            this.planned_request_count = planned_request_count;
        }

        internal void reject_preflight(bool locally_hidden = false) {
            this.locally_hidden = locally_hidden;
            status = MessageDeletionItemStatus.PREFLIGHT_REJECTED;
        }

        internal void reject_revalidation(bool locally_hidden = false) {
            this.locally_hidden = locally_hidden;
            status = MessageDeletionItemStatus.REVALIDATION_REJECTED;
        }

        internal void record_dispatch_attempt() {
            dispatch_attempted = true;
            attempted_request_count++;
        }

        internal void record_dispatch_accepted(bool confirmed) {
            accepted_request_count++;
            if (confirmed) confirmed_request_count++;
            dispatch_accepted =
                accepted_request_count == planned_request_count;
        }

        internal void record_server_confirmation(bool confirmed) {
            server_confirmed = confirmed;
        }

        internal void complete(bool locally_hidden) {
            this.locally_hidden = locally_hidden;
            status = locally_hidden
                ? MessageDeletionItemStatus.SUCCEEDED
                : MessageDeletionItemStatus.LOCAL_STATE_FAILED;
        }

        internal void fail(MessageDeletionItemStatus status,
                bool locally_hidden = false) {
            this.locally_hidden = locally_hidden;
            this.status = status;
        }
    }

    /** Summary for a caller-ordered, sequential global-delete snapshot. */
    public class MessageDeletionBatchResult : Object {
        public Gee.ArrayList<MessageDeletionItemResult> item_results {
            get; private set; default = new Gee.ArrayList<MessageDeletionItemResult>();
        }
        public bool preflight_passed { get; private set; default = false; }
        public bool success { get; private set; default = false; }
        public bool partial_success { get; private set; default = false; }
        public int requested_count { get; private set; default = 0; }
        public int succeeded_count { get; private set; default = 0; }
        public int failed_count { get; private set; default = 0; }
        public int not_attempted_count { get; private set; default = 0; }
        public int attempted_request_count { get; private set; default = 0; }
        public int accepted_request_count { get; private set; default = 0; }
        public int confirmed_request_count { get; private set; default = 0; }

        internal void add(MessageDeletionItemResult result) {
            item_results.add(result);
        }

        internal void finish(bool preflight_passed) {
            this.preflight_passed = preflight_passed;
            requested_count = item_results.size;
            succeeded_count = 0;
            failed_count = 0;
            not_attempted_count = 0;
            attempted_request_count = 0;
            accepted_request_count = 0;
            confirmed_request_count = 0;

            foreach (MessageDeletionItemResult result in item_results) {
                attempted_request_count += result.attempted_request_count;
                accepted_request_count += result.accepted_request_count;
                confirmed_request_count += result.confirmed_request_count;
                if (result.success) {
                    succeeded_count++;
                } else if (result.status ==
                        MessageDeletionItemStatus.NOT_ATTEMPTED) {
                    not_attempted_count++;
                } else {
                    failed_count++;
                }
            }

            success = preflight_passed &&
                succeeded_count == requested_count;
            // Protocol progress can be partial inside one logical ContentItem,
            // for example when revision one was written but revision two
            // failed. Do not require a fully completed item to report that.
            partial_success = !success &&
                (succeeded_count > 0 || accepted_request_count > 0);
        }
    }

    private class MessageDeletionWriteWaiter : Object {
        private Entities.Message message;
        private SourceFunc? resume_callback = null;
        private ulong notify_handler_id = 0;
        private bool accepted = false;
        private bool completed = false;

        public MessageDeletionWriteWaiter(Entities.Message message) {
            this.message = message;
        }

        private static bool marked_is_accepted(Entities.Message.Marked marked) {
            return marked == Entities.Message.Marked.SENT ||
                marked == Entities.Message.Marked.ACKNOWLEDGED ||
                marked == Entities.Message.Marked.RECEIVED ||
                marked == Entities.Message.Marked.READ;
        }

        private static bool marked_is_rejected(Entities.Message.Marked marked) {
            return marked == Entities.Message.Marked.UNSENT ||
                marked == Entities.Message.Marked.WONTSEND ||
                marked == Entities.Message.Marked.ERROR;
        }

        private bool terminal(out bool accepted) {
            accepted = marked_is_accepted(message.marked);
            return accepted || marked_is_rejected(message.marked);
        }

        private void complete_if_terminal() {
            bool terminal_accepted = false;
            if (completed || !terminal(out terminal_accepted)) return;
            completed = true;
            accepted = terminal_accepted;
            if (notify_handler_id != 0 && GLib.SignalHandler.is_connected(
                    message, notify_handler_id)) {
                GLib.SignalHandler.disconnect(message, notify_handler_id);
                notify_handler_id = 0;
            }
            Idle.add(() => {
                SourceFunc? callback = (owned) resume_callback;
                if (callback != null) ((!) callback)();
                return Source.REMOVE;
            });
        }

        public async bool wait() {
            bool terminal_accepted = false;
            if (terminal(out terminal_accepted)) return terminal_accepted;

            resume_callback = wait.callback;
            notify_handler_id = message.notify["marked"].connect(() => {
                complete_if_terminal();
            });
            // Close the check/connect race without assuming the write callback
            // is deferred; test streams and local failures may settle inline.
            complete_if_terminal();
            yield;
            return accepted;
        }
    }

    private class MessageDeletionGlobalPlan : Object {
        public int content_item_id { get; private set; }
        public int conversation_id { get; private set; }
        public int content_type { get; private set; }
        public int foreign_id { get; private set; }
        public int backing_message_id { get; private set; }
        public MessageDeletionGlobalMode mode { get; private set; }
        public XmppStream stream { get; private set; }
        public Gee.ArrayList<string> reference_ids { get; private set;
            default = new Gee.ArrayList<string>(); }

        public MessageDeletionGlobalPlan(int content_item_id,
                int conversation_id, int content_type, int foreign_id,
                int backing_message_id, MessageDeletionGlobalMode mode,
                XmppStream stream, Gee.Iterable<string> reference_ids) {
            this.content_item_id = content_item_id;
            this.conversation_id = conversation_id;
            this.content_type = content_type;
            this.foreign_id = foreign_id;
            this.backing_message_id = backing_message_id;
            this.mode = mode;
            this.stream = stream;
            foreach (string reference_id in reference_ids) {
                this.reference_ids.add(reference_id);
            }
        }
    }

    public class MessageDeletion : StreamInteractionModule, MessageListener {
        public static ModuleIdentity<MessageDeletion> IDENTITY = new ModuleIdentity<MessageDeletion>("message_deletion");
        public string id { get { return IDENTITY.id; } }

        public signal void item_deleted(ContentItem content_item);

        private StreamInteractor stream_interactor;
        private Database db;

        public static void start(StreamInteractor stream_interactor, Database db) {
            MessageDeletion m = new MessageDeletion(stream_interactor, db);
            stream_interactor.add_module(m);
        }

        public MessageDeletion(StreamInteractor stream_interactor, Database db) {
            this.stream_interactor = stream_interactor;
            this.db = db;

            stream_interactor.get_module<MessageProcessor>(MessageProcessor.IDENTITY).received_pipeline.connect(this);
            
            // Start timer for auto-deleting expired messages (every 5 minutes)
            Timeout.add_seconds(60 * 5, check_expired_messages);
        }

        public bool is_deletable(Conversation conversation, ContentItem content_item) {
            if (content_item is MessageItem) {
                return ((MessageItem) content_item).message.body != "";
            } else if (content_item is FileItem) {
                return true;
            }
            return false;
        }

        public bool can_delete_for_everyone(Conversation conversation, ContentItem content_item) {
            MessageDeletionGlobalPlan? plan;
            return try_build_global_delete_plan(conversation, content_item,
                out plan);
        }

        internal static string? get_retraction_reference_id(Conversation.Type conversation_type, Message message) {
            // XEP-0424 requires groupchat retractions to reference the stable
            // stanza-id assigned by the room. Origin/message IDs remain the
            // correct reference for 1:1 chats and private MUC messages.
            if (conversation_type == Conversation.Type.GROUPCHAT &&
                    message.server_id != null && message.server_id.strip().length > 0) {
                return message.server_id;
            }

            // Every XEP-0308 correction is a separate physical message with
            // its own sender-assigned stanza/origin ID. edit_to identifies the
            // chain root and must never be used as this revision's retraction
            // target.
            if (message.stanza_id != null &&
                    message.stanza_id.strip().length > 0) {
                return message.stanza_id;
            }

            return null;
        }

        internal static bool try_get_complete_retraction_reference_ids(
                Conversation.Type conversation_type,
                bool require_groupchat_server_ids,
                Gee.Iterable<Message> revisions,
                out Gee.List<string> reference_ids) {
            reference_ids = new ArrayList<string>();
            var seen_reference_ids = new HashSet<string>();

            foreach (Message revision in revisions) {
                string? reference_id = null;
                if (conversation_type == Conversation.Type.GROUPCHAT &&
                        require_groupchat_server_ids) {
                    if (revision.server_id != null &&
                            revision.server_id.strip().length > 0) {
                        reference_id = revision.server_id;
                    }
                } else {
                    reference_id = get_retraction_reference_id(
                        conversation_type, revision);
                }

                if (reference_id == null ||
                        ((!) reference_id).strip().length == 0 ||
                        seen_reference_ids.contains((!) reference_id)) {
                    reference_ids.clear();
                    return false;
                }

                seen_reference_ids.add((!) reference_id);
                reference_ids.add((!) reference_id);
            }
            return !reference_ids.is_empty;
        }

        internal static bool groupchat_requires_server_ids(
                bool has_current_room_features,
                bool advertises_stable_ids) {
            // An origin-id fallback is permitted only after a complete,
            // current disco response has proven that neither XEP-0359 nor
            // the historical MUC stable-id feature is advertised.
            return !has_current_room_features || advertises_stable_ids;
        }

        private bool room_requires_server_ids(Conversation conversation) {
            if (conversation.type_ != Conversation.Type.GROUPCHAT)
                return false;

            XmppStream? stream = stream_interactor.get_stream(
                conversation.account);
            if (stream == null) return true;

            Xep.Muc.Flag? flag = ((!) stream).get_flag(Xep.Muc.Flag.IDENTITY);
            bool current = flag != null && ((!) flag)
                .has_current_room_features(conversation.counterpart);
            bool advertises_stable_ids = flag != null && ((!) flag)
                .has_room_feature(conversation.counterpart,
                    Xep.Muc.Feature.STABLE_ID);
            return groupchat_requires_server_ids(current,
                advertises_stable_ids);
        }

        private bool try_get_complete_global_ids(Conversation conversation,
                ContentItem content_item, bool moderation,
                out Gee.List<string> reference_ids,
                out int backing_message_id) {
            reference_ids = new ArrayList<string>();
            backing_message_id = -1;
            if (stream_interactor.get_stream(conversation.account) == null)
                return false;
            if (content_item is FileItem &&
                    ((FileItem) content_item).file_transfer
                        .resolve_message_db_id() <= 0)
                return false;
            if (conversation.type_ == Conversation.Type.GROUPCHAT_PM) {
                string target_error;
                if (!stream_interactor.get_module<MessageProcessor>(
                        MessageProcessor.IDENTITY)
                        .validate_groupchat_pm_conversation_target(
                            conversation, out target_error)) {
                    return false;
                }
            }
            Message? referenced_message = stream_interactor
                .get_module<ContentItemStore>(ContentItemStore.IDENTITY)
                .get_message_for_content_item(conversation, content_item,
                    true);
            if (referenced_message == null) return false;
            backing_message_id = ((!) referenced_message).id;

            Gee.List<Message> revisions = stream_interactor
                .get_module<MessageStorage>(MessageStorage.IDENTITY)
                .get_revision_chain(conversation, (!) referenced_message,
                    true, true);
            // XEP-0425 confirms each physical room stanza independently and
            // reflects successful removals immediately. Without a protocol
            // batch transaction, a partially accepted correction chain cannot
            // be represented atomically in our one-row conversation model.
            // Keep moderation honest and fail closed for edited foreign
            // messages; own XEP-0424 retractions still cover every revision.
            if (moderation && revisions.size != 1) return false;
            bool require_server_ids = moderation ||
                room_requires_server_ids(conversation);
            return try_get_complete_retraction_reference_ids(
                conversation.type_, require_server_ids, revisions,
                out reference_ids);
        }

        private bool has_moderation_permission(Conversation conversation) {
            // XEP-0425 moderation is a groupchat operation. A private MUC
            // message is type='chat' and must retain normal local-delete
            // semantics for messages from other occupants.
            if (conversation.type_ != Conversation.Type.GROUPCHAT) return false;

            bool muc_supports_moderation = stream_interactor
                .get_module<EntityInfo>(EntityInfo.IDENTITY)
                .has_feature_offline(conversation.account,
                    conversation.counterpart,
                    Xmpp.Xep.MessageModeration.NS_URI);
            bool we_are_moderator = stream_interactor
                .get_module<MucManager>(MucManager.IDENTITY)
                .get_own_role(conversation) == Xmpp.Xep.Muc.Role.MODERATOR;
            return muc_supports_moderation && we_are_moderator;
        }

        private bool try_get_content_item_row_state(Conversation conversation,
                ContentItem content_item, out int content_type,
                out int foreign_id, out bool hidden) {
            content_type = -1;
            foreign_id = -1;
            hidden = false;
            RowOption row = db.content_item.select({
                    db.content_item.conversation_id,
                    db.content_item.content_type,
                    db.content_item.foreign_id,
                    db.content_item.hide
                })
                .with(db.content_item.id, "=", content_item.id)
                .single().row();
            if (!row.is_present() ||
                    row[db.content_item.conversation_id] != conversation.id) {
                return false;
            }

            content_type = row[db.content_item.content_type];
            foreign_id = row[db.content_item.foreign_id];
            hidden = row[db.content_item.hide];
            if (content_item is MessageItem) {
                return content_type == 1 &&
                    ((MessageItem) content_item).message.id == foreign_id;
            }
            if (content_item is FileItem) {
                return content_type == 2 &&
                    ((FileItem) content_item).file_transfer.id == foreign_id;
            }
            return false;
        }

        private bool content_item_row_matches_plan(Conversation conversation,
                ContentItem content_item, MessageDeletionGlobalPlan plan,
                out bool hidden) {
            int content_type;
            int foreign_id;
            if (!try_get_content_item_row_state(conversation, content_item,
                    out content_type, out foreign_id, out hidden)) {
                return false;
            }
            return content_item.id == plan.content_item_id &&
                conversation.id == plan.conversation_id &&
                content_type == plan.content_type &&
                foreign_id == plan.foreign_id;
        }

        private bool content_item_is_hidden(Conversation conversation,
                ContentItem content_item) {
            RowOption row = db.content_item.select({
                    db.content_item.conversation_id,
                    db.content_item.hide
                })
                .with(db.content_item.id, "=", content_item.id)
                .single().row();
            return row.is_present() &&
                row[db.content_item.conversation_id] == conversation.id &&
                row[db.content_item.hide];
        }

        private bool try_build_global_delete_plan(Conversation conversation,
                ContentItem content_item,
                out MessageDeletionGlobalPlan? plan,
                bool allow_hidden = false) {
            plan = null;
            int content_type;
            int foreign_id;
            bool hidden;
            if (!try_get_content_item_row_state(conversation, content_item,
                    out content_type, out foreign_id, out hidden) ||
                    (hidden && !allow_hidden)) {
                return false;
            }

            ContentItem? persisted_item = stream_interactor
                .get_module<ContentItemStore>(ContentItemStore.IDENTITY)
                .get_persisted_item_by_id(conversation, content_item.id);
            if (persisted_item == null) return false;
            int persisted_content_type;
            int persisted_foreign_id;
            bool persisted_hidden;
            if (!try_get_content_item_row_state(conversation,
                    (!) persisted_item, out persisted_content_type,
                    out persisted_foreign_id, out persisted_hidden) ||
                    persisted_content_type != content_type ||
                    persisted_foreign_id != foreign_id ||
                    persisted_hidden != hidden ||
                    (!hidden && !is_deletable(conversation,
                        (!) persisted_item))) {
                return false;
            }

            XmppStream? stream = stream_interactor.get_stream(
                conversation.account);
            if (stream == null) return false;

            bool own_message = ContentItem.is_own((!) persisted_item);
            if (!own_message && !has_moderation_permission(conversation)) {
                return false;
            }

            Gee.List<string> reference_ids;
            int backing_message_id;
            if (!try_get_complete_global_ids(conversation,
                    (!) persisted_item, !own_message, out reference_ids,
                    out backing_message_id)) {
                return false;
            }

            plan = new MessageDeletionGlobalPlan(
                content_item.id, conversation.id, content_type, foreign_id,
                backing_message_id,
                own_message ? MessageDeletionGlobalMode.RETRACTION
                    : MessageDeletionGlobalMode.MODERATION,
                (!) stream, reference_ids);
            return true;
        }

        private bool revalidate_global_delete_plan(Conversation conversation,
                ContentItem content_item, MessageDeletionGlobalPlan expected,
                out bool hidden) {
            hidden = false;
            MessageDeletionGlobalPlan? current;
            if (!try_build_global_delete_plan(conversation, content_item,
                    out current, true) ||
                    !global_delete_plans_match(expected, (!) current)) {
                // Preserve the local visibility bit even when another plan
                // field changed, so the result remains causally descriptive.
                int content_type;
                int foreign_id;
                try_get_content_item_row_state(conversation, content_item,
                    out content_type, out foreign_id, out hidden);
                return false;
            }
            int content_type;
            int foreign_id;
            return try_get_content_item_row_state(conversation, content_item,
                out content_type, out foreign_id, out hidden);
        }

        private static bool global_delete_plans_match(
                MessageDeletionGlobalPlan expected,
                MessageDeletionGlobalPlan current) {
            if (expected.content_item_id != current.content_item_id ||
                    expected.conversation_id != current.conversation_id ||
                    expected.content_type != current.content_type ||
                    expected.foreign_id != current.foreign_id ||
                    expected.backing_message_id !=
                        current.backing_message_id ||
                    expected.mode != current.mode ||
                    expected.stream != current.stream ||
                    expected.reference_ids.size != current.reference_ids.size) {
                return false;
            }
            for (int i = 0; i < expected.reference_ids.size; i++) {
                if (expected.reference_ids[i] != current.reference_ids[i]) {
                    return false;
                }
            }
            return true;
        }

        private bool delete_persisted_item_locally(
                Conversation conversation, MessageDeletionGlobalPlan plan) {
            ContentItem? persisted_item = stream_interactor
                .get_module<ContentItemStore>(ContentItemStore.IDENTITY)
                .get_persisted_item_by_id(conversation,
                    plan.content_item_id);
            if (persisted_item == null) return false;

            int content_type;
            int foreign_id;
            bool hidden;
            if (!try_get_content_item_row_state(conversation,
                    (!) persisted_item, out content_type, out foreign_id,
                    out hidden) || content_type != plan.content_type ||
                    foreign_id != plan.foreign_id) {
                return false;
            }
            if (hidden) return true;

            delete_locally(conversation, (!) persisted_item,
                conversation.account.bare_jid);
            return content_item_is_hidden(conversation, (!) persisted_item);
        }

        private async void execute_global_delete_plan(
                Conversation conversation, ContentItem content_item,
                MessageDeletionGlobalPlan plan,
                MessageDeletionItemResult result) {
            if (plan.mode == MessageDeletionGlobalMode.RETRACTION) {
                foreach (string retraction_id in plan.reference_ids) {
                    bool hidden = false;
                    if (stream_interactor.get_stream(conversation.account) !=
                            plan.stream ||
                            !content_item_row_matches_plan(conversation,
                                content_item, plan, out hidden)) {
                        result.fail(MessageDeletionItemStatus.CONTEXT_CHANGED,
                            hidden);
                        return;
                    }
                    result.record_dispatch_attempt();
                    bool write_accepted = yield send_retraction_terminal(
                        conversation, retraction_id);
                    if (write_accepted) {
                        result.record_dispatch_accepted(false);
                    }

                    if (stream_interactor.get_stream(conversation.account) !=
                            plan.stream ||
                            !revalidate_global_delete_plan(conversation,
                                content_item, plan, out hidden)) {
                        result.fail(MessageDeletionItemStatus.CONTEXT_CHANGED,
                            hidden);
                        return;
                    }
                    if (!write_accepted) {
                        result.fail(
                            MessageDeletionItemStatus.DISPATCH_REJECTED,
                            hidden);
                        return;
                    }
                }

                bool hidden = false;
                if (stream_interactor.get_stream(conversation.account) !=
                        plan.stream ||
                        !revalidate_global_delete_plan(conversation,
                            content_item, plan, out hidden)) {
                    result.fail(MessageDeletionItemStatus.CONTEXT_CHANGED,
                        hidden);
                    return;
                }
                if (hidden) {
                    result.complete(true);
                    return;
                }
                result.complete(delete_persisted_item_locally(conversation,
                    plan));
                return;
            }

            result.record_server_confirmation(true);
            foreach (string moderation_id in plan.reference_ids) {
                result.record_dispatch_attempt();
                bool confirmed = yield Xmpp.Xep.MessageModeration.moderate(
                    plan.stream, conversation.counterpart, moderation_id);
                if (confirmed) result.record_dispatch_accepted(true);

                bool hidden = false;
                if (stream_interactor.get_stream(conversation.account) !=
                        plan.stream ||
                        !revalidate_global_delete_plan(conversation,
                            content_item, plan, out hidden)) {
                    result.fail(MessageDeletionItemStatus.CONTEXT_CHANGED,
                        hidden);
                    return;
                }
                if (!confirmed) {
                    result.record_server_confirmation(false);
                    result.fail(MessageDeletionItemStatus.SERVER_REJECTED,
                        hidden);
                    return;
                }
            }

            // A successful IQ result belongs to the stream on which the room
            // accepted it. Do not apply its local side effect to a replacement
            // account session.
            if (stream_interactor.get_stream(conversation.account) !=
                    plan.stream) {
                result.fail(MessageDeletionItemStatus.CONTEXT_CHANGED,
                    content_item_is_hidden(conversation, content_item));
                return;
            }

            bool hidden = false;
            if (!revalidate_global_delete_plan(conversation, content_item,
                    plan, out hidden)) {
                result.fail(MessageDeletionItemStatus.CONTEXT_CHANGED,
                    hidden);
                return;
            }
            // A reflected moderation may have hidden the same immutable row
            // before the IQ result resumed this coroutine.
            if (hidden) {
                result.complete(true);
                return;
            }

            result.complete(delete_persisted_item_locally(conversation,
                plan));
        }

        /**
         * Globally delete one item and return its terminal protocol result.
         *
         * Own XEP-0424 retractions complete when every control stanza's actual
         * asynchronous stream write completed. Foreign XEP-0425 moderation
         * completes only after the room returned a successful IQ result.
         */
        public async MessageDeletionItemResult delete_globally_detailed(
                Conversation conversation, ContentItem content_item) {
            var result = new MessageDeletionItemResult(content_item);
            MessageDeletionGlobalPlan? plan;
            if (!try_build_global_delete_plan(conversation, content_item,
                    out plan)) {
                result.reject_preflight(content_item_is_hidden(conversation,
                    content_item));
                return result;
            }

            result.accept_preflight(((!) plan).mode,
                ((!) plan).reference_ids.size);
            yield execute_global_delete_plan(conversation, content_item,
                (!) plan, result);
            return result;
        }

        /**
         * Execute a caller-ordered snapshot sequentially.
         *
         * Callers place replies first and the root last. The order is copied
         * and preserved. Every item is preflighted before the first dispatch;
         * any initially unsuitable or duplicate item aborts with zero network
         * side effects. Each plan is then rebuilt immediately before its turn,
         * and processing stops on the first failure so the unattempted root is
         * never removed after a reply failure.
         */
        public async MessageDeletionBatchResult
                delete_globally_batch_detailed(Conversation conversation,
                    Gee.List<ContentItem> ordered_snapshot) {
            return yield execute_global_delete_batch(conversation,
                ordered_snapshot, null);
        }

        private async MessageDeletionBatchResult execute_global_delete_batch(
                Conversation conversation,
                Gee.List<ContentItem> ordered_snapshot,
                ContentItem? direct_reply_root_guard) {
            var snapshot = new ArrayList<ContentItem>();
            foreach (ContentItem content_item in ordered_snapshot) {
                snapshot.add(content_item);
            }

            var batch_result = new MessageDeletionBatchResult();
            if (snapshot.is_empty) {
                batch_result.finish(false);
                return batch_result;
            }
            var preflight_plans =
                new ArrayList<MessageDeletionGlobalPlan?>();
            var seen_content_item_ids = new HashSet<int>();
            bool preflight_passed = true;

            foreach (ContentItem content_item in snapshot) {
                var item_result = new MessageDeletionItemResult(content_item);
                batch_result.add(item_result);

                MessageDeletionGlobalPlan? plan = null;
                bool unique = content_item.id >= 0 &&
                    !seen_content_item_ids.contains(content_item.id);
                if (unique) seen_content_item_ids.add(content_item.id);
                if (!unique || !try_build_global_delete_plan(conversation,
                        content_item, out plan)) {
                    item_result.reject_preflight(content_item_is_hidden(
                        conversation, content_item));
                    preflight_plans.add(null);
                    preflight_passed = false;
                    continue;
                }

                item_result.accept_preflight(((!) plan).mode,
                    ((!) plan).reference_ids.size);
                preflight_plans.add(plan);
            }

            if (!preflight_passed) {
                batch_result.finish(false);
                return batch_result;
            }

            for (int i = 0; i < snapshot.size; i++) {
                ContentItem content_item = snapshot[i];
                MessageDeletionItemResult item_result =
                    batch_result.item_results[i];

                if (direct_reply_root_guard != null &&
                        i == snapshot.size - 1 &&
                        content_item.id == ((!) direct_reply_root_guard).id) {
                    // Replies already hidden by this batch can still receive
                    // a correction while a later IQ/write is pending. Rebuild
                    // every completed reply plan with hidden rows allowed;
                    // any new physical revision must stop before the root.
                    for (int reply_index = 0; reply_index < i;
                            reply_index++) {
                        MessageDeletionGlobalPlan? completed_reply_plan;
                        if (!try_build_global_delete_plan(conversation,
                                snapshot[reply_index],
                                out completed_reply_plan, true) ||
                                !global_delete_plans_match(
                                    (!) preflight_plans[reply_index],
                                    (!) completed_reply_plan)) {
                            MessageDeletionItemResult completed_reply_result =
                                batch_result.item_results[reply_index];
                            completed_reply_result.fail(
                                MessageDeletionItemStatus.REVALIDATION_REJECTED,
                                content_item_is_hidden(conversation,
                                    snapshot[reply_index]));
                            batch_result.finish(true);
                            return batch_result;
                        }
                    }
                    Replies? replies_module = stream_interactor
                        .get_module<Replies>(Replies.IDENTITY);
                    if (replies_module == null ||
                            !((!) replies_module).get_direct_replies(
                                conversation,
                                (!) direct_reply_root_guard).is_empty) {
                        item_result.reject_revalidation(
                            content_item_is_hidden(conversation,
                                content_item));
                        batch_result.finish(true);
                        return batch_result;
                    }
                }

                MessageDeletionGlobalPlan expected_plan =
                    (!) preflight_plans[i];
                MessageDeletionGlobalPlan? current_plan;
                if (!try_build_global_delete_plan(conversation, content_item,
                        out current_plan) ||
                        !global_delete_plans_match(expected_plan,
                            (!) current_plan)) {
                    item_result.reject_revalidation(content_item_is_hidden(
                        conversation, content_item));
                    batch_result.finish(true);
                    return batch_result;
                }

                yield execute_global_delete_plan(conversation, content_item,
                    (!) current_plan, item_result);
                if (!item_result.success) {
                    batch_result.finish(true);
                    return batch_result;
                }
            }

            batch_result.finish(true);
            return batch_result;
        }

        private MessageDeletionBatchResult reject_root_last_snapshot(
                Conversation conversation,
                Gee.List<ContentItem> snapshot) {
            var result = new MessageDeletionBatchResult();
            for (int i = 0; i < snapshot.size; i++) {
                var item_result = new MessageDeletionItemResult(snapshot[i]);
                result.add(item_result);
                // The root carries a relationship/order preflight failure;
                // preceding replies truthfully remain unattempted.
                if (i == snapshot.size - 1) {
                    item_result.reject_preflight(content_item_is_hidden(
                        conversation, snapshot[i]));
                }
            }
            result.finish(false);
            return result;
        }

        /**
         * Production-safe direct-reply batch entry point.
         *
         * The service, rather than the UI, appends the root last. The supplied
         * reply snapshot must exactly match the currently visible direct-reply
         * snapshot (including its deterministic order), and duplicate/root IDs
         * are rejected before any network dispatch.
         */
        public async MessageDeletionBatchResult
                delete_globally_with_replies_detailed(
                    Conversation conversation,
                    Gee.List<ContentItem> direct_replies_snapshot,
                    ContentItem root) {
            var ordered_snapshot = new ArrayList<ContentItem>();
            var seen_content_item_ids = new HashSet<int>();
            bool snapshot_valid = root.id >= 0;

            foreach (ContentItem reply in direct_replies_snapshot) {
                if (reply.id < 0 || reply.id == root.id ||
                        seen_content_item_ids.contains(reply.id)) {
                    snapshot_valid = false;
                } else {
                    seen_content_item_ids.add(reply.id);
                }
                ordered_snapshot.add(reply);
            }
            if (seen_content_item_ids.contains(root.id)) snapshot_valid = false;
            ordered_snapshot.add(root);

            Replies? replies_module = stream_interactor.get_module<Replies>(
                Replies.IDENTITY);
            if (replies_module == null) {
                snapshot_valid = false;
            } else if (!((!) replies_module).direct_reply_snapshot_matches(
                    conversation, root, direct_replies_snapshot)) {
                snapshot_valid = false;
            }

            if (!snapshot_valid) {
                return reject_root_last_snapshot(conversation,
                    ordered_snapshot);
            }
            return yield execute_global_delete_batch(conversation,
                ordered_snapshot, root);
        }

        public bool delete_globally(Conversation conversation, ContentItem content_item) {
            MessageDeletionGlobalPlan? nullable_plan;
            if (!try_build_global_delete_plan(conversation, content_item,
                    out nullable_plan)) {
                if (ContentItem.is_own(content_item)) {
                    warning("Refusing incomplete global retraction for content item %i",
                        content_item.id);
                } else {
                    warning("Refusing incomplete MUC moderation for content item %i",
                        content_item.id);
                }
                return false;
            }
            MessageDeletionGlobalPlan plan = (!) nullable_plan;

            if (plan.mode == MessageDeletionGlobalMode.RETRACTION) {
                foreach (string retraction_id in plan.reference_ids) {
                    bool hidden;
                    if (stream_interactor.get_stream(conversation.account) !=
                            plan.stream || !content_item_row_matches_plan(
                                conversation, content_item, plan,
                                out hidden)) {
                        warning("Refusing changed global retraction context for content item %i",
                            content_item.id);
                        return false;
                    }
                    if (!send_retraction(conversation, retraction_id)) {
                        warning("Global retraction dispatch failed for content item %i",
                            content_item.id);
                        return false;
                    }
                }
                // Delete locally once after every physical retraction reached
                // the send pipeline. Reflected per-revision retractions are
                // idempotent and cannot remove the shared UI row again.
                bool hidden;
                if (!revalidate_global_delete_plan(conversation, content_item,
                        plan, out hidden)) {
                    warning("Refusing changed global retraction context for content item %i",
                        content_item.id);
                    return false;
                }
                if (hidden) return true;
                return delete_persisted_item_locally(conversation, plan);
            }

            int pending_moderations = plan.reference_ids.size;
            bool all_moderations_succeeded = true;
            foreach (string moderation_id in plan.reference_ids) {
                bool hidden;
                if (stream_interactor.get_stream(conversation.account) !=
                        plan.stream || !content_item_row_matches_plan(
                            conversation, content_item, plan, out hidden)) {
                    warning("Refusing changed MUC moderation context for content item %i",
                        content_item.id);
                    return false;
                }
                Xmpp.Xep.MessageModeration.moderate.begin(plan.stream,
                    conversation.counterpart, moderation_id, (obj, res) => {
                        bool succeeded = Xmpp.Xep.MessageModeration.moderate
                            .end(res);
                        all_moderations_succeeded =
                            all_moderations_succeeded && succeeded;
                        pending_moderations--;
                        if (pending_moderations != 0) return;

                        bool callback_hidden = false;
                        if (all_moderations_succeeded &&
                                stream_interactor.get_stream(
                                    conversation.account) == plan.stream &&
                                revalidate_global_delete_plan(conversation,
                                    content_item, plan,
                                    out callback_hidden)) {
                            if (callback_hidden) return;
                            if (!delete_persisted_item_locally(conversation,
                                    plan)) {
                                warning("MUC moderation local cleanup failed for content item %i",
                                    content_item.id);
                            }
                        } else {
                            warning("MUC moderation did not confirm every revision for content item %i",
                                content_item.id);
                        }
                    });
            }
            return true;
        }

        private bool send_retraction(Conversation conversation,
                string message_id_to_delete) {
            Entities.Message retraction_message;
            return dispatch_retraction(conversation, message_id_to_delete,
                out retraction_message);
        }

        private async bool send_retraction_terminal(
                Conversation conversation, string message_id_to_delete) {
            Entities.Message retraction_message;
            if (!dispatch_retraction(conversation, message_id_to_delete,
                    out retraction_message)) {
                return false;
            }
            var waiter = new MessageDeletionWriteWaiter(retraction_message);
            return yield waiter.wait();
        }

        private bool dispatch_retraction(Conversation conversation,
                string message_id_to_delete,
                out Entities.Message retraction_msg) {
            // Send retraction as a proper XEP-0424 control message with Fallback/Hint.
            var control_message = new Entities.Message(
                "This message was retracted.");
            retraction_msg = control_message;
            control_message.account = conversation.account;
            control_message.counterpart = conversation.counterpart;
            control_message.direction = Entities.Message.DIRECTION_SENT;
            // Retraction is an XEP-0424 control stanza. Keep the control
            // element outside body encryption so receivers can process it
            // without blocking on an OpenPGP/OMEMO decrypt path.
            control_message.encryption = Encryption.NONE;
            control_message.stanza_id = Xmpp.random_uuid();
            control_message.type_ = Util.get_message_type_for_conversation(
                conversation);

            if (conversation.type_ == Conversation.Type.GROUPCHAT) {
                control_message.ourpart = stream_interactor
                    .get_module<MucManager>(MucManager.IDENTITY)
                    .get_own_jid(conversation.counterpart,
                        conversation.account) ??
                        conversation.account.bare_jid;
            } else {
                control_message.ourpart = conversation.account.full_jid;
            }

            // Use a dedicated handler method instead of lambda to avoid Vala compiler crashes
            ulong signal_id = 0;
            bool stanza_built = false;
            var message_processor = stream_interactor.get_module<MessageProcessor>(MessageProcessor.IDENTITY);
            signal_id = message_processor.build_message_stanza.connect((msg, stanza, conv) => {
                if (msg == control_message) {
                    stanza_built = true;
                    // 1. Retract
                    Xep.MessageRetraction.set_retract_id(stanza,
                        message_id_to_delete);

                    // 2. Fallback
                    var locations = new ArrayList<Xep.FallbackIndication.FallbackLocation>();
                    // "This message was retracted." is 27 chars
                    locations.add(new Xep.FallbackIndication.FallbackLocation.partial_body(0, 27));
                    var fallback = new Xep.FallbackIndication.Fallback(Xep.MessageRetraction.NS_URI, locations);
                    Xep.FallbackIndication.set_fallback(stanza, fallback);

                    // 3. Store Hint
                    Xep.MessageProcessingHints.set_message_hint(stanza, Xep.MessageProcessingHints.HINT_STORE);

                    // Disconnect self immediately
                    if (GLib.SignalHandler.is_connected(message_processor, signal_id)) {
                        GLib.SignalHandler.disconnect(message_processor, signal_id);
                    }
                }
            });

            message_processor.send_xmpp_message(control_message, conversation);
            bool dispatch_accepted = stanza_built &&
                control_message.marked != Entities.Message.Marked.UNSENT &&
                control_message.marked != Entities.Message.Marked.WONTSEND &&
                control_message.marked != Entities.Message.Marked.ERROR;
            if (!stanza_built && GLib.SignalHandler.is_connected(
                    message_processor, signal_id)) {
                GLib.SignalHandler.disconnect(message_processor, signal_id);
            }
            return dispatch_accepted;
        }

        public void delete_locally(Conversation conversation, ContentItem content_item, Jid removed_by) {
            // Mark the (underlying) message as removed and clear the body
            Message? message = null;
            ContentItemStore? content_item_store = stream_interactor.get_module<
                ContentItemStore>(ContentItemStore.IDENTITY);
            MessageItem? message_item = content_item as MessageItem;
            if (message_item != null) {
                message = ((!) message_item).message;
            } else if (content_item_store != null) {
                message = ((!) content_item_store).get_message_for_content_item(
                    conversation, content_item);
            }
            if (message != null) {
                ((!) message).body = "";
            }

            var deletion_items = new ArrayList<ContentItem>();
            if (content_item is FileItem && message != null &&
                    content_item_store != null) {
                bool selected_included = false;
                foreach (FileItem related_item in ((!) content_item_store)
                        .get_file_items_for_message(conversation,
                            (!) message)) {
                    if (related_item.id == content_item.id) {
                        deletion_items.add(content_item);
                        selected_included = true;
                    } else {
                        deletion_items.add(related_item);
                    }
                }
                if (!selected_included) deletion_items.add(content_item);
            } else {
                deletion_items.add(content_item);
            }

            foreach (ContentItem deletion_item in deletion_items) {
                hide_content_item_locally(conversation, deletion_item);
            }
        }

        private void hide_content_item_locally(Conversation conversation,
                ContentItem content_item) {
            if (content_item is FileItem) {
                FileItem file_item = (FileItem) content_item;
                if (file_item.file_transfer.path != null) {
                    FileUtils.remove(file_item.file_transfer.path);
                }
            }

            // A chain retraction is reflected once per physical revision. The
            // message/file cleanup above remains safe to repeat, but the UI
            // row must only be removed on the real hide=false -> hide=true
            // transition.
            RowOption content_item_row = db.content_item.select({db.content_item.hide})
                .with(db.content_item.id, "=", content_item.id)
                .with(db.content_item.conversation_id, "=", conversation.id)
                .single().row();
            if (!content_item_row.is_present() ||
                    content_item_row[db.content_item.hide]) {
                return;
            }

            db.content_item.update()
                .with(db.content_item.id, "=", content_item.id)
                .with(db.content_item.conversation_id, "=", conversation.id)
                .with(db.content_item.hide, "=", false)
                .set(db.content_item.hide, true)
                .perform();

            item_deleted(content_item);
        }

        public string[] after_actions_const = new string[]{ };
        public override string action_group { get { return "DELETE"; } }
        public override string[] after_actions { get { return after_actions_const; } }

        public override async bool run(Entities.Message message, Xmpp.MessageStanza stanza, Conversation conversation) {
            string? delete_message_id = Xep.MessageRetraction.get_retract_id(stanza);
            if (delete_message_id == null || delete_message_id.strip().length == 0) return false;

            ContentItem? content_item = stream_interactor.get_module<ContentItemStore>(ContentItemStore.IDENTITY).get_content_item_for_referencing_id(conversation, delete_message_id);
            
            // Debugging Retraction Issues:
            if (content_item == null) {
                // If standard lookup failed, maybe the ID was stored as the other ID type?
                // Sometimes clients send the stanza-id as 'id', but we stored it as 'server_id' or vice versa,
                // especially in mixed environments (MAM/Carbons).
                // Let's manually try to find it by poking MessageStorage directly for BOTH fields.
                
                var msg_storage = stream_interactor.get_module<MessageStorage>(MessageStorage.IDENTITY);
                Message? found_msg = msg_storage.get_message_by_stanza_id(delete_message_id, conversation);
                if (found_msg == null) {
                    found_msg = msg_storage.get_message_by_server_id(delete_message_id, conversation);
                }
                
                if (found_msg != null) {
                    // We found the message, but ContentItemStore lookup failed. Map it back to ContentItem.
                    // This is a workaround for database lookup inconsistencies.
                     var ci_row = stream_interactor.get_module<ContentItemStore>(ContentItemStore.IDENTITY).get_content_item_row_for_message(conversation, found_msg);
                     if (ci_row != null) {
                         try {
                            content_item = stream_interactor.get_module<ContentItemStore>(ContentItemStore.IDENTITY).get_item_from_row(ci_row, conversation);
                         } catch (GLib.Error e) {}
                     }
                }
            }

            if (content_item != null) {
                bool allowed = is_removal_allowed(conversation, content_item, stanza.from);
                debug("Deletion request: %s wants to remove message %s content item id %i. Allowed: %b",
                        message.from.to_string(), delete_message_id, content_item.id, allowed);
                
                if (allowed) {
                    delete_locally(conversation, content_item, stanza.from);
                    return true;
                }
            } else {
                debug("Deletion request: %s wants to remove message %s but it was not found.", 
                        message.from.to_string(), delete_message_id);
                // Even if we didn't find the message, we should consume the retraction stanza to prevent
                // the fallback "This message was retracted" text from appearing as a new message.
                // The user clearly intended to retract something, showing the fallback is confusing/wrong
                // if we can't link it.
                return true;
            }

            return false;
        }

        private bool is_removal_allowed(Conversation conversation, ContentItem content_item, Jid removed_by) {
            if (conversation.type_ == Conversation.Type.CHAT) {
                // In 1:1 chats, allow retraction if the sender matches (ignoring resource)
                return removed_by.equals_bare(content_item.jid);
            } else if (conversation.type_.is_muc_semantic()) {
                // Case 1: Moderator/Server Removal (XEP-0425) - From Room JID
                if (removed_by.equals(conversation.counterpart)) {
                    return stream_interactor.get_module<EntityInfo>(EntityInfo.IDENTITY)
                        .has_feature_cached(conversation.account, conversation.counterpart, Xmpp.Xep.MessageModeration.NS_URI);
                }
                
                // Case 2: Self-Retraction (XEP-0424) - From Sender's Occupant JID
                // Verify the retraction sender matches the original message sender
                if (removed_by.equals(content_item.jid)) {
                    return true;
                }
            }

            return false;
        }

        // Timer callback for auto-deleting expired messages
        private bool check_expired_messages() {
            var now = new DateTime.now_utc();
            var content_item_store = stream_interactor.get_module<ContentItemStore>(ContentItemStore.IDENTITY);
            
            foreach (Account account in stream_interactor.get_accounts()) {
                foreach (Conversation conversation in db.get_conversations(account)) {
                    if (conversation.message_expiry_seconds > 0) {
                        delete_expired_messages(conversation, now, content_item_store);
                    }
                }
            }
            return true;  // Keep timer running
        }

        private void delete_expired_messages(Conversation conversation, DateTime now, ContentItemStore content_item_store) {
            var cutoff_time = now.add_seconds(-conversation.message_expiry_seconds);
            // Process in batches to avoid loading all expired messages into memory at once (D5)
            Gee.List<ContentItem> items = new Gee.ArrayList<ContentItem>();
            int total_deleted = 0;
            do {
                items = content_item_store.get_items_older_than(conversation, cutoff_time, 500);
                if (items.size > 0 && total_deleted == 0) {
                    debug("Auto-deleting expired messages for %s (older than %s)", 
                          conversation.counterpart.to_string(), cutoff_time.to_string());
                }
                total_deleted += items.size;
            
            foreach (ContentItem item in items) {
                if (ContentItem.is_own(item) &&
                        can_delete_for_everyone(conversation, item) &&
                        delete_globally(conversation, item)) {
                    // Own message: Delete globally (server + local)
                } else {
                    // Received message: Delete locally only
                    delete_locally(conversation, item, conversation.account.bare_jid);
                }
            }
            } while (items.size >= 500); // Continue if batch was full (more may remain)
            if (total_deleted > 0) {
                debug("Auto-deleted %d expired messages for %s", total_deleted, conversation.counterpart.to_string());
            }
        }
    }

}

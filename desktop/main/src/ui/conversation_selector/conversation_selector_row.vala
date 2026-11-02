/*
 * Copyright (C) 2025 Ralf Peter <dinox@handwerker.jetzt>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

using Gee;
using Gdk;
using Gtk;
using Pango;

using Dino;
using Dino.Entities;
using Xmpp;

namespace Dino.Ui {

private class ConversationEncryptionMenuButton : Gtk.Button {
    static construct {
        set_accessible_role(Gtk.AccessibleRole.MENU_ITEM);
    }
}

[GtkTemplate (ui = "/im/dinox/dinox/conversation_row.ui")]
public class ConversationSelectorRow : ListBoxRow {

    [GtkChild] protected unowned AvatarPicture picture;
    [GtkChild] private unowned Overlay avatar_overlay;
    [GtkChild] protected unowned Label name_label;
    [GtkChild] protected unowned Label time_label;
    [GtkChild] protected unowned Label nick_label;
    [GtkChild] protected unowned Label message_label;
    [GtkChild] protected unowned Label unread_count_label;
    [GtkChild] protected unowned Label mention_indicator_label;
    [GtkChild] protected unowned Image muted_image;
    [GtkChild] protected unowned Image blocked_image;
    [GtkChild] protected unowned Image pinned_image;
    [GtkChild] protected unowned Label status_label;
    [GtkChild] protected unowned Image muc_indicator;
    [GtkChild] protected unowned Image private_room_image;
    [GtkChild] public unowned Revealer main_revealer;
    [GtkChild] private unowned Box row_box;
    [GtkChild] private unowned Box text_container;
    [GtkChild] private unowned Label compact_unread_count_label;
    [GtkChild] private unowned Label compact_mention_indicator_label;
    [GtkChild] private unowned Box compact_bottom_indicators;
    [GtkChild] private unowned Image compact_pinned_image;
    [GtkChild] private unowned Image compact_muted_image;
    [GtkChild] private unowned Image compact_muc_indicator;

    public Conversation conversation { get; private set; }
    internal int64 initial_latest_query_us { get; private set; default = 0; }
    private bool compact_ = false;
    private string compact_summary = "";

    public bool compact {
        get { return compact_; }
        set {
            if (compact_ == value) return;
            compact_ = value;
            text_container.visible = !value;
            // Compact pictures are smaller; the marker canvas keeps count
            // and mute badges in separate corners.
            picture.width_request = value ? COMPACT_AVATAR_SIZE : AVATAR_SIZE;
            picture.height_request = value ? COMPACT_AVATAR_SIZE : AVATAR_SIZE;
            picture.halign = value ? Align.CENTER : Align.FILL;
            avatar_overlay.width_request = value ? 44 : -1;
            avatar_overlay.height_request = value ? 40 : -1;
            row_box.halign = value ? Align.CENTER : Align.FILL;
            if (value) add_css_class("compact-conversation-row");
            else remove_css_class("compact-conversation-row");
            sync_compact_indicators();
        }
    }

    protected const int AVATAR_SIZE = 35;
    private const int COMPACT_AVATAR_SIZE = 32;

    protected ContentItem? last_content_item;
    protected int num_unread = 0;
    private PopoverMenu? active_popover = null;
    private Widget? cached_groupchat_tooltip = null;
    private Binding? display_name_binding = null;
    private ViewModel.CompatAvatarPictureModel? avatar_model = null;
    // D14: Signal handler IDs for proper cleanup
    private MucRoomObserver? muc_room_observer;
    private ulong content_new_item_handler_id;
    private ulong content_visibility_handler_id;
    private ulong correction_handler_id;
    private ulong deletion_handler_id;
    private ulong conversation_cleared_handler_id;
    private ulong block_changed_handler_id;
    private ulong notify_read_handler_id;
    private ulong notify_pinned_handler_id;
    private ulong notify_muted_handler_id;
    private ulong notify_nickname_handler_id;
    private PresenceObserver? presence_observer;
    private ulong presence_status_handler_id;
    private bool destroy_in_progress = false;
    private bool cleanup_complete = false;

    protected StreamInteractor stream_interactor;

    construct {
        name_label.attributes = new AttrList();
        unrealize.connect(() => {
            has_tooltip = false;
            cached_groupchat_tooltip = null;
        });
        realize.connect(() => {
            if (!cleanup_complete) update_compact_metadata();
        });
    }

    public ConversationSelectorRow(StreamInteractor stream_interactor, Conversation conversation) {
        this.conversation = conversation;
        this.stream_interactor = stream_interactor;

        var display_name_model = stream_interactor.get_module<ContactModels>(ContactModels.IDENTITY).get_display_name_model(conversation);
        WeakRef display_row_weak = WeakRef(this);
        display_name_binding = display_name_model.bind_property(
            "display-name", name_label, "label", BindingFlags.SYNC_CREATE,
            (_, from_value, ref to_value) => {
                string display_name = from_value.get_string() ?? "";
                to_value.set_string(display_name);
                var row = (ConversationSelectorRow?) display_row_weak.get();
                if (row != null) ((!) row).update_compact_metadata(display_name);
                return true;
            });

        // Add right-click context menu for all conversations
        GestureClick gesture = new GestureClick();
        gesture.set_button(3); // Right click
        gesture.released.connect((n_press, x, y) => {
            show_context_menu(x, y);
        });
        add_controller(gesture);
        
        if (conversation.type_ == Conversation.Type.CHAT) {
            // Observe only this counterpart. A large MUC presence burst must
            // not fan out through every direct-chat sidebar row.
            var pm = stream_interactor.get_module<PresenceManager>(PresenceManager.IDENTITY);
            WeakRef row_weak = WeakRef(this);
            presence_observer = pm.observe_presence(conversation.account, conversation.counterpart.bare_jid,
                (jid, account, available) => {
                    ConversationSelectorRow? row = (ConversationSelectorRow?) row_weak.get();
                    if (row == null) return false;
                    ((!) row).on_presence_changed(jid, account);
                    return true;
                });
            presence_status_handler_id = pm.status_changed.connect(on_own_status_changed);
            
            // Initial update
            update_status();
        }

        if (conversation.type_ == Conversation.Type.GROUPCHAT) {
            muc_indicator.visible = true;
            var muc_manager = stream_interactor.get_module<MucManager>(MucManager.IDENTITY);
            WeakRef row_weak = WeakRef(this);
            muc_room_observer = muc_manager.observe_room(conversation.account, conversation.counterpart.bare_jid,
                (kind, account, room, occupant) => {
                    ConversationSelectorRow? row = (ConversationSelectorRow?) row_weak.get();
                    if (row == null) return false;
                    if (kind == MucRoomUpdateKind.ROOM_INFO) {
                        ((!) row).update_read(true); // bubble color might have changed
                        ((!) row).update_private_room_indicator();
                    } else if (kind == MucRoomUpdateKind.SUBJECT) {
                        ((!) row).cached_groupchat_tooltip = null;
                        if (((!) row).get_realized() && ((!) row).get_root() != null) {
                            ((!) row).trigger_tooltip_query();
                        }
                    }
                    return true;
                });
            update_private_room_indicator();
        }

        // Set tooltip
        switch (conversation.type_) {
            case Conversation.Type.CHAT:
                break;
            case Conversation.Type.GROUPCHAT:
                has_tooltip = Util.use_tooltips();
                query_tooltip.connect ((x, y, keyboard_tooltip, tooltip) => {
                    if (compact) {
                        tooltip.set_text(compact_summary);
                        return true;
                    }
                    if (cached_groupchat_tooltip == null) {
                        cached_groupchat_tooltip = generate_groupchat_tooltip();
                    }
                    tooltip.set_custom(Util.widget_if_tooltips_active(cached_groupchat_tooltip));
                    return true;
                });
                break;
            case Conversation.Type.GROUPCHAT_PM:
                break;
        }

        content_new_item_handler_id = stream_interactor.get_module<ContentItemStore>(ContentItemStore.IDENTITY).new_item.connect((item, c) => {
            if (conversation.equals(c)) {
                content_item_received(item);
            }
        });
        content_visibility_handler_id = connect_content_visibility_updates(this,
            stream_interactor.get_module<ContentItemStore>(ContentItemStore.IDENTITY));
        correction_handler_id = stream_interactor.get_module<MessageCorrection>(MessageCorrection.IDENTITY).received_correction.connect((item) => {
            if (!item_belongs_to_conversation(item)) return;
            if (last_content_item != null && last_content_item.id == item.id) {
                content_item_received(item);
            }
            // An earlier unread message can gain or lose a mention without
            // changing either the message count or the preview.
            update_read(true);
        });
        deletion_handler_id = stream_interactor.get_module<MessageDeletion>(MessageDeletion.IDENTITY).item_deleted.connect((item) => {
            if (!item_belongs_to_conversation(item)) return;
            if (last_content_item != null && last_content_item.id == item.id) {
                content_item_received(item);
            }
            update_read(true);
        });
        conversation_cleared_handler_id = stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY).conversation_cleared.connect((cleared_conversation) => {
            if (conversation.id == cleared_conversation.id) {
                last_content_item = null;
                update_message_label();
                update_time_label();
            }
        });

        avatar_model = new ViewModel.CompatAvatarPictureModel(stream_interactor)
            .set_conversation(conversation);
        picture.model = avatar_model;
        notify_read_handler_id = conversation.notify["read-up-to-item"].connect(() => update_read());
        notify_pinned_handler_id = conversation.notify["pinned"].connect(() => { update_pinned_icon(); });
        notify_muted_handler_id = conversation.notify["notify-setting"].connect(() => { update_muted_icon(); });
        notify_nickname_handler_id = conversation.notify["nickname"].connect(() => update_read(true));
        
        // Listen for block status changes
        if (conversation.type_ == Conversation.Type.CHAT) {
            block_changed_handler_id = stream_interactor.get_module<BlockingManager>(BlockingManager.IDENTITY).block_changed.connect((account, jid) => {
                if (conversation.account.equals(account) && conversation.counterpart.equals_bare(jid)) {
                    update_blocked_icon();
                }
            });
        }

        update_name_label();
        update_pinned_icon();
        update_muted_icon();
        update_blocked_icon();
        // This is the single initial latest-item query. Do not preload the same
        // item above and then query it again here for every restored sidebar row.
        content_item_received();
    }

    internal void cleanup() {
        if (cleanup_complete) return;
        cleanup_complete = true;

        // Context-menu actions and the popover's closed callback can otherwise
        // keep an already detached row alive through their closures.
        PopoverMenu? popover = active_popover;
        active_popover = null;
        if (popover != null) {
            popover.popdown();
            if (popover.get_parent() != null) {
                popover.unparent();
            }
        }
        insert_action_group("row", null);
        has_tooltip = false;
        cached_groupchat_tooltip = null;
        last_content_item = null;
        if (update_read_source_id != 0) {
            Source.remove(update_read_source_id);
            update_read_source_id = 0;
        }
        update_read_pending = false;
        update_read_pending_force = false;

        if (display_name_binding != null) {
            ((!) display_name_binding).unbind();
            display_name_binding = null;
        }
        if (avatar_model != null) {
            ((!) avatar_model).cleanup();
            avatar_model = null;
        }
        picture.model = null;

        if (presence_observer != null) {
            ((!) presence_observer).unsubscribe();
            presence_observer = null;
        }
        if (presence_status_handler_id != 0) {
            var pm = stream_interactor.get_module<PresenceManager>(PresenceManager.IDENTITY);
            if (pm != null && SignalHandler.is_connected(pm, presence_status_handler_id)) {
                SignalHandler.disconnect(pm, presence_status_handler_id);
            }
            presence_status_handler_id = 0;
        }

        // Disconnect the module closures while the row is still reachable.
        // Waiting for finalization is too late: several of these closures hold
        // a strong reference to the row themselves.
        if (muc_room_observer != null) {
            ((!) muc_room_observer).unsubscribe();
            muc_room_observer = null;
        }
        if (content_new_item_handler_id != 0) {
            var cis = stream_interactor.get_module<ContentItemStore>(ContentItemStore.IDENTITY);
            if (cis != null && SignalHandler.is_connected(cis, content_new_item_handler_id)) {
                SignalHandler.disconnect(cis, content_new_item_handler_id);
            }
            content_new_item_handler_id = 0;
        }
        if (content_visibility_handler_id != 0) {
            var cis = stream_interactor.get_module<ContentItemStore>(ContentItemStore.IDENTITY);
            if (cis != null && SignalHandler.is_connected(cis, content_visibility_handler_id)) {
                SignalHandler.disconnect(cis, content_visibility_handler_id);
            }
            content_visibility_handler_id = 0;
        }
        if (correction_handler_id != 0) {
            var mc = stream_interactor.get_module<MessageCorrection>(MessageCorrection.IDENTITY);
            if (mc != null && SignalHandler.is_connected(mc, correction_handler_id)) {
                SignalHandler.disconnect(mc, correction_handler_id);
            }
            correction_handler_id = 0;
        }
        if (deletion_handler_id != 0) {
            var md = stream_interactor.get_module<MessageDeletion>(MessageDeletion.IDENTITY);
            if (md != null && SignalHandler.is_connected(md, deletion_handler_id)) {
                SignalHandler.disconnect(md, deletion_handler_id);
            }
            deletion_handler_id = 0;
        }
        if (conversation_cleared_handler_id != 0) {
            var cm = stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY);
            if (cm != null && SignalHandler.is_connected(cm, conversation_cleared_handler_id)) {
                SignalHandler.disconnect(cm, conversation_cleared_handler_id);
            }
            conversation_cleared_handler_id = 0;
        }
        if (block_changed_handler_id != 0) {
            var bm = stream_interactor.get_module<BlockingManager>(BlockingManager.IDENTITY);
            if (bm != null && SignalHandler.is_connected(bm, block_changed_handler_id)) {
                SignalHandler.disconnect(bm, block_changed_handler_id);
            }
            block_changed_handler_id = 0;
        }

        // Disconnect conversation property-change signals
        if (notify_read_handler_id != 0) {
            if (SignalHandler.is_connected(conversation, notify_read_handler_id)) {
                SignalHandler.disconnect(conversation, notify_read_handler_id);
            }
            notify_read_handler_id = 0;
        }
        if (notify_pinned_handler_id != 0) {
            if (SignalHandler.is_connected(conversation, notify_pinned_handler_id)) {
                SignalHandler.disconnect(conversation, notify_pinned_handler_id);
            }
            notify_pinned_handler_id = 0;
        }
        if (notify_muted_handler_id != 0) {
            if (SignalHandler.is_connected(conversation, notify_muted_handler_id)) {
                SignalHandler.disconnect(conversation, notify_muted_handler_id);
            }
            notify_muted_handler_id = 0;
        }
        if (notify_nickname_handler_id != 0) {
            if (SignalHandler.is_connected(conversation, notify_nickname_handler_id)) {
                SignalHandler.disconnect(conversation, notify_nickname_handler_id);
            }
            notify_nickname_handler_id = 0;
        }
    }

    ~ConversationSelectorRow() {
        cleanup();
    }

    public override void dispose() {
        cleanup();
        base.dispose();
    }

    public void update() {
        update_time_label();
    }

    public void content_item_received(ContentItem? ci = null) {
        // D3: If a new item is provided and is newer than cached, use it directly
        // instead of querying the DB (avoids N+1 on every incoming message)
        if (ci != null && (last_content_item == null || ci.compare(last_content_item) >= 0)) {
            last_content_item = ci;
        } else {
            int64 query_started_us = UiTiming.enabled() ? UiTiming.now_us() : 0;
            last_content_item = stream_interactor.get_module<ContentItemStore>(ContentItemStore.IDENTITY).get_latest(conversation) ?? ci;
            if (query_started_us != 0) {
                initial_latest_query_us = UiTiming.now_us() - query_started_us;
            }
        }
        update_message_label();
        update_time_label();
        update_read(ci != null);
    }

    private static ulong connect_content_visibility_updates(ConversationSelectorRow owner, ContentItemStore store) {
        WeakRef row_weak = WeakRef(owner);
        return store.item_visibility_changed.connect((item, changed_conversation, hidden) => {
            ConversationSelectorRow? row = (ConversationSelectorRow?) row_weak.get();
            if (row == null || ((!) row).cleanup_complete ||
                    ((!) row).conversation.id != changed_conversation.id ||
                    ((!) row).conversation.account.id != changed_conversation.account.id) return;
            ContentItemStore current_store = ((!) row).stream_interactor
                .get_module<ContentItemStore>(ContentItemStore.IDENTITY);
            ((!) row).last_content_item = current_store.get_latest(((!) row).conversation);
            ((!) row).update_message_label();
            ((!) row).update_time_label();
            ((!) row).update_compact_metadata();
            // This is a trust projection of existing history, not receipt of
            // another message. Keep unread and notification state untouched.
        });
    }

    public void dismiss_popover() {
        if (active_popover != null) {
            active_popover.popdown();
        }
    }

    protected void update_name_label() {
        name_label.label = Util.get_conversation_display_name(stream_interactor, conversation);
        update_compact_metadata();
    }

    private void update_pinned_icon() {
        pinned_image.visible = conversation.pinned != 0;
        sync_compact_indicators();
    }

    private void update_muted_icon() {
        muted_image.visible = (conversation.notify_setting == Conversation.NotifySetting.OFF);
        sync_compact_indicators();
    }

    private void update_blocked_icon() {
        if (conversation.type_ == Conversation.Type.CHAT) {
            bool is_blocked = stream_interactor.get_module<BlockingManager>(BlockingManager.IDENTITY).is_blocked(conversation.account, conversation.counterpart);
            blocked_image.visible = is_blocked;
        } else {
            blocked_image.visible = false;
        }
    }

    protected void update_time_label(DateTime? new_time = null) {
        if (last_content_item != null) {
            time_label.visible = true;
            time_label.label = get_relative_time(last_content_item.time.to_local());
        } else {
            time_label.label = "";
            time_label.visible = false;
        }
    }

    protected void update_message_label() {
        if (last_content_item != null) {
            switch (last_content_item.type_) {
                case MessageItem.TYPE:
                    MessageItem message_item = last_content_item as MessageItem;
                    Message last_message = message_item.message;

                    string body = Dino.Ui.ConversationSummary.MessageDiagnostics.is_local_decryption_failure(last_message)
                        ? (Dino.Ui.ConversationSummary.MessageDiagnostics.body_for_display(last_message) ?? "")
                        : Dino.message_body_without_reply_fallback(last_message);
                    bool me_command = body.has_prefix("/me ");

                    /* If we have a /me command, we always show the display
                     * name, and we don't set me_is_me on
                     * get_participant_display_name, since that will return
                     * "Me" (internationalized), whereas /me commands expect to
                     * be in the third person. We also omit the colon in this
                     * case, and strip off the /me prefix itself. */

                    if (conversation.type_ == Conversation.Type.GROUPCHAT || me_command) {
                        nick_label.label = Util.get_participant_display_name(stream_interactor, conversation, last_message.from, !me_command);
                    } else if (last_message.direction == Message.DIRECTION_SENT) {
                        nick_label.label = _("Me");
                    } else {
                        nick_label.label = "";
                    }

                    if (me_command) {
                        /* Don't slice off the space after /me */
                        body = body.slice("/me".length, body.length);
                    } else if (nick_label.label.length > 0) {
                        /* TODO: Is this valid for RTL languages? */
                        nick_label.label += ": ";
                    }

                    if (message_item.message.body == "") {
                        change_label_attribute(message_label, attr_style_new(Pango.Style.ITALIC));
                        message_label.label = _("Message deleted");
                    } else {
                        change_label_attribute(message_label, attr_style_new(Pango.Style.NORMAL));
                        message_label.label = Util.summarize_whitespaces_to_space(body);
                    }

                    break;
                case FileItem.TYPE:
                    FileItem file_item = last_content_item as FileItem;
                    FileTransfer transfer = file_item.file_transfer;
                    if (transfer == null) break;

                    if (conversation.type_ == Conversation.Type.GROUPCHAT) {
                        // TODO properly display nick for oneself
                        nick_label.label = Util.get_participant_display_name(stream_interactor, conversation, file_item.file_transfer.from, true) + ": ";
                    } else {
                        nick_label.label = transfer.direction == Message.DIRECTION_SENT ? _("Me") + ": " : "";
                    }

                    bool file_is_image = transfer.mime_type != null && transfer.mime_type.has_prefix("image");
                    change_label_attribute(message_label, attr_style_new(Pango.Style.ITALIC));
                    if (transfer.direction == Message.DIRECTION_SENT) {
                        message_label.label = (file_is_image ? _("Image sent") : _("File sent") );
                    } else {
                        message_label.label = (file_is_image ? _("Image received") : _("File received") );
                    }
                    break;
                case CallItem.TYPE:
                    CallItem call_item = (CallItem) last_content_item;
                    Call call = call_item.call;

                    nick_label.label = call.direction == Call.DIRECTION_OUTGOING ? _("Me") + ": " : "";
                    change_label_attribute(message_label, attr_style_new(Pango.Style.ITALIC));
                    message_label.label = call.direction == Call.DIRECTION_OUTGOING ? _("Outgoing call") : _("Incoming call");
                    break;
            }
            nick_label.visible = true;
            message_label.visible = true;
        } else {
            nick_label.label = "";
            message_label.label = "";
            nick_label.visible = false;
            message_label.visible = false;
        }
    }

    private static void change_label_attribute(Label label, owned Attribute attribute) {
        AttrList copy = label.attributes.copy();
        copy.change((owned) attribute);
        label.attributes = copy;
    }

    private bool update_read_pending = false;
    private bool update_read_pending_force = false;
    private uint update_read_source_id = 0;
    protected void update_read(bool force_update = false) {
        if (cleanup_complete) return;
        if (force_update) update_read_pending_force = true;
        if (update_read_pending) return;
        update_read_pending = true;
        update_read_source_id = Idle.add(() => {
            update_read_source_id = 0;
            if (cleanup_complete) return Source.REMOVE;
            bool force = update_read_pending_force;
            update_read_pending = false;
            update_read_pending_force = false;
            update_read_idle(force);
            return Source.REMOVE;
        }, Priority.LOW);
    }

    private bool item_belongs_to_conversation(ContentItem item) {
        Conversation? owner = null;
        if (item is MessageItem) owner = ((MessageItem) item).conversation;
        else if (item is FileItem) owner = ((FileItem) item).conversation;
        return owner != null && conversation.equals((!) owner);
    }

    private void update_read_idle(bool force_update = false) {
        int current_num_unread = stream_interactor.get_module<ChatInteraction>(ChatInteraction.IDENTITY).get_num_unread(conversation);
        if (num_unread == current_num_unread && !force_update) return;
        num_unread = current_num_unread;

        if (num_unread == 0) {
            unread_count_label.visible = false;
            mention_indicator_label.visible = false;

            change_label_attribute(name_label, attr_weight_new(Weight.NORMAL));
            change_label_attribute(time_label, attr_weight_new(Weight.NORMAL));
            change_label_attribute(nick_label, attr_weight_new(Weight.NORMAL));
            change_label_attribute(message_label, attr_weight_new(Weight.NORMAL));
        } else {
            unread_count_label.label = num_unread.to_string();
            unread_count_label.visible = true;
            mention_indicator_label.visible = stream_interactor.get_module<ChatInteraction>(ChatInteraction.IDENTITY).has_unread_mention(conversation);

            if (conversation.get_notification_setting(stream_interactor) == Conversation.NotifySetting.ON) {
                unread_count_label.add_css_class("unread-count-notify");
                unread_count_label.remove_css_class("unread-count");
            } else {
                unread_count_label.add_css_class("unread-count");
                unread_count_label.remove_css_class("unread-count-notify");
            }

            change_label_attribute(name_label, attr_weight_new(Weight.BOLD));
            change_label_attribute(time_label, attr_weight_new(Weight.BOLD));
            change_label_attribute(nick_label, attr_weight_new(Weight.BOLD));
            change_label_attribute(message_label, attr_weight_new(Weight.BOLD));
        }
        sync_compact_indicators();
    }

    private void sync_compact_indicators() {
        // Mirror the existing row state. Compact layout never runs another
        // unread/mention query and preserves the notification state.
        // Keep 99+ in its logical order without changing RTL badge placement.
        compact_unread_count_label.label = num_unread > 99 ? "\u206699+\u2069" : num_unread.to_string();
        compact_unread_count_label.visible = compact && unread_count_label.visible;
        compact_mention_indicator_label.visible = compact && mention_indicator_label.visible;
        compact_pinned_image.visible = compact && pinned_image.visible;
        compact_bottom_indicators.visible = compact &&
            (compact_pinned_image.visible || compact_mention_indicator_label.visible);
        // A pin and mention share the lower leading corner. Reserve enough
        // marker space for both plus the room/status marker at the other end,
        // keeping the picture centred and the 72px rail unchanged.
        bool pin_and_mention = compact_pinned_image.visible && compact_mention_indicator_label.visible;
        avatar_overlay.width_request = compact ? (pin_and_mention ? 52 : 44) : -1;
        row_box.margin_start = pin_and_mention ? 0 : 2;
        row_box.margin_end = pin_and_mention ? 0 : 4;
        compact_muted_image.visible = compact && muted_image.visible;
        // Room identity is independent of contact presence. Reuse the
        // account-scoped private-room state from the expanded row.
        compact_muc_indicator.icon_name = private_room_image.visible
            ? "changes-prevent-symbolic" : "system-users-symbolic";
        compact_muc_indicator.visible = compact && conversation.type_ == Conversation.Type.GROUPCHAT;
        if (unread_count_label.has_css_class("unread-count-notify")) {
            compact_unread_count_label.add_css_class("unread-count-notify");
            compact_unread_count_label.remove_css_class("unread-count");
        } else {
            compact_unread_count_label.add_css_class("unread-count");
            compact_unread_count_label.remove_css_class("unread-count-notify");
        }
        update_compact_metadata();
    }

    private void update_compact_metadata(string? display_name = null) {
        if (!compact) {
            tooltip_text = null;
            has_tooltip = conversation.type_ == Conversation.Type.GROUPCHAT && Util.use_tooltips();
            reset_property(Gtk.AccessibleProperty.LABEL);
            return;
        }
        compact_summary = "%s\n%s".printf(display_name ?? name_label.label, conversation.account.bare_jid.to_string());
        if (conversation.type_ == Conversation.Type.GROUPCHAT) {
            compact_summary += "\n" + (private_room_image.visible
                ? _("Private room (supports group calls)") : _("Group chat"));
        }
        if (num_unread > 0) compact_summary += "\n" + _("Unread messages: %d").printf(num_unread);
        if (mention_indicator_label.visible) compact_summary += "\n" + _("Mentioned");
        if (muted_image.visible) compact_summary += "\n" + _("Muted");
        if (pinned_image.visible) compact_summary += "\n" + _("Pinned");
        tooltip_text = Util.string_if_tooltips_active(compact_summary);
        // Labels remain independent of the user's tooltip preference.
        update_property(Gtk.AccessibleProperty.LABEL, compact_summary, -1);
    }

    private Widget generate_groupchat_tooltip() {
        Grid grid = new Grid() { row_spacing=5, column_homogeneous=false, column_spacing=5, margin_start=7, margin_end=7, margin_top=7, margin_bottom=7 };

        // JID as title
        Label jid_label = new Label(conversation.counterpart.bare_jid.to_string()) { valign=Align.START, xalign=0 };
        jid_label.attributes = new AttrList();
        jid_label.attributes.insert(attr_weight_new(Weight.BOLD));
        grid.attach(jid_label, 0, 0, 2, 1);

        int row = 1;

        // Room topic/subject
        string? topic = stream_interactor.get_module<MucManager>(MucManager.IDENTITY).get_groupchat_subject(conversation.counterpart, conversation.account);
        // topic can legitimately be null for rooms without a subject set
        if (topic != null && topic.strip() != "") {
            Label topic_title = new Label(_("Thema:")) { valign=Align.START, xalign=0 };
            topic_title.attributes = new AttrList();
            topic_title.attributes.insert(attr_style_new(Style.ITALIC));
            grid.attach(topic_title, 0, row, 1, 1);

            // Limit topic length for tooltip
            string display_topic = topic.strip();
            if (display_topic.length > 100) {
                display_topic = display_topic.substring(0, 100) + "…";
            }
            Label topic_label = new Label(display_topic) { valign=Align.START, xalign=0, wrap=true, max_width_chars=40 };
            grid.attach(topic_label, 1, row, 1, 1);
            row++;
        }

        // Room features (private/public, members-only, etc.)
        MucManager muc_manager = stream_interactor.get_module<MucManager>(MucManager.IDENTITY);
        var features = new StringBuilder();
        
        if (muc_manager.is_private_room(conversation.account, conversation.counterpart)) {
            features.append(_("Privat"));
        } else {
            features.append(_("Öffentlich"));
        }

        if (features.len > 0) {
            Label features_title = new Label(_("Typ:")) { valign=Align.START, xalign=0 };
            features_title.attributes = new AttrList();
            features_title.attributes.insert(attr_style_new(Style.ITALIC));
            grid.attach(features_title, 0, row, 1, 1);

            Label features_label = new Label(features.str) { valign=Align.START, xalign=0 };
            grid.attach(features_label, 1, row, 1, 1);
            row++;
        }

        return grid;
    }

    private static string get_relative_time(DateTime datetime) {
         DateTime now = new DateTime.now_local();
         TimeSpan timespan = now.difference(datetime);
         if (timespan > 365 * TimeSpan.DAY) {
             return datetime.get_year().to_string();
         } else if (timespan > 7 * TimeSpan.DAY) {
             // Day and month
             // xgettext:no-c-format
             return datetime.format(_("%b %d"));
         } else if (timespan > 2 * TimeSpan.DAY) {
             return datetime.format("%a");
         } else if (datetime.get_day_of_month() != now.get_day_of_month()) {
             return _("Yesterday");
         } else if (timespan > 9 * TimeSpan.MINUTE) {
             return datetime.format(Util.is_24h_format() ?
                /* xgettext:no-c-format */ /* Time in 24h format (w/o seconds) */ _("%H∶%M") :
                /* xgettext:no-c-format */ /* Time in 12h format (w/o seconds) */ _("%l∶%M %p"));
         } else if (timespan > 1 * TimeSpan.MINUTE) {
             ulong mins = (ulong) (timespan.abs() / TimeSpan.MINUTE);
             return n("%i min ago", "%i mins ago", mins).printf(mins);
         } else {
             return _("Just now");
         }
    }

    private static void attach_context_popover_cleanup(
            ConversationSelectorRow row, PopoverMenu popover) {
        WeakRef row_weak = WeakRef(row);
        WeakRef popover_weak = WeakRef(popover);
        popover.closed.connect(() => {
            Idle.add(() => {
                ConversationSelectorRow? current_row =
                    (ConversationSelectorRow?) row_weak.get();
                PopoverMenu? current_popover =
                    (PopoverMenu?) popover_weak.get();
                if (current_popover == null) return false;
                if (current_popover.get_parent() != null) {
                    current_popover.unparent();
                }
                if (current_row != null &&
                        ((!) current_row).active_popover == current_popover) {
                    ((!) current_row).active_popover = null;
                }
                return false;
            });
        });
    }

    private bool has_encryption_details(Conversation target) {
        var app = GLib.Application.get_default() as Dino.Application;
        if (app == null || target.counterpart.domainpart == "mqtt.local") return false;
        if (target.type_ == Conversation.Type.GROUPCHAT_PM) return false;
        if (target.type_ == Conversation.Type.CHAT &&
                target.counterpart.equals_bare(target.account.bare_jid) &&
                target.nickname == "Botmother") return false;

        bool omemo_details = false;
        bool pgp_details = false;
        foreach (Plugins.ContactDetailsProvider provider in app.plugin_registry.contact_details_entries) {
            if (provider.tab != "encryption") continue;
            if (provider.id == "omemo_info") omemo_details = true;
            if (provider.id == "pgp_info") pgp_details = true;
        }
        omemo_details = omemo_details && app.plugin_registry.encryption_list_entries.has_key(Encryption.OMEMO);
        pgp_details = pgp_details && app.plugin_registry.encryption_list_entries.has_key(Encryption.PGP);
        if (target.type_ == Conversation.Type.GROUPCHAT) {
            return omemo_details && stream_interactor.get_module<MucManager>(MucManager.IDENTITY)
                .is_private_room(target.account, target.counterpart);
        }
        return target.type_ == Conversation.Type.CHAT && (omemo_details || pgp_details);
    }

    private void open_encryption_details(int target_id, int target_account_id,
            string target_account_jid, string target_jid) {
        if (cleanup_complete) return;
        Conversation? target = stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY)
            .get_conversation_by_id(target_id);
        if (target == null || target.id != target_id || target.account.id != target_account_id ||
                target.account.bare_jid.to_string() != target_account_jid ||
                target.counterpart.bare_jid.to_string() != target_jid ||
                !has_encryption_details(target)) return;
        dismiss_popover();
        var variant = new GLib.Variant.tuple(new GLib.Variant[] {
            new GLib.Variant.int32(target_id), new GLib.Variant.string("encryption")
        });
        GLib.Application.get_default().activate_action("open-conversation-details", variant);
    }

    private static void bind_encryption_action(SimpleAction action, ConversationSelectorRow owner,
            int target_id, int target_account_id, string target_account_jid, string target_jid) {
        WeakRef row_weak = WeakRef(owner);
        action.activate.connect(() => {
            var row = row_weak.get() as ConversationSelectorRow;
            if (row != null) row.open_encryption_details(target_id, target_account_id,
                target_account_jid, target_jid);
        });
    }

    private Button? append_encryption_context_entry(Menu menu, SimpleActionGroup action_group) {
        if (!has_encryption_details(conversation)) return null;
        var app = (Dino.Application) GLib.Application.get_default();
        Plugins.EncryptionListEntry? entry = app.plugin_registry.encryption_list_entries[conversation.encryption];
        Plugins.ConversationEncryptionTrust trust = Plugins.ConversationEncryptionTrust.UNKNOWN;
        string detail;
        string? status_class = null;
        if (conversation.encryption == Encryption.NONE) {
            detail = _("Unencrypted");
        } else {
            if (entry != null) trust = entry.get_conversation_trust(conversation);
            string status;
            switch (trust) {
                case Plugins.ConversationEncryptionTrust.VERIFIED:
                    status = _("Verified");
                    status_class = "success";
                    break;
                case Plugins.ConversationEncryptionTrust.TRUSTED:
                    status = _("Trusted");
                    status_class = "accent";
                    break;
                case Plugins.ConversationEncryptionTrust.NEEDS_ATTENTION:
                    status = _("Check keys");
                    status_class = "warning";
                    break;
                default:
                    status = _("Unknown");
                    break;
            }
            detail = "%s · %s".printf(entry != null ? entry.name.make_valid() : _("Unknown"), status);
        }
        string label = "%s · %s".printf(_("Encryption"), detail);

        var item = new MenuItem(label, null);
        item.set_attribute_value("custom", new GLib.Variant.string("encryption-entry"));
        menu.append_item(item);
        var action = new SimpleAction("encryption", null);
        bind_encryption_action(action, this, conversation.id, conversation.account.id,
            conversation.account.bare_jid.to_string(), conversation.counterpart.bare_jid.to_string());
        action_group.add_action(action);

        var button = new ConversationEncryptionMenuButton() {
            action_name = "row.encryption", hexpand = true, halign = Align.FILL,
            tooltip_text = trust == Plugins.ConversationEncryptionTrust.VERIFIED
                ? "%s\n%s".printf(label, _("Locally known active keys are verified. Open encryption details to review them."))
                : label
        };
        button.add_css_class("flat");
        button.add_css_class("model");
        button.update_property(Gtk.AccessibleProperty.LABEL, label, -1);
        var content = new Box(Orientation.HORIZONTAL, 8);
        var icon = new Image.from_icon_name(trust == Plugins.ConversationEncryptionTrust.VERIFIED
            ? "dino-shield-check-symbolic" : "dino-security-high-symbolic") { pixel_size = 16 };
        icon.add_css_class(status_class ?? "dim-label");
        content.append(icon);
        var captions = new Box(Orientation.VERTICAL, 2) { hexpand = true };
        captions.append(new Label(_("Encryption")) {
            xalign = 0, hexpand = true, use_markup = false,
            ellipsize = EllipsizeMode.END, width_chars = 1, max_width_chars = 28
        });
        var status_label = new Label(detail) {
            xalign = 0, hexpand = true, use_markup = false, wrap = true,
            wrap_mode = Pango.WrapMode.WORD_CHAR, lines = 2,
            ellipsize = EllipsizeMode.END, width_chars = 1, max_width_chars = 28
        };
        status_label.add_css_class("dim-label");
        captions.append(status_label);
        content.append(captions);
        button.child = content;
        return button;
    }

    private void show_context_menu(double x, double y) {
        if (cleanup_complete) return;
        var menu = new Menu();
        var details = new Menu();
        var notifications = new Menu();
        var history = new Menu();
        var closing = new Menu();
        var removal = new Menu();
        var action_group = new SimpleActionGroup();
        Button? encryption_button = null;
        
        if (conversation.type_ == Conversation.Type.GROUPCHAT) {
            // MUC/Groupchat options
            MucManager muc_manager = stream_interactor.get_module<MucManager>(
                MucManager.IDENTITY);
            bool can_invite_current_room =
                muc_manager.mediated_invite_possible(conversation.account,
                    conversation.counterpart);
            details.append(_("Conversation Details"), "row.details");
            if (can_invite_current_room) {
                details.append(_("Invite Contact"), "row.invite");
            }
            encryption_button = append_encryption_context_entry(details, action_group);
            
            // Mute/Unmute
            bool is_muted = (conversation.notify_setting == Conversation.NotifySetting.OFF);
            notifications.append(is_muted ? _("Unmute") : _("Mute"), "row.mute");
            
            history.append(_("Delete Conversation History"), "row.clear");
            closing.append(_("Close Conversation"), "row.close");
            closing.append(_("Leave Conversation"), "row.leave");
            closing.append(_("Leave Permanently"), "row.leave-permanently");
            
            // Show "Destroy Room" only for owners
            Jid? own_muc_jid = stream_interactor.get_module<MucManager>(MucManager.IDENTITY).get_own_jid(conversation.counterpart, conversation.account);
            if (own_muc_jid != null) {
                Xep.Muc.Affiliation? own_aff = stream_interactor.get_module<MucManager>(MucManager.IDENTITY).get_affiliation(conversation.counterpart, own_muc_jid, conversation.account);
                if (own_aff == Xep.Muc.Affiliation.OWNER) {
                    removal.append(_("Destroy Room"), "row.destroy");
                }
            }
            
            // Details action
            var details_action = new SimpleAction("details", null);
            details_action.activate.connect(() => {
                var variant = new GLib.Variant.tuple(new GLib.Variant[] {new GLib.Variant.int32(conversation.id), new GLib.Variant.string("about")});
                GLib.Application.get_default().activate_action("open-conversation-details", variant);
            });
            action_group.add_action(details_action);
            
            // Invite action
            var invite_action = new SimpleAction("invite", null);
            invite_action.set_enabled(can_invite_current_room);
            invite_action.activate.connect(() => {
                if (!muc_manager.mediated_invite_possible(
                        conversation.account,
                        conversation.counterpart)) return;
                show_invite_dialog();
            });
            action_group.add_action(invite_action);
            
            // Mute action
            var mute_action = new SimpleAction("mute", null);
            mute_action.activate.connect(() => {
                toggle_mute();
            });
            action_group.add_action(mute_action);
            
            // Clear history action
            var clear_action = new SimpleAction("clear", null);
            clear_action.activate.connect(() => {
                show_clear_history_dialog();
            });
            action_group.add_action(clear_action);
            
            // Close conversation action (leave MUC and close)
            var close_action = new SimpleAction("close", null);
            close_action.activate.connect(() => {
                GLib.Application.get_default().activate_action("close-conversation", new GLib.Variant.int32(conversation.id));
            });
            action_group.add_action(close_action);

            // Leave MUC room and close locally, without removing bookmark
            var leave_action = new SimpleAction("leave", null);
            leave_action.activate.connect(() => {
                GLib.Application.get_default().activate_action("leave-conversation", new GLib.Variant.int32(conversation.id));
            });
            action_group.add_action(leave_action);

            // Permanently leave room, remove bookmark, and keep local history
            var leave_permanently_action = new SimpleAction("leave-permanently", null);
            leave_permanently_action.activate.connect(() => {
                GLib.Application.get_default().activate_action("leave-conversation-permanently", new GLib.Variant.int32(conversation.id));
            });
            action_group.add_action(leave_permanently_action);
            
            // Destroy room action (only added to menu for owners)
            var destroy_action = new SimpleAction("destroy", null);
            destroy_action.activate.connect(() => {
                show_destroy_room_dialog();
            });
            action_group.add_action(destroy_action);
            
        } else {
            // Direct-chat options. A MUC PM still uses room@service/nick as
            // its transport address and must never expose roster/block actions
            // for that unstable nickname.
            bool is_muc_pm = conversation.type_ ==
                Conversation.Type.GROUPCHAT_PM;
            bool is_synthetic_bot = (conversation.counterpart.domainpart == "mqtt.local");
            bool is_botmother_chat = is_botmother_self_chat();
            bool is_system_chat = is_synthetic_bot || is_botmother_chat ||
                is_muc_pm;

            details.append(_("Conversation Details"), "row.details");
            if (!is_system_chat) {
                details.append(_("Edit Alias"), "row.edit");
            }
            encryption_button = append_encryption_context_entry(details, action_group);
            
            // Mute/Unmute
            bool is_muted = (conversation.notify_setting == Conversation.NotifySetting.OFF);
            notifications.append(is_muted ? _("Unmute") : _("Mute"), "row.mute");
            
            if (!is_system_chat) {
                // Block/Unblock
                bool is_blocked = stream_interactor.get_module<BlockingManager>(BlockingManager.IDENTITY).is_blocked(conversation.account, conversation.counterpart);
                notifications.append(is_blocked ? _("Unblock") : _("Block"), "row.block");
            }
            
            history.append(_("Delete Conversation History"), "row.clear");
            closing.append(_("Close"), "row.close");
            if (!is_system_chat) {
                var roster = stream_interactor.get_module<RosterManager>(RosterManager.IDENTITY);
                if (roster.get_roster_item(conversation.account, conversation.counterpart) != null) {
                    removal.append(_("Remove Contact"), "row.remove");
                } else if (!conversation.counterpart.equals_bare(conversation.account.bare_jid) &&
                        !stream_interactor.get_module<PresenceManager>(PresenceManager.IDENTITY).is_subscription_suppressed(conversation.account, conversation.counterpart)) {
                    details.append(_("Add to Contacts"), "row.add-contact");
                    var add_action = new SimpleAction("add-contact", null);
                    add_action.activate.connect(() => {
                        if (cleanup_complete || roster.get_roster_item(conversation.account, conversation.counterpart) != null ||
                                stream_interactor.get_module<PresenceManager>(PresenceManager.IDENTITY).is_subscription_suppressed(conversation.account, conversation.counterpart)) return;
                        var dialog = AddContactDialog.for_account(stream_interactor, conversation.account);
                        dialog.jid = conversation.counterpart.bare_jid.to_string();
                        dialog.present(this.get_root() as Gtk.Widget);
                    });
                    action_group.add_action(add_action);
                }
            }
            
            // Details action
            var details_action = new SimpleAction("details", null);
            details_action.activate.connect(() => {
                var variant = new GLib.Variant.tuple(new GLib.Variant[] {new GLib.Variant.int32(conversation.id), new GLib.Variant.string("about")});
                GLib.Application.get_default().activate_action("open-conversation-details", variant);
            });
            action_group.add_action(details_action);
            
            // Edit action
            var edit_action = new SimpleAction("edit", null);
            edit_action.activate.connect(() => {
                show_edit_dialog();
            });
            action_group.add_action(edit_action);
            
            // Mute action
            var mute_action = new SimpleAction("mute", null);
            mute_action.activate.connect(() => {
                toggle_mute();
            });
            action_group.add_action(mute_action);
            
            // Block action
            var block_action = new SimpleAction("block", null);
            block_action.activate.connect(() => {
                toggle_block();
            });
            action_group.add_action(block_action);
            
            // Close conversation action
            var close_action = new SimpleAction("close", null);
            close_action.activate.connect(() => {
                GLib.Application.get_default().activate_action("close-conversation", new GLib.Variant.int32(conversation.id));
            });
            action_group.add_action(close_action);

            // Clear history action
            var clear_action = new SimpleAction("clear", null);
            clear_action.activate.connect(() => {
                show_clear_history_dialog();
            });
            action_group.add_action(clear_action);
            
            // Remove action
            var remove_action = new SimpleAction("remove", null);
            remove_action.activate.connect(() => {
                show_remove_dialog();
            });
            action_group.add_action(remove_action);
        }
        
        foreach (Menu section in new Menu[] { details, notifications, history, closing, removal }) {
            if (section.get_n_items() > 0) menu.append_section(null, section);
        }

        this.insert_action_group("row", action_group);
        
        // Dismiss any existing popover first
        dismiss_popover();
        
        // Show popover menu
        var popover = new PopoverMenu.from_model(menu);
        if (encryption_button != null) popover.add_child(encryption_button, "encryption-entry");
        active_popover = popover;
        popover.set_parent(this);
        popover.set_pointing_to({ (int)x, (int)y, 1, 1 });
        attach_context_popover_cleanup(this, popover);
        popover.popup();
    }

    private void show_edit_dialog() {
        var dialog = new Adw.AlertDialog(
            _("Edit Alias"),
            null
        );
        
        var entry = new Entry() {
            placeholder_text = _("Alias"),
            text = stream_interactor.get_module<RosterManager>(RosterManager.IDENTITY).get_roster_item(conversation.account, conversation.counterpart)?.name ?? ""
        };
        
        dialog.set_extra_child(entry);
        dialog.add_response("cancel", _("Cancel"));
        dialog.add_response("save", _("Save"));
        dialog.set_response_appearance("save", SUGGESTED);
        dialog.set_default_response("save");
        dialog.set_close_response("cancel");
        
        dialog.response.connect((response) => {
            if (response == "save") {
                string new_alias = entry.text.strip();
                if (new_alias.length > 0) {
                    stream_interactor.get_module<RosterManager>(RosterManager.IDENTITY).set_jid_handle(conversation.account, conversation.counterpart, new_alias);
                }
            }
        });
        
        dialog.present((Window)this.get_root());
    }

    private bool is_botmother_self_chat() {
        return conversation.type_ == Conversation.Type.CHAT
            && conversation.counterpart.equals_bare(conversation.account.bare_jid)
            && conversation.nickname == "Botmother";
    }

    private void toggle_mute() {
        bool currently_muted = (conversation.notify_setting == Conversation.NotifySetting.OFF);
        
        if (currently_muted) {
            // Unmute
            var dialog = new Adw.AlertDialog(
                _("Unmute contact?"),
                _("This will enable notifications from %s.").printf(conversation.counterpart.to_string())
            );
            dialog.add_response("cancel", _("Cancel"));
            dialog.add_response("unmute", _("Unmute"));
            dialog.set_response_appearance("unmute", SUGGESTED);
            dialog.set_default_response("unmute");
            dialog.set_close_response("cancel");
            
            dialog.response.connect((response) => {
                if (response == "unmute") {
                    conversation.notify_setting = Conversation.NotifySetting.DEFAULT;
                }
            });
            
            dialog.present((Window)this.get_root());
        } else {
            // Mute
            var dialog = new Adw.AlertDialog(
                _("Mute contact?"),
                _("This will disable notifications from %s.").printf(conversation.counterpart.to_string())
            );
            dialog.add_response("cancel", _("Cancel"));
            dialog.add_response("mute", _("Mute"));
            dialog.set_response_appearance("mute", DESTRUCTIVE);
            dialog.set_default_response("mute");
            dialog.set_close_response("cancel");
            
            dialog.response.connect((response) => {
                if (response == "mute") {
                    conversation.notify_setting = Conversation.NotifySetting.OFF;
                }
            });
            
            dialog.present((Window)this.get_root());
        }
    }

    private void toggle_block() {
        // XEP-0191 addresses stable user JIDs. room@service/nick is a
        // session-local MUC address and may belong to another person after a
        // rejoin, so GROUPCHAT_PM must fail closed here as well as in the menu.
        if (conversation.type_ != Conversation.Type.CHAT) return;
        bool currently_blocked = stream_interactor.get_module<BlockingManager>(BlockingManager.IDENTITY).is_blocked(conversation.account, conversation.counterpart);
        
        if (currently_blocked) {
            // Unblock
            var dialog = new Adw.AlertDialog(
                _("Unblock contact?"),
                _("This will allow %s to send you messages again.").printf(conversation.counterpart.to_string())
            );
            dialog.add_response("cancel", _("Cancel"));
            dialog.add_response("unblock", _("Unblock"));
            dialog.set_response_appearance("unblock", SUGGESTED);
            dialog.set_default_response("unblock");
            dialog.set_close_response("cancel");
            
            dialog.response.connect((response) => {
                if (response == "unblock") {
                    stream_interactor.get_module<BlockingManager>(BlockingManager.IDENTITY).unblock(conversation.account, conversation.counterpart);
                }
            });
            
            dialog.present((Window)this.get_root());
        } else {
            // Block
            var dialog = new Adw.AlertDialog(
                _("Block contact?"),
                _("This will prevent %s from sending you messages.").printf(conversation.counterpart.to_string())
            );
            dialog.add_response("cancel", _("Cancel"));
            dialog.add_response("block", _("Block"));
            dialog.set_response_appearance("block", DESTRUCTIVE);
            dialog.set_default_response("block");
            dialog.set_close_response("cancel");
            
            dialog.response.connect((response) => {
                if (response == "block") {
                    stream_interactor.get_module<BlockingManager>(BlockingManager.IDENTITY).block(conversation.account, conversation.counterpart);
                }
            });
            
            dialog.present((Window)this.get_root());
        }
    }

    private bool removing_contact = false;

    private void show_remove_dialog() {
        if (removing_contact) return;
        Conversation target = conversation;
        WeakRef parent_ref = WeakRef(this.get_root());
        var dialog = new Adw.AlertDialog(
            _("Remove contact?"),
            _("This will:\n• Delete all conversation history\n• Remove %s from your contact list\n\nThis action cannot be undone.").printf(conversation.counterpart.to_string())
        );
        dialog.add_response("cancel", _("Cancel"));
        dialog.add_response("remove", _("Remove"));
        dialog.set_response_appearance("remove", DESTRUCTIVE);
        dialog.set_default_response("cancel");
        dialog.set_close_response("cancel");
        
        dialog.response.connect((response) => {
            if (response == "remove") {
                if (removing_contact) return;
                removing_contact = true;
                var manager = stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY);
                manager.remove_contact_and_history.begin(target.account, target.counterpart, (obj, res) => {
                    RosterRemoveResult result = manager.remove_contact_and_history.end(res);
                    removing_contact = false;
                    var parent = parent_ref.get() as Gtk.Widget;
                    if (result != RosterRemoveResult.SUCCESS && parent != null && parent.get_root() != null)
                        Util.show_remove_contact_failure(parent, target.counterpart, result);
                });
            }
        });
        
        dialog.present((Window)this.get_root());
    }

    private void show_invite_dialog() {
        Util.show_muc_invite_dialog(conversation, stream_interactor, this.get_root() as Gtk.Window);
    }

    private void show_clear_history_dialog() {
        Util.show_clear_history_dialog(conversation, stream_interactor, (Window)this.get_root());
    }

    private void show_destroy_room_dialog() {
        if (destroy_in_progress) return;
        MucManager muc_manager = stream_interactor.get_module<MucManager>(
            MucManager.IDENTITY);
        MucManager.MucOwnerMutationContext? destroy_context =
            muc_manager.capture_current_owner_context(conversation.account,
                conversation.counterpart);
        if (destroy_context == null) {
            var error_dialog = new Adw.AlertDialog(
                _("Failed to destroy room"),
                _("The room action is not permitted for the current user state."));
            error_dialog.add_response("close", _("Close"));
            error_dialog.present((Window) this.get_root());
            return;
        }
        var dialog = new Adw.AlertDialog(
            _("Destroy Room?"),
            _("This permanently destroys the room on the server. Its message archive may also be deleted, depending on the server settings. Messages already stored on participants' devices are kept.")
        );
        dialog.add_response("cancel", _("Cancel"));
        dialog.add_response("destroy", _("Destroy"));
        dialog.set_response_appearance("destroy", DESTRUCTIVE);
        dialog.set_default_response("cancel");
        dialog.set_close_response("cancel");
        
        dialog.response.connect((response) => {
            if (response == "destroy") {
                if (destroy_in_progress) return;
                destroy_in_progress = true;
                Gtk.Window? parent_window = this.get_root() as Gtk.Window;
                muc_manager.destroy_room_detailed_in_context.begin(
                        conversation.account, (!) destroy_context, null,
                        (obj, res) => {
                    try {
                        MucDestroyResult destroy_result = muc_manager
                            .destroy_room_detailed_in_context.end(res);
                        // destroy_room now handles: bookmark removal + part + conversation close
                        if (destroy_result == MucDestroyResult.APPLIED_LOCAL_SYNC_WARNING) {
                            var warning_dialog = new Adw.AlertDialog(
                                _("Room was destroyed"),
                                _("The server destroyed the room, but DinoX could not confirm bookmark cleanup. If the bookmark remains after reconnecting, remove it manually."));
                            warning_dialog.add_response("close", _("Close"));
                            warning_dialog.present(parent_window);
                        }
                    } catch (GLib.Error e) {
                        destroy_in_progress = false;
                        var error_dialog = new Adw.AlertDialog(_("Failed to destroy room"), e.message);
                        error_dialog.add_response("close", _("Close"));
                        error_dialog.present(parent_window);
                    }
                });
            }
        });
        
        dialog.present((Window)this.get_root());
    }

    private void on_presence_changed(Jid jid, Account account) {
        if (account == conversation.account && jid.bare_jid.equals(conversation.counterpart)) {
            // For own-account conversations, the dot is managed by
            // on_own_status_changed() using the global status the user set.
            // Received presence from other resources (e.g. Monal-iOS still
            // "online") would overwrite it with incorrect data, so skip.
            foreach (Account acc in stream_interactor.get_accounts()) {
                if (acc.bare_jid.equals(conversation.counterpart)) {
                    return;
                }
            }
            update_status();
        }
    }

    /**
     * Called when the user changes their own global status.
     * If the conversation counterpart is one of the user's own accounts,
     * update the dot immediately using the new show value — bypassing
     * the Presence.Flag cache which won't be updated until the server
     * echoes the presence back.
     */
    private void on_own_status_changed(string show, string? status_msg) {
        if (conversation.type_ != Conversation.Type.CHAT) return;
        foreach (Account acc in stream_interactor.get_accounts()) {
            if (acc.bare_jid.equals(conversation.counterpart)) {
                // Counterpart is one of our own accounts — update immediately
                string emoji = "🟢";
                if (show == "away") {
                    emoji = "🟠";
                } else if (show == "dnd") {
                    emoji = "🔴";
                } else if (show == "xa") {
                    emoji = "⭕";
                }
                status_label.label = emoji;
                status_label.visible = true;
                return;
            }
        }
    }

    private void update_status() {
        if (conversation.type_ != Conversation.Type.CHAT) {
            status_label.visible = false;
            return;
        }

        Gee.List<Jid>? full_jids = stream_interactor.get_module<PresenceManager>(PresenceManager.IDENTITY).get_full_jids(conversation.counterpart, conversation.account);
        
        string? best_show = null;
        if (full_jids != null) {
            foreach (Jid full_jid in full_jids) {
                string? show = stream_interactor.get_module<PresenceManager>(PresenceManager.IDENTITY).get_last_show(full_jid, conversation.account);
                if (show == null) continue;
                
                if (best_show == null) {
                    best_show = show;
                } else {
                    if (score_show(show) > score_show(best_show)) {
                        best_show = show;
                    }
                }
            }
        }

        if (best_show != null) {
            status_label.visible = true;
            string emoji = "🟢";

            if (best_show == "away") {
                emoji = "🟠";
            } else if (best_show == "dnd") {
                emoji = "🔴";
            } else if (best_show == "xa") {
                emoji = "⭕";
            }

            status_label.label = emoji;
        } else {
            status_label.visible = false;
        }
    }

    private int score_show(string show) {
        if (show == "chat") return 5;
        if (show == "online") return 4;
        if (show == "away") return 3;
        if (show == "dnd") return 2;
        if (show == "xa") return 1;
        return 0;
    }

    private void update_private_room_indicator() {
        if (conversation.type_ != Conversation.Type.GROUPCHAT) {
            private_room_image.visible = false;
            return;
        }

        bool is_private = stream_interactor.get_module<MucManager>(MucManager.IDENTITY).is_private_room(
            conversation.account, 
            conversation.counterpart
        );
        
        private_room_image.visible = is_private;
        sync_compact_indicators();
    }
}

}

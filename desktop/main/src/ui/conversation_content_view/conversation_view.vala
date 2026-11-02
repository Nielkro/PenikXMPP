/*
 * Copyright (C) 2025 Ralf Peter <dinox@handwerker.jetzt>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

using Gee;
using Gtk;
using Gdk;
using Graphene;

using Dino.Entities;

namespace Dino.Ui.ConversationSummary {

[GtkTemplate (ui = "/im/dinox/dinox/conversation_content_view/view.ui")]
public class ConversationView : Widget, Plugins.ConversationItemCollection, Plugins.NotificationCollection {
    static construct {
        typeof(Dino.Ui.SizeRequestBox).ensure();
    }

    private const int MESSAGE_MENU_BOX_OFFSET = 0;
    private const int MAX_CONTENT_ITEMS = 200;
    private const int MAX_STATUS_ITEMS = 200;
    private const uint CONTENT_SETTLE_CHECK_MS = 40;
    private const uint CONTENT_SETTLE_STABLE_REQUIRED_CHECKS = 1;
    private const uint CONTENT_SETTLE_MAX_CHECKS = 6;

    public Conversation? conversation { get; private set; }

    [GtkChild] public unowned ScrolledWindow scrolled;
    [GtkChild] private unowned Revealer notification_revealer;
    [GtkChild] private unowned Gtk.Box message_menu_box;
    [GtkChild] private unowned Gtk.Box notifications;
    [GtkChild] private unowned Gtk.Box main;
    [GtkChild] private unowned Widget main_wrap_box;

    private HashMap<string, Widget> action_buttons = new HashMap<string, Widget>();
    private Gee.List<Dino.Plugins.MessageAction>? message_actions = null;
    private Label message_action_target_label;

    private StreamInteractor stream_interactor;
    private ContentItemStore? visibility_store;
    private ulong visibility_handler_id = 0;
    private Gee.TreeSet<ContentMetaItem> content_items = new Gee.TreeSet<ContentMetaItem>(compare_content_meta_items);
    private Gee.TreeSet<Plugins.MetaConversationItem> meta_items = new TreeSet<Plugins.MetaConversationItem>(compare_meta_items);
    private Gee.HashMap<Plugins.MetaConversationItem, ConversationItemSkeleton> item_item_skeletons = new Gee.HashMap<Plugins.MetaConversationItem, ConversationItemSkeleton>();
    private Gee.HashMap<Plugins.MetaConversationItem, Widget> widgets = new Gee.HashMap<Plugins.MetaConversationItem, Widget>();
    private Gee.List<Widget> widget_order = new Gee.ArrayList<Widget>();
    private ContentProvider content_populator;
    private SubscriptionNotification subscription_notification;
    private ExpiryNotification expiry_notification;
    private VoiceRequestNotification voice_request_notification;
    private RealJidVisibilityNotification real_jid_visibility_notification;

    private double? was_value;
    private double? was_upper;
    private double? was_page_size;

    private bool is_reloading = false;
    private bool at_current_content = true;
    private bool reload_messages = true;
    Widget currently_highlighted = null;
    ContentMetaItem? current_meta_item = null;
    private FileTransfer? current_action_file_transfer = null;
    private Message? current_action_message = null;
    private ulong current_action_transfer_message_id_handler_id = 0;
    private ulong current_action_transfer_info_handler_id = 0;
    private ulong current_action_message_stanza_id_handler_id = 0;
    private ulong current_action_message_server_id_handler_id = 0;

    private uint conversation_load_generation = 0;
    private bool initial_scroll_pending = false;
    private bool content_settle_pending = false;
    private bool content_settle_scroll_to_bottom = true;
    private uint content_settle_source_id = 0;
    private uint content_settle_checks = 0;
    private uint content_settle_stable_checks = 0;
    private double content_settle_last_upper = -1;
    private double content_settle_last_page_size = -1;
    private int64 content_settle_started_us = 0;
    private ChatFocusScroll focus_scroll;
    private ChatScrollMotion scroll_motion;
    private ChatScrollLayout scroll_layout;
    private bool repositioning_scroll = false;
    private uint highlight_source_id = 0;
    private Widget? jump_highlight = null;
    private bool bottom_snap_pending = false;
    private uint around_message_jump_source_id = 0;
    private int64 pending_init_clear_work_us = 0;
    private int64 pending_init_init_work_us = 0;

    private bool bulk_inserting_latest = false;
    private FrameRenderQueue initial_render_queue;
    // Signal handler IDs for proper cleanup in dispose()
    private ulong vadjust_changed_handler_id;
    private ulong vadjust_value_handler_id;
    private ulong add_meta_notification_handler_id;
    private ulong remove_meta_notification_handler_id;
    private ulong message_correction_handler_id;

    construct {
        initial_render_queue = new FrameRenderQueue(this);
        focus_scroll = new ChatFocusScroll((Gtk.Viewport) scrolled.get_child());
        scroll_motion = new ChatScrollMotion(scrolled);
        scroll_layout = new ChatScrollLayout(scrolled, main);
        this.layout_manager = scroll_layout;
        main_wrap_box.layout_manager = new BinLayout();

        // Setup all message menu buttons
        message_action_target_label = new Label("") {
            ellipsize = Pango.EllipsizeMode.END,
            max_width_chars = 12,
            margin_start = 6,
            margin_end = 2,
            valign = Align.CENTER
        };
        message_action_target_label.add_css_class("caption");
        message_action_target_label.add_css_class(
            "message-action-target-label");
        message_menu_box.append(message_action_target_label);

        var correction_button = new Button() { name="correction" };
        correction_button.add_css_class("message-action-button");
        correction_button.clicked.connect((button) => {
            on_action_button_clicked("correction", null);
        });
        action_buttons["correction"] = correction_button;
        message_menu_box.append(correction_button);

        var reaction_button = new MenuButton() { name="reaction" };
        reaction_button.add_css_class("message-action-button");
        EmojiChooser chooser = new EmojiChooser();
        chooser.emoji_picked.connect((emoji) => {
            on_action_button_clicked("reaction", new GLib.Variant.string(emoji));
        });
        Util.set_menu_button_popover(reaction_button, chooser);
        action_buttons["reaction"] = reaction_button;
        message_menu_box.append(reaction_button);

        var reply_button = new Button() { name="reply" };
        reply_button.add_css_class("message-action-button");
        reply_button.clicked.connect((button) => {
            on_action_button_clicked("reply", null);
        });
        action_buttons["reply"] = reply_button;
        message_menu_box.append(reply_button);

        var delete_button = new Button() { name="delete" };
        delete_button.add_css_class("message-action-button");
        delete_button.clicked.connect((button) => {
            on_action_button_clicked("delete", null);
        });
        action_buttons["delete"] = delete_button;
        message_menu_box.append(delete_button);

        var kick_button = new Button() { name="kick" };
        kick_button.add_css_class("message-action-button");
        kick_button.clicked.connect((button) => {
            on_action_button_clicked("kick", null);
        });
        action_buttons["kick"] = kick_button;
        message_menu_box.append(kick_button);

        var ban_button = new Button() { name="ban" };
        ban_button.add_css_class("message-action-button");
        ban_button.clicked.connect((button) => {
            on_action_button_clicked("ban", null);
        });
        action_buttons["ban"] = ban_button;
        message_menu_box.append(ban_button);

        var menu_button = new MenuButton() { name="menu", tooltip_text=_("More actions") };
        action_buttons["menu"] = menu_button;
        message_menu_box.append(menu_button);

        SimpleAction action_action = new SimpleAction("action", VariantType.STRING);
        action_action.activate.connect((parameter) => {
            on_action_button_clicked(parameter.get_string());
        });
        SimpleActionGroup action_group = new SimpleActionGroup();
        action_group.add_action(action_action);
        this.insert_action_group("action", action_group);
    }

    public ConversationView init(StreamInteractor stream_interactor) {
        this.stream_interactor = stream_interactor;
        stream_interactor.get_module<MessageDeletion>(MessageDeletion.IDENTITY).item_deleted.connect(on_item_deleted);
        visibility_store = stream_interactor.get_module<ContentItemStore>(ContentItemStore.IDENTITY);
        visibility_handler_id = connect_visibility_updates(this, (!) visibility_store);
        message_correction_handler_id = stream_interactor
            .get_module<MessageCorrection>(MessageCorrection.IDENTITY)
            .received_correction.connect(on_item_corrected);
        // Observe the complete range update once, before the frame is drawn.
        vadjust_changed_handler_id = scrolled.vadjustment.changed.connect(on_upper_notify);
        vadjust_value_handler_id = scrolled.vadjustment.notify["value"].connect(on_value_notify);

        content_populator = new ContentProvider(stream_interactor);
        subscription_notification = new SubscriptionNotification(stream_interactor);
        expiry_notification = new ExpiryNotification(stream_interactor);
        voice_request_notification = new VoiceRequestNotification(
            stream_interactor);
        real_jid_visibility_notification =
            new RealJidVisibilityNotification(stream_interactor);

        add_meta_notification_handler_id = add_meta_notification.connect(on_add_meta_notification);
        remove_meta_notification_handler_id = remove_meta_notification.connect(on_remove_meta_notification);

        Application app = GLib.Application.get_default() as Application;
        app.plugin_registry.register_conversation_addition_populator(new ChatStatePopulator(stream_interactor));
        app.plugin_registry.register_conversation_addition_populator(new DateSeparatorPopulator(stream_interactor));
        app.plugin_registry.register_conversation_addition_populator(new UnreadIndicatorPopulator(stream_interactor));
        app.plugin_registry.register_conversation_addition_populator(new StatusPopulator(stream_interactor));

        // Rather than connecting to the leave event of the main_event_box directly,
        // we connect to the parent event box that also wraps the overlaying message_menu_box.
        // This eliminates the unwanted leave events emitted on the main_event_box when hovering
        // the overlaying menu buttons.
        EventControllerMotion main_wrap_motion_events = new EventControllerMotion();
        main_wrap_box.add_controller(main_wrap_motion_events);
        main_wrap_motion_events.leave.connect(on_leave_notify_event);
        // The buttons of the overlaying message_menu_box may partially overlap the adjacent
        // conversation items. We connect to the main_event_box directly to avoid emitting
        // the pointer motion events as long as the pointer is above the message menu.
        // This ensures that the currently highlighted item remains unchanged when the pointer
        // reaches the overlapping part of a button.
        EventControllerMotion main_motion_events = new EventControllerMotion();
        main.add_controller(main_motion_events);
        main_motion_events.motion.connect(update_highlight);

        // Process touch events and capture phase to allow highlighting a message without cursor
        GestureClick click_controller = new GestureClick();
        click_controller.touch_only = true;
        click_controller.propagation_phase = Gtk.PropagationPhase.CAPTURE;
        main_wrap_box.add_controller(click_controller);
        click_controller.pressed.connect_after((n, x, y) => {
            update_highlight(x, y);
        });

        return this;
    }

    public void activate_last_message_correction() {
        Gee.BidirIterator<Plugins.MetaConversationItem> iter = content_items.bidir_iterator();
        iter.last();
        for (int i = 0; i < 10 && content_items.size > i; i++) {
            Plugins.MetaConversationItem item = iter.get();
            MessageMetaItem message_item = item as MessageMetaItem;
            if (message_item != null) {
                if ((conversation.type_ == Conversation.Type.CHAT && message_item.jid.equals_bare(conversation.account.bare_jid)) ||
                        (conversation.type_ == Conversation.Type.GROUPCHAT &&
                        message_item.jid.equals(stream_interactor.get_module<MucManager>(MucManager.IDENTITY).get_own_jid(conversation.counterpart, conversation.account)))) {
                    message_item.in_edit_mode = true;
                    break;
                }
            }
            iter.previous();
        }
    }

    private bool is_highlight_fixed() {
        foreach (Widget widget in action_buttons.values) {
            MenuButton? menu_button = widget as MenuButton;
            if (menu_button != null && menu_button.popover != null && menu_button.popover.visible) return true;

            ToggleButton? toggle_button = widget as ToggleButton;
            if (toggle_button != null && toggle_button.active) return true;
        }
        return false;
    }

    private void on_leave_notify_event() {
        if (!this.get_realized()) return;
        if (is_highlight_fixed()) return;

        clear_message_action_target();
    }

    private void clear_message_action_target() {
        if (currently_highlighted != null) {
            currently_highlighted.remove_css_class("highlight");
        }
        disconnect_current_action_observers();
        currently_highlighted = null;
        current_meta_item = null;
        message_actions = null;
        message_action_target_label.label = "";
        message_action_target_label.tooltip_text = null;
        message_menu_box.visible = false;
    }

    private void update_highlight(double x, double y) {
        if (!main.get_realized()) return;
        if (is_highlight_fixed()) return;

        // Use GTK pick() to find the widget under the pointer in O(1),
        // then resolve the direct skeleton child. Embedded reply quotes are
        // references to another message, so they deliberately expose no row
        // actions; clicking the quote still jumps to the referenced message.
        Widget? picked = main.pick(x, y, Gtk.PickFlags.DEFAULT);
        Widget? w = MessageActionTarget.find_row_for_pointer(main, picked);

        // Pointer motion within the same row must not rebuild every action and
        // query its protocol capabilities over and over. Still refresh the
        // overlay position because asynchronous content can resize the row.
        if (w != null && w == currently_highlighted) {
            Graphene.Rect current_bounds;
            if (((!) w).compute_bounds(main, out current_bounds)) {
                message_menu_box.margin_top = (int) current_bounds.origin.y;
            }
            return;
        }

        clear_message_action_target();

        if (w == null) {
            return;
        }

        // Reverse-lookup: find the MetaConversationItem for this widget.
        // Use item_item_skeletons (keyed by item) — iterate only until match.
        foreach (Plugins.MetaConversationItem item in item_item_skeletons.keys) {
            if (item_item_skeletons[item].get_widget() == w) {
                current_meta_item = item as ContentMetaItem;
                break;
            }
        }

        connect_current_action_observers();

        update_message_menu();

        if (current_meta_item != null && message_actions != null &&
                !((!) message_actions).is_empty) {
            // Highlight widget
            currently_highlighted = w;
            currently_highlighted.add_css_class("highlight");

            // Position menu at the widget's position
            Graphene.Rect bounds;
            if (w.compute_bounds(main, out bounds)) {
                message_menu_box.margin_top = (int)(bounds.origin.y);
            }
        } else {
            // During edit mode a message intentionally exposes no actions.
            // Do not cache that row as highlighted: after Cancel, the next
            // pointer motion must rebuild the now-valid action list.
            disconnect_current_action_observers();
            current_meta_item = null;
            message_actions = null;
        }
    }

    private void connect_current_action_observers() {
        if (current_meta_item == null || conversation == null) return;

        FileItem? file_item = ((!) current_meta_item).content_item as FileItem;
        if (file_item != null) {
            current_action_file_transfer = ((!) file_item).file_transfer;
            current_action_transfer_message_id_handler_id =
                ((!) current_action_file_transfer).notify["message-db-id"].connect(
                    on_current_action_transfer_changed);
            current_action_transfer_info_handler_id =
                ((!) current_action_file_transfer).notify["info"].connect(
                    on_current_action_transfer_changed);
        }
        connect_current_action_message_observer();
    }

    private void on_current_action_transfer_changed() {
        connect_current_action_message_observer();
        update_message_menu();
    }

    private void connect_current_action_message_observer() {
        disconnect_current_action_message_observer();
        if (current_meta_item == null || conversation == null) return;

        current_action_message = stream_interactor
            .get_module<ContentItemStore>(ContentItemStore.IDENTITY)
            .get_message_for_content_item((!) conversation,
                ((!) current_meta_item).content_item);
        if (current_action_message == null) return;

        Message message = (!) current_action_message;
        current_action_message_stanza_id_handler_id =
            message.notify["stanza-id"].connect(update_message_menu);
        current_action_message_server_id_handler_id =
            message.notify["server-id"].connect(update_message_menu);
    }

    private void disconnect_current_action_observers() {
        disconnect_current_action_message_observer();
        if (current_action_file_transfer != null) {
            if (current_action_transfer_message_id_handler_id != 0) {
                ((!) current_action_file_transfer).disconnect(
                    current_action_transfer_message_id_handler_id);
            }
            if (current_action_transfer_info_handler_id != 0) {
                ((!) current_action_file_transfer).disconnect(
                    current_action_transfer_info_handler_id);
            }
        }
        current_action_file_transfer = null;
        current_action_transfer_message_id_handler_id = 0;
        current_action_transfer_info_handler_id = 0;
    }

    private void disconnect_current_action_message_observer() {
        if (current_action_message != null) {
            if (current_action_message_stanza_id_handler_id != 0) {
                ((!) current_action_message).disconnect(
                    current_action_message_stanza_id_handler_id);
            }
            if (current_action_message_server_id_handler_id != 0) {
                ((!) current_action_message).disconnect(
                    current_action_message_server_id_handler_id);
            }
        }
        current_action_message = null;
        current_action_message_stanza_id_handler_id = 0;
        current_action_message_server_id_handler_id = 0;
    }

    private void update_message_menu() {
        if (current_meta_item == null) {
            message_actions = null;
            message_menu_box.visible = false;
            return;
        }

        message_actions = current_meta_item.get_item_actions(Plugins.WidgetType.GTK4);

        if (message_actions != null) {
            string display_name = Util.get_participant_display_name(
                stream_interactor, conversation, current_meta_item.jid, true);
            string target_label =
                MessageActionTarget.format_target_label(display_name);
            message_action_target_label.label = target_label;
            message_action_target_label.tooltip_text = target_label;
            message_menu_box.visible = true;

            Menu menu_model = new Menu();
            ((MenuButton)action_buttons["menu"]).menu_model = menu_model;

            foreach (Widget widget in action_buttons.values) {
                widget.visible = false;
            }

            // Configure as many buttons as we need with the actions for the current meta item
            foreach (var message_action in message_actions) {
                if (message_action.shortcut_action) {
                    Widget button_widget = action_buttons[message_action.name];
                    button_widget.visible = true;

                    if (message_action.name == "reaction") {
                        MenuButton button = (MenuButton) button_widget;
                        button.sensitive = message_action.sensitive;
                        button.icon_name = message_action.icon_name;
                        button.tooltip_text = Util.string_if_tooltips_active(message_action.tooltip);
                    } else if (message_action.callback != null) {
                        Button button = (Button) button_widget;
                        button.sensitive = message_action.sensitive;
                        button.icon_name = message_action.icon_name;
                        button.tooltip_text = Util.string_if_tooltips_active(message_action.tooltip);
                    }
                } else {
                    MenuItem item = new MenuItem(message_action.tooltip, null);
                    item.set_action_and_target_value("action.action", new GLib.Variant.string(message_action.name));
                    menu_model.append_item(item);
                    action_buttons["menu"].visible = true;
                }
            }
        } else {
            message_menu_box.visible = false;
        }
    }

    public void initialize_for_conversation(Conversation? conversation, bool force_reload = false) {
        int64 t0_us = Dino.Ui.UiTiming.now_us();
        cancel_around_message_jump();
        if (conversation == this.conversation && at_current_content && !force_reload) {
            // Just make sure we are scrolled down — instantly, no animation
            scrolled.vadjustment.value = scrolled.vadjustment.upper;
            return;
        }

        prepare_content_rebuild();
        subscription_notification.clear();

        int64 t_clear_us = Dino.Ui.UiTiming.now_us();
        clear();
        pending_init_clear_work_us = Dino.Ui.UiTiming.now_us() - t_clear_us;
        Dino.Ui.UiTiming.log_ms("ConversationView.initialize_for_conversation: clear", t_clear_us);

        if (conversation == null) {
            // Close old populators before unsetting conversation —
            // otherwise they remain active and may call insert_item()
            // with this.conversation == null, causing NULL assertions.
            Dino.Application app = Dino.Application.get_default();
            if (this.conversation != null) {
                foreach (Plugins.ConversationItemPopulator populator in app.plugin_registry.conversation_addition_populators) {
                    populator.close(this.conversation);
                }
                foreach (Plugins.NotificationPopulator populator in app.plugin_registry.notification_populators) {
                    populator.close(this.conversation);
                }
            }
            clear_notifications();
            this.conversation = null;
            main.opacity = 1;
            return;
        }

        int64 t_init_us = Dino.Ui.UiTiming.now_us();
        initialize_for_conversation_(conversation);
        pending_init_init_work_us = Dino.Ui.UiTiming.now_us() - t_init_us;
        Dino.Ui.UiTiming.log_ms("ConversationView.initialize_for_conversation: initialize_for_conversation_", t_init_us);

        // Start a new generation so delayed work from older conversation loads
        // can no longer affect this view.
        conversation_load_generation++;

        int64 t_display_us = Dino.Ui.UiTiming.now_us();
        display_latest(conversation_load_generation, t0_us, t_display_us);
    }

    private void prepare_content_rebuild() {
        cancel_content_settle();
        cancel_around_message_jump();

        // Rows are filled over multiple frames. Keep layout anchoring active
        // during that work; do not fade or rebuild the whole timeline again.
        main.opacity = 1;
        message_menu_box.visible = false;
    }

    private void cancel_content_settle() {
        pause_content_settle();
        content_settle_pending = false;
        initial_scroll_pending = false;
        content_settle_started_us = 0;
    }

    private void pause_content_settle() {
        if (content_settle_source_id != 0) {
            Source.remove(content_settle_source_id);
            content_settle_source_id = 0;
        }
        content_settle_checks = 0;
        content_settle_stable_checks = 0;
        content_settle_last_upper = -1;
        content_settle_last_page_size = -1;
    }

    private void cancel_around_message_jump() {
        scroll_motion.cancel();
        if (highlight_source_id != 0) {
            Source.remove(highlight_source_id);
            highlight_source_id = 0;
        }
        if (jump_highlight != null) jump_highlight.remove_css_class("highlight-once");
        jump_highlight = null;
        if (around_message_jump_source_id != 0) {
            Source.remove(around_message_jump_source_id);
            around_message_jump_source_id = 0;
        }
        reload_messages = true;
    }

    private void settle_content_after_layout(uint generation,
            bool scroll_to_bottom = true) {
        cancel_content_settle();
        scroll_layout.preserve_visible_row = false;
        content_settle_pending = true;
        content_settle_scroll_to_bottom = scroll_to_bottom;
        initial_scroll_pending = scroll_to_bottom;
        content_settle_started_us = Dino.Ui.UiTiming.now_us();
        resume_content_settle(generation);
    }

    private bool has_usable_viewport() {
        return get_mapped() && scrolled.get_mapped() &&
            scrolled.get_width() > 0 && scrolled.get_height() > 0 &&
            scrolled.vadjustment.page_size > 0;
    }

    private void resume_content_settle(uint generation) {
        if (content_settle_pending && content_settle_source_id == 0 &&
                has_usable_viewport()) {
            schedule_content_settle_check(generation, content_settle_scroll_to_bottom);
        }
    }

    public override void map() {
        base.map();
        resume_content_settle(conversation_load_generation);
        if (bottom_snap_pending) queue_bottom_snap();
    }

    public override void unmap() {
        cancel_around_message_jump();
        // A hidden navigation page has no final viewport to settle against.
        // Preserve its request, but do not keep a timer running offscreen.
        pause_content_settle();
        cancel_bottom_snap(true);
        base.unmap();
    }

    private void schedule_content_settle_check(uint generation,
            bool scroll_to_bottom) {
        uint source_id = 0;
        source_id = Timeout.add(CONTENT_SETTLE_CHECK_MS, () => {
            if (content_settle_source_id != source_id) {
                return Source.REMOVE;
            }
            content_settle_source_id = 0;
            run_content_settle_check(generation, scroll_to_bottom);
            return Source.REMOVE;
        });
        content_settle_source_id = source_id;
    }

    private void run_content_settle_check(uint generation,
            bool scroll_to_bottom) {
        if (generation != conversation_load_generation) {
            cancel_content_settle();
            return;
        }
        if (!has_usable_viewport()) {
            pause_content_settle();
            return;
        }

        // Empty row shells are not a settled history viewport. Keep the
        // initial bottom anchor and suppress paging until their content exists.
        if (initial_render_queue.pending) {
            content_settle_checks = 0;
            content_settle_stable_checks = 0;
            content_settle_last_upper = -1;
            content_settle_last_page_size = -1;
            schedule_content_settle_check(generation, scroll_to_bottom);
            return;
        }

        double upper = scrolled.vadjustment.upper;
        double page_size = scrolled.vadjustment.page_size;
        bool stable = content_settle_last_upper >= 0 &&
            (upper - content_settle_last_upper).abs() < 0.5 &&
            (page_size - content_settle_last_page_size).abs() < 0.5;

        content_settle_last_upper = upper;
        content_settle_last_page_size = page_size;
        content_settle_checks++;

        if (stable) {
            content_settle_stable_checks++;
        } else {
            content_settle_stable_checks = 0;
        }

        bool stability_reached =
            content_settle_stable_checks >= CONTENT_SETTLE_STABLE_REQUIRED_CHECKS;
        bool max_checks_reached =
            content_settle_checks >= CONTENT_SETTLE_MAX_CHECKS;

        if (!stability_reached && !max_checks_reached) {
            schedule_content_settle_check(generation, scroll_to_bottom);
            return;
        }

        string settle_reason = stability_reached
            ? "stable"
            : "max_checks";
        if (scroll_to_bottom) {
            scrolled.vadjustment.value = double.max(0, upper - page_size);
        }
        // The value notification above is programmatic. Only subsequent
        // scrolling may request another history page.
        initial_scroll_pending = false;
        content_settle_pending = false;
        was_upper = upper;
        was_page_size = page_size;
        was_value = scrolled.vadjustment.value;
        scroll_layout.preserve_visible_row = true;
        main.opacity = 1;
        if (Dino.Ui.UiTiming.enabled()) {
            GLib.message("UI-TIMING ConversationView.settle_content_after_layout: reason=%s checks=%u",
                settle_reason, content_settle_checks);
            if (content_settle_started_us != 0) {
                Dino.Ui.UiTiming.log_ms(
                    "ConversationView.settle_content_after_layout: total",
                    content_settle_started_us);
            }
        }
        content_settle_started_us = 0;
        // A short, non-scrollable first page cannot produce a user value
        // change yet. Fill it only after this mapped layout has settled.
        if (scroll_to_bottom && upper <= page_size) on_value_notify();
    }

    private void scroll_and_highlight_item(Plugins.MetaConversationItem target, uint duration = 500) {
        Widget widget = null;
        int h = 0;
        foreach (Plugins.MetaConversationItem item in meta_items) {
            widget = widgets[item];
            if (target == item) {
                break;
            }
            h += widget.get_height();
        }
        if (widget != widgets[target]) {
            warning("Target item widget not reached");
            return;
        }
        double target_height = h - scrolled.vadjustment.page_size * 1/3;
        uint generation = conversation_load_generation;
        scroll_motion.animate_to(target_height, duration, () => {
            if (generation != conversation_load_generation) return;
            jump_highlight = widget;
            widget.remove_css_class("highlight-once");
            widget.add_css_class("highlight-once");
            highlight_source_id = Timeout.add(5000, () => {
                highlight_source_id = 0;
                if (jump_highlight != null) jump_highlight.remove_css_class("highlight-once");
                jump_highlight = null;
                return Source.REMOVE;
            });
        });
    }

    public void initialize_around_message(Conversation conversation, ContentItem content_item) {
        // A pending normal-chat settle would snap to the bottom after this
        // search jump, including the early-return path for an existing item.
        cancel_content_settle();
        cancel_around_message_jump();
        cancel_bottom_snap();
        main.opacity = 1;
        if (conversation == this.conversation) {
            ContentMetaItem? matching_item = content_items.first_match(it => it.content_item.id == content_item.id);
            if (matching_item != null) {
                scroll_and_highlight_item(matching_item);
                return;
            }
        }
        clear();
        initialize_for_conversation_(conversation);
        Gee.List<ContentMetaItem> before_items = content_populator.populate_before(conversation, content_item, 40);
        foreach (ContentMetaItem item in before_items) {
            do_insert_item(item);
        }
        ContentMetaItem meta_item = content_populator.get_content_meta_item(content_item);
        if (insert_new(meta_item) != null) {
            content_items.add(meta_item);
            meta_items.add(meta_item);
        }

        Gee.List<ContentMetaItem> after_items = content_populator.populate_after(conversation, content_item, 40);
        foreach (ContentMetaItem item in after_items) {
            do_insert_item(item);
        }
        if (after_items.size == 40) {
            at_current_content = false;
        }

        uint around_message_generation = conversation_load_generation;

        // Compute where to jump to for centered message, jump, highlight.
        reload_messages = false;
        uint jump_source_id = 0;
        jump_source_id = Timeout.add(700, () => {
            if (around_message_jump_source_id != jump_source_id) {
                return false;
            }
            around_message_jump_source_id = 0;
            if (around_message_generation != conversation_load_generation ||
                    this.conversation != conversation ||
                    !widgets.has_key(meta_item)) {
                return false;
            }
            scroll_and_highlight_item(meta_item, 300);
            reload_messages = true;
            return false;
        });
        around_message_jump_source_id = jump_source_id;
    }

    private void initialize_for_conversation_(Conversation? conversation) {
        if (this.conversation == conversation) {
            debug("Re-initialized for %s", conversation.counterpart.bare_jid.to_string());
        }
        // Deinitialize old conversation
        Dino.Application app = Dino.Application.get_default();
        if (this.conversation != null) {
            foreach (Plugins.ConversationItemPopulator populator in app.plugin_registry.conversation_addition_populators) {
                populator.close(this.conversation);
            }
            foreach (Plugins.NotificationPopulator populator in app.plugin_registry.notification_populators) {
                populator.close(this.conversation);
            }
        }

        // Clear data structures
        clear_notifications();
        this.conversation = conversation;

        // Init for new conversation
        foreach (Plugins.ConversationItemPopulator populator in app.plugin_registry.conversation_addition_populators) {
            populator.init(conversation, this, Plugins.WidgetType.GTK4);
        }
        content_populator.init(this, conversation, Plugins.WidgetType.GTK4);
        subscription_notification.init(conversation, this);
        expiry_notification.init(conversation, this);
        voice_request_notification.init(conversation, this);
        real_jid_visibility_notification.init(conversation, this);
    }

    private void display_latest(uint generation, int64 init_t0_us, int64 init_t_display_us) {
        int64 t_pop_us = Dino.Ui.UiTiming.now_us();
        Gee.List<ContentMetaItem> items = content_populator.populate_latest(conversation, 40);
        int64 populate_work_us = Dino.Ui.UiTiming.now_us() - t_pop_us;
        Dino.Ui.UiTiming.log_ms("ConversationView.display_latest: populate_latest", t_pop_us);

        int64 insert_work_us = 0;
        int64 slowest_item_work_us = 0;

        if (generation != conversation_load_generation) {
            return;
        }

        initial_scroll_pending = true;
        reload_messages = true;
        bulk_inserting_latest = true;

        foreach (ContentMetaItem item in items) {
            int64 item_start_us = Dino.Ui.UiTiming.now_us();
            do_insert_item(item);
            int64 item_work_us = Dino.Ui.UiTiming.now_us() - item_start_us;
            insert_work_us += item_work_us;
            if (item_work_us > slowest_item_work_us) {
                slowest_item_work_us = item_work_us;
            }
        }

        bulk_inserting_latest = false;
        prune_oldest_items();

        // The bottom of the history is visible first. Populate those rows
        // before older offscreen messages, with one shared budget per frame.
        var render_iter = meta_items.bidir_iterator();
        if (render_iter.last()) {
            do {
                var skeleton = item_item_skeletons[render_iter.get()];
                if (skeleton != null)
                    ConversationItemSkeleton.queue_initialization(skeleton,
                        initial_render_queue);
            } while (render_iter.previous());
        }

        // Force the scroll adjustment to snap to the bottom on the next layout pass.
        was_upper = null;

        // Finished inserting.
        Dino.Ui.UiTiming.log_ms("ConversationView.display_latest: insert_items", Dino.Ui.UiTiming.now_us() - insert_work_us);
        Dino.Ui.UiTiming.log_ms("ConversationView.display_latest: insert_items.slowest_item", Dino.Ui.UiTiming.now_us() - slowest_item_work_us);

        Application app = GLib.Application.get_default() as Application;
        int64 t_notif_us = Dino.Ui.UiTiming.now_us();
        foreach (Plugins.NotificationPopulator populator in app.plugin_registry.notification_populators) {
            populator.init(conversation, this, Plugins.WidgetType.GTK4);
        }
        int64 notif_work_us = Dino.Ui.UiTiming.now_us() - t_notif_us;
        Dino.Ui.UiTiming.log_ms("ConversationView.display_latest: notification_populators.init", t_notif_us);
        settle_content_after_layout(generation);

        int64 total_work_us = populate_work_us + insert_work_us + notif_work_us;
        Dino.Ui.UiTiming.log_ms("ConversationView.display_latest: total", Dino.Ui.UiTiming.now_us() - total_work_us);

        // Mirror previous behaviour: we're at current content and scrolled to end once the content is inserted.
        at_current_content = true;

        Dino.Ui.UiTiming.log_ms("ConversationView.initialize_for_conversation: display_latest", Dino.Ui.UiTiming.now_us() - total_work_us);
        Dino.Ui.UiTiming.log_ms("ConversationView.initialize_for_conversation: total", Dino.Ui.UiTiming.now_us() - (pending_init_clear_work_us + pending_init_init_work_us + total_work_us));
    }

    public void insert_item(Plugins.MetaConversationItem item) {
        if (conversation == null) return;
        if (meta_items.size > 0) {
            bool after_last = meta_items.last().time.compare(item.time) <= 0;
            bool within_range = meta_items.last().time.compare(item.time) > 0 && meta_items.first().time.compare(item.time) < 0;
            bool accept = within_range || (at_current_content && after_last);
            if (!accept) {
                return;
            }
        }

        do_insert_item(item);

        // Live items used to bypass the retention window which is otherwise
        // only enforced while scrolling through history. In a busy,
        // continuously open MUC that retained every message widget forever.
        ContentMetaItem? content_item = item as ContentMetaItem;
        if (content_item != null) {
            if (at_current_content) {
                prune_oldest_items();
            } else {
                prune_content_items_around((!) content_item);
            }
        }
        if (item is MetaStatusItem) {
            prune_oldest_status_items();
        }
    }

    public void do_insert_item(Plugins.MetaConversationItem item) {
        lock (meta_items) {
            if (insert_new(item) == null) return;
            if (item is ContentMetaItem) {
                content_items.add((ContentMetaItem)item);
            }
            meta_items.add(item);
        }

        inserted_item(item);
    }

    private void remove_item(Plugins.MetaConversationItem item) {
        ConversationItemSkeleton? skeleton = item_item_skeletons[item];
        if (skeleton != null) {
            Plugins.MetaConversationItem? lower_item = meta_items.lower(item);
            Plugins.MetaConversationItem? upper_item = meta_items.higher(item);

            if (current_meta_item == item ||
                    currently_highlighted == skeleton.get_widget()) {
                clear_message_action_target();
            }

            // Clear focus while the row still belongs to a GtkRoot. GTK 4.14
            // otherwise moves focus during AFTER_PAINT, after the row and its
            // focused descendants may already have been finalized.
            skeleton.clear_focus_before_detach();
            main.remove(skeleton.get_widget());
            widgets.unset(item);
            widget_order.remove(skeleton.get_widget());
            item_item_skeletons.unset(item);

            if (item is ContentMetaItem) {
                content_items.remove((ContentMetaItem)item);
            }
            meta_items.remove(item);
            skeleton.dispose();
            item.dispose();

            // A row may previously have merged with the row being removed.
            // Recompute the surviving upper neighbour so the new first message
            // does not lose its sender/avatar header during live pruning.
            if (upper_item != null &&
                    item_item_skeletons.has_key((!) upper_item)) {
                ConversationItemSkeleton upper_skeleton =
                    item_item_skeletons[(!) upper_item];
                upper_skeleton.show_skeleton = lower_item == null ||
                    !can_merge((!) upper_item, (!) lower_item);
            }
        }

        removed_item(item);
    }

    public void on_add_meta_notification(Plugins.MetaConversationNotification notification) {
        Widget? widget = (Widget) notification.get_widget(Plugins.WidgetType.GTK4);
        if (widget != null) {
            add_notification(widget);
        }
    }

    public void on_remove_meta_notification(Plugins.MetaConversationNotification notification){
        Widget? widget = (Widget) notification.get_widget(Plugins.WidgetType.GTK4);
        if (widget != null) {
            remove_notification(widget);
        }
    }

    public void add_notification(Widget widget) {
        if (widget.get_parent() != null) return; // Already parented — avoid GTK assertion
        notifications.append(widget);
        Timeout.add(20, () => {
            notification_revealer.transition_duration = 200;
            notification_revealer.reveal_child =
                notifications.get_first_child() != null;
            return false;
        });
    }

    public void remove_notification(Widget widget) {
        if (widget.get_parent() == notifications) {
            Util.clear_focus_before_detach(widget);
            notifications.remove(widget);
            if (notifications.get_first_child() == null) {
                notification_revealer.reveal_child = false;
            }
        }
    }

    private Widget? insert_new(Plugins.MetaConversationItem item) {
        if (conversation == null) return null;
        int64 t0_us = Dino.Ui.UiTiming.now_us();
        Plugins.MetaConversationItem? lower_item = meta_items.lower(item);

        // Fill datastructure
        int64 t_skel_us = Dino.Ui.UiTiming.now_us();
        ConversationItemSkeleton item_skeleton = new ConversationItemSkeleton(stream_interactor, conversation, item, bulk_inserting_latest);
        Dino.Ui.UiTiming.log_ms("ConversationView.insert_new: ConversationItemSkeleton", t_skel_us);
        item_item_skeletons[item] = item_skeleton;
        connect_mention_refresh(this, item_skeleton, item);
        int index = lower_item != null ? widget_order.index_of(item_item_skeletons[lower_item].get_widget()) + 1 : 0;
        widget_order.insert(index, item_skeleton.get_widget());

        // Insert widget
        widgets[item] = item_skeleton.get_widget();
        widgets[item].insert_after(main, item_item_skeletons.has_key(lower_item) ? item_item_skeletons[lower_item].get_widget() : null);

        if (lower_item != null) {
            if (can_merge(item, lower_item)) {
                item_skeleton.show_skeleton = false;
            } else {
                item_skeleton.show_skeleton = true;
            }
        } else {
            item_skeleton.show_skeleton = true;
        }

        Plugins.MetaConversationItem? upper_item = meta_items.higher(item);
        if (upper_item != null) {
            if (!can_merge(upper_item, item)) {
                ConversationItemSkeleton upper_skeleton = item_item_skeletons[upper_item];
                upper_skeleton.show_skeleton = true;
            }
        }

        // If an item from the past was added, add everything between that item and the (post-)first present item
        if (index == 0) {
            Dino.Application app = Dino.Application.get_default();
            int64 t_span_us = Dino.Ui.UiTiming.now_us();
            if (widget_order.size == 1) {
                foreach (Plugins.ConversationAdditionPopulator populator in app.plugin_registry.conversation_addition_populators) {
                    populator.populate_timespan(conversation, item.time, new DateTime.now_utc());
                }
            } else {
                foreach (Plugins.ConversationAdditionPopulator populator in app.plugin_registry.conversation_addition_populators) {
                    populator.populate_timespan(conversation, item.time, meta_items.higher(item).time);
                }
            }
            Dino.Ui.UiTiming.log_ms("ConversationView.insert_new: conversation_addition_populators.populate_timespan", t_span_us);
        }

        Dino.Ui.UiTiming.log_ms("ConversationView.insert_new: total", t0_us);
        return item_skeleton.get_widget();
    }

    private bool can_merge(Plugins.MetaConversationItem upper_item /*more recent, displayed below*/, Plugins.MetaConversationItem lower_item /*less recent, displayed above*/) {
        return upper_item.time != null && lower_item.time != null &&
            upper_item.time.difference(lower_item.time) < TimeSpan.MINUTE &&
            upper_item.jid != null && lower_item.jid != null &&
            upper_item.jid.equals(lower_item.jid) &&
            upper_item.encryption == lower_item.encryption &&
            item_is_mentioned(upper_item) == item_is_mentioned(lower_item) &&
            (upper_item.mark == Message.Marked.WONTSEND) == (lower_item.mark == Message.Marked.WONTSEND);
    }

    private bool item_is_mentioned(Plugins.MetaConversationItem item) {
        if (item_item_skeletons.has_key(item)) {
            // The displayed row also knows about hiding and deletion of its
            // content, which a raw message flag alone cannot represent.
            return item_item_skeletons[item].has_mention;
        }
        ContentMetaItem? content = item as ContentMetaItem;
        return conversation != null && content != null &&
            MessageMentionPresentation.is_item_mentioned(stream_interactor,
                (!) conversation, ((!) content).content_item);
    }

    private static void connect_mention_refresh(ConversationView view,
            ConversationItemSkeleton skeleton, Plugins.MetaConversationItem item) {
        WeakRef view_weak = WeakRef(view);
        WeakRef item_weak = WeakRef(item);
        skeleton.mention_changed.connect(() => {
            var current_view = (ConversationView?) view_weak.get();
            var current_item = (Plugins.MetaConversationItem?) item_weak.get();
            if (current_view != null && current_item != null) {
                ((!) current_view).refresh_mention_headers((!) current_item);
            }
        });
    }

    private void refresh_mention_headers(Plugins.MetaConversationItem item) {
        if (!item_item_skeletons.has_key(item)) return;
        Plugins.MetaConversationItem? lower_item = meta_items.lower(item);
        item_item_skeletons[item].show_skeleton = lower_item == null ||
            !can_merge(item, (!) lower_item);
        Plugins.MetaConversationItem? upper_item = meta_items.higher(item);
        if (upper_item != null && item_item_skeletons.has_key((!) upper_item)) {
            item_item_skeletons[(!) upper_item].show_skeleton =
                !can_merge((!) upper_item, item);
        }
    }

    private void on_action_button_clicked(string action_name, GLib.Variant? variant = null) {
        if (message_actions == null || current_meta_item == null) return;

        Plugins.MessageAction? selected_action = null;
        foreach (var action in message_actions) {
            if (action.name != action_name) continue;
            selected_action = action;
            break;
        }
        if (selected_action == null) return;

        // Actions may synchronously replace or remove their ContentItem. Drop
        // every row/action closure before invoking the callback so the toolbar
        // cannot keep targeting the pre-edit or pre-delete item.
        clear_message_action_target();
        if (((!) selected_action).callback != null) {
            ((!) selected_action).callback(variant);
        }
    }

    private void on_upper_notify() {
        // Follow the newest rows while initial content is filled over frames.
        // Paging stays blocked until the last row has a settled allocation.
        if (bulk_inserting_latest || initial_scroll_pending || !reload_messages) {
            if (initial_scroll_pending && !bulk_inserting_latest && has_usable_viewport()) {
                scroll_motion.snap_to_bottom();
            }
            was_upper = scrolled.vadjustment.upper;
            was_page_size = scrolled.vadjustment.page_size;
            resume_content_settle(conversation_load_generation);
            return;
        }

        if (was_upper == null || (was_value ?? scrolled.vadjustment.value) > was_upper - was_page_size - 1) { // scrolled down or content smaller than page size
            if (at_current_content) {
                queue_bottom_snap();
            }
        }
        was_upper = scrolled.vadjustment.upper;
        was_page_size = scrolled.vadjustment.page_size;
        was_value = scrolled.vadjustment.value;
        if (bottom_snap_pending) queue_bottom_snap();
    }

    private void cancel_bottom_snap(bool preserve_request = false) {
        if (!preserve_request) bottom_snap_pending = false;
    }

    private void queue_bottom_snap() {
        if (conversation == null || initial_scroll_pending || !reload_messages || !at_current_content) return;
        bottom_snap_pending = true;
        if (!has_usable_viewport()) return;
        bottom_snap_pending = false;
        // Layout changes are not user scrolling and must not page the history.
        repositioning_scroll = true;
        scroll_motion.snap_to_bottom();
        repositioning_scroll = false;
    }

    private void on_value_notify() {
        if (scroll_layout.restoring_position) {
            was_value = scrolled.vadjustment.value;
            return;
        }
        if (repositioning_scroll || conversation == null || !reload_messages || bulk_inserting_latest ||
                initial_scroll_pending || !has_usable_viewport()) return;
        was_value = scrolled.vadjustment.value;
        if (scrolled.vadjustment.value < 400) {
            load_earlier_messages();
        } else if (scrolled.vadjustment.upper - (scrolled.vadjustment.value + scrolled.vadjustment.page_size) < 400) {
            load_later_messages();
        }
    }

    private void load_earlier_messages() {
        was_value = scrolled.vadjustment.value;
        if (is_reloading) return;
        is_reloading = true;
        if (content_items.size > 0) {
            Gee.List<ContentMetaItem> items = content_populator.populate_before(conversation, ((ContentMetaItem) content_items.first()).content_item, 20);
            foreach (ContentMetaItem item in items) {
                do_insert_item(item);
            }
            prune_newest_items();
        }
        is_reloading = false;
    }

    private void load_later_messages() {
        if (is_reloading) return;
        is_reloading = true;
        if (content_items.size > 0 && !at_current_content) {
            Gee.List<ContentMetaItem> items = content_populator.populate_after(conversation, ((ContentMetaItem) content_items.last()).content_item, 20);
            if (items.size == 0) {
                at_current_content = true;
            }
            foreach (ContentMetaItem item in items) {
                do_insert_item(item);
            }
            prune_oldest_items();
        }
        is_reloading = false;
    }

    /** Remove oldest items (top) when user scrolled down and loaded newer messages. */
    private void prune_oldest_items() {
        while (content_items.size > MAX_CONTENT_ITEMS) {
            ContentMetaItem oldest = content_items.first();
            remove_item(oldest);
        }
    }

    /**
     * A ContentItemStore insertion can arrive inside a historical window.
     * Keep the inserted item's nearest side and discard the more distant edge,
     * so that backfill/correction traffic cannot bypass the bound.
     */
    private void prune_content_items_around(ContentMetaItem inserted_item) {
        while (content_items.size > MAX_CONTENT_ITEMS) {
            ContentMetaItem oldest = content_items.first();
            ContentMetaItem newest = content_items.last();
            TimeSpan distance_from_oldest =
                inserted_item.time.difference(oldest.time);
            TimeSpan distance_to_newest =
                newest.time.difference(inserted_item.time);
            if (distance_from_oldest <= distance_to_newest) {
                remove_item(newest);
            } else {
                remove_item(oldest);
            }
        }
    }

    /**
     * MUC role/affiliation events are live-only status rows and are not loaded
     * from history. Bound exactly that class without discarding unread markers,
     * date separators or plugin-provided security warnings.
     */
    private void prune_oldest_status_items() {
        int status_count = 0;
        foreach (Plugins.MetaConversationItem item in meta_items) {
            if (item is MetaStatusItem) {
                status_count++;
            }
        }
        while (status_count > MAX_STATUS_ITEMS) {
            MetaStatusItem? oldest_status = null;
            foreach (Plugins.MetaConversationItem item in meta_items) {
                oldest_status = item as MetaStatusItem;
                if (oldest_status != null) break;
            }
            if (oldest_status == null) break;
            remove_item((!) oldest_status);
            status_count--;
        }
    }

    /** Remove newest items (bottom) when user scrolled up and loaded older messages. */
    private void prune_newest_items() {
        if (content_items.size > MAX_CONTENT_ITEMS) {
            at_current_content = false;
        }
        while (content_items.size > MAX_CONTENT_ITEMS) {
            ContentMetaItem newest = content_items.last();
            remove_item(newest);
        }
    }

    private static int compare_content_meta_items(ContentMetaItem a, ContentMetaItem b) {
        return compare_meta_items(a, b);
    }

    private static int compare_meta_items(Plugins.MetaConversationItem a, Plugins.MetaConversationItem b) {
        int cmp1 = a.time.compare(b.time);
        if (cmp1 != 0) return cmp1;

        return a.secondary_sort_indicator - b.secondary_sort_indicator;
    }

    private void clear() {
        scroll_layout.preserve_visible_row = false;
        cancel_around_message_jump();
        conversation_load_generation++;
        initial_render_queue.cancel();
        cancel_content_settle();
        cancel_bottom_snap();
        reload_messages = false;
        was_upper = null;
        was_page_size = null;
        was_value = null;
        clear_message_action_target();

        // Guard against clear() being called after dispose() has nullified fields
        if (content_items == null) return;

        foreach (var item in content_items) {
            item.dispose();
        }
        content_items.clear();
        meta_items.clear();
        widget_order.clear();
        foreach (var skeleton in item_item_skeletons.values) {
            skeleton.dispose();
        }
        item_item_skeletons.clear();
        // widgets[] contains skeleton.get_widget() (= main_grid) which is already
        // disposed by skeleton.dispose() above — just clear the map, don't re-dispose.
        foreach (Widget widget in widgets.values) {
            widget.unparent();
        }
        widgets.clear();

        Widget? notification = notifications.get_first_child();
        while (notification != null) {
            Util.clear_focus_before_detach(notification);
            notifications.remove(notification);
            notification = notifications.get_first_child();
        }
    }

    private void clear_notifications() {
//        notifications.@foreach((widget) => { notifications.remove(widget); });
        notification_revealer.transition_duration = 0;
        notification_revealer.set_reveal_child(false);
    }

    public override void dispose() {
        initial_render_queue.cancel();
        clear_message_action_target();
        subscription_notification.dispose();
        voice_request_notification.dispose();
        real_jid_visibility_notification.dispose();

        // Disconnect vadjustment signals
        if (scrolled != null) {
            var adj = scrolled.vadjustment;
            if (adj != null) {
                if (vadjust_changed_handler_id != 0) {
                    SignalHandler.disconnect(adj, vadjust_changed_handler_id);
                    vadjust_changed_handler_id = 0;
                }
                if (vadjust_value_handler_id != 0) {
                    SignalHandler.disconnect(adj, vadjust_value_handler_id);
                    vadjust_value_handler_id = 0;
                }
            }
        }
        // Disconnect self-signals
        if (add_meta_notification_handler_id != 0) {
            SignalHandler.disconnect(this, add_meta_notification_handler_id);
            add_meta_notification_handler_id = 0;
        }
        if (remove_meta_notification_handler_id != 0) {
            SignalHandler.disconnect(this, remove_meta_notification_handler_id);
            remove_meta_notification_handler_id = 0;
        }
        if (stream_interactor != null) {
            stream_interactor.get_module<MessageDeletion>(MessageDeletion.IDENTITY).item_deleted.disconnect(on_item_deleted);
            if (visibility_store != null && visibility_handler_id != 0) {
                SignalHandler.disconnect((!) visibility_store, visibility_handler_id);
                visibility_handler_id = 0;
                visibility_store = null;
            }
            if (message_correction_handler_id != 0) {
                SignalHandler.disconnect(stream_interactor
                    .get_module<MessageCorrection>(MessageCorrection.IDENTITY),
                    message_correction_handler_id);
                message_correction_handler_id = 0;
            }
            stream_interactor = null;
        }
        cancel_content_settle();
        cancel_bottom_snap();
        cancel_around_message_jump();
        base.dispose();
    }

    private static ulong connect_visibility_updates(ConversationView owner, ContentItemStore store) {
        // Static scope prevents Vala from implicitly retaining this view.
        var weak_owner = WeakRef(owner);
        return store.item_visibility_changed.connect((item, conversation, hidden) => {
            ConversationView? view = weak_owner.get() as ConversationView;
            if (view != null) ((!) view).on_content_visibility_changed(item, conversation, hidden);
        });
    }

    private void on_content_visibility_changed(ContentItem item, Conversation item_conversation, bool hidden) {
        if (conversation == null || conversation.id != item_conversation.id ||
                conversation.account.id != item_conversation.account.id) return;
        if (hidden) {
            foreach (ContentMetaItem current in content_items) {
                if (current.content_item.id == item.id) {
                    remove_item(current);
                    break;
                }
            }
            return;
        }
        if (conversation.history_cleared_at != null &&
                item.time.compare(conversation.history_cleared_at) < 0) return;
        foreach (ContentMetaItem current in content_items) {
            if (current.content_item.id == item.id) return;
        }
        ContentMetaItem? meta = content_populator.get_content_meta_item(item);
        // insert_item applies the existing live/history viewport bounds.
        if (meta != null) insert_item((!) meta);
    }

    private void on_item_deleted(ContentItem item) {
        Conversation? item_conversation = null;
        if (item is MessageItem) {
            item_conversation = ((MessageItem) item).conversation;
        } else if (item is FileItem) {
            item_conversation = ((FileItem) item).conversation;
        } else if (item is CallItem) {
            item_conversation = ((CallItem) item).conversation;
        }

        if (conversation == null || item_conversation != conversation) return;

        ContentMetaItem? to_remove = null;
        foreach (var meta_item in content_items) {
            if (meta_item.content_item.id == item.id) {
                to_remove = meta_item;
                break;
            }
        }

        if (to_remove != null) {
            remove_item(to_remove);
        }
    }

    private void on_item_corrected(ContentItem item) {
        if (current_meta_item != null &&
                ((!) current_meta_item).content_item.id == item.id) {
            clear_message_action_target();
        }
    }
}

}

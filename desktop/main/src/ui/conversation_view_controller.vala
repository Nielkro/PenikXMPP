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

using Dino.Entities;

namespace Dino.Ui {

private class DroppedFileResult : Object {
    public File file { get; private set; }
    public bool needs_access_confirmation { get; private set; }

    public DroppedFileResult(File file, bool needs_access_confirmation) {
        this.file = file;
        this.needs_access_confirmation = needs_access_confirmation;
    }
}

public class ConversationViewController : Object {

    private Application app;
    private MainWindow main_window;
    private ConversationView view;
    public SearchMenuEntry search_menu_entry = new SearchMenuEntry();
    public ListView list_view = new ListView(null, null);
    private EventController drop_event_controller;

    private ChatInputController chat_input_controller;
    private StreamInteractor stream_interactor;
    private Conversation? conversation;
    private ChatInput.InputTargetSnapshot? selected_input_target = null;
    private uint conversation_generation = 0;
    private uint file_upload_status_generation = 0;
    private bool file_upload_available = false;
    private bool file_send_request_active = false;
    private SimpleAction history_load_action = new SimpleAction(
        "load-current-conversation-history", null);
    private Box? history_load_notice = null;
    private uint history_load_notice_timeout_id = 0;
    private uint history_load_request_generation = 0;
    private ulong muc_history_finished_handler = 0;
    private FileSendOverlay? active_file_send_overlay = null;
    private Cancellable? active_file_dialog_cancellable = null;
    private Cancellable? active_location_cancellable = null;
    private uint active_location_timeout_id = 0;
    private Adw.AlertDialog? active_location_dialog = null;
    private uint location_attempt_generation = 0;
    private ChatInput.InputTargetSnapshot? active_location_target = null;

    private Binding? display_name_binding = null;

    private const string[] KEY_COMBINATION_CLOSE_CONVERSATION = {"<Ctrl>W", null};
    private const string[] KEY_COMBINATION_LOAD_HISTORY = {"<Ctrl><Shift>H", null};

    public ConversationViewController(MainWindow main_window, ConversationView view, StreamInteractor stream_interactor) {
        this.main_window = main_window;
        this.view = view;
        this.stream_interactor = stream_interactor;
        this.app = GLib.Application.get_default() as Application;

        this.chat_input_controller = new ChatInputController(view.chat_input, stream_interactor);
        chat_input_controller.activate_last_message_correction.connect(view.conversation_frame.activate_last_message_correction);
        chat_input_controller.file_picker_selected.connect(open_file_picker);
        chat_input_controller.clipboard_pasted.connect(start_clipboard_paste);
        chat_input_controller.voice_message_recorded.connect((path, target_conversation) => {
            send_file(File.new_for_path(path), target_conversation);
        });
        chat_input_controller.video_message_recorded.connect((path, target_conversation) => {
            send_file(File.new_for_path(path), target_conversation);
        });
        chat_input_controller.send_allowed_changed.connect((allowed) => {
            if (!allowed) {
                cancel_active_file_dialog();
                close_active_file_send_overlay();
                cancel_location_request();
            }
        });
        app.settings.notify["location-sharing-enabled"].connect(() => {
            if (!app.settings.location_sharing_enabled) cancel_location_request();
        });

        view.chat_input.send_file_button.clicked.connect(() => {
            view.chat_input.attachment_popover.popdown();
            open_file_picker();
        });
        view.chat_input.send_location_button.clicked.connect(() => {
            view.chat_input.attachment_popover.popdown();
            send_location();
        });

        view.conversation_frame.init(stream_interactor);

        if (FileTransferInput.should_use_async_drop_target(
                FileTransferInput.is_flatpak_runtime())) {
            // A Flatpak target needs explicit MIME ordering so the
            // FileTransfer portal grant wins over an unreadable host URI.
            var async_target = FileTransferInput.create_async_drop_target();
            async_target.accept.connect(can_accept_file_drop);
            async_target.drop.connect(this.on_async_drag_data_received);
            drop_event_controller = async_target;
        } else {
            // GTK 4.14 on X11 can retain GtkDropTargetAsync's active-drop
            // controller state after completion. Native Linux and Win32 only
            // need GType deserialization, for which GtkDropTarget is both
            // sufficient and the previously proven path. A separate GTK-X11
            // action-update warning can still occur after a completed drop.
            var native_target = FileTransferInput.create_native_drop_target();
            native_target.drop.connect(this.on_native_drag_data_received);
            drop_event_controller = native_target;
        }
        view.add_controller(drop_event_controller);

        // forward key presses
        var key_controller = new EventControllerKey() { name = "dino-forward-to-input-key-events-1" };
        key_controller.key_pressed.connect(forward_key_press_to_chat_input);
        view.conversation_frame.add_controller(key_controller);

        var key_controller2 = new EventControllerKey() { name = "dino-forward-to-input-key-events-2" };
        key_controller2.key_pressed.connect(forward_key_press_to_chat_input);
        view.chat_input.add_controller(key_controller2);

        var key_controller3 = new EventControllerKey() { name = "dino-forward-to-input-key-events-3" };
        key_controller3.key_pressed.connect(forward_key_press_to_chat_input);
        main_window.conversation_headerbar.add_controller(key_controller3);

        var title_click_controller = new GestureClick();
        title_click_controller.pressed.connect((n_press, x, y) => {
            if (this.conversation != null) {
                var conversation_details = ConversationDetails.setup_dialog(this.conversation, this.stream_interactor);
                conversation_details.present(main_window);
            }
        });
        main_window.conversation_window_title.add_controller(title_click_controller);

//      goto-end floating button
        var vadjustment = view.conversation_frame.scrolled.vadjustment;
        vadjustment.notify["value"].connect(() => {
            bool button_active = vadjustment.value <  vadjustment.upper - vadjustment.page_size;
            view.goto_end_revealer.reveal_child = button_active;
            view.goto_end_revealer.visible = button_active;
        });
        view.goto_end_button.clicked.connect(() => {
            view.conversation_frame.initialize_for_conversation(conversation);
        });

        // Update conversation topic
        stream_interactor.get_module<MucManager>(MucManager.IDENTITY).subject_set.connect((account, jid, subject) => {
            if (conversation != null && conversation.counterpart.equals_bare(jid) && conversation.account.equals(account)) {
                update_conversation_topic(subject);
            }
        });

        stream_interactor.get_module<FileManager>(FileManager.IDENTITY).upload_available.connect(start_update_file_upload_status);
        
        // Listen for conversation history cleared signal
        stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY).conversation_cleared.connect((cleared_conversation) => {
            if (conversation == cleared_conversation && selected_input_target != null &&
                    !((!) selected_input_target).matches(cleared_conversation)) {
                // A room/nick can be rebound in place to another person.
                // Invalidate pending attachment requests as well as location.
                conversation_generation++;
                cancel_active_file_dialog();
                close_active_file_send_overlay();
                cancel_location_request();
                selected_input_target = new ChatInput.InputTargetSnapshot(cleared_conversation);
            }
            chat_input_controller.on_conversation_cleared(cleared_conversation);
            if (this.conversation != null && this.conversation.id == cleared_conversation.id &&
                    this.conversation.account == cleared_conversation.account) {
                history_load_request_generation++;
                disconnect_muc_history_feedback();
                clear_history_load_notice();
                // Force reload the conversation view to show empty chat
                view.conversation_frame.initialize_for_conversation(this.conversation, true);
            }
        });

        // Headerbar plugins
        app.plugin_registry.register_contact_titlebar_entry(new MenuEntry(stream_interactor));
        app.plugin_registry.register_contact_titlebar_entry(new NotificationEntry(stream_interactor));
        app.plugin_registry.register_contact_titlebar_entry(search_menu_entry);
        app.plugin_registry.register_contact_titlebar_entry(new OccupantsEntry(stream_interactor));
        app.plugin_registry.register_contact_titlebar_entry(new CallTitlebarEntry(stream_interactor));
        foreach(var entry in app.plugin_registry.conversation_titlebar_entries) {
            Widget? button = entry.get_widget(Plugins.WidgetType.GTK4) as Widget;
            if (button == null) {
                continue;
            }
            main_window.conversation_headerbar.pack_end(button);
        }

        Shortcut shortcut = new Shortcut(new KeyvalTrigger(Key.U, ModifierType.CONTROL_MASK), new CallbackAction(() => {
            if (conversation == null) return false;
            Conversation expected_conversation = (!) conversation;
            uint expected_generation = conversation_generation;
            FileManager file_manager = stream_interactor.get_module<FileManager>(FileManager.IDENTITY);
            file_manager.is_upload_available.begin(expected_conversation, (_, res) => {
                bool upload_available = file_manager.is_upload_available.end(res);
                if (FileTransferInput.is_current_target_request(
                        expected_conversation, conversation,
                        expected_generation, conversation_generation,
                        upload_available)) {
                    open_file_picker();
                }
            });
            return false;
        }));
        ((Gtk.Window)view.get_root()).add_shortcut(shortcut);

        SimpleAction close_conversation_action = new SimpleAction("close-current-conversation", null);
        close_conversation_action.activate.connect(() => {
            if (conversation == null) return;
            if (conversation.type_ == Conversation.Type.GROUPCHAT) {
                stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY).hide_conversation(conversation);
            } else {
                stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY).close_conversation(conversation);
            }
        });
        app.add_action(close_conversation_action);
        app.set_accels_for_action("app.close-current-conversation", KEY_COMBINATION_CLOSE_CONVERSATION);

        history_load_action.set_enabled(false);
        history_load_action.activate.connect(() => {
            load_current_conversation_history.begin();
        });
        app.add_action(history_load_action);
        app.set_accels_for_action("app.load-current-conversation-history",
            KEY_COMBINATION_LOAD_HISTORY);

        SimpleAction leave_current_conversation_action = new SimpleAction("leave-current-conversation", null);
        leave_current_conversation_action.activate.connect(() => {
            if (conversation == null || conversation.type_ != Conversation.Type.GROUPCHAT) return;
            GLib.Application.get_default().activate_action("leave-conversation", new GLib.Variant.int32(conversation.id));
        });
        app.add_action(leave_current_conversation_action);

        SimpleAction leave_current_conversation_permanently_action = new SimpleAction("leave-current-conversation-permanently", null);
        leave_current_conversation_permanently_action.activate.connect(() => {
            if (conversation == null || conversation.type_ != Conversation.Type.GROUPCHAT) return;
            GLib.Application.get_default().activate_action("leave-conversation-permanently", new GLib.Variant.int32(conversation.id));
        });
        app.add_action(leave_current_conversation_permanently_action);
    }

    public void select_conversation(Conversation? conversation, bool default_initialize_conversation) {
        debug("ConversationViewController.select_conversation: Called with %s", conversation != null ? conversation.counterpart.to_string() : "NULL");
        int64 t0_us = Dino.Ui.UiTiming.now_us();
        conversation_generation++;
        history_load_request_generation++;
        disconnect_muc_history_feedback();
        clear_history_load_notice();
        cancel_location_request();
        file_upload_available = false;
        chat_input_controller.set_file_upload_active(false);
        cancel_active_file_dialog();
        close_active_file_send_overlay();
        stream_interactor.get_module<AvatarManager>(AvatarManager.IDENTITY).defer_muc_avatar_background_work_for_ui_transition();
        if (this.conversation != null) {
            this.conversation.notify["encryption"].disconnect(start_update_file_upload_status);
        }

        this.conversation = conversation;
        history_load_action.set_enabled(MenuEntry.supports_history_refresh(
            conversation));
        selected_input_target = conversation != null ?
            new ChatInput.InputTargetSnapshot((!) conversation) : null;
        
        if (conversation == null) {
            debug("ConversationViewController.select_conversation: conversation is NULL, returning!");
            unset_conversation();
            return;
        }

        // Set list model onto list view
//        Dino.Application app = GLib.Application.get_default() as Dino.Application;
//        var map_list_model = get_conversation_content_model(new ContentItemMetaModel(app.db, conversation, stream_interactor), stream_interactor);
//        NoSelection selection_model = new NoSelection(map_list_model);
//        view.list_view.set_model(selection_model);
//        view.at_current_content = true;

        conversation.notify["encryption"].connect(start_update_file_upload_status);

        int64 t_input_us = Dino.Ui.UiTiming.now_us();
        chat_input_controller.set_conversation(conversation);
        Dino.Ui.UiTiming.log_ms("ConversationViewController.select_conversation: chat_input_controller.set_conversation", t_input_us);

        if (display_name_binding != null) display_name_binding.unbind();
        int64 t_title_us = Dino.Ui.UiTiming.now_us();
        var display_name_model = stream_interactor.get_module<ContactModels>(ContactModels.IDENTITY).get_display_name_model(conversation);
        display_name_binding = display_name_model.bind_property("display-name", main_window.conversation_window_title, "title", BindingFlags.SYNC_CREATE);
        Dino.Ui.UiTiming.log_ms("ConversationViewController.select_conversation: display_name_model+bind", t_title_us);

        int64 t_topic_us = Dino.Ui.UiTiming.now_us();
        update_conversation_topic();
        Dino.Ui.UiTiming.log_ms("ConversationViewController.select_conversation: update_conversation_topic", t_topic_us);
        
        // Fetch Entity Time (XEP-0202) for 1:1 chats
        start_check_and_update_entity_time();

        int64 t_plugins_us = Dino.Ui.UiTiming.now_us();
        foreach(Plugins.ConversationTitlebarEntry e in this.app.plugin_registry.conversation_titlebar_entries) {
            int64 t_plugin_entry_us = Dino.Ui.UiTiming.now_us();
            e.set_conversation(conversation);
            Dino.Ui.UiTiming.log_ms("ConversationViewController.select_conversation: titlebar_entries.%s.set_conversation".printf(e.id), t_plugin_entry_us);
        }
        Dino.Ui.UiTiming.log_ms("ConversationViewController.select_conversation: titlebar_entries.set_conversation", t_plugins_us);

        if (default_initialize_conversation) {
            int64 t_view_us = Dino.Ui.UiTiming.now_us();
            view.conversation_frame.initialize_for_conversation(conversation);
            Dino.Ui.UiTiming.log_ms("ConversationViewController.select_conversation: conversation_frame.initialize_for_conversation", t_view_us);
        }

        start_update_file_upload_status();

        Dino.Ui.UiTiming.log_ms("ConversationViewController.select_conversation: total", t0_us);
    }

    public void unset_conversation() {
        conversation_generation++;
        history_load_request_generation++;
        history_load_action.set_enabled(false);
        disconnect_muc_history_feedback();
        clear_history_load_notice();
        selected_input_target = null;
        cancel_location_request();
        file_upload_available = false;
        chat_input_controller.set_file_upload_active(false);
        cancel_active_file_dialog();
        close_active_file_send_overlay();
        if (this.conversation != null) {
            this.conversation.notify["encryption"].disconnect(start_update_file_upload_status);
            this.conversation = null;
        }
        if (display_name_binding != null) {
            display_name_binding.unbind();
            display_name_binding = null;
        }
        chat_input_controller.unset_conversation();
        foreach(Plugins.ConversationTitlebarEntry e in this.app.plugin_registry.conversation_titlebar_entries) {
            e.unset_conversation();
        }
        main_window.conversation_window_title.title = null;
        main_window.conversation_window_title.subtitle = null;
        // Free all message widgets when no conversation is active
        view.conversation_frame.initialize_for_conversation(null);
        start_update_file_upload_status();
    }

    private async void load_current_conversation_history() {
        if (!MenuEntry.supports_history_refresh(conversation)) return;
        disconnect_muc_history_feedback();
        Conversation target = (!) conversation;
        var snapshot = new ChatInput.InputTargetSnapshot(target);
        uint selection_generation = conversation_generation;
        uint request_generation = ++history_load_request_generation;

        if (target.type_ == Conversation.Type.GROUPCHAT) {
            var muc_manager = stream_interactor.get_module<MucManager>(MucManager.IDENTITY);
            WeakRef controller_weak = WeakRef(this);
            muc_history_finished_handler = muc_manager.history_refresh_finished.connect((finished, outcome) => {
                var controller = controller_weak.get() as ConversationViewController;
                if (controller == null || finished.id != target.id ||
                        finished.account != target.account) return;
                controller.disconnect_muc_history_feedback();
                if (controller.is_current_history_load(target, snapshot,
                        selection_generation, request_generation)) {
                    controller.show_history_load_result(target, outcome);
                }
            });
            MucHistoryRefreshResult result = muc_manager.request_muc_history_refresh(target);
            if (!is_current_history_load(target, snapshot,
                    selection_generation, request_generation)) return;
            switch (result) {
                case MucHistoryRefreshResult.QUEUED:
                    if (muc_history_finished_handler != 0) {
                        show_history_load_notice(_("History load requested. Messages will appear as they are received."));
                    }
                    break;
                case MucHistoryRefreshResult.PENDING_JOIN:
                    disconnect_muc_history_feedback();
                    show_history_load_notice(_("The saved history period applies when you reconnect and join this group."));
                    break;
                case MucHistoryRefreshResult.UNAVAILABLE:
                    disconnect_muc_history_feedback();
                    show_history_load_notice(_("Message history is not available for this group right now."));
                    break;
            }
            return;
        }

        show_history_load_notice(_("Loading message history…"), false);
        HistorySync.FetchResult result = yield stream_interactor.get_module<
            MessageProcessor>(MessageProcessor.IDENTITY).history_sync
                .refresh_direct_conversation(target);
        if (!is_current_history_load(target, snapshot,
                selection_generation, request_generation)) {
            // Hiding the window does not supersede a request. A changed
            // target does; remove only this request's own pending notice.
            if (history_load_request_generation == request_generation) {
                clear_history_load_notice();
            }
            return;
        }
        show_history_load_result(target, result);
    }

    private void show_history_load_result(Conversation target, HistorySync.FetchResult result) {
        switch (result) {
            case HistorySync.FetchResult.SUCCESS_WITH_OMEMO_FAILURES:
                show_history_load_notice(_("The archive query has finished. Some messages could not be restored."));
                break;
            case HistorySync.FetchResult.SUCCESS:
                // A completed MAM query may contain only control stanzas or
                // own encrypted copies that this device cannot decrypt after
                // local deletion. Do not claim that an empty chat was restored.
                bool has_content = !stream_interactor.get_module<ContentItemStore>(
                    ContentItemStore.IDENTITY).get_n_latest(target, 1).is_empty;
                show_history_load_notice(has_content
                    ? _("The server archive query has finished.")
                    : _("No messages could be restored from the server archive."));
                break;
            case HistorySync.FetchResult.ERROR:
                show_history_load_notice(_("Could not load message history. Please try again."));
                break;
            case HistorySync.FetchResult.UNAVAILABLE:
                show_history_load_notice(_("No message archive is currently available for this chat. Check the account connection and the server's archive support."));
                break;
            case HistorySync.FetchResult.CANCELLED:
                show_history_load_notice(_("History loading was cancelled."));
                break;
        }
    }

    private void disconnect_muc_history_feedback() {
        if (muc_history_finished_handler == 0) return;
        SignalHandler.disconnect(stream_interactor.get_module<MucManager>(
            MucManager.IDENTITY), muc_history_finished_handler);
        muc_history_finished_handler = 0;
    }

    private bool is_current_history_load(Conversation target,
            ChatInput.InputTargetSnapshot snapshot,
            uint selection_generation, uint request_generation) {
        return conversation == target && snapshot.matches(target) &&
            conversation_generation == selection_generation &&
            history_load_request_generation == request_generation &&
            view.get_root() == main_window;
    }

    private void show_history_load_notice(string text, bool auto_dismiss = true) {
        clear_history_load_notice();
        var notice = new Box(Orientation.HORIZONTAL, 8) {
            margin_start = 12, margin_end = 12, margin_top = 6,
            margin_bottom = 6
        };
        if (!auto_dismiss) {
            notice.append(new Spinner() { spinning = true, valign = Align.CENTER });
        }
        notice.append(new Label(text) { wrap = true, xalign = 0, hexpand = true });
        var dismiss = new Button.from_icon_name("window-close-symbolic") {
            valign = Align.CENTER, tooltip_text = _("Close")
        };
        dismiss.add_css_class("flat");
        notice.append(dismiss);
        WeakRef controller_weak = WeakRef(this);
        WeakRef notice_weak = WeakRef(notice);
        dismiss.clicked.connect(() => {
            var controller = controller_weak.get() as ConversationViewController;
            if (controller != null &&
                    controller.history_load_notice == notice_weak.get()) {
                controller.clear_history_load_notice();
            }
        });
        history_load_notice = notice;
        view.conversation_frame.add_notification(notice);
        if (auto_dismiss) {
            history_load_notice_timeout_id = Timeout.add_seconds(10, () => {
                var controller = controller_weak.get() as ConversationViewController;
                if (controller != null &&
                        controller.history_load_notice == notice_weak.get()) {
                    controller.history_load_notice_timeout_id = 0;
                    controller.clear_history_load_notice();
                }
                return Source.REMOVE;
            });
        }
    }

    private void clear_history_load_notice() {
        if (history_load_notice_timeout_id != 0) {
            Source.remove(history_load_notice_timeout_id);
            history_load_notice_timeout_id = 0;
        }
        if (history_load_notice != null) {
            view.conversation_frame.remove_notification((!) history_load_notice);
            history_load_notice = null;
        }
    }

    public override void dispose() {
        disconnect_muc_history_feedback();
        history_load_request_generation++;
        clear_history_load_notice();
        base.dispose();
    }

    private async void update_file_upload_status(Conversation? expected_conversation, uint generation) {
        bool upload_available = false;

        if (expected_conversation != null) {
            upload_available = yield stream_interactor.get_module<FileManager>(FileManager.IDENTITY).is_upload_available((!) expected_conversation);

            // Optimistic UI: If the stream is still connecting and the server hasn't
            // confirmed HTTP Upload yet, keep the button visible instead of hiding it
            // and causing a jarring pop-in once the disco#info response arrives.
            if (!upload_available) {
                var conn_state = stream_interactor.connection_manager.get_state(((!) expected_conversation).account);
                if (conn_state == ConnectionManager.ConnectionState.CONNECTING) {
                    // Stream not fully negotiated yet -- assume upload will be available
                    // (virtually all modern XMPP servers support HTTP File Upload).
                    upload_available = true;
                }
            }
        }

        if (generation != file_upload_status_generation || conversation != expected_conversation) return;

        file_upload_available = upload_available;
        chat_input_controller.set_file_upload_active(upload_available);
    }

    private void start_update_file_upload_status() {
        uint generation = ++file_upload_status_generation;
        Conversation? expected_conversation = conversation;
        update_file_upload_status.begin(expected_conversation, generation, (obj, res) => {
            update_file_upload_status.end(res);
        });
    }

    private async void check_and_update_entity_time() {
        if (conversation == null || conversation.type_ != Conversation.Type.CHAT) return;
        
        var entity_time = stream_interactor.get_module<Dino.Service.EntityTime>(Dino.Service.EntityTime.IDENTITY);
        if (entity_time == null) return;
        
        var tzo_str = yield entity_time.request_time(conversation.account, conversation.counterpart);
        if (tzo_str != null) {
            try {
                var tz = new TimeZone.identifier(tzo_str);
                var contact_time = new DateTime.now(tz);
                
                int hour = contact_time.get_hour();
                if (hour >= 22 || hour < 6) { // Night is between 22:00 and 05:59
                    string night_str = "🌙 " + _("Local time: %s").printf(contact_time.format("%H:%M"));
                    update_conversation_topic(night_str);
                }
            } catch (Error e) {
                // Ignore timezone parse errors
            }
        }
    }

    private void start_check_and_update_entity_time() {
        check_and_update_entity_time.begin((obj, res) => {
            check_and_update_entity_time.end(res);
        });
    }

    private void update_conversation_topic(string? subtitle = null) {
        string? str = null;
        if (subtitle != null) {
            str = Util.summarize_whitespaces_to_space(subtitle);
        } else if (conversation.type_ == Conversation.Type.GROUPCHAT) {
            string? subject = stream_interactor.get_module<MucManager>(MucManager.IDENTITY).get_groupchat_subject(conversation.counterpart, conversation.account);
            if (subject != null) {
                str = Util.summarize_whitespaces_to_space(subject);
            }
        }

        main_window.conversation_window_title.subtitle = str;
    }

    private async bool on_clipboard_paste(Clipboard clipboard, ClipboardTransferKind kind,
            Conversation expected_conversation, uint expected_generation) {
        if (!is_current_file_send_context(expected_conversation, expected_generation)) return false;

        if (kind == ClipboardTransferKind.FILE_LIST) {
            File? file = null;
            Error? typed_read_error = null;
            try {
                unowned Value? value = yield clipboard.read_value_async(
                        typeof(Gdk.FileList), Priority.DEFAULT, null);
                if (value != null) file = FileTransferInput.first_file_from_value((!) value);
            } catch (Error e) {
                typed_read_error = e;
            }
            if (!is_current_file_send_context(expected_conversation, expected_generation)) return false;

            // Explorer advertises the generic GDK types but some Win32 GTK
            // releases cannot materialize them. Its directly readable
            // FileNameW stream preserves the full Unicode path.
            if (file == null && clipboard.get_formats().contain_mime_type(
                    "application/x.windows.FileNameW")) {
                try {
                    file = yield read_first_clipboard_windows_file(clipboard);
                } catch (Error e) {
                    debug("Failed to read Windows clipboard filename: %s", e.message);
                }
            }
            if (!is_current_file_send_context(expected_conversation, expected_generation)) return false;

            // A few native backends expose a single GFile directly rather
            // than constructing the boxed FileList value.
            if (file == null) {
                try {
                    unowned Value? value = yield clipboard.read_value_async(
                            typeof(File), Priority.DEFAULT, null);
                    if (value != null) file = FileTransferInput.first_file_from_value((!) value);
                } catch (Error e) {
                    if (typed_read_error == null) typed_read_error = e;
                }
            }
            if (!is_current_file_send_context(expected_conversation, expected_generation)) return false;

            // Standard MIME fallback for portals and non-Windows backends.
            // Never treat arbitrary clipboard text as a filesystem path.
            if (file == null && clipboard.get_formats().contain_mime_type("text/uri-list")) {
                try {
                    file = yield read_first_clipboard_uri_file(clipboard);
                } catch (Error e) {
                    debug("Failed to read clipboard URI list: %s", e.message);
                }
            }

            if (!is_current_file_send_context(expected_conversation, expected_generation)) return false;
            if (file != null) {
                return schedule_send_file_overlay_for_active_request(
                        (!) file, expected_conversation, expected_generation);
            } else if (typed_read_error != null) {
                debug("Failed to read clipboard file list: %s", ((!) typed_read_error).message);
            }
            return false;
        }

        PlaintextFileLeaseTarget? plaintext_target = null;
        try {
            Gdk.Texture? texture = yield clipboard.read_texture_async(null);
            if (texture == null || !is_current_file_send_context(
                    expected_conversation, expected_generation)) return false;

            plaintext_target = FileManager.create_named_plaintext_file_lease_target(
                    "clipboard", "clipboard.png");
            save_texture_as_private_png((!) texture, ((!) plaintext_target).file);

            var pending_send = new PendingPlaintextSend((!) plaintext_target);
            plaintext_target = null;
            if (schedule_send_file_overlay_for_active_request(
                    pending_send.file, expected_conversation, expected_generation, pending_send)) {
                return true;
            }
            pending_send.overlay_closed();
        } catch (Error e) {
            debug("Failed to prepare clipboard image: %s", e.message);
        } finally {
            if (plaintext_target != null) {
                ((!) plaintext_target).discard();
            }
        }
        return false;
    }

    private static async File? read_first_clipboard_uri_file(Clipboard clipboard) throws Error {
        const size_t MAX_URI_LIST_BYTES = 64 * 1024;
        unowned string selected_mime_type;
        InputStream? input = yield ((DinoNative.Clipboard) clipboard).read_async(
                { "text/uri-list" }, Priority.DEFAULT, null, out selected_mime_type);
        if (input == null || selected_mime_type != "text/uri-list") return null;

        uint8[] buffer = new uint8[MAX_URI_LIST_BYTES + 1];
        size_t bytes_read = 0;
        try {
            yield ((!) input).read_all_async(buffer, Priority.DEFAULT, null, out bytes_read);
        } finally {
            try {
                ((!) input).close(null);
            } catch (Error e) {
                debug("Failed to close clipboard URI-list stream: %s", e.message);
            }
        }
        if (bytes_read == 0 || bytes_read > MAX_URI_LIST_BYTES) return null;

        unowned string raw = (string) buffer;
        if (!raw.validate_len(bytes_read)) return null;
        string uri_list = raw.substring(0, (long) bytes_read);
        if ((size_t) uri_list.length != bytes_read) return null;
        return FileTransferInput.first_native_file_from_uri_list(uri_list);
    }

    private static async File? read_first_clipboard_windows_file(Clipboard clipboard) throws Error {
        const size_t MAX_FILENAME_BYTES = 64 * 1024;
        unowned string selected_mime_type;
        InputStream? input = yield ((DinoNative.Clipboard) clipboard).read_async(
                { "application/x.windows.FileNameW" }, Priority.DEFAULT, null,
                out selected_mime_type);
        if (input == null || selected_mime_type != "application/x.windows.FileNameW") return null;

        uint8[] buffer = new uint8[MAX_FILENAME_BYTES + 2];
        size_t bytes_read = 0;
        try {
            yield ((!) input).read_all_async(buffer, Priority.DEFAULT, null, out bytes_read);
        } finally {
            try {
                ((!) input).close(null);
            } catch (Error e) {
                debug("Failed to close Windows clipboard filename stream: %s", e.message);
            }
        }
        if (bytes_read == 0 || bytes_read > MAX_FILENAME_BYTES || bytes_read % 2 != 0) return null;
        return FileTransferInput.file_from_windows_filename_w(buffer[0:(int) bytes_read]);
    }

    private static void save_texture_as_private_png(Gdk.Texture texture, File file) throws Error {
        Bytes png = texture.save_to_png_bytes();
        unowned uint8[] png_data = png.get_data();
        OutputStream? output = null;

        try {
            output = file.create(FileCreateFlags.PRIVATE);
            size_t bytes_written;
            ((!) output).write_all(png_data, out bytes_written);
            ((!) output).close();
            output = null;
        } finally {
            if (output != null) {
                try {
                    ((!) output).close();
                } catch (Error close_error) {
                    debug("Failed to close clipboard image output: %s", close_error.message);
                }
            }
        }
    }

    private void start_clipboard_paste() {
        Clipboard clipboard = view.get_clipboard();
        ClipboardTransferKind kind = FileTransferInput.classify_clipboard_formats(clipboard.get_formats());
        if (kind == ClipboardTransferKind.NONE) return;

        // File/image content is handled as an attachment. Prevent Gtk.TextView
        // from additionally inserting a URI or clipboard fallback string.
        Signal.stop_emission_by_name(
                view.chat_input.chat_text_view.text_view, "paste-clipboard");

        if (!can_start_file_send()) return;

        Conversation expected_conversation = (!) conversation;
        uint expected_generation = conversation_generation;
        file_send_request_active = true;
        on_clipboard_paste.begin(clipboard, kind, expected_conversation, expected_generation, (obj, res) => {
            bool request_handed_off = on_clipboard_paste.end(res);
            if (!request_handed_off) finish_file_send_request();
        });
    }

    private bool on_native_drag_data_received(DropTarget target, Value value,
            double x, double y) {
        // Once the parent accepted a file value, consume it even if sending
        // became unavailable. Otherwise Gtk.TextView may insert the same file
        // as path text.
        if (!can_start_file_send() || conversation == null) return true;

        Conversation expected_conversation = (!) conversation;
        uint expected_generation = conversation_generation;
        file_send_request_active = true;

        File? file = FileTransferInput.first_file_from_value(value);
        if (file == null) {
            // Return from GtkDropTarget::drop before presenting a dialog so
            // GTK can finish its own synchronous drop lifecycle first.
            Idle.add(() => {
                if (is_current_file_send_context(
                        expected_conversation, expected_generation)) {
                    show_file_input_error();
                }
                finish_file_send_request();
                return Source.REMOVE;
            });
            return true;
        }

        bool request_handed_off = schedule_send_file_overlay_for_active_request(
                (!) file, expected_conversation, expected_generation);
        if (!request_handed_off) finish_file_send_request();
        return true;
    }

    private bool on_async_drag_data_received(DropTargetAsync target, Gdk.Drop drop,
            double x, double y) {
        // Once the async target accepted a file drop, always consume it here.
        // Returning false after DROP_START would let Gtk.TextView insert the
        // same file as URI/path text.
        if (!can_start_file_send() || conversation == null) {
            drop.finish((Gdk.DragAction) 0);
            return true;
        }

        Conversation expected_conversation = (!) conversation;
        uint expected_generation = conversation_generation;
        file_send_request_active = true;
        receive_file_drop.begin(drop, expected_conversation, expected_generation);
        return true;
    }

    private async void receive_file_drop(Gdk.Drop drop, Conversation expected_conversation,
            uint expected_generation) {
        Gdk.DragAction completed_action = (Gdk.DragAction) 0;
        bool request_handed_off = false;
        bool show_error_after_drop = false;
        try {
            DroppedFileResult? result = yield read_file_from_drop(drop);
            if (result != null && is_current_file_send_context(
                    expected_conversation, expected_generation)) {
                request_handed_off = schedule_send_file_overlay_for_active_request(
                        ((!) result).file, expected_conversation, expected_generation,
                        null, ((!) result).needs_access_confirmation);
                if (request_handed_off) {
                    completed_action = Gdk.DragAction.COPY;
                }
            } else if (result == null && is_current_file_send_context(
                    expected_conversation, expected_generation)) {
                show_error_after_drop = true;
            }
        } catch (Error e) {
            warning("Failed reading dropped file: %s", e.message);
            if (is_current_file_send_context(expected_conversation, expected_generation)) {
                show_error_after_drop = true;
            }
        } finally {
            if (!request_handed_off && !show_error_after_drop) {
                finish_file_send_request();
            }
            // GtkDropTargetAsync requires the destination to finish only after
            // every byte needed to resolve the dropped value has been read.
            drop.finish(completed_action);
        }

        if (show_error_after_drop) {
            // Let GTK return from DROP_START and complete its crossing state
            // before a modal alert changes the widget hierarchy.
            Idle.add(() => {
                if (is_current_file_send_context(
                        expected_conversation, expected_generation)) {
                    show_file_input_error();
                }
                finish_file_send_request();
                return Source.REMOVE;
            });
        }
    }

    private async DroppedFileResult? read_file_from_drop(Gdk.Drop drop) throws Error {
        string? portal_mime = FileTransferInput.preferred_portal_file_transfer_mime(
                drop.get_formats());
        if (portal_mime != null) {
            InputStream? input = null;
            try {
                unowned string selected_mime_type;
                input = yield ((DinoNative.Drop) drop).read_async(
                        { (!) portal_mime }, Priority.DEFAULT, null, out selected_mime_type);
                if (input == null || selected_mime_type != portal_mime) {
                    throw new IOError.INVALID_DATA("The FileTransfer portal did not provide its advertised format");
                }

                Value value;
                if (!yield Gdk.content_deserialize_async(
                        (!) input, selected_mime_type, typeof(Gdk.FileList),
                        Priority.DEFAULT, null, out value)) {
                    throw new IOError.INVALID_DATA("The FileTransfer portal data could not be decoded");
                }

                File? portal_file = FileTransferInput.first_file_from_value(value);
                if (portal_file == null) {
                    throw new IOError.INVALID_DATA("The FileTransfer portal did not grant a file");
                }
                return new DroppedFileResult(portal_file, false);
            } finally {
                if (input != null) {
                    try {
                        if (!((!) input).is_closed()) {
                            yield ((!) input).close_async(Priority.DEFAULT, null);
                        }
                    } catch (Error e) {
                        debug("Failed to close dropped portal stream: %s", e.message);
                    }
                }
            }
        }

        Error? first_error = null;
        try {
            unowned Value? file_list_value = yield drop.read_value_async(
                    typeof(Gdk.FileList), Priority.DEFAULT, null);
            if (file_list_value != null) {
                File? file = FileTransferInput.first_file_from_value((!) file_list_value);
                if (file != null) return new DroppedFileResult(
                        file, FileTransferInput.target_can_request_file_access());
            }
        } catch (Error e) {
            first_error = e;
        }

        try {
            unowned Value? file_value = yield drop.read_value_async(
                    typeof(File), Priority.DEFAULT, null);
            File? file = file_value != null
                    ? FileTransferInput.first_file_from_value((!) file_value)
                    : null;
            if (file != null) return new DroppedFileResult(
                    file, FileTransferInput.target_can_request_file_access());
        } catch (Error e) {
            if (first_error == null) first_error = e;
        }

        if (first_error != null) throw (!) first_error;
        return null;
    }

    private void open_file_picker() {
        if (!can_start_file_send()) return;
        file_send_request_active = true;

        debug("ConversationViewController: open_file_picker called");
        var chooser = new Gtk.FileDialog();
        chooser.title = _("Select file");
        chooser.accept_label = _("Select");
        var dialog_cancellable = new Cancellable();
        active_file_dialog_cancellable = dialog_cancellable;

        Conversation expected_conversation = (!) conversation;
        uint expected_generation = conversation_generation;

        chooser.open.begin(view.get_root() as Gtk.Window, dialog_cancellable, (obj, res) => {
            bool request_handed_off = false;
            try {
                File file = chooser.open.end(res);
                debug("ConversationViewController: File selected: %s", file.get_path());
                request_handed_off = schedule_send_file_overlay_for_active_request(
                        file, expected_conversation, expected_generation);
            } catch (Error e) {
                if (!(e is IOError.CANCELLED) &&
                        !(e is Gtk.DialogError.CANCELLED) &&
                        !(e is Gtk.DialogError.DISMISSED)) {
                    warning("ConversationViewController: File picker error: %s", e.message);
                }
            } finally {
                if (active_file_dialog_cancellable == dialog_cancellable) {
                    active_file_dialog_cancellable = null;
                }
                if (!request_handed_off) finish_file_send_request();
            }
        });
    }

    private bool schedule_send_file_overlay_for_active_request(File file,
            Conversation expected_conversation,
            uint expected_generation, PendingPlaintextSend? pending_plaintext_send = null,
            bool allow_drop_file_reselection = false) {
        if (!file_send_request_active ||
                !is_current_file_send_context(expected_conversation, expected_generation)) {
            return false;
        }

        Idle.add(() => {
            if (!is_current_file_send_context(expected_conversation, expected_generation)) {
                finish_file_send_request(pending_plaintext_send);
                return Source.REMOVE;
            }

            open_send_file_overlay.begin(
                    file, expected_conversation, expected_generation, pending_plaintext_send,
                    allow_drop_file_reselection,
                    (obj, res) => open_send_file_overlay.end(res));
            return Source.REMOVE;
        });
        return true;
    }

    private async void open_send_file_overlay(File file, Conversation expected_conversation,
            uint expected_generation, PendingPlaintextSend? pending_plaintext_send = null,
            bool allow_drop_file_reselection = false) {
        if (!is_current_file_send_context(expected_conversation, expected_generation)) {
            finish_file_send_request(pending_plaintext_send);
            return;
        }

        File selected_file = file;
        bool can_reselect_dropped_file = allow_drop_file_reselection;
        FileInfo file_info;
        while (true) {
            debug("ConversationViewController: open_send_file_overlay called for %s",
                    selected_file.get_path());
            try {
                string attributes = FileAttribute.STANDARD_DISPLAY_NAME + "," +
                        FileAttribute.STANDARD_CONTENT_TYPE + "," +
                        FileAttribute.STANDARD_SIZE + "," + FileAttribute.STANDARD_TYPE;
                file_info = yield selected_file.query_info_async(
                        attributes, FileQueryInfoFlags.NONE, Priority.DEFAULT, null);
                break;
            } catch (Error e) {
                if (FileTransferInput.should_reselect_unreadable_drop(
                                selected_file, e, can_reselect_dropped_file) &&
                        is_current_file_send_context(
                                expected_conversation, expected_generation)) {
                    can_reselect_dropped_file = false;
                    File? reselected_file = yield reselect_dropped_file(
                            selected_file, expected_conversation, expected_generation);
                    if (reselected_file != null && is_current_file_send_context(
                            expected_conversation, expected_generation)) {
                        selected_file = (!) reselected_file;
                        continue;
                    }
                    finish_file_send_request(pending_plaintext_send);
                    return;
                }

                warning("Failed querying info for dropped or selected file: %s", e.message);
                if (is_current_file_send_context(expected_conversation, expected_generation)) {
                    show_file_input_error();
                }
                finish_file_send_request(pending_plaintext_send);
                return;
            }
        }
        if (!is_current_file_send_context(expected_conversation, expected_generation)) {
            finish_file_send_request(pending_plaintext_send);
            return;
        }

        FileSendOverlay file_send_overlay = new FileSendOverlay(selected_file, file_info);
        active_file_send_overlay = file_send_overlay;
        bool dialog_closed = false;
        file_send_overlay.send_file.connect((file, preferred_file_sender_id) => {
            if (!is_current_file_send_context(expected_conversation, expected_generation)) return;
            if (pending_plaintext_send != null && !((!) pending_plaintext_send).begin_send()) return;
            send_file(file, expected_conversation, preferred_file_sender_id, pending_plaintext_send);
        });

        FileManager file_manager = stream_interactor.get_module<FileManager>(FileManager.IDENTITY);
        var progressive_limits = new HashMap<int, long>();
        file_manager.get_file_size_limits_progressive.begin(expected_conversation, file_info.get_size(),
                (sender_id, limit) => {
            progressive_limits[sender_id] = limit;
            if (dialog_closed || !is_current_file_send_context(expected_conversation, expected_generation)) return;

            // HTTP Upload is normally resolved from local service-discovery
            // state, while a direct-transfer probe may still be waiting on a
            // peer disco request. Make every resolved method usable
            // immediately instead of keeping the whole dialog disabled.
            file_send_overlay.set_file_sender_limits(progressive_limits, file_info.get_size());
        }, (_, res) => {
            HashMap<int, long> limits = file_manager.get_file_size_limits_progressive.end(res);
            if (dialog_closed || !is_current_file_send_context(expected_conversation, expected_generation)) return;

            file_send_overlay.set_file_sender_limits(limits, file_info.get_size());
            bool something_works = false;
            foreach (var limit in limits.values) {
                if (limit >= file_info.get_size()) {
                    something_works = true;
                }
            }
            if (!something_works && file_send_overlay != null) {
                long http_limit = limits.has_key(FileManager.HTTP_PROVIDER_ID) ? limits[FileManager.HTTP_PROVIDER_ID] : -1;
                if (http_limit >= 0 && file_info.get_size() > http_limit) {
                    file_send_overlay.set_file_too_large();
                } else {
                    file_send_overlay.set_no_transfer_method_available();
                }
            }
        });

        file_send_overlay.closed.connect(() => {
            dialog_closed = true;
            active_file_send_overlay = null;
            finish_file_send_request(pending_plaintext_send);
        });

        file_send_overlay.present(view);
        debug("ConversationViewController: file_send_overlay presented");
    }

    private async File? reselect_dropped_file(File dropped_file,
            Conversation expected_conversation, uint expected_generation) {
        if (!is_current_file_send_context(expected_conversation, expected_generation)) {
            return null;
        }

        var chooser = new Gtk.FileDialog();
        chooser.title = _("Select the dropped file again");
        chooser.accept_label = _("Select");
        File? parent = dropped_file.get_parent();
        if (parent != null) chooser.initial_folder = parent;

        var dialog_cancellable = new Cancellable();
        active_file_dialog_cancellable = dialog_cancellable;
        try {
            File selected_file = yield chooser.open(
                    view.get_root() as Gtk.Window, dialog_cancellable);
            if (!is_current_file_send_context(
                    expected_conversation, expected_generation)) return null;
            return selected_file;
        } catch (Error e) {
            if (e is IOError.CANCELLED || e is Gtk.DialogError.CANCELLED ||
                    e is Gtk.DialogError.DISMISSED) return null;
            warning("Failed selecting the dropped file through the file portal: %s", e.message);
            if (is_current_file_send_context(expected_conversation, expected_generation)) {
                show_file_input_error();
            }
            return null;
        } finally {
            if (active_file_dialog_cancellable == dialog_cancellable) {
                active_file_dialog_cancellable = null;
            }
        }
    }

    private void send_file(File file, Conversation target_conversation,
            int preferred_file_sender_id = FileManager.NO_REQUIRED_FILE_SENDER_ID,
            PendingPlaintextSend? pending_plaintext_send = null) {
        if (!chat_input_controller.can_send_to_conversation(target_conversation)) {
            if (pending_plaintext_send != null) ((!) pending_plaintext_send).send_finished();
            return;
        }
        debug("ConversationViewController: send_file called for %s", file.get_path());
        var file_manager = stream_interactor.get_module<FileManager>(FileManager.IDENTITY);
        file_manager.send_file.begin(file, target_conversation, (file_transfer) => {
            file_transfer.preferred_file_sender_id = preferred_file_sender_id;
        }, (_, res) => {
            try {
                file_manager.send_file.end(res);
            } finally {
                if (pending_plaintext_send != null) {
                    ((!) pending_plaintext_send).send_finished();
                }
            }
        });
    }

    private bool can_start_file_send() {
        return conversation != null && file_upload_available && !file_send_request_active &&
            chat_input_controller.can_send_current();
    }

    private void show_file_input_error() {
        var dialog = new Adw.AlertDialog(
                _("Could not attach file"),
                _("DinoX could not read the selected file. Try the attachment button."));
        dialog.add_response("close", _("Close"));
        dialog.set_default_response("close");
        dialog.set_close_response("close");
        dialog.present(view);
    }

    private bool can_accept_file_drop(Gdk.Drop drop) {
        if (!FileTransferInput.has_compatible_drag_action(
                drop.get_actions(), Gdk.DragAction.COPY)) return false;

        // Avoid GtkDropTargetAsync.get_formats(): GTK returns a borrowed
        // pointer, but GTK 4.14 GIR metadata incorrectly marks it transfer-full.
        Gdk.ContentFormats target_formats = FileTransferInput.create_drop_formats();
        return FileTransferInput.has_compatible_file_format(
                target_formats, drop.get_formats());
    }

    private bool is_current_file_send_context(Conversation expected_conversation,
            uint expected_generation) {
        return FileTransferInput.is_current_target_request(
                expected_conversation, conversation,
                expected_generation, conversation_generation, file_upload_available) &&
            chat_input_controller.can_send_current();
    }

    private void finish_file_send_request(PendingPlaintextSend? pending_plaintext_send = null) {
        if (pending_plaintext_send != null) {
            ((!) pending_plaintext_send).overlay_closed();
        }
        file_send_request_active = false;
    }

    private void close_active_file_send_overlay() {
        if (active_file_send_overlay != null) {
            ((!) active_file_send_overlay).close();
        }
    }

    private void cancel_active_file_dialog() {
        if (active_file_dialog_cancellable != null) {
            ((!) active_file_dialog_cancellable).cancel();
            active_file_dialog_cancellable = null;
        }
    }

    private bool forward_key_press_to_chat_input(EventControllerKey key_controller, uint keyval, uint keycode, Gdk.ModifierType state) {
        Gtk.Root? root = view.get_root();
        if (root == null || !should_forward_composer_key(root.get_focus(),
                view.conversation_frame, keyval, state)) return false;
        return key_controller.forward(view.chat_input.chat_text_view.text_view);
    }

    internal static bool should_forward_composer_key(Widget? focus,
            Widget timeline, uint keyval, Gdk.ModifierType state) {
        if ((state & (ModifierType.CONTROL_MASK | ModifierType.ALT_MASK |
                ModifierType.SUPER_MASK | ModifierType.HYPER_MASK | ModifierType.META_MASK)) != 0) return false;
        // Navigation, activation and IME keys belong to the focused control.
        // Only ordinary printable typing from the passive timeline redirects.
        unichar character = (unichar) Gdk.keyval_to_unicode(keyval);
        if (character == 0 || !character.isprint() || keyval == Gdk.Key.space) return false;
        for (Widget? widget = focus; widget != null; widget = widget.get_parent()) {
            if (widget is TextView || widget is Gtk.Editable || widget is Button ||
                    widget is MenuButton || widget is DropDown || widget is Range) return false;
            if (widget == timeline) return true;
        }
        return false;
    }

    private bool is_current_location_context(Conversation expected_conversation,
            uint expected_generation, uint expected_attempt) {
        return location_attempt_generation == expected_attempt &&
            active_location_target != null &&
            ((!) active_location_target).matches(expected_conversation) &&
            conversation == expected_conversation &&
            conversation_generation == expected_generation &&
            app.settings.location_sharing_enabled &&
            chat_input_controller.can_send_current();
    }

    private void cancel_location_request() {
        // Cancellation stays final even if the same chat becomes writable
        // again before an uncancellable platform cleanup finishes.
        location_attempt_generation++;
        active_location_target = null;
        if (active_location_timeout_id != 0) {
            Source.remove(active_location_timeout_id);
            active_location_timeout_id = 0;
        }
        if (active_location_cancellable != null) {
            ((!) active_location_cancellable).cancel();
            active_location_cancellable = null;
        }
        if (active_location_dialog != null) {
            Adw.AlertDialog dialog = (!) active_location_dialog;
            active_location_dialog = null;
            dialog.close();
        }
        view.chat_input.set_location_request_active(false);
    }

    private void send_location() {
        if (conversation == null || !chat_input_controller.can_send_current() ||
                !app.settings.location_sharing_enabled || active_location_dialog != null) return;
        var loc_mgr = LocationManager.get_default();
        if (loc_mgr.is_busy() || active_location_cancellable != null) return;

        Conversation expected_conversation = (!) conversation;
        uint expected_generation = conversation_generation;
        uint expected_attempt = ++location_attempt_generation;
        active_location_target = new ChatInput.InputTargetSnapshot(expected_conversation);
        var cancel = new Cancellable();
        active_location_cancellable = cancel;
        view.chat_input.set_location_request_active(true);
        active_location_timeout_id = Timeout.add_seconds(15, () => {
            if (active_location_cancellable == cancel) active_location_timeout_id = 0;
            cancel.cancel();
            return Source.REMOVE;
        });

        loc_mgr.get_location.begin(cancel, (obj, res) => {
            if (active_location_cancellable == cancel) {
                active_location_cancellable = null;
                if (active_location_timeout_id != 0) {
                    Source.remove(active_location_timeout_id);
                    active_location_timeout_id = 0;
                }
                view.chat_input.set_location_request_active(false);
            }
            try {
                double lat, lon, accuracy;
                loc_mgr.get_location.end(res, out lat, out lon, out accuracy);
                if (!is_current_location_context(expected_conversation, expected_generation, expected_attempt)) return;
                if (!valid_location_coordinates(lat, lon) || !accuracy.is_finite() || accuracy < 0) {
                    show_manual_location_dialog(expected_conversation, expected_generation, expected_attempt);
                } else if (accuracy > 1000) {
                    show_accuracy_warning(expected_conversation, expected_generation, expected_attempt, lat, lon, accuracy);
                } else {
                    send_location_message(expected_conversation, expected_generation, expected_attempt, lat, lon, accuracy);
                }
            } catch (Error e) {
                if (!is_current_location_context(expected_conversation, expected_generation, expected_attempt)) return;
                debug("Location lookup unavailable: %s; offering manual coordinates", e.message);
                show_manual_location_dialog(expected_conversation, expected_generation, expected_attempt);
            }
        });
    }

    private void show_accuracy_warning(Conversation expected_conversation,
            uint expected_generation, uint expected_attempt, double lat, double lon, double accuracy) {
        if (!is_current_location_context(expected_conversation, expected_generation, expected_attempt)) return;
        double accuracy_km = accuracy / 1000.0;
        string body_text = _("The detected location has an accuracy of approximately %.0f km. This may be very inaccurate. You can send it anyway or enter coordinates manually.").printf(accuracy_km);
        var dialog = new Adw.AlertDialog(_("Low location accuracy"), body_text);
        active_location_dialog = dialog;
        dialog.add_response("cancel", _("Cancel"));
        dialog.add_response("manual", _("Enter manually"));
        dialog.add_response("send", _("Send anyway"));
        dialog.set_close_response("cancel");
        dialog.set_default_response("cancel");
        dialog.set_response_appearance("manual", Adw.ResponseAppearance.SUGGESTED);
        dialog.set_response_appearance("send", Adw.ResponseAppearance.DESTRUCTIVE);
        WeakRef dialog_weak = WeakRef(dialog);
        dialog.response.connect((response) => {
            if (active_location_dialog == dialog_weak.get()) active_location_dialog = null;
            if (!is_current_location_context(expected_conversation, expected_generation, expected_attempt)) return;
            if (response == "send") {
                send_location_message(expected_conversation, expected_generation, expected_attempt, lat, lon, accuracy);
            } else if (response == "manual") {
                show_manual_location_dialog(expected_conversation, expected_generation, expected_attempt);
            }
        });
        dialog.present(main_window);
    }

    internal static bool valid_location_coordinates(double lat, double lon) {
        return lat.is_finite() && lon.is_finite() &&
            lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180;
    }

    internal static bool try_parse_location_coordinates(string latitude,
            string longitude, out double lat, out double lon) {
        string lat_text = latitude.strip().replace(",", ".");
        string lon_text = longitude.strip().replace(",", ".");
        lat = 0;
        lon = 0;
        return lat_text != "" && lon_text != "" &&
            double.try_parse(lat_text, out lat) &&
            double.try_parse(lon_text, out lon) && valid_location_coordinates(lat, lon);
    }

    private static void update_location_coordinate_response(WeakRef dialog_weak,
            WeakRef latitude_weak, WeakRef longitude_weak) {
        var dialog = dialog_weak.get() as Adw.AlertDialog;
        var latitude = latitude_weak.get() as Gtk.Entry;
        var longitude = longitude_weak.get() as Gtk.Entry;
        if (dialog == null || latitude == null || longitude == null) return;
        double lat, lon;
        dialog.set_response_enabled("send", try_parse_location_coordinates(
            latitude.text, longitude.text, out lat, out lon));
    }

    private static void install_location_coordinate_validation(Adw.AlertDialog dialog,
            Gtk.Entry latitude, Gtk.Entry longitude, Gtk.Entry geo) {
        WeakRef dialog_weak = WeakRef(dialog);
        WeakRef latitude_weak = WeakRef(latitude);
        WeakRef longitude_weak = WeakRef(longitude);
        WeakRef geo_weak = WeakRef(geo);
        latitude.changed.connect(() => {
            update_location_coordinate_response(dialog_weak, latitude_weak, longitude_weak);
        });
        longitude.changed.connect(() => {
            update_location_coordinate_response(dialog_weak, latitude_weak, longitude_weak);
        });
        geo.changed.connect(() => {
            var geo_entry = geo_weak.get() as Gtk.Entry;
            var lat_entry = latitude_weak.get() as Gtk.Entry;
            var lon_entry = longitude_weak.get() as Gtk.Entry;
            if (geo_entry == null || lat_entry == null || lon_entry == null) return;
            string text = geo_entry.text.strip();
            if (text == "") return;
            if (!text.has_prefix("geo:")) {
                lat_entry.text = "";
                lon_entry.text = "";
                return;
            }
            string[] parts = text.substring(4).split(",");
            if (parts.length < 2) {
                lat_entry.text = "";
                lon_entry.text = "";
                return;
            }
            lat_entry.text = parts[0].strip();
            lon_entry.text = parts[1].split(";", 2)[0].split("?", 2)[0].strip();
        });
    }

    private void show_manual_location_dialog(Conversation expected_conversation,
            uint expected_generation, uint expected_attempt) {
        if (!is_current_location_context(expected_conversation, expected_generation, expected_attempt)) return;
        var dialog = new Adw.AlertDialog(_("Send Location"), _("Enter coordinates or paste a geo: link (e.g. geo:48.2082,16.3738)"));
        active_location_dialog = dialog;
        var grid = new Gtk.Grid();
        grid.column_spacing = 10;
        grid.row_spacing = 8;
        grid.margin_start = grid.margin_end = 12;

        var lat_label = new Gtk.Label(_("Latitude"));
        lat_label.halign = Gtk.Align.END;
        var lat_entry = new Gtk.Entry();
        lat_entry.placeholder_text = "48.2082";
        lat_entry.input_purpose = Gtk.InputPurpose.NUMBER;
        lat_entry.hexpand = true;
        var lon_label = new Gtk.Label(_("Longitude"));
        lon_label.halign = Gtk.Align.END;
        var lon_entry = new Gtk.Entry();
        lon_entry.placeholder_text = "16.3738";
        lon_entry.input_purpose = Gtk.InputPurpose.NUMBER;
        lon_entry.hexpand = true;
        var geo_label = new Gtk.Label(_("or geo: link"));
        geo_label.halign = Gtk.Align.END;
        var geo_entry = new Gtk.Entry();
        geo_entry.placeholder_text = "geo:48.2082,16.3738";
        geo_entry.hexpand = true;
        grid.attach(lat_label, 0, 0); grid.attach(lat_entry, 1, 0);
        grid.attach(lon_label, 0, 1); grid.attach(lon_entry, 1, 1);
        grid.attach(geo_label, 0, 2); grid.attach(geo_entry, 1, 2);
        dialog.set_extra_child(grid);
        dialog.add_response("cancel", _("Cancel"));
        dialog.add_response("send", _("Send"));
        dialog.set_close_response("cancel");
        dialog.set_default_response("cancel");
        dialog.set_response_appearance("send", Adw.ResponseAppearance.SUGGESTED);
        dialog.set_response_enabled("send", false);

        // The response remains disabled for incomplete/invalid input, keeping
        // the entered coordinates available for correction in this dialog.
        install_location_coordinate_validation(dialog, lat_entry, lon_entry, geo_entry);
        WeakRef dialog_weak = WeakRef(dialog);
        dialog.response.connect((response) => {
            if (active_location_dialog == dialog_weak.get()) active_location_dialog = null;
            if (response != "send" ||
                    !is_current_location_context(expected_conversation, expected_generation, expected_attempt)) return;
            double lat, lon;
            if (try_parse_location_coordinates(lat_entry.text, lon_entry.text, out lat, out lon)) {
                send_location_message(expected_conversation, expected_generation, expected_attempt, lat, lon, 0);
            }
        });
        dialog.present(main_window);
    }

    internal static void add_plaintext_location_extension(Entities.Message message,
            Xmpp.MessageStanza stanza, double lat, double lon, double accuracy) {
        // Legacy OMEMO and OpenPGP encrypt the body, not arbitrary outer XML.
        // The encrypted geo: body is sufficient for the location renderer.
        if (message.encryption != Encryption.NONE) return;
        var user_loc = new Xmpp.Xep.UserLocation.UserLocation.create();
        user_loc.lat = lat;
        user_loc.lon = lon;
        user_loc.accuracy = accuracy;
        stanza.stanza.put_node(user_loc.node);
    }

    private void send_location_message(Conversation expected_conversation,
            uint expected_generation, uint expected_attempt, double lat, double lon, double accuracy) {
        if (!is_current_location_context(expected_conversation, expected_generation, expected_attempt) ||
                !valid_location_coordinates(lat, lon) || !accuracy.is_finite() || accuracy < 0) return;
        string body = "geo:%s,%s".printf(
            "%.6f".printf(lat).replace(",", "."),
            "%.6f".printf(lon).replace(",", "."));
        MessageProcessor processor = stream_interactor.get_module<MessageProcessor>(MessageProcessor.IDENTITY);
        Entities.Message message = processor.create_out_message(body, expected_conversation);
        ulong signal_id = processor.pre_message_send.connect((msg, stanza, conv) => {
            if (msg == message && conv == expected_conversation) {
                add_plaintext_location_extension(msg, stanza, lat, lon, accuracy);
            }
        });
        stream_interactor.get_module<ContentItemStore>(ContentItemStore.IDENTITY).insert_message(message, expected_conversation);
        processor.send_xmpp_message(message, expected_conversation);
        // send_xmpp_message emits pre_message_send synchronously or returns
        // offline. Do not leave this one-message handler in the global service.
        processor.disconnect(signal_id);
        processor.message_sent(message, expected_conversation);
    }

}
}

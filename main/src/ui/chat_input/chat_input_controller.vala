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
using Xmpp;

using Xmpp;
using Dino.Entities;
using Dino.Ui.ChatInput;

namespace Dino.Ui {

public class ChatInputController : Object {

    public signal void activate_last_message_correction();
    public signal void file_picker_selected();
    public signal void clipboard_pasted();
    public signal void voice_message_recorded(string path, Conversation target_conversation);
    public signal void video_message_recorded(string path, Conversation target_conversation);
    public signal void send_allowed_changed(bool allowed);

    public new string? conversation_display_name { get; set; }
    public string? conversation_topic { get; set; }

    private Conversation? conversation;
    private InputTargetSnapshot? current_target = null;
    private bool suppress_chat_state_on_text_change = false;
    private ChatInput.View chat_input;
    private Label status_description_label;

    private StreamInteractor stream_interactor;
    private MucVoiceRequestManager voice_request_manager;
    private Plugins.InputFieldStatus input_field_status;
    private Plugins.InputFieldStatus? encryption_input_status = null;
    private ChatTextViewController chat_text_view_controller;
    private uint encryption_status_generation = 0;
    private uint send_controls_refresh_source = 0;
    private Account? observed_send_account = null;
    private ulong observed_send_account_enabled_handler = 0;

    private ContentItem? quoted_content_item = null;
    private AudioMessageRecorderBackend? audio_recorder = null;
    private RecordingSendContext audio_recording_send_context = new RecordingSendContext();
    private VoiceRecorderPopover? recorder_popover = null;
    private bool is_recording = false;
    private VideoMessageRecorderBackend? video_recorder = null;
    private RecordingSendContext video_recording_send_context = new RecordingSendContext();
    private VideoRecorderPopover? video_popover = null;
    private bool is_video_recording = false;
    private bool video_recording_finalizing = false;
    private int64 video_recording_finalize_start_us = 0;

    public ChatInputController(ChatInput.View chat_input, StreamInteractor stream_interactor) {
        this.chat_input = chat_input;
        this.status_description_label = chat_input.chat_input_status;
        this.stream_interactor = stream_interactor;
        this.chat_text_view_controller = new ChatTextViewController(chat_input.chat_text_view, stream_interactor);

        chat_input.init(stream_interactor);

        reset_input_field_status();

        var text_input_key_events = new EventControllerKey() { name = "dino-text-input-controller-key-events" };
        text_input_key_events.key_pressed.connect(on_text_input_key_press);
        chat_input.chat_text_view.text_view.add_controller(text_input_key_events);

        chat_input.chat_text_view.text_view.paste_clipboard.connect(() => clipboard_pasted());
        chat_input.chat_text_view.text_view.buffer.changed.connect(on_text_input_changed);

        chat_text_view_controller.send_text.connect(send_text);

        chat_input.encryption_widget.encryption_changed.connect(on_encryption_changed);

        // chat_input.file_button.clicked.connect(() => file_picker_selected());
        chat_input.record_button.clicked.connect(show_recorder_popover);
        chat_input.video_record_button.clicked.connect(show_video_recorder_popover);
        chat_input.send_button.clicked.connect(send_text);
        chat_input.request_voice_button.clicked.connect(request_voice);

        stream_interactor.account_added.connect(on_send_account_added);
        stream_interactor.account_removed.connect(on_send_account_removed);
        stream_interactor.connection_manager.connection_state_changed.connect(on_send_connection_state_changed);
        stream_interactor.stream_negotiated.connect(on_send_stream_ready);
        stream_interactor.stream_resumed.connect(on_send_stream_ready);

        MucManager muc_manager = stream_interactor.get_module<MucManager>(MucManager.IDENTITY);
        voice_request_manager = stream_interactor.get_module<
            MucVoiceRequestManager>(MucVoiceRequestManager.IDENTITY);
        muc_manager.received_occupant_role.connect(update_moderated_input_status);
        muc_manager.room_info_updated.connect(update_moderated_input_status);
        // A role is valid only for the current room visit.  In particular, a
        // kick/ban clears our occupant JID before the next role notification.
        // Keep the composer in sync with that lifecycle instead of leaving an
        // apparently writable input behind while we are no longer an occupant.
        muc_manager.joined.connect(update_moderated_input_status);
        muc_manager.left_signal.connect(update_moderated_input_status);
        muc_manager.self_removed.connect((account, room_jid, code, reason) => {
            update_moderated_input_status(account, room_jid);
        });
        voice_request_manager.own_request_changed.connect((account,
                room_jid, request) => {
            update_moderated_input_status(account, room_jid);
        });

        SimpleAction quote_action = new SimpleAction("quote", new VariantType("(ii)"));
        quote_action.activate.connect((variant) => {
            int conversation_id = variant.get_child_value(0).get_int32();
            Conversation? conversation = stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY).get_conversation_by_id(conversation_id);
            if (conversation == null || this.conversation == null ||
                    !this.conversation.equals(conversation)) return;

            int content_item_id = variant.get_child_value(1).get_int32();
            ContentItem? content_item = stream_interactor.get_module<ContentItemStore>(ContentItemStore.IDENTITY).get_item_by_id(conversation, content_item_id);
            if (content_item == null) return;

            quoted_content_item = content_item;
            var quote_model = new Quote.Model.from_content_item(content_item, conversation, stream_interactor) { can_abort = true };
            quote_model.aborted.connect(() => {
                quoted_content_item = null;
                chat_input.unset_quoted_message();
            });
            chat_input.set_quoted_message(Quote.get_widget(quote_model));
        });
        GLib.Application.get_default().add_action(quote_action);
    }

    private void on_send_account_added(Account account) {
        // account_added restores the selected conversation before
        // ConnectionManager inserts this account into its managed set.
        // Refresh after the emission has completed, including accounts whose
        // Tor/readiness gate or a test interceptor emits no CONNECTING state.
        queue_send_controls_refresh();
    }

    private void on_send_account_removed(Account account) {
        if (conversation != null && conversation.account == account) {
            restore_input_field_status();
        }
    }

    private void on_send_connection_state_changed(Account account,
            ConnectionManager.ConnectionState state) {
        if (conversation != null && conversation.account == account) {
            restore_input_field_status();
        }
    }

    private void on_send_stream_ready(Account account, Xmpp.XmppStream stream) {
        if (conversation != null && conversation.account == account) {
            restore_input_field_status();
        }
    }

    private void queue_send_controls_refresh() {
        if (send_controls_refresh_source != 0) return;
        send_controls_refresh_source = queue_send_controls_refresh_source(this);
    }

    private static uint queue_send_controls_refresh_source(ChatInputController owner) {
        WeakRef controller_weak = WeakRef(owner);
        return Idle.add(() => {
            var controller = controller_weak.get() as ChatInputController;
            if (controller != null) {
                controller.send_controls_refresh_source = 0;
                // Recompute the currently selected account/room. This keeps
                // encryption readiness and moderation blocks intact even if
                // selection changed while account setup was pending.
                controller.restore_input_field_status();
            }
            return Source.REMOVE;
        });
    }

    private void observe_send_account(Account? account) {
        if (observed_send_account == account) return;
        if (observed_send_account != null && observed_send_account_enabled_handler != 0) {
            ((!) observed_send_account).disconnect(observed_send_account_enabled_handler);
        }
        observed_send_account_enabled_handler = 0;
        observed_send_account = account;
        if (account != null) {
            observed_send_account_enabled_handler = ((!) account).notify["enabled"].connect(
                on_send_account_enabled_changed);
        }
    }

    private void on_send_account_enabled_changed(Object source, ParamSpec property) {
        if (conversation == null || source != conversation.account) return;
        restore_input_field_status();
        if (conversation.account.enabled) queue_send_controls_refresh();
    }

    public override void dispose() {
        if (send_controls_refresh_source != 0) {
            Source.remove(send_controls_refresh_source);
            send_controls_refresh_source = 0;
        }
        observe_send_account(null);
        stream_interactor.account_added.disconnect(on_send_account_added);
        stream_interactor.account_removed.disconnect(on_send_account_removed);
        stream_interactor.connection_manager.connection_state_changed.disconnect(on_send_connection_state_changed);
        stream_interactor.stream_negotiated.disconnect(on_send_stream_ready);
        stream_interactor.stream_resumed.disconnect(on_send_stream_ready);
        base.dispose();
    }

    public void set_conversation(Conversation conversation) {
        debug("ChatInputController.set_conversation: Called with %s", conversation != null ? conversation.counterpart.to_string() : "NULL");
        int64 t0_us = Dino.Ui.UiTiming.now_us();
        encryption_status_generation++;
        suppress_chat_state_on_text_change = true;
        encryption_input_status = null;
        reset_input_field_status();
        this.quoted_content_item = null;
        chat_input.unset_quoted_message();

        this.conversation = conversation;
        observe_send_account(conversation.account);
        current_target = new InputTargetSnapshot(conversation);

        int64 t_enc_us = Dino.Ui.UiTiming.now_us();
        debug("ChatInputController.set_conversation: About to call encryption_widget.set_conversation");
        chat_input.encryption_widget.set_conversation(conversation);
        Dino.Ui.UiTiming.log_ms("ChatInputController.set_conversation: encryption_widget.set_conversation", t_enc_us);

        int64 t_view_us = Dino.Ui.UiTiming.now_us();
        chat_input.initialize_for_conversation(conversation);
        Dino.Ui.UiTiming.log_ms("ChatInputController.set_conversation: chat_input.initialize_for_conversation", t_view_us);

        int64 t_text_us = Dino.Ui.UiTiming.now_us();
        chat_text_view_controller.initialize_for_conversation(conversation);
        Dino.Ui.UiTiming.log_ms("ChatInputController.set_conversation: chat_text_view_controller.initialize_for_conversation", t_text_us);

        int64 t_mod_us = Dino.Ui.UiTiming.now_us();
        update_moderated_input_status(conversation.account);
        Dino.Ui.UiTiming.log_ms("ChatInputController.set_conversation: update_moderated_input_status", t_mod_us);

        suppress_chat_state_on_text_change = false;
        update_send_controls();

        Dino.Ui.UiTiming.log_ms("ChatInputController.set_conversation: total", t0_us);
    }

    public void unset_conversation() {
        observe_send_account(null);
        encryption_status_generation++;
        suppress_chat_state_on_text_change = true;
        encryption_input_status = null;
        reset_input_field_status();
        this.quoted_content_item = null;
        chat_input.unset_quoted_message();
        chat_input.encryption_widget.unset_conversation();
        chat_text_view_controller.unset_conversation();
        chat_input.unset_conversation();
        this.conversation = null;
        current_target = null;
        suppress_chat_state_on_text_change = false;
        update_send_controls();
    }

    public void set_file_upload_active(bool active) {
        chat_input.set_file_upload_active(active);
    }

    public void on_conversation_cleared(Conversation cleared_conversation) {
        if (conversation == null || conversation.type_ != Conversation.Type.GROUPCHAT_PM ||
                conversation.id != cleared_conversation.id ||
                conversation.account != cleared_conversation.account ||
                !conversation.counterpart.equals(cleared_conversation.counterpart) ||
                current_target == null || ((!) current_target).matches(conversation)) return;
        current_target = new InputTargetSnapshot(conversation);
        quoted_content_item = null;
        chat_input.unset_quoted_message();
        chat_input.chat_text_view.text_view.buffer.text = "";
        update_send_controls();
    }

    private void on_encryption_changed(Encryption encryption) {
        debug("ChatInputController: on_encryption_changed called with %d", (int)encryption);
        encryption_status_generation++;
        uint current_generation = encryption_status_generation;
        Conversation? checked_conversation = conversation;
        encryption_input_status = null;
        restore_input_field_status();

        if (encryption == Encryption.NONE) {
            debug("ChatInputController: encryption is NONE, returning");
            return;
        }

        Application app = GLib.Application.get_default() as Application;
        debug("ChatInputController: Looking for encryption_entry for %d, registry has %d entries", 
              (int)encryption, app.plugin_registry.encryption_list_entries.size);
        var encryption_entry = app.plugin_registry.encryption_list_entries[encryption];
        if (encryption_entry != null) {
            debug("ChatInputController: Found encryption_entry '%s', calling encryption_activated", encryption_entry.name);
            encryption_entry.encryption_activated(conversation, (status) => {
                if (current_generation != encryption_status_generation ||
                        checked_conversation == null ||
                        conversation == null ||
                        !conversation.equals(checked_conversation) ||
                        conversation.encryption != encryption) {
                    debug("ChatInputController: ignoring stale encryption status for %d", (int) encryption);
                    return;
                }
                if (encryption_status_requires_context_restore(status)) {
                    // An async encryption readiness check has finished. Restore
                    // the current room state instead of blindly enabling the
                    // composer: a visitor or a user who left the room must
                    // remain unable to send.
                    encryption_input_status = null;
                    restore_input_field_status();
                } else {
                    encryption_input_status = status;
                    restore_input_field_status();
                }
            });
        } else {
            debug("ChatInputController: encryption_entry is NULL for %d!", (int)encryption);
        }
    }

    private void set_input_field_status(Plugins.InputFieldStatus status) {
        // Finalizing a recording is presentation state, not permission to
        // send. Always retain current encryption/membership/moderation policy.
        input_field_status = status;
        update_input_status_presentation();
        update_send_controls();
    }

    private void update_input_status_presentation() {
        bool show_finalizing = video_recording_finalizing &&
            input_field_status.input_state == Plugins.InputFieldStatus.InputState.NORMAL;
        chat_input.set_input_state(show_finalizing ?
            Plugins.InputFieldStatus.MessageType.INFO : input_field_status.message_type);
        status_description_label.use_markup = !show_finalizing && input_field_status.contains_markup;
        status_description_label.label = show_finalizing ?
            _("Preparing video message…") : input_field_status.message;
    }

    public bool can_send_current() {
        return conversation != null && input_field_status != null &&
            input_field_status.input_state == Plugins.InputFieldStatus.InputState.NORMAL &&
            can_send_to_conversation((!) conversation);
    }

    // Recordings retain their original destination across chat switches. A
    // late completion must check that destination, never the newly opened one.
    public bool can_send_to_conversation(Conversation target) {
        bool managed = false;
        foreach (Account account in stream_interactor.get_accounts()) {
            if (account == target.account) {
                managed = true;
                break;
            }
        }
        if (!managed || !target.account.enabled) return false;
        if (target == conversation && input_field_status != null &&
                input_field_status.input_state != Plugins.InputFieldStatus.InputState.NORMAL) {
            return false;
        }
        if (target.type_ == Conversation.Type.GROUPCHAT) {
            MucManager muc_manager = stream_interactor.get_module<MucManager>(MucManager.IDENTITY);
            Jid? own_jid = muc_manager.get_own_jid(target.counterpart, target.account);
            return own_jid != null && muc_manager.is_joined(target.counterpart, target.account) &&
                muc_manager.get_role((!) own_jid, target.account) != Xmpp.Xep.Muc.Role.VISITOR;
        }
        if (target.type_ == Conversation.Type.GROUPCHAT_PM) {
            return stream_interactor.get_module<MessageProcessor>(MessageProcessor.IDENTITY)
                .is_groupchat_pm_send_target_valid(target);
        }
        return true;
    }

    private void update_send_controls() {
        bool allowed = can_send_current();
        chat_input.set_send_allowed(allowed);
        send_allowed_changed(allowed);
    }

    private void set_context_input_field_status(
            Plugins.InputFieldStatus status) {
        set_input_field_status(effective_context_input_status(status,
            encryption_input_status));
    }

    private void reset_input_field_status() {
        chat_input.request_voice_button.visible = false;
        set_context_input_field_status(new Plugins.InputFieldStatus("",
            Plugins.InputFieldStatus.MessageType.NONE,
            Plugins.InputFieldStatus.InputState.NORMAL));
    }

    private void restore_input_field_status() {
        reset_input_field_status();
        if (conversation != null) {
            update_moderated_input_status(conversation.account);
        }
    }

    private void send_text() {
        // Don't do anything if we're in a NO_SEND state. Don't clear the chat input, don't send.
        if (!can_send_current()) {
            chat_input.highlight_state_description();
            return;
        }

        string text = chat_input.chat_text_view.get_text();
        if (text.strip() == "") return;

        ContentItem? quoted_content_item_bak = quoted_content_item;
        var markups = chat_input.chat_text_view.get_markups();

        // Reset input state. Has do be done before parsing commands, because those directly return.
        chat_input.chat_text_view.text_view.buffer.text = "";
        chat_input.unset_quoted_message();
        quoted_content_item = null;

        if (text.has_prefix("/")) {
            string[] token = text.split(" ", 2);
            switch(token[0]) {
                case "/me":
                    // Just send as is.
                    break;
                case "/say":
                    if (token.length == 1) return;
                    text = token[1];
                    markups = ChatTextView.trim_markup_prefix(markups, 5,
                        (int) text.char_count());
                    break;
                case "/kick":
                    if (token.length < 2) return;
                    perform_kick_command.begin(conversation, token[1].strip());
                    return;
                case "/affiliate":
                    if (token.length > 1) {
                        string[] user_affiliation = token[1].strip().split(" ", 2);
                        if (user_affiliation.length == 2) {
                            try {
                                Jid target = new Jid(user_affiliation[0].strip());
                                if (target.is_full()) {
                                    show_muc_command_error(_("A bare JID is required."));
                                    return;
                                }
                                perform_affiliation_command.begin(conversation,
                                    target.bare_jid,
                                    user_affiliation[1].strip());
                            } catch (Xmpp.InvalidJidError e) {
                                show_muc_command_error(e.message);
                            }
                        } else {
                            show_muc_command_error(
                                _("Use /affiliate user@example.org member|admin|owner|outcast|none."));
                        }
                    }
                    return;
                case "/nick":
                    if (token.length < 2) return;
                    stream_interactor.get_module<MucManager>(MucManager.IDENTITY).change_nick.begin(conversation, token[1]);
                    return;
                case "/ping":
                    if (token.length < 2) return;
                    Xmpp.XmppStream? stream = stream_interactor.get_stream(conversation.account);
                    if (stream == null || conversation.type_ != Conversation.Type.GROUPCHAT) {
                        show_muc_command_error(_("The room action is not permitted for the current user state."));
                        return;
                    }
                    try {
                        stream.get_module<Xmpp.Xep.Ping.Module>(Xmpp.Xep.Ping.Module.IDENTITY).send_ping.begin(stream, conversation.counterpart.with_resource(token[1]));
                    } catch (Xmpp.InvalidJidError e) {
                        warning("Could not ping invalid Jid: %s", e.message);
                    }
                    return;
                case "/topic":
                    if (token.length < 2) return;
                    try {
                        stream_interactor.get_module<MucManager>(
                            MucManager.IDENTITY).change_subject_checked(
                                conversation.account,
                                conversation.counterpart, token[1]);
                    } catch (GLib.Error e) {
                        show_muc_command_error(
                            _("The room action is not permitted for the current user state."));
                    }
                    return;
                default:
                    if (token[0].has_prefix("//")) {
                        text = text.substring(1);
                        markups = ChatTextView.trim_markup_prefix(markups, 1,
                            (int) text.char_count());
                    } else {
                        string cmd_name = token[0].substring(1);
                        Dino.Application app = GLib.Application.get_default() as Dino.Application;
                        if (app != null && app.plugin_registry.text_commands.has_key(cmd_name)) {
                            string? new_text = app.plugin_registry.text_commands[cmd_name].handle_command(token.length > 1 ? token[1] : "", conversation);
                            if (new_text == null) return;
                            string command_text = Util.sanitize_utf8((!)new_text);
                            if (command_text != text) markups.clear();
                            text = command_text;
                        }
                    }
                    break;
            }
        }

        text = Util.sanitize_utf8(text);
        Dino.send_message(conversation, text, quoted_content_item_bak != null ? quoted_content_item_bak.id : 0, null, markups);
    }

    private async void perform_kick_command(Conversation command_conversation,
            string nick) {
        MucManager muc_manager = stream_interactor.get_module<MucManager>(
            MucManager.IDENTITY);
        if (command_conversation.type_ != Conversation.Type.GROUPCHAT ||
                !muc_manager.is_joined(command_conversation.counterpart,
                    command_conversation.account)) {
            show_muc_command_error(
                _("The room action is not permitted for the current user state."));
            return;
        }
        Jid? occupant = null;
        Gee.List<Jid>? occupants = muc_manager.get_occupants(
            command_conversation.counterpart, command_conversation.account);
        if (occupants != null) {
            foreach (Jid candidate in (!) occupants) {
                if (candidate.resourcepart == nick &&
                        muc_manager.is_current_occupant(command_conversation.account,
                            command_conversation.counterpart, candidate)) {
                    occupant = candidate;
                    break;
                }
            }
        }
        if (occupant == null || !muc_manager.kick_possible(
                command_conversation.account, (!) occupant)) {
            show_muc_command_error(
                _("The room action is not permitted for the current user state."));
            return;
        }
        try {
            yield muc_manager.kick_checked(command_conversation.account,
                command_conversation.counterpart, nick);
        } catch (GLib.Error e) {
            show_muc_command_error(e.message);
        }
    }

    private async void perform_affiliation_command(
            Conversation command_conversation, Jid target,
            string affiliation) {
        MucManager muc_manager = stream_interactor.get_module<MucManager>(
            MucManager.IDENTITY);
        if (command_conversation.type_ != Conversation.Type.GROUPCHAT ||
                !muc_manager.is_joined(command_conversation.counterpart,
                    command_conversation.account)) {
            show_muc_command_error(
                _("The room action is not permitted for the current user state."));
            return;
        }
        try {
            yield muc_manager.set_affiliation_checked(command_conversation.account,
                    command_conversation.counterpart, target.bare_jid,
                    affiliation);
        } catch (GLib.Error e) {
            show_muc_command_error(e.message);
        }
    }

    private void show_muc_command_error(string detail) {
        var dialog = new Adw.AlertDialog(_("Room action failed"), detail);
        dialog.add_response("close", _("Close"));
        Application? app = GLib.Application.get_default() as Application;
        dialog.present(app != null ? ((!) app).window : null);
    }

    private void on_text_input_changed() {
        bool has_text = chat_input.chat_text_view.get_text().strip() != "";
        chat_input.send_button.sensitive = has_text && can_send_current();

        if (suppress_chat_state_on_text_change || conversation == null) {
            return;
        }
        
        if (has_text) {
            stream_interactor.get_module<ChatInteraction>(ChatInteraction.IDENTITY).on_message_entered(conversation);
        } else {
            stream_interactor.get_module<ChatInteraction>(ChatInteraction.IDENTITY).on_message_cleared(conversation);
        }
    }

    private void update_moderated_input_status(Account account, Xmpp.Jid? jid = null) {
        if (conversation == null || conversation.type_ != Conversation.Type.GROUPCHAT) return;
        if (!conversation.account.equals(account)) return;
        if (jid != null && !((!) jid).bare_jid.equals(conversation.counterpart.bare_jid)) return;

        chat_input.request_voice_button.visible = false;
        MucManager muc_manager = stream_interactor.get_module<MucManager>(MucManager.IDENTITY);
        Xmpp.Jid? own_jid = muc_manager.get_own_jid(conversation.counterpart, conversation.account);
        if (own_jid == null || !muc_manager.is_joined(conversation.counterpart, conversation.account)) {
            set_context_input_field_status(new Plugins.InputFieldStatus(
                _("You are not currently in this room."),
                Plugins.InputFieldStatus.MessageType.ERROR,
                Plugins.InputFieldStatus.InputState.NO_SEND));
            return;
        }

        // XEP-0045 defines visitor as the role without voice.  Do not depend
        // on a possibly stale disco feature bit here: if the room assigned us
        // the visitor role, groupchat messages must not be offered locally.
        if (muc_manager.get_role((!) own_jid, conversation.account) == Xmpp.Xep.Muc.Role.VISITOR) {
            OwnMucVoiceRequest? request = voice_request_manager.get_own_request(
                conversation.account, conversation.counterpart);
            string message = _("This conference does not allow you to send messages.");
            string button_label = _("Request permission");
            Plugins.InputFieldStatus.MessageType message_type =
                Plugins.InputFieldStatus.MessageType.ERROR;
            bool button_sensitive = true;

            if (request != null) {
                switch (((!) request).state) {
                    case OwnMucVoiceRequestState.SENDING:
                        message = _("Sending permission request…");
                        message_type = Plugins.InputFieldStatus.MessageType.INFO;
                        button_sensitive = false;
                        break;
                    case OwnMucVoiceRequestState.SENT:
                        message = _("Permission request sent. A moderator can now allow you to write.");
                        message_type = Plugins.InputFieldStatus.MessageType.INFO;
                        button_label = _("Request again");
                        break;
                    case OwnMucVoiceRequestState.FAILED:
                        message = get_voice_request_failure_text(
                            ((!) request).condition, ((!) request).text);
                        button_label = _("Request again");
                        break;
                }
            }

            set_context_input_field_status(new Plugins.InputFieldStatus(message,
                message_type, Plugins.InputFieldStatus.InputState.NO_SEND));
            chat_input.request_voice_button.label = button_label;
            chat_input.request_voice_button.sensitive = button_sensitive;
            chat_input.request_voice_button.visible = true;
        } else {
            reset_input_field_status();
        }
    }

    private void request_voice() {
        if (conversation == null ||
                ((!) conversation).type_ != Conversation.Type.GROUPCHAT) {
            return;
        }

        MucManager muc_manager = stream_interactor.get_module<MucManager>(
            MucManager.IDENTITY);
        Xmpp.Jid? own_jid = muc_manager.get_own_jid(
            ((!) conversation).counterpart, ((!) conversation).account);
        if (own_jid == null ||
                !muc_manager.is_joined(((!) conversation).counterpart,
                    ((!) conversation).account) ||
                muc_manager.get_role((!) own_jid,
                    ((!) conversation).account) !=
                    Xmpp.Xep.Muc.Role.VISITOR) {
            update_moderated_input_status(((!) conversation).account,
                ((!) conversation).counterpart);
            return;
        }

        voice_request_manager.request_voice(((!) conversation).account,
            ((!) conversation).counterpart);
    }

    private string get_voice_request_failure_text(string? condition,
            string? server_text) {
        if (condition == ErrorStanza.CONDITION_RESOURCE_CONSTRAINT) {
            return _("The server rejected the request because another voice request was sent too recently. Please wait and try again.");
        }
        if (condition == ErrorStanza.CONDITION_FORBIDDEN &&
                (server_text == null || ((!) server_text).strip() == "")) {
            return _("This room does not allow visitors to request permission to write.");
        }
        if (condition == "send-failed") {
            return _("The voice request could not be sent. Please try again.");
        }
        if (server_text != null && ((!) server_text).strip() != "") {
            return _("The server rejected the voice request: %s").printf(
                (!) server_text);
        }
        return _("The voice request could not be sent. Please try again.");
    }

    private bool on_text_input_key_press(uint keyval, uint keycode, Gdk.ModifierType state) {
        if (keyval == Gdk.Key.Up && chat_input.chat_text_view.get_text() == "") {
            activate_last_message_correction();
            return true;
        } else {
            chat_input.do_focus();
        }
        return false;
    }

    private void show_recorder_popover() {
        if (!can_send_current()) {
            chat_input.highlight_state_description();
            return;
        }
        if (is_recording ||
                (audio_recorder != null && ((!) audio_recorder).state.is_busy())) return;
        try {
            ensure_audio_recorder();
        } catch (Error e) {
            show_audio_recording_error(e.message);
            return;
        }

        if (recorder_popover == null) {
            recorder_popover = new VoiceRecorderPopover((!) audio_recorder);
            recorder_popover.set_parent(chat_input.record_button);
            
            recorder_popover.send_clicked.connect(() => {
                if (is_recording) {
                    is_recording = false;
                    stop_recording();
                }
                recorder_popover.popdown();
            });
            
            recorder_popover.cancel_clicked.connect(() => {
                if (is_recording) {
                    is_recording = false;
                    cancel_recording();
                }
                recorder_popover.popdown();
            });
            
            recorder_popover.closed.connect(() => {
                if (is_recording) {
                    is_recording = false;
                    cancel_recording();
                }
            });
        }
        
        recorder_popover.prepare_for_recording();
        recorder_popover.popup();
        start_recording();
    }

    private void start_recording() {
        if (!can_send_current()) return;
        try {
            ensure_audio_recorder();
            if (((!) audio_recorder).state.is_busy()) return;
            if (!audio_recording_send_context.try_bind((!) conversation)) return;
            string recording_directory = Path.build_filename(Environment.get_user_cache_dir(), "dinox", "temp_audio");
            if (DirUtils.create_with_parents(recording_directory, 0700) != 0 ||
                    FileUtils.chmod(recording_directory, 0700) != 0) {
                throw new IOError.FAILED("%s", strerror(errno));
            }
            string path = Path.build_filename(recording_directory, "voice-" + Uuid.string_random() + ".m4a");
            debug("ChatInputController.start_recording: path=%s", path);
            ((!) audio_recorder).start_recording(path);
            is_recording = true;
            chat_input.record_button.icon_name = "media-record-symbolic";
            chat_input.record_button.add_css_class("destructive-action");
        } catch (Error e) {
            warning("Failed to start recording: %s", e.message);
            audio_recording_send_context.clear();
            is_recording = false;
            if (recorder_popover != null) {
                recorder_popover.popdown();
            }
            show_audio_recording_error(e.message);
        }
    }

    private void stop_recording() {
        debug("ChatInputController.stop_recording: called");
        if (audio_recorder == null) {
            audio_recording_send_context.clear();
            return;
        }
        ((!) audio_recorder).stop_recording();
        Conversation? target_conversation = audio_recording_send_context.take();
        debug("ChatInputController.stop_recording: recorder closed");
        
        chat_input.record_button.icon_name = "microphone-sensitivity-medium-symbolic";
        chat_input.record_button.remove_css_class("destructive-action");

        if (((!) audio_recorder).current_output_path != null) {
            string output_path = (!) ((!) audio_recorder).current_output_path;
            File f = File.new_for_path(output_path);
            try {
                FileInfo info = f.query_info(FileAttribute.STANDARD_SIZE, FileQueryInfoFlags.NONE);
                debug("ChatInputController.stop_recording: file size=%s", info.get_size().to_string());
                if (info.get_size() > 0 && target_conversation != null &&
                        can_send_to_conversation((!) target_conversation)) {
                    debug("ChatInputController.stop_recording: emitting voice_message_recorded");
                    voice_message_recorded(output_path, (!) target_conversation);
                } else {
                    warning("Recorded audio file is empty or has no send target, not sending.");
                    FileUtils.unlink(output_path);
                }
            } catch (Error e) {
                debug("ChatInputController.stop_recording: Error checking file: %s", e.message);
                warning("Failed to check recorded audio file: %s", e.message);
                FileUtils.unlink(output_path);
            }
        }
    }
    
    private void cancel_recording() {
        audio_recording_send_context.clear();
        if (audio_recorder != null) {
            ((!) audio_recorder).cancel_recording();
        }
        
        chat_input.record_button.icon_name = "microphone-sensitivity-medium-symbolic";
        chat_input.record_button.remove_css_class("destructive-action");
    }

    private void ensure_audio_recorder() throws Error {
        if (audio_recorder != null) return;
        Application? app = GLib.Application.get_default() as Application;
        Dino.Plugins.MediaMessageRecorderProvider? provider =
            app != null ? ((!) app).plugin_registry.media_message_recorder_provider : null;
        if (provider == null) {
            throw new MediaMessageRecorderError.UNSUPPORTED(_("Audio recording is not available."));
        }
        if (!((!) provider).audio_available) {
            string reason = ((!) provider).audio_unavailable_reason ?? _("Audio recording is not available.");
            throw new MediaMessageRecorderError.ENCODER_UNAVAILABLE(reason);
        }
        audio_recorder = new ProviderAudioMessageRecorderBackend((!) provider);
        ((!) audio_recorder).recording_error.connect((msg) => {
            audio_recording_send_context.clear();
            is_recording = false;
            chat_input.record_button.icon_name = "microphone-sensitivity-medium-symbolic";
            chat_input.record_button.remove_css_class("destructive-action");
            if (recorder_popover != null) {
                recorder_popover.popdown();
            }
            show_audio_recording_error(msg);
        });
    }

    private void show_audio_recording_error(string message) {
        var root = chat_input.get_root() as Gtk.Window;
        if (root == null) return;
        var dlg = new Adw.AlertDialog(
            _("Audio recording failed"),
            message);
        dlg.add_response("ok", _("OK"));
        dlg.present(root);
    }

    // === Video Recording ===

    private void show_video_recorder_popover() {
        if (!can_send_current()) {
            chat_input.highlight_state_description();
            return;
        }
        if (is_video_recording || video_recording_finalizing ||
                (video_recorder != null && ((!) video_recorder).state.is_busy())) return;
        try {
            ensure_video_recorder();
        } catch (Error e) {
            show_video_recording_error(e.message);
            return;
        }

        if (video_popover == null) {
            video_popover = new VideoRecorderPopover((!) video_recorder);
            video_popover.set_parent(chat_input.video_record_button);

            video_popover.send_clicked.connect(() => {
                bool should_stop = is_video_recording;
                is_video_recording = false;
                if (video_popover != null) {
                    video_popover.popdown();
                }
                if (should_stop) {
                    stop_video_recording();
                }
            });

            video_popover.cancel_clicked.connect(() => {
                bool should_cancel = is_video_recording;
                is_video_recording = false;
                if (video_popover != null) {
                    video_popover.popdown();
                }
                if (should_cancel) {
                    cancel_video_recording();
                }
            });

            video_popover.closed.connect(() => {
                if (is_video_recording) {
                    is_video_recording = false;
                    cancel_video_recording();
                }
                // Destroy popover so preview poll restarts fresh next time
                VideoRecorderPopover? closed_popover = video_popover;
                video_popover = null;
                if (closed_popover != null && ((!) closed_popover).get_parent() != null) {
                    ((!) closed_popover).unparent();
                }
            });
        }

        video_popover.popup();
        start_video_recording();
    }

    private void start_video_recording() {
        if (!can_send_current()) return;
        try {
            ensure_video_recorder();
            if (video_recording_finalizing || ((!) video_recorder).state.is_busy()) return;
            if (!video_recording_send_context.try_bind((!) conversation)) return;
            string path = Path.build_filename(Environment.get_tmp_dir(),
                "dino_video_%s.mp4".printf(new DateTime.now_local().format("%Y%m%d%H%M%S")));
            debug("ChatInputController.start_video_recording: path=%s", path);
            ((!) video_recorder).start_recording(path);
            is_video_recording = true;
            chat_input.video_record_button.icon_name = "media-record-symbolic";
            chat_input.video_record_button.add_css_class("destructive-action");
        } catch (Error e) {
            warning("Failed to start video recording: %s", e.message);
            video_recording_send_context.clear();
            is_video_recording = false;
            if (video_popover != null) {
                video_popover.popdown();
            }
            show_video_recording_error(e.message);
        }
    }

    private void stop_video_recording() {
        debug("ChatInputController.stop_video_recording: called");
        video_recording_finalizing = true;
        video_recording_finalize_start_us = GLib.get_monotonic_time();
        update_input_status_presentation();
        chat_input.video_record_button.icon_name = "sync-synchronizing-symbolic";
        chat_input.video_record_button.remove_css_class("destructive-action");
        if (video_recorder != null) {
            ((!) video_recorder).stop_recording();
        }
    }

    private void cancel_video_recording() {
        video_recording_send_context.clear();
        video_recording_finalizing = false;
        video_recording_finalize_start_us = 0;
        restore_input_field_status();
        if (video_recorder != null) {
            ((!) video_recorder).cancel_recording();
        }
        chat_input.video_record_button.icon_name = "camera-video-symbolic";
        chat_input.video_record_button.remove_css_class("destructive-action");
    }

    private void ensure_video_recorder() throws Error {
        if (video_recorder != null) return;
        Application? app = GLib.Application.get_default() as Application;
        Dino.Plugins.MediaMessageRecorderProvider? provider =
            app != null ? ((!) app).plugin_registry.media_message_recorder_provider : null;
        if (provider == null) {
            throw new MediaMessageRecorderError.UNSUPPORTED(_("Video recording is not available."));
        }
        if (!((!) provider).video_available) {
            string reason = ((!) provider).video_unavailable_reason ?? _("Video recording is not available.");
            throw new MediaMessageRecorderError.ENCODER_UNAVAILABLE(reason);
        }

        video_recorder = new ProviderVideoMessageRecorderBackend((!) provider);
        ((!) video_recorder).recording_error.connect((msg) => {
            video_recording_send_context.clear();
            is_video_recording = false;
            video_recording_finalizing = false;
            restore_input_field_status();
            chat_input.video_record_button.icon_name = "camera-video-symbolic";
            chat_input.video_record_button.remove_css_class("destructive-action");
            if (video_popover != null) {
                video_popover.popdown();
            }
            show_video_recording_error(msg);
        });
        ((!) video_recorder).recording_stopped.connect(handle_video_recording_stopped);
    }

    private void handle_video_recording_stopped(MediaMessageRecorderOutput? output) {
        Conversation? target_conversation = video_recording_send_context.take();
        string? path = output != null ? ((!) output).path : null;
        debug("ChatInputController: video recording_stopped signal, path=%s", path ?? "(null)");
        if (video_recording_finalize_start_us != 0) {
            int64 elapsed_ms = (GLib.get_monotonic_time() - video_recording_finalize_start_us) / 1000;
            debug("ChatInputController: video recording finalization took %sms", elapsed_ms.to_string());
        }
        video_recording_finalize_start_us = 0;
        video_recording_finalizing = false;
        restore_input_field_status();
        chat_input.video_record_button.icon_name = "camera-video-symbolic";
        chat_input.video_record_button.remove_css_class("destructive-action");
        if (path != null) {
            File f = File.new_for_path((!) path);
            try {
                FileInfo info = f.query_info(FileAttribute.STANDARD_SIZE, FileQueryInfoFlags.NONE);
                debug("ChatInputController: video file size=%s", info.get_size().to_string());
                if (info.get_size() > 0 && target_conversation != null &&
                        can_send_to_conversation((!) target_conversation)) {
                    video_message_recorded((!) path, (!) target_conversation);
                } else {
                    warning("Recorded video file is empty or has no send target, not sending.");
                    FileUtils.unlink((!) path);
                }
            } catch (Error e) {
                warning("Failed to check recorded video file: %s", e.message);
                FileUtils.unlink((!) path);
            }
        }
    }

    private void show_video_recording_error(string message) {
        var root = chat_input.get_root() as Gtk.Window;
        if (root == null) return;
        var dlg = new Adw.AlertDialog(
            _("Video recording failed"),
            message);
        dlg.add_response("ok", _("OK"));
        dlg.present(root);
    }
}

}

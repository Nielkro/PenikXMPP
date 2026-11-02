using Gdk;
using Gee;
using Gtk;

using Dino.Entities;
using Xmpp;
using Dino.Ui.ViewModel;

namespace Dino.Ui.ChatInput {

[GtkTemplate (ui = "/im/dinox/dinox/chat_input.ui")]
public class View : Box {

    public string text {
        owned get { return chat_text_view.get_text(); }
        set { chat_text_view.text_view.buffer.text = Util.sanitize_utf8(value); }
    }

    private StreamInteractor stream_interactor;
    private Conversation? conversation;
    private HashMap<string, Draft> entry_cache = new HashMap<string, Draft>();
    private InputTargetSnapshot? active_target;
    private Dino.Entities.Settings? settings;
    private bool file_upload_active = false;
    private bool send_allowed = false;
    private bool location_request_active = false;

    private class Draft : Object {
        public string text;
        public Gee.List<Xep.MessageMarkup.Span> markups;
        public int cursor;
        public int selection;
        public InputTargetSnapshot target;

        public Draft(ChatTextView input, Conversation conversation) {
            text = input.get_text();
            markups = input.get_markups();
            TextIter iter;
            input.text_view.buffer.get_iter_at_mark(out iter, input.text_view.buffer.get_insert());
            cursor = iter.get_offset();
            input.text_view.buffer.get_iter_at_mark(out iter, input.text_view.buffer.get_selection_bound());
            selection = iter.get_offset();
            target = new InputTargetSnapshot(conversation);
        }
    }

    [GtkChild] public unowned Box quote_box;
    [GtkChild] public unowned AvatarPicture account_avatar;
    [GtkChild] public unowned ChatTextView chat_text_view;
    [GtkChild] public unowned MenuButton file_button;
    [GtkChild] public unowned Button send_file_button;
    [GtkChild] public unowned Button send_location_button;
    [GtkChild] public unowned Popover attachment_popover;
    [GtkChild] public unowned Button record_button;
    [GtkChild] public unowned Button video_record_button;
    [GtkChild] public unowned MenuButton emoji_button;
    [GtkChild] public unowned MenuButton sticker_button;
    [GtkChild] public unowned MenuButton encryption_button;
    [GtkChild] public unowned Button send_button;
    [GtkChild] public unowned Button request_voice_button;
    [GtkChild] public unowned Separator file_separator;
    [GtkChild] public unowned Label chat_input_status;

    public EncryptionButton encryption_widget;
    private StickerChooser? sticker_chooser;

    public View init(StreamInteractor stream_interactor) {
        this.stream_interactor = stream_interactor;

        encryption_widget = new EncryptionButton(stream_interactor, encryption_button);

        EmojiChooser chooser = new EmojiChooser();
        chooser.emoji_picked.connect(on_emoji_picked);
        chooser.closed.connect(do_focus);

        Util.set_menu_button_popover(emoji_button, chooser);

        sticker_button.tooltip_text = Util.string_if_tooltips_active(_("Stickers"));

        // Hide sticker button when stickers are disabled in settings
        settings = Dino.Application.get_default().settings;
        ((!) settings).bind_property("send-on-ctrl-enter", chat_text_view,
            "send-on-ctrl-enter", BindingFlags.SYNC_CREATE);
        ((!) settings).notify["stickers-enabled"].connect(on_stickers_enabled_changed);
        on_stickers_enabled_changed();

        // Hide location button when location sharing is disabled in settings
        ((!) settings).notify["location-sharing-enabled"].connect(on_location_enabled_changed);
        on_location_enabled_changed();

        stream_interactor.account_removed.connect(on_account_removed);
        stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY)
            .conversation_cleared.connect(on_conversation_cleared);

        file_button.tooltip_text = Util.string_if_tooltips_active(_("Attachments"));

        return this;
    }

    private void on_emoji_picked(string emoji) {
        if (!chat_text_view.text_view.editable) return;
        chat_text_view.text_view.buffer.insert_at_cursor(emoji, emoji.length);
    }

    private void on_stickers_enabled_changed() {
        bool enabled = settings != null && ((!) settings).stickers_enabled;
        sticker_button.visible = enabled;
        if (enabled) {
            ensure_sticker_chooser();
            ((!) sticker_chooser).set_conversation(conversation);
            ((!) sticker_chooser).set_send_allowed(send_allowed);
        } else if (sticker_button.active) {
            sticker_button.active = false;
        }
    }

    private void on_location_enabled_changed() {
        send_location_button.visible = settings != null && ((!) settings).location_sharing_enabled;
        update_attachment_availability();
    }

    private void on_sticker_closed() {
        if (sticker_button.active) sticker_button.active = false;
        do_focus();
    }

    private void ensure_sticker_chooser() {
        if (sticker_chooser != null) return;

        sticker_chooser = new StickerChooser(stream_interactor);
        Util.set_menu_button_popover(sticker_button, sticker_chooser);

        // Defensive: keep MenuButton state in sync when the popover is dismissed programmatically
        // (e.g. by selecting a sticker) or by outside clicks.
        sticker_chooser.set_send_allowed(send_allowed);
        sticker_chooser.closed.connect(on_sticker_closed);
    }

    public void set_file_upload_active(bool active) {
        file_upload_active = active;
        update_attachment_availability();
    }

    private void update_attachment_availability() {
        send_file_button.visible = file_upload_active;
        send_file_button.sensitive = file_upload_active && send_allowed;
        bool available = file_upload_active || send_location_button.visible;
        file_button.visible = available;
        file_separator.visible = available;
        send_location_button.sensitive = send_allowed && !location_request_active;
    }

    public void set_location_request_active(bool active) {
        location_request_active = active;
        update_attachment_availability();
    }

    public void set_send_allowed(bool allowed) {
        send_allowed = allowed;
        file_button.sensitive = allowed;
        record_button.sensitive = allowed;
        video_record_button.sensitive = allowed;
        sticker_button.sensitive = allowed;
        send_button.sensitive = allowed && chat_text_view.get_text().strip() != "";
        if (sticker_chooser != null) sticker_chooser.set_send_allowed(allowed);
        if (!allowed) {
            if (file_button.active) file_button.active = false;
            if (sticker_button.active) sticker_button.active = false;
        }
        update_attachment_availability();
    }

    private static string draft_key(Conversation conversation) {
        return "%i:%i:%i:%s".printf(conversation.account.id,
            conversation.id, (int) conversation.type_, conversation.counterpart.to_string());
    }

    private void cache_current_draft() {
        if (conversation == null) return;
        string key = draft_key((!) conversation);
        if (active_target == null || !((!) active_target).matches((!) conversation)) {
            entry_cache.unset(key);
            return;
        }
        var draft = new Draft(chat_text_view, (!) conversation);
        if (draft.text == "") entry_cache.unset(key);
        else entry_cache[key] = draft;
    }

    private void on_account_removed(Account account) {
        var keys = new ArrayList<string>();
        foreach (var entry in entry_cache.entries) {
            if (entry.value.target.account == account) keys.add(entry.key);
        }
        foreach (string key in keys) entry_cache.unset(key);
        if (conversation != null && conversation.account == account) {
            clear_current_draft();
            set_send_allowed(false);
        }
    }

    private void on_conversation_cleared(Conversation cleared) {
        if (cleared.type_ != Conversation.Type.GROUPCHAT_PM) return;
        string key = draft_key(cleared);
        Draft? cached = entry_cache[key];
        if (cached != null && !((!) cached).target.matches(cleared)) entry_cache.unset(key);
        if (conversation == cleared && active_target != null &&
                !((!) active_target).matches(cleared)) clear_current_draft();
    }

    public void clear_current_draft() {
        if (conversation != null) {
            entry_cache.unset(draft_key((!) conversation));
            active_target = new InputTargetSnapshot((!) conversation);
        }
        chat_text_view.text_view.buffer.text = "";
    }

    public void initialize_for_conversation(Conversation conversation) {
        int64 t0_us = Dino.Ui.UiTiming.now_us();
        chat_text_view.reset_context_menu();

        int64 t_cache_prev_us = Dino.Ui.UiTiming.now_us();
        cache_current_draft();
        Dino.Ui.UiTiming.log_ms("ChatInput.View.initialize_for_conversation: cache_prev", t_cache_prev_us);

        int64 t_set_conv_us = Dino.Ui.UiTiming.now_us();
        this.conversation = conversation;
        active_target = new InputTargetSnapshot(conversation);
        if (file_button.active) file_button.active = false;
        if (emoji_button.active) emoji_button.active = false;
        if (sticker_button.active) sticker_button.active = false;
        if (encryption_button.active) encryption_button.active = false;
        Dino.Ui.UiTiming.log_ms("ChatInput.View.initialize_for_conversation: set_conversation", t_set_conv_us);

        int64 t_clear_us = Dino.Ui.UiTiming.now_us();
        chat_text_view.text_view.buffer.text = "";
        Dino.Ui.UiTiming.log_ms("ChatInput.View.initialize_for_conversation: clear_buffer", t_clear_us);

        int64 t_restore_us = Dino.Ui.UiTiming.now_us();
        string key = draft_key(conversation);
        Draft? draft = entry_cache[key];
        if (draft != null) {
            if (((!) draft).target.matches(conversation)) {
                chat_text_view.restore_draft(((!) draft).text, ((!) draft).markups,
                    ((!) draft).cursor, ((!) draft).selection);
            } else {
                entry_cache.unset(key);
            }
        }
        Dino.Ui.UiTiming.log_ms("ChatInput.View.initialize_for_conversation: restore_draft", t_restore_us);

        int64 t_focus_us = Dino.Ui.UiTiming.now_us();
        do_focus();
        Dino.Ui.UiTiming.log_ms("ChatInput.View.initialize_for_conversation: focus", t_focus_us);

        int64 t_sticker_us = Dino.Ui.UiTiming.now_us();
        if (sticker_chooser != null) {
            sticker_chooser.set_conversation(conversation);
        }
        var self_conv = new Conversation(conversation.account.bare_jid, conversation.account, Conversation.Type.CHAT);
        account_avatar.model = new ViewModel.CompatAvatarPictureModel(stream_interactor).set_conversation(self_conv);
        Dino.Ui.UiTiming.log_ms("ChatInput.View.initialize_for_conversation: sticker_chooser", t_sticker_us);

        Dino.Ui.UiTiming.log_ms("ChatInput.View.initialize_for_conversation: total", t0_us);
    }

    public void unset_conversation() {
        chat_text_view.reset_context_menu();
        cache_current_draft();
        this.conversation = null;
        active_target = null;
        if (file_button.active) file_button.active = false;
        if (emoji_button.active) emoji_button.active = false;
        if (sticker_button.active) sticker_button.active = false;
        if (encryption_button.active) encryption_button.active = false;
        chat_text_view.text_view.buffer.text = "";
        if (sticker_chooser != null) {
            sticker_chooser.set_conversation(null);
        }
    }

    public void set_input_state(Plugins.InputFieldStatus.MessageType message_type) {
        switch (message_type) {
            case Plugins.InputFieldStatus.MessageType.NONE:
                this.remove_css_class("dino-input-warning");
                this.remove_css_class("dino-input-error");
                break;
            case Plugins.InputFieldStatus.MessageType.INFO:
                this.remove_css_class("dino-input-warning");
                this.remove_css_class("dino-input-error");
                break;
            case Plugins.InputFieldStatus.MessageType.WARNING:
                this.add_css_class("dino-input-warning");
                this.remove_css_class("dino-input-error");
                break;
            case Plugins.InputFieldStatus.MessageType.ERROR:
                this.remove_css_class("dino-input-warning");
                this.add_css_class("dino-input-error");
                break;
        }
    }

    public void highlight_state_description() {
        chat_input_status.add_css_class("input-status-highlight-once");
        Timeout.add(500, () => {
            if (!this.get_realized()) return false;
            chat_input_status.remove_css_class("input-status-highlight-once");
            return false;
        });
    }

    public void set_quoted_message(Widget quote_widget) {
        Widget? quote_box_child = quote_box.get_first_child();
        if (quote_box_child != null) quote_box.remove(quote_box_child);
        quote_box.append(quote_widget);
        quote_box.visible = true;
    }

    public void unset_quoted_message() {
        Widget? quote_box_child = quote_box.get_first_child();
        if (quote_box_child != null) quote_box.remove(quote_box_child);
        quote_box.visible = false;
    }

    public void do_focus() {
        chat_text_view.text_view.grab_focus();
    }
}

}

/*
 * Copyright (C) 2025 Ralf Peter <dinox@handwerker.jetzt>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

using Gtk;
using Gee;

using Dino.Entities;

namespace Dino.Ui {

public class EncryptionButton : Object {

    public signal void encryption_changed(Encryption encryption);

    private MenuButton menu_button;
    private Image status_icon;
    private PopoverMenu popover_menu;
    private Menu menu_model;
    private HashMap<Encryption, Choice> choices = new HashMap<Encryption, Choice>();
    private Conversation? conversation;
    private StreamInteractor stream_interactor;
    private SimpleAction action;
    private Plugins.Registry registry;
    private MucManager muc_manager;
    private bool suppress_encryption_notify_signal = false;
    private bool room_info_refresh_covered_by_encryption_notify = false;
    private uint room_info_refresh_reset_source = 0;
    private uint trust_refresh_source = 0;
    private bool disposed = false;
    ulong conversation_encryption_handler_id = -1;

    private class Choice : Object {
        public Encryption encryption;
        public string name;
        public MenuItem item;
        public int index;
        public CheckButton? button;
        public Image? icon;
        public Label? status;

        public Choice(Encryption encryption, string name, MenuItem item, int index) {
            this.encryption = encryption;
            this.name = name;
            this.item = item;
            this.index = index;
        }
    }

    public EncryptionButton(StreamInteractor stream_interactor, MenuButton menu_button) {
        this.stream_interactor = stream_interactor;
        this.menu_button = menu_button;
        status_icon = new Image.from_icon_name("changes-allow-symbolic");
        menu_button.child = status_icon;

        // Build menu model including "Unencrypted" and all registered encryption entries
        menu_model = new Menu();
        add_choice(menu_model, Encryption.NONE, _("Unencrypted"));

        var encryption_entries = new ArrayList<Plugins.EncryptionListEntry>();
        Dino.Application app = Dino.Application.get_default();
        registry = app.plugin_registry;
        encryption_entries.add_all(registry.encryption_list_entries.values);
        encryption_entries.sort((a,b) => b.name.collate(a.name));
        foreach (var e in encryption_entries) {
            add_choice(menu_model, e.encryption, e.name.make_valid());
        }
        registry.encryption_readiness_changed.connect(on_encryption_readiness_changed);
        registry.encryption_trust_changed.connect(on_encryption_trust_changed);

        // Create action to act on menu selections (stateful => radio buttons)
        SimpleActionGroup action_group = new SimpleActionGroup();
        action = new SimpleAction.stateful("encryption", VariantType.INT32, new Variant.int32(Encryption.NONE));
        action.activate.connect(on_action_activated);
        action_group.add_action(action);
        menu_button.insert_action_group("enc", action_group);

        // Create and set popover menu
        popover_menu = new Gtk.PopoverMenu.from_model(menu_model);
#if GTK_4_8
        CheckButton? first = null;
        foreach (Choice choice in choices.values) {
            var row = new CheckButton() {
                action_target = new Variant.int32(choice.encryption), action_name = "enc.encryption",
                margin_start = 6, margin_end = 6, margin_top = 4, margin_bottom = 4
            };
            if (first == null) first = row;
            else row.group = first;
            var content = new Box(Orientation.HORIZONTAL, 8);
            var icon = new Image() { pixel_size = 16 };
            var captions = new Box(Orientation.VERTICAL, 2) { hexpand = true };
            captions.append(new Label(choice.name) {
                xalign = 0, use_markup = false, hexpand = true,
                ellipsize = Pango.EllipsizeMode.END, width_chars = 1, max_width_chars = 28
            });
            var status = new Label("") {
                xalign = 0, use_markup = false, wrap = true, wrap_mode = Pango.WrapMode.WORD_CHAR,
                lines = 2, ellipsize = Pango.EllipsizeMode.END, max_width_chars = 28
            };
            status.add_css_class("dim-label");
            captions.append(status);
            content.append(icon);
            content.append(captions);
            row.child = content;
            popover_menu.add_child(row, choice_slot(choice.encryption));
            choice.button = row;
            choice.icon = icon;
            choice.status = status;
        }
#endif
        Util.set_menu_button_popover(menu_button, popover_menu);
        menu_button.notify["active"].connect(on_menu_active_changed);

        muc_manager = stream_interactor.get_module<MucManager>(MucManager.IDENTITY);
        muc_manager.room_info_updated.connect(on_room_info_updated);
        muc_manager.room_info_query_failed.connect(on_room_info_query_failed);
        muc_manager.private_muc_affiliation_snapshot_changed.connect(on_affiliation_snapshot_changed);
        muc_manager.joined.connect(on_room_joined);
        muc_manager.left_signal.connect(on_room_left);
        stream_interactor.connection_manager.connection_state_changed.connect(on_connection_state_changed);
        update_encryption_menu_icon();
    }

    private static string choice_slot(Encryption encryption) {
        return "encryption-choice-%d".printf((int) encryption);
    }

    private void add_choice(Menu menu, Encryption encryption, string name) {
        var item = new MenuItem(name, "enc.encryption");
        item.set_action_and_target_value("enc.encryption", new Variant.int32(encryption));
#if GTK_4_8
        item.set_attribute_value("custom", new Variant.string(choice_slot(encryption)));
#endif
        int index = menu.get_n_items();
        menu.append_item(item);
        choices[encryption] = new Choice(encryption, name, item, index);
    }

    private static string trust_label(Plugins.ConversationEncryptionTrust trust) {
        switch (trust) {
            case Plugins.ConversationEncryptionTrust.VERIFIED: return _("Verified");
            case Plugins.ConversationEncryptionTrust.TRUSTED: return _("Trusted");
            case Plugins.ConversationEncryptionTrust.NEEDS_ATTENTION: return _("Check keys");
            default: return _("Unknown");
        }
    }

    private static void style_status_icon(Image image, Encryption encryption,
            Plugins.ConversationEncryptionTrust trust) {
        foreach (string name in new string[] { "success", "accent", "warning", "dim-label" }) {
            image.remove_css_class(name);
        }
        string style = "dim-label";
        if (encryption != Encryption.NONE) {
            switch (trust) {
                case Plugins.ConversationEncryptionTrust.VERIFIED: style = "success"; break;
                case Plugins.ConversationEncryptionTrust.TRUSTED: style = "accent"; break;
                case Plugins.ConversationEncryptionTrust.NEEDS_ATTENTION: style = "warning"; break;
                default: break;
            }
        }
        image.add_css_class(style);
        image.icon_name = encryption == Encryption.NONE ? "changes-allow-symbolic" :
            trust == Plugins.ConversationEncryptionTrust.VERIFIED ? "dino-shield-check-symbolic" : "changes-prevent-symbolic";
    }

    private Plugins.ConversationEncryptionTrust cached_trust(Encryption encryption) {
        if (conversation == null || encryption == Encryption.NONE) return Plugins.ConversationEncryptionTrust.UNKNOWN;
        var entry = registry.encryption_list_entries[encryption];
        return entry != null ? entry.get_conversation_trust(conversation) : Plugins.ConversationEncryptionTrust.UNKNOWN;
    }

    private string status_description(Encryption encryption, Plugins.ConversationEncryptionTrust trust) {
        if (encryption == Encryption.NONE) return "%s · %s".printf(_("Encryption"), _("Unencrypted"));
        var entry = registry.encryption_list_entries[encryption];
        string description = "%s · %s · %s".printf(_("Encryption"), entry != null ? entry.name.make_valid() : _("Unknown"), trust_label(trust));
        return trust == Plugins.ConversationEncryptionTrust.VERIFIED
            ? "%s\n%s".printf(description, _("Locally known active keys are verified. Open encryption details to review them."))
            : description;
    }

    private void refresh_choices() {
        foreach (Choice choice in choices.values) {
            var trust = cached_trust(choice.encryption);
            string description = status_description(choice.encryption, trust);
            if (choice.button != null) {
                choice.button.update_property(AccessibleProperty.LABEL, description, -1);
                style_status_icon(choice.icon, choice.encryption, trust);
                choice.status.label = trust_label(trust);
                choice.status.visible = choice.encryption != Encryption.NONE;
            } else {
                // Older GTK keeps its generated radio rows and full status text.
                string label = choice.encryption == Encryption.NONE ? choice.name :
                    "%s · %s".printf(choice.name, trust_label(trust));
                if (choice.item.get_attribute_value(Menu.ATTRIBUTE_LABEL, VariantType.STRING).get_string() != label) {
                    choice.item.set_label(label);
                    menu_model.remove(choice.index);
                    menu_model.insert_item(choice.index, choice.item);
                }
            }
        }
    }

    private void on_menu_active_changed() {
        if (menu_button.active && !disposed) {
            update_encryption_menu_icon();
        }
    }

    private void on_encryption_trust_changed(Encryption encryption, Account account, Xmpp.Jid? changed_jid) {
        if (conversation == null || conversation.account.id != account.id ||
                !conversation.account.bare_jid.equals_bare(account.bare_jid)) return;
        if (changed_jid != null && conversation.type_ != Conversation.Type.GROUPCHAT &&
                !conversation.counterpart.equals_bare(changed_jid) &&
                !(encryption == Encryption.OMEMO && account.bare_jid.equals_bare(changed_jid))) return;
        if (conversation.encryption == encryption || menu_button.active) queue_trust_refresh();
    }

    private void queue_trust_refresh() {
        if (disposed || conversation == null || trust_refresh_source != 0) return;
        trust_refresh_source = add_trust_refresh(this);
    }

    private static uint add_trust_refresh(EncryptionButton owner) {
        WeakRef owner_weak = WeakRef(owner);
        return Idle.add(() => {
            var current = owner_weak.get() as EncryptionButton;
            if (current != null) {
                current.trust_refresh_source = 0;
                if (!current.disposed) current.update_encryption_menu_icon();
            }
            return Source.REMOVE;
        });
    }

    private void cancel_trust_refresh() {
        if (trust_refresh_source != 0) {
            Source.remove(trust_refresh_source);
            trust_refresh_source = 0;
        }
    }

    private void on_room_left(Account account, Xmpp.Jid room) {
        if (conversation != null && conversation.type_ == Conversation.Type.GROUPCHAT &&
                conversation.account.id == account.id && conversation.counterpart.equals_bare(room)) queue_trust_refresh();
    }

    private void on_connection_state_changed(Account account, ConnectionManager.ConnectionState state) {
        if (conversation != null && conversation.type_ == Conversation.Type.GROUPCHAT &&
                conversation.account.id == account.id) queue_trust_refresh();
    }

    private void on_encryption_readiness_changed(Encryption encryption,
            Account account, Xmpp.Jid counterpart) {
        if (conversation != null &&
                conversation.type_ == Conversation.Type.GROUPCHAT &&
                conversation.encryption == encryption &&
                conversation.account.equals(account) &&
                conversation.counterpart.equals_bare(counterpart)) {
            encryption_changed(encryption);
        }
    }

    private void on_action_activated(Variant? parameter) {
        if (parameter == null || conversation == null) return;
        debug("EncryptionButton: Setting encryption to %d for %s",
            ((!) parameter).get_int32(), conversation.counterpart.to_string());
        action.set_state((!) parameter);
        suppress_encryption_notify_signal = true;
        conversation.encryption = (Encryption) ((!) parameter).get_int32();
        suppress_encryption_notify_signal = false;
        update_encryption_menu_state();
        update_encryption_menu_icon();
        close_menu();
        encryption_changed(conversation.encryption);
    }

    private void close_menu() {
        // Clear popup focus before hiding it. GTK 4.14 otherwise retains the
        // hidden native as previous focus until AFTER_PAINT; hiding the
        // composer in the same turn can supersede that pending focus move.
        Util.clear_focus_before_detach(popover_menu);
        menu_button.active = false;
    }

    private void on_room_info_updated(Account account, Xmpp.Jid muc_jid) {
        if (conversation != null && conversation.account.equals(account) &&
                conversation.counterpart.equals(muc_jid)) {
            if (!consume_room_info_refresh_covered_by_encryption_notify()) {
                refresh_private_room_encryption_readiness();
            }
            update_visibility();
            queue_trust_refresh();
        }
    }

    private void on_room_info_query_failed(Account account, Xmpp.Jid muc_jid) {
        if (conversation != null &&
                conversation.type_ == Conversation.Type.GROUPCHAT &&
                conversation.account.equals(account) &&
                conversation.counterpart.equals_bare(muc_jid) &&
                conversation.encryption != Encryption.NONE) {
            // ROOM_INFO_PENDING keeps the composer closed. A terminal
            // failure replaces that status; the retained failure marker
            // prevents this recheck from starting a retry loop.
            encryption_changed(conversation.encryption);
        }
    }

    private void on_affiliation_snapshot_changed(Account account,
            Xmpp.Jid muc_jid, uint revision) {
        if (conversation != null && conversation.type_ == Conversation.Type.GROUPCHAT &&
                conversation.account.id == account.id && conversation.counterpart.equals_bare(muc_jid)) {
            queue_trust_refresh();
        }
        if (conversation != null &&
                conversation.type_ == Conversation.Type.GROUPCHAT &&
                conversation.account.equals(account) &&
                conversation.counterpart.equals_bare(muc_jid) &&
                conversation.encryption != Encryption.NONE) {
            // The authoritative member set deduplicates this signal.
            // A membership delta retries earlier unsupported/no-member states.
            encryption_changed(conversation.encryption);
        }
    }

    private void on_room_joined(Account account, Xmpp.Jid muc_jid) {
        if (conversation != null && conversation.type_ == Conversation.Type.GROUPCHAT &&
                conversation.account.id == account.id && conversation.counterpart.equals_bare(muc_jid)) {
            queue_trust_refresh();
        }
        if (conversation != null &&
                conversation.type_ == Conversation.Type.GROUPCHAT &&
                conversation.account.equals(account) &&
                conversation.counterpart.equals_bare(muc_jid) &&
                joined_room_requires_encryption_refresh(
                    muc_manager.has_live_private_room_features(account, muc_jid),
                    conversation.encryption)) {
            // If room-info is still in flight, its own result restarts the
            // readiness check without racing a second discovery request.
            encryption_changed(conversation.encryption);
        }
    }

    private void on_conversation_encryption_changed(Object source, ParamSpec property) {
        if (conversation == null || source != conversation) return;
        update_encryption_menu_state();
        update_encryption_menu_icon();
        if (!suppress_encryption_notify_signal) {
            mark_room_info_refresh_covered_by_encryption_notify();
            encryption_changed(conversation.encryption);
        }
    }

    public override void dispose() {
        if (disposed) { base.dispose(); return; }
        disposed = true;
        unset_conversation();
        registry.encryption_readiness_changed.disconnect(on_encryption_readiness_changed);
        registry.encryption_trust_changed.disconnect(on_encryption_trust_changed);
        muc_manager.room_info_updated.disconnect(on_room_info_updated);
        muc_manager.room_info_query_failed.disconnect(on_room_info_query_failed);
        muc_manager.private_muc_affiliation_snapshot_changed.disconnect(on_affiliation_snapshot_changed);
        muc_manager.joined.disconnect(on_room_joined);
        muc_manager.left_signal.disconnect(on_room_left);
        stream_interactor.connection_manager.connection_state_changed.disconnect(on_connection_state_changed);
        menu_button.notify["active"].disconnect(on_menu_active_changed);
        action.activate.disconnect(on_action_activated);
#if GTK_4_8
        foreach (Choice choice in choices.values) {
            if (choice.button == null) continue;
            choice.button.action_name = null;
            choice.button.set_group(null);
            popover_menu.remove_child(choice.button);
        }
#endif
        popover_menu.set_menu_model(null);
        menu_button.insert_action_group("enc", null);
        Util.set_menu_button_popover(menu_button, null);
        choices.clear();
        base.dispose();
    }

    // ConversationManager owns private/public encryption transitions. The UI
    // only restarts the active plugin's readiness check after authoritative
    // private-room information changed.
    private void refresh_private_room_encryption_readiness() {
        if (conversation == null) return;
        if (conversation.type_ != Conversation.Type.GROUPCHAT) return;

        bool is_private = stream_interactor.get_module<MucManager>(MucManager.IDENTITY).is_private_room(
            conversation.account, conversation.counterpart);

        if (private_room_info_requires_encryption_refresh(is_private,
                conversation.encryption)) {
            // A private-to-private configuration readback starts a new
            // authoritative affiliation snapshot. Re-run the active plugin's
            // readiness check so the composer remains blocked until the new
            // recipient set and keys have been verified.
            encryption_changed(conversation.encryption);
        }
    }

    // ConversationManager handles room_info_updated before this UI callback.
    // If that authoritative update changed the encryption property, its notify
    // handler already started the readiness check. Consume that synchronous
    // duplicate without delaying the first check or suppressing a later join
    // or affiliation lifecycle recheck.
    private void mark_room_info_refresh_covered_by_encryption_notify() {
        room_info_refresh_covered_by_encryption_notify = true;
        if (room_info_refresh_reset_source != 0) {
            Source.remove(room_info_refresh_reset_source);
        }
        WeakRef self_weak = WeakRef(this);
        room_info_refresh_reset_source = Idle.add(() => {
            EncryptionButton? button = (EncryptionButton?) self_weak.get();
            if (button != null) {
                ((!) button).room_info_refresh_reset_source = 0;
                ((!) button).room_info_refresh_covered_by_encryption_notify = false;
            }
            return Source.REMOVE;
        });
    }

    private bool consume_room_info_refresh_covered_by_encryption_notify() {
        if (!room_info_refresh_covered_by_encryption_notify) return false;

        room_info_refresh_covered_by_encryption_notify = false;
        if (room_info_refresh_reset_source != 0) {
            Source.remove(room_info_refresh_reset_source);
            room_info_refresh_reset_source = 0;
        }
        return true;
    }

    private void clear_room_info_refresh_coverage() {
        room_info_refresh_covered_by_encryption_notify = false;
        if (room_info_refresh_reset_source != 0) {
            Source.remove(room_info_refresh_reset_source);
            room_info_refresh_reset_source = 0;
        }
    }

    private void update_encryption_menu_state() {
        if (conversation == null) return;
        action.set_state(new Variant.int32(conversation.encryption));
    }

    private void update_encryption_menu_icon() {
        Encryption encryption = conversation != null ? conversation.encryption : Encryption.NONE;
        var trust = cached_trust(encryption);
        style_status_icon(status_icon, encryption, trust);
        string description = conversation != null ? status_description(encryption, trust) : _("Encryption");
        menu_button.tooltip_text = conversation != null ? description : null;
        menu_button.update_property(AccessibleProperty.LABEL, description, -1);
        if (menu_button.active) refresh_choices();
    }

    private void update_visibility() {
        if (conversation == null) {
            menu_button.visible = false;
            return;
        }
        if (conversation.encryption != Encryption.NONE) {
            menu_button.visible = true;
            return;
        }
        switch (conversation.type_) {
            case Conversation.Type.CHAT:
                menu_button.visible = true;
                break;
            case Conversation.Type.GROUPCHAT_PM:
                menu_button.visible = false;
                break;
            case Conversation.Type.GROUPCHAT:
                menu_button.visible = stream_interactor.get_module<MucManager>(MucManager.IDENTITY).is_private_room(conversation.account, conversation.counterpart);
                break;
        }
    }

    public void set_conversation(Conversation conversation) {
        debug("EncryptionButton.set_conversation: Called with %s", conversation != null ? conversation.counterpart.to_string() : "NULL");
        clear_room_info_refresh_coverage();
        cancel_trust_refresh();
        close_menu();
        if (conversation_encryption_handler_id != -1 && this.conversation != null) {
            this.conversation.disconnect(conversation_encryption_handler_id);
            conversation_encryption_handler_id = -1;
        }

        this.conversation = conversation;
        debug("EncryptionButton.set_conversation: this.conversation is now %s", this.conversation != null ? "SET" : "NULL");
        update_encryption_menu_state();
        update_encryption_menu_icon();
        update_visibility();
        encryption_changed(this.conversation.encryption);

        conversation_encryption_handler_id = conversation.notify["encryption"].connect(
            on_conversation_encryption_changed);
    }

    public void unset_conversation() {
        clear_room_info_refresh_coverage();
        cancel_trust_refresh();
        close_menu();
        if (conversation_encryption_handler_id != -1 && this.conversation != null) {
            this.conversation.disconnect(conversation_encryption_handler_id);
            conversation_encryption_handler_id = -1;
        }
        this.conversation = null;
        action.set_state(new Variant.int32(Encryption.NONE));
        update_encryption_menu_icon();
        update_visibility();
    }
}

}

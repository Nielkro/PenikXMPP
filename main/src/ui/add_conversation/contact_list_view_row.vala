using Gee;
using Gtk;

using Dino.Entities;
using Xmpp;

namespace Dino.Ui {

/**
 * Reusable row for the contact-only Gtk.ListView.
 *
 * Expensive observers deliberately live only while Gtk has this factory row
 * bound to a visible ContactListItem. The model itself stays widget-free.
 */
internal class ContactListViewRow : Object {

    private Box outer_box;
    private AvatarPicture picture;
    private Label name_label;
    private Image status_dot;
    private Label via_label;

    private StreamInteractor? stream_interactor = null;
    private ViewModel.ContactListItem? item = null;
    private PresenceObserver? presence_observer = null;
    private AvatarObserver? avatar_observer = null;
    private ViewModel.CompatAvatarPictureModel? avatar_model = null;
    private CallbackBridge? callbacks = null;
    private ulong display_name_handler_id = 0;
    private bool show_account_hint = false;
    private bool show_jid_with_account_hint = false;

    private class CallbackBridge : Object {
        private WeakRef owner_ref;

        public CallbackBridge(ContactListViewRow owner) {
            owner_ref = WeakRef(owner);
        }

        public void display_name_changed() {
            ContactListViewRow? owner = (ContactListViewRow?) owner_ref.get();
            if (owner != null) ((!) owner).refresh_labels_and_avatar();
        }

        public bool presence_changed(Jid jid, Account account, bool available) {
            ContactListViewRow? owner = (ContactListViewRow?) owner_ref.get();
            if (owner == null) return false;
            ((!) owner).refresh_presence();
            return true;
        }

        public bool avatar_changed(Jid jid, Account account) {
            ContactListViewRow? owner = (ContactListViewRow?) owner_ref.get();
            if (owner == null) return false;
            ((!) owner).refresh_avatar();
            return true;
        }

        public void clear() {
            owner_ref.set(null);
        }
    }

    construct {
        Builder builder = new Builder.from_resource("/im/dinox/dinox/add_conversation/list_row.ui");
        outer_box = (Box) builder.get_object("outer_box");
        picture = (AvatarPicture) builder.get_object("picture");
        name_label = (Label) builder.get_object("name_label");
        status_dot = (Image) builder.get_object("status_dot");
        via_label = (Label) builder.get_object("via_label");
        Image private_room_image = (Image) builder.get_object("private_room_image");
        private_room_image.visible = false;
    }

    public Widget get_widget() {
        return outer_box;
    }

    public void bind(StreamInteractor stream_interactor, ViewModel.ContactListItem item,
            bool show_account_hint, bool show_jid_with_account_hint = false) {
        unbind();
        this.stream_interactor = stream_interactor;
        this.item = item;
        this.show_account_hint = show_account_hint;
        this.show_jid_with_account_hint = show_jid_with_account_hint;
        CallbackBridge bridge = new CallbackBridge(this);
        callbacks = bridge;
        display_name_handler_id = item.notify["display-name"].connect(bridge.display_name_changed);

        PresenceManager? presence_manager = stream_interactor.get_module<PresenceManager>(PresenceManager.IDENTITY);
        if (presence_manager != null) {
            presence_observer = ((!) presence_manager).observe_presence(
                item.account, item.jid, bridge.presence_changed);
        }

        AvatarManager? avatar_manager = stream_interactor.get_module<AvatarManager>(AvatarManager.IDENTITY);
        if (avatar_manager != null) {
            avatar_observer = ((!) avatar_manager).observe_avatar(
                item.account, item.jid, bridge.avatar_changed);
        }

        refresh_labels_and_avatar();
        refresh_presence();
    }

    public void unbind() {
        if (presence_observer != null) {
            ((!) presence_observer).unsubscribe();
            presence_observer = null;
        }
        if (avatar_observer != null) {
            ((!) avatar_observer).unsubscribe();
            avatar_observer = null;
        }
        if (item != null && display_name_handler_id != 0 &&
                SignalHandler.is_connected((!) item, display_name_handler_id)) {
            SignalHandler.disconnect((!) item, display_name_handler_id);
        }
        display_name_handler_id = 0;
        if (callbacks != null) {
            ((!) callbacks).clear();
            callbacks = null;
        }
        clear_avatar_model();
        item = null;
        stream_interactor = null;
        show_account_hint = false;
        show_jid_with_account_hint = false;
        outer_box.tooltip_text = null;
        name_label.tooltip_text = null;
        via_label.label = "";
        via_label.visible = false;
        status_dot.visible = false;
    }

    public void cleanup() {
        unbind();
    }

    public void set_show_account_hint(bool show_account_hint) {
        if (this.show_account_hint == show_account_hint) return;
        this.show_account_hint = show_account_hint;
        refresh_labels();
    }

    ~ContactListViewRow() {
        cleanup();
    }

    private void refresh_labels_and_avatar() {
        refresh_labels();
        refresh_avatar();
    }

    private void refresh_labels() {
        if (item == null) return;
        ViewModel.ContactListItem bound_item = (!) item;
        string display_name = bound_item.display_name.make_valid();
        string bare_jid = bound_item.jid.to_string().make_valid();
        name_label.label = display_name;
        name_label.tooltip_text = display_name;

        if (show_account_hint) {
            string via = _("via %s").printf(bound_item.account.bare_jid.to_string());
            via_label.label = Util.sanitize_utf8(show_jid_with_account_hint
                ? "%s\n%s".printf(bare_jid, via)
                : via);
            via_label.visible = true;
        } else if (display_name != bare_jid) {
            via_label.label = bare_jid;
            via_label.visible = true;
        } else {
            via_label.label = "";
            via_label.visible = false;
        }
        outer_box.tooltip_text = Util.use_tooltips() ? bare_jid : null;
    }

    private void refresh_avatar() {
        if (item == null || stream_interactor == null) return;
        ViewModel.ContactListItem bound_item = (!) item;
        AvatarManager? avatar_manager = ((!) stream_interactor).get_module<AvatarManager>(AvatarManager.IDENTITY);
        Bytes? image_bytes = avatar_manager != null
            ? ((!) avatar_manager).get_avatar_bytes_with_policy(
                bound_item.account, bound_item.jid, Dino.AvatarReadPolicy.LOCAL_CACHE_ONLY)
            : null;
        clear_avatar_model();
        avatar_model = new ViewModel.CompatAvatarPictureModel(null).add(
            bound_item.display_name, bound_item.jid.to_string(), image_bytes);
        picture.model = avatar_model;
    }

    private void clear_avatar_model() {
        if (avatar_model != null) {
            ((!) avatar_model).cleanup();
            avatar_model = null;
        }
        picture.model = null;
    }

    private void refresh_presence() {
        if (item == null || stream_interactor == null) return;
        ViewModel.ContactListItem bound_item = (!) item;
        StreamInteractor interactor = (!) stream_interactor;
        status_dot.visible = interactor.connection_manager.get_state(bound_item.account) ==
            ConnectionManager.ConnectionState.CONNECTED;

        PresenceManager? presence_manager = interactor.get_module<PresenceManager>(PresenceManager.IDENTITY);
        if (presence_manager == null) {
            status_dot.set_from_icon_name("dino-status-offline");
            return;
        }

        Gee.List<Jid>? full_jids = ((!) presence_manager).get_full_jids(bound_item.jid, bound_item.account);
        var statuses = new HashSet<string>();
        if (full_jids != null) {
            foreach (Jid full_jid in (!) full_jids) {
                statuses.add(((!) presence_manager).get_last_show(full_jid, bound_item.account));
            }
        }

        if (statuses.contains(Xmpp.Presence.Stanza.SHOW_DND)) {
            status_dot.set_from_icon_name("dino-status-dnd");
        } else if (statuses.contains(Xmpp.Presence.Stanza.SHOW_CHAT)) {
            status_dot.set_from_icon_name("dino-status-chat");
        } else if (statuses.contains(Xmpp.Presence.Stanza.SHOW_ONLINE)) {
            status_dot.set_from_icon_name("dino-status-online");
        } else if (statuses.contains(Xmpp.Presence.Stanza.SHOW_AWAY) ||
                statuses.contains(Xmpp.Presence.Stanza.SHOW_XA)) {
            status_dot.set_from_icon_name("dino-status-away");
        } else {
            status_dot.set_from_icon_name("dino-status-offline");
        }
    }
}

}

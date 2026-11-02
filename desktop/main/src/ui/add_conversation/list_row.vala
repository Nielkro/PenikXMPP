using Gee;
using Gtk;

using Dino.Entities;
using Xmpp;

namespace Dino.Ui {

public class ListRow : Widget {

    public Box outer_box;
    public AvatarPicture picture;
    public Label name_label;
    public Image status_dot;
    public Label via_label;
    public Image private_room_image;

    public StreamInteractor stream_interactor;
    public Jid jid;
    public Account account;

    private bool disposed = false;
    private bool show_account_hint = false;
    private string? initial_display_name;
    private uint hydrate_source_id = 0;
    private uint avatar_generation = 0;
    private bool hydrated = false;
    private PresenceManager? presence_manager = null;
    private PresenceObserver? presence_observer = null;
    private AvatarManager? avatar_manager = null;

    public bool is_disposed {
        get { return disposed; }
    }

    construct {
        Builder builder = new Builder.from_resource("/im/dinox/dinox/add_conversation/list_row.ui");
        outer_box = (Box) builder.get_object("outer_box");
        picture = (AvatarPicture) builder.get_object("picture");
        name_label = (Label) builder.get_object("name_label");
        status_dot = (Image) builder.get_object("status_dot");
        via_label = (Label) builder.get_object("via_label");
        private_room_image = (Image) builder.get_object("private_room_image");


        this.layout_manager = new BinLayout();
        outer_box.set_parent(this);
    }

    private void set_status_dot(StreamInteractor stream_interactor){
        status_dot.visible = stream_interactor.connection_manager.get_state(account) == ConnectionManager.ConnectionState.CONNECTED;

        PresenceManager? presence_manager = stream_interactor.get_module<PresenceManager>(PresenceManager.IDENTITY);
        if (presence_manager == null) {
            status_dot.set_from_icon_name("dino-status-offline");
            return;
        }

        Gee.List<Jid>? full_jids = presence_manager.get_full_jids(jid, account);
        if (full_jids != null) {
            var statuses = new ArrayList<string>();
            foreach (var full_jid in full_jids) {
                statuses.add(presence_manager.get_last_show(full_jid, account));
            }

            if (statuses.contains(Xmpp.Presence.Stanza.SHOW_DND)) status_dot.set_from_icon_name("dino-status-dnd");
            else if (statuses.contains(Xmpp.Presence.Stanza.SHOW_CHAT)) status_dot.set_from_icon_name("dino-status-chat");
            else if (statuses.contains(Xmpp.Presence.Stanza.SHOW_ONLINE)) status_dot.set_from_icon_name("dino-status-online");
            else if (statuses.contains(Xmpp.Presence.Stanza.SHOW_AWAY)) status_dot.set_from_icon_name("dino-status-away");
            else if (statuses.contains(Xmpp.Presence.Stanza.SHOW_XA)) status_dot.set_from_icon_name("dino-status-away");
            else status_dot.set_from_icon_name("dino-status-offline");
        } else {
            status_dot.set_from_icon_name("dino-status-offline");
        }
    }

    public ListRow.from_jid(StreamInteractor stream_interactor, Jid jid, Account account, bool show_account, string? initial_display_name = null, bool auto_hydrate = true) {
        this.stream_interactor = stream_interactor;
        this.jid = jid;
        this.account = account;
        show_account_hint = show_account;
        this.initial_display_name = initial_display_name;

        string safe_initial_display_name = Util.sanitize_utf8(initial_display_name);
        string safe_bare_jid = Util.sanitize_utf8(jid.bare_jid.to_string());
        string? resolved_name = safe_initial_display_name.strip() != "" ? safe_initial_display_name : null;
        string placeholder = resolved_name != null ? (!) resolved_name : safe_bare_jid;
        if (show_account && stream_interactor.get_accounts().size > 1) {
            via_label.label = Util.sanitize_utf8(_("via %s").printf(account.bare_jid.to_string()));
            this.has_tooltip = Util.use_tooltips();
            set_tooltip_text(Util.sanitize_utf8(Util.string_if_tooltips_active(jid.to_string())));
        } else {
            via_label.visible = false;
        }
        name_label.label = placeholder;
        picture.model = new ViewModel.CompatAvatarPictureModel(null).add(
            placeholder != "" ? placeholder.get_char(0).toupper().to_string() : "?",
            jid.bare_jid.to_string(),
            null
        );
        status_dot.set_from_icon_name("dino-status-offline");
        presence_manager = stream_interactor.get_module<PresenceManager>(PresenceManager.IDENTITY);
        avatar_manager = stream_interactor.get_module<AvatarManager>(AvatarManager.IDENTITY);
        if (auto_hydrate) {
            hydrate_now();
        }
    }

    public void hydrate_immediately() {
        if (hydrated || disposed) return;
        hydrate();
    }

    public void hydrate_now() {
        if (hydrated || disposed) return;
        if (hydrate_source_id == 0) {
            hydrate_source_id = Idle.add_full(GLib.Priority.LOW, () => {
                hydrate_source_id = 0;
                hydrate();
                return false;
            });
            return;
        }
    }

    private void hydrate() {
        if (disposed || hydrated) return;
        string safe_initial_display_name = Util.sanitize_utf8(initial_display_name);
        string safe_bare_jid = Util.sanitize_utf8(jid.bare_jid.to_string());
        hydrated = true;
        string display_name;
        if (safe_initial_display_name.strip() == "") {
            Conversation conv = new Conversation(jid, account, Conversation.Type.CHAT);
            display_name = Util.sanitize_utf8(Util.get_conversation_display_name(stream_interactor, conv));
        } else {
            display_name = safe_initial_display_name;
        }
        if (show_account_hint && stream_interactor.get_accounts().size > 1) {
            via_label.label = Util.sanitize_utf8(_("via %s").printf(account.bare_jid.to_string()));
            this.has_tooltip = Util.use_tooltips();
            set_tooltip_text(Util.sanitize_utf8(Util.string_if_tooltips_active(jid.to_string())));
            via_label.visible = true;
        } else if (display_name != safe_bare_jid) {
            via_label.label = safe_bare_jid;
            via_label.visible = true;
        } else {
            via_label.visible = false;
        }
        name_label.label = display_name;
        if (presence_manager != null) {
            // Observe only this row's account/JID instead of receiving every
            // contact and MUC-occupant presence in every dialog row.
            WeakRef row_weak = WeakRef(this);
            presence_observer = ((!) presence_manager).observe_presence(account, jid.bare_jid,
                (changed_jid, changed_account, available) => {
                    ListRow? row = (ListRow?) row_weak.get();
                    if (row == null || ((!) row).disposed) return false;
                    ((!) row).set_status_dot(((!) row).stream_interactor);
                    return true;
                });
        }

        if (avatar_manager == null) {
            if (presence_manager != null) {
                set_status_dot(stream_interactor);
            }
            return;
        }

        uint generation = ++avatar_generation;
        Account expected_account = account;
        Jid expected_jid = jid.bare_jid;
        picture.model = new ViewModel.CompatAvatarPictureModel(null).add(
            display_name != "" ? display_name.get_char(0).toupper().to_string() : "?",
            jid.bare_jid.to_string(),
            null
        );
        AvatarManager manager = (!) avatar_manager;
        WeakRef row_weak = WeakRef(this);
        manager.get_avatar_bytes_from_local_cache_async.begin(expected_account, expected_jid, (obj, result) => {
            Bytes? image_bytes = manager.get_avatar_bytes_from_local_cache_async.end(result);
            ListRow? row = (ListRow?) row_weak.get();
            if (row == null || ((!) row).disposed || generation != ((!) row).avatar_generation ||
                    !Account.equals_func(((!) row).account, expected_account) ||
                    !((!) row).jid.equals_bare(expected_jid) || image_bytes == null) return;

            ((!) row).picture.model = new ViewModel.CompatAvatarPictureModel(null).add(
                display_name != "" ? display_name.get_char(0).toupper().to_string() : "?",
                expected_jid.to_string(),
                image_bytes
            );
        });

        set_status_dot(stream_interactor);
        return;
    }

    public void deactivate() {
        if (disposed) return;
        disposed = true;
        avatar_generation++;
        if (hydrate_source_id != 0) {
            Source.remove(hydrate_source_id);
            hydrate_source_id = 0;
        }

        if (presence_observer != null) {
            ((!) presence_observer).unsubscribe();
            presence_observer = null;
        }
    }

    public override void dispose() {
        deactivate();
        if (outer_box != null) {
            outer_box.unparent();
            outer_box = null;
        }
        base.dispose();
    }
}

}

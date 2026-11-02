using Gee;
using Gtk;
using Dino.Entities;
using Xmpp;

namespace Dino.Ui {

public class MucAdminDialog : Adw.Dialog {

    private StreamInteractor stream_interactor;
    private MucManager muc_manager;
    private Account account;
    private Jid muc_jid;
    private MucManager.MucOwnerMutationContext? room_context;

    private ListBox list_box;
    private DropDown affiliation_dropdown;
    private ArrayList<string> affiliation_ids = new ArrayList<string>();
    private Button add_button;
    private Button remove_button;

    private string current_affiliation = "member";
    private ArrayList<ListBoxRow> rows = new ArrayList<ListBoxRow>();
    private uint load_generation = 0;
    private bool action_busy = false;
    private bool dialog_closed = false;
    private bool query_available = false;
    private uint initial_affiliation_index = 0;

    public MucAdminDialog(StreamInteractor stream_interactor, Account account, Jid muc_jid) {
        this.stream_interactor = stream_interactor;
        this.muc_manager = stream_interactor.get_module<MucManager>(
            MucManager.IDENTITY);
        this.account = account;
        this.muc_jid = muc_jid.bare_jid;
        this.room_context = muc_manager.capture_current_muc_context(account,
            this.muc_jid);

        this.title = _("Room Administration");
        this.content_width = 400;
        this.content_height = 500;

        configure_visible_affiliations();
        setup_ui();
        closed.connect(() => {
            dialog_closed = true;
            load_generation++;
        });
        if (affiliation_ids.size > 0) {
            reload_list();
        } else {
            append_status_row(_("Room action failed"));
            set_action_busy(false);
        }
    }

    private void configure_visible_affiliations() {
        Xep.Muc.Affiliation? actor_affiliation = get_current_actor_affiliation();
        if (actor_affiliation == Xep.Muc.Affiliation.OWNER) {
            affiliation_ids.add("owner");
            affiliation_ids.add("admin");
            affiliation_ids.add("member");
            affiliation_ids.add("outcast");
            initial_affiliation_index = 2;
        } else if (actor_affiliation == Xep.Muc.Affiliation.ADMIN) {
            affiliation_ids.add("member");
            affiliation_ids.add("outcast");
        }
        if (affiliation_ids.size > 0) {
            current_affiliation = affiliation_ids[(int) initial_affiliation_index];
        }
    }

    private void setup_ui() {
        var toolbar_view = new Adw.ToolbarView();
        
        var header_bar = new Adw.HeaderBar();
        toolbar_view.add_top_bar(header_bar);

        Box main_box = new Box(Orientation.VERTICAL, 0);
        
        // Header / Toolbar
        Box header_box = new Box(Orientation.HORIZONTAL, 6);
        header_box.margin_top = 6;
        header_box.margin_bottom = 6;
        header_box.margin_start = 6;
        header_box.margin_end = 6;

        var model = new StringList(null);
        foreach (string affiliation in affiliation_ids) {
            model.append(get_affiliation_label(affiliation));
        }

        affiliation_dropdown = new DropDown(model, null);
        affiliation_dropdown.selected = initial_affiliation_index;
        affiliation_dropdown.visible = affiliation_ids.size > 0;
        affiliation_dropdown.notify["selected"].connect(() => {
            if (affiliation_dropdown.selected >= affiliation_ids.size) return;
            current_affiliation = affiliation_ids[(int) affiliation_dropdown.selected];
            reload_list();
        });
        header_box.append(affiliation_dropdown);

        main_box.append(header_box);

        // List
        ScrolledWindow scrolled = new ScrolledWindow();
        scrolled.vexpand = true;
        list_box = new ListBox();
        list_box.selection_mode = SelectionMode.SINGLE;
        list_box.row_selected.connect(update_buttons);
        scrolled.set_child(list_box);
        main_box.append(scrolled);

        // Bottom Action Bar
        Box action_box = new Box(Orientation.HORIZONTAL, 6);
        action_box.margin_top = 6;
        action_box.margin_bottom = 6;
        action_box.margin_start = 6;
        action_box.margin_end = 6;

        add_button = new Button.with_label(_("Add..."));
        add_button.hexpand = true;
        add_button.visible = affiliation_ids.size > 0;
        add_button.clicked.connect(on_add_clicked);
        action_box.append(add_button);

        remove_button = new Button.with_label(_("Remove"));
        remove_button.sensitive = false;
        remove_button.visible = affiliation_ids.size > 0;
        remove_button.clicked.connect(on_remove);
        action_box.append(remove_button);

        main_box.append(action_box);
        
        toolbar_view.content = main_box;
        this.child = toolbar_view;
    }

    private void reload_list() {
        if (!has_current_room_context()) {
            load_generation++;
            clear_list();
            append_status_row(_("Room action failed"));
            set_action_busy(false);
            return;
        }
        Xep.Muc.Affiliation? actor_affiliation = get_current_actor_affiliation();
        Xep.Muc.Affiliation list_affiliation = affiliation_from_id(current_affiliation);
        if (!MucManager.can_manage_affiliation_list(
                actor_affiliation, list_affiliation)) {
            load_generation++;
            clear_list();
            append_status_row(_("Room action failed"));
            set_action_busy(false);
            return;
        }

        uint generation = ++load_generation;
        string affiliation = current_affiliation;

        clear_list();
        query_available = false;
        set_action_busy(true);
        load_list.begin(affiliation, (obj, res) => {
            Gee.List<Jid>? jids = load_list.end(res);
            if (dialog_closed || generation != load_generation) return;

            Xep.Muc.Affiliation? current_actor = get_current_actor_affiliation();
            if (!MucManager.can_manage_affiliation_list(
                    current_actor, affiliation_from_id(affiliation))) {
                clear_list();
                append_status_row(_("Room action failed"));
                set_action_busy(false);
                return;
            }

            if (jids == null) {
                query_available = false;
                append_status_row(_("Error"));
                set_action_busy(false);
                return;
            }

            query_available = true;
            set_action_busy(false);
            foreach (Jid jid in (!) jids) {
                append_jid_row(jid.bare_jid);
            }
            update_buttons();
        });
    }

    private async Gee.List<Jid>? load_list(string affiliation) {
        MucManager.MucOwnerMutationContext? context = room_context;
        if (context == null ||
                !muc_manager.is_current_muc_context(account, (!) context)) {
            return null;
        }
        return yield muc_manager.get_affiliations_in_context(account,
            (!) context, affiliation);
    }

    private void clear_list() {
        ListBoxRow? row;
        while ((row = list_box.get_row_at_index(0)) != null) {
            list_box.remove(row);
        }
        rows.clear();
        query_available = false;
        remove_button.sensitive = false;
    }

    private void append_jid_row(Jid jid) {
        var label = new Label(jid.to_string());
        label.xalign = 0;
        label.margin_start = 10;
        label.margin_end = 10;
        label.margin_top = 10;
        label.margin_bottom = 10;

        var list_row = new ListBoxRow();
        list_row.set_child(label);
        list_row.set_data("jid", jid);

        list_box.append(list_row);
        rows.add(list_row);
    }

    private void append_status_row(string text) {
        var label = new Label(text);
        label.xalign = 0;
        label.margin_start = 10;
        label.margin_end = 10;
        label.margin_top = 10;
        label.margin_bottom = 10;
        label.sensitive = false;

        var list_row = new ListBoxRow();
        list_row.selectable = false;
        list_row.set_child(label);
        list_box.append(list_row);
    }

    private void update_buttons() {
        remove_button.sensitive = !action_busy && query_available &&
            list_box.get_selected_row() != null;
    }

    private void set_action_busy(bool busy) {
        action_busy = busy;
        affiliation_dropdown.sensitive = !busy;
        add_button.sensitive = !busy && query_available;
        update_buttons();
    }

    private void on_add_clicked() {
        var accounts = new ArrayList<Account>();
        accounts.add(account);

        SelectContactDialog dialog = new SelectContactDialog(stream_interactor, accounts);
        dialog.title = _("Add Member");
        dialog.ok_button.label = _("Add");
        
        dialog.selected.connect((selected_account, jid) => {
            if (selected_account != account) return;
            string affiliation = current_affiliation;
            dialog.close();
            apply_affiliation(jid.bare_jid, affiliation, null);
        });
        
        dialog.present(this);
    }

    private void on_remove() {
        var row = list_box.get_selected_row();
        if (row == null) return;

        Jid? jid = row.get_data<Jid>("jid");
        if (jid != null) {
            apply_affiliation(((Jid) jid).bare_jid, "none", current_affiliation);
        }
    }

    private void apply_affiliation(Jid target, string affiliation,
            string? source_affiliation) {
        MucManager.MucOwnerMutationContext? context = room_context;
        if (action_busy || !query_available || context == null ||
                !muc_manager.is_current_muc_context(account, (!) context)) {
            show_action_error(_("Room action failed"));
            return;
        }

        Xep.Muc.Affiliation? actor_affiliation = get_current_actor_affiliation();
        Xep.Muc.Affiliation? source = null;
        if (source_affiliation != null) {
            source = affiliation_from_id((!) source_affiliation);
        } else {
            source = muc_manager.get_affiliation(muc_jid.bare_jid,
                target.bare_jid, account);
        }
        Xep.Muc.Affiliation requested = affiliation_from_id(affiliation);
        if (!MucManager.can_request_affiliation_change(
                actor_affiliation, source, requested)) {
            show_action_error(_("Room action failed"));
            return;
        }

        query_available = false;
        set_action_busy(true);
        can_close = false;

        muc_manager.set_affiliation_checked_in_context.begin(account,
            (!) context, target.bare_jid, affiliation, null, (obj, res) => {
                try {
                    muc_manager.set_affiliation_checked_in_context.end(res);
                    can_close = true;
                    if (dialog_closed) return;
                    set_action_busy(false);
                    if (has_current_room_context()) {
                        reload_list();
                    } else {
                        clear_list();
                        append_status_row(_("Room action failed"));
                    }
                } catch (GLib.Error e) {
                    warning("Failed to change room affiliation for %s: %s",
                        target.to_string(), e.message);
                    can_close = true;
                    if (dialog_closed) return;
                    set_action_busy(false);
                    show_action_error(e.message);
                }
            });
    }

    private Xep.Muc.Affiliation? get_current_actor_affiliation() {
        MucManager.MucOwnerMutationContext? context = room_context;
        if (context == null ||
                !muc_manager.is_current_muc_context(account, (!) context)) {
            return null;
        }
        MucManager.MucOwnerMutationContext frozen_context = (!) context;
        return muc_manager.get_affiliation(frozen_context.room,
            frozen_context.own_jid, account);
    }

    private bool has_current_room_context() {
        return room_context != null &&
            muc_manager.is_current_muc_context(account, (!) room_context);
    }

    private static Xep.Muc.Affiliation affiliation_from_id(string affiliation) {
        switch (affiliation) {
            case "owner": return Xep.Muc.Affiliation.OWNER;
            case "admin": return Xep.Muc.Affiliation.ADMIN;
            case "member": return Xep.Muc.Affiliation.MEMBER;
            case "outcast": return Xep.Muc.Affiliation.OUTCAST;
            default: return Xep.Muc.Affiliation.NONE;
        }
    }

    private static string get_affiliation_label(string affiliation) {
        switch (affiliation) {
            case "owner": return _("Owners");
            case "admin": return _("Admins");
            case "outcast": return _("Banned");
            default: return _("Members");
        }
    }

    private void show_action_error(string detail) {
        Gtk.Root? root = this.root;
        if (root == null) return;
        var dialog = new Adw.AlertDialog(_("Error"), detail);
        dialog.add_response("ok", _("OK"));
        dialog.present((Gtk.Widget) root);
    }
}

}

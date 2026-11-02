using Dino.Entities;
using Gee;
using Gtk;
using Xmpp;

public class Dino.Ui.PreferencesWindowContacts : Adw.PreferencesPage {

    public signal void contact_chosen(Account account, Jid jid);

    private Adw.PreferencesGroup contacts_group;
    private Button add_contact_button;
    private Adw.ComboRow account_filter_row;
    private ArrayList<Account?> account_filter_options = new ArrayList<Account?>();
    private Stack contact_stack;
    private Adw.StatusPage empty_state;
    private ListView contact_list_view;
    private SignalListItemFactory contact_factory;
    private HashMap<Widget, PreferencesContactListViewRow> factory_rows = new HashMap<Widget, PreferencesContactListViewRow>();
    private ContactRosterModelSource? roster_source = null;
    private ViewModel.ContactListSelectionModel? contact_projection = null;
    private NoSelection? contact_no_selection = null;
    private ArrayList<Account> scoped_accounts = new ArrayList<Account>();
    private ulong projection_items_changed_handler_id = 0;
    private ViewModel.PreferencesDialog? connected_model = null;
    private ulong model_update_handler_id = 0;
    private BlockingManager? connected_blocking_manager = null;
    private ulong blocking_handler_id = 0;
    private bool needs_refresh = true;
    private Account? account_filter = null;
    private uint refresh_timeout_id = 0;
    private bool suppress_account_filter_change = false;
    private HashSet<string> pending_removals = new HashSet<string>();
    private bool timing_enabled = false;
    private HashSet<Widget> timing_bound_widgets = new HashSet<Widget>();
    private uint timing_setup_count = 0;
    private uint timing_bind_count = 0;
    private uint timing_unbind_count = 0;
    private uint timing_teardown_count = 0;
    private uint timing_release_count = 0;
    private int timing_pool_max = 0;
    private int timing_bound_max = 0;
    private int64 timing_bind_total_us = 0;
    private int64 timing_unbind_total_us = 0;

    public ViewModel.PreferencesDialog model { get; set; }

    construct {
        this.title = _("Contacts");
        this.icon_name = "avatar-default-symbolic";
        timing_enabled = UiTiming.enabled();
        build_contact_shell();
        this.notify["model"].connect(on_model_changed);
        this.map.connect(on_mapped);
        this.unmap.connect(on_unmapped);
        this.destroy.connect(on_destroyed);
    }

    private void on_model_changed() {
        setup_model_signals();
        schedule_refresh();
    }

    private void on_mapped() {
        if (contact_list_view.factory == null) {
            contact_list_view.factory = contact_factory;
        }
        if (!needs_refresh) {
            contact_list_view.model = contact_no_selection;
            return;
        }
        needs_refresh = false;
        queue_refresh();
    }

    private void on_unmapped() {
        if (refresh_timeout_id != 0) needs_refresh = true;
        cancel_refresh_source();
        detach_contact_list_view();
        release_detached_factory_rows();
        if (timing_enabled) log_factory_timing("unmap");
    }

    private void on_destroyed() {
        cancel_refresh_source();
        if (timing_enabled) log_factory_timing("destroy");
        teardown_contact_model();
        detach_contact_list_view();
        release_detached_factory_rows();
        disconnect_model_signals();
    }
    
    private void build_contact_shell() {
        contacts_group = new Adw.PreferencesGroup() { title = _("Contacts") };
        add_contact_button = new Button.from_icon_name("list-add-symbolic");
        add_contact_button.add_css_class("flat");
        add_contact_button.tooltip_text = _("Add Contact");
        add_contact_button.update_property(
            AccessibleProperty.LABEL, _("Add Contact"), -1);
        add_contact_button.clicked.connect(on_add_contact_clicked);
        contacts_group.header_suffix = add_contact_button;

        account_filter_row = new Adw.ComboRow() {
            title = _("Account"),
            visible = false
        };
        account_filter_row.notify["selected"].connect(on_account_filter_changed);
        contacts_group.add(account_filter_row);

        contact_factory = new SignalListItemFactory();
        contact_factory.setup.connect(on_factory_setup);
        contact_factory.bind.connect(on_factory_bind);
        contact_factory.unbind.connect(on_factory_unbind);
        contact_factory.teardown.connect(on_factory_teardown);
        contact_list_view = new ListView(null, contact_factory) {
            show_separators = true,
            hexpand = true,
            vexpand = true
        };
        var scroller = new ScrolledWindow() {
            child = contact_list_view,
            hscrollbar_policy = PolicyType.NEVER,
            min_content_height = 320,
            height_request = 320,
            propagate_natural_height = false,
            hexpand = true,
            vexpand = true
        };
        var list_frame = new Frame(null) { child = scroller };
        list_frame.add_css_class("card");

        empty_state = new Adw.StatusPage() {
            icon_name = "avatar-default-symbolic",
            title = _("No contacts"),
            description = _("Add contacts to start chatting"),
            height_request = 320
        };
        contact_stack = new Stack() {
            vhomogeneous = true,
            transition_type = StackTransitionType.CROSSFADE
        };
        contact_stack.add_named(list_frame, "contacts");
        contact_stack.add_named(empty_state, "empty");
        contact_stack.visible_child_name = "empty";
        contacts_group.add(contact_stack);
        this.add(contacts_group);
    }

    private void setup_model_signals() {
        if (connected_model == model && model_update_handler_id != 0) {
            ensure_stream_signals_connected();
            return;
        }

        disconnect_model_signals();

        if (model == null) return;

        connected_model = model;
        model_update_handler_id = model.update.connect(on_model_updated);
        ensure_stream_signals_connected();
    }

    private void on_model_updated() {
        ensure_stream_signals_connected();
        schedule_refresh();
    }

    private void disconnect_model_signals() {
        disconnect_stream_signals();

        if (connected_model != null && model_update_handler_id != 0) {
            if (SignalHandler.is_connected(connected_model, model_update_handler_id)) {
                SignalHandler.disconnect(connected_model, model_update_handler_id);
            }
        }
        connected_model = null;
        model_update_handler_id = 0;
    }

    private void ensure_stream_signals_connected() {
        if (model == null || model.stream_interactor == null) return;

        var blocking_manager = model.stream_interactor.get_module<BlockingManager>(BlockingManager.IDENTITY);
        if (connected_blocking_manager != null && connected_blocking_manager != blocking_manager) {
            disconnect_blocking_signals();
        }
        if (blocking_manager != null && connected_blocking_manager == null) {
            connected_blocking_manager = blocking_manager;
            blocking_handler_id = blocking_manager.block_changed.connect(on_blocking_changed);
        }
    }

    private void on_blocking_changed(Account account, Jid jid) {
        refresh_bound_rows();
    }

    private void disconnect_stream_signals() {
        disconnect_blocking_signals();
    }

    private void disconnect_blocking_signals() {
        if (connected_blocking_manager != null && blocking_handler_id != 0) {
            if (SignalHandler.is_connected(connected_blocking_manager, blocking_handler_id)) {
                SignalHandler.disconnect(connected_blocking_manager, blocking_handler_id);
            }
        }
        connected_blocking_manager = null;
        blocking_handler_id = 0;
    }

    private void schedule_refresh() {
        // Only refresh if the page is currently visible. Otherwise mark dirty.
        if (this.get_mapped()) {
            queue_refresh();
        } else {
            needs_refresh = true;
        }
    }

    private void queue_refresh() {
        if (refresh_timeout_id != 0) Source.remove(refresh_timeout_id);
        refresh_timeout_id = Timeout.add(100, on_refresh_timeout);
    }

    private bool on_refresh_timeout() {
        refresh_timeout_id = 0;
        refresh();
        return Source.REMOVE;
    }

    private void cancel_refresh_source() {
        if (refresh_timeout_id == 0) return;
        Source.remove(refresh_timeout_id);
        refresh_timeout_id = 0;
    }

    private void refresh() {
        if (model == null || model.stream_interactor == null) return;
        int64 started_us = UiTiming.enabled() ? UiTiming.now_us() : 0;
        ensure_stream_signals_connected();
        cancel_refresh_source();

        ArrayList<Account> enabled_accounts = model.get_active_accounts();
        add_contact_button.sensitive = enabled_accounts.size > 0;
        account_filter = find_current_account(enabled_accounts, account_filter);

        if (!same_account_scope(enabled_accounts)) {
            rebuild_contact_model(enabled_accounts);
        }
        contact_list_view.model = contact_no_selection;
        rebuild_account_selector(enabled_accounts);
        update_empty_state();
        needs_refresh = false;

        if (UiTiming.enabled()) {
            uint rows = contact_projection != null
                ? ((!) contact_projection).items.get_n_items()
                : 0;
            UiTiming.log_ms("Preferences.contacts.refresh: accounts=%d rows=%u".printf(
                enabled_accounts.size, rows), started_us);
        }
    }

    private bool same_account_scope(ArrayList<Account> enabled_accounts) {
        if (scoped_accounts.size != enabled_accounts.size) return false;
        for (int index = 0; index < scoped_accounts.size; index++) {
            if (scoped_accounts[index] != enabled_accounts[index] ||
                    scoped_accounts[index].id != enabled_accounts[index].id) return false;
        }
        return true;
    }

    private Account? find_current_account(ArrayList<Account> enabled_accounts, Account? candidate) {
        if (candidate == null) return null;
        foreach (Account account in enabled_accounts) {
            if (account == (!) candidate && account.id == ((!) candidate).id) return account;
        }
        return null;
    }

    private void rebuild_contact_model(ArrayList<Account> enabled_accounts) {
        teardown_contact_model();
        scoped_accounts.add_all(enabled_accounts);
        if (enabled_accounts.is_empty) return;

        roster_source = new ContactRosterModelSource(model.stream_interactor, enabled_accounts);
        contact_projection = new ViewModel.ContactListSelectionModel(((!) roster_source).model);
        projection_items_changed_handler_id = ((!) contact_projection).items.items_changed.connect(
            on_projection_items_changed);
        contact_no_selection = new NoSelection(((!) contact_projection).items);
        contact_list_view.model = contact_no_selection;
    }

    private void teardown_contact_model() {
        contact_list_view.model = null;
        if (contact_projection != null && projection_items_changed_handler_id != 0 &&
                SignalHandler.is_connected(((!) contact_projection).items,
                    projection_items_changed_handler_id)) {
            SignalHandler.disconnect(((!) contact_projection).items,
                projection_items_changed_handler_id);
        }
        projection_items_changed_handler_id = 0;
        contact_no_selection = null;
        contact_projection = null;
        if (roster_source != null) {
            ((!) roster_source).deactivate();
            roster_source = null;
        }
        scoped_accounts.clear();
    }

    private void detach_contact_list_view() {
        contact_list_view.model = null;
        contact_list_view.factory = null;
    }

    private void release_detached_factory_rows() {
        if (timing_enabled) timing_release_count += factory_rows.size;
        foreach (PreferencesContactListViewRow row in factory_rows.values) row.cleanup();
        factory_rows.clear();
        timing_bound_widgets.clear();
    }

    private void rebuild_account_selector(ArrayList<Account> enabled_accounts) {
        account_filter_options.clear();
        var labels = new StringList(null);
        uint selected_index = 0;

        if (enabled_accounts.size > 1) {
            labels.append(_("All Accounts"));
            account_filter_options.add(null);
            foreach (Account account in enabled_accounts) {
                labels.append(Util.sanitize_utf8(account.display_name));
                account_filter_options.add(account);
                if (account_filter == account) {
                    selected_index = (uint) account_filter_options.size - 1;
                }
            }
        } else if (enabled_accounts.size == 1) {
            labels.append(Util.sanitize_utf8(enabled_accounts[0].display_name));
            account_filter_options.add(enabled_accounts[0]);
            account_filter = null;
        }

        suppress_account_filter_change = true;
        account_filter_row.model = labels;
        account_filter_row.selected = selected_index;
        account_filter_row.visible = enabled_accounts.size > 1;
        suppress_account_filter_change = false;

        if (contact_projection != null) {
            ((!) contact_projection).update_account_filter(account_filter);
        }
        bool show_account_hint = enabled_accounts.size > 1;
        foreach (PreferencesContactListViewRow row in factory_rows.values) {
            row.set_show_account_hint(show_account_hint);
        }
    }

    private void on_account_filter_changed() {
        if (suppress_account_filter_change) return;
        uint index = account_filter_row.selected;
        account_filter = index < account_filter_options.size
            ? account_filter_options[(int) index]
            : null;
        if (contact_projection != null) {
            ((!) contact_projection).update_account_filter(account_filter);
        }
        update_empty_state();
    }

    private void on_add_contact_clicked() {
        if (model == null || model.stream_interactor == null) return;
        ArrayList<Account> enabled_accounts = model.get_active_accounts();
        Account? selected_account = find_current_account(enabled_accounts, account_filter);
        if (account_filter != null && selected_account == null) {
            account_filter = null;
            schedule_refresh();
            return;
        }
        if (selected_account == null && enabled_accounts.size == 1) {
            selected_account = enabled_accounts[0];
        }
        AddContactDialog dialog = selected_account != null
            ? AddContactDialog.for_account(model.stream_interactor, (!) selected_account)
            : new AddContactDialog(model.stream_interactor);
        present_with_root(dialog);
    }

    private void on_factory_setup(Object object) {
        ListItem? list_item = object as ListItem;
        if (list_item == null) return;
        var row = new PreferencesContactListViewRow();
        row.edit_requested.connect(on_edit_contact);
        row.mute_requested.connect(on_mute_contact);
        row.block_requested.connect(on_block_contact);
        row.remove_requested.connect(on_remove_contact);
        Widget widget = row.get_widget();
        factory_rows[widget] = row;
        ((!) list_item).activatable = false;
        ((!) list_item).selectable = false;
        ((!) list_item).child = widget;
        if (timing_enabled) {
            timing_setup_count++;
            timing_pool_max = int.max(timing_pool_max, factory_rows.size);
        }
    }

    private void on_factory_bind(Object object) {
        int64 started_us = timing_enabled ? UiTiming.now_us() : 0;
        if (model == null) return;
        ListItem? list_item = object as ListItem;
        if (list_item == null || ((!) list_item).child == null) return;
        PreferencesContactListViewRow? row = factory_rows[((!) list_item).child];
        ViewModel.ContactListItem? item = ((!) list_item).item as ViewModel.ContactListItem;
        if (row == null || item == null) return;
        string accessible_label = "%s, %s".printf(
            ((!) item).display_name.make_valid(), ((!) item).jid.to_string().make_valid());
        if (scoped_accounts.size > 1) {
            accessible_label = "%s, %s".printf(
                accessible_label, _("via %s").printf(((!) item).account.bare_jid.to_string()));
        }
        ((!) list_item).accessible_label = accessible_label;
        ((!) row).bind(model, (!) item, scoped_accounts.size > 1,
            pending_removals.contains(get_contact_key(((!) item).account, ((!) item).jid)));
        if (timing_enabled) {
            timing_bind_count++;
            timing_bind_total_us += UiTiming.now_us() - started_us;
            timing_bound_widgets.add((!) list_item.child);
            timing_bound_max = int.max(timing_bound_max, timing_bound_widgets.size);
        }
    }

    private void on_factory_unbind(Object object) {
        int64 started_us = timing_enabled ? UiTiming.now_us() : 0;
        ListItem? list_item = object as ListItem;
        if (list_item == null || ((!) list_item).child == null) return;
        PreferencesContactListViewRow? row = factory_rows[((!) list_item).child];
        if (row != null) ((!) row).unbind();
        ((!) list_item).accessible_label = "";
        if (timing_enabled) {
            timing_unbind_count++;
            timing_unbind_total_us += UiTiming.now_us() - started_us;
            timing_bound_widgets.remove((!) list_item.child);
        }
    }

    private void on_factory_teardown(Object object) {
        ListItem? list_item = object as ListItem;
        if (list_item == null || ((!) list_item).child == null) return;
        Widget widget = ((!) list_item).child;
        PreferencesContactListViewRow? row = factory_rows[widget];
        if (row != null) ((!) row).cleanup();
        if (timing_enabled) timing_bound_widgets.remove(widget);
        factory_rows.unset(widget);
        if (timing_enabled) timing_teardown_count++;
    }

    private void on_projection_items_changed(uint position, uint removed, uint added) {
        update_empty_state();
    }

    private void update_empty_state() {
        uint visible_rows = contact_projection != null
            ? ((!) contact_projection).items.get_n_items()
            : 0;
        if (visible_rows > 0) {
            contact_stack.visible_child_name = "contacts";
            return;
        }

        if (scoped_accounts.is_empty) {
            empty_state.title = _("No active accounts");
            empty_state.description = _("Enable an account to manage contacts");
        } else if (account_filter != null) {
            empty_state.title = _("No contacts for this account");
            empty_state.description = _("Add contacts to this account");
        } else {
            empty_state.title = _("No contacts");
            empty_state.description = _("Add contacts to start chatting");
        }
        contact_stack.visible_child_name = "empty";
    }

    private void refresh_bound_rows() {
        bool show_account_hint = scoped_accounts.size > 1;
        foreach (PreferencesContactListViewRow row in factory_rows.values) {
            row.set_show_account_hint(show_account_hint);
            row.refresh_state(is_row_removing(row));
        }
    }

    private bool is_row_removing(PreferencesContactListViewRow row) {
        string? key = row.contact_key;
        return key != null && pending_removals.contains((!) key);
    }

    private string get_contact_key(Account account, Jid jid) {
        return account.id.to_string() + ":" + jid.bare_jid.to_string();
    }

    private void log_factory_timing(string reason) {
        uint model_rows = roster_source != null ? ((!) roster_source).model.size : 0;
        uint projected_rows = contact_projection != null
            ? ((!) contact_projection).items.get_n_items()
            : 0;
        GLib.message(
            "UI-TIMING Preferences.contacts.factory_%s: model_rows=%u projected_rows=%u " +
            "pool_max=%d bound_max=%d live_pool=%d live_bound=%d " +
            "setup=%u bind=%u/%.2fms unbind=%u/%.2fms teardown=%u release=%u",
            reason,
            model_rows,
            projected_rows,
            timing_pool_max,
            timing_bound_max,
            factory_rows.size,
            timing_bound_widgets.size,
            timing_setup_count,
            timing_bind_count,
            timing_bind_total_us / 1000.0,
            timing_unbind_count,
            timing_unbind_total_us / 1000.0,
            timing_teardown_count,
            timing_release_count);
    }

    private void on_mute_contact(Account account, Jid jid, bool currently_muted, Conversation conversation) {
        if (currently_muted) {
            // Unmute contact
            var dialog = new Adw.AlertDialog(
                _("Unmute contact?"),
                _("This will enable notifications from %s.").printf(jid.to_string())
            );
            dialog.add_response("cancel", _("Cancel"));
            dialog.add_response("unmute", _("Unmute"));
            dialog.set_response_appearance("unmute", Adw.ResponseAppearance.SUGGESTED);
            dialog.default_response = "unmute";
            dialog.close_response = "cancel";

            dialog.response.connect((response) => {
                if (response == "unmute") {
                    conversation.notify_setting = Conversation.NotifySetting.DEFAULT;
                    refresh_bound_rows();
                }
            });

            present_with_root(dialog);
        } else {
            // Mute contact
            var dialog = new Adw.AlertDialog(
                _("Mute contact?"),
                _("This will disable notifications from %s.").printf(jid.to_string())
            );
            dialog.add_response("cancel", _("Cancel"));
            dialog.add_response("mute", _("Mute"));
            dialog.set_response_appearance("mute", Adw.ResponseAppearance.DESTRUCTIVE);
            dialog.default_response = "cancel";
            dialog.close_response = "cancel";

            dialog.response.connect((response) => {
                if (response == "mute") {
                    conversation.notify_setting = Conversation.NotifySetting.OFF;
                    refresh_bound_rows();
                }
            });

            present_with_root(dialog);
        }
    }

    private void on_block_contact(Account account, Jid jid, bool currently_blocked) {
        if (currently_blocked) {
            // Unblock contact
            var dialog = new Adw.AlertDialog(
                _("Unblock contact?"),
                _("This will allow %s to send you messages again.").printf(jid.to_string())
            );
            dialog.add_response("cancel", _("Cancel"));
            dialog.add_response("unblock", _("Unblock"));
            dialog.set_response_appearance("unblock", Adw.ResponseAppearance.SUGGESTED);
            dialog.default_response = "unblock";
            dialog.close_response = "cancel";

            dialog.response.connect((response) => {
                if (response == "unblock") {
                    model.stream_interactor.get_module<BlockingManager>(BlockingManager.IDENTITY).unblock(account, jid);
                    refresh_bound_rows();
                }
            });

            present_with_root(dialog);
        } else {
            // Block contact
            var dialog = new Adw.AlertDialog(
                _("Block contact?"),
                _("This will prevent %s from sending you messages.").printf(jid.to_string())
            );
            dialog.add_response("cancel", _("Cancel"));
            dialog.add_response("block", _("Block"));
            dialog.set_response_appearance("block", Adw.ResponseAppearance.DESTRUCTIVE);
            dialog.default_response = "cancel";
            dialog.close_response = "cancel";

            dialog.response.connect((response) => {
                if (response == "block") {
                    model.stream_interactor.get_module<BlockingManager>(BlockingManager.IDENTITY).block(account, jid);
                    refresh_bound_rows();
                }
            });

            present_with_root(dialog);
        }
    }

    private void on_remove_contact(Account account, Jid jid) {
        var dialog = new Adw.AlertDialog(
            _("Remove contact?"),
            _("This will remove %s from your contact list. Conversation history will be kept.").printf(jid.to_string())
        );
        dialog.add_response("cancel", _("Cancel"));
        dialog.add_response("remove", _("Remove"));
        dialog.set_response_appearance("remove", Adw.ResponseAppearance.DESTRUCTIVE);
        dialog.default_response = "cancel";
        dialog.close_response = "cancel";

        dialog.response.connect((response) => {
            if (response == "remove") {
                remove_contact.begin(account, jid, (_, res) => {
                    remove_contact.end(res);
                });
            }
        });

        present_with_root(dialog);
    }

    private async void remove_contact(Account account, Jid jid) {
        string contact_key = get_contact_key(account, jid);
        if (pending_removals.contains(contact_key)) return;

        pending_removals.add(contact_key);
        refresh_bound_rows();

        var roster_manager = model.stream_interactor.get_module<RosterManager>(RosterManager.IDENTITY);
        if (roster_manager == null) {
            pending_removals.remove(contact_key);
            show_remove_contact_unavailable(jid);
            refresh_bound_rows();
            return;
        }

        RosterRemoveResult result = yield roster_manager.remove_jid_async(account, jid);
        pending_removals.remove(contact_key);
        if (this.get_root() == null) return;

        switch (result) {
            case RosterRemoveResult.SUCCESS:
                break;
            case RosterRemoveResult.SERVER_REJECTED:
                show_remove_contact_rejected(jid);
                break;
            case RosterRemoveResult.UNAVAILABLE:
                show_remove_contact_unavailable(jid);
                break;
        }
        refresh_bound_rows();
    }

    private void show_remove_contact_rejected(Jid jid) {
        var root = this.get_root() as Window;
        if (root == null) return;

        var dialog = new Adw.AlertDialog(
            _("Could not remove contact"),
            _("The server did not allow removing %s. This contact may be managed by the server.").printf(jid.to_string())
        );
        dialog.add_response("ok", _("OK"));
        dialog.default_response = "ok";
        dialog.close_response = "ok";
        dialog.present(root);
    }

    private void show_remove_contact_unavailable(Jid jid) {
        var root = this.get_root() as Window;
        if (root == null) return;

        var dialog = new Adw.AlertDialog(
            _("Could not remove contact"),
            _("DinoX could not contact the server for %s. Check that the account is connected and try again.").printf(jid.to_string())
        );
        dialog.add_response("ok", _("OK"));
        dialog.default_response = "ok";
        dialog.close_response = "ok";
        dialog.present(root);
    }

    private void on_edit_contact(Account account, Jid jid, string? current_alias) {
        var dialog = new Adw.AlertDialog(
            _("Edit Contact Alias"),
            _("Change the display name for %s").printf(jid.to_string())
        );
        
        // Create entry for alias
        var entry = new Entry();
        entry.text = current_alias ?? "";
        entry.placeholder_text = _("Alias (optional)");
        entry.hexpand = true;
        
        var box = new Box(Orientation.VERTICAL, 12);
        box.append(entry);
        dialog.set_extra_child(box);
        
        dialog.add_response("cancel", _("Cancel"));
        dialog.add_response("save", _("Save"));
        dialog.set_response_appearance("save", Adw.ResponseAppearance.SUGGESTED);
        dialog.default_response = "save";
        dialog.close_response = "cancel";
        
        // Validate alias on change
        entry.changed.connect(() => {
            string new_alias = entry.text.strip();
            bool is_valid = true;
            
            // Check for duplicate aliases in the same account (excluding current contact)
            if (new_alias != "" && new_alias != current_alias) {
                var roster_manager = model.stream_interactor.get_module<RosterManager>(RosterManager.IDENTITY);
                var roster = roster_manager != null ? roster_manager.get_roster(account) : null;
                if (roster != null) {
                    foreach (Roster.Item item in roster) {
                        if (item.jid.equals_bare(jid)) continue;

                        if (item.name != null && item.name == new_alias) {
                            is_valid = false;
                            break;
                        }
                    }
                }
            }
            
            dialog.set_response_enabled("save", is_valid);
            
            if (!is_valid && new_alias != "") {
                entry.add_css_class("error");
            } else {
                entry.remove_css_class("error");
            }
        });
        
        dialog.response.connect((response) => {
            if (response == "save") {
                string new_alias = entry.text.strip();
                string? alias_to_set = new_alias == "" ? null : new_alias;
                
                // Update roster item alias
                var roster_manager = model.stream_interactor.get_module<RosterManager>(RosterManager.IDENTITY);
                if (roster_manager != null) {
                    roster_manager.set_jid_handle(account, jid, alias_to_set);
                }
            }
        });

        present_with_root(dialog);
    }

    private void present_with_root(Adw.Dialog dialog) {
        var root = this.get_root() as Window;
        if (root != null) {
            dialog.present(root);
            return;
        }
        var app = GLib.Application.get_default() as Gtk.Application;
        if (app != null && app.active_window != null) {
            dialog.present(app.active_window);
        }
    }

}

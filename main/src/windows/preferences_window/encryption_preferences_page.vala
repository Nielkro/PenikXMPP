using Dino.Entities;
using Xmpp;
using Xmpp.Xep;
using Gee;
using Gtk;

public class Dino.Ui.PreferencesWindowEncryption : Adw.PreferencesPage {

    private DropDown drop_down = null;
    private Adw.PreferencesGroup accounts_group = new Adw.PreferencesGroup();
    private ArrayList<Adw.PreferencesGroup> added_widgets = new ArrayList<Adw.PreferencesGroup>();
    private bool needs_refresh = true;
    private Account? selected_encryption_account = null;
    private ViewModel.PreferencesDialog? connected_model = null;
    private ulong model_update_handler_id = 0;
    private uint refresh_source_id = 0;

    public ViewModel.PreferencesDialog model { get; set; }

    construct {
        this.add(accounts_group);

        this.notify["model"].connect(() => {
            if (connected_model != null && model_update_handler_id != 0 && connected_model != model) {
                if (SignalHandler.is_connected(connected_model, model_update_handler_id)) {
                    SignalHandler.disconnect(connected_model, model_update_handler_id);
                }
                model_update_handler_id = 0;
            }

            if (model == null) {
                connected_model = null;
                selected_encryption_account = null;
                accounts_group.visible = false;
                unset_account();
                return;
            }

            if (connected_model != model || model_update_handler_id == 0) {
                model_update_handler_id = this.model.update.connect(() => {
                    schedule_refresh();
                });
                connected_model = model;
            }
            needs_refresh = true;
            schedule_refresh();
        });

        this.destroy.connect(() => {
            cancel_scheduled_refresh();
            if (connected_model != null && model_update_handler_id != 0) {
                if (SignalHandler.is_connected(connected_model, model_update_handler_id)) {
                    SignalHandler.disconnect(connected_model, model_update_handler_id);
                }
                connected_model = null;
                model_update_handler_id = 0;
            }
        });

        // Lazy loading: only populate when page becomes visible
        this.map.connect(() => {
            int64 map_start_us = UiTiming.enabled() ? UiTiming.now_us() : 0;
            if (needs_refresh) {
                needs_refresh = false;
                repopulate_account_selector();
            }
            if (UiTiming.enabled()) {
                UiTiming.log_ms("Preferences.encryption: map", map_start_us);
            }
        });
    }

    private void schedule_refresh() {
        if (!this.get_mapped()) {
            needs_refresh = true;
            return;
        }
        needs_refresh = false;
        if (refresh_source_id != 0) return;
        refresh_source_id = Idle.add(() => {
            refresh_source_id = 0;
            if (!this.get_mapped()) {
                needs_refresh = true;
                return Source.REMOVE;
            }
            int64 refresh_start_us = UiTiming.enabled() ? UiTiming.now_us() : 0;
            repopulate_account_selector();
            if (UiTiming.enabled()) {
                UiTiming.log_ms("Preferences.encryption: refresh", refresh_start_us);
            }
            return Source.REMOVE;
        });
    }

    private void cancel_scheduled_refresh() {
        if (refresh_source_id != 0) {
            Source.remove(refresh_source_id);
            refresh_source_id = 0;
        }
    }

    private void repopulate_account_selector() {
        // Remove current selector
        if (drop_down != null) {
            accounts_group.remove(drop_down);
            drop_down = null;
        }

        if (model == null) {
            selected_encryption_account = null;
            accounts_group.visible = false;
            unset_account();
            return;
        }

        uint active_account_count = model.active_accounts_selection.get_n_items();

        // Don't show selector if the user has only one active account
        accounts_group.visible = active_account_count != 1;

        // Populate selector
        if (active_account_count > 0) {
            drop_down = new DropDown(model.active_accounts_selection, null) { halign=Align.CENTER };
            drop_down.factory = new BuilderListItemFactory.from_resource(null, "/im/dinox/dinox/account_picker_row.ui");

            uint selected_index = 0;
            ViewModel.AccountDetails selected_account_details = (ViewModel.AccountDetails) model.active_accounts_selection.get_item(0);
            for (uint i = 0; i < active_account_count; i++) {
                var account_details = (ViewModel.AccountDetails) model.active_accounts_selection.get_item(i);
                if (selected_encryption_account != null && account_details.account == selected_encryption_account) {
                    selected_index = i;
                    selected_account_details = account_details;
                    break;
                }
            }

            drop_down.selected = selected_index;
            DropDown selector = drop_down;

            selector.notify["selected-item"].connect((obj, pspec) => {
                var selected_drop_down = obj as DropDown;
                if (selected_drop_down == null) return;
                var account_details = selected_drop_down.selected_item as ViewModel.AccountDetails;
                if (account_details == null) return;
                selected_encryption_account = account_details.account;
                set_account(account_details.account);
            });

            selected_encryption_account = selected_account_details.account;
            set_account(selected_account_details.account);
        } else {
            var no_accounts_model = new StringList(null);
            no_accounts_model.append(_("No active accounts"));
            drop_down = new DropDown(no_accounts_model, null) { halign=Align.CENTER, sensitive=false };
            selected_encryption_account = null;
            unset_account();
        }
        accounts_group.add(drop_down);
    }

    private void unset_account() {
        foreach (var widget in added_widgets) {
            this.remove(widget);
        }
        added_widgets.clear();
    }

    private void set_account(Account account) {
        int64 account_start_us = UiTiming.enabled() ? UiTiming.now_us() : 0;
        unset_account();

        Application app = GLib.Application.get_default() as Application;
        foreach (Plugins.EncryptionPreferencesEntry e in app.plugin_registry.encryption_preferences_entries) {
            int64 entry_start_us = UiTiming.enabled() ? UiTiming.now_us() : 0;
            var widget = (Adw.PreferencesGroup) e.get_widget(account, Plugins.WidgetType.GTK4);
            this.add(widget);
            this.added_widgets.add(widget);
            if (UiTiming.enabled()) {
                UiTiming.log_ms("Preferences.encryption: build " + e.id, entry_start_us);
            }
        }
        if (UiTiming.enabled()) {
            UiTiming.log_ms("Preferences.encryption: set account", account_start_us);
        }
    }
}

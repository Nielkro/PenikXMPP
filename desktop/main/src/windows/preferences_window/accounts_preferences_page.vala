using Dino.Entities;
using Gee;
using Gtk;

public class Dino.Ui.PreferencesWindowAccounts : Adw.PreferencesPage {

    public signal void account_chosen(Account account);

    public Adw.PreferencesGroup active_accounts;
    public Adw.PreferencesGroup disabled_accounts;
    private bool model_ready = false;
    private uint refresh_timeout_id = 0;
    private bool refresh_scheduled = false;

    public ViewModel.PreferencesDialog model { get; set; }
    private ViewModel.PreferencesDialog? connected_model = null;
    private ulong model_update_handler_id = 0;

    construct  {
        this.title = _("Accounts");
        this.icon_name = "system-users-symbolic";

        this.notify["model"].connect(() => {
            if (connected_model != null && model_update_handler_id != 0 && connected_model != model) {
                if (SignalHandler.is_connected(connected_model, model_update_handler_id)) {
                    SignalHandler.disconnect(connected_model, model_update_handler_id);
                }
                model_update_handler_id = 0;
            }

            if (model == null) {
                connected_model = null;
                return;
            }

            if (connected_model != model || model_update_handler_id == 0) {
                model_update_handler_id = model.update.connect(() => {
                    model_ready = true;
                    if (this.get_mapped()) {
                        queue_refresh();
                    }
                });
                connected_model = model;
            }

            model_ready = true;
            if (this.get_mapped()) {
                queue_refresh();
            }
        });

        this.destroy.connect(() => {
            if (connected_model != null && model_update_handler_id != 0) {
                if (SignalHandler.is_connected(connected_model, model_update_handler_id)) {
                    SignalHandler.disconnect(connected_model, model_update_handler_id);
                }
                connected_model = null;
                model_update_handler_id = 0;
            }
        });

        // Load rows when page becomes visible to avoid UI-thread spikes during first draw.
        this.map.connect(() => {
            if (model_ready) {
                queue_refresh();
            }
        });
        this.unmap.connect(() => {
            cancel_refresh();
        });
    }

    private void queue_refresh() {
        if (refresh_scheduled) return;
        if (!this.get_mapped()) return;
        refresh_scheduled = true;
        refresh_timeout_id = Timeout.add(16, () => {
            refresh_timeout_id = 0;
            refresh_scheduled = false;
            if (this.get_mapped()) {
                refresh();
            }
            return false;
        });
    }

    private void cancel_refresh() {
        if (refresh_timeout_id != 0) {
            Source.remove(refresh_timeout_id);
            refresh_timeout_id = 0;
            refresh_scheduled = false;
        }
    }

    private void refresh() {
        if (active_accounts != null) this.remove(active_accounts);
        if (disabled_accounts != null) this.remove(disabled_accounts);

        active_accounts = new Adw.PreferencesGroup() { title=_("Accounts")};
        disabled_accounts = new Adw.PreferencesGroup() { title=_("Disabled accounts")};
        Button add_account_button = new Button.from_icon_name("list-add-symbolic");
        add_account_button.add_css_class("flat");
        add_account_button.tooltip_text = _("Add Account");
        active_accounts.header_suffix = add_account_button;

        this.add(active_accounts);
        this.add(disabled_accounts);

        add_account_button.clicked.connect(() => {
            bool created;
            Ui.ManageAccounts.AddAccountDialog add_account_dialog =
                    Ui.ManageAccounts.AddAccountDialog.present_regular(model.stream_interactor, model.db, get_dialog_parent(), false, out created);
            if (created) {
                add_account_dialog.added.connect((account) => {
                    refresh();
                });
            }
        });

        disabled_accounts.visible = false; // Only display disabled section if it contains accounts
        var enabled_account_added = false;

        foreach (ViewModel.AccountDetails account_details in model.account_details.values) {
            var row = new Adw.ActionRow() {
                title = account_details.bare_jid.to_string()
            };
            row.add_prefix(new AvatarPicture() { valign=Align.CENTER, height_request=35, width_request=35, model = account_details.avatar_model });
            row.add_suffix(new Image.from_icon_name("go-next-symbolic"));
            row.activatable = true;

            if (account_details.account.enabled) {
                active_accounts.add(row);
                enabled_account_added = true;
            } else {
                disabled_accounts.add(row);
                disabled_accounts.visible = true;
            }

            row.activated.connect(() => {
                if (account_details != null) {
                    account_chosen(account_details.account);
                }
            });
        }

        // We always have to show the active accounts group for the add new button. Display placeholder if there are no active accounts
        if (!enabled_account_added) {
            active_accounts.add(new Adw.ActionRow() { title=_("No active accounts") });
        }
    }

    private Window? get_dialog_parent() {
        var root = this.get_root() as Window;
        if (root != null) {
            return root;
        }
        if (model != null && model.stream_interactor != null) {
            var app = GLib.Application.get_default() as Gtk.Application;
            if (app != null && app.active_window != null) {
                return app.active_window;
            }
        }
        return null;
    }
}

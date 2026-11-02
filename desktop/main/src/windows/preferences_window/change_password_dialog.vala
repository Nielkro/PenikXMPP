using Gee;
using Gtk;

using Dino.Entities;
using Xmpp;

namespace Dino.Ui{

    [GtkTemplate (ui = "/im/dinox/dinox/preferences_window/change_password_dialog.ui")]
    public class ChangePasswordDialog : Adw.Dialog {

        [GtkChild] private unowned Button change_password_button;
        [GtkChild] private unowned Stack change_password_stack;
        [GtkChild] private unowned Button cancel_button;
        [GtkChild] private unowned Adw.PasswordEntryRow current_password_entry;
        [GtkChild] private unowned Adw.PasswordEntryRow new_password_entry;
        [GtkChild] private unowned Adw.PasswordEntryRow confirm_new_password_entry;
        [GtkChild] private unowned Label change_password_error_label;

        private ViewModel.ChangePasswordDialog model;
        private bool password_change_in_progress = false;
        private bool dialog_closed = false;

        public ChangePasswordDialog(ViewModel.ChangePasswordDialog model) {
            this.model = model;

            Util.force_error_color(change_password_error_label);
            closed.connect(on_closed);
            cancel_button.clicked.connect(() => { close(); });
            current_password_entry.changed.connect(is_form_filled);
            new_password_entry.changed.connect(is_form_filled);
            confirm_new_password_entry.changed.connect(is_form_filled);
            change_password_button.clicked.connect(change_password);
        }

        private void change_password() {
            on_change_password_button_clicked.begin((obj, res) => {
                on_change_password_button_clicked.end(res);
            });
        }

        private void is_form_filled(){
            if (dialog_closed) return;
            if (password_change_in_progress) {
                change_password_button.sensitive = false;
                return;
            }
            if (current_password_entry.get_text().length > 0
                    && new_password_entry.get_text().length > 0
                    && confirm_new_password_entry.get_text().length > 0
                    && new_password_entry.get_text() == confirm_new_password_entry.get_text()){
                change_password_button.sensitive = true;
            } else {
                change_password_button.sensitive = false;
            }
        }

        private void on_closed() {
            dialog_closed = true;
        }

        private async void on_change_password_button_clicked(){
            if (password_change_in_progress || dialog_closed) return;
            string? pw_input = current_password_entry.get_text();
            string? new_pw_input = new_password_entry.get_text();

            if (pw_input != null && model.account.password == pw_input){
                password_change_in_progress = true;
                change_password_button.sensitive = false;
                change_password_stack.visible_child_name = "spinner";
                string? ret = yield model.change_password(new_pw_input);
                password_change_in_progress = false;
                if (dialog_closed) return;
                change_password_stack.visible_child_name = "label";
                is_form_filled();
                if (ret == null) {
                    close();
                    return;
                }

                change_password_error_label.label = _("Error: %s").printf(ret);

            } else {
                change_password_error_label.label = _("Wrong current password");
            }
        }
    }
}

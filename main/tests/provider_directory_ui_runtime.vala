using Gtk;

namespace Dino.Ui.ManageAccounts {

// The production dialog has service and database dependencies. This focused
// runtime fixture deliberately shares its GType/template name so GTK parses
// the real resource and binds the provider-directory controls without needing
// an account or touching a user profile.
[GtkTemplate (ui = "/im/dinox/dinox/preferences_window/add_account_dialog.ui")]
class AddAccountDialog : Adw.Dialog {
    [GtkChild] private unowned Label provider_directory_status_label;
    [GtkChild] private unowned Button provider_directory_refresh_button;
    [GtkChild] private unowned Stack provider_directory_refresh_indicator_stack;
    [GtkChild] private unowned Spinner provider_directory_refresh_spinner;

    internal Label provider_status_label {
        get { return provider_directory_status_label; }
    }

    internal Button provider_refresh_button {
        get { return provider_directory_refresh_button; }
    }

    internal Stack provider_refresh_indicator_stack {
        get { return provider_directory_refresh_indicator_stack; }
    }

    internal Spinner provider_refresh_spinner {
        get { return provider_directory_refresh_spinner; }
    }
}

}

namespace Dino.Ui.Test {

class ProviderDirectoryUiRuntimeTest : Gee.TestCase {
    public ProviderDirectoryUiRuntimeTest() {
        base("ProviderDirectoryUiRuntime");
        add_test("refresh_control_template_is_valid_and_idle",
            test_refresh_control_template_is_valid_and_idle);
    }

    private void test_refresh_control_template_is_valid_and_idle() {
        var dialog = new ManageAccounts.AddAccountDialog();

        fail_if_not(dialog.provider_status_label.hexpand,
            "provider status must leave horizontal room for the refresh control");
        fail_if_not(dialog.provider_status_label.wrap,
            "provider status must remain readable at narrow dialog widths");
        fail_if(dialog.provider_refresh_button.sensitive,
            "refresh must remain disabled until the bundled or cached list is loaded");
        fail_if_not(dialog.provider_refresh_button.tooltip_text == "Update provider list",
            "refresh control must expose a descriptive tooltip");
        fail_if_not(dialog.provider_refresh_button.has_css_class("flat"),
            "refresh control must use the compact flat style");
        fail_if_not(dialog.provider_refresh_button.has_css_class("circular"),
            "refresh control must use the circular icon-button style");
        fail_if_not(dialog.provider_refresh_indicator_stack.visible_child_name == "refresh",
            "refresh icon must be the initial indicator");
        fail_if(dialog.provider_refresh_spinner.spinning,
            "the hidden refresh spinner must not consume resources while idle");

        dialog.close();
        drain_main_context();
    }

    private void drain_main_context() {
        MainContext context = MainContext.default();
        while (context.pending()) {
            context.iteration(false);
        }
    }
}

}

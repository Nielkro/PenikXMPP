namespace Dino.Ui.Test {

class ServerAdministrationTextRuntimeTest : Gee.TestCase {
    public ServerAdministrationTextRuntimeTest() {
        base("ServerAdministrationTextRuntime");
        add_test("server_text_is_literal_without_changing_form_values", test_literal_text);
        add_test("entry_and_password_help_popovers_are_literal", test_entry_help_popovers);
        add_test("combo_and_multiline_help_are_literal_in_both_markup_modes",
            test_combo_and_multiline_help);
        add_test("server_toggle_and_multi_check_help_are_literal_in_both_markup_modes",
            test_toggle_and_multi_check_help);
        add_test("missing_field_help_does_not_add_empty_controls", test_missing_field_help);
    }

    private void test_literal_text() {
        string heading = "Команды <test> & server";
        string title = "Benutzer <name> & сервер";
        string explanation = "Use <value/> & keep spaces";
        var rows = new GLib.ListStore(typeof(ViewModel.PreferencesRow.Any));
        var fixed_row = new ViewModel.PreferencesRow.Text() { text = heading };
        var toggle = new ViewModel.PreferencesRow.Toggle() {
            title = title, subtitle = explanation, state = false
        };
        var input = new ViewModel.PreferencesRow.Entry() {
            title = title, text = " <actual input> & Привет "
        };
        rows.append(fixed_row);
        rows.append(toggle);
        rows.append(input);

        var groups = Util.rows_to_preference_window_split_at_text(rows, false);
        fail_if_not_eq_int(1, groups.size);
        // AdwPreferencesGroup exposes the displayed label text in its getter,
        // not the escaped markup supplied to its setter.
        fail_if_not_eq_str(heading, groups[0].title);
        fail_if_not(all_rows_are_plain(groups[0]));
        fail_if_not(has_visible_text(groups[0], heading));
        fail_if_not(has_visible_text(groups[0], title));
        fail_if_not(has_visible_text(groups[0], explanation));
        fail_if_not_eq_str(heading, fixed_row.text);
        fail_if_not_eq_str(title, toggle.title);
        fail_if_not_eq_str(explanation, toggle.subtitle);
        fail_if_not_eq_str(" <actual input> & Привет ", input.text);
    }

    private void test_entry_help_popovers() {
        string help = "Помощь: use <value/> & keep <b>literal</b> text";
        string value = "  secret & Привет <value/>  ";
        foreach (bool use_markup in new bool[] { false, true }) {
            var input = new ViewModel.PreferencesRow.Entry() {
                title = "Username", description = help, text = value
            };
            var input_view = Util.row_to_preference_row(input, use_markup) as Adw.EntryRow;
            if (fail_if(input_view == null, "entry help needs a real Adw.EntryRow")) return;
            check_help_popover((!) input_view, help, value);
            fail_if_not_eq_str(value, ((!) input_view).text);
            fail_if_not_eq_str(value, input.text);
            fail_if_not_eq_str(help, (!) input.description);

            var password = new ViewModel.PreferencesRow.PrivateText() {
                title = "Password", description = help, text = value
            };
            var password_view = Util.row_to_preference_row(password, use_markup)
                as Adw.PasswordEntryRow;
            if (fail_if(password_view == null, "private help needs a real password entry")) return;
            check_help_popover((!) password_view, help, value);
            fail_if_not_eq_str(value, ((!) password_view).text);
            fail_if_not_eq_str(value, password.text);
            fail_if_not_eq_str(help, (!) password.description);
        }
    }

    private void check_help_popover(Gtk.Widget row, string help, string value) {
        Gtk.MenuButton? button = find_help_button(row);
        if (fail_if(button == null, "field help must have its own information button")) return;
        fail_if_not_eq_str(_("Field help"), (!) ((!) button).tooltip_text);
        Gtk.Popover? popover = ((!) button).popover;
        if (fail_if(popover == null, "field help button must own its popover")) return;
        var label = ((!) popover).child as Gtk.Label;
        if (fail_if(label == null, "field help must contain a readable text label")) return;
        fail_if_not_eq_str(help, ((!) label).get_text());
        fail_if(((!) label).use_markup,
            "server help must never be interpreted as Pango markup in the popover");
        fail_if_not(((!) label).wrap && ((!) label).selectable,
            "long field help must wrap and remain selectable");
        fail_if(has_visible_text((!) popover, value),
            "the help popover must not expose the entered value or password");
    }

    private void test_combo_and_multiline_help() {
        string help = "Описание <value/> & <b>не разметка</b>";
        string value = "\n  Привет <value/> &  \n";
        foreach (bool use_markup in new bool[] { false, true }) {
            var combo = new ViewModel.PreferencesRow.ComboBox() {
                title = "Choice", description = help, active_item = 1
            };
            combo.items.add("First choice");
            combo.items.add("Second choice");
            var combo_view = Util.row_to_preference_row(combo, use_markup) as Adw.ComboRow;
            if (fail_if(combo_view == null, "list help needs a real Adw.ComboRow")) return;
            fail_if_not(has_visible_text((!) combo_view, help),
                "combo help must display the server's literal Cyrillic and XML-looking text");
            fail_if_not_eq_int(1, (int) ((!) combo_view).selected);
            fail_if_not_eq_int(1, combo.active_item);
            fail_if_not_eq_str(help, (!) combo.description);

            var multi = new ViewModel.PreferencesRow.MultiText() {
                title = "Lines", description = help, text = value
            };
            var multi_view = Util.row_to_preference_row(multi, use_markup) as Adw.ActionRow;
            if (fail_if(multi_view == null, "multiline help needs a real Adw.ActionRow")) return;
            fail_if_not(has_visible_text((!) multi_view, help + "\n" + _("One value per line")),
                "multiline help must display literally beside the editing instruction");
            fail_if_not_eq_str(value, multi.text);
            fail_if_not_eq_str(help, (!) multi.description);
        }
    }

    private void test_toggle_and_multi_check_help() {
        string help = "Выберите <value/> & <b>literal</b>";
        foreach (bool use_markup in new bool[] { false, true }) {
            var toggle = new ViewModel.PreferencesRow.Toggle() {
                title = "Enabled", description = help, subtitle = help, state = false
            };
            var toggle_view = Util.row_to_preference_row(toggle, use_markup);
            if (fail_if(toggle_view == null, "boolean help needs a real preferences row")) return;
            fail_if_not(has_visible_text((!) toggle_view, help),
                "server boolean help must display literal text in either markup mode");
            fail_if(toggle.state, "rendering help must not enable the boolean field");
            fail_if_not_eq_str(help, toggle.subtitle);

            var choices = new ViewModel.PreferencesRow.MultiCheck() {
                title = "Multiple choices", description = help, subtitle = help
            };
            choices.items.add("First choice");
            choices.items.add("Second choice");
            choices.states.add(true);
            choices.states.add(false);
            var choices_view = Util.row_to_preference_row(choices, use_markup);
            if (fail_if(choices_view == null, "multi-list help needs a real preferences row")) return;
            fail_if_not(has_visible_text((!) choices_view, help),
                "server multi-list help must display literal text in either markup mode");
            fail_if_not(choices.states[0] && !choices.states[1],
                "rendering help must preserve the original selections");
            fail_if_not_eq_str(help, (!) choices.subtitle);

            // JID_MULTI with a preloaded user list has description but no
            // subtitle. Its help must not disappear when selecting accounts.
            choices.subtitle = null;
            var jid_choices_view = Util.row_to_preference_row(choices, use_markup);
            if (fail_if(jid_choices_view == null, "account picker needs a real preferences row")) return;
            fail_if_not(has_visible_text((!) jid_choices_view, help),
                "preloaded account selection must display its field description");
            fail_if_not(choices.states[0] && !choices.states[1],
                "showing account-picker help must preserve the selected accounts");
        }
    }

    private void test_missing_field_help() {
        foreach (string? description in new string?[] { null, "" }) {
            var entry = new ViewModel.PreferencesRow.Entry() {
                title = "Username", description = description, text = "unchanged"
            };
            var row = Util.row_to_preference_row(entry, false);
            if (fail_if(row == null)) return;
            fail_if(find_help_button((!) row) != null,
                "missing field help must not add an empty information popover");
            var multi = new ViewModel.PreferencesRow.MultiText() {
                title = "Lines", description = description, text = "unchanged"
            };
            var multi_view = Util.row_to_preference_row(multi, false);
            if (fail_if(multi_view == null)) return;
            fail_if_not(has_visible_text((!) multi_view, _("One value per line")),
                "fields without server help must retain their ordinary editing instruction");
        }
    }

    private Gtk.MenuButton? find_help_button(Gtk.Widget widget) {
        if (widget is Gtk.MenuButton &&
                ((Gtk.MenuButton) widget).icon_name == "dialog-information-symbolic") {
            return widget as Gtk.MenuButton;
        }
        for (Gtk.Widget? child = widget.get_first_child(); child != null; child = child.get_next_sibling()) {
            Gtk.MenuButton? found = find_help_button((!) child);
            if (found != null) return found;
        }
        return null;
    }

    private bool all_rows_are_plain(Gtk.Widget widget) {
        if (widget is Adw.PreferencesRow && ((Adw.PreferencesRow) widget).use_markup) return false;
        for (Gtk.Widget? child = widget.get_first_child(); child != null; child = child.get_next_sibling()) {
            if (!all_rows_are_plain((!) child)) return false;
        }
        return true;
    }

    private bool has_visible_text(Gtk.Widget widget, string text) {
        if (widget is Gtk.Label && ((Gtk.Label) widget).get_text() == text) return true;
        for (Gtk.Widget? child = widget.get_first_child(); child != null; child = child.get_next_sibling()) {
            if (has_visible_text((!) child, text)) return true;
        }
        return false;
    }
}
}

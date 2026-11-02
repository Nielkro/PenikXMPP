using Gee;
using Gdk;
using Gtk;

using Dino.Entities;
using Xmpp.Xep;

namespace Dino.Ui.Util {
    public Gee.List<Adw.PreferencesGroup> rows_to_preference_window_split_at_text(
            GLib.ListStore row_view_models, bool use_markup = true) {
        var preference_groups = new ArrayList<Adw.PreferencesGroup>();
        Adw.PreferencesGroup? preference_group = null;

        for (int preference_group_i = 0; preference_group_i < row_view_models.get_n_items(); preference_group_i++) {
            var preferences_row = (ViewModel.PreferencesRow.Any) row_view_models.get_item(preference_group_i);

            // If it's a text, start a new PreferencesGroup with the text as title. Else, add an item to the current group.
            var preferences_row_text = preferences_row as ViewModel.PreferencesRow.Text;
            if (preferences_row_text != null) {
                if (preference_group != null) preference_groups.add(preference_group);
                preference_group = new Adw.PreferencesGroup() {
                    title = use_markup ? preferences_row_text.text : Markup.escape_text(preferences_row_text.text)
                };
            } else {
                if (preference_group == null) {
                    preference_group = new Adw.PreferencesGroup();
                }
                Widget? w = row_to_preference_row(preferences_row, use_markup);
                if (w == null) continue;
                preference_group.add(w);
            }

        }
        
        // Don't forget the last preference group!
        if (preference_group != null) {
            preference_groups.add(preference_group);
        }

        return preference_groups;
    }

    public void commit_preference_rows(GLib.ListStore row_view_models) {
        for (uint index = 0; index < row_view_models.get_n_items(); index++) {
            var number = row_view_models.get_item(index) as ViewModel.PreferencesRow.Number;
            if (number != null) number.commit();
        }
    }

    // Section markers are explicit: legacy Text models remain property rows.
    public Gee.List<Adw.PreferencesGroup> rows_to_preference_groups_with_sections(
            GLib.ListStore row_view_models, string first_title) {
        var groups = new ArrayList<Adw.PreferencesGroup>();
        var group = new Adw.PreferencesGroup() { title = first_title };
        groups.add(group);
        for (uint index = 0; index < row_view_models.get_n_items(); index++) {
            var row = (ViewModel.PreferencesRow.Any) row_view_models.get_item(index);
            var section = row as ViewModel.PreferencesRow.Section;
            if (section != null) {
                group = new Adw.PreferencesGroup() {
                    title = Markup.escape_text(section.title)
                };
                groups.add(group);
                continue;
            }
            Widget? widget = row_to_preference_row(row);
            if (widget != null) group.add(widget);
        }
        return groups;
    }

    public Adw.PreferencesGroup rows_to_preference_group(GLib.ListStore row_view_models, string title) {
        var preference_group = new Adw.PreferencesGroup() { title=title };

        for (int preference_group_i = 0; preference_group_i < row_view_models.get_n_items(); preference_group_i++) {
            var preferences_row = (ViewModel.PreferencesRow.Any) row_view_models.get_item(preference_group_i);

            Widget? w = row_to_preference_row(preferences_row);
            if (w == null) continue;

            preference_group.add(w);
        }

        return preference_group;
    }

    public Adw.PreferencesRow? row_to_preference_row(ViewModel.PreferencesRow.Any preferences_row,
            bool use_markup = true) {
        var entry_view_model = preferences_row as ViewModel.PreferencesRow.Entry;
        if (entry_view_model != null) {
            Adw.EntryRow view = new Adw.EntryRow() { use_markup = use_markup, title = entry_view_model.title, show_apply_button=true };
            add_entry_field_help(view, entry_view_model.description);
            if (preferences_row.media_uri != null) {
                var bytes = Xmpp.get_data_for_uri(preferences_row.media_uri);
                try {
                    Picture picture = new Picture.for_paintable(Texture.from_bytes(bytes));
                    view.add_suffix(picture);
                } catch (Error e) {
                    warning("Failed to create texture from bytes: %s", e.message);
                }
            }
            entry_view_model.bind_property("text", view, "text", BindingFlags.SYNC_CREATE | BindingFlags.BIDIRECTIONAL, (_, from, ref to) => {
                var str = (string) from;
                to = str ?? "";
                return true;
            });
            view.apply.connect(() => {
                // AdwEntryRow owns its apply-button and focus lifecycle.
                // Toggling the button or forcing focus here breaks that
                // lifecycle on GTK 4.14.
                entry_view_model.changed();
            });
            return view;
        }

        var password_view_model = preferences_row as ViewModel.PreferencesRow.PrivateText;
        if (password_view_model != null) {
            Adw.PasswordEntryRow view = new Adw.PasswordEntryRow() { use_markup = use_markup, title = password_view_model.title, show_apply_button=true };
            add_entry_field_help(view, password_view_model.description);
            password_view_model.bind_property("text", view, "text", BindingFlags.SYNC_CREATE | BindingFlags.BIDIRECTIONAL, (_, from, ref to) => {
                var str = (string) from;
                to = str ?? "";
                return true;
            });
            view.apply.connect(() => {
                password_view_model.changed();
            });

            return view;
        }

        var row_text = preferences_row as ViewModel.PreferencesRow.Text;
        if (row_text != null) {
            var view = new Adw.ActionRow() {
                use_markup = use_markup,
                title = row_text.title,
                subtitle_selectable = true
            };
            row_text.bind_property("text", view, "subtitle", BindingFlags.SYNC_CREATE, (_, from, ref to) => {
                var str = (string) from;
                to = str ?? "";
                return true;
            });
            view.title_lines = 0;
            view.subtitle_lines = 0;
            view.add_css_class("property");

            if (preferences_row.media_uri != null) {
                var bytes = Xmpp.get_data_for_uri(preferences_row.media_uri);
                try {
                    Picture picture = new Picture.for_paintable(Texture.from_bytes(bytes));
                    picture.vexpand = false;
                    picture.valign = Align.CENTER;
                    view.add_suffix(picture);
                } catch (Error e) {
                    warning("Failed to create texture from bytes: %s", e.message);
                }
            }

            Util.force_css(view, "row.property > box.header > box.title > .title { font-weight: 400; font-size: 9pt; opacity: 0.55; }");
            Util.force_css(view, "row.property > box.header > box.title > .subtitle { font-size: inherit; opacity: 1; }");
            return view;
        }

        var toggle_view_model = preferences_row as ViewModel.PreferencesRow.Toggle;
        if (toggle_view_model != null) {
            var view = new Adw.ActionRow() { use_markup = use_markup, title = toggle_view_model.title,
                subtitle = toggle_view_model.description == null ? toggle_view_model.subtitle :
                    field_help_text(toggle_view_model.subtitle, use_markup) };
            view.title_lines = 0;
            view.subtitle_lines = 0;
            var toggle = new Switch() { valign = Align.CENTER };
            view.activatable_widget = toggle;
            view.add_suffix(toggle);
            toggle_view_model.bind_property("state", toggle, "active", BindingFlags.SYNC_CREATE | BindingFlags.BIDIRECTIONAL);
            bind_preference_row_enabled(toggle_view_model, view);
            return view;
        }

        var number_view_model = preferences_row as ViewModel.PreferencesRow.Number;
        if (number_view_model != null) {
            var view = new Adw.SpinRow.with_range(number_view_model.minimum,
                number_view_model.maximum, 1) {
                use_markup = use_markup,
                title = number_view_model.title,
                subtitle = field_help_text(number_view_model.description, use_markup),
                digits = 0,
                numeric = true,
                snap_to_ticks = true,
                update_policy = Gtk.SpinButtonUpdatePolicy.ALWAYS,
                title_lines = 0,
                subtitle_lines = 0
            };
            number_view_model.bind_property("value", view, "value",
                BindingFlags.SYNC_CREATE | BindingFlags.BIDIRECTIONAL,
                (_, from, ref to) => {
                    to = (double) (int) from;
                    return true;
                }, (_, from, ref to) => {
                    to = (int) Math.round((double) from);
                    return true;
                });
            WeakRef view_weak = WeakRef(view);
            number_view_model.commit.connect(() => {
                var current_view = view_weak.get() as Adw.SpinRow;
                if (current_view != null) current_view.update();
            });
            bind_preference_row_enabled(number_view_model, view);
            return view;
        }

        var combobox_view_model = preferences_row as ViewModel.PreferencesRow.ComboBox;
        if (combobox_view_model != null) {
            var string_list = new StringList(null);
            foreach (string text in combobox_view_model.items) {
                string_list.append(text);
            }
            var view = new Adw.ComboRow() {
                use_markup = use_markup,
                title = combobox_view_model.title,
                subtitle = field_help_text(combobox_view_model.description, use_markup)
            };
            view.title_lines = 0;
            view.model = string_list;
            combobox_view_model.bind_property("active-item", view, "selected", BindingFlags.SYNC_CREATE | BindingFlags.BIDIRECTIONAL);
            return view;
        }

        var multi_text_view_model = preferences_row as ViewModel.PreferencesRow.MultiText;
        if (multi_text_view_model != null) {
            var view = new Adw.ActionRow() { use_markup = use_markup, title = multi_text_view_model.title };
            view.title_lines = 0;
            view.subtitle = multi_text_view_model.description == null || multi_text_view_model.description == "" ?
                _("One value per line") : "%s\n%s".printf(
                    (!) field_help_text(multi_text_view_model.description, use_markup), _("One value per line"));
            view.subtitle_lines = 0;
            var button = new Button.with_label(_("Edit")) { valign = Align.CENTER };
            view.add_suffix(button);
            button.clicked.connect(() => {
                var dialog = new Adw.Dialog();
                dialog.title = multi_text_view_model.title;
                dialog.content_width = 420;
                dialog.content_height = 360;

                var toolbar_view = new Adw.ToolbarView();
                var header_bar = new Adw.HeaderBar();
                toolbar_view.add_top_bar(header_bar);

                var done_button = new Button.with_label(_("Done"));
                done_button.add_css_class("suggested-action");
                header_bar.pack_end(done_button);

                var scrolled = new ScrolledWindow();
                scrolled.margin_top = 12;
                scrolled.margin_bottom = 12;
                scrolled.margin_start = 12;
                scrolled.margin_end = 12;
                scrolled.vexpand = true;
                scrolled.hexpand = true;

                var text_view = new TextView();
                text_view.monospace = false;
                text_view.wrap_mode = WrapMode.WORD_CHAR;
                text_view.buffer.text = multi_text_view_model.text ?? "";
                scrolled.set_child(text_view);

                toolbar_view.content = scrolled;
                dialog.child = toolbar_view;

                done_button.clicked.connect(() => {
                    TextIter start;
                    TextIter end;
                    text_view.buffer.get_bounds(out start, out end);
                    multi_text_view_model.text = text_view.buffer.get_text(start, end, false);
                    multi_text_view_model.changed();
                    dialog.close();
                });

                var app = GLib.Application.get_default() as Gtk.Application;
                dialog.present(app != null ? app.active_window : null);
            });
            return view;
        }

        var multi_check_view_model = preferences_row as ViewModel.PreferencesRow.MultiCheck;
        if (multi_check_view_model != null) {
            var expander = new Adw.ExpanderRow() {
                use_markup = use_markup,
                title = multi_check_view_model.title,
                subtitle = multi_check_view_model.description == null ? multi_check_view_model.subtitle :
                    field_help_text(multi_check_view_model.description, use_markup)
            };
            expander.title_lines = 0;
            for (int i = 0; i < multi_check_view_model.items.size; i++) {
                int index = i;
                var option_row = new Adw.ActionRow() { use_markup = use_markup, title = multi_check_view_model.items[i] };
                option_row.title_lines = 0;
                var toggle = new Switch() { valign = Align.CENTER, active = multi_check_view_model.states[i] };
                option_row.activatable_widget = toggle;
                option_row.add_suffix(toggle);
                toggle.notify["active"].connect(() => {
                    multi_check_view_model.states[index] = toggle.active;
                    multi_check_view_model.state_changed(index, toggle.active);
                });
                expander.add_row(option_row);
            }
            return expander;
        }

        var button_view_model = preferences_row as ViewModel.PreferencesRow.Button;
        if (button_view_model != null) {
            var view = new Adw.ActionRow() { use_markup = use_markup, title = button_view_model.title };
            view.title_lines = 0;
            view.subtitle_lines = 0;
            button_view_model.bind_property("description", view, "subtitle",
                BindingFlags.SYNC_CREATE, (_, from, ref to) => {
                    to = field_help_text((string?) from, use_markup) ?? "";
                    return true;
                });
            var button = new Button.with_label(button_view_model.button_text) { valign = Align.CENTER };
            view.add_suffix(button);
            button.clicked.connect(() => button_view_model.clicked());
            bind_preference_row_enabled(button_view_model, button);
            return view;
        }

        return null;
    }

    private void bind_preference_row_enabled(ViewModel.PreferencesRow.Any model,
            Gtk.Widget view) {
        view.sensitive = model.enabled;
        WeakRef model_weak = WeakRef(model);
        WeakRef view_weak = WeakRef(view);
        model.notify["enabled"].connect(() => {
            var current_model = model_weak.get() as ViewModel.PreferencesRow.Any;
            var current_view = view_weak.get() as Gtk.Widget;
            if (current_model == null || current_view == null) return;
            if (!current_model.enabled) clear_focus_before_detach(current_view);
            current_view.sensitive = current_model.enabled;
        });
    }

    private string? field_help_text(string? description, bool use_markup) {
        // Field descriptions are server text, including in other data-form
        // dialogs that allow markup for their existing titles.
        return description == null || !use_markup ? description : Markup.escape_text((!) description);
    }

    private void add_entry_field_help(Adw.EntryRow row, string? description) {
        if (description == null || description == "") return;
        var label = new Gtk.Label((!) description) {
            use_markup = false,
            wrap = true,
            selectable = true,
            max_width_chars = 50,
            margin_top = 12,
            margin_bottom = 12,
            margin_start = 12,
            margin_end = 12
        };
        var help = new Gtk.MenuButton() {
            icon_name = "dialog-information-symbolic",
            tooltip_text = _("Field help"),
            valign = Gtk.Align.CENTER
        };
        set_menu_button_popover(help, new Gtk.Popover() { child = label });
        row.add_suffix(help);
    }
}

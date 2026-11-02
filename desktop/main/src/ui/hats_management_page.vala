using Gtk;
using Xmpp;
using Xmpp.Xep;

namespace Dino.Ui.ConversationDetails {

public class HatChoice : Object {
    public string uri { get; set; }
    public string title { get; set; }
    public string? hue { get; set; }
}

public class AssignedHatChoice : HatChoice {
    public string jid { get; set; }
}

/** Drop dialog-owned callbacks on close, including closures holding the dialog. */
public class HatsDialogSignals : Object {
    private class Handler : Object {
        public WeakRef source;
        public ulong id;
        public Handler(Object source, ulong id) {
            this.source = WeakRef(source);
            this.id = id;
        }
    }
    private Gee.ArrayList<Handler> handlers = new Gee.ArrayList<Handler>();

    public static void track(Adw.Dialog dialog, Object source, ulong id) {
        HatsDialogSignals? connections = dialog.get_data<HatsDialogSignals>("hats-ui-signals");
        if (connections == null) {
            connections = new HatsDialogSignals();
            dialog.set_data<HatsDialogSignals>("hats-ui-signals", connections);
            var captured = connections;
            dialog.closed.connect(() => captured.disconnect_all());
        }
        connections.handlers.add(new Handler(source, id));
    }

    private void disconnect_all() {
        foreach (var handler in handlers) {
            Object? source = handler.source.get();
            if (source != null && SignalHandler.is_connected(source, handler.id)) {
                SignalHandler.disconnect(source, handler.id);
            }
        }
        handlers.clear();
    }
}

/** Server-owned command choices. A directory never expands a restricted form. */
public class HatFormChoices : Object {
    public static string new_uri() {
        return "urn:uuid:" + Uuid.string_random();
    }

    public static double? parse_hue(string? value) {
        double hue = 0;
        if (value == null || value.strip() == "" || !double.try_parse(value, out hue) ||
                !hue.is_finite() || hue < 0 || hue > 360) return null;
        return hue;
    }

    public static Gdk.RGBA hue_color(double hue) {
        float red, green, blue;
        Gtk.hsv_to_rgb((float) (hue / 360.0), 0.65f, 0.45f, out red, out green, out blue);
        return Gdk.RGBA() { red = red, green = green, blue = blue, alpha = 1 };
    }

    public static string color_hue(Gdk.RGBA color, string fallback) {
        float hue, saturation, value;
        Gtk.rgb_to_hsv(color.red, color.green, color.blue, out hue, out saturation, out value);
        // Achromatic colors have no hue: retain the existing hue instead of
        // unexpectedly changing a grey/black selection to red.
        return saturation < 0.0001f ? fallback : (hue * 360.0).to_string();
    }

    public static string picker_hue(Gtk.ColorDialogButton picker, string fallback) {
        // Use the pointer-returning getter: older gtk4 VAPIs misdeclare the
        // struct-valued property getter as an out parameter.
        unowned Gdk.RGBA? color = picker.get_rgba();
        return color != null ? color_hue((!) color, fallback) : fallback;
    }

    public static bool permits_value(DataForms.DataForm? form, string value, bool uri) {
        if (form == null) return false;
        foreach (var field in form.fields) {
            bool matches = uri ? (field.var == "hat" || field.var == "hat_uri" ||
                field.var == "hats#uri") : (field.var == "jid" || field.var == "hats#jid");
            if (!matches) continue;
            var single = field as DataForms.DataForm.ListSingleField;
            if (single != null) {
                foreach (var option in single.options) if (option.value == value) return true;
                return false;
            }
            if (field.type_ == DataForms.DataForm.Type.HIDDEN) {
                return field.get_values().contains(value);
            }
            return field.type_ == DataForms.DataForm.Type.TEXT_SINGLE;
        }
        return true;
    }

    public static bool permits_preset(DataForms.DataForm? form, Gee.List<HatChoice> allowed,
            Gee.List<AssignedHatChoice>? assigned, string? uri, string? jid, bool remove) {
        if (uri != null) {
            bool found = false;
            foreach (var hat in allowed) if (hat.uri == uri) found = true;
            if (!found || !permits_value(form, uri, true)) return false;
        }
        if (jid != null && !permits_value(form, jid, false)) return false;
        if (remove && jid != null && assigned != null) {
            foreach (var assignment in assigned) {
                if (assignment.uri == uri && assignment.jid == jid) return true;
            }
            return false;
        }
        return true;
    }

    public static bool can_render_specialized(DataForms.DataForm? form, bool create) {
        if (form == null) return false;
        foreach (var field in form.fields) {
            bool uri = field.var == "hat" || field.var == "hat_uri" || field.var == "hats#uri";
            bool known = uri || field.var == "jid" || field.var == "hats#jid" ||
                field.var == "hats#title" || field.var == "hats#hue";
            if (!known) continue;
            if (!create && uri && field is DataForms.DataForm.ListSingleField) continue;
            if (field.type_ != DataForms.DataForm.Type.TEXT_SINGLE) return false;
        }
        return true;
    }

    public static Gee.List<HatChoice> available(DataForms.DataForm? form,
            Gee.List<HatChoice> from_form, Gee.List<HatChoice>? directory) {
        bool restricted = false;
        if (form != null) {
            foreach (var field in form.fields) {
                if ((field.var == "hat" || field.var == "hat_uri" ||
                        field.var == "hats#uri") &&
                        field is DataForms.DataForm.ListSingleField) restricted = true;
            }
        }
        var result = new Gee.ArrayList<HatChoice>();
        foreach (var hat in from_form) result.add(hat);
        if (directory != null) {
            foreach (var hat in directory) {
                HatChoice? match = null;
                foreach (var candidate in result) {
                    if (candidate.uri == hat.uri) { match = candidate; break; }
                }
                if (match != null) {
                    match.title = hat.title;
                    match.hue = hat.hue;
                } else if (!restricted) {
                    result.add(hat);
                }
            }
        }
        return result;
    }
}

/** Room/account-scoped overview; all actions go through the guarded controller. */
public class HatsManagementPage : Adw.PreferencesPage {
    public signal void requested(string node, string? uri, string? jid);
    private Adw.PreferencesGroup definitions = new Adw.PreferencesGroup();
    private Adw.PreferencesGroup assignments = new Adw.PreferencesGroup();

    public HatsManagementPage(string room, string account) {
        margin_top = margin_bottom = margin_start = margin_end = 12;
        var scope = create_scope(room, account,
            _("Hats are visible labels such as Maintainer. They do not grant room permissions."));
        add(scope);
        definitions.title = _("Available Hats");
        definitions.description = _("Create a label, then assign it to people in this room.");
        assignments.title = _("Assigned Hats");
        assignments.description = _("Removing an assignment keeps the hat available for other people.");
        add(definitions);
        add(assignments);
        add_row(definitions, message_row(_("Loading…")));
    }

    public static Adw.PreferencesGroup create_scope(string room, string account,
            string? explanation = null) {
        var scope = new Adw.PreferencesGroup() { description = explanation };
        scope.add(new Adw.ActionRow() {
            use_markup = false, title = room,
            subtitle = _("Account: %s").printf(account),
            title_lines = 1, subtitle_lines = 1,
            tooltip_text = "%s\n%s".printf(room, account)
        });
        return scope;
    }

    private static Adw.ActionRow message_row(string text) {
        return new Adw.ActionRow() { title = text, use_markup = false };
    }

    private Gtk.Button action(string label, string node, string? uri = null,
            string? jid = null, string? icon = null) {
        var button = new Gtk.Button() { valign = Align.CENTER, tooltip_text = label };
        if (icon == null) button.label = label;
        else {
            button.icon_name = icon;
            button.update_property(AccessibleProperty.LABEL, label, -1);
        }
        connect_action(button, this, node, uri, jid);
        return button;
    }

    private static void connect_action(Gtk.Button button, HatsManagementPage source,
            string node, string? uri, string? jid) {
        WeakRef page_ref = WeakRef(source);
        button.clicked.connect(() => {
            var page = page_ref.get() as HatsManagementPage;
            if (page != null) page.requested(node, uri, jid);
        });
    }

    private static OccupantMenu.OccupantHatBadges badge(HatChoice hat) {
        var chips = new OccupantMenu.OccupantHatBadges();
        var hats = new Gee.ArrayList<Muc.Hat>();
        hats.add(new Muc.Hat() { uri = hat.uri, title = hat.title, hue = hat.hue });
        chips.set_hats(hats);
        chips.valign = Align.CENTER;
        chips.hexpand = false;
        return chips;
    }

    public void show_failure() {
        clear_group(definitions);
        clear_group(assignments);
        definitions.header_suffix = assignments.header_suffix = null;
        add_row(definitions, message_row(_("Available hats could not be loaded.")));
    }

    private static void clear_group(Adw.PreferencesGroup group) {
        // Only rows created by this page are tracked, never private Adwaita children.
        Gee.ArrayList<Widget>? rows = group.get_data<Gee.ArrayList<Widget>>("hats-rows");
        if (rows != null) foreach (var row in rows) group.remove(row);
        group.set_data<Gee.ArrayList<Widget>>("hats-rows", new Gee.ArrayList<Widget>());
    }

    private static void add_row(Adw.PreferencesGroup group, Widget row) {
        Gee.ArrayList<Widget>? rows = group.get_data<Gee.ArrayList<Widget>>("hats-rows");
        if (rows == null) {
            rows = new Gee.ArrayList<Widget>();
            group.set_data<Gee.ArrayList<Widget>>("hats-rows", rows);
        }
        rows.add(row);
        group.add(row);
    }

    public void show_content(Gee.Set<string> nodes, Gee.List<HatChoice>? hats,
            Gee.List<AssignedHatChoice>? assigned) {
        clear_group(definitions);
        clear_group(assignments);
        definitions.header_suffix = assignments.header_suffix = null;
        if (nodes.contains("urn:xmpp:hats:commands:create")) {
            definitions.header_suffix = action(_("Create Hat"), "urn:xmpp:hats:commands:create");
        }
        if (nodes.contains("urn:xmpp:hats:commands:assign")) {
            assignments.header_suffix = action(_("Assign Hat"), "urn:xmpp:hats:commands:assign");
        }
        if (!nodes.contains("urn:xmpp:hats:commands:list")) {
            add_row(definitions, message_row(_("This server does not offer a hat overview.")));
            if (nodes.contains("urn:xmpp:hats:commands:destroy")) {
                var row = message_row(_("Delete Hat from Room"));
                row.add_suffix(action(_("Delete"), "urn:xmpp:hats:commands:destroy"));
                add_row(definitions, row);
            }
        } else if (hats == null) {
            add_row(definitions, message_row(_("Available hats could not be loaded.")));
        } else if (hats.size == 0) {
            add_row(definitions, message_row(_("No hats are available in this room.")));
        } else {
            foreach (var hat in hats) {
                var row = new Adw.ActionRow() { use_markup = false, title_lines = 1 };
                row.update_property(AccessibleProperty.LABEL, hat.title, -1);
                row.add_prefix(badge(hat));
                if (nodes.contains("urn:xmpp:hats:commands:create")) {
                    // XEP-0317 updates a definition through create with its existing URI.
                    row.add_suffix(action(_("Edit Hat"), "urn:xmpp:hats:commands:create",
                        hat.uri, null, "document-edit-symbolic"));
                }
                if (nodes.contains("urn:xmpp:hats:commands:assign")) {
                    row.add_suffix(action(_("Assign"), "urn:xmpp:hats:commands:assign", hat.uri));
                }
                if (nodes.contains("urn:xmpp:hats:commands:destroy")) {
                    row.add_suffix(action(_("Delete Hat from Room"), "urn:xmpp:hats:commands:destroy",
                        hat.uri, null, "user-trash-symbolic"));
                }
                add_row(definitions, row);
            }
        }
        if (!nodes.contains("urn:xmpp:hats:commands:list-assigned")) {
            add_row(assignments, message_row(_("This server does not offer an assignment overview.")));
            if (nodes.contains("urn:xmpp:hats:commands:unassign")) {
                var row = message_row(_("Remove Hat Assignment"));
                row.add_suffix(action(_("Remove Assignment"), "urn:xmpp:hats:commands:unassign"));
                add_row(assignments, row);
            }
        } else if (assigned == null) {
            add_row(assignments, message_row(_("Assigned hats could not be loaded.")));
        } else if (assigned.size == 0) {
            add_row(assignments, message_row(_("No hats are assigned in this room.")));
        } else {
            foreach (var assignment in assigned) {
                var row = new Adw.ActionRow() { use_markup = false,
                    title = assignment.jid, title_lines = 1 };
                row.add_prefix(badge(assignment));
                if (nodes.contains("urn:xmpp:hats:commands:create") &&
                        nodes.contains("urn:xmpp:hats:commands:list")) {
                    row.add_suffix(action(_("Edit Hat"), "urn:xmpp:hats:commands:create",
                        assignment.uri, null, "document-edit-symbolic"));
                }
                if (nodes.contains("urn:xmpp:hats:commands:unassign")) {
                    row.add_suffix(action(_("Remove Hat Assignment"), "urn:xmpp:hats:commands:unassign",
                        assignment.uri, assignment.jid, "list-remove-symbolic"));
                }
                add_row(assignments, row);
            }
        }
    }
}
}

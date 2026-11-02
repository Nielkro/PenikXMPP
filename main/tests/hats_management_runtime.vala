using Dino.Ui.ConversationDetails;
using Dino.Ui.OccupantMenu;
using Gtk;
using Xmpp;
using Xmpp.Xep;

namespace Dino.Ui.Test {

// Actual management widgets and server-owned form choices, without connected
// accounts, command submission, or reads from a real user profile.
class HatsManagementRuntimeTest : Gee.TestCase {
    private const string CREATE = "urn:xmpp:hats:commands:create";
    private const string ASSIGN = "urn:xmpp:hats:commands:assign";
    private const string UNASSIGN = "urn:xmpp:hats:commands:unassign";
    private const string DESTROY = "urn:xmpp:hats:commands:destroy";
    private const string LIST = "urn:xmpp:hats:commands:list";
    private const string LIST_ASSIGNED = "urn:xmpp:hats:commands:list-assigned";

    public HatsManagementRuntimeTest() {
        base("HatsManagementRuntime");
        add_test("new_definitions_never_reuse_title_based_uris", test_new_uris);
        add_test("command_options_cannot_be_expanded_by_directory", test_restricted_choices);
        add_test("free_uri_fields_can_use_directory_choices", test_free_choices);
        add_test("hue_zero_is_distinct_from_missing_or_invalid_color", test_hue);
        add_test("literal_scope_badges_and_actions_carry_exact_targets", test_page_actions);
        add_test("empty_unknown_and_failed_overviews_are_distinct", test_overview_states);
        add_test("refresh_retires_old_capabilities_and_assignments", test_refresh);
        add_test("retained_actions_do_not_keep_closed_pages_alive", test_lifetime);
        add_test("stale_shortcuts_cannot_restore_restricted_hat_targets", test_restricted_presets);
        add_test("server_jid_hidden_and_multi_fields_preserve_form_authority", test_field_authority);
        add_test("native_dialog_close_disconnects_callbacks_holding_the_dialog", test_dialog_signals);
        add_test("real_management_page_fits_small_themed_rtl_windows", test_layout);
    }

    private static Gee.Set<string> nodes(bool mutation = true) {
        var values = new Gee.HashSet<string>();
        values.add(LIST);
        values.add(LIST_ASSIGNED);
        if (mutation) {
            values.add(CREATE);
            values.add(ASSIGN);
            values.add(UNASSIGN);
            values.add(DESTROY);
        }
        return values;
    }

    private static Gee.List<HatChoice> definitions(string title = "Maintainer") {
        var values = new Gee.ArrayList<HatChoice>();
        values.add(new HatChoice() {
            uri = "urn:example:hat:maintainer", title = title, hue = "225"
        });
        return values;
    }

    private static Gee.List<AssignedHatChoice> assignments(string title = "Maintainer") {
        var values = new Gee.ArrayList<AssignedHatChoice>();
        values.add(new AssignedHatChoice() {
            uri = "urn:example:hat:maintainer", title = title, hue = "225",
            jid = "member@example.test"
        });
        return values;
    }

    private static void settle(uint milliseconds = 100) {
        int64 deadline = get_monotonic_time() + milliseconds * 1000;
        while (get_monotonic_time() < deadline) {
            if (MainContext.default().pending()) MainContext.default().iteration(false);
            else Thread.usleep(1000);
        }
    }

    private static void descendants(Widget root, Gee.List<Widget> result) {
        result.add(root);
        for (Widget? child = root.get_first_child(); child != null;
                child = child.get_next_sibling()) descendants(child, result);
    }

    private static Gee.List<Widget> widgets(Widget root) {
        var result = new Gee.ArrayList<Widget>();
        descendants(root, result);
        return result;
    }

    private static Adw.ActionRow? row(Widget root, string title) {
        foreach (var child in widgets(root)) {
            var candidate = child as Adw.ActionRow;
            if (candidate != null && candidate.title == title) return candidate;
        }
        return null;
    }

    private static Button? button(Widget root, string tooltip) {
        foreach (var child in widgets(root)) {
            var candidate = child as Button;
            if (candidate != null && candidate.tooltip_text == tooltip) return candidate;
        }
        return null;
    }

    private static OccupantHatBadges? badges(Widget root) {
        foreach (var child in widgets(root)) {
            if (child is OccupantHatBadges) return (OccupantHatBadges) child;
        }
        return null;
    }

    private static bool contains_badge_text(Widget root, string text) {
        foreach (var child in widgets(root)) {
            if (!(child is OccupantHatBadges)) continue;
            foreach (var descendant in widgets(child)) {
                if (descendant is Label && ((Label) descendant).label == text) return true;
            }
        }
        return false;
    }

    private static Adw.ActionRow? definition_row(Widget root, string title) {
        foreach (var child in widgets(root)) {
            var candidate = child as Adw.ActionRow;
            if (candidate != null && candidate.title == "" &&
                    contains_badge_text(candidate, title)) return candidate;
        }
        return null;
    }

    private void test_new_uris() {
        // The generator deliberately has no title input: an accented spelling,
        // identical label, or non-Latin label must not update another Hat URI.
        var unique = new Gee.HashSet<string>();
        for (int i = 0; i < 100; i++) {
            string uri = HatFormChoices.new_uri();
            fail_if_not(uri.has_prefix("urn:uuid:"));
            fail_if_not(Uuid.string_is_valid(uri.substring("urn:uuid:".length)));
            fail_if_not(unique.add(uri), "creating another definition must never reuse its predecessor's URI");
        }
        fail_if(unique.contains("urn:dinox:hat:maintainer"));
        fail_if(unique.contains("urn:dinox:hat:hat"));
    }

    private static DataForms.DataForm form(string type, string field_var) {
        var node = new StanzaNode.build("x", DataForms.NS_URI)
            .put_attribute("type", "form");
        var field = new StanzaNode.build("field", DataForms.NS_URI)
            .put_attribute("type", type).put_attribute("var", field_var);
        if (type == "list-single") {
            field.put_node(new StanzaNode.build("option", DataForms.NS_URI)
                .put_attribute("label", "Server's allowed label")
                .put_node(new StanzaNode.build("value", DataForms.NS_URI)
                    .put_node(new StanzaNode.text("urn:example:allowed"))));
        }
        node.put_node(field);
        DataForms.DataForm? parsed = DataForms.DataForm.create_from_node(node);
        fail_if(parsed == null, "the actual public data-form parser must accept the server fixture");
        return parsed ?? new DataForms.DataForm();
    }

    private void test_restricted_choices() {
        foreach (string field_var in new string[] { "hat", "hats#uri", "hat_uri" }) {
            var source = new Gee.ArrayList<HatChoice>();
            source.add(new HatChoice() { uri = "urn:example:allowed", title = "Server's allowed label" });
            var directory = new Gee.ArrayList<HatChoice>();
            directory.add(new HatChoice() { uri = "urn:example:allowed", title = "Maintainer", hue = "225" });
            directory.add(new HatChoice() { uri = "urn:example:forbidden", title = "Not offered", hue = "35" });
            var restricted = form("list-single", field_var);
            var actual = HatFormChoices.available(restricted, source, directory);
            fail_if_not_eq_int(1, actual.size,
                "the command form's options constrain the selectable URI set");
            if (actual.size != 1) continue;
            fail_if_not_eq_str("urn:example:allowed", actual[0].uri);
            fail_if_not_eq_str("Maintainer", actual[0].title);
            fail_if_not_eq_str("225", actual[0].hue ?? "");
            var none = HatFormChoices.available(restricted,
                new Gee.ArrayList<HatChoice>(), directory);
            fail_if_not_eq_int(0, none.size,
                "an empty restricted choice set cannot become the complete room directory");
            fail_if_not_eq_str("urn:example:forbidden", directory[1].uri);
        }
    }

    private void test_free_choices() {
        var directory = definitions();
        foreach (DataForms.DataForm? source in new DataForms.DataForm?[] {
                null, form("text-single", "hats#uri") }) {
            var actual = HatFormChoices.available(source,
                new Gee.ArrayList<HatChoice>(), directory);
            fail_if_not_eq_int(1, actual.size);
            if (actual.size == 1) fail_if_not_eq_str(directory[0].uri, actual[0].uri);
        }
    }

    private void test_hue() {
        double? red = HatFormChoices.parse_hue("0");
        double? decimal = HatFormChoices.parse_hue("327.255249");
        fail_if(red == null || (!) red != 0,
            "a valid red hue cannot be confused with a missing neutral color");
        fail_if(decimal == null || Math.fabs((!) decimal - 327.255249) > 0.000001);
        fail_if(HatFormChoices.parse_hue(null) != null);
        foreach (string invalid in new string[] { "", "NaN", "inf", "-1", "361", "#f00", "0; color: red" }) {
            fail_if(HatFormChoices.parse_hue(invalid) != null,
                "invalid server metadata must not become a numeric color or CSS source");
        }
    }

    private void test_restricted_presets() {
        var restricted = form("list-single", "hat");
        var allowed = new Gee.ArrayList<HatChoice>();
        allowed.add(new HatChoice() { uri = "urn:example:allowed", title = "Allowed" });
        var assigned = new Gee.ArrayList<AssignedHatChoice>();
        assigned.add(new AssignedHatChoice() {
            uri = "urn:example:stale", title = "Stale", jid = "member@example.test"
        });
        fail_if(HatFormChoices.permits_preset(restricted, allowed, assigned,
            "urn:example:stale", "member@example.test", true),
            "an assignment still present on the server cannot restore a Hat URI removed from this command's choices");
        assigned.add(new AssignedHatChoice() {
            uri = "urn:example:allowed", title = "Allowed", jid = "member@example.test"
        });
        fail_if_not(HatFormChoices.permits_preset(restricted, allowed, assigned,
            "urn:example:allowed", "member@example.test", true));
        fail_if(HatFormChoices.permits_preset(restricted, allowed, assigned,
            "urn:example:allowed", "gone@example.test", true),
            "a removed person's assignment cannot fall back to the first remaining person");
        fail_if(HatFormChoices.permits_preset(restricted, allowed, assigned,
            "urn:example:stale", null, false),
            "assign and delete row shortcuts must also respect the current URI restrictions");
        fail_if_not(HatFormChoices.permits_preset(restricted, allowed, assigned,
            null, null, false), "opening a generic task does not require a row preset");
    }

    private static DataForms.DataForm field_form(string type, string field_var,
            string value) {
        var node = new StanzaNode.build("x", DataForms.NS_URI)
            .put_attribute("type", "form");
        var field = new StanzaNode.build("field", DataForms.NS_URI)
            .put_attribute("type", type).put_attribute("var", field_var);
        if (type == "list-single") {
            field.put_node(new StanzaNode.build("option", DataForms.NS_URI)
                .put_attribute("label", "Server's allowed target")
                .put_node(new StanzaNode.build("value", DataForms.NS_URI)
                    .put_node(new StanzaNode.text(value))));
        } else {
            field.put_node(new StanzaNode.build("value", DataForms.NS_URI)
                .put_node(new StanzaNode.text(value)));
        }
        node.put_node(field);
        DataForms.DataForm? parsed = DataForms.DataForm.create_from_node(node);
        fail_if(parsed == null);
        return parsed ?? new DataForms.DataForm();
    }

    private void test_field_authority() {
        foreach (string field_var in new string[] { "jid", "hats#jid" }) {
            var restricted = field_form("list-single", field_var, "allowed@example.test");
            fail_if_not(HatFormChoices.permits_value(restricted, "allowed@example.test", false));
            fail_if(HatFormChoices.permits_value(restricted, "other@example.test", false),
                "manual JID entry cannot expand the server's user choice set");
            fail_if(HatFormChoices.can_render_specialized(restricted, false),
                "restricted JID selectors use the server's original form renderer");
            var hidden = field_form("hidden", field_var, "fixed@example.test");
            fail_if_not(HatFormChoices.permits_value(hidden, "fixed@example.test", false));
            fail_if(HatFormChoices.permits_value(hidden, "other@example.test", false));
            fail_if(HatFormChoices.can_render_specialized(hidden, false),
                "a hidden user target cannot become an editable specialized selector");
            foreach (string type in new string[] { "jid-multi", "list-multi" }) {
                var multi = field_form(type, field_var, "allowed@example.test");
                fail_if(HatFormChoices.can_render_specialized(multi, false));
                fail_if(HatFormChoices.permits_value(multi, "allowed@example.test", false),
                    "a multi-value server field cannot be overwritten as a single user address");
            }
            var ordinary = field_form("jid-single", field_var, "");
            fail_if_not(HatFormChoices.can_render_specialized(ordinary, false),
                "the public data-form parser preserves ejabberd's ordinary jid-single semantics");
            fail_if_not(HatFormChoices.permits_value(ordinary, "offline@example.test", false));
        }
        var limited_uri = field_form("list-single", "hats#uri", "urn:example:allowed");
        fail_if_not(HatFormChoices.can_render_specialized(limited_uri, false));
        fail_if(HatFormChoices.can_render_specialized(limited_uri, true),
            "Create cannot overwrite a server's fixed URI choices with a fresh UUID");
        var hidden_uri = field_form("hidden", "hats#uri", "urn:example:fixed");
        fail_if(HatFormChoices.can_render_specialized(hidden_uri, true));
        fail_if_not(HatFormChoices.permits_value(hidden_uri, "urn:example:fixed", true));
        fail_if(HatFormChoices.permits_value(hidden_uri, "urn:example:other", true));
        fail_if(HatFormChoices.permits_value(null, "urn:example:other", true));
    }

    private static void wire_and_close_dialog(Adw.Window window,
            Button retained, out ulong handler, ref WeakRef observer) {
        var dialog = new Adw.Dialog() { title = "Before callback" };
        var body = new Box(Orientation.VERTICAL, 0);
        body.append(retained);
        dialog.child = body;
        // Deliberately capture the actual dialog strongly, like a submit
        // callback. Its registered close hook must break this native cycle.
        handler = retained.clicked.connect(() => { dialog.title = "Callback ran"; });
        HatsDialogSignals.track(dialog, retained, handler);
        // GWeakRef is address-bound: initialize the caller's storage in place,
        // rather than returning/copying a weak-ref struct from this helper.
        observer.set(dialog);
        dialog.present(window);
        settle();
        retained.clicked();
        fail_if_not_eq_str("Callback ran", dialog.title);
        dialog.force_close();
        int64 deadline = get_monotonic_time() + 2000000;
        while (dialog.get_mapped() && get_monotonic_time() < deadline) {
            if (MainContext.default().pending()) MainContext.default().iteration(false);
            else Thread.usleep(1000);
        }
        settle();
        fail_if(dialog.get_mapped(), "the actual Adw.Dialog close lifecycle must have completed");
    }

    private void test_dialog_signals() {
        var window = new Adw.Window();
        try {
            window.content = new Box(Orientation.VERTICAL, 0);
            window.set_default_size(500, 500);
            window.present(); settle();
            var retained = new Button.with_label("Local-only action");
            ulong handler;
            var dialog_ref = WeakRef(null);
            wire_and_close_dialog(window, retained, out handler, ref dialog_ref);
            settle();
            fail_if(SignalHandler.is_connected(retained, handler),
                "closing the actual dialog disconnects its tracked widget callback");
            fail_if(dialog_ref.get() != null,
                "a retained button must not keep the closed native dialog and account context alive");
            retained.clicked();
        } finally { window.destroy(); settle(); }
    }

    private void test_page_actions() {
        string literal = "<Maintainer> & Support";
        var page = new HatsManagementPage("<Room> & Team", "first@example.test");
        page.show_content(nodes(), definitions(literal), assignments(literal));
        var scope = row(page, "<Room> & Team");
        if (fail_if(scope == null)) return;
        fail_if(scope.use_markup);
        fail_if_not_eq_str(_("Account: %s").printf("first@example.test"), scope.subtitle);
        var definition = definition_row(page, literal);
        var assignment = row(page, "member@example.test");
        if (fail_if(definition == null || assignment == null)) return;
        fail_if(definition.use_markup || assignment.use_markup);
        foreach (Adw.ActionRow item in new Adw.ActionRow[] { definition, assignment }) {
            var chips = badges(item);
            if (fail_if(chips == null || chips.count != 1)) continue;
            var chip = chips.get_first_child();
            var label = chip.get_last_child() as Label;
            fail_if(label == null || label.label != literal || label.use_markup,
                "the actual badge preserves the literal Hat title");
            fail_if_not(chip.has_css_class("hat-tone-225"),
                "the overview's real badge retains its server color");
        }
        var requests = new Gee.ArrayList<string>();
        page.requested.connect((node, uri, jid) => {
            requests.add(node + "|" + (uri ?? "") + "|" + (jid ?? ""));
        });
        var create = button(page, _("Create Hat"));
        var edit = button(definition, _("Edit Hat"));
        var assign = button(definition, _("Assign"));
        var destroy = button(definition, _("Delete Hat from Room"));
        var unassign = button(assignment, _("Remove Hat Assignment"));
        var edit_assigned = button(assignment, _("Edit Hat"));
        if (fail_if(create == null || edit == null || assign == null || destroy == null || unassign == null || edit_assigned == null)) return;
        create.clicked(); assign.clicked(); destroy.clicked(); unassign.clicked(); edit.clicked(); edit_assigned.clicked();
        fail_if_not_eq_int(6, requests.size);
        if (requests.size == 6) {
            fail_if_not_eq_str(CREATE + "||", requests[0]);
            fail_if_not_eq_str(ASSIGN + "|urn:example:hat:maintainer|", requests[1]);
            fail_if_not_eq_str(DESTROY + "|urn:example:hat:maintainer|", requests[2]);
            fail_if_not_eq_str(UNASSIGN + "|urn:example:hat:maintainer|member@example.test", requests[3]);
            fail_if_not_eq_str(CREATE + "|urn:example:hat:maintainer|", requests[4]);
            fail_if_not_eq_str(CREATE + "|urn:example:hat:maintainer|", requests[5],
                "editing an assigned badge updates its definition and preserves the assignment");
        }
        var other = new HatsManagementPage("<Room> & Team", "second@example.test");
        other.show_content(nodes(false), definitions("Second account"), new Gee.ArrayList<AssignedHatChoice>());
        fail_if(button(other, _("Edit Hat")) != null,
            "editing requires the server's create/update capability");
        fail_if_not_eq_str(_("Account: %s").printf("second@example.test"),
            row(other, "<Room> & Team").subtitle);
        fail_if(contains_badge_text(page, "Second account") || contains_badge_text(other, literal),
            "same-room overview instances must not share their account's projected state");
    }

    private void test_overview_states() {
        var page = new HatsManagementPage("Room", "first@example.test");
        page.show_content(nodes(), new Gee.ArrayList<HatChoice>(),
            new Gee.ArrayList<AssignedHatChoice>());
        fail_if(row(page, _("No hats are available in this room.")) == null);
        fail_if(row(page, _("No hats are assigned in this room.")) == null);
        var unsupported = new Gee.HashSet<string>();
        unsupported.add(DESTROY); unsupported.add(UNASSIGN);
        page.show_content(unsupported, null, null);
        fail_if(row(page, _("This server does not offer a hat overview.")) == null);
        fail_if(row(page, _("This server does not offer an assignment overview.")) == null);
        fail_if(row(page, _("No hats are assigned in this room.")) != null);
        fail_if(button(page, _("Delete")) == null || button(page, _("Remove Assignment")) == null,
            "servers without overview commands must retain their advertised form actions");
        page.show_content(nodes(false), null, null);
        fail_if(row(page, _("Available hats could not be loaded.")) == null);
        fail_if(row(page, _("Assigned hats could not be loaded.")) == null);
        fail_if(row(page, _("This server does not offer a hat overview.")) != null);
    }

    private void test_refresh() {
        var page = new HatsManagementPage("Room", "first@example.test");
        page.show_content(nodes(), definitions(), assignments());
        page.show_content(nodes(false), definitions("Read-only"), new Gee.ArrayList<AssignedHatChoice>());
        fail_if(button(page, _("Create Hat")) != null || button(page, _("Assign Hat")) != null,
            "retired command capabilities cannot retain actionable header buttons");
        fail_if(contains_badge_text(page, "Maintainer") || row(page, "member@example.test") != null,
            "refresh replaces definitions and assignments instead of accumulating stale rows");
        page.show_content(nodes(), definitions(), assignments());
        page.show_failure();
        fail_if(row(page, "member@example.test") != null,
            "a failed refresh cannot keep an old assignment presented as current");
        fail_if(button(page, _("Create Hat")) != null || button(page, _("Assign Hat")) != null,
            "a failed discovery cannot keep previous command buttons armed");
    }

    private void test_lifetime() {
        HatsManagementPage? page = new HatsManagementPage("Room", "first@example.test");
        page.show_content(nodes(), definitions(), assignments());
        Button? retained = button(page, _("Create Hat"));
        if (fail_if(retained == null)) return;
        int requests = 0;
        page.requested.connect(() => { requests++; });
        var page_ref = WeakRef(page);
        page = null;
        settle();
        fail_if(page_ref.get() != null,
            "retaining a native action must not retain the overview or its room scope");
        retained.clicked();
        fail_if_not_eq_int(0, requests,
            "an action retained after close cannot dispatch to the discarded page");
    }

    private static void check_bounds(Widget widget, Widget ancestor) {
        if (!widget.get_visible() || !widget.get_mapped()) return;
        if (widget is Button || widget is OccupantHatBadges || widget is Adw.ActionRow) {
            Graphene.Rect bounds;
            fail_if_not(widget.compute_bounds(ancestor, out bounds));
            fail_if(bounds.origin.x < -0.5f || bounds.origin.x + bounds.size.width > ancestor.get_width() + 0.5f,
                "actual management controls and badges must fit their narrow content allocation");
        }
        for (Widget? child = widget.get_first_child(); child != null;
                child = child.get_next_sibling()) check_bounds(child, ancestor);
    }

    private static void capture(Adw.Window window, string name) {
        string? directory = Environment.get_variable("DINOX_HATS_CAPTURE_DIR");
        if (directory == null) return;
        DirUtils.create_with_parents(directory, 0700);
        settle(200);
        var snapshot = new Snapshot();
        // Include the real Adw.Window background; a page-only paintable has
        // transparent areas and cannot prove its text/background contrast.
        new WidgetPaintable(window).snapshot(snapshot, window.get_width(), window.get_height());
        var node = snapshot.to_node();
        var renderer = window.get_renderer();
        if (fail_if(node == null || renderer == null,
                "the native management page must provide a real rendered frame")) return;
        var texture = renderer.render_texture(node, null);
        fail_if_not(texture.save_to_png(Path.build_filename(directory, name + ".png")));
    }

    private void test_layout() {
        var manager = Adw.StyleManager.get_default();
        var previous_scheme = manager.color_scheme;
        var previous_direction = Widget.get_default_direction();
        try {
            foreach (Adw.ColorScheme scheme in new Adw.ColorScheme[] {
                    Adw.ColorScheme.FORCE_LIGHT, Adw.ColorScheme.FORCE_DARK }) {
                manager.color_scheme = scheme;
                foreach (TextDirection direction in new TextDirection[] { TextDirection.LTR, TextDirection.RTL }) {
                    Widget.set_default_direction(direction);
                    foreach (int width in new int[] { 320, 500 }) {
                        var window = new Adw.Window();
                        try {
                            window.add_css_class("dino-main");
                            var page = new HatsManagementPage(
                                "A_long_unbroken_room_name_" + string.nfill(100, 'r'),
                                "a-long-multi-account-address-with-explicit-current-account@example.test");
                            var hats = definitions("Maintainer");
                            hats.add(new HatChoice() { uri = "urn:example:long", title = string.nfill(120, 'x'), hue = "35" });
                            var assigned = assignments();
                            assigned.add(new AssignedHatChoice() {
                                uri = "urn:example:long", title = string.nfill(120, 'x'), hue = "35",
                                jid = string.nfill(100, 'u') + "@example.test"
                            });
                            page.show_content(nodes(), hats, assigned);
                            var toolbar = new Adw.ToolbarView();
                            var header = new Adw.HeaderBar();
                            header.title_widget = new Adw.WindowTitle(_("Manage Hats"), "");
                            toolbar.add_top_bar(header);
                            toolbar.content = page;
                            window.content = toolbar;
                            window.set_default_size(width, 720);
                            window.present(); settle();
                            int minimum, natural;
                            toolbar.measure(Orientation.HORIZONTAL, -1, out minimum, out natural, null, null);
                            GLib.Test.message("Hats page target=%d actual=%d minimum=%d natural=%d",
                                width, window.get_width(), minimum, natural);
                            fail_if(window.get_width() > width + 1 || minimum > width,
                                "a real management page cannot enlarge the user's 320/500px window");
                            check_bounds(page, page);
                            capture(window, "management-%d-%s-%s".printf(width,
                                scheme == Adw.ColorScheme.FORCE_DARK ? "dark" : "light",
                                direction == TextDirection.RTL ? "rtl" : "ltr"));
                        } finally { window.destroy(); settle(); }
                    }
                }
            }
        } finally {
            manager.color_scheme = previous_scheme;
            Widget.set_default_direction(previous_direction);
        }
    }
}
}

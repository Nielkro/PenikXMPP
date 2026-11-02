using Dino.Entities;
using Dino.Security;
using Dino.Ui.OccupantMenu;
using Gtk;
using Xmpp;

namespace Dino.Ui.Test {

[CCode (cname = "gtk_test_accessible_check_property", cheader_filename = "gtk/gtk.h")]
private static extern string? check_hat_accessible_property(Accessible accessible,
    AccessibleProperty property, ...);

class OccupantHatBadgesRuntimeTest : Gee.TestCase {
    public OccupantHatBadgesRuntimeTest() {
        base("OccupantHatBadgesRuntime");
        add_test("real_chips_keep_plain_titles_icons_and_accessible_names", test_content);
        add_test("chips_wrap_compactly_in_both_themes_and_directions", test_layout);
        add_test("recycled_rows_clear_hats_and_disconnect_previous_items", test_rebind);
        add_test("item_updates_do_not_keep_discarded_rows_alive", test_lifetime);
        add_test("server_hues_use_a_bounded_palette_with_safe_fallback", test_hues);
        add_test("native_member_rows_keep_small_avatars_and_bounded_badges", test_member_rows);
    }

    private static Gee.List<Xep.Muc.Hat> hats(string title = "Maintainer") {
        var hats = new Gee.ArrayList<Xep.Muc.Hat>();
        hats.add(new Xep.Muc.Hat() { title = title, uri = "urn:example:maintainer" });
        return hats;
    }

    private static void settle() {
        int64 until = get_monotonic_time() + 60000;
        while (get_monotonic_time() < until) {
            if (MainContext.default().pending()) MainContext.default().iteration(false);
            else Thread.usleep(1000);
        }
    }

    private void test_content() {
        var badges = new OccupantHatBadges();
        var values = hats("<b>Support & Team</b>");
        badges.set_hats(values);
        var chip = badges.get_first_child() as Box;
        if (fail_if(chip == null)) return;
        var icon = chip.get_first_child() as Image;
        if (fail_if(icon == null)) return;
        var label = icon.get_next_sibling() as Label;
        if (fail_if(label == null)) return;
        fail_if_not_eq_str("dino-hat-symbolic", icon.icon_name);
        fail_if_not(IconTheme.get_for_display(Gdk.Display.get_default())
            .has_icon("dino-hat-symbolic"), "the bundled tag icon must resolve on every platform");
        fail_if_not_eq_str("<b>Support & Team</b>", label.label,
            "server titles are plain text, never executable Pango markup");
        fail_if(label.use_markup);
        fail_if_not_eq_str("<b>Support & Team</b>", chip.tooltip_text);
        if (Environment.get_variable("GTK_A11Y") != "none") {
            string? failure = check_hat_accessible_property(chip,
                AccessibleProperty.LABEL, "<b>Support & Team</b>");
            fail_if(failure != null, failure);
        }
        values[0].title = "Changed externally";
        fail_if_not_eq_str("<b>Support & Team</b>", label.label,
            "model mutations cannot silently change an existing row");
        badges.set_hats(values);
        fail_if_not_eq_str("Changed externally",
            ((Label) badges.get_first_child().get_last_child()).label);
        values[0].uri = "urn:example:updated";
        badges.set_hats(values);
        fail_if_not_eq_str("Changed externally",
            badges.get_first_child().tooltip_text,
            "protocol identifiers do not appear in ordinary member tooltips");
        badges.clear();
        fail_if_not_eq_int(0, badges.count);
        fail_if(badges.get_first_child() != null);
        badges.dispose();
    }

    private void test_hues() {
        fail_if_not_eq_str("hat-tone-0", OccupantHatBadges.get_hue_css_class("0"));
        fail_if_not_eq_str("hat-tone-0", OccupantHatBadges.get_hue_css_class("360"));
        fail_if_not_eq_str("hat-tone-16", OccupantHatBadges.get_hue_css_class("16"));
        fail_if_not_eq_str("hat-tone-330", OccupantHatBadges.get_hue_css_class("330"));
        fail_if_not_eq_str("hat-tone-137", OccupantHatBadges.get_hue_css_class("137.125"));
        foreach (string value in new string[] { "", "NaN", "inf", "-1", "361", "#ff0000", "0; color: red" }) {
            fail_if(OccupantHatBadges.get_hue_css_class(value) != null,
                "malformed or nonfinite metadata uses the default readable badge color");
        }
        fail_if(OccupantHatBadges.get_hue_css_class(null) != null);
        var badges = new OccupantHatBadges();
        var values = hats();
        badges.set_hats(values);
        fail_if(badges.get_first_child().has_css_class("hat-tone-0"),
            "no hue must remain distinct from the valid hue zero");
        values[0].hue = "0";
        badges.set_hats(values);
        fail_if_not(badges.get_first_child().has_css_class("hat-tone-0"));
        badges.dispose();
    }

    private void test_layout() {
        var manager = Adw.StyleManager.get_default();
        var previous_scheme = manager.color_scheme;
        var previous_direction = Widget.get_default_direction();
        try {
            foreach (var scheme in new Adw.ColorScheme[] {
                    Adw.ColorScheme.FORCE_LIGHT, Adw.ColorScheme.FORCE_DARK }) {
                manager.color_scheme = scheme;
                foreach (var direction in new TextDirection[] { TextDirection.LTR, TextDirection.RTL }) {
                    Widget.set_default_direction(direction);
                    var values = hats();
                    values.add(new Xep.Muc.Hat() { title = "Support", uri = "urn:example:support" });
                    values.add(new Xep.Muc.Hat() { title = string.nfill(200, 'x'), uri = "urn:example:long" });
                    foreach (int width in new int[] { 160, 280 }) {
                        var window = new Adw.Window();
                        try {
                            window.add_css_class("dino-main");
                            var badges = new OccupantHatBadges();
                            badges.set_hats(values);
                            var host = new Box(Orientation.VERTICAL, 0) { valign = Align.START };
                            host.append(badges);
                            window.content = host;
                            window.set_default_size(width, 130);
                            window.present();
                            settle();
                            fail_if(window.get_width() > width,
                                "long unbroken Hat titles cannot enlarge the member popover");
                            Widget? first = badges.get_first_child();
                            Widget? second = first.get_next_sibling();
                            Graphene.Rect a, b;
                            if (fail_if_not(first.compute_bounds(badges, out a),
                                    "the first Hat must have bounds in its badge container")) continue;
                            if (fail_if_not(second.compute_bounds(badges, out b),
                                    "the second Hat must have bounds in its badge container")) continue;
                            if (width == 280) fail_if(Math.fabs(a.origin.y - b.origin.y) > 0.5,
                                "two short hats remain next to each other when there is space");
                            for (Widget? child = first; child != null; child = child.get_next_sibling()) {
                                Graphene.Rect bounds;
                                fail_if_not(child.compute_bounds(badges, out bounds));
                                fail_if(bounds.origin.x < -0.5 || bounds.origin.x + bounds.size.width > badges.get_width() + 0.5);
                                fail_if(bounds.origin.y < -0.5 || bounds.origin.y + bounds.size.height > badges.get_height() + 0.5,
                                    "height-for-width must reserve every wrapped row");
                            }
                        } finally { window.destroy(); settle(); }
                    }
                }
            }
        } finally {
            manager.color_scheme = previous_scheme;
            Widget.set_default_direction(previous_direction);
        }
    }

    private class Fixture : Object {
        public string root;
        public Database db;
        public StreamInteractor interactor;
        public Conversation first;
        public Conversation second;

        public Fixture() throws Error {
            root = DirUtils.make_tmp("dinox-occupant-hats-XXXXXX");
            db = new Database(Path.build_filename(root, "dino.db"), "isolated occupant hats");
            interactor = new StreamInteractor.for_tests(db);
            AvatarManager.start(interactor, db, new FileEncryption("isolated occupant hats"));
            var a = new Account(new Jid("first@example.test"), "fixture") { id = 1 };
            var b = new Account(new Jid("second@example.test"), "fixture") { id = 2 };
            first = new Conversation(new Jid("room@conference.example.test"), a,
                Conversation.Type.GROUPCHAT) { id = 1 };
            second = new Conversation(new Jid("room@conference.example.test"), b,
                Conversation.Type.GROUPCHAT) { id = 2 };
        }

        public OccupantListItem item(string title, string nick = "DinoX") throws Error {
            var item = new OccupantListItem.occupant(new Jid("room@conference.example.test/" + nick)) {
                display_name = nick, avatar_read_policy = AvatarReadPolicy.MEMORY_ONLY,
                hats_text = title
            };
            item.hats = hats(title);
            return item;
        }

        public void close() {
            db.close();
            FileUtils.remove(Path.build_filename(root, "dino.db"));
            FileUtils.remove(Path.build_filename(root, "dino.db-wal"));
            FileUtils.remove(Path.build_filename(root, "dino.db-shm"));
            DirUtils.remove(root);
        }
    }

    private static OccupantHatBadges? find_badges(Widget root) {
        if (root is OccupantHatBadges) return (OccupantHatBadges) root;
        for (Widget? child = root.get_first_child(); child != null; child = child.get_next_sibling()) {
            var result = find_badges(child);
            if (result != null) return result;
        }
        return null;
    }

    private void test_rebind() {
        Fixture? fixture = null;
        var row = new ListRow();
        try {
            fixture = new Fixture();
            var first = fixture.item("Maintainer");
            row.bind(fixture.interactor, fixture.first, first);
            var badges = find_badges(row.get_widget());
            fail_if(badges == null);
            fail_if_not_eq_int(1, badges.count);
            first.hats = hats("Support");
            first.notify_changed();
            fail_if_not_eq_str("Support", ((Label) badges.get_first_child().get_last_child()).label);
            var second = fixture.item("Second account");
            row.bind(fixture.interactor, fixture.second, second);
            first.hats = hats("Stale first account");
            first.notify_changed();
            fail_if_not_eq_str("Second account", ((Label) badges.get_first_child().get_last_child()).label,
                "same room and nick on another account must not retain a previous binding");
            row.bind(fixture.interactor, fixture.second, new OccupantListItem.header("Members", 1, true));
            fail_if_not_eq_int(0, badges.count);
            fail_if(badges.visible, "recycled section headings cannot retain occupant Hats");
            row.bind(fixture.interactor, fixture.second, second);
            second.hats = new Gee.ArrayList<Xep.Muc.Hat>();
            second.hats_text = "";
            second.role_known = true;
            second.role = Xep.Muc.Role.VISITOR;
            second.affiliation_known = true;
            second.affiliation = Xep.Muc.Affiliation.OWNER;
            second.notify_changed();
            fail_if_not_eq_int(0, badges.count);
            var role = badges.get_prev_sibling() as Label;
            fail_if(role == null || !role.visible || role.label == "",
                "actual MUC roles remain separate and visible when no Hat is assigned");
            row.unbind();
            fail_if_not_eq_int(0, badges.count);
        } catch (Error error) { fail_if(true, error.message); }
        finally { row.cleanup(); if (fixture != null) fixture.close(); }
    }

    private void test_lifetime() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture();
            var item = fixture.item("Maintainer");
            ListRow? row = new ListRow();
            row.bind(fixture.interactor, fixture.first, item);
            var weak_row = WeakRef(row);
            row = null;
            settle();
            fail_if(weak_row.get() != null,
                "an item.changed handler must not retain a recycled row controller");
            item.notify_changed();
        } catch (Error error) { fail_if(true, error.message); }
        finally { if (fixture != null) fixture.close(); }
    }

    private void test_member_rows() {
        Fixture? fixture = null;
        var manager = Adw.StyleManager.get_default();
        var previous_scheme = manager.color_scheme;
        var previous_direction = Widget.get_default_direction();
        try {
            fixture = new Fixture();
            foreach (var scheme in new Adw.ColorScheme[] {
                    Adw.ColorScheme.FORCE_LIGHT, Adw.ColorScheme.FORCE_DARK }) {
                manager.color_scheme = scheme;
                foreach (var direction in new TextDirection[] { TextDirection.LTR, TextDirection.RTL }) {
                    Widget.set_default_direction(direction);
                    var window = new Adw.Window();
                    var rows = new Gee.ArrayList<ListRow>();
                    try {
                        window.add_css_class("dino-main");
                        var content = new Box(Orientation.VERTICAL, 3) {
                            margin_top = 12, margin_bottom = 12, margin_start = 8, margin_end = 8,
                            valign = Align.START
                        };
                        content.add_css_class("background");
                        var search = new SearchEntry() {
                            placeholder_text = "Search members", margin_start = 7, margin_end = 7
                        };
                        content.append(search);
                        var heading = new ListRow();
                        rows.add(heading);
                        heading.bind(fixture.interactor, fixture.first,
                            new OccupantListItem.header("Owners", 1, true));
                        content.append(heading.get_widget());
                        var owner = fixture.item("Maintainer");
                        owner.affiliation_known = owner.role_known = true;
                        owner.affiliation = Xep.Muc.Affiliation.OWNER;
                        owner.role = Xep.Muc.Role.MODERATOR;
                        owner.status_icon = "user-busy-symbolic";
                        owner.status_css_class = "error";
                        owner.status_text = "Busy";
                        var owner_row = new ListRow();
                        rows.add(owner_row);
                        owner_row.bind(fixture.interactor, fixture.first, owner);
                        content.append(owner_row.get_widget());
                        var members_heading = new ListRow();
                        rows.add(members_heading);
                        members_heading.bind(fixture.interactor, fixture.first,
                            new OccupantListItem.header("Members", 2, false));
                        content.append(members_heading.get_widget());
                        var member = fixture.item("Support", "big");
                        member.hats[0].hue = "210";
                        member.hats.add(new Xep.Muc.Hat() { title = "Team", uri = "urn:example:team", hue = "120" });
                        var member_row = new ListRow();
                        rows.add(member_row);
                        member_row.bind(fixture.interactor, fixture.first, member);
                        content.append(member_row.get_widget());
                        var long_member = fixture.item("Long Hat title that does not widen the member popover", "A long member name without room to display all characters");
                        long_member.hats.add(new Xep.Muc.Hat() { title = "Reviewer", uri = "urn:example:reviewer", hue = "300" });
                        var long_row = new ListRow();
                        rows.add(long_row);
                        long_row.bind(fixture.interactor, fixture.first, long_member);
                        content.append(long_row.get_widget());
                        window.content = content;
                        window.set_default_size(300, 300);
                        window.present();
                        settle();
                        fail_if(window.get_width() > 300,
                            "the production member row template must remain within a narrow popover");
                        foreach (var row in rows) {
                            var badges = find_badges(row.get_widget());
                            if (!badges.visible) continue;
                            Graphene.Rect bounds;
                            fail_if_not(badges.compute_bounds(content, out bounds));
                            fail_if(bounds.origin.x < -0.5 || bounds.origin.x + bounds.size.width > content.get_width() + 0.5);
                            var grid = row.get_widget() as Grid;
                            var overlay = grid.get_child_at(0, 0) as Overlay;
                            fail_if_not_eq_int(30, overlay.child.get_width(),
                                "badge design must retain the existing small member avatar");
                        }
                        string? capture_dir = Environment.get_variable("DINOX_HATS_BADGE_CAPTURE_DIR");
                        if (capture_dir != null) {
                            string theme = scheme == Adw.ColorScheme.FORCE_DARK ? "dark" : "light";
                            string dir = direction == TextDirection.RTL ? "rtl" : "ltr";
                            save_capture(window, content,
                                Path.build_filename((!) capture_dir, "members-%s-%s.png".printf(theme, dir)));
                        }
                    } finally {
                        window.destroy();
                        foreach (var row in rows) row.cleanup();
                        settle();
                    }
                }
            }
        } catch (Error error) { fail_if(true, error.message); }
        finally {
            if (fixture != null) fixture.close();
            manager.color_scheme = previous_scheme;
            Widget.set_default_direction(previous_direction);
        }
    }

    private static void save_capture(Adw.Window window, Widget content, string path) {
        var snapshot = new Snapshot();
        var paintable = new WidgetPaintable(content);
        paintable.snapshot(snapshot, content.get_width(), content.get_height());
        var node = snapshot.to_node();
        var renderer = window.get_renderer();
        if (fail_if(node == null || renderer == null)) return;
        var texture = renderer.render_texture(node, null);
        fail_if_not(texture.save_to_png(path), "native member row capture must be written locally");
    }
}

}

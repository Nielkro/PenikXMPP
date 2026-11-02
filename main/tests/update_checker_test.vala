using Dino.Ui;

namespace Dino.Ui.Test {

class UpdateCheckerTest : Gee.TestCase {

    public UpdateCheckerTest() {
        base("UpdateChecker");

        add_test("parses stable Forgejo release", test_parses_stable_release);
        add_test("rejects prerelease", test_rejects_prerelease);
        add_test("rejects foreign release URL", test_rejects_foreign_url);
        add_test("rejects mismatched release URL", test_rejects_mismatched_url);
        add_test("compares numeric versions", test_compares_numeric_versions);
        add_test("accepts local build suffix", test_accepts_local_build_suffix);
        add_test("offers an arbitrary newer release", test_offers_newer_release);
        add_test("does not offer a downgrade", test_does_not_offer_downgrade);
        add_test("rejects malformed version", test_rejects_malformed_version);
        add_test("menu action is between about and panic wipe", test_menu_action_order);
        add_test("official_host_case_is_independent_of_system_locale", test_host_locale);
    }

    private void test_host_locale() {
        string? previous = Intl.setlocale(LocaleCategory.CTYPE, null);
        Intl.setlocale(LocaleCategory.CTYPE, "");
        try {
            var release = UpdateChecker.parse_release_json(release_json("v2.3.5",
                "https://GIT.DINOX.IM/dinoxim/dinox/releases/tag/v2.3.5"));
            fail_if_not_eq_str("2.3.5", release.version);
            bool rejected = false;
            try {
                UpdateChecker.parse_release_json(release_json("v2.3.5",
                    "https://gıt.dinox.im/dinoxim/dinox/releases/tag/v2.3.5"));
            } catch (UpdateCheckError error) { rejected = true; }
            assert_true(rejected, "a Unicode lookalike must not become the official update host");
        } catch (Error error) { GLib.Test.message("%s", error.message); GLib.Test.fail(); }
        finally { Intl.setlocale(LocaleCategory.CTYPE, previous); }
    }

    private static string release_json(string tag_name, string release_url,
            bool draft = false, bool prerelease = false) {
        return "{\"tag_name\":\"%s\",\"html_url\":\"%s\",\"draft\":%s,\"prerelease\":%s}".printf(
            tag_name,
            release_url,
            draft ? "true" : "false",
            prerelease ? "true" : "false"
        );
    }

    private void test_parses_stable_release() {
        try {
            UpdateRelease release = UpdateChecker.parse_release_json(
                release_json(
                    "v2.2.8",
                    "https://git.dinox.im/dinoxim/dinox/releases/tag/v2.2.8"
                )
            );
            fail_if_not_eq_str("v2.2.8", release.tag_name);
            fail_if_not_eq_str("2.2.8", release.version);
            fail_if_not_eq_str(
                "https://git.dinox.im/dinoxim/dinox/releases/tag/v2.2.8",
                release.release_url
            );
        } catch (Error error) {
            GLib.Test.message("Valid stable release was rejected: %s", error.message);
            GLib.Test.fail();
        }
    }

    private void test_rejects_prerelease() {
        bool rejected = false;
        try {
            UpdateChecker.parse_release_json(
                release_json(
                    "v2.2.8",
                    "https://git.dinox.im/dinoxim/dinox/releases/tag/v2.2.8",
                    false,
                    true
                )
            );
        } catch (UpdateCheckError error) {
            rejected = true;
        }
        assert_true(rejected, "A prerelease must not be offered as a stable update");
    }

    private void test_rejects_foreign_url() {
        bool rejected = false;
        try {
            UpdateChecker.parse_release_json(
                release_json(
                    "v2.2.8",
                    "https://example.org/dinox/releases/tag/v2.2.8"
                )
            );
        } catch (UpdateCheckError error) {
            rejected = true;
        }
        assert_true(rejected, "Only the official DinoX Forgejo host is allowed");
    }

    private void test_rejects_mismatched_url() {
        bool rejected = false;
        try {
            UpdateChecker.parse_release_json(
                release_json(
                    "v2.2.8",
                    "https://git.dinox.im/dinoxim/dinox/releases/tag/v9.9.9"
                )
            );
        } catch (UpdateCheckError error) {
            rejected = true;
        }
        assert_true(rejected, "Release URL and release tag must match");
    }

    private void test_compares_numeric_versions() {
        try {
            assert_true(UpdateChecker.compare_versions("2.9.9", "2.10.0") < 0);
            assert_true(UpdateChecker.compare_versions("2.10.0", "2.9.9") > 0);
            assert_true(UpdateChecker.compare_versions("2.99.99", "3.0.0") < 0);
            assert_true(UpdateChecker.compare_versions("4.0.0", "3.99.99") > 0);
            assert_true(UpdateChecker.compare_versions("11.99.99", "12.34.56") < 0);
            assert_true(UpdateChecker.compare_versions("2.2.7", "2.2.7.0") == 0);
            assert_true(UpdateChecker.compare_versions("2.2.7.1", "2.2.7") > 0);
        } catch (Error error) {
            GLib.Test.message("Valid version comparison failed: %s", error.message);
            GLib.Test.fail();
        }
    }

    private void test_accepts_local_build_suffix() {
        try {
            assert_true(
                UpdateChecker.compare_versions(
                    "2.2.7~git20260822.abc123", "2.2.7") == 0
            );
            assert_true(
                UpdateChecker.compare_versions("v2.2.7+", "2.2.8") < 0
            );
        } catch (Error error) {
            GLib.Test.message("Local build suffix was rejected: %s", error.message);
            GLib.Test.fail();
        }
    }

    private void test_offers_newer_release() {
        try {
            UpdateRelease release = UpdateChecker.parse_release_json(
                release_json(
                    "v12.34.56",
                    "https://git.dinox.im/dinoxim/dinox/releases/tag/v12.34.56"
                )
            );
            UpdateCheckResult result = UpdateChecker.evaluate("4.0.0", release);
            assert_true(result.update_available,
                "Any numerically newer x.x.x release must be offered");
        } catch (Error error) {
            GLib.Test.message("Arbitrary newer release evaluation failed: %s", error.message);
            GLib.Test.fail();
        }
    }

    private void test_does_not_offer_downgrade() {
        try {
            UpdateRelease release = UpdateChecker.parse_release_json(
                release_json(
                    "v2.2.7",
                    "https://git.dinox.im/dinoxim/dinox/releases/tag/v2.2.7"
                )
            );
            UpdateCheckResult result = UpdateChecker.evaluate("2.2.8", release);
            assert_false(result.update_available,
                "A newer local build must not be offered an older release");
        } catch (Error error) {
            GLib.Test.message("Downgrade evaluation failed: %s", error.message);
            GLib.Test.fail();
        }
    }

    private void test_rejects_malformed_version() {
        bool rejected = false;
        try {
            UpdateChecker.compare_versions("2.2.x", "2.2.8");
        } catch (UpdateCheckError error) {
            rejected = true;
        }
        assert_true(rejected, "Malformed local versions must fail closed");
    }

    private void test_menu_action_order() {
        var builder = new Gtk.Builder.from_resource("/im/dinox/dinox/menu_app.ui");
        var menu = builder.get_object("menu_app") as GLib.MenuModel;
        assert_true(menu != null, "Application menu resource must expose menu_app");
        if (menu == null) return;

        assert_true(menu.get_n_items() == 4,
            "Settings, feeds, help and destructive actions must remain separate");
        if (menu.get_n_items() != 4) return;
        assert_menu_section(menu, 0, { "app.preferences" });
        assert_menu_section(menu, 1, { "app.feeds" });
        assert_menu_section(menu, 2,
            { "win.show-help-overlay", "app.about", "app.check-for-updates" });
        assert_menu_section(menu, 3, { "app.panic-wipe" });
    }

    private void assert_menu_section(GLib.MenuModel menu, int position, string[] actions) {
        GLib.MenuModel? section = menu.get_item_link(position, GLib.Menu.LINK_SECTION);
        assert_true(section != null, "Application menu must contain its section");
        if (section == null) return;
        assert_true(section.get_n_items() == actions.length,
            "Menu section must contain the expected actions");
        for (int i = 0; i < actions.length; i++) {
            assert_menu_action(section, i, actions[i]);
        }
    }

    private void assert_menu_action(GLib.MenuModel menu, int position,
            string expected) {
        // GMenuModel does not promise a safe out-of-range attribute lookup.
        // Report a failed assertion instead of crashing the remaining suite.
        assert_true(position >= 0 && position < menu.get_n_items(),
            "Menu action position must exist");
        if (position < 0 || position >= menu.get_n_items()) return;
        Variant? action = menu.get_item_attribute_value(
            position, GLib.Menu.ATTRIBUTE_ACTION, VariantType.STRING);
        assert_true(action != null,
            "Menu item %d must have an action".printf(position));
        if (action != null) {
            fail_if_not_eq_str(expected, ((!) action).get_string());
        }
    }
}

}

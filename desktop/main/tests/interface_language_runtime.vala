namespace Dino.Ui.Test {

class InterfaceLanguageRuntimeTest : Gee.TestCase {
    public InterfaceLanguageRuntimeTest() {
        base("InterfaceLanguageRuntime");
        add_test("app_language_controls_direction_without_system_catalog", test_direction);
        add_test("unsupported_saved_and_system_languages_fall_back_to_english", test_fallback);
        add_test("regional_system_locales_keep_the_supported_language_and_script", test_regions);
        add_test("preferences_offer_complete_languages_and_show_the_effective_saved_choice", test_preferences);
        add_test("english_fallback_does_not_inherit_an_unsupported_rtl_language", test_fallback_direction);
        add_test("language_selection_preserves_system_formats", test_format_isolation);
    }

    private void test_format_isolation() {
        string? previous_language = Environment.get_variable("LANGUAGE");
        string? previous_lang = Environment.get_variable("LANG");
        string? previous_all = Environment.get_variable("LC_ALL");
        string? numeric_locale = Intl.setlocale(LocaleCategory.NUMERIC, null);
        string? time_locale = Intl.setlocale(LocaleCategory.TIME, null);
        string formatted = "%.2f".printf(137.125);
        GLib.Test.message("Loaded language label: %s; numeric locale: %s; formatted number: %s",
            _("_Language"), numeric_locale ?? "unknown", formatted);
        try {
            foreach (string language in InterfaceLanguage.CODES) {
                if (language == "system") continue;
                fail_if_not_eq_str(language, InterfaceLanguage.apply_environment(language));
                fail_if(Environment.get_variable("LANG") != previous_lang,
                    "the interface language must not replace the system locale");
                fail_if(Environment.get_variable("LC_ALL") != previous_all,
                    "the interface language must not replace locale overrides");
                fail_if(Intl.setlocale(LocaleCategory.NUMERIC, null) != numeric_locale ||
                        Intl.setlocale(LocaleCategory.TIME, null) != time_locale,
                    "language selection must preserve numeric and date formats");
                fail_if_not_eq_str(formatted, "%.2f".printf(137.125));
                // Protocol values must retain ASCII decimal syntax even when
                // UI formatting uses a decimal comma.
                double? hue = ConversationDetails.HatFormChoices.parse_hue("137.125");
                fail_if(hue == null || Math.fabs((!) hue - 137.125) > 0.00001);
                var color = Gdk.RGBA() { red = 0, green = 1, blue = 0.45f, alpha = 1 };
                string wire_hue = ConversationDetails.HatFormChoices.color_hue(color, "0");
                fail_if(wire_hue.contains(","), "hat protocol values must never use decimal commas");
                fail_if(ConversationDetails.HatFormChoices.parse_hue(wire_hue) == null);
            }
        } finally {
            if (previous_language == null) Environment.unset_variable("LANGUAGE");
            else Environment.set_variable("LANGUAGE", (!) previous_language, true);
        }
    }

    private void test_fallback() {
        assert_true(InterfaceLanguage.resolve("el", new string[] { "de_DE", "C" }) == "en");
        assert_true(InterfaceLanguage.resolve("fa", new string[] { "ar", "C" }) == "en");
        assert_true(InterfaceLanguage.resolve("system", new string[] { "el_GR", "el", "C" }) == "en");
        assert_true(InterfaceLanguage.resolve(null, new string[] {}) == "en");
        assert_true(InterfaceLanguage.resolve("system", new string[] { "el_GR", "de_DE", "C" }) == "de");
        assert_true(InterfaceLanguage.resolve("system", new string[] { "en_GB", "de_DE", "C" }) == "en");
        assert_true(InterfaceLanguage.resolve("system", new string[] { "C", "de" }) == "en");
        assert_true(InterfaceLanguage.resolve("de", new string[] { "C" }) == "de");
    }

    private void test_regions() {
        foreach (string locale in new string[] { "yue", "yue_HK.UTF-8", "yue-HK", "yue-Hant", "yue-Hant-HK" }) {
            assert_true(InterfaceLanguage.resolve("system", new string[] { locale, "C" }) == "yue", locale);
            assert_true(InterfaceLanguage.normalize_setting(locale) == "yue", locale);
        }
        foreach (string locale in new string[] { "vi", "vi_VN.UTF-8", "vi-VN" }) {
            assert_true(InterfaceLanguage.resolve("system", new string[] { locale, "C" }) == "vi", locale);
            assert_true(InterfaceLanguage.normalize_setting(locale) == "vi", locale);
        }
        foreach (string locale in new string[] { "arz", "arz_EG.UTF-8", "arz-EG" }) {
            assert_true(InterfaceLanguage.resolve("system", new string[] { locale, "C" }) == "arz", locale);
            assert_true(InterfaceLanguage.normalize_setting(locale) == "arz", locale);
        }
        foreach (string locale in new string[] { "pcm", "pcm_NG.UTF-8", "pcm-NG" }) {
            assert_true(InterfaceLanguage.resolve("system", new string[] { locale, "C" }) == "pcm", locale);
            assert_true(InterfaceLanguage.normalize_setting(locale) == "pcm", locale);
        }
        string[] locales = { "de_CH.UTF-8", "pt-BR", "pt_PT.UTF-8", "nb_NO", "ar_EG.UTF-8", "bn_BD.UTF-8", "bn-IN", "id_ID.UTF-8", "id-ID", "ja_JP.UTF-8", "ja-JP", "he_IL.UTF-8", "he-IL", "iw_IL", "ur_PK.UTF-8", "ur-PK", "ur_IN", "zh-Hans-CN", "zh-Hant-TW", "zh_HK", "zh_SG" };
        string[] expected = { "de", "pt_BR", "pt", "nb", "ar", "bn", "bn", "id", "id", "ja", "ja", "he", "he", "he", "ur", "ur", "ur", "zh_CN", "zh_TW", "zh_TW", "zh_CN" };
        for (int i = 0; i < locales.length; i++) {
            assert_true(InterfaceLanguage.resolve("system", new string[] { locales[i], "C" }) == expected[i], locales[i]);
        }
    }

    private Adw.ComboRow? find_language_row(Gtk.Widget widget) {
        var row = widget as Adw.ComboRow;
        if (row != null && row.title == _("_Language")) return row;
        for (var child = widget.get_first_child(); child != null; child = child.get_next_sibling()) {
            var found = find_language_row(child);
            if (found != null) return found;
        }
        return null;
    }

    private void test_preferences() {
        var model = new ViewModel.GeneralPreferencesPage() { language = "el" };
        var page = new GeneralPreferencesPage() { model = model };
        page.ensure_content();
        var row = find_language_row(page);
        if (fail_if(row == null, "Native language row missing")) return;
        var names = ((!) row).model as Gtk.StringList;
        if (fail_if(names == null, "Language names missing")) return;
        assert_true(((!) names).get_string(((!) row).selected) == "English");
        assert_true(model.language == "el", "Opening preferences must not rewrite saved settings");
        assert_true(((!) names).get_n_items() == InterfaceLanguage.CODES.length);
        for (uint i = 0; i < InterfaceLanguage.CODES.length; i++) {
            ((!) row).selected = i;
            assert_true(model.language == InterfaceLanguage.CODES[i]);
        }
        model.language = "pt_BR";
        assert_true(((!) names).get_string(((!) row).selected) == "Português (Brasil)");
        model.language = "he";
        assert_true(((!) names).get_string(((!) row).selected) == "עברית");
        model.language = "ur";
        assert_true(((!) names).get_string(((!) row).selected) == "اردو");
        model.language = "ja";
        assert_true(((!) names).get_string(((!) row).selected) == "日本語");
        model.language = "arz";
        assert_true(((!) names).get_string(((!) row).selected) == "العربية المصرية");
        model.language = "pcm";
        assert_true(((!) names).get_string(((!) row).selected) == "Naija Pidgin");
        model.language = "vi";
        assert_true(((!) names).get_string(((!) row).selected) == "Tiếng Việt");
        model.language = "yue";
        assert_true(((!) names).get_string(((!) row).selected) == "粵語");
        model.language = "el";
        assert_true(((!) names).get_string(((!) row).selected) == "English");
    }

    private void test_fallback_direction() {
        var previous = Gtk.Widget.get_default_direction();
        string selected = InterfaceLanguage.resolve("system", new string[] { "fa_IR", "C" });
        InterfaceLanguage.apply_direction(selected);
        assert_true(Gtk.Widget.get_default_direction() == Gtk.TextDirection.LTR);
        InterfaceLanguage.apply_direction(InterfaceLanguage.resolve("ar", new string[] { "C" }));
        assert_true(Gtk.Widget.get_default_direction() == Gtk.TextDirection.RTL);
        Gtk.Widget.set_default_direction(previous);
    }

    private void test_direction() {
        var previous = Gtk.Widget.get_default_direction();
        foreach (string locale in new string[] { "ar", "ar_EG.UTF-8", "ar-SA", "arz", "arz_EG.UTF-8", "arz-EG", "he", "he_IL.UTF-8", "he-IL", "ur", "ur_PK.UTF-8", "ur-IN", "fa" }) {
            Gtk.Widget.set_default_direction(Gtk.TextDirection.LTR);
            InterfaceLanguage.apply_direction(locale);
            var row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
            assert_true(row.get_direction() == Gtk.TextDirection.RTL, locale);
            // Explicit directions on mixed-script content must still win.
            var address = new Gtk.Entry();
            address.set_direction(Gtk.TextDirection.LTR);
            row.append(address);
            assert_true(address.get_direction() == Gtk.TextDirection.LTR);
        }
        foreach (string locale in new string[] { "en", "de_DE.UTF-8", "hi", "bn", "bn_BD.UTF-8", "id", "id_ID.UTF-8", "ja", "ja_JP.UTF-8", "pcm", "pcm_NG.UTF-8", "vi", "vi_VN.UTF-8", "vi-VN", "yue", "yue_HK.UTF-8", "yue-Hant-HK", "zh_TW", "fa-Latn", "C" }) {
            Gtk.Widget.set_default_direction(Gtk.TextDirection.RTL);
            InterfaceLanguage.apply_direction(locale);
            assert_true(new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0).get_direction() == Gtk.TextDirection.LTR, locale);
        }
        Gtk.Widget.set_default_direction(previous);
    }
}

}

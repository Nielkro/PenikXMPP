// Runs in a fresh native process per language. Use the application's locale
// search/binding functions, not a Python gettext replacement or a forced path.
private int main(string[] crt_args) {
#if WINDOWS
    string[] native_args = GLib.Win32.get_command_line();
    unowned string[] args = native_args;
#else
    unowned string[] args = crt_args;
#endif
    if (args.length != 2) return 2;
    try {
        var parser = new Json.Parser();
        parser.load_from_file(args[1]);
        var request = parser.get_root().get_object();
        string language = request.get_string_member("language");
        var offered = request.get_array_member("languages");
        if (offered.get_length() + 1 != Dino.Ui.InterfaceLanguage.CODES.length) {
            stderr.printf("Language selector and packaged catalog lists differ\n");
            return 1;
        }
        for (uint i = 0; i < offered.get_length(); i++) {
            if (!(offered.get_string_element(i) in Dino.Ui.InterfaceLanguage.CODES)) return 1;
        }
        if (Intl.setlocale(LocaleCategory.ALL, "") == null) {
            stderr.printf("Requested system locale is unavailable\n");
            return 77;
        }
        if (Dino.Ui.InterfaceLanguage.apply_environment(language) != language) {
            stderr.printf("Unsupported application language: %s\n", language);
            return 1;
        }
        bool rtl = ICU.locale_is_right_to_left(language);
        Dino.Ui.InterfaceLanguage.apply_direction(language);
        if ((Gtk.Widget.get_default_direction() == Gtk.TextDirection.RTL) != rtl) return 1;
        if (rtl != request.get_boolean_member("rtl")) {
            stderr.printf("Unexpected reading direction: %s\n", language);
            return 1;
        }
        var paths = new Dino.SearchPathGenerator(args[0]);
        var domains = request.get_array_member("domains");
        uint checks = 0;
        for (uint i = 0; i < domains.get_length(); i++) {
            var domain = domains.get_object_element(i);
            string name = domain.get_string_member("name");
            string actual_path = paths.get_locale_path(name, "/usr/share/locale");
            string expected_path = domain.get_string_member("path");
            if (!File.new_for_path(actual_path).equal(File.new_for_path(expected_path))) {
                stderr.printf("Wrong catalog search result for %s: %s; expected %s\n", name, actual_path, expected_path);
                return 1;
            }
            Dino.internationalize(name, actual_path);
            var queries = domain.get_array_member("queries");
            for (uint j = 0; j < queries.get_length(); j++) {
                var query = queries.get_object_element(j);
                string id = query.get_string_member("id");
                string? context = query.has_member("context") ? query.get_string_member("context") : null;
                string actual;
                if (query.has_member("plural")) {
                    string key = context != null ? context + "\004" + id : id;
                    actual = GLib.dngettext(name, key, query.get_string_member("plural"), (ulong) query.get_int_member("n"));
                    if (context != null && actual == key) actual = id;
                } else {
                    actual = context != null ? GLib.dpgettext2(name, context, id) : GLib.dgettext(name, id);
                }
                string expected = query.get_string_member("expected");
                if (actual != expected || !actual.validate()) {
                    stderr.printf("Catalog mismatch: language=%s domain=%s id=%s\nExpected: %s\nActual: %s\n",
                        language, name, id, expected, actual);
                    return 1;
                }
                // Validate translated Pango templates even when their dialog
                // is not opened by a widget fixture. Plain text containing
                // literal angle brackets is not automatically markup.
                string source = query.has_member("plural") && query.get_int_member("n") != 1
                    ? query.get_string_member("plural") : id;
                if (source.contains("<") && valid_pango_markup(source) && !valid_pango_markup(actual)) {
                    stderr.printf("Invalid translated Pango markup: %s/%s: %s\n", language, name, id);
                    return 1;
                }
                checks++;
            }
        }
        stdout.printf("PASS language=%s direction=%s domains=%u lookups=%u\n", language,
            rtl ? "rtl" : "ltr", domains.get_length(), checks);
        return 0;
    } catch (Error error) {
        stderr.printf("Catalog runtime test failed: %s\n", error.message);
        return 1;
    }
}

private bool valid_pango_markup(string value) {
    try {
        Pango.AttrList attributes;
        string plain;
        unichar accelerator;
        return Pango.parse_markup(value, -1, 0, out attributes, out plain, out accelerator);
    } catch (Error error) {
        return false;
    }
}

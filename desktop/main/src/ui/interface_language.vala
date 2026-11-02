namespace Dino.Ui {

// LANGUAGE can select DinoX's bundled catalog without an installed system
// locale or GTK catalog. GTK's own translated direction marker is therefore
// not sufficient for the application's language selection.
public class InterfaceLanguage : Object {
    [CCode (cname = "dinox_dup_language_names", cheader_filename = "ui/interface_language_native.h", array_length = false, array_null_terminated = true)]
    private static extern string[] dup_language_names();

    // Only locales complete in all shipped domains belong here. The translation
    // gate checks this list against all three LINGUAS files and current sources.
    // English is supplied by source strings, not by the historical en.po files.
    public const string[] CODES = {
        "system", "ar", "arz", "bg", "bn", "ca", "cs", "da", "de", "en", "es", "et",
        "fi", "fr", "he", "hi", "hu", "id", "it", "ja", "lt", "lv", "nb", "nl", "pcm", "pl",
        "pt", "pt_BR", "ro", "ru", "sk", "sv", "tr", "uk", "ur", "vi", "yue", "zh_CN", "zh_TW"
    };

    public static Gtk.StringList create_model() {
        string[] labels = {
            _("System") + " (" + _("Automatic") + ")", "العربية", "العربية المصرية", "Български", "বাংলা", "Català", "Čeština",
            "Dansk", "Deutsch", "English", "Español", "Eesti", "Suomi",
            "Français", "עברית", "हिन्दी", "Magyar", "Bahasa Indonesia", "Italiano", "日本語", "Lietuvių", "Latviešu",
            "Norsk bokmål", "Nederlands", "Naija Pidgin", "Polski", "Português",
            "Português (Brasil)", "Română", "Русский", "Slovenčina", "Svenska",
            "Türkçe", "Українська", "اردو", "Tiếng Việt", "粵語", "中文 (简体)", "中文 (繁體)"
        };
        var model = new Gtk.StringList(null);
        foreach (string label in labels) model.append(label);
        return model;
    }

    private static string? match_locale(string locale) {
        string normalized = locale.strip().replace("-", "_").split(".")[0].split("@")[0].ascii_down();
        foreach (string code in CODES) {
            if (code != "system" && code.ascii_down() == normalized) return code;
        }
        // Preserve script variants when the OS uses a regional or BCP-47 name.
        if (normalized.has_prefix("zh_hant") || normalized == "zh_hk" || normalized == "zh_mo") return "zh_TW";
        if (normalized.has_prefix("zh_hans") || normalized == "zh_sg" || normalized == "zh") return "zh_CN";
        string base_language = normalized.split("_")[0];
        // Older system locales can still use the former Hebrew code.
        if (base_language == "iw") return "he";
        foreach (string code in CODES) {
            if (code != "system" && code == base_language) return code;
        }
        return null;
    }

    public static string normalize_setting(string? requested) {
        if (requested == null || requested.strip() == "" || requested.strip() == "system") return "system";
        return match_locale(requested) ?? "en";
    }

    public static string resolve(string? requested, string[] system_languages) {
        string setting = normalize_setting(requested);
        if (setting != "system") return setting;
        foreach (string locale in system_languages) {
            string? matched = match_locale(locale);
            if (matched != null) return matched;
            // C/POSIX explicitly requests untranslated source strings.
            if (locale == "C" || locale.has_prefix("C.") || locale == "POSIX") break;
        }
        return "en";
    }

    // Called before gettext/GTK initialization. Set a single approved language
    // so an old installed partial catalog cannot leak into the fallback chain.
    public static string apply_environment(string? requested = null) {
        string selected = resolve(requested, dup_language_names());
        Environment.set_variable("LANGUAGE", selected, true);
        return selected;
    }

    public static void apply_direction(string? language = null) {
        string selected = language ?? dup_language_names()[0];
        Gtk.Widget.set_default_direction(ICU.locale_is_right_to_left(selected)
            ? Gtk.TextDirection.RTL : Gtk.TextDirection.LTR);
    }
}

}

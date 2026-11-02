using Gee;
using Gdk;
using Xmpp;

namespace Dino {

private extern const string SYSTEM_LIBDIR_NAME;
private extern const string SYSTEM_PLUGIN_DIR;

[CCode (cname = "gdk_pixbuf_save_to_buffer", cheader_filename = "gdk-pixbuf/gdk-pixbuf.h")]
private extern static bool save_pixbuf_to_buffer(Pixbuf pixbuf, [CCode (array_length_cname = "buffer_size", array_length_pos = 2.1, array_length_type = "gsize", type = "gchar**")] out uint8[] buffer, string type, ...) throws Error;

internal static uint8[] pixbuf_to_png_bytes(Pixbuf pixbuf) throws Error {
    uint8[] buffer;
    save_pixbuf_to_buffer(pixbuf, out buffer, "png", null);
    return buffer;
}

internal static string join_strings(string separator, Collection<string> values) {
    string[] parts = new string[values.size + 1];
    int i = 0;
    foreach (string value in values) {
        parts[i++] = value;
    }
    parts[i] = null;
    return string.joinv(separator, parts);
}

public class SearchPathGenerator {

    public string? exec_path { get; private set; }

    public SearchPathGenerator(string? exec_path) {
        this.exec_path = exec_path;
    }

    private static bool has_locale_catalog(string directory, string gettext_package) {
        // English is the source language and need not have a catalog. Detect
        // the domain itself instead of using one particular locale as a marker.
        try {
            Dir locales = Dir.open(directory);
            string? language;
            while ((language = locales.read_name()) != null) {
                if (FileUtils.test(Path.build_filename(directory, language,
                        "LC_MESSAGES", gettext_package + ".mo"), FileTest.IS_REGULAR)) return true;
            }
        } catch (FileError ignored) { }
        return false;
    }

    public string get_locale_path(string gettext_package, string locale_install_dir) {
        // Check for TEXTDOMAINDIR environment variable (used by AppImage)
        string? env_locale_dir = Environment.get_variable("TEXTDOMAINDIR");
        if (env_locale_dir != null && has_locale_catalog(env_locale_dir, gettext_package)) {
            return env_locale_dir;
        }
        
        if (exec_path == null) return locale_install_dir;
        string dirname = Path.get_dirname(exec_path);

        // Portable/Windows and legacy builds: check <exe_dir>/locale/ first.
        // This is where update_dist.sh places the .mo files.
        string portable_locale = Path.build_filename(dirname, "locale");
        if (has_locale_catalog(portable_locale, gettext_package)) {
            return portable_locale;
        }

        // Does our environment look like a meson build dir?
        if (dirname == "." || Path.get_basename(dirname) == "main") {
            if (gettext_package == "dino") {
                string exec_locale = Path.build_filename(dirname, "po");
                if (has_locale_catalog(exec_locale, gettext_package)) {
                    return exec_locale;
                }
            } else if (gettext_package.has_prefix("dino-")) {
                // This is a plugin, so fetch from plugin subdir
                string exec_locale = Path.build_filename(dirname, "..", "plugins", gettext_package.substring(5), "po");
                if (has_locale_catalog(exec_locale, gettext_package)) {
                    return exec_locale;
                }
            }
        }
        return locale_install_dir;
    }

    public string[] get_plugin_paths() {
        string[] search_paths = new string[0];
        if (Environment.get_variable("DINO_PLUGIN_DIR") != null) {
            search_paths += Environment.get_variable("DINO_PLUGIN_DIR");
        }
        search_paths += Path.build_filename(Environment.get_home_dir(), ".local", "lib", "dinox", "plugins");
        string? exec_path = this.exec_path;
        if (exec_path != null) {
            if (!exec_path.contains(Path.DIR_SEPARATOR_S)) {
                exec_path = Environment.find_program_in_path(this.exec_path);
            }
            string dirname = Path.get_dirname(exec_path);
#if WINDOWS
            // Always look for plugins in 'plugins' subdirectory of the executable on Windows
            search_paths += Path.build_filename(dirname, "plugins");
#endif
            // Does our environment look like a CMake build dir?
            if (dirname.contains("dino") || dirname == "." || dirname.contains("build") || Path.get_basename(dirname) == "main") {
                search_paths += Path.build_filename(Path.get_dirname(exec_path), "plugins");
            }
            // Does our environment look like a meson build dir?
            if (dirname == "." || Path.get_basename(dirname) == "main") {
                try {
                    Dir plugin_dir = Dir.open(Path.build_path(Path.DIR_SEPARATOR_S, dirname, "..", "plugins"));
                    string? entry = null;
                    while ((entry = plugin_dir.read_name()) != null) {
                        string plugin_subdir = Path.build_path(Path.DIR_SEPARATOR_S, dirname, "..", "plugins", entry);
                        try {
                            Dir.open(plugin_subdir);
                            search_paths += plugin_subdir;
                        } catch (FileError e) {
                            // ignore
                        }
                    }
                } catch (FileError e) {
                    // ignore
                }
            }
            if (Path.get_basename(dirname) == "bin") {
                search_paths += Path.build_filename(Path.get_dirname(Path.get_dirname(exec_path)), SYSTEM_LIBDIR_NAME, "dinox", "plugins");
            }
        }
        search_paths += SYSTEM_PLUGIN_DIR;
        return search_paths;
    }
}

public static string get_storage_dir() {
    return Path.build_filename(Environment.get_user_data_dir(), "dinox");
}

public static string get_cache_dir() {
    return Path.build_filename(Environment.get_user_cache_dir(), "dinox");
}

[CCode (cname = "dino_gettext", cheader_filename = "dino_i18n.h")]
public static extern unowned string _(string s);

[CCode (cname = "dino_ngettext", cheader_filename = "dino_i18n.h")]
public static extern unowned string n(string msgid, string plural, ulong number);

[CCode (cname = "bindtextdomain", cheader_filename = "libintl.h")]
private static extern unowned string? bindtextdomain(string domainname, string? dirname);

[CCode (cname = "bind_textdomain_codeset", cheader_filename = "libintl.h")]
private static extern unowned string? bind_textdomain_codeset(string domainname, string? codeset);

public static void internationalize(string gettext_package, string locales_dir) {
    bind_textdomain_codeset(gettext_package, "UTF-8");
    bindtextdomain(gettext_package, locales_dir);
}

public static HashMap<ChecksumType, string> compute_file_hashes_sync(File file, Gee.List<ChecksumType> checksum_types, Cancellable? cancellable = null) {
    var checksums = new Checksum[checksum_types.size];

    for (int i = 0; i < checksum_types.size; i++) {
        checksums[i] = new Checksum(checksum_types.get(i));
    }

    FileInputStream stream;
    try {
        stream = file.read(cancellable);
    } catch (GLib.Error e) {
        warning("Failed to read file for checksum: %s", e.message);
        return new HashMap<ChecksumType, string>();
    }

    uint8 fbuf[65536];
    size_t size;
    try {
        while ((size = stream.read(fbuf, cancellable)) > 0) {
            for (int i = 0; i < checksum_types.size; i++) {
                checksums[i].update(fbuf, size);
            }
        }
    } catch (GLib.Error e) {
        warning("Failed to read stream for checksum: %s", e.message);
        return new HashMap<ChecksumType, string>();
    } finally {
        try {
            stream.close(cancellable);
        } catch (GLib.Error e) {
            debug("Failed to close file checksum stream: %s", e.message);
        }
    }

    var ret = new HashMap<ChecksumType, string>();
    for (int i = 0; i < checksum_types.size; i++) {
        var checksum_type = checksum_types.get(i);
        uint8[] digest = new uint8[64];
        size_t length = digest.length;
        checksums[i].get_digest(digest, ref length);
        string computed_hash = GLib.Base64.encode(digest[0:length]);
        ret[checksum_type] = computed_hash;
    }
    return ret;
}

public static async HashMap<ChecksumType, string> compute_file_hashes(File file, Gee.List<ChecksumType> checksum_types) {
    var hashes = new HashMap<ChecksumType, string>();
    try {
        yield FileTransferWorker.run("compute-file-hashes", () => {
            var computed_hashes = compute_file_hashes_sync(file, checksum_types);
            foreach (var entry in computed_hashes.entries) {
                hashes[entry.key] = entry.value;
            }
        });
    } catch (GLib.Error e) {
        warning("Failed to compute file checksum on transfer worker: %s", e.message);
        return new HashMap<ChecksumType, string>();
    }

    return hashes;
}

public static string? build_socks5_proxy_uri(Dino.Entities.Account account) {
    if (account.proxy_type != "socks5" && account.proxy_type != "tor") return null;

    string h = account.proxy_host ?? "";
    int p = account.proxy_port;
    if (account.proxy_type == "tor") {
        h = (h != "") ? h : "127.0.0.1";
        p = (p > 0) ? p : 9050;
    } else if (h == "" || p <= 0) {
        return null;
    }
    if (":" in h) h = "[" + h + "]";
    if (account.proxy_user != null && account.proxy_user != "") {
        string eu = Uri.escape_string(account.proxy_user, null, false);
        string ep = (account.proxy_pass != null && account.proxy_pass != "") ? Uri.escape_string(account.proxy_pass, null, false) : "";
        return "socks5://%s:%s@%s:%d".printf(eu, ep, h, p);
    }
    return "socks5://%s:%d".printf(h, p);
}

}

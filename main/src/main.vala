using Dino.Entities;
using Dino.Ui;
using Gst;

extern const string GETTEXT_PACKAGE;
extern const string LOCALE_INSTALL_DIR;

#if LINUX
extern const string DINOX_IBUS_COMPAT_INSTALL_PATH;
extern const string DINOX_IBUS_COMPAT_SOURCE_PATH;
[CCode (cname = "dinox_ibus_prepare_compat", cheader_filename = "ibus_compat.h")]
extern bool prepare_ibus_client_compat(string private_path);
#endif

#if HAVE_MALLOC_TRIM
[CCode (cname = "mallopt", cheader_filename = "malloc.h")]
extern int mallopt (int param, int value);
#endif

#if WINDOWS
[CCode (cname = "g_tls_file_database_new", cheader_filename = "gio/gio.h")]
extern TlsDatabase? create_tls_file_database(string anchors) throws Error;
#endif

namespace Dino {

#if LINUX
private void prepare_ibus_compat() {
    string? module = Environment.get_variable("GTK_IM_MODULE");
    if (module != null && module != "" && module != "ibus") return;

    // Use the actual executable, never the working directory or argv[0].
    // This covers relocated AppImages and the Deb dinox.real wrapper target.
    try {
        string executable = FileUtils.read_link("/proc/self/exe");
        string adjacent = Path.build_filename(Path.get_dirname(executable),
            "..", "lib", "dinox", "ibus-compat", "libibus-1.0.so.5.0.530");
        if (prepare_ibus_client_compat(adjacent)) {
            debug("Selected private IBus client for the affected 1.5.29 library");
            return;
        }
    } catch (FileError e) {
        // The configured install/source paths remain available below.
    }
    if (prepare_ibus_client_compat(DINOX_IBUS_COMPAT_INSTALL_PATH) ||
            (DINOX_IBUS_COMPAT_SOURCE_PATH != "" &&
             prepare_ibus_client_compat(DINOX_IBUS_COMPAT_SOURCE_PATH))) {
        debug("Selected private IBus client for the affected 1.5.29 library");
    }
}
#endif

#if WINDOWS
[CCode (has_target = false)]
private delegate Type RuntimeSmokeRegisterPluginFunction(Module module);

private string? find_startup_xmpp_uri(string[] args) {
    for (int i = 1; i < args.length; i++) {
        if (args[i].has_prefix("xmpp:")) {
            return args[i];
        }
    }
    return null;
}

private void write_pending_xmpp_uri_for_existing_instance(string uri) {
    string path = Dino.Ui.Application.get_pending_external_xmpp_uri_path();
    string dir = Path.get_dirname(path);
    if (DirUtils.create_with_parents(dir, 0700) == -1) {
        warning("Could not create pending XMPP URI directory %s", dir);
        return;
    }
    try {
        FileUtils.set_contents(path, uri);
    } catch (FileError e) {
        warning("Could not write pending XMPP URI: %s", e.message);
    }
}

private string? materialize_pixbuf_loader_cache(string exe_dir) {
    string template_path = Path.build_filename(
        exe_dir, "lib", "gdk-pixbuf-2.0", "2.10.0", "loaders.cache"
    );
    string template_data;
    try {
        FileUtils.get_contents(template_path, out template_data);
    } catch (FileError e) {
        warning("Could not read bundled pixbuf loader cache: %s", e.message);
        return null;
    }

    const string marker = "@DINOX_GDK_PIXBUF_MODULEDIR@";
    if (!template_data.contains(marker)) {
        warning("Bundled pixbuf loader cache has no portable path marker");
        return null;
    }
    string loader_dir = Path.build_filename(
        exe_dir, "lib", "gdk-pixbuf-2.0", "2.10.0", "loaders"
    ).replace("\\", "/");
    string cache_dir = Path.build_filename(
        Environment.get_user_cache_dir(), "dinox"
    );
    if (DirUtils.create_with_parents(cache_dir, 0700) == -1) {
        warning("Could not create DinoX cache directory for pixbuf loaders");
        return null;
    }
    string cache_path = Path.build_filename(
        cache_dir, "gdk-pixbuf-loaders.cache"
    );
    try {
        FileUtils.set_contents(cache_path, template_data.replace(marker, loader_dir));
    } catch (FileError e) {
        warning("Could not materialize portable pixbuf loader cache: %s", e.message);
        return null;
    }
    return cache_path;
}
#endif

private void configure_local_desktop_file_hint(string? exec_path) {
#if !WINDOWS
    if (exec_path == null) return;

    string resolved_exec = exec_path;
    if (!Path.is_absolute(resolved_exec)) {
        resolved_exec = Path.build_filename(Environment.get_current_dir(), resolved_exec);
    }

    string exe_dir = Path.get_dirname(resolved_exec);
    string desktop_file = Path.build_filename(exe_dir, "..", "..", "main", "data", "im.dinox.dinox.desktop");
    if (!FileUtils.test(desktop_file, FileTest.IS_REGULAR)) return;

    string icon_file = Path.build_filename(exe_dir, "..", "..", "main", "data", "icons", "hicolor", "256x256", "apps", "im.dinox.dinox.png");
    if (FileUtils.test(icon_file, FileTest.IS_REGULAR)) {
        string desktop_data;
        try {
            FileUtils.get_contents(desktop_file, out desktop_data);
            string generated_dir = Path.build_filename(Environment.get_user_runtime_dir(), "dinox");
            if (DirUtils.create_with_parents(generated_dir, 0700) == 0) {
                string generated_desktop = Path.build_filename(generated_dir, "im.dinox.dinox-local.desktop");
                desktop_data = desktop_data.replace("Icon=im.dinox.dinox", "Icon=%s".printf(icon_file));
                desktop_data = desktop_data.replace("Exec=dinox %U", "Exec=%s %%U".printf(resolved_exec));
                FileUtils.set_contents(generated_desktop, desktop_data);
                desktop_file = generated_desktop;
            }
        } catch (FileError e) {
            debug("Could not prepare local desktop file hint: %s", e.message);
        }
    }

    if (Environment.get_variable("GIO_LAUNCHED_DESKTOP_FILE") == null) {
        Environment.set_variable("GIO_LAUNCHED_DESKTOP_FILE", desktop_file, false);
    }
    if (Environment.get_variable("GIO_LAUNCHED_DESKTOP_FILE_PID") == null) {
        Environment.set_variable("GIO_LAUNCHED_DESKTOP_FILE_PID", "%d".printf((int) Posix.getpid()), false);
    }
    if (Environment.get_variable("BAMF_DESKTOP_FILE_HINT") == null) {
        Environment.set_variable("BAMF_DESKTOP_FILE_HINT", desktop_file, false);
    }
#endif
}

void main(string[] crt_args) {

#if WINDOWS
    // MinGW passes main() arguments in the active Windows codepage, which
    // replaces characters outside that codepage with '?'.  Always use GLib's
    // GetCommandLineW-backed UTF-8 argv so portable installs work from any
    // Unicode path and external XMPP URIs are not corrupted.
    string[] win32_args = GLib.Win32.get_command_line();
    unowned string[] args = win32_args;
#else
    unowned string[] args = crt_args;
#endif

    Crypto.initialize();
    bool runtime_smoke = false;
#if WINDOWS
    string? runtime_smoke_language = null;
#endif

#if HAVE_MALLOC_TRIM
    // Force allocations > 64 KB to use mmap instead of sbrk.  When freed,
    // mmap'd pages are returned to the OS immediately (munmap) instead of
    // lingering in glibc's arena — preventing the heap fragmentation that
    // makes malloc_trim() ineffective for large GStreamer buffer pools.
    mallopt(-3 /* M_MMAP_THRESHOLD */, 65536);
#endif

    // Handle `--version` early (before GTK/GApplication startup).
    for (int i = 1; i < args.length; i++) {
        if (args[i] == "--version") {
            stdout.printf("DinoX %s\n", Dino.get_version());
            return;
        } else if (args[i] == "--runtime-smoke") {
            runtime_smoke = true;
        }
    }

    // Deletion must run before GTK/GStreamer creates caches or opens files.
    // The internal helper exits without a UI and never acts without a request.
    bool deletion_only = false;
    bool maintenance_start = false;
    string[] normal_args = {};
    foreach (string arg in args) {
        if (arg == "--apply-pending-profile-deletion") deletion_only = true;
        else if (arg == "--complete-profile-maintenance") maintenance_start = true;
        else normal_args += arg;
    }
    args = normal_args;
    try {
        string profile = Dino.Application.get_storage_dir ();
        if (deletion_only || maintenance_start || Security.ProfileDeletion.has_pending (profile)) {
            var profile_lock = Security.ProfileLock.acquire (profile);
            Security.ProfileDeletion.apply_pending (profile_lock.profile_dir,
                Path.build_filename (Environment.get_user_config_dir (), "dinox"),
                Path.build_filename (Environment.get_user_cache_dir (), "dinox"),
                Ui.Application.get_profile_temporary_directory ());
        }
        if (deletion_only) return;
    } catch (Error err) {
        if (deletion_only) {
            stderr.printf ("Profile deletion failed: %s\n", err.message);
            Process.exit (1);
        }
        Ui.Application.profile_preflight_error = err.message;
    }

#if WINDOWS
    if (runtime_smoke) {
        uint active_code_page = CertstoreWin32.get_active_code_page();
        if (active_code_page != 65001) {
            stderr.printf(
                "Runtime smoke failed: Windows process code page is %u, expected UTF-8 (65001)\n",
                active_code_page
            );
            Process.exit(1);
        }

        string? requested_smoke_language =
            Environment.get_variable("DINOX_RUNTIME_SMOKE_LANGUAGE");
        if (requested_smoke_language != null) {
            string normalized_smoke_language = ((!) requested_smoke_language).strip();
            if (normalized_smoke_language != "de" &&
                    normalized_smoke_language != "ru") {
                stderr.printf(
                    "Runtime smoke failed: DINOX_RUNTIME_SMOKE_LANGUAGE must be de or ru\n"
                );
                Process.exit(2);
            }
            runtime_smoke_language = normalized_smoke_language;
        }
    }
#endif

    try{
        string? exec_path = args.length > 0 ? args[0] : null;

#if WINDOWS
        // Resolve exec_path to absolute path EARLY — before SearchPathGenerator
        // needs it.  On Windows Explorer launch, args[0] may be just "dinox.exe"
        // (no path separators), so Path.get_dirname() would return "." which
        // resolves to CWD (often C:\Windows\System32).  We must resolve it to
        // the actual exe directory for locale and plugin path detection.
        if (exec_path != null) {
            if (!exec_path.contains("\\") && !exec_path.contains("/")) {
                exec_path = Environment.find_program_in_path(exec_path);
            }
            if (exec_path != null && !Path.is_absolute(exec_path)) {
                exec_path = Path.build_filename(Environment.get_current_dir(), exec_path);
            }
        }
#endif

        SearchPathGenerator search_path_generator = new SearchPathGenerator(exec_path);
        configure_local_desktop_file_hint(exec_path);

#if !WINDOWS
        configure_native_gstreamer_plugin_path();
#endif

        // Apply user language override before gettext init. LANGUAGE selects the
        // gettext catalog; keep LANG as the user's working C/GTK locale so
        // languages without an installed system locale (for example nl on many
        // systems) still work.
        bool has_language_override = false;
        string? requested_language = null;
#if WINDOWS
        if (runtime_smoke_language != null) {
            requested_language = runtime_smoke_language;
            Environment.set_variable(
                "LANGUAGE", (!) runtime_smoke_language, true
            );
            // g_win32_getlocale() returns LANG verbatim when it is inherited
            // from an MSYS2 shell. Clear it first, then use the native locale
            // spelling accepted by the Windows libintl setlocale wrapper.
            Environment.unset_variable("LANG");
            string smoke_working_locale = GLib.Win32.getlocale();
            if (smoke_working_locale != "") {
                Environment.set_variable("LANG", smoke_working_locale, true);
            }
            Environment.unset_variable("LC_ALL");
            Environment.unset_variable("LC_MESSAGES");
            has_language_override = true;
        }
#endif
        string lang_file = Path.build_filename(Environment.get_user_data_dir(), "dinox", "language");
        if (!has_language_override && FileUtils.test(lang_file, FileTest.EXISTS)) {
            try {
                string lang_code;
                FileUtils.get_contents(lang_file, out lang_code);
                lang_code = lang_code.strip();
                if (lang_code != "" && lang_code != "system") {
                    requested_language = lang_code;
                    has_language_override = true;
                    string? lc_all = Environment.get_variable("LC_ALL");
                    if (lc_all != null && (lc_all == "C" || lc_all.has_prefix("C."))) {
                        Environment.unset_variable("LC_ALL");
                    }
                }
            } catch (FileError e) {
                // ignore — use system locale
            }
        }

#if WINDOWS
        // GLib/gettext on Windows does not reliably infer the Windows UI
        // language when LANG/LANGUAGE are unset. Seed LANG from the user locale
        // so "system language" works without asking users to set environment
        // variables manually.
        string? env_lang = Environment.get_variable("LANG");
        if (env_lang == null || env_lang == "") {
            string win_locale = GLib.Win32.getlocale();
            if (win_locale != "") {
                Environment.set_variable("LANG", win_locale, true);
            }
        }
#endif

        Dino.Ui.InterfaceLanguage.apply_environment(requested_language);

#if WINDOWS
        // Initialize the Microsoft CRT locale before GStreamer or GTK can
        // initialize locale-sensitive runtime state. LANG uses the native
        // Windows locale spelling understood by libintl_setlocale.
        Intl.setlocale(LocaleCategory.ALL, "");
#endif

        Intl.textdomain(GETTEXT_PACKAGE);
        internationalize(GETTEXT_PACKAGE, search_path_generator.get_locale_path(GETTEXT_PACKAGE, LOCALE_INSTALL_DIR));

#if WINDOWS
        // Windows environment setup — MUST happen BEFORE Gst.init() and Gtk.init()
        // so that GTK4 can find schemas, pixbuf loaders, and GStreamer its plugins.

        // Attach to parent console if launched from CMD/MSYS2.
        // With -mwindows the EXE is GUI subsystem (no console on double-click),
        // but when run from a terminal we want log output to be visible.
        SystrayWin32.attach_parent_console ();

        // Set AppUserModelID BEFORE any windows are created.
        // This controls taskbar grouping and is required for jump list
        // suppression to work (must happen before Gtk.init).
        SystrayWin32.set_app_id ("im.dinox.dinox");

        // Single-instance check: if another DinoX is running, activate it and exit.
        string? startup_xmpp_uri = find_startup_xmpp_uri(args);
        if (!runtime_smoke && !SystrayWin32.check_single_instance ()) {
            if (startup_xmpp_uri != null) {
                write_pending_xmpp_uri_for_existing_instance((!) startup_xmpp_uri);
            }
            SystrayWin32.activate_existing_instance();
            Process.exit (0);
        }

        string? exe_path = exec_path;  // Already resolved to absolute path above
        string exe_dir = (exe_path != null) ? Path.get_dirname(exe_path) : Environment.get_current_dir();
        if (!runtime_smoke && exe_path != null && !SystrayWin32.register_xmpp_protocol_handler((!) exe_path)) {
            warning("Could not register xmpp: protocol handler");
        }

        // Publish exe_dir so plugins can find bundled files without relying on cwd
        Environment.set_variable("DINOX_EXE_DIR", exe_dir, true);

        // GTK/GLib resource paths
        Environment.set_variable("XDG_DATA_DIRS",
            Path.build_filename(exe_dir, "share"), true);
        Environment.set_variable("XDG_CONFIG_DIRS",
            Path.build_filename(exe_dir, "etc"), true);
        Environment.set_variable("GSETTINGS_SCHEMA_DIR",
            Path.build_filename(exe_dir, "share", "glib-2.0", "schemas"), true);
        string pixbuf_loader_dir = Path.build_filename(
            exe_dir, "lib", "gdk-pixbuf-2.0", "2.10.0", "loaders"
        );
        Environment.set_variable("GDK_PIXBUF_MODULEDIR", pixbuf_loader_dir, true);
        string? pixbuf_cache = materialize_pixbuf_loader_cache(exe_dir);
        if (pixbuf_cache != null) {
            Environment.set_variable("GDK_PIXBUF_MODULE_FILE", (!) pixbuf_cache, true);
        }
        Environment.set_variable("GTK_PATH", exe_dir, true);

        // Fontconfig — tell it to use our bundled config + fonts.
        string fc_conf = Path.build_filename(exe_dir, "etc", "fonts");
        Environment.set_variable("FONTCONFIG_PATH", fc_conf, true);

        // GStreamer plugin path — only look in our bundled dir, not system.
        string gst_plugin_dir = Path.build_filename(exe_dir, "lib", "gstreamer-1.0");
        Environment.set_variable("GST_PLUGIN_PATH", gst_plugin_dir, true);
        Environment.set_variable("GST_PLUGIN_SYSTEM_PATH", "", true);

        // GStreamer registry cache — use the pre-generated one next to the
        // plugins if it exists (created by update_dist.sh), otherwise fall
        // back to a user-data cache so subsequent starts are still fast.
        string bundled_registry = Path.build_filename(gst_plugin_dir, "registry.bin");
        if (FileUtils.test(bundled_registry, FileTest.EXISTS)) {
            Environment.set_variable("GST_REGISTRY", bundled_registry, true);
        } else {
            // Runtime caches must not create or modify the profile before the
            // primary application's profile lock and pending restore checks.
            string gst_cache_dir = Path.build_filename(Environment.get_user_cache_dir(), "dinox");
            DirUtils.create_with_parents(gst_cache_dir, 0700);
            Environment.set_variable("GST_REGISTRY",
                Path.build_filename(gst_cache_dir, "gstreamer-registry.bin"), true);
        }

        // Force GnuTLS to find the CA bundle.
        // Strategy: merge Windows system cert store + bundled MSYS2 ca-bundle.crt
        // so that CAs trusted by *either* source are accepted.  This avoids the
        // common problem where the MSYS2 bundle is outdated (e.g. missing ISRG
        // Root X1) even though Windows itself trusts Let's Encrypt.
        string? trusted_certs = Environment.get_variable("GTLS_SYSTEM_CA_FILE");
        if (trusted_certs == null) {
            string? ca_path = null;

            // Locate bundled CA bundle from MSYS2
            string local_cert = Path.build_filename(exe_dir, "ssl", "certs", "ca-bundle.crt");
            string local_cert_flat = Path.build_filename(exe_dir, "ca-bundle.crt");
            string? bundled_path = null;
            if (FileUtils.test(local_cert, FileTest.EXISTS)) {
                bundled_path = local_cert;
            } else if (FileUtils.test(local_cert_flat, FileTest.EXISTS)) {
                bundled_path = local_cert_flat;
            }

            // Export Windows system ROOT certificates and merge with bundled bundle
            string cache_dir = Path.build_filename(Environment.get_user_cache_dir(), "dinox");
            DirUtils.create_with_parents(cache_dir, 0700);
            string cached_pem = Path.build_filename(cache_dir, "merged-ca-bundle.pem");
            bool have_windows = CertstoreWin32.export_pem(cached_pem);

            if (have_windows && bundled_path != null) {
                // Append bundled Mozilla roots for maximum coverage
                try {
                    uint8[] bundled_data;
                    FileUtils.get_data(bundled_path, out bundled_data);
                    var file = File.new_for_path(cached_pem);
                    var os = file.append_to(FileCreateFlags.NONE);
                    os.write(bundled_data);
                    os.close();
                } catch (Error e) {
                    warning("Failed to append bundled CA certs: %s", e.message);
                }
                ca_path = cached_pem;
                debug("Merged Windows root certs + %s → %s", bundled_path, cached_pem);
            } else if (have_windows) {
                ca_path = cached_pem;
                debug("Using Windows root certificates: %s", cached_pem);
            } else if (bundled_path != null) {
                ca_path = bundled_path;
            } else {
                warning("No CA certificates available — TLS connections will fail");
            }

            if (ca_path != null) {
                Environment.set_variable("GTLS_SYSTEM_CA_FILE", ca_path, true);
                Environment.set_variable("SSL_CERT_FILE", ca_path, true);
                string ca_dir = Path.get_dirname(ca_path);
                Environment.set_variable("SSL_CERT_DIR", ca_dir, true);
                debug("Set GTLS_SYSTEM_CA_FILE to %s", ca_path);

                // Explicitly set the default TLS trust database from our merged
                // CA bundle.  Env vars alone are unreliable: glib-networking on
                // MSYS2/MinGW may use a backend (OpenSSL/SChannel) that ignores
                // GTLS_SYSTEM_CA_FILE.  This forces ALL TlsConnections to verify
                // against our merged Windows + Mozilla root certificates.
                try {
                    TlsDatabase? tls_db = create_tls_file_database(ca_path);
                    if (tls_db != null) {
                        TlsBackend.get_default().set_default_database(tls_db);
                        debug("TLS trust database loaded: %s", ca_path);
                    } else {
                        warning("Failed to load TLS database from %s", ca_path);
                        if (runtime_smoke) {
                            stderr.printf(
                                "Runtime smoke failed: TLS trust database could not be loaded\n"
                            );
                            Process.exit(1);
                        }
                    }
                } catch (Error e) {
                    warning("Failed to load TLS database from %s: %s", ca_path, e.message);
                    if (runtime_smoke) {
                        stderr.printf(
                            "Runtime smoke failed: TLS trust database could not be loaded: %s\n",
                            e.message
                        );
                        Process.exit(1);
                    }
                }
            }
        }

        // Add exe directory AND bin/ folder to PATH so DLLs and tools are found
        string bin_path = Path.build_filename(exe_dir, "bin");
        {
            string? old_path = Environment.get_variable("PATH");
            string new_path = exe_dir;
            if (FileUtils.test(bin_path, FileTest.IS_DIR)) {
                new_path = exe_dir + ";" + bin_path;
            }
            if (old_path != null) {
                new_path = new_path + ";" + old_path;
            }
            Environment.set_variable("PATH", new_path, true);
            debug("PATH prepended: %s", exe_dir);
        }

        // Suppress "win32 session dbus binary not found" warning
        Environment.set_variable("DBUS_SESSION_BUS_ADDRESS", "", true);

        // Prevent GStreamer from forking gst-plugin-scanner.exe (which
        // flashes a CMD window).  In-process scanning is fine for us.
        Environment.set_variable("GST_REGISTRY_FORK", "no", true);

        // Suppress CRT invalid-parameter-handler assertions BEFORE Gst.init().
        // GStreamer's MediaFoundation plugin scanning triggers CRT invalid parameter
        // calls in worker threads which corrupt GLib's handler stack.
        SystrayWin32.suppress_crt_assertions();
#endif

#if LINUX
        try {
            Dino.AppImageTlsTrust.configure(
                Environment.get_variable("APPIMAGE"),
                Environment.get_variable("GTLS_SYSTEM_CA_FILE"));
        } catch (Error e) {
            // Do not silently fall back to a different or empty trust store.
            stderr.printf("AppImage system certificate setup failed: %s\n", e.message);
            Process.exit(1);
        }
#endif

        debug("Initializing GStreamer…");
        Gst.init(ref args);
        debug("GStreamer initialized");

#if WINDOWS
        bool gst_startup_diagnostics = Environment.get_variable("DINOX_GST_STARTUP_DIAGNOSTICS") == "1";
        if (gst_startup_diagnostics) {
            // Keep this opt-in on Windows: enumerating factories can force
            // plugin DLL loading and make the first UI frame look hung.
            var registry = Gst.Registry.@get();
            var plugins = registry.get_plugin_list();
            debug("GStreamer: %u plugins loaded from %s",
                    plugins.length(),
                    Environment.get_variable("GST_PLUGIN_PATH") ?? "(default)");
            string[] critical = {"playbin", "videoconvert", "appsink",
                                 "qtdemux", "matroskademux", "avdec_h264",
                                 "openh264dec", "avdec_aac", "opusdec",
                                 "wasapi2src", "mfvideosrc",
                                 "mfh264enc", "mfaacenc",
                                 "aacparse", "h264parse", "mp4mux",
                                 "audioconvert", "audioresample",
                                 "filesink", "uridecodebin"};
            foreach (string el in critical) {
                var factory = Gst.ElementFactory.find(el);
                if (factory == null) {
                    warning("GStreamer: MISSING element '%s' — video playback may fail!", el);
                }
            }
        }

        // Pre-warm Media Foundation and codec DLLs in a background thread.
        // First use of mfvideosrc/mfh264enc/wasapi2src loads multiple Windows
        // system DLLs (mfplat.dll, mfreadwrite.dll, evr.dll, d3d11.dll, etc.)
        // which takes several seconds.  Do not do this by default: even in a
        // worker thread it can contend with registry/plugin locks and make a
        // fresh Windows start appear unresponsive.
        if (Environment.get_variable("DINOX_GST_WARMUP") == "1") {
            new Thread<void*>("gst-mf-warmup", () => {
                int64 tw0 = GLib.get_monotonic_time();
                var wv = Gst.ElementFactory.make("mfvideosrc", null);
                if (wv != null) { wv.set_state(Gst.State.READY); wv.set_state(Gst.State.NULL); wv = null; }
                var we = Gst.ElementFactory.make("mfh264enc", null);
                if (we != null) { we.set_state(Gst.State.READY); we.set_state(Gst.State.NULL); we = null; }
                var wa = Gst.ElementFactory.make("wasapi2src", null);
                if (wa != null) { wa.set_state(Gst.State.READY); wa.set_state(Gst.State.NULL); wa = null; }
                var waac = Gst.ElementFactory.make("avenc_aac", null);
                waac = null;
                var wmux = Gst.ElementFactory.make("mp4mux", null);
                wmux = null;
                debug("GStreamer MF warm-up completed in %lldms",
                      (GLib.get_monotonic_time() - tw0) / 1000);
                return null;
            });
        }
#endif

        // Suppress "Locale not supported by C library" by falling back gracefully.
        // This happens when the system locale (e.g. a custom locale on openSUSE)
        // isn't available in the C library or in AppImage's bundled glibc.
        // We must also update LANG so that Gtk.init() (which re-reads the
        // environment) does not fail with the same warning.
        if (Intl.setlocale(LocaleCategory.ALL, "") == null) {
            string? lang = Environment.get_variable("LANG");
            string? working_locale = null;
            if (lang != null) {
                string base_lang = lang.split(".")[0];
#if WINDOWS
                string candidate = base_lang;
#else
                string candidate = base_lang + ".UTF-8";
#endif
                if (Intl.setlocale(LocaleCategory.ALL, candidate) != null) {
                    working_locale = candidate;
                }
            }
            if (working_locale == null) {
                if (Intl.setlocale(LocaleCategory.ALL, "C.UTF-8") != null) {
                    working_locale = "C.UTF-8";
                } else if (Intl.setlocale(LocaleCategory.ALL, "C") != null) {
                    working_locale = "C";
                }
            }
            // Update environment so Gtk.init() picks up the working locale
            if (working_locale != null) {
                Environment.set_variable("LC_ALL", (!) working_locale, true);
            }
        }

        // GTK4 does not support legacy GTK3-era IM modules.  If GTK_IM_MODULE
        // is set to a GTK3-only module (e.g. "cedilla", "xim"), GTK4 prints
        // "No IM module matching GTK_IM_MODULE=… found".  Unset only known
        // GTK3-only modules; leave ibus, fcitx5, etc. alone (GTK4 supports them).
        string? im_module = Environment.get_variable("GTK_IM_MODULE");
        if (im_module == "cedilla" || im_module == "xim") {
            Environment.unset_variable("GTK_IM_MODULE");
        }

#if !WINDOWS
        // Preserve synchronous key ordering and explicit user configuration.
        // Mode 2 can reorder rapid input; it is not a compatibility workaround.
        if (Environment.get_variable("IBUS_ENABLE_SYNC_MODE") == null) {
            Environment.set_variable("IBUS_ENABLE_SYNC_MODE", "1", false);
        }
#endif

#if LINUX
        // Select the corrected client before GTK initializes any IBus types.
        // Modern/unknown libraries and other input methods remain unchanged.
        prepare_ibus_compat();
#endif

        debug("Initializing GTK…");
        Gtk.init();
        Dino.Ui.InterfaceLanguage.apply_direction();
        debug("GTK initialized");
        
        // Ensure custom widget types are registered before loading templates that use them
        typeof(Dino.Ui.SizeRequestBox).ensure();
        typeof(Dino.Ui.NaturalSizeIncrease).ensure();
        typeof(Dino.Ui.SizingBin).ensure();

#if WINDOWS
        if (runtime_smoke) {
            if (exec_path == null) {
                stderr.printf("Runtime smoke failed: executable path could not be resolved\n");
                Process.exit(1);
            }

            if (runtime_smoke_language != null) {
                string translated_preferences = _("Preferences");
                if (translated_preferences == "" ||
                        translated_preferences == "Preferences") {
                    stderr.printf(
                        "Runtime smoke failed: main translation catalog was not applied for %s\n",
                        (!) runtime_smoke_language
                    );
                    Process.exit(1);
                }
                string translation_digest = Checksum.compute_for_string(
                    ChecksumType.SHA256, translated_preferences
                );
                stdout.printf(
                    "DinoX Windows portable translation smoke OK (%s:%s)\n",
                    (!) runtime_smoke_language,
                    translation_digest
                );
            }

            string runtime_icon_path = Path.build_filename(
                Path.get_dirname((!) exec_path),
                "share", "icons", "hicolor", "48x48", "apps",
                "im.dinox.dinox.png"
            );
            try {
                var runtime_icon = new Gdk.Pixbuf.from_file(runtime_icon_path);
                if (runtime_icon.width <= 0 || runtime_icon.height <= 0) {
                    stderr.printf("Runtime smoke failed: bundled PNG has invalid dimensions\n");
                    Process.exit(1);
                }
            } catch (Error e) {
                stderr.printf("Runtime smoke failed: could not decode bundled PNG: %s\n",
                    e.message);
                Process.exit(1);
            }

            string[] required_gstreamer_elements = {
                "playbin",
                "uridecodebin",
                "appsink",
                "qtdemux",
                "matroskademux",
                "audioconvert",
                "audioresample",
                "videoconvert"
            };
            foreach (string element_name in required_gstreamer_elements) {
                if (Gst.ElementFactory.find(element_name) == null) {
                    stderr.printf("Runtime smoke failed: missing GStreamer element %s\n", element_name);
                    Process.exit(1);
                }
            }

            string plugin_dir = Path.build_filename(Path.get_dirname((!) exec_path), "plugins");
            string[] required_plugins = {
                "google-webrtc.dll",
                "http-files.dll",
                "ice.dll",
                "notification-sound.dll",
                "omemo.dll",
                "openpgp.dll",
                "mqtt.dll",
                "libtor-manager.dll",
                "bot-features.dll"
            };
            Module[] loaded_modules = new Module[0];
            foreach (string plugin_name in required_plugins) {
                string plugin_path = Path.build_filename(plugin_dir, plugin_name);
                Module module = Module.open(plugin_path, ModuleFlags.LAZY);
                if (module == null) {
                    stderr.printf("Runtime smoke failed: could not load %s: %s\n",
                        plugin_name, Module.error());
                    Process.exit(1);
                }
                void* register_function;
                module.symbol("register_plugin", out register_function);
                if (register_function == null) {
                    stderr.printf("Runtime smoke failed: register_plugin missing in %s\n",
                        plugin_name);
                    Process.exit(1);
                }
                RuntimeSmokeRegisterPluginFunction register_plugin =
                    (RuntimeSmokeRegisterPluginFunction) register_function;
                Type plugin_type = register_plugin(module);
                if (!plugin_type.is_a(typeof(Dino.Plugins.RootInterface))) {
                    stderr.printf(
                        "Runtime smoke failed: register_plugin returned an unexpected type for %s\n",
                        plugin_name
                    );
                    Process.exit(1);
                }
                // register_plugin() installs a static GType whose class
                // implementation remains inside this DLL. Keep the module
                // loaded until the smoke process exits, like the production
                // plugin loader does for the application lifetime.
                module.make_resident();
                loaded_modules += (owned) module;
            }

            try {
                Dino.Ui.Application.run_windows_backup_unicode_runtime_smoke ();
            } catch (Error err) {
                stderr.printf (
                    "Runtime smoke failed: Windows backup Unicode tar roundtrip: %s\n",
                    err.message
                );
                Process.exit (1);
            }

            stdout.printf("DinoX Windows portable runtime smoke OK (%d plugins)\n",
                loaded_modules.length);
            return;
        }
#else
        if (runtime_smoke) {
            stderr.printf("--runtime-smoke is only supported by the packaged Windows build\n");
            Process.exit(2);
        }
#endif

        Dino.Ui.Application app = new Dino.Ui.Application() { search_path_generator=search_path_generator };

#if WINDOWS
        // Do not access Gdk.Display, Gtk.IconTheme, or Gtk.Settings here.
        // GTK4/Win32 can still be finalizing display startup after Gtk.init(),
        // and touching display-scoped objects before GApplication::startup has
        // caused startup SIGSEGVs in packaged Windows builds.  The portable
        // distribution provides icon, font, and decoration defaults through
        // XDG_DATA_DIRS, XDG_CONFIG_DIRS, Fontconfig, and bundled GTK settings
        // files instead.
#endif

        // Probe system CA certificate locations on ALL platforms.
        // GnuTLS compiled on Ubuntu defaults to /etc/ssl/certs/ca-certificates.crt
        // which doesn't exist on openSUSE, Fedora, Alpine, etc.
        // On Windows the paths simply don't exist, so the loop is a harmless no-op.
        if (Environment.get_variable("GTLS_SYSTEM_CA_FILE") == null) {
            string[] system_ca_paths = {
                "/etc/ssl/certs/ca-certificates.crt",       // Debian, Ubuntu, Arch, Gentoo
                "/etc/pki/tls/certs/ca-bundle.crt",         // Fedora, RHEL, CentOS
                "/etc/ssl/ca-bundle.pem",                   // openSUSE
                "/var/lib/ca-certificates/ca-bundle.pem",   // openSUSE (alternative)
                "/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem", // Fedora p11-kit
                "/etc/ssl/cert.pem",                        // Alpine, macOS
            };
            foreach (string path in system_ca_paths) {
                if (FileUtils.test(path, FileTest.EXISTS)) {
                    Environment.set_variable("GTLS_SYSTEM_CA_FILE", path, true);
                    debug("Set GTLS_SYSTEM_CA_FILE to %s (system CA)", path);
                    break;
                }
            }
        }

        Plugins.Loader loader = new Plugins.Loader(app);
        app.plugin_loader = loader;

        app.run(args);

        app.shutdown_plugins_once();
    } catch (Error e) {
        warning(@"Fatal error: $(e.message)");
    }
}

#if !WINDOWS
private void configure_native_gstreamer_plugin_path() {
    if (Environment.get_variable("GST_PLUGIN_SYSTEM_PATH") != null) return;

    string cache_dir = Path.build_filename(
        Environment.get_user_cache_dir(),
        "dinox",
        "gstreamer-plugins-no-va-msdk"
    );
    if (DirUtils.create_with_parents(cache_dir, 0700) != 0) return;

    string[] plugin_dirs = {
        "/usr/lib/x86_64-linux-gnu/gstreamer-1.0",
        "/usr/lib/aarch64-linux-gnu/gstreamer-1.0",
        "/usr/lib/gstreamer-1.0",
        "/usr/local/lib/gstreamer-1.0",
        "/lib/x86_64-linux-gnu/gstreamer-1.0",
        "/lib/aarch64-linux-gnu/gstreamer-1.0"
    };

    bool has_plugins = false;
    foreach (string plugin_dir in plugin_dirs) {
        if (!FileUtils.test(plugin_dir, FileTest.IS_DIR)) continue;

        try {
            Dir dir = Dir.open(plugin_dir, 0);
            string? entry = null;
            while ((entry = dir.read_name()) != null) {
                if (!entry.has_prefix("libgst") || !entry.has_suffix(".so")) continue;
                if (entry == "libgstva.so" || entry == "libgstvaapi.so" || entry == "libgstmsdk.so") continue;

                string source = Path.build_filename(plugin_dir, entry);
                string target = Path.build_filename(cache_dir, entry);
                if (!FileUtils.test(target, FileTest.EXISTS)) {
                    Posix.symlink(source, target);
                }
                has_plugins = true;
            }
        } catch (FileError e) {
            debug("Skipping GStreamer plugin directory %s: %s", plugin_dir, e.message);
        }
    }

    if (!has_plugins) return;

    Environment.set_variable("GST_PLUGIN_SYSTEM_PATH", cache_dir, true);
    if (Environment.get_variable("GST_REGISTRY") == null) {
        Environment.set_variable(
            "GST_REGISTRY",
            Path.build_filename(Environment.get_user_cache_dir(), "dinox", "gstreamer-registry-no-va-msdk.bin"),
            true
        );
    }
}
#endif

}

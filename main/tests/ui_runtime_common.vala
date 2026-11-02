namespace Dino.Ui.Test {

[CCode (cname = "gtk_style_context_add_provider_for_display", cheader_filename = "gtk/gtk.h")]
private static extern void add_runtime_style_provider(Gdk.Display display,
    Gtk.StyleProvider provider, uint priority);

int main(string[] crt_args) {
#if WINDOWS
    // Match the application: MinGW's narrow CRT argv can lose Unicode paths.
    string[] win32_args = GLib.Win32.get_command_line();
    unowned string[] args = win32_args;
#else
    unowned string[] args = crt_args;
#endif
    string profile;
    try {
        profile = DirUtils.make_tmp("dinox-ui-runtime-XXXXXX");
    } catch (Error error) {
        stderr.printf("Could not create isolated UI runtime profile: %s\n", error.message);
        return 1;
    }
    // Set this before GTK/GLib cache user paths. Tests never touch a user profile.
    Environment.set_variable("XDG_DATA_HOME", Path.build_filename(profile, "data"), true);
    Environment.set_variable("XDG_CACHE_HOME", Path.build_filename(profile, "cache"), true);
    Environment.set_variable("XDG_CONFIG_HOME", Path.build_filename(profile, "config"), true);
    GLib.Test.init(ref args);
    GLib.Test.set_nonfatal_assertions();
    // Optional built catalog for exercising the actual translated UI. Normal
    // runs keep their existing locale and never depend on installed catalogs.
    string? locale_dir = Environment.get_variable("DINOX_UI_TEST_LOCALE_DIR");
    string? matrix_language = Environment.get_variable("DINOX_TEST_APP_LANGUAGE");
    if (matrix_language != null) {
        if (Intl.setlocale(LocaleCategory.ALL, "") == null) return 77;
        if (InterfaceLanguage.apply_environment(matrix_language) != matrix_language) return 1;
        var paths = new SearchPathGenerator(args[0]);
        foreach (string domain in new string[] { "dino", "dino-omemo", "dino-openpgp" }) {
            Dino.internationalize(domain, paths.get_locale_path(domain, "/usr/share/locale"));
        }
    } else if (locale_dir != null) {
        // gettext ignores LANGUAGE while the process still uses the C locale.
        // Match main.vala for explicit translated UI runs, including Windows.
        Intl.setlocale(LocaleCategory.ALL, "");
        Intl.bindtextdomain("dino", locale_dir);
        Intl.bind_textdomain_codeset("dino", "UTF-8");
    }
    // Match main.vala: GtkBuilder uses the process default text domain,
    // while Vala's _() calls address the package domain explicitly.
    Intl.textdomain("dino");
    Gst.init(ref args);
    Gtk.init();
    InterfaceLanguage.apply_direction();
    Adw.init();
    Gtk.IconTheme.get_for_display(Gdk.Display.get_default())
        .add_resource_path("/im/dinox/dinox/icons");
    var stylesheet = new Gtk.CssProvider();
    stylesheet.load_from_resource("/im/dinox/dinox/style.css");
    add_runtime_style_provider(Gdk.Display.get_default(),
        stylesheet, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
    typeof(Dino.Ui.SizingBin).ensure();
    typeof(Dino.Ui.AvatarPicture).ensure();

    TestSuite.get_root().add_suite(new MucHistoryPreferencesRuntimeTest().get_suite());
    TestSuite.get_root().add_suite(new HistoryReloadShortcutRuntimeTest().get_suite());
    TestSuite.get_root().add_suite(new FileDefaultWidgetRuntimeTest().get_suite());
    TestSuite.get_root().add_suite(new FileTransferInputRuntimeTest().get_suite());
    TestSuite.get_root().add_suite(new FileWidgetControllerRuntimeTest().get_suite());
    TestSuite.get_root().add_suite(new CallBottomBarRuntimeTest().get_suite());
    TestSuite.get_root().add_suite(new VideoRecorderPopoverRuntimeTest().get_suite());
    TestSuite.get_root().add_suite(new MessageActionTargetRuntimeTest().get_suite());
    TestSuite.get_root().add_suite(new WidgetFocusLifecycleRuntimeTest().get_suite());
    TestSuite.get_root().add_suite(new ServerAdministrationTextRuntimeTest().get_suite());
    TestSuite.get_root().add_suite(new ProviderDirectoryUiRuntimeTest().get_suite());
    TestSuite.get_root().add_suite(new UserSearchRuntimeTest().get_suite());
    TestSuite.get_root().add_suite(new ContactSelectionViewRuntimeTest().get_suite());
    TestSuite.get_root().add_suite(new StickerRuntimeTest().get_suite());
    TestSuite.get_root().add_suite(new StickerAnimationRuntimeTest().get_suite());
    TestSuite.get_root().add_suite(new AudioVideoPreferencesRuntimeTest().get_suite());
    TestSuite.get_root().add_suite(new AudioPlayerRuntimeTest().get_suite());
    TestSuite.get_root().add_suite(new VideoPlayerRuntimeTest().get_suite());
    TestSuite.get_root().add_suite(new VoiceRecorderRuntimeTest().get_suite());
    TestSuite.get_root().add_suite(new ConversationSidebarRuntimeTest().get_suite());
    TestSuite.get_root().add_suite(new FrameRenderQueueRuntimeTest().get_suite());
    TestSuite.get_root().add_suite(new ConversationSelectorRowRuntimeTest().get_suite());
    TestSuite.get_root().add_suite(new MessageMentionRuntimeTest().get_suite());
    TestSuite.get_root().add_suite(new ChatPreviewLayoutRuntimeTest().get_suite());
    TestSuite.get_root().add_suite(new ResponsiveContentRuntimeTest().get_suite());
    TestSuite.get_root().add_suite(new ConversationDetailsRuntimeTest().get_suite());
    TestSuite.get_root().add_suite(new FeedsRuntimeTest().get_suite());
    TestSuite.get_root().add_suite(new LoginProtectionStatusRuntimeTest().get_suite());
    TestSuite.get_root().add_suite(new OccupantHatBadgesRuntimeTest().get_suite());
    TestSuite.get_root().add_suite(new OccupantListRuntimeTest().get_suite());
    TestSuite.get_root().add_suite(new HatsManagementRuntimeTest().get_suite());
    TestSuite.get_root().add_suite(new HatsCommandDialogRuntimeTest().get_suite());
    TestSuite.get_root().add_suite(new InterfaceStyleRuntimeTest().get_suite());
    TestSuite.get_root().add_suite(new InterfaceLanguageRuntimeTest().get_suite());
    TestSuite.get_root().add_suite(new ChatFontPreferencesRuntimeTest().get_suite());
    TestSuite.get_root().add_suite(new WindowsFontSettingsRuntimeTest().get_suite());
    TestSuite.get_root().add_suite(new ChatTextViewRuntimeTest().get_suite());
    TestSuite.get_root().add_suite(new RecordingSendContextTest().get_suite());
    TestSuite.get_root().add_suite(new EncryptionInputStatusPolicyTest().get_suite());
    int result = GLib.Test.run();
    remove_runtime_profile(File.new_for_path(profile));
    return result;
}

private void remove_runtime_profile(File file) {
    try {
        if (file.query_file_type(FileQueryInfoFlags.NOFOLLOW_SYMLINKS) == FileType.DIRECTORY) {
            var children = file.enumerate_children("standard::name", FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
            FileInfo? child;
            while ((child = children.next_file()) != null) remove_runtime_profile(file.get_child(child.get_name()));
            children.close();
        }
        file.delete();
    } catch (Error ignored) { }
}

bool fail_if(bool exp, string? reason = null) {
    if (exp) {
        if (reason != null) GLib.Test.message(reason);
        GLib.Test.fail();
        return true;
    }
    return false;
}

bool fail_if_not(bool exp, string? reason = null) {
    return fail_if(!exp, reason);
}

bool fail_if_not_eq_int(int expected, int actual, string? reason = null) {
    return fail_if(expected != actual,
        @"$(reason != null ? reason + ": " : "")$(expected) != $(actual)");
}

bool fail_if_not_eq_str(string expected, string actual, string? reason = null) {
    return fail_if(expected != actual,
        @"$(reason != null ? reason + ": " : "")\"$(expected)\" != \"$(actual)\"");
}

void fail_if_reached(string? reason = null) {
    fail_if(true, reason);
}

void assert_true(bool condition, string? reason = null) {
    fail_if_not(condition, reason);
}

void assert_false(bool condition, string? reason = null) {
    fail_if(condition, reason);
}

}

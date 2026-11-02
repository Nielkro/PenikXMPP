int main(string[] crt_args) {
#if WINDOWS
    // Match the application: MinGW's narrow CRT argv can lose Unicode paths.
    string[] win32_args = GLib.Win32.get_command_line();
    unowned string[] args = win32_args;
#else
    unowned string[] args = crt_args;
#endif
    GLib.Test.init(ref args);
    GLib.Test.set_nonfatal_assertions();

    TestSuite.get_root().add_suite(new Dino.Plugins.BotFeatures.Test.RateLimiterTest().get_suite());
    TestSuite.get_root().add_suite(new Dino.Plugins.BotFeatures.Test.PermissionUtilsTest().get_suite());
    TestSuite.get_root().add_suite(new Dino.Plugins.BotFeatures.Test.CryptoTest().get_suite());
    TestSuite.get_root().add_suite(new Dino.Plugins.BotFeatures.Test.HttpApiTest().get_suite());
    // Security Audit Tests (spec-based, expected to FAIL = bugs found)
    TestSuite.get_root().add_suite(new Dino.Plugins.BotFeatures.Test.RateLimiterAudit().get_suite());
    TestSuite.get_root().add_suite(new Dino.Plugins.BotFeatures.Test.JSONEscapeAudit().get_suite());

    return GLib.Test.run();
}

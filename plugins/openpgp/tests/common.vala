namespace OpenPgp.Test {

int main(string[] crt_args) {
#if WINDOWS
    // Match the application: MinGW's narrow CRT argv can lose Unicode paths.
    string[] win32_args = GLib.Win32.get_command_line();
    unowned string[] args = win32_args;
#else
    unowned string[] args = crt_args;
#endif
    GLib.Test.init(ref args);
    if (Environment.get_variable("DINOX_TEST_APP_LANGUAGE") != null &&
            Intl.setlocale(LocaleCategory.ALL, "") == null) return 77;
    GLib.Test.set_nonfatal_assertions();
    TestSuite.get_root().add_suite(new StreamModuleLogicTest().get_suite());
    TestSuite.get_root().add_suite(new GPGKeylistParserTest().get_suite());
    TestSuite.get_root().add_suite(new SecretKeyBackupTest().get_suite());
    TestSuite.get_root().add_suite(new KeyPublicationLifecycleTest().get_suite());
    TestSuite.get_root().add_suite(new ArmorParserTest().get_suite());
    TestSuite.get_root().add_suite(new LiveGPGHelperTest().get_suite());
    TestSuite.get_root().add_suite(new RemoteOpenPgpPrivateMucHttpSmokeTest().get_suite());
    TestSuite.get_root().add_suite(new FileDecryptorTest().get_suite());
    return GLib.Test.run();
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

bool fail_if_not_eq_int(int left, int right, string? reason = null) {
    return fail_if_not(left == right, @"$(reason + ": " ?? "")$left != $right");
}

bool fail_if_not_eq_str(string left, string right, string? reason = null) {
    return fail_if_not(left == right, @"$(reason + ": " ?? "")$left != $right");
}

bool fail_if_null(void* what, string? reason = null) {
    return fail_if(what == null || (size_t)what == 0, reason);
}

}

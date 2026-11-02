int main(string[] crt_args) {
#if WINDOWS
    // Match the application: MinGW's narrow CRT argv can lose Unicode paths.
    string[] win32_args = GLib.Win32.get_command_line();
    unowned string[] args = win32_args;
#else
    unowned string[] args = crt_args;
#endif
    Environment.set_variable("GSETTINGS_BACKEND", "memory", true);
    GLib.Test.init(ref args);
    GLib.Test.set_nonfatal_assertions();

    TestSuite.get_root().add_suite(new Dino.Plugins.HttpFiles.Test.UrlRegexTest().get_suite());
    TestSuite.get_root().add_suite(new Dino.Plugins.HttpFiles.Test.FileNameExtractionTest().get_suite());
    TestSuite.get_root().add_suite(new Dino.Plugins.HttpFiles.Test.SanitizeLogTest().get_suite());
    TestSuite.get_root().add_suite(new Dino.Plugins.HttpFiles.Test.AccountHttpSessionPoolTest().get_suite());
    TestSuite.get_root().add_suite(new Dino.Plugins.HttpFiles.Test.MetadataHeadCancellationTest().get_suite());
    TestSuite.get_root().add_suite(new Dino.Plugins.HttpFiles.Test.HttpDownloadCancellationTest().get_suite());
    TestSuite.get_root().add_suite(new Dino.Plugins.HttpFiles.Test.HttpDownloadTransportConcurrencyTest().get_suite());
    TestSuite.get_root().add_suite(new Dino.Plugins.HttpFiles.Test.HttpUploadRequestTest().get_suite());
    TestSuite.get_root().add_suite(new Dino.Plugins.HttpFiles.Test.HttpPrepareSendFileTest().get_suite());
    TestSuite.get_root().add_suite(new Dino.Plugins.HttpFiles.Test.RemotePrivateMucHttpSmokeTest().get_suite());
    TestSuite.get_root().add_suite(new Dino.Plugins.HttpFiles.Test.RemoteForeignHttpUploadSmokeTest().get_suite());
    TestSuite.get_root().add_suite(new Dino.Plugins.HttpFiles.Test.ReceiveEncryptionClassificationTest().get_suite());
    TestSuite.get_root().add_suite(new Dino.Plugins.HttpFiles.Test.OutgoingFileLinkTest().get_suite());
    TestSuite.get_root().add_suite(new Dino.Plugins.HttpFiles.Test.SfsSourceSelectionTest().get_suite());

    return GLib.Test.run();
}

void fail_if(bool condition, string? msg = null) {
    if (condition) GLib.Test.fail();
    if (condition && msg != null) GLib.Test.message("FAIL: %s", msg);
}

void fail_if_not(bool condition, string? msg = null) {
    fail_if(!condition, msg);
}

void fail_if_not_eq_str(string expected, string actual, string? msg = null) {
    if (expected != actual) {
        GLib.Test.fail();
        GLib.Test.message("Expected '%s' but got '%s'", expected, actual);
        if (msg != null) GLib.Test.message("FAIL: %s", msg);
    }
}

void fail_if_not_eq_int(int expected, int actual, string? msg = null) {
    if (expected != actual) {
        GLib.Test.fail();
        GLib.Test.message("Expected %d but got %d", expected, actual);
        if (msg != null) GLib.Test.message("FAIL: %s", msg);
    }
}

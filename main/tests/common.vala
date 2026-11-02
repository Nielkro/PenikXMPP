namespace Dino.Ui.Test {

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
    Gst.init(ref args);
    GLib.Test.set_nonfatal_assertions();
    TestSuite.get_root().add_suite(new BotProviderSelectionTest().get_suite());
    TestSuite.get_root().add_suite(new AccountConnectionInputTest().get_suite());
    TestSuite.get_root().add_suite(new PreferencesRowTest().get_suite());
    TestSuite.get_root().add_suite(new DataFormViewModelTest().get_suite());
    TestSuite.get_root().add_suite(new ServerAdministrationLabelsTest().get_suite());
    TestSuite.get_root().add_suite(new ContactListModelTest().get_suite());
    TestSuite.get_root().add_suite(new ContactListSelectionModelTest().get_suite());
    TestSuite.get_root().add_suite(new ContactRosterModelSourceTest().get_suite());
    TestSuite.get_root().add_suite(new ContactSubscriptionModelTest().get_suite());
    TestSuite.get_root().add_suite(new InitialSnapshotWaitPolicyTest().get_suite());
    TestSuite.get_root().add_suite(new MucMemberListSectionTest().get_suite());
    TestSuite.get_root().add_suite(new MucStatusMessagesTest().get_suite());
    TestSuite.get_root().add_suite(new ProviderDirectoryTest().get_suite());
    TestSuite.get_root().add_suite(new UpdateCheckerTest().get_suite());
    TestSuite.get_root().add_suite(new MediaAudioPlaybackBridgeTest().get_suite());
    TestSuite.get_root().add_suite(new VideoPlaybackLifecycleTest().get_suite());
    TestSuite.get_root().add_suite(new FileTransferInputTest().get_suite());
    TestSuite.get_root().add_suite(new RecordingSendContextTest().get_suite());
    TestSuite.get_root().add_suite(new PendingPlaintextSendTest().get_suite());
    TestSuite.get_root().add_suite(new EncryptionInputStatusPolicyTest().get_suite());
    TestSuite.get_root().add_suite(new MessageDiagnosticsTest().get_suite());
    TestSuite.get_root().add_suite(new UiHelperAudit().get_suite());
    return GLib.Test.run();
}

void fail_if_not_eq_str(string expected, string actual) {
    if (expected != actual) {
        GLib.Test.message(@"Expected \"$(expected)\" but got \"$(actual)\"");
        GLib.Test.fail();
    }
}

void fail_if_not_eq_int(int expected, int actual) {
    if (expected != actual) {
        GLib.Test.message(@"Expected $(expected) but got $(actual)");
        GLib.Test.fail();
    }
}

void assert_true(bool condition, string? reason = null) {
    if (!condition) {
        if (reason != null) GLib.Test.message(reason);
        GLib.Test.fail();
    }
}

void assert_false(bool condition, string? reason = null) {
    if (condition) {
        if (reason != null) GLib.Test.message(reason);
        GLib.Test.fail();
    }
}

}

namespace Omemo.Test {

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
    Dino.Plugins.Omemo.TrustManager.set_omemo2_runtime_test_override(true);
    TestSuite.get_root().add_suite(new Curve25519().get_suite());
    TestSuite.get_root().add_suite(new SessionBuilderTest().get_suite());
    TestSuite.get_root().add_suite(new HKDF().get_suite());
    TestSuite.get_root().add_suite(new FileDecryptorTest().get_suite());
    TestSuite.get_root().add_suite(new DecryptLogicTest().get_suite());
    TestSuite.get_root().add_suite(new BundleParserTest().get_suite());
    TestSuite.get_root().add_suite(new LegacyBundlePubSubTest().get_suite());
    TestSuite.get_root().add_suite(new LegacyRegistrationGuardTest().get_suite());
    TestSuite.get_root().add_suite(new LegacyRegistrationPubSubTest().get_suite());
    TestSuite.get_root().add_suite(new LegacyPreKeyRecoveryTest().get_suite());
    TestSuite.get_root().add_suite(new LegacyPreKeyHighWatermarkTest().get_suite());
    TestSuite.get_root().add_suite(new LegacyOwnBundleMaintenanceTest().get_suite());
    TestSuite.get_root().add_suite(new MucHistoricalReceiveTest().get_suite());
    TestSuite.get_root().add_suite(new SceContextTest().get_suite());
    TestSuite.get_root().add_suite(new OwnBundleV2MaintenanceTest().get_suite());
    TestSuite.get_root().add_suite(new TrustLifecycleTest().get_suite());
    TestSuite.get_root().add_suite(new SignalFailureDiagnosticsTest().get_suite());
    TestSuite.get_root().add_suite(new JetOmemoTest().get_suite());
    TestSuite.get_root().add_suite(new JingleS5bJetOmemoFileManagerTest().get_suite());
    TestSuite.get_root().add_suite(new Omemo2CryptoTest().get_suite());
    TestSuite.get_root().add_suite(new SessionVersionGuardTest().get_suite());
    TestSuite.get_root().add_suite(new PreKeyUpdateClassifierTest().get_suite());
    TestSuite.get_root().add_suite(new EncryptSafetyCheckTest().get_suite());
    TestSuite.get_root().add_suite(new DecryptFailureStageTest().get_suite());
    TestSuite.get_root().add_suite(new Omemo2RuntimeFlagTest().get_suite());
    TestSuite.get_root().add_suite(new Omemo2DefaultOffTrustTest().get_suite());
    TestSuite.get_root().add_suite(new OmemoSendStateTest().get_suite());
    TestSuite.get_root().add_suite(new MultiAccountMessageStateTest().get_suite());
    TestSuite.get_root().add_suite(new ConversationClearCryptoStateTest().get_suite());
    TestSuite.get_root().add_suite(new ContactDetailsTrustIconTest().get_suite());
    TestSuite.get_root().add_suite(new ProactiveMucDiscoveryQueueTest().get_suite());
    TestSuite.get_root().add_suite(new FileSendSessionProofTest().get_suite());
    TestSuite.get_root().add_suite(new OutgoingCurrentDeviceTest().get_suite());
    TestSuite.get_root().add_suite(new CallFingerprintTest().get_suite());
    TestSuite.get_root().add_suite(new RemotePrivateMucHttpSmokeTest().get_suite());
    TestSuite.get_root().add_suite(new RemoteOmemoJingleS5bSmokeTest().get_suite());
    return GLib.Test.run();
}

Store setup_test_store_context(Context global_context) {
    Store store = global_context.create_store();
    try {
        store.identity_key_store.local_registration_id = (Random.next_int() % 16380) + 1;

        ECKeyPair key_pair = global_context.generate_key_pair();
        store.identity_key_store.identity_key_private = new Bytes(key_pair.private.serialize());
        store.identity_key_store.identity_key_public = new Bytes(key_pair.public.serialize());
    } catch (Error e) {
        fail_if_reached();
    }
    return store;
}

ECPublicKey? create_test_ec_public_key(Context context) {
    try {
        return context.generate_key_pair().public;
    } catch (Error e) {
        fail_if_reached();
        return null;
    }
}

bool fail_if(bool exp, string? reason = null) {
    if (exp) {
        if (reason != null) GLib.Test.message(reason);
        GLib.Test.fail();
        return true;
    }
    return false;
}

void fail_if_reached(string? reason = null) {
    fail_if(true, reason);
}

delegate void ErrorFunc() throws Error;

void fail_if_not_error_code(owned ErrorFunc func, int expectedCode, string? reason = null) {
    try {
        func();
        fail_if_reached(@"$(reason + ": " ?? "")no error thrown");
    } catch (Error e) {
        fail_if_not_eq_int(e.code, expectedCode, @"$(reason + ": " ?? "")caught unexpected error");
    }
}

bool fail_if_not(bool exp, string? reason = null) {
    return fail_if(!exp, reason);
}

// bool fail_if_eq_int(int left, int right, string? reason = null) {
//     return fail_if(left == right, @"$(reason + ": " ?? "")$left == $right");
// }

bool fail_if_not_eq_int(int left, int right, string? reason = null) {
    return fail_if_not(left == right, @"$(reason + ": " ?? "")$left != $right");
}

bool fail_if_not_eq_str(string left, string right, string? reason = null) {
    return fail_if_not(left == right, @"$(reason + ": " ?? "")$left != $right");
}

bool fail_if_not_eq_uint8_arr(uint8[] left, uint8[] right, string? reason = null) {
    if (fail_if_not_eq_int(left.length, right.length, @"$(reason + ": " ?? "")array length not equal")) return true;
    return fail_if_not_eq_str(Base64.encode(left), Base64.encode(right), reason);
}

bool fail_if_not_zero_int(int zero, string? reason = null) {
    return fail_if_not_eq_int(zero, 0, reason);
}

// bool fail_if_zero_int(int zero, string? reason = null) {
//     return fail_if_eq_int(zero, 0, reason);
// }

bool fail_if_null(void* what, string? reason = null) {
    return fail_if(what == null || (size_t)what == 0, reason);
}

}

namespace Dino.Ui.Test {

class EncryptionInputStatusPolicyTest : Gee.TestCase {
    public EncryptionInputStatusPolicyTest() {
        base("EncryptionInputStatusPolicyTest");
        add_test("ready_restores_moderated_context",
            test_ready_restores_moderated_context);
        add_test("verification_keeps_plugin_block",
            test_verification_keeps_plugin_block);
        add_test("error_keeps_plugin_block", test_error_keeps_plugin_block);
        add_test("verification_overrides_normal_room_state",
            test_verification_overrides_normal_room_state);
        add_test("ready_restore_keeps_visitor_block",
            test_ready_restore_keeps_visitor_block);
        add_test("normal_encryption_info_keeps_visitor_block",
            test_normal_encryption_info_keeps_visitor_block);
        add_test("private_room_info_rechecks_active_encryption",
            test_private_room_info_rechecks_active_encryption);
        add_test("joined_room_rechecks_persisted_encryption",
            test_joined_room_rechecks_persisted_encryption);
    }

    private void test_ready_restores_moderated_context() {
        var ready = new Plugins.InputFieldStatus("",
            Plugins.InputFieldStatus.MessageType.NONE,
            Plugins.InputFieldStatus.InputState.NORMAL);
        assert_true(encryption_status_requires_context_restore(ready),
            "an async encryption READY result must restore the current MUC " +
            "moderation state instead of blindly enabling the composer");
    }

    private void test_verification_keeps_plugin_block() {
        var verifying = new Plugins.InputFieldStatus("verifying",
            Plugins.InputFieldStatus.MessageType.INFO,
            Plugins.InputFieldStatus.InputState.NO_SEND);
        assert_false(encryption_status_requires_context_restore(verifying),
            "the private-MUC verification block must remain active");
    }

    private void test_error_keeps_plugin_block() {
        var error = new Plugins.InputFieldStatus("failed",
            Plugins.InputFieldStatus.MessageType.ERROR,
            Plugins.InputFieldStatus.InputState.NO_SEND);
        assert_false(encryption_status_requires_context_restore(error),
            "an encryption readiness error must remain visible and block sending");
    }

    private void test_verification_overrides_normal_room_state() {
        var normal = new Plugins.InputFieldStatus("",
            Plugins.InputFieldStatus.MessageType.NONE,
            Plugins.InputFieldStatus.InputState.NORMAL);
        var verifying = new Plugins.InputFieldStatus("verifying",
            Plugins.InputFieldStatus.MessageType.INFO,
            Plugins.InputFieldStatus.InputState.NO_SEND);
        Plugins.InputFieldStatus effective = effective_context_input_status(
            normal, verifying);
        assert_true(effective == verifying,
            "room-state refreshes must not clear an active OMEMO verification block");
    }

    private void test_ready_restore_keeps_visitor_block() {
        var visitor = new Plugins.InputFieldStatus("visitor",
            Plugins.InputFieldStatus.MessageType.ERROR,
            Plugins.InputFieldStatus.InputState.NO_SEND);
        var verifying = new Plugins.InputFieldStatus("verifying",
            Plugins.InputFieldStatus.MessageType.INFO,
            Plugins.InputFieldStatus.InputState.NO_SEND);
        Plugins.InputFieldStatus during_verification =
            effective_context_input_status(visitor, verifying);
        assert_true(during_verification == visitor,
            "visitor/not-joined state must remain authoritative while OMEMO is verified");

        Plugins.InputFieldStatus after_ready = effective_context_input_status(
            visitor, null);
        assert_true(after_ready == visitor,
            "clearing the OMEMO verification state must preserve a visitor NO_SEND block");
    }

    private void test_normal_encryption_info_keeps_visitor_block() {
        var visitor = new Plugins.InputFieldStatus("visitor",
            Plugins.InputFieldStatus.MessageType.ERROR,
            Plugins.InputFieldStatus.InputState.NO_SEND);
        var plugin_info = new Plugins.InputFieldStatus("ready info",
            Plugins.InputFieldStatus.MessageType.INFO,
            Plugins.InputFieldStatus.InputState.NORMAL);
        Plugins.InputFieldStatus effective = effective_context_input_status(
            visitor, plugin_info);
        assert_true(effective == visitor,
            "an async encryption INFO/NORMAL result must not enable a visitor composer");
    }

    private void test_private_room_info_rechecks_active_encryption() {
        assert_true(private_room_info_requires_encryption_refresh(true,
                Entities.Encryption.OMEMO),
            "a private room-info refresh must restart OMEMO readiness");
        assert_true(private_room_info_requires_encryption_refresh(true,
                Entities.Encryption.PGP),
            "a private room-info refresh must revalidate any active encryption plugin");
        assert_false(private_room_info_requires_encryption_refresh(true,
                Entities.Encryption.NONE),
            "an unencrypted room has no encryption readiness state to refresh");
        assert_false(private_room_info_requires_encryption_refresh(false,
                Entities.Encryption.OMEMO),
            "public-room handling disables encryption through its existing transition path");
    }

    private void test_joined_room_rechecks_persisted_encryption() {
        assert_true(joined_room_requires_encryption_refresh(true,
                Entities.Encryption.OMEMO),
            "post-activation join must retry a persisted OMEMO readiness check");
        assert_true(joined_room_requires_encryption_refresh(true,
                Entities.Encryption.PGP),
            "post-activation join must retry any persisted encryption plugin");
        assert_false(joined_room_requires_encryption_refresh(true,
                Entities.Encryption.NONE),
            "an unencrypted joined room needs no encryption readiness retry");
        assert_false(joined_room_requires_encryption_refresh(false,
                Entities.Encryption.OMEMO),
            "joined must not start a second disco while room-info is still in flight");
    }
}

}

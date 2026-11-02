namespace Dino.Ui.Test {

class PendingPlaintextSendTest : Gee.TestCase {
    public PendingPlaintextSendTest() {
        base("PendingPlaintextSendTest");
        add_test("overlay_cancel_discards_clipboard_plaintext", test_overlay_cancel_discards_clipboard_plaintext);
        add_test("send_handoff_keeps_plaintext_until_send_finishes", test_send_handoff_keeps_plaintext_until_send_finishes);
        add_test("abnormal_owner_teardown_discards_clipboard_plaintext", test_abnormal_owner_teardown_discards_clipboard_plaintext);
    }

    private void test_overlay_cancel_discards_clipboard_plaintext() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-file-manager-" + Uuid.string_random());
        string lease_root = Path.build_filename(temp_dir, "dinox", "temp_plaintext");
        string? plaintext_path = null;
        string? lease_dir = null;
        PendingPlaintextSend? pending_send = null;

        try {
            PlaintextFileLeaseTarget target = FileManager.create_plaintext_file_lease_target_for_tests(
                    "clipboard", lease_root, null, "clipboard.png");
            plaintext_path = target.file.get_path();
            lease_dir = target.file.get_parent().get_path();
            write_test_png(target.file);

            pending_send = new PendingPlaintextSend(target);
            fail_if_not_eq_str("clipboard.png", pending_send.file.get_basename());
            assert_true(FileUtils.test((!) plaintext_path, FileTest.EXISTS),
                    "clipboard plaintext must exist while the send dialog is open");

            pending_send.overlay_closed();

            assert_false(FileUtils.test((!) plaintext_path, FileTest.EXISTS),
                    "closing the dialog without sending must delete clipboard plaintext");
            assert_false(FileUtils.test((!) lease_dir, FileTest.EXISTS),
                    "closing the dialog without sending must delete the clipboard lease directory");
        } catch (Error e) {
            GLib.Test.message(@"Clipboard dialog-cancel lifecycle failed: $(e.message)");
            GLib.Test.fail();
        } finally {
            if (pending_send != null) ((!) pending_send).send_finished();
            FileManager.cleanup_plaintext_lease_root_for_tests(lease_root);
            cleanup_test_dir(temp_dir);
        }
    }

    private void test_send_handoff_keeps_plaintext_until_send_finishes() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-file-manager-" + Uuid.string_random());
        string lease_root = Path.build_filename(temp_dir, "dinox", "temp_plaintext");
        string? plaintext_path = null;
        string? lease_dir = null;
        PendingPlaintextSend? pending_send = null;

        try {
            PlaintextFileLeaseTarget target = FileManager.create_plaintext_file_lease_target_for_tests(
                    "clipboard", lease_root, null, "clipboard.png");
            plaintext_path = target.file.get_path();
            lease_dir = target.file.get_parent().get_path();
            write_test_png(target.file);

            pending_send = new PendingPlaintextSend(target);
            assert_true(pending_send.begin_send(), "first send handoff must take ownership");
            assert_false(pending_send.begin_send(), "clipboard plaintext must not be handed off twice");

            pending_send.overlay_closed();
            assert_true(FileUtils.test((!) plaintext_path, FileTest.EXISTS),
                    "dialog close after handoff must keep plaintext until FileManager finishes");

            pending_send.send_finished();
            assert_false(FileUtils.test((!) plaintext_path, FileTest.EXISTS),
                    "FileManager completion must delete clipboard plaintext");
            assert_false(FileUtils.test((!) lease_dir, FileTest.EXISTS),
                    "FileManager completion must delete the clipboard lease directory");
        } catch (Error e) {
            GLib.Test.message(@"Clipboard send-handoff lifecycle failed: $(e.message)");
            GLib.Test.fail();
        } finally {
            if (pending_send != null) ((!) pending_send).send_finished();
            FileManager.cleanup_plaintext_lease_root_for_tests(lease_root);
            cleanup_test_dir(temp_dir);
        }
    }

    private void test_abnormal_owner_teardown_discards_clipboard_plaintext() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-file-manager-" + Uuid.string_random());
        string lease_root = Path.build_filename(temp_dir, "dinox", "temp_plaintext");
        string? plaintext_path = null;
        string? lease_dir = null;
        PlaintextFileLeaseTarget? target = null;
        PendingPlaintextSend? pending_send = null;

        try {
            target = FileManager.create_plaintext_file_lease_target_for_tests(
                    "clipboard", lease_root, null, "clipboard.png");
            plaintext_path = ((!) target).file.get_path();
            lease_dir = ((!) target).file.get_parent().get_path();
            write_test_png(((!) target).file);

            pending_send = new PendingPlaintextSend((!) target);
            target = null;
            pending_send = null;

            assert_false(FileUtils.test((!) plaintext_path, FileTest.EXISTS),
                    "destroying the dialog owner must delete clipboard plaintext");
            assert_false(FileUtils.test((!) lease_dir, FileTest.EXISTS),
                    "destroying the dialog owner must delete the clipboard lease directory");
        } catch (Error e) {
            GLib.Test.message(@"Clipboard abnormal teardown lifecycle failed: $(e.message)");
            GLib.Test.fail();
        } finally {
            if (pending_send != null) ((!) pending_send).send_finished();
            if (target != null) ((!) target).discard();
            FileManager.cleanup_plaintext_lease_root_for_tests(lease_root);
            cleanup_test_dir(temp_dir);
        }
    }

    private static void write_test_png(File file) throws Error {
        uint8[] png_marker = { 0x89, 0x50, 0x4e, 0x47 };
        OutputStream output = file.create(FileCreateFlags.PRIVATE);
        size_t written;
        output.write_all(png_marker, out written);
        output.close();
    }

    private static void cleanup_test_dir(string path) {
        FileUtils.remove(path);
        DirUtils.remove(Path.build_filename(path, "dinox"));
        DirUtils.remove(path);
    }
}

}

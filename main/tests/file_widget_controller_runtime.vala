using GLib;
using Gtk;

using Dino.Entities;
using Dino.Security;

namespace Dino.Ui.Test {

class FileWidgetControllerRuntimeTest : Gee.TestCase {

    private delegate bool Predicate();

    private class RecordingLauncher : Object, FileOpenLauncher {
        public int launches = 0;
        public string? launched_path = null;
        public string? launched_contents = null;

        public void launch(File file) throws Error {
            launches++;
            launched_path = file.get_path();
            fail_if(launched_path == null || (!) launched_path == "",
                "open launcher must receive a local plaintext path");
            FileUtils.get_contents((!) launched_path, out launched_contents);
        }
    }

    private class RecordingSaveTargetPicker : Object, FileSaveTargetPicker {
        public int requests = 0;
        public string? title = null;
        public string? initial_name = null;
        public File? target = null;
        public bool manual_completion = false;
        private SourceFunc? pending_resume = null;

        public RecordingSaveTargetPicker(File? target, bool manual_completion = false) {
            this.target = target;
            this.manual_completion = manual_completion;
        }

        public bool is_waiting() {
            return pending_resume != null;
        }

        public void complete_pending() {
            SourceFunc? resume = (owned) pending_resume;
            if (resume != null) {
                Idle.add((owned) resume);
            }
        }

        public async File? pick_save_target(Gtk.Window? parent, string title, string initial_name) throws Error {
            requests++;
            this.title = title;
            this.initial_name = initial_name;
            if (manual_completion) {
                pending_resume = pick_save_target.callback;
                yield;
            }
            return target;
        }
    }

    private class AcceptingHttpProvider : Object, Dino.FileProvider {
        public Encryption get_encryption(FileTransfer file_transfer, FileReceiveData receive_data, FileMeta file_meta) {
            return Encryption.NONE;
        }

        public FileMeta get_file_meta(FileTransfer file_transfer) throws FileReceiveError {
            return new FileMeta();
        }

        public FileReceiveData? get_file_receive_data(FileTransfer file_transfer) {
            return new HttpFileReceiveData() { url = "https://example.invalid/gate4-open.txt" };
        }

        public bool has_usable_download_source(FileTransfer file_transfer) {
            return file_transfer.has_usable_download_source(FileManager.SFS_PROVIDER_ID);
        }

        public async FileMeta get_meta_info(FileTransfer file_transfer, FileReceiveData receive_data, FileMeta file_meta) throws FileReceiveError, IOError {
            return file_meta;
        }

        public async InputStream download(FileTransfer file_transfer, FileReceiveData receive_data, FileMeta file_meta) throws IOError {
            return new MemoryInputStream.from_data("stub".data);
        }

        public int get_id() {
            return FileManager.HTTP_PROVIDER_ID;
        }
    }

    private class RuntimeFixture : Object {
        public string temp_dir;
        public string storage_name;
        public string storage_path;
        public uint8[] plaintext;
        public Database? db = null;
        public StreamInteractor? stream_interactor = null;
        public FileEncryption? file_encryption = null;

        public RuntimeFixture() {
            temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-file-widget-runtime-" + Uuid.string_random());
            storage_name = "gate4-open-" + Uuid.string_random() + ".enc";
            storage_path = Path.build_filename(FileManager.get_storage_dir(), storage_name);
            plaintext = "gate4 verified open plaintext\n".data;
        }

        public void setup() throws Error {
            DirUtils.create_with_parents(temp_dir, 0700);
            DirUtils.create_with_parents(FileManager.get_storage_dir(), 0700);

            db = new Database(Path.build_filename(temp_dir, "dino.db"), "gate4-file-widget-open-test");
            stream_interactor = new StreamInteractor.for_tests((!) db);
            file_encryption = new FileEncryption("gate4-file-widget-open-test");
            FileManager.start((!) stream_interactor, (!) db, (!) file_encryption);
            ((!) stream_interactor).get_module<FileManager>(FileManager.IDENTITY).add_provider(new AcceptingHttpProvider());
            write_encrypted_source_sync((!) file_encryption, File.new_for_path(storage_path), plaintext);
        }

        public FileTransfer create_transfer(FileTransfer.Phase phase) {
            var file_transfer = new FileTransfer();
            file_transfer.file_name = "gate4-open.txt";
            file_transfer.mime_type = "text/plain";
            file_transfer.path = storage_name;
            file_transfer.direction = FileTransfer.DIRECTION_RECEIVED;
            file_transfer.provider = FileManager.SFS_PROVIDER_ID;
            file_transfer.encryption = Encryption.NONE;
            file_transfer.size = plaintext.length;
            file_transfer.set_transfer_phase(phase, phase == FileTransfer.Phase.FAILED ? "synthetic failure" : null);
            return file_transfer;
        }

        public void cleanup() {
            if (db != null) {
                ((!) db).close();
                db = null;
            }
            FileUtils.remove(storage_path);
            remove_path(temp_dir);
        }

        private void write_encrypted_source_sync(FileEncryption file_encryption, File source_file, uint8[] plaintext) throws Error {
            Error? caught_error = null;
            var loop = new MainLoop();
            write_encrypted_source.begin(file_encryption, source_file, plaintext, (obj, res) => {
                try {
                    write_encrypted_source.end(res);
                } catch (Error e) {
                    caught_error = e;
                }
                loop.quit();
            });
            loop.run();
            if (caught_error != null) throw (!) caught_error;
        }

        private async void write_encrypted_source(FileEncryption file_encryption, File source_file, uint8[] plaintext) throws Error {
            var input = new MemoryInputStream.from_data(plaintext);
            OutputStream? output = null;
            try {
                output = source_file.create(FileCreateFlags.PRIVATE);
                yield file_encryption.encrypt_stream(input, (!) output, null);
                yield ((!) output).close_async(Priority.LOW, null);
                output = null;
            } finally {
                if (output != null) {
                    try { ((!) output).close(null); } catch (Error e) {}
                }
                try { input.close(null); } catch (Error e) {}
            }
        }
    }

    public FileWidgetControllerRuntimeTest() {
        base("FileWidgetControllerRuntime");

        add_test("Gate4_incomplete_open_signal_never_creates_plaintext_launch", test_incomplete_open_signal_never_creates_plaintext_launch);
        add_test("Gate4_complete_open_signal_launches_verified_plaintext_lease", test_complete_open_signal_launches_verified_plaintext_lease);
        add_test("Gate4_dispose_during_open_releases_pending_plaintext_lease", test_dispose_during_open_releases_pending_plaintext_lease);
        add_test("Gate4_incomplete_save_signal_never_exports_plaintext", test_incomplete_save_signal_never_exports_plaintext);
        add_test("Gate4_complete_save_signal_exports_verified_plaintext", test_complete_save_signal_exports_verified_plaintext);
        add_test("Gate4_complete_save_cancel_never_exports_plaintext", test_complete_save_cancel_never_exports_plaintext);
        add_test("Gate4_save_phase_rollback_after_picker_blocks_export", test_save_phase_rollback_after_picker_blocks_export);
        add_test("Gate4_dispose_during_save_picker_blocks_export", test_dispose_during_save_picker_blocks_export);
        add_test("Gate4_own_sent_remote_download_signal_uses_receive_path", test_own_sent_remote_download_signal_uses_receive_path);
    }

    private void test_incomplete_open_signal_never_creates_plaintext_launch() {
        FileTransfer.Phase[] blocked_phases = {
            FileTransfer.Phase.NONE,
            FileTransfer.Phase.PREPARING,
            FileTransfer.Phase.ENCRYPTING,
            FileTransfer.Phase.REQUESTING_SLOT,
            FileTransfer.Phase.UPLOADING,
            FileTransfer.Phase.ANNOUNCING,
            FileTransfer.Phase.DOWNLOADING,
            FileTransfer.Phase.DECRYPTING,
            FileTransfer.Phase.VERIFYING,
            FileTransfer.Phase.STORING,
            FileTransfer.Phase.PREVIEWING,
            FileTransfer.Phase.FAILED
        };

        var fixture = new RuntimeFixture();
        try {
            fixture.setup();
            foreach (FileTransfer.Phase phase in blocked_phases) {
                var launcher = new RecordingLauncher();
                var widget = new FileWidget();
                var controller = new FileWidgetController(widget, fixture.create_transfer(phase), fixture.stream_interactor, launcher);

                widget.open_file();
                drain_main_context();

                fail_if_not_eq_int(0, launcher.launches,
                    @"Gate 4 controller must not launch plaintext while phase is $(phase.to_string())");
                fail_if_not_eq_int(0, count_plaintext_lease_files(),
                    @"Gate 4 controller must not create plaintext leases while phase is $(phase.to_string())");
                controller.dispose();
            }
        } catch (Error e) {
            fail_if_reached(@"Gate 4 incomplete FileWidgetController open test failed: $(e.message)");
        } finally {
            fixture.cleanup();
        }
    }

    private void test_complete_open_signal_launches_verified_plaintext_lease() {
        var fixture = new RuntimeFixture();
        try {
            fixture.setup();
            var launcher = new RecordingLauncher();
            var widget = new FileWidget();
            var controller = new FileWidgetController(
                widget,
                fixture.create_transfer(FileTransfer.Phase.COMPLETE),
                fixture.stream_interactor,
                launcher);

            widget.open_file();
            fail_if_not(wait_for_condition(5000, () => launcher.launches == 1),
                "complete transfer open signal must launch verified plaintext");

            fail_if_not_eq_int(1, launcher.launches,
                "complete transfer open signal must launch exactly once");
            fail_if_not_eq_str("gate4 verified open plaintext\n", launcher.launched_contents ?? "",
                "open launcher must see decrypted verified plaintext");
            fail_if(launcher.launched_path == null || !FileUtils.test((!) launcher.launched_path, FileTest.EXISTS),
                "plaintext lease must stay available for the external opener while the controller lives");

            string launched_path = (!) launcher.launched_path;
            controller.dispose();
            drain_main_context();
            fail_if(FileUtils.test(launched_path, FileTest.EXISTS),
                "disposing the FileWidgetController must release the temporary plaintext lease");
        } catch (Error e) {
            fail_if_reached(@"Gate 4 complete FileWidgetController open test failed: $(e.message)");
        } finally {
            fixture.cleanup();
        }
    }

    private void test_dispose_during_open_releases_pending_plaintext_lease() {
        var fixture = new RuntimeFixture();
        try {
            fixture.setup();
            var launcher = new RecordingLauncher();
            var widget = new FileWidget();
            var controller = new FileWidgetController(
                widget,
                fixture.create_transfer(FileTransfer.Phase.COMPLETE),
                fixture.stream_interactor,
                launcher);

            widget.open_file();
            controller.dispose();

            fail_if_not(wait_for_stable_no_plaintext_files(5000, 250),
                "disposing during async open must release any plaintext lease created after the yield");
            fail_if_not_eq_int(0, launcher.launches,
                "disposing during async open must not launch the external opener");
        } catch (Error e) {
            fail_if_reached(@"Gate 4 dispose-during-open test failed: $(e.message)");
        } finally {
            fixture.cleanup();
        }
    }

    private void test_incomplete_save_signal_never_exports_plaintext() {
        FileTransfer.Phase[] blocked_phases = {
            FileTransfer.Phase.NONE,
            FileTransfer.Phase.PREPARING,
            FileTransfer.Phase.ENCRYPTING,
            FileTransfer.Phase.REQUESTING_SLOT,
            FileTransfer.Phase.UPLOADING,
            FileTransfer.Phase.ANNOUNCING,
            FileTransfer.Phase.DOWNLOADING,
            FileTransfer.Phase.DECRYPTING,
            FileTransfer.Phase.VERIFYING,
            FileTransfer.Phase.STORING,
            FileTransfer.Phase.PREVIEWING,
            FileTransfer.Phase.FAILED
        };

        var fixture = new RuntimeFixture();
        try {
            fixture.setup();
            foreach (FileTransfer.Phase phase in blocked_phases) {
                string target_path = Path.build_filename(fixture.temp_dir, "blocked-" + phase.to_string() + ".txt");
                var picker = new RecordingSaveTargetPicker(File.new_for_path(target_path));
                var widget = new FileWidget();
                var controller = new FileWidgetController(
                    widget,
                    fixture.create_transfer(phase),
                    fixture.stream_interactor,
                    new RecordingLauncher(),
                    picker);

                widget.save_file_as();
                drain_main_context();

                fail_if_not_eq_int(0, picker.requests,
                    @"Gate 4 controller must not ask for a save target while phase is $(phase.to_string())");
                fail_if(FileUtils.test(target_path, FileTest.EXISTS),
                    @"Gate 4 controller must not export plaintext while phase is $(phase.to_string())");
                controller.dispose();
            }
        } catch (Error e) {
            fail_if_reached(@"Gate 4 incomplete FileWidgetController save test failed: $(e.message)");
        } finally {
            fixture.cleanup();
        }
    }

    private void test_complete_save_signal_exports_verified_plaintext() {
        var fixture = new RuntimeFixture();
        try {
            fixture.setup();
            string target_path = Path.build_filename(fixture.temp_dir, "gate4-exported.txt");
            var picker = new RecordingSaveTargetPicker(File.new_for_path(target_path));
            var widget = new FileWidget();
            var controller = new FileWidgetController(
                widget,
                fixture.create_transfer(FileTransfer.Phase.COMPLETE),
                fixture.stream_interactor,
                new RecordingLauncher(),
                picker);

            widget.save_file_as();
            fail_if_not(wait_for_condition(5000, () => FileUtils.test(target_path, FileTest.EXISTS)),
                "complete transfer save signal must export verified plaintext");

            fail_if_not_eq_int(1, picker.requests,
                "complete transfer save signal must ask for one save target");
            fail_if_not_eq_str("Save as…", picker.title ?? "",
                "save target picker must receive the product save title");
            fail_if_not_eq_str("gate4-open.txt", picker.initial_name ?? "",
                "save target picker must receive the original transfer file name");
            string exported_contents = "";
            FileUtils.get_contents(target_path, out exported_contents);
            fail_if_not_eq_str("gate4 verified open plaintext\n", exported_contents,
                "exported file must contain decrypted verified plaintext");

            controller.dispose();
            fail_if(!FileUtils.test(target_path, FileTest.EXISTS),
                "exported user target must remain after controller disposal");
        } catch (Error e) {
            fail_if_reached(@"Gate 4 complete FileWidgetController save test failed: $(e.message)");
        } finally {
            fixture.cleanup();
        }
    }

    private void test_complete_save_cancel_never_exports_plaintext() {
        var fixture = new RuntimeFixture();
        try {
            fixture.setup();
            string target_path = Path.build_filename(fixture.temp_dir, "gate4-cancelled-save.txt");
            var picker = new RecordingSaveTargetPicker(null);
            var widget = new FileWidget();
            var controller = new FileWidgetController(
                widget,
                fixture.create_transfer(FileTransfer.Phase.COMPLETE),
                fixture.stream_interactor,
                new RecordingLauncher(),
                picker);

            widget.save_file_as();
            fail_if_not(wait_for_condition(5000, () => picker.requests == 1),
                "complete transfer save signal must reach the injected picker even when it is cancelled");
            fail_if_not(wait_for_stable_missing_path(target_path, 5000, 250),
                "cancelled save picker must not export plaintext");

            controller.dispose();
        } catch (Error e) {
            fail_if_reached(@"Gate 4 save-cancel test failed: $(e.message)");
        } finally {
            fixture.cleanup();
        }
    }

    private void test_save_phase_rollback_after_picker_blocks_export() {
        var fixture = new RuntimeFixture();
        try {
            fixture.setup();
            string target_path = Path.build_filename(fixture.temp_dir, "gate4-rollback-save.txt");
            var picker = new RecordingSaveTargetPicker(File.new_for_path(target_path), true);
            var widget = new FileWidget();
            var transfer = fixture.create_transfer(FileTransfer.Phase.COMPLETE);
            var controller = new FileWidgetController(
                widget,
                transfer,
                fixture.stream_interactor,
                new RecordingLauncher(),
                picker);

            widget.save_file_as();
            fail_if_not(wait_for_condition(5000, () => picker.is_waiting()),
                "phase-rollback save test must stop at the injected picker");
            transfer.set_transfer_phase(FileTransfer.Phase.FAILED, "synthetic rollback");
            picker.complete_pending();
            fail_if_not(wait_for_stable_missing_path(target_path, 5000, 250),
                "phase rollback after choosing a save target must not export plaintext");

            controller.dispose();
        } catch (Error e) {
            fail_if_reached(@"Gate 4 save phase-rollback test failed: $(e.message)");
        } finally {
            fixture.cleanup();
        }
    }

    private void test_dispose_during_save_picker_blocks_export() {
        var fixture = new RuntimeFixture();
        try {
            fixture.setup();
            string target_path = Path.build_filename(fixture.temp_dir, "gate4-disposed-save.txt");
            var picker = new RecordingSaveTargetPicker(File.new_for_path(target_path), true);
            var widget = new FileWidget();
            var controller = new FileWidgetController(
                widget,
                fixture.create_transfer(FileTransfer.Phase.COMPLETE),
                fixture.stream_interactor,
                new RecordingLauncher(),
                picker);

            widget.save_file_as();
            fail_if_not(wait_for_condition(5000, () => picker.is_waiting()),
                "dispose-during-save test must stop at the injected picker");
            controller.dispose();
            picker.complete_pending();

            fail_if_not(wait_for_stable_missing_path(target_path, 5000, 250),
                "disposing while the save picker is pending must not export plaintext");
        } catch (Error e) {
            fail_if_reached(@"Gate 4 dispose-during-save test failed: $(e.message)");
        } finally {
            fixture.cleanup();
        }
    }

    private void test_own_sent_remote_download_signal_uses_receive_path() {
        var fixture = new RuntimeFixture();
        try {
            fixture.setup();
            FileTransfer[] transfers = {
                fixture.create_transfer(FileTransfer.Phase.NONE),
                fixture.create_transfer(FileTransfer.Phase.NONE)
            };
            transfers[0].direction = FileTransfer.DIRECTION_SENT;
            transfers[0].path = "";
            transfers[0].add_sfs_source(new Xmpp.Xep.StatelessFileSharing.HttpSource() {
                url = "https://example.invalid/gate4-open.txt"
            });
            transfers[1].direction = FileTransfer.DIRECTION_SENT;
            transfers[1].provider = FileManager.HTTP_PROVIDER_ID;
            transfers[1].path = "";
            transfers[1].info = "url:aesgcm://example.invalid/gate4-open.txt#00112233445566778899aabbccddeeff";

            foreach (FileTransfer transfer in transfers) {
                var widget = new FileWidget();
                var controller = new FileWidgetController(
                    widget,
                    transfer,
                    fixture.stream_interactor,
                    new RecordingLauncher());

                widget.start_download();
                fail_if_not(wait_for_condition(5000, () => transfer.state == FileTransfer.State.FAILED),
                    "own sent remote transfer from another device must enter the receive-download path");
                fail_if_not_eq_str("No conversation available for this transfer", transfer.phase_error ?? "",
                    "receive-download path should report the missing test conversation instead of silently ignoring upload retry");

                controller.dispose();
            }
        } catch (Error e) {
            fail_if_reached(@"Gate 4 own sent remote download signal test failed: $(e.message)");
        } finally {
            fixture.cleanup();
        }
    }

    private bool wait_for_condition(uint timeout_ms, Predicate predicate) {
        int64 deadline = get_monotonic_time() + ((int64) timeout_ms * 1000);
        do {
            drain_main_context();
            if (predicate()) return true;
            Thread.usleep(10000);
        } while (get_monotonic_time() < deadline);
        drain_main_context();
        return predicate();
    }

    private bool wait_for_stable_missing_path(string path, uint timeout_ms, uint stable_ms) {
        int64 deadline = get_monotonic_time() + ((int64) timeout_ms * 1000);
        int64 stable_since = 0;
        do {
            drain_main_context();
            int64 now = get_monotonic_time();
            if (!FileUtils.test(path, FileTest.EXISTS)) {
                if (stable_since == 0) stable_since = now;
                if (now - stable_since >= ((int64) stable_ms * 1000)) return true;
            } else {
                stable_since = 0;
            }
            Thread.usleep(10000);
        } while (get_monotonic_time() < deadline);
        drain_main_context();
        return !FileUtils.test(path, FileTest.EXISTS);
    }

    private bool wait_for_stable_no_plaintext_files(uint timeout_ms, uint stable_ms) {
        int64 deadline = get_monotonic_time() + ((int64) timeout_ms * 1000);
        int64 stable_since = 0;
        do {
            drain_main_context();
            int64 now = get_monotonic_time();
            if (count_plaintext_lease_files() == 0) {
                if (stable_since == 0) stable_since = now;
                if (now - stable_since >= ((int64) stable_ms * 1000)) return true;
            } else {
                stable_since = 0;
            }
            Thread.usleep(10000);
        } while (get_monotonic_time() < deadline);
        drain_main_context();
        return count_plaintext_lease_files() == 0;
    }

    private int count_plaintext_lease_files() {
        string root = Path.build_filename(Environment.get_user_cache_dir(), "dinox", "temp_plaintext");
        return count_regular_files(root);
    }

    private int count_regular_files(string path) {
        if (!FileUtils.test(path, FileTest.EXISTS)) return 0;
        if (!FileUtils.test(path, FileTest.IS_DIR)) return 1;

        int count = 0;
        try {
            Dir dir = Dir.open(path);
            string? name;
            while ((name = dir.read_name()) != null) {
                count += count_regular_files(Path.build_filename(path, (!) name));
            }
        } catch (Error e) {}
        return count;
    }

    private void drain_main_context() {
        MainContext context = MainContext.default();
        while (context.pending()) {
            context.iteration(false);
        }
    }

    private static void remove_path(string path) {
        if (!FileUtils.test(path, FileTest.EXISTS)) return;

        if (FileUtils.test(path, FileTest.IS_DIR)) {
            try {
                Dir dir = Dir.open(path);
                string? name;
                while ((name = dir.read_name()) != null) {
                    remove_path(Path.build_filename(path, (!) name));
                }
            } catch (Error e) {}
            DirUtils.remove(path);
        } else {
            FileUtils.remove(path);
        }
    }
}

}

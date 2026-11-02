using Dino.Entities;
using Gee;
using Xmpp;

namespace Dino.Plugins.HttpFiles.Test {

class RemoteForeignHttpUploadSmokeTest : Gee.TestCase {
    private const uint DEFAULT_TIMEOUT_SECONDS = 90;
    private const int64 AUTO_DOWNLOAD_MAX_BYTES = 5000000;

    public RemoteForeignHttpUploadSmokeTest() {
        base("RemoteForeignHttpUploadSmoke");
        add_test("incoming_go_sendxmpp_http_upload_env", test_incoming_go_sendxmpp_http_upload_env_sync);
    }

    private void test_incoming_go_sendxmpp_http_upload_env_sync() {
        RemoteForeignHttpUploadSmokeConfig? config = RemoteForeignHttpUploadSmokeConfig.from_env();
        if (config == null) return;

        MainLoop loop = new MainLoop();
        run_incoming_go_sendxmpp_http_upload.begin((!) config, (obj, res) => {
            try {
                run_incoming_go_sendxmpp_http_upload.end(res);
            } catch (Error e) {
                fail_if(true, @"Remote foreign HTTP upload smoke failed: $(e.message)");
            }
            loop.quit();
        });
        loop.run();
    }

    private async void run_incoming_go_sendxmpp_http_upload(RemoteForeignHttpUploadSmokeConfig config) throws Error {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-remote-foreign-http-upload-smoke-" + Uuid.string_random());
        string? previous_xdg_data_home = Environment.get_variable("XDG_DATA_HOME");
        string? previous_xdg_cache_home = Environment.get_variable("XDG_CACHE_HOME");
        Database? db = null;
        StreamInteractor? stream_interactor = null;
        Account? receiver_account = null;
        TestApplication? application = null;
        GLib.Application? previous_application = GLib.Application.get_default();
        FileProvider? http_provider = null;
        FileManager? file_manager = null;
        FileTransfer? received_transfer = null;
        Conversation? received_conversation = null;
        string? storage_dir = null;
        ulong received_handler = 0;
        Error? pending_error = null;
        Error? temp_cleanup_error = null;

        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            storage_dir = configure_isolated_storage(temp_dir);
            db = new Database(Path.build_filename(temp_dir, "dino.db"), "remote-foreign-http-upload-smoke");
            stream_interactor = new StreamInteractor.for_tests((!) db);
            application = new TestApplication((!) db, (!) stream_interactor);
            GLib.Application.set_default((!) application);
            Security.FileEncryption file_encryption = (!) application.file_encryption;
            start_remote_file_modules((!) stream_interactor, (!) db, file_encryption);

            file_manager = ((!) stream_interactor).get_module<FileManager>(FileManager.IDENTITY);
            if (file_manager == null) {
                throw new IOError.FAILED("FileManager was not started for remote foreign HTTP upload smoke");
            }
            http_provider = new FileProvider((!) stream_interactor, (!) db);
            ((!) file_manager).add_provider((!) http_provider);

            receiver_account = new Account(config.receiver_jid.bare_jid, config.receiver_password);
            ((!) receiver_account).enabled = true;
            ((!) receiver_account).custom_host = config.custom_host;
            ((!) receiver_account).custom_port = config.custom_port;
            persist_remote_smoke_account_without_password((!) db, (!) receiver_account);
            seed_trusted_roster_contact((!) db, (!) receiver_account, config.sender_jid);

            Conversation expected_conversation = new Conversation(config.sender_jid.bare_jid, (!) receiver_account, Conversation.Type.CHAT);
            expected_conversation.persist((!) db);

            string connect_failure = "";
            if (!(yield connect_and_wait_for_negotiation((!) stream_interactor, (!) receiver_account, config.timeout_seconds, out connect_failure))) {
                throw new IOError.TIMED_OUT(connect_failure);
            }

            received_handler = ((!) file_manager).received_file.connect((file_transfer, conversation) => {
                if (!Account.equals_func(file_transfer.account, (!) receiver_account)) return;
                if (file_transfer.direction != FileTransfer.DIRECTION_RECEIVED) return;
                if (!file_transfer.counterpart.equals_bare(config.sender_jid.bare_jid)) return;

                received_transfer = file_transfer;
                received_conversation = conversation;
                if (file_transfer.provider == Dino.StatelessFileSharing.SFS_PROVIDER_ID &&
                        config.expected_size < AUTO_DOWNLOAD_MAX_BYTES) {
                    ((!) file_manager).download_file.begin(file_transfer, (_, res) => {
                        ((!) file_manager).download_file.end(res);
                    });
                }
            });

            publish_ready_message(config);

            if (!(yield wait_for_condition(config.timeout_seconds, () => received_transfer != null))) {
                throw new IOError.TIMED_OUT("timed out waiting for a terminal-client HTTP upload message from the expected sender");
            }
            FileTransfer file_transfer = (!) received_transfer;
            if (!(yield wait_for_condition(config.timeout_seconds, () =>
                    file_transfer.phase == FileTransfer.Phase.COMPLETE ||
                    file_transfer.phase == FileTransfer.Phase.FAILED))) {
                throw new IOError.TIMED_OUT(@"timed out waiting for remote foreign HTTP upload receive-store completion (phase=$((int) file_transfer.phase), state=$((int) file_transfer.state), error=$(file_transfer.phase_error ?? "none"))");
            }
            if (file_transfer.phase == FileTransfer.Phase.FAILED) {
                throw new IOError.FAILED(@"remote foreign HTTP upload receive-store failed: $(file_transfer.phase_error ?? "no phase error")");
            }

            validate_received_transfer(file_transfer, (!) received_conversation, config);
            yield validate_stored_payload(file_encryption, file_transfer, config.expected_size, config.expected_sha256);

            if (count_receive_pending_files_for_basename((!) storage_dir, file_transfer.file_name) != 0) {
                throw new IOError.FAILED("remote foreign HTTP upload receive-store left pending receive files");
            }

            GLib.Test.message("Remote foreign HTTP upload smoke passed");
        } catch (Error e) {
            pending_error = e;
        }

        if (received_handler != 0 && file_manager != null) {
            SignalHandler.disconnect((!) file_manager, received_handler);
        }
        if (http_provider != null) ((!) http_provider).shutdown();
        if (stream_interactor != null && receiver_account != null) {
            yield ((!) stream_interactor).connection_manager.disconnect_account((!) receiver_account);
        }
        restore_default_application(application, previous_application);
        if (db != null) {
            ((!) db).close();
            db = null;
        }
        restore_env_var("XDG_DATA_HOME", previous_xdg_data_home);
        restore_env_var("XDG_CACHE_HOME", previous_xdg_cache_home);
        try {
            delete_file_tree(File.new_for_path(temp_dir));
        } catch (Error e) {
            temp_cleanup_error = e;
            GLib.Test.message(@"Could not clean remote foreign HTTP upload smoke temp dir: $(e.message)");
        }

        if (pending_error != null) throw (!) pending_error;
        if (temp_cleanup_error != null) throw (!) temp_cleanup_error;
    }

    private static void start_remote_file_modules(StreamInteractor stream_interactor, Database db, Security.FileEncryption file_encryption) {
        MessageStorage.start(stream_interactor, db);
        FileTransferStorage.start(stream_interactor, db);
        MessageProcessor.start(stream_interactor, db);
        MessageProcessor? message_processor = stream_interactor.get_module<MessageProcessor>(MessageProcessor.IDENTITY);
        if (message_processor != null) ((!) message_processor).history_sync.auto_fetch_enabled = false;
        EntityInfo.start(stream_interactor, db);
        RosterManager.start(stream_interactor, db);
        Calls.start(stream_interactor, db);
        ConversationManager.start(stream_interactor, db);
        PresenceManager.start(stream_interactor, db);
        OccupantIdStore.start(stream_interactor, db);
        MucManager.start(stream_interactor);
        FileManager.start(stream_interactor, db, file_encryption);
        CallStore.start(stream_interactor, db);
        ContentItemStore.start(stream_interactor, db);
        StatelessFileSharing.start(stream_interactor, db);
    }

    private static string configure_isolated_storage(string temp_dir) throws IOError {
        string xdg_data_home = Path.build_filename(temp_dir, "xdg-data");
        string xdg_cache_home = Path.build_filename(temp_dir, "xdg-cache");
        DirUtils.create_with_parents(xdg_data_home, 0700);
        DirUtils.create_with_parents(xdg_cache_home, 0700);
        Environment.set_variable("XDG_DATA_HOME", xdg_data_home, true);
        Environment.set_variable("XDG_CACHE_HOME", xdg_cache_home, true);

        string storage_dir = FileManager.get_storage_dir();
        if (!is_path_at_or_below(storage_dir, xdg_data_home) && !is_meson_test_storage_dir(storage_dir)) {
            throw new IOError.PERMISSION_DENIED(@"remote foreign HTTP upload smoke refuses to use non-test storage directory '$storage_dir'; run through meson test or start the process with an isolated XDG_DATA_HOME");
        }
        return storage_dir;
    }

    private static bool is_path_at_or_below(string path, string parent) {
        string normalized_parent = parent.has_suffix(Path.DIR_SEPARATOR_S) ? parent.substring(0, parent.length - 1) : parent;
        return path == normalized_parent || path.has_prefix(normalized_parent + Path.DIR_SEPARATOR_S);
    }

    private static bool is_meson_test_storage_dir(string storage_dir) {
        return Path.get_basename(storage_dir) == "dinox" &&
            Path.get_basename(Path.get_dirname(storage_dir)) == "test-xdg-data";
    }

    private static void persist_remote_smoke_account_without_password(Database db, Account account) {
        if (account.id > 0) return;
        account.id = (int) db.account.insert()
            .value(db.account.bare_jid, account.bare_jid.to_string())
            .value(db.account.resourcepart, account.resourcepart)
            .value(db.account.password, (string?) null)
            .value(db.account.alias, account.alias)
            .value(db.account.enabled, account.enabled)
            .value(db.account.roster_version, account.roster_version)
            .value(db.account.custom_host, account.custom_host)
            .value(db.account.custom_port, account.custom_port)
            .value(db.account.proxy_type, account.proxy_type)
            .value(db.account.proxy_host, account.proxy_host)
            .value(db.account.proxy_port, account.proxy_port)
            .value(db.account.proxy_user, account.proxy_user)
            .value(db.account.proxy_pass, account.proxy_pass)
            .value(db.account.require_channel_binding, account.require_channel_binding)
            .perform();
    }

    private static void seed_trusted_roster_contact(Database db, Account account, Jid jid) {
        db.roster.upsert()
            .value(db.roster.account_id, account.id, true)
            .value(db.roster.jid, jid.bare_jid.to_string(), true)
            .value(db.roster.handle, jid.bare_jid.to_string())
            .value(db.roster.subscription, Xmpp.Roster.Item.SUBSCRIPTION_BOTH)
            .perform();
    }

    private async bool connect_and_wait_for_negotiation(StreamInteractor stream_interactor, Account account, uint timeout_seconds, out string failure_reason) {
        failure_reason = "";
        string local_failure_reason = "";
        bool completed = false;
        bool success = false;
        SourceFunc resume = connect_and_wait_for_negotiation.callback;
        uint timeout_id = 0;
        ulong negotiated_id = 0;
        ulong error_id = 0;

        negotiated_id = stream_interactor.stream_negotiated.connect((seen_account, stream) => {
            if (completed || !Account.equals_func(seen_account, account)) return;
            completed = true;
            success = true;
            remove_source(ref timeout_id);
            if (error_id != 0) SignalHandler.disconnect(stream_interactor.connection_manager, error_id);
            if (negotiated_id != 0) SignalHandler.disconnect(stream_interactor, negotiated_id);
            resume();
        });
        error_id = stream_interactor.connection_manager.connection_error.connect((seen_account, error) => {
            if (completed || !Account.equals_func(seen_account, account)) return;
            completed = true;
            success = false;
            local_failure_reason = format_connection_error(error);
            remove_source(ref timeout_id);
            if (error_id != 0) SignalHandler.disconnect(stream_interactor.connection_manager, error_id);
            if (negotiated_id != 0) SignalHandler.disconnect(stream_interactor, negotiated_id);
            resume();
        });
        timeout_id = Timeout.add_seconds(timeout_seconds, () => {
            if (completed) return Source.REMOVE;
            completed = true;
            success = false;
            local_failure_reason = "timed out waiting for XMPP stream negotiation";
            timeout_id = 0;
            if (error_id != 0) SignalHandler.disconnect(stream_interactor.connection_manager, error_id);
            if (negotiated_id != 0) SignalHandler.disconnect(stream_interactor, negotiated_id);
            resume();
            return Source.REMOVE;
        });

        stream_interactor.connect_account(account);
        yield;
        failure_reason = local_failure_reason;
        return success;
    }

    private static void publish_ready_message(RemoteForeignHttpUploadSmokeConfig config) throws Error {
        string message = "remote-foreign-http-upload-smoke-ready\n" +
            @"expected_size=$(config.expected_size)\n" +
            @"expected_sha256=$(config.expected_sha256)\n";
        if (config.expected_name != null) {
            message += @"expected_name=$((!) config.expected_name)\n";
        }
        GLib.Test.message("Remote foreign HTTP upload receiver is ready");
        if (config.ready_file != null) {
            FileUtils.set_contents((!) config.ready_file, message);
        }
    }

    private delegate bool ConditionCheck();

    private async bool wait_for_condition(uint timeout_seconds, owned ConditionCheck condition) {
        if (condition()) return true;

        SourceFunc resume = wait_for_condition.callback;
        bool done = false;
        bool success = false;
        uint timeout_id = 0;
        uint poll_id = 0;

        timeout_id = Timeout.add_seconds(timeout_seconds, () => {
            done = true;
            success = condition();
            timeout_id = 0;
            remove_source(ref poll_id);
            resume();
            return Source.REMOVE;
        });
        poll_id = Timeout.add(100, () => {
            if (done) return Source.REMOVE;
            if (!condition()) return Source.CONTINUE;
            done = true;
            success = true;
            poll_id = 0;
            remove_source(ref timeout_id);
            resume();
            return Source.REMOVE;
        });

        yield;
        remove_source(ref poll_id);
        remove_source(ref timeout_id);
        return success;
    }

    private static void remove_source(ref uint source_id) {
        if (source_id == 0) return;
        uint id = source_id;
        source_id = 0;
        Source.remove(id);
    }

    private static void validate_received_transfer(FileTransfer file_transfer, Conversation conversation, RemoteForeignHttpUploadSmokeConfig config) throws Error {
        if (file_transfer.id == -1) {
            throw new IOError.FAILED("remote foreign HTTP upload receive must publish a persisted incoming transfer");
        }
        if (file_transfer.direction != FileTransfer.DIRECTION_RECEIVED) {
            throw new IOError.FAILED("remote foreign HTTP upload receiver transfer must be incoming");
        }
        if (!file_transfer.counterpart.equals_bare(config.sender_jid.bare_jid)) {
            throw new IOError.FAILED("remote foreign HTTP upload receiver transfer must come from the expected sender");
        }
        if (file_transfer.encryption != Encryption.NONE) {
            throw new IOError.FAILED("remote foreign HTTP upload receiver transfer must stay unencrypted");
        }
        if (file_transfer.provider != Dino.FileManager.HTTP_PROVIDER_ID) {
            throw new IOError.FAILED(@"remote foreign HTTP upload receiver transfer must use the HTTP provider, got provider $(file_transfer.provider)");
        }
        if (file_transfer.info == null || !((!) file_transfer.info).has_prefix("url:")) {
            throw new IOError.FAILED("remote foreign HTTP upload receiver transfer must persist the legacy HTTP URL source");
        }
        string transfer_url = ((!) file_transfer.info).substring("url:".length);
        if (!FileProvider.http_url_regex.match(transfer_url)) {
            throw new IOError.FAILED("remote foreign HTTP upload receiver transfer source must be an HTTP(S) URL");
        }
        if (config.expected_name != null && file_transfer.file_name != (!) config.expected_name) {
            throw new IOError.FAILED(@"remote foreign HTTP upload receiver file name '$(file_transfer.file_name)' did not match expected payload");
        }
        if (file_transfer.size != config.expected_size) {
            throw new IOError.FAILED(@"remote foreign HTTP upload receiver transfer published size $(file_transfer.size) instead of $(config.expected_size)");
        }
        if (file_transfer.state != FileTransfer.State.COMPLETE || file_transfer.phase != FileTransfer.Phase.COMPLETE) {
            throw new IOError.FAILED("remote foreign HTTP upload receiver transfer must finish COMPLETE");
        }
        if (file_transfer.phase_error != null) {
            throw new IOError.FAILED(@"remote foreign HTTP upload receiver transfer kept phase error '$(file_transfer.phase_error)'");
        }
        if (file_transfer.path == null || file_transfer.path == "") {
            throw new IOError.FAILED("remote foreign HTTP upload receiver transfer must publish a storage path");
        }
        if (!file_transfer.is_plaintext_release_allowed()) {
            throw new IOError.FAILED("remote foreign HTTP upload receiver transfer must only allow plaintext release after completion");
        }
        if (conversation.type_ != Conversation.Type.CHAT || !conversation.counterpart.equals_bare(config.sender_jid.bare_jid)) {
            throw new IOError.FAILED("remote foreign HTTP upload receiver conversation must be the expected one-to-one chat");
        }
    }

    private async void validate_stored_payload(Security.FileEncryption file_encryption, FileTransfer file_transfer, int64 expected_size, string expected_sha256) throws Error {
        File? stored_file = file_transfer.get_file();
        if (stored_file == null || !((!) stored_file).query_exists()) {
            throw new IOError.FAILED("remote foreign HTTP upload receive-store must write the verified local file");
        }

        var decrypted_output = new MemoryOutputStream.resizable();
        yield file_encryption.decrypt_file_to_stream((!) stored_file, decrypted_output, null);
        uint8[] decrypted = decrypted_output.steal_data();
        decrypted.length = (int) decrypted_output.get_data_size();

        if (decrypted.length != expected_size) {
            throw new IOError.FAILED(@"decrypted remote foreign HTTP upload payload size $(decrypted.length) did not match $(expected_size)");
        }
        string actual_sha256 = Checksum.compute_for_data(ChecksumType.SHA256, decrypted);
        if (actual_sha256.down() != expected_sha256.down()) {
            throw new IOError.FAILED("decrypted remote foreign HTTP upload payload SHA-256 did not match expected payload");
        }
    }

    private static int count_receive_pending_files_for_basename(string storage_dir, string file_name) {
        int count = 0;
        File dir = File.new_for_path(storage_dir);
        try {
            FileEnumerator enumerator = dir.enumerate_children(FileAttribute.STANDARD_NAME, FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
            FileInfo? info;
            while ((info = enumerator.next_file()) != null) {
                string name = ((!) info).get_name();
                if (name.has_prefix(file_name + ".") && name.has_suffix(".download")) count++;
            }
            enumerator.close();
        } catch (Error e) {
            GLib.Test.message(@"Could not count pending remote foreign HTTP upload receive files: $(e.message)");
        }
        return count;
    }

    private static string format_connection_error(ConnectionManager.ConnectionError error) {
        string text = @"XMPP connection error: $(error.source.to_string())";
        if (error.identifier != null) {
            text += @"/$((!) error.identifier)";
        }
        if (error.tls_flags != 0) {
            text += @" TLS flags $(error.tls_flags.to_string())";
        }
        return text;
    }

    private static void restore_default_application(TestApplication? application, GLib.Application? previous_application) {
        if (application == null) return;
        if (GLib.Application.get_default() == (!) application) {
            GLib.Application.set_default(previous_application);
        }
    }

    private static void restore_env_var(string name, string? previous_value) {
        if (previous_value == null) {
            Environment.unset_variable(name);
        } else {
            Environment.set_variable(name, (!) previous_value, true);
        }
    }

    private static void delete_file_tree(File file) throws Error {
        FileType type = file.query_file_type(FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
        if (type == FileType.DIRECTORY) {
            FileEnumerator enumerator = file.enumerate_children(
                FileAttribute.STANDARD_NAME,
                FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
            FileInfo? info;
            while ((info = enumerator.next_file()) != null) {
                delete_file_tree(file.get_child(((!) info).get_name()));
            }
            enumerator.close();
        }
        file.delete();
    }

    private class RemoteForeignHttpUploadSmokeConfig : Object {
        public Jid receiver_jid;
        public string receiver_password;
        public Jid sender_jid;
        public string? expected_name = null;
        public int64 expected_size;
        public string expected_sha256;
        public string? custom_host = null;
        public int custom_port = 0;
        public string? ready_file = null;
        public uint timeout_seconds = DEFAULT_TIMEOUT_SECONDS;

        public static RemoteForeignHttpUploadSmokeConfig? from_env() {
            if (Environment.get_variable("DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_SMOKE") != "1") {
                GLib.Test.skip("Set DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_SMOKE=1 with receiver, sender and expected payload env to run the remote foreign HTTP upload smoke");
                return null;
            }

            string? receiver_env = require_env("DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_RECEIVER_JID");
            string? receiver_password_env = require_env("DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_RECEIVER_PASSWORD");
            string? sender_env = require_env("DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_SENDER_JID");
            string? expected_size_env = require_env("DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_EXPECTED_SIZE");
            string? expected_sha256_env = require_env("DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_EXPECTED_SHA256");
            if (receiver_env == null || receiver_password_env == null || sender_env == null ||
                    expected_size_env == null || expected_sha256_env == null) {
                return null;
            }

            RemoteForeignHttpUploadSmokeConfig config = new RemoteForeignHttpUploadSmokeConfig();
            try {
                config.receiver_jid = new Jid((!) receiver_env);
                config.sender_jid = new Jid((!) sender_env);
                if (config.receiver_jid.resourcepart != null || config.sender_jid.resourcepart != null) {
                    fail_if(true, "remote foreign HTTP upload smoke requires bare receiver and sender account JIDs");
                    return null;
                }
                if (config.receiver_jid.bare_jid.equals(config.sender_jid.bare_jid)) {
                    fail_if(true, "remote foreign HTTP upload smoke requires distinct sender and receiver accounts");
                    return null;
                }
            } catch (InvalidJidError e) {
                fail_if(true, @"Remote foreign HTTP upload smoke env contains an invalid JID: $(e.message)");
                return null;
            }

            int64 parsed_size = 0;
            if (!int64.try_parse((!) expected_size_env, out parsed_size, null, 10) ||
                    parsed_size < 0 || parsed_size >= AUTO_DOWNLOAD_MAX_BYTES) {
                fail_if(true, "DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_EXPECTED_SIZE must be an integer between 0 and 4999999");
                return null;
            }
            string normalized_sha256 = normalize_sha256((!) expected_sha256_env);
            if (!is_sha256_hex(normalized_sha256)) {
                fail_if(true, "DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_EXPECTED_SHA256 must be a SHA-256 hex digest");
                return null;
            }

            config.receiver_password = (!) receiver_password_env;
            config.expected_size = parsed_size;
            config.expected_sha256 = normalized_sha256;
            config.custom_host = empty_to_null(Environment.get_variable("DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_HOST"));
            config.expected_name = nullable_sanitized_filename(Environment.get_variable("DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_EXPECTED_NAME"));
            config.ready_file = empty_to_null(Environment.get_variable("DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_READY_FILE"));

            string? port_env = empty_to_null(Environment.get_variable("DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_PORT"));
            if (port_env != null) {
                int parsed_port = 0;
                if (!int.try_parse((!) port_env, out parsed_port, null, 10) || parsed_port < 1 || parsed_port > 65535) {
                    fail_if(true, "DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_PORT must be an integer between 1 and 65535");
                    return null;
                }
                config.custom_port = parsed_port;
            }

            string? timeout_env = empty_to_null(Environment.get_variable("DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_TIMEOUT_SECONDS"));
            if (timeout_env != null) {
                uint parsed_timeout = 0;
                if (!uint.try_parse((!) timeout_env, out parsed_timeout, null, 10) || parsed_timeout < 5 || parsed_timeout > 600) {
                    fail_if(true, "DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_TIMEOUT_SECONDS must be an integer between 5 and 600");
                    return null;
                }
                config.timeout_seconds = parsed_timeout;
            }

            return config;
        }

        private static string? require_env(string name) {
            string? value = empty_to_null(Environment.get_variable(name));
            if (value == null) {
                fail_if(true, @"$name must be set when DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_SMOKE=1");
                return null;
            }
            return value;
        }

        private static string? nullable_sanitized_filename(string? value) {
            string? stripped = empty_to_null(value);
            if (stripped == null) return null;
            return FileTransfer.sanitize_file_name((!) stripped);
        }

        private static string normalize_sha256(string value) {
            return value.down().replace(":", "").replace("-", "").replace(" ", "");
        }

        private static bool is_sha256_hex(string value) {
            if (value.length != 64) return false;
            for (int i = 0; i < value.length; i++) {
                char c = value[i];
                if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return false;
            }
            return true;
        }

        private static string? empty_to_null(string? value) {
            if (value == null) return null;
            string stripped = ((!) value).strip();
            return stripped == "" ? null : stripped;
        }
    }

    private class TestApplication : GLib.Application, Dino.Application {
        public Database db { get; set; }
        public string? db_key { get; set; }
        public Security.FileEncryption file_encryption { get; set; }
        public Dino.Entities.Settings settings { get; set; }
        public StreamInteractor stream_interactor { get; set; }
        public Plugins.Registry plugin_registry { get; set; default = new Plugins.Registry(); }
        public SearchPathGenerator? search_path_generator { get; set; }

        public TestApplication(Database db, StreamInteractor stream_interactor) {
            Object(application_id: "im.dinox.remote-foreign-http-upload-smoke-test", flags: GLib.ApplicationFlags.NON_UNIQUE);
            this.db = db;
            this.db_key = "remote-foreign-http-upload-smoke-test";
            this.file_encryption = new Security.FileEncryption((!) this.db_key);
            this.settings = new Dino.Entities.Settings.from_db(db);
            this.stream_interactor = stream_interactor;
        }

        public void handle_uri(string jid, string query, Gee.Map<string, string> options) {
        }
    }
}

}

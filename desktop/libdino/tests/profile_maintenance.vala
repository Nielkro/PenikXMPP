using Dino.Security;

namespace Dino.Test {

class ProfileMaintenanceTest : Gee.TestCase {
    private const string OLD = "old maintenance password";
    private const string NEXT = "new maintenance password";
    private const string OMEMO = "independent omemo database key";

    public ProfileMaintenanceTest() {
        base("ProfileMaintenance");
        add_test("schedule_is_encrypted_and_does_not_touch_profile", test_schedule);
        add_test("wrong_password_preserves_profile_and_request", test_wrong_password);
        add_test("password_change_rekeys_all_shared_databases_and_preserves_files", test_password_change);
        add_test("plugin_failure_keeps_original_profile_and_retry_request", test_plugin_failure);
        add_test("unfinished_stage_is_rebuilt_from_original", test_unfinished_stage);
        add_test("installed_marker_finishes_without_old_password", test_finish_after_swap);
        add_test("reset_preserves_all_accounts_settings_and_plugin_scope", test_reset);
        add_test("cancel_preserves_other_profiles_and_unowned_directories", test_cancel_scope);
        add_test("existing_database_open_never_creates_or_migrates", test_existing_open);
        add_test("cancelled_maintenance_preserves_profile_and_request", test_cancelled);
#if !WINDOWS
        add_test("failed_request_cleanup_preserves_ownership_for_retry", test_failed_request_cleanup);
        add_test("profile_symlink_is_rejected_without_changing_target", test_profile_symlink);
#endif
    }

    private class Fixture : Object {
        public string root;
        public string profile;
        public string manifest;

        public Fixture() throws Error {
            root = DirUtils.make_tmp("dinox-profile-maintenance-XXXXXX");
            profile = Path.build_filename(root, "dinox");
            manifest = Path.build_filename(root, ".dinox-maintenance-pending");
            DirUtils.create(profile, 0700);
            var core = new Dino.Database(Path.build_filename(profile, "dino.db"), OLD);
            core.exec("INSERT INTO account (id,bare_jid,password,enabled,roster_version) VALUES (7,'one@example.test','one-secret',1,'v7'),(19,'two@example.test','two-secret',0,'v19')");
            core.exec("INSERT INTO account_settings (account_id,key,value) VALUES (7,'setting-a','one'),(19,'setting-a','two')");
            core.exec("INSERT INTO settings (key,value) VALUES ('theme','dark')");
            core.exec("INSERT INTO jid (id,bare_jid) VALUES (3,'contact@example.test')");
            core.exec("INSERT INTO conversation (id,account_id,jid_id,type,read_up_to,read_up_to_item) VALUES (5,7,3,0,11,12)");
            core.exec("INSERT INTO conversation_settings (conversation_id,key,value) VALUES (5,'custom-setting','preserved')");
            core.exec("INSERT INTO message (id,account_id,counterpart_id,direction,body) VALUES (11,7,3,0,'private history')");
            core.exec("INSERT INTO content_item (id,conversation_id,time,local_time,content_type,foreign_id) VALUES (12,5,1,1,1,11)");
            core.exec("INSERT INTO sticker_pack (account_id,pack_id,name) VALUES (19,'local-library','Local stickers')");
            core.close();
            foreach (string name in new string[] { "pgp.db", "mqtt.db", "bot_registry.db" }) create_plugin(name, OLD);
            create_plugin("omemo.db", OMEMO);
            FileUtils.set_contents(Path.build_filename(profile, "omemo.key"), OMEMO);
            DirUtils.create(Path.build_filename(profile, "files"), 0700);
            var encryption = new FileEncryption(OLD);
            FileUtils.set_data(Path.build_filename(profile, "files", "kept.enc"), encryption.encrypt_data("old encrypted attachment".data));
            DirUtils.create(Path.build_filename(profile, "stickers"), 0700);
            FileUtils.set_contents(Path.build_filename(profile, "stickers", "local.enc"), "local encrypted sticker");
        }

        private void create_plugin(string name, string key) throws Error {
            var database = new Qlite.Database(Path.build_filename(profile, name), 1);
            database.init({}, key, false);
            database.exec("CREATE TABLE preserved (account_id INTEGER, value TEXT)");
            database.exec("INSERT INTO preserved VALUES (7,'first account'),(19,'second account')");
            database.close();
        }

        public string token() throws Error {
            var data = new KeyFile();
            data.load_from_file(manifest, KeyFileFlags.NONE);
            return data.get_string("Maintenance", "token");
        }

        public string request_dir() throws Error { return Path.build_filename(root, ".dinox-maintenance-" + token()); }
        public string stage() throws Error { return Path.build_filename(root, "dinox-restore-stage-" + token()); }
        public void cleanup() {
            try { remove_tree(root); } catch (Error e) { warning("Maintenance fixture cleanup failed: %s", e.message); }
        }
    }

    private static void remove_tree(string path) throws Error {
        var file = File.new_for_path(path);
        var entry = file.query_info(FileAttribute.STANDARD_TYPE, FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
        if (entry.get_file_type() == FileType.DIRECTORY) {
            var children = file.enumerate_children(FileAttribute.STANDARD_NAME, FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
            FileInfo? child;
            while ((child = children.next_file()) != null) remove_tree(Path.build_filename(path, child.get_name()));
            children.close();
        }
        file.delete();
    }

    private Bytes bytes(string path) throws Error {
        uint8[] data;
        FileUtils.get_data(path, out data);
        return new Bytes(data);
    }

    private void unchanged(string path, Bytes before) throws Error {
        fail_if(before.compare(bytes(path)) != 0, "Original profile bytes changed before a complete install");
    }

    private void assert_key(string path, string key, string wrong) throws Error {
        var database = Qlite.Database.open_existing(path, key);
        database.close();
        try {
            database = Qlite.Database.open_existing(path, wrong);
            database.close();
            fail_if_reached("Database accepted the wrong key");
        } catch (Error expected) { }
    }

    private string value(Qlite.Database database, string sql) throws Error {
        string[] values = database.query_column_checked(sql);
        fail_if(values.length != 1, "Expected exactly one result");
        return values.length == 1 ? values[0] : "";
    }

    private void test_schedule() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture();
            string core = Path.build_filename(fixture.profile, "dino.db");
            Bytes before = bytes(core);
            ProfileMaintenance.schedule_password_change(fixture.profile, OLD, NEXT);
            unchanged(core, before);
            string manifest;
            FileUtils.get_contents(fixture.manifest, out manifest);
            fail_if(manifest.contains(OLD) || manifest.contains(NEXT));
            string request = Path.build_filename(fixture.request_dir(), "request.db");
            uint8[] data;
            FileUtils.get_data(request, out data);
            fail_if(data.length < 16);
            fail_if(new Bytes(data[0:15]).compare(new Bytes("SQLite format 3".data)) == 0,
                "Request contains plaintext SQLite data");
            assert_key(request, OLD, NEXT);
            fail_if(FileUtils.test(fixture.stage(), FileTest.EXISTS), "Scheduling must not copy the live profile");
        } catch (Error e) { fail_if_reached(e.message); }
        finally { if (fixture != null) fixture.cleanup(); }
    }

    private void test_wrong_password() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture();
            string core = Path.build_filename(fixture.profile, "dino.db");
            Bytes before = bytes(core);
            ProfileMaintenance.schedule_password_change(fixture.profile, OLD, NEXT);
            try { ProfileMaintenance.apply_pending(fixture.profile, "incorrect"); fail_if_reached("Wrong password accepted"); }
            catch (Error expected) { }
            unchanged(core, before);
            fail_if_not(ProfileMaintenance.has_pending(fixture.profile));
            fail_if(FileUtils.test(fixture.stage(), FileTest.EXISTS));
        } catch (Error e) { fail_if_reached(e.message); }
        finally { if (fixture != null) fixture.cleanup(); }
    }

    private void test_password_change() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture();
            string omemo = Path.build_filename(fixture.profile, "omemo.db");
            Bytes original_omemo = bytes(omemo);
            string file = Path.build_filename(fixture.profile, "files", "kept.enc");
            Bytes original_file = bytes(file);
            ProfileMaintenance.schedule_password_change(fixture.profile, OLD, NEXT);
            string token = fixture.token();
            string request_dir = fixture.request_dir();
            fail_if_not_eq_str(NEXT, ProfileMaintenance.apply_pending(fixture.profile, OLD));
            foreach (string name in new string[] { "dino.db", "pgp.db", "mqtt.db", "bot_registry.db" })
                assert_key(Path.build_filename(fixture.profile, name), NEXT, OLD);
            unchanged(omemo, original_omemo);
            unchanged(file, original_file);
            var core = new Dino.Database(Path.build_filename(fixture.profile, "dino.db"), NEXT);
            string secret = core.get_or_create_file_encryption_key(NEXT);
            fail_if_not_eq_str(OLD, secret);
            uint8[] encrypted;
            FileUtils.get_data(file, out encrypted);
            var encryption = new FileEncryption(secret);
            uint8[] decrypted = encryption.decrypt_data(encrypted);
            fail_if(new Bytes(decrypted).compare(new Bytes("old encrypted attachment".data)) != 0);
            fail_if_not_eq_str("2", value(core, "SELECT count(*) FROM account"));
            fail_if_not_eq_str("1", value(core, "SELECT count(*) FROM message"));
            core.close();
            fail_if(ProfileMaintenance.has_pending(fixture.profile));
            fail_if(FileUtils.test(request_dir, FileTest.EXISTS));
            fail_if(FileUtils.test(Path.build_filename(fixture.root, ".dinox-restore-rollback-" + token), FileTest.EXISTS));
        } catch (Error e) { fail_if_reached(e.message); }
        finally { if (fixture != null) fixture.cleanup(); }
    }

    private void test_plugin_failure() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture();
            string core = Path.build_filename(fixture.profile, "dino.db");
            string broken = Path.build_filename(fixture.profile, "mqtt.db");
            FileUtils.set_contents(broken, "corrupted plugin database");
            Bytes before = bytes(core);
            ProfileMaintenance.schedule_password_change(fixture.profile, OLD, NEXT);
            string stage = fixture.stage();
            try { ProfileMaintenance.apply_pending(fixture.profile, OLD); fail_if_reached("Corrupt plugin database accepted"); }
            catch (Error expected) { }
            unchanged(core, before);
            assert_key(core, OLD, NEXT);
            fail_if_not(ProfileMaintenance.has_pending(fixture.profile));
            fail_if(FileUtils.test(stage, FileTest.EXISTS));
        } catch (Error e) { fail_if_reached(e.message); }
        finally { if (fixture != null) fixture.cleanup(); }
    }

    private void test_unfinished_stage() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture();
            ProfileMaintenance.schedule_password_change(fixture.profile, OLD, NEXT);
            string stage = fixture.stage();
            ProfileRestore.prepare_stage(fixture.profile, stage);
            FileUtils.set_contents(Path.build_filename(stage, "unfinished"), "interrupted copy");
            fail_if_not_eq_str(NEXT, ProfileMaintenance.apply_pending(fixture.profile, OLD));
            fail_if(FileUtils.test(Path.build_filename(fixture.profile, "unfinished"), FileTest.EXISTS));
            assert_key(Path.build_filename(fixture.profile, "dino.db"), NEXT, OLD);
        } catch (Error e) { fail_if_reached(e.message); }
        finally { if (fixture != null) fixture.cleanup(); }
    }

    private void test_finish_after_swap() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture();
            ProfileMaintenance.schedule_password_change(fixture.profile, OLD, NEXT);
            string stage = fixture.stage();
            string token = fixture.token();
            string request_dir = fixture.request_dir();
            ProfileRestore.prepare_stage(fixture.profile, stage);
            string profile = Path.build_filename(stage, "dinox");
            DirUtils.create(profile, 0700);
            var database = new Dino.Database(Path.build_filename(profile, "dino.db"), NEXT);
            database.close();
            FileUtils.set_contents(Path.build_filename(profile, ".dinox-maintenance-complete"), token);
            ProfileRestore.schedule(fixture.profile, stage);
            ProfileRestore.apply_pending(fixture.profile);
            // Simulate a process crash after swap, before request deletion.
            string restore_hint = Path.build_filename(fixture.profile, ".restore_pending");
            fail_if_not(FileUtils.test(restore_hint, FileTest.EXISTS));
            fail_if_not(ProfileMaintenance.finish_completed(fixture.profile));
            fail_if(FileUtils.test(restore_hint, FileTest.EXISTS),
                "Completed password maintenance still asks for the original backup password");
            fail_if(ProfileMaintenance.finish_completed(fixture.profile));
            fail_if_not_eq_str(NEXT, ProfileMaintenance.apply_pending(fixture.profile, NEXT));
            fail_if(FileUtils.test(request_dir, FileTest.EXISTS));
            assert_key(Path.build_filename(fixture.profile, "dino.db"), NEXT, OLD);
            // A subsequent regular restore has no maintenance request. Even
            // an old COMPLETE marker must not consume its unlock hint.
            FileUtils.set_contents(restore_hint, "1");
            fail_if(ProfileMaintenance.finish_completed(fixture.profile));
            fail_if_not(FileUtils.test(restore_hint, FileTest.EXISTS),
                "Normal backup restore lost its original-password hint");
        } catch (Error e) { fail_if_reached(e.message); }
        finally { if (fixture != null) fixture.cleanup(); }
    }

    private void test_reset() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture();
            Bytes pgp_before = bytes(Path.build_filename(fixture.profile, "pgp.db"));
            ProfileMaintenance.schedule_reset(fixture.profile, OLD);
            fail_if_not_eq_str(OLD, ProfileMaintenance.apply_pending(fixture.profile, OLD));
            var core = new Dino.Database(Path.build_filename(fixture.profile, "dino.db"), OLD);
            fail_if_not_eq_str("7,19", value(core, "SELECT group_concat(id, ',') FROM (SELECT id FROM account ORDER BY id)"));
            fail_if_not_eq_str("one,two", value(core, "SELECT group_concat(value, ',') FROM (SELECT value FROM account_settings ORDER BY account_id)"));
            fail_if_not_eq_str("dark", value(core, "SELECT value FROM settings WHERE key='theme'"));
            fail_if_not_eq_str("preserved", value(core, "SELECT value FROM conversation_settings WHERE conversation_id=5"));
            fail_if_not_eq_str("v7", value(core, "SELECT roster_version FROM account WHERE id=7"));
            fail_if_not_eq_str("0", value(core, "SELECT count(*) FROM message"));
            fail_if_not_eq_str("0", value(core, "SELECT count(*) FROM content_item"));
            fail_if_not_eq_str("1", value(core, "SELECT count(*) FROM sticker_pack WHERE account_id=19"));
            fail_if_not_eq_str("1", value(core, "SELECT count(*) FROM conversation WHERE read_up_to IS NULL AND read_up_to_item=-1 AND history_cleared_at>0"));
            core.close();
            unchanged(Path.build_filename(fixture.profile, "pgp.db"), pgp_before);
            foreach (string name in new string[] { "omemo.db", "omemo.key", "files" })
                fail_if(FileUtils.test(Path.build_filename(fixture.profile, name), FileTest.EXISTS));
            fail_if_not(FileUtils.test(Path.build_filename(fixture.profile, "stickers", "local.enc"), FileTest.EXISTS));
        } catch (Error e) { fail_if_reached(e.message); }
        finally { if (fixture != null) fixture.cleanup(); }
    }

    private void test_cancel_scope() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture();
            ProfileMaintenance.schedule_reset(fixture.profile, OLD);
            string request_dir = fixture.request_dir();
            string other = Path.build_filename(fixture.root, "other");
            DirUtils.create(other, 0700);
            ProfileMaintenance.schedule_password_change(other, "other-old", "other-new");
            string unowned = Path.build_filename(fixture.root, ".dinox-maintenance-" + Uuid.string_random());
            DirUtils.create(unowned, 0700);
            FileUtils.set_contents(Path.build_filename(unowned, "keep"), "unowned");
            ProfileMaintenance.cancel_pending(fixture.profile);
            fail_if(FileUtils.test(request_dir, FileTest.EXISTS));
            fail_if(ProfileMaintenance.has_pending(fixture.profile));
            fail_if_not(ProfileMaintenance.has_pending(other));
            fail_if_not(FileUtils.test(Path.build_filename(unowned, "keep"), FileTest.EXISTS));
        } catch (Error e) { fail_if_reached(e.message); }
        finally { if (fixture != null) fixture.cleanup(); }
    }

    private void test_cancelled() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture();
            Bytes before = bytes(Path.build_filename(fixture.profile, "dino.db"));
            ProfileMaintenance.schedule_password_change(fixture.profile, OLD, NEXT);
            var cancellable = new Cancellable();
            cancellable.cancel();
            try { ProfileMaintenance.apply_pending(fixture.profile, OLD, cancellable); fail_if_reached("Cancelled maintenance applied"); }
            catch (IOError.CANCELLED expected) { }
            unchanged(Path.build_filename(fixture.profile, "dino.db"), before);
            fail_if_not(ProfileMaintenance.has_pending(fixture.profile));
            fail_if(FileUtils.test(fixture.stage(), FileTest.EXISTS));
        } catch (Error e) { fail_if_reached(e.message); }
        finally { if (fixture != null) fixture.cleanup(); }
    }

    private void test_existing_open() {
        string? root = null;
        try {
            root = DirUtils.make_tmp("dinox-maintenance-existing-XXXXXX");
            string missing = Path.build_filename(root, "missing.db");
            try { var database = Qlite.Database.open_existing(missing, OLD); database.close(); fail_if_reached("Created a missing database"); }
            catch (Error expected) { }
            fail_if(FileUtils.test(missing, FileTest.EXISTS));
            FileUtils.set_contents(missing, "");
            try { var database = Qlite.Database.open_existing(missing, OLD); database.close(); fail_if_reached("Empty file accepted as encrypted database"); }
            catch (Error expected) { }
            FileUtils.remove(missing);
            var created = Qlite.Database.create_encrypted(missing, OLD);
            created.exec("CREATE TABLE custom_schema (value TEXT)");
            created.exec_prepared("INSERT INTO custom_schema VALUES (?)", { "preserved" });
            created.close();
            created = Qlite.Database.open_existing(missing, OLD);
            fail_if_not_eq_str("preserved", value(created, "SELECT value FROM custom_schema"));
            fail_if_not_eq_str("0", value(created, "SELECT count(*) FROM sqlite_master WHERE name='_meta'"));
            created.close();
            Bytes existing = bytes(missing);
            try { created = Qlite.Database.create_encrypted(missing, NEXT); created.close(); fail_if_reached("Existing database overwritten"); }
            catch (Error expected) { }
            unchanged(missing, existing);
            string path = Path.build_filename(root, "plaintext.db");
            var plain = new Qlite.Database(path, 1);
            plain.init({});
            plain.close();
            Bytes original = bytes(path);
            try { var database = Qlite.Database.open_existing(path, OLD); database.close(); fail_if_reached("Plaintext fallback was accepted"); }
            catch (Error expected) { }
            unchanged(path, original);
        } catch (Error e) { fail_if_reached(e.message); }
        finally { if (root != null) { try { remove_tree(root); } catch (Error ignored) { } } }
    }

#if !WINDOWS
    private void test_failed_request_cleanup() {
        Fixture? fixture = null;
        string? protected_dir = null;
        try {
            fixture = new Fixture();
            ProfileMaintenance.schedule_password_change(fixture.profile, OLD, NEXT);
            string request_dir = fixture.request_dir();
            protected_dir = Path.build_filename(request_dir, "blocked");
            fail_if(DirUtils.create(protected_dir, 0700) != 0);
            FileUtils.set_contents(Path.build_filename(protected_dir, "private"), "private request contents");
            fail_if(FileUtils.chmod(protected_dir, 0500) != 0);
            var access = File.new_for_path(protected_dir).query_info(
                FileAttribute.ACCESS_CAN_WRITE, FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
            if (access.get_attribute_boolean(FileAttribute.ACCESS_CAN_WRITE)) {
                GLib.Test.skip("Permission-failure fixture requires an unprivileged process");
                return;
            }
            bool failed = false;
            try { ProfileMaintenance.cancel_pending(fixture.profile); }
            catch (Error e) { failed = true; }
            fail_if_not(failed, "Cleanup must report a retained private payload");
            fail_if_not(FileUtils.test(Path.build_filename(request_dir, ".dinox-maintenance-request"), FileTest.IS_REGULAR),
                "Ownership must remain available after partial cleanup");
            fail_if_not(ProfileMaintenance.has_pending(fixture.profile));
            fail_if(FileUtils.chmod(protected_dir, 0700) != 0);
            ProfileMaintenance.cancel_pending(fixture.profile);
            fail_if(FileUtils.test(request_dir, FileTest.EXISTS));
            fail_if(ProfileMaintenance.has_pending(fixture.profile));
        } catch (Error e) { fail_if_reached(e.message); }
        finally {
            if (protected_dir != null) FileUtils.chmod(protected_dir, 0700);
            if (fixture != null) fixture.cleanup();
        }
    }

    private void test_profile_symlink() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture();
            string outside = Path.build_filename(fixture.root, "outside");
            FileUtils.set_contents(outside, "must stay unchanged");
            File.new_for_path(Path.build_filename(fixture.profile, "link")).make_symbolic_link(outside);
            Bytes before = bytes(Path.build_filename(fixture.profile, "dino.db"));
            ProfileMaintenance.schedule_password_change(fixture.profile, OLD, NEXT);
            try { ProfileMaintenance.apply_pending(fixture.profile, OLD); fail_if_reached("Symlink profile copied"); }
            catch (Error expected) { }
            unchanged(Path.build_filename(fixture.profile, "dino.db"), before);
            string contents;
            FileUtils.get_contents(outside, out contents);
            fail_if_not_eq_str("must stay unchanged", contents);
        } catch (Error e) { fail_if_reached(e.message); }
        finally { if (fixture != null) fixture.cleanup(); }
    }
#endif
}

}

using Dino.Security;

namespace Dino.Test {

class ProfileDataSafetyTest : Gee.TestCase {
    public ProfileDataSafetyTest() {
        base("ProfileDataSafety");
        add_test("cache_clear_preserves_both_accounts_roster_library_and_history", test_cache_scope);
        add_test("cache_sql_failure_rolls_back_and_is_reported", test_cache_failure);
        add_test("cache_files_preserve_active_leases_recordings_and_runtime_data", test_disposable_cache_scope);
        add_test("cancelled_cache_clear_preserves_files", test_cancelled_cache_clear);
        add_test("snapshot_uses_completed_databases_without_live_journals", test_snapshot);
        add_test("missing_snapshot_is_an_error", test_missing_snapshot);
#if !WINDOWS
        add_test("snapshot_rejects_unrestorable_links", test_snapshot_link);
        add_test("cache_clear_never_follows_disposable_directory_link", test_disposable_cache_link);
#endif
    }

    private Database create_database(string root) throws Error {
        var database = new Database(Path.build_filename(root, "dino.db"), "isolated cache password");
        database.exec("INSERT INTO account (id,bare_jid,password,enabled,roster_version) VALUES (7,'one@example.test','one',1,'v7'),(19,'two@example.test','two',0,'v19')");
        database.exec("INSERT INTO jid (id,bare_jid) VALUES (3,'contact@example.test')");
        database.exec("INSERT INTO roster (account_id,jid,name) VALUES (7,'contact@example.test','Contact one'),(19,'contact@example.test','Contact two')");
        database.exec("INSERT INTO sticker_pack (account_id,pack_id,name) VALUES (19,'local-only','Local stickers')");
        database.exec("INSERT INTO sticker_item (account_id,pack_id,position,local_path) VALUES (19,'local-only',0,'local.enc')");
        database.exec("INSERT INTO message (account_id,counterpart_id,direction,body) VALUES (7,3,0,'kept history')");
        database.exec("INSERT INTO entity (account_id,jid_id,caps_hash) VALUES (7,3,'discardable')");
        database.get_or_create_file_encryption_key("isolated cache password");
        return database;
    }

    private void test_cache_scope() {
        string? root = null;
        Database? database = null;
        try {
            root = DirUtils.make_tmp("dinox-cache-scope-XXXXXX");
            database = create_database(root);
            fail_if(database.purge_caches() != 1);
            fail_if_not_eq_str(database.query_column_checked("SELECT count(*) FROM entity")[0], "0");
            fail_if_not_eq_str(database.query_column_checked("SELECT count(*) FROM account")[0], "2");
            fail_if_not_eq_str(database.query_column_checked("SELECT count(*) FROM roster")[0], "2");
            fail_if_not_eq_str(database.query_column_checked("SELECT roster_version FROM account WHERE id=7")[0], "v7");
            fail_if_not_eq_str(database.query_column_checked("SELECT roster_version FROM account WHERE id=19")[0], "v19");
            foreach (string table in new string[] { "sticker_pack", "sticker_item", "message" }) {
                fail_if_not_eq_str(database.query_column_checked("SELECT count(*) FROM " + table)[0], "1");
            }
            fail_if_not_eq_str(database.get_or_create_file_encryption_key("must not replace"), "isolated cache password");
        } catch (Error err) { fail_if_reached(err.message); }
        finally {
            if (database != null) database.close();
            cleanup(root);
        }
    }

    private void test_cache_failure() {
        string? root = null;
        Database? database = null;
        try {
            root = DirUtils.make_tmp("dinox-cache-failure-XXXXXX");
            database = create_database(root);
            database.exec("INSERT INTO contact_avatar (account_id,jid_id,hash,type) VALUES (7,3,'avatar',0)");
            database.exec("CREATE TRIGGER deny_cache_delete BEFORE DELETE ON contact_avatar BEGIN SELECT RAISE(ABORT,'injected cache failure'); END");
            bool failed = false;
            try { database.purge_caches(); } catch (Error err) { failed = true; }
            fail_if(!failed, "cache failure must reach the caller");
            fail_if_not_eq_str(database.query_column_checked("SELECT count(*) FROM entity")[0], "1");
            fail_if_not_eq_str(database.query_column_checked("SELECT count(*) FROM contact_avatar")[0], "1");
        } catch (Error err) { fail_if_reached(err.message); }
        finally {
            if (database != null) database.close();
            cleanup(root);
        }
    }

    private void test_disposable_cache_scope() {
        string? root = null;
        try {
            root = DirUtils.make_tmp("dinox-disposable-cache-XXXXXX");
            foreach (string name in new string[] { "avatars", "providers", "temp_audio", "temp_video",
                    "temp_plaintext", "temp_open", "unknown-cache" }) {
                string directory = Path.build_filename(root, name);
                DirUtils.create(directory, 0700);
                FileUtils.set_contents(Path.build_filename(directory, "keep-or-discard"), name);
            }
            FileUtils.set_contents(Path.build_filename(root, "merged-ca-bundle.pem"), "runtime trust roots");
            FileUtils.set_contents(Path.build_filename(root, "pending-xmpp-uri"), "xmpp:pending@example.test");
            int64 deleted = ProfileDeletion.clear_disposable_caches(root);
            fail_if(deleted != "avatars".length + "providers".length,
                "Cache clear must report only the deleted regenerable file bytes");
            fail_if(FileUtils.test(Path.build_filename(root, "avatars"), FileTest.EXISTS));
            fail_if(FileUtils.test(Path.build_filename(root, "providers"), FileTest.EXISTS));
            foreach (string name in new string[] { "temp_audio", "temp_video", "temp_plaintext", "temp_open", "unknown-cache" }) {
                string contents;
                FileUtils.get_contents(Path.build_filename(root, name, "keep-or-discard"), out contents);
                fail_if_not_eq_str(contents, name);
            }
            string contents;
            FileUtils.get_contents(Path.build_filename(root, "merged-ca-bundle.pem"), out contents);
            fail_if_not_eq_str(contents, "runtime trust roots");
            FileUtils.get_contents(Path.build_filename(root, "pending-xmpp-uri"), out contents);
            fail_if_not_eq_str(contents, "xmpp:pending@example.test");
            fail_if(ProfileDeletion.clear_disposable_caches(root) != 0, "Repeated cache clearing should be harmless");
        } catch (Error err) { fail_if_reached(err.message); }
        finally { cleanup(root); }
    }

    private void test_cancelled_cache_clear() {
        string? root = null;
        try {
            root = DirUtils.make_tmp("dinox-cancel-cache-XXXXXX");
            DirUtils.create(Path.build_filename(root, "avatars"), 0700);
            string path = Path.build_filename(root, "avatars", "keep");
            FileUtils.set_contents(path, "untouched");
            var cancellable = new Cancellable();
            cancellable.cancel();
            bool failed = false;
            try { ProfileDeletion.clear_disposable_caches(root, cancellable); }
            catch (IOError.CANCELLED expected) { failed = true; }
            fail_if(!failed, "Cancellation must be reported to the caller");
            string contents;
            FileUtils.get_contents(path, out contents);
            fail_if_not_eq_str(contents, "untouched");
        } catch (Error err) { fail_if_reached(err.message); }
        finally { cleanup(root); }
    }

#if !WINDOWS
    private void test_disposable_cache_link() {
        string? root = null;
        try {
            root = DirUtils.make_tmp("dinox-cache-link-XXXXXX");
            string cache = Path.build_filename(root, "cache");
            string outside = Path.build_filename(root, "outside");
            DirUtils.create(cache, 0700);
            DirUtils.create(outside, 0700);
            FileUtils.set_contents(Path.build_filename(outside, "keep"), "outside data");
            File.new_for_path(Path.build_filename(cache, "avatars")).make_symbolic_link(outside);
            ProfileDeletion.clear_disposable_caches(cache);
            fail_if(FileUtils.test(Path.build_filename(cache, "avatars"), FileTest.IS_SYMLINK));
            string contents;
            FileUtils.get_contents(Path.build_filename(outside, "keep"), out contents);
            fail_if_not_eq_str(contents, "outside data");
            string root_link = Path.build_filename(root, "cache-link");
            File.new_for_path(root_link).make_symbolic_link(outside);
            bool failed = false;
            try { ProfileDeletion.clear_disposable_caches(root_link); }
            catch (IOError.INVALID_ARGUMENT expected) { failed = true; }
            fail_if(!failed, "Cache clearing must reject a symlink root");
            FileUtils.get_contents(Path.build_filename(outside, "keep"), out contents);
            fail_if_not_eq_str(contents, "outside data");
        } catch (Error err) { fail_if_reached(err.message); }
        finally { cleanup(root); }
    }
#endif

    private void test_snapshot() { check_snapshot(false, false); }
    private void test_missing_snapshot() { check_snapshot(true, false); }
#if !WINDOWS
    private void test_snapshot_link() { check_snapshot(false, true); }
#endif

    private void check_snapshot(bool missing, bool link) {
        string? root = null;
        try {
            root = DirUtils.make_tmp("dinox-profile-snapshot-XXXXXX");
            string source = Path.build_filename(root, "source");
            string target = Path.build_filename(root, "target");
            DirUtils.create(source, 0700);
            DirUtils.create(target, 0700);
            FileUtils.set_contents(Path.build_filename(source, "dino.db"), "live database");
            FileUtils.set_contents(Path.build_filename(source, "dino.db-wal"), "live WAL");
            FileUtils.set_contents(Path.build_filename(source, "dino.db-shm"), "live SHM");
            FileUtils.set_contents(Path.build_filename(source, "omemo.key"), "preserved key");
            if (!missing) FileUtils.set_contents(Path.build_filename(target, "dino.db"), "consistent snapshot");
#if !WINDOWS
            if (link) FileUtils.symlink("omemo.key", Path.build_filename(source, "link"));
#endif
            bool failed = false;
            try { ProfileSnapshot.copy_files(source, target); } catch (Error err) { failed = true; }
            fail_if(failed != (missing || link));
            if (!missing) {
                string contents;
                FileUtils.get_contents(Path.build_filename(target, "dino.db"), out contents);
                fail_if_not_eq_str(contents, "consistent snapshot");
            }
            fail_if(FileUtils.test(Path.build_filename(target, "dino.db-wal"), FileTest.EXISTS));
            fail_if(FileUtils.test(Path.build_filename(target, "dino.db-shm"), FileTest.EXISTS));
            if (!missing && !link) {
                string key;
                FileUtils.get_contents(Path.build_filename(target, "omemo.key"), out key);
                fail_if_not_eq_str(key, "preserved key");
            }
        } catch (Error err) { fail_if_reached(err.message); }
        finally { cleanup(root); }
    }

    private void cleanup(string? root) {
        if (root == null) return;
        try { ProfileDeletion.delete_tree(File.new_for_path(root)); }
        catch (Error err) { fail_if_reached(err.message); }
    }
}

}

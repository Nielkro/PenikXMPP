using Dino.Security;

namespace Dino.Test {

class ProfileDeletionTest : Gee.TestCase {
    public ProfileDeletionTest() {
        base("ProfileDeletion");
        add_test("no_request_never_deletes_data", test_no_request);
        add_test("schedule_is_deferred_and_cannot_be_overwritten", test_schedule);
        add_test("factory_and_panic_delete_only_requested_roots", test_profile_isolation);
        add_test("malformed_request_fails_before_data_deletion", test_invalid_request);
        add_test("partial_failure_keeps_request_for_idempotent_retry", test_failed_retry);
        add_test("wipe_cleans_owned_backup_restore_and_rollback_artifacts", test_artifacts);
        add_test("backup_cleanup_removes_only_exact_owned_stage", test_backup_cleanup);
        add_test("backup_cleanup_rejects_unowned_and_linked_stages", test_backup_cleanup_rejection);
        add_test("wipe_cancels_only_its_encrypted_password_request", test_password_request);
        add_test("tree_deletion_does_not_follow_child_links", test_child_link);
        add_test("content_deletion_rejects_link_root", test_root_link);
        add_test("request_symlink_is_not_followed", test_request_link);
#if !WINDOWS
        add_test("backup_payload_failure_preserves_owner_and_pending_request", test_backup_owner_retry);
        add_test("backup_cleanup_failure_preserves_owner_without_wipe_request", test_direct_backup_owner_retry);
#endif
    }

    private delegate void FixtureTest(Fixture fixture) throws Error;

    private class Fixture : Object {
        public string root;
        public string profile;
        public string configuration;
        public string cache;
        public string temporary;
        public string other;
        public string request;

        public Fixture() throws Error {
            root = DirUtils.make_tmp("dinox-profile-deletion-XXXXXX");
            profile = Path.build_filename(root, "dinox");
            configuration = Path.build_filename(root, "configuration", "dinox");
            cache = Path.build_filename(root, "cache", "dinox");
            temporary = Path.build_filename(root, "temporary");
            other = Path.build_filename(root, "other-profile");
            request = Path.build_filename(root, ".dinox-delete-pending");
            foreach (string directory in new string[] {profile, configuration, cache, temporary, other}) {
                if (DirUtils.create_with_parents(directory, 0700) != 0)
                    throw new IOError.FAILED("Cannot create private deletion fixture");
                FileUtils.set_contents(Path.build_filename(directory, "sentinel"), "keep until requested");
            }
            FileUtils.set_contents(Path.build_filename(profile, "dino.db"), "test database payload");
            FileUtils.set_contents(Path.build_filename(profile, "omemo.key"), "test key payload");
            FileUtils.set_contents(Path.build_filename(other, "dino.db"), "other profile payload");
        }

        public bool apply() throws Error {
            return ProfileDeletion.apply_pending(profile, configuration, cache, temporary);
        }

        public string make_stage(string owner_profile) throws Error {
            string stage = Path.build_filename(root, "dinox-restore-stage-" + Uuid.string_random());
            ProfileRestore.prepare_stage(owner_profile, stage);
            string payload = Path.build_filename(stage, "dinox");
            if (DirUtils.create(payload, 0700) != 0)
                throw new IOError.FAILED("Cannot create restore payload fixture");
            FileUtils.set_contents(Path.build_filename(payload, "dino.db"), "replacement database");
            FileUtils.set_contents(Path.build_filename(payload, "omemo.key"), "replacement key");
            return stage;
        }

        public string make_backup_stage(string? owner) throws Error {
            string stage = Path.build_filename(temporary, "dinox-backup-stage-" + Uuid.string_random());
            if (DirUtils.create(stage, 0700) != 0)
                throw new IOError.FAILED("Cannot create backup fixture");
            FileUtils.set_contents(Path.build_filename(stage, "unencrypted-backup.db"), "owned test snapshot");
            if (owner != null) FileUtils.set_contents(Path.build_filename(stage, ".dinox-backup-owner"), owner);
            return stage;
        }
    }

    private static void remove_fixture(string path) throws Error {
        File file = File.new_for_path(path);
        FileInfo? entry = null;
        try {
            entry = file.query_info(FileAttribute.STANDARD_TYPE, FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
        } catch (IOError.NOT_FOUND e) { return; }
        if (entry.get_file_type() == FileType.DIRECTORY) {
            var children = file.enumerate_children(FileAttribute.STANDARD_NAME, FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
            FileInfo? child;
            while ((child = children.next_file()) != null)
                remove_fixture(Path.build_filename(path, child.get_name()));
            children.close();
        }
        file.delete();
    }

    private void with_fixture(FixtureTest test) {
        Fixture? fixture = null;
        try {
            fixture = new Fixture();
            test((!) fixture);
        } catch (Error e) {
            fail_if_reached(e.message);
        } finally {
            if (fixture != null) {
                try { remove_fixture(fixture.root); }
                catch (Error e) { fail_if_reached("Private deletion fixture cleanup: " + e.message); }
            }
        }
    }

    private static bool exists(string path) {
        return FileUtils.test(path, FileTest.EXISTS) || FileUtils.test(path, FileTest.IS_SYMLINK);
    }

    private static void contents_equal(string path, string expected) throws Error {
        string actual;
        FileUtils.get_contents(path, out actual);
        fail_if_not_eq_str(expected, actual);
    }

    private static bool make_link(string path, string target) throws Error {
#if WINDOWS
        try { File.new_for_path(path).make_symbolic_link(target); }
        catch (Error e) { GLib.Test.skip("Windows symlink creation unavailable: " + e.message); return false; }
#else
        File.new_for_path(path).make_symbolic_link(target);
#endif
        return true;
    }

    private void test_no_request() {
        with_fixture((fixture) => {
            fail_if(fixture.apply());
            foreach (string directory in new string[] {fixture.profile, fixture.configuration, fixture.cache, fixture.other})
                contents_equal(Path.build_filename(directory, "sentinel"), "keep until requested");
        });
    }

    private void test_schedule() {
        with_fixture((fixture) => {
            ProfileDeletion.schedule(fixture.profile, false);
            contents_equal(fixture.request, "1\nfactory\n");
            contents_equal(Path.build_filename(fixture.profile, "omemo.key"), "test key payload");
            bool rejected = false;
            try { ProfileDeletion.schedule(fixture.profile, true); }
            catch (IOError.EXISTS e) { rejected = true; }
            fail_if_not(rejected);
            contents_equal(fixture.request, "1\nfactory\n");
        });
    }

    private void test_profile_isolation() {
        foreach (bool panic in new bool[] {false, true}) {
            with_fixture((fixture) => {
                ProfileDeletion.schedule(fixture.profile, panic);
                fail_if_not(fixture.apply());
                fail_if(exists(fixture.profile));
                fail_if(exists(fixture.configuration));
                fail_if(exists(fixture.cache));
                fail_if(exists(fixture.request));
                contents_equal(Path.build_filename(fixture.other, "sentinel"), "keep until requested");
                contents_equal(Path.build_filename(fixture.temporary, "sentinel"), "keep until requested");
                fail_if(fixture.apply(), "successful deletion must be idempotent");
            });
        }
    }

    private void test_invalid_request() {
        with_fixture((fixture) => {
            FileUtils.set_contents(fixture.request, "unknown-operation\n");
            bool rejected = false;
            try { fixture.apply(); }
            catch (IOError.INVALID_DATA e) { rejected = true; }
            fail_if_not(rejected);
            contents_equal(Path.build_filename(fixture.profile, "omemo.key"), "test key payload");
            contents_equal(fixture.request, "unknown-operation\n");
        });
    }

    private void test_failed_retry() {
        with_fixture((fixture) => {
            string blocker = Path.build_filename(fixture.root, "not-a-directory");
            FileUtils.set_contents(blocker, "unrelated file must survive");
            ProfileDeletion.schedule(fixture.profile, false);
            // Begin with one root already removed, as after an interrupted wipe.
            // Enumerating a regular file injects a real error on both platforms.
            ProfileDeletion.delete_tree(File.new_for_path(fixture.profile));
            bool rejected = false;
            try {
                ProfileDeletion.apply_pending(fixture.profile,
                    fixture.configuration, fixture.cache, blocker);
            } catch (Error e) { rejected = true; }
            fail_if_not(rejected, "a real filesystem error must not report successful reset");
            contents_equal(fixture.request, "1\nfactory\n");
            contents_equal(blocker, "unrelated file must survive");
            fail_if(exists(fixture.profile));
            foreach (string directory in new string[] {fixture.configuration, fixture.cache, fixture.other})
                contents_equal(Path.build_filename(directory, "sentinel"), "keep until requested");
            // Retrying completes all remaining roots before removing intent.
            fail_if_not(fixture.apply());
            fail_if(exists(fixture.request));
            fail_if(exists(fixture.configuration));
            fail_if(exists(fixture.cache));
            fail_if(exists(fixture.profile));
            fail_if(fixture.apply(), "successful retry must be idempotent");
            contents_equal(blocker, "unrelated file must survive");
            contents_equal(Path.build_filename(fixture.other, "sentinel"), "keep until requested");
            contents_equal(Path.build_filename(fixture.temporary, "sentinel"), "keep until requested");
        });
    }

    private void test_artifacts() {
        with_fixture((fixture) => {
            string installed_stage = fixture.make_stage(fixture.profile);
            string token = Path.get_basename(installed_stage).substring("dinox-restore-stage-".length);
            ProfileRestore.schedule(fixture.profile, installed_stage);
            ProfileRestore.apply_pending(fixture.profile);
            string rollback = Path.build_filename(fixture.root, ".dinox-restore-rollback-" + token);
            fail_if_not(exists(rollback));
            string abandoned = fixture.make_stage(fixture.profile);
            string pending = fixture.make_stage(fixture.profile);
            ProfileRestore.schedule(fixture.profile, pending);
            string other_stage = fixture.make_stage(fixture.other);
            string owned_backup = fixture.make_backup_stage(fixture.profile);
            string other_backup = fixture.make_backup_stage(fixture.other);
            string unmarked_backup = fixture.make_backup_stage(null);

            ProfileDeletion.schedule(fixture.profile, true);
            fail_if_not(fixture.apply());
            foreach (string removed in new string[] {rollback, abandoned, pending, owned_backup, fixture.request})
                fail_if(exists(removed), "owned plaintext/identity artifact survived wipe: " + removed);
            fail_if(exists(Path.build_filename(fixture.root, ".dinox-restore-pending")));
            foreach (string retained in new string[] {other_stage, other_backup, unmarked_backup, fixture.other})
                fail_if_not(exists(retained), "another or unproven owner's data was removed: " + retained);
        });
    }

    private void test_password_request() {
        with_fixture((fixture) => {
            ProfileMaintenance.schedule_password_change(fixture.profile, "test-old-password", "test-new-password");
            ProfileMaintenance.schedule_password_change(fixture.other, "other-old-password", "other-new-password");
            string own_manifest = Path.build_filename(fixture.root, ".dinox-maintenance-pending");
            string other_manifest = Path.build_filename(fixture.root, ".other-profile-maintenance-pending");
            var request = new KeyFile();
            request.load_from_file(own_manifest, KeyFileFlags.NONE);
            string request_dir = Path.build_filename(fixture.root,
                ".dinox-maintenance-" + request.get_string("Maintenance", "token"));
            fail_if_not(exists(Path.build_filename(request_dir, "request.db")));
            ProfileDeletion.schedule(fixture.profile, true);
            fail_if_not(fixture.apply());
            fail_if(exists(own_manifest));
            fail_if(exists(request_dir));
            fail_if_not(exists(other_manifest));
            fail_if_not(ProfileMaintenance.has_pending(fixture.other));
            contents_equal(Path.build_filename(fixture.other, "sentinel"), "keep until requested");
        });
    }

    private void test_backup_cleanup() {
        with_fixture((fixture) => {
            string stage = fixture.make_backup_stage(fixture.profile);
            string second = fixture.make_backup_stage(fixture.profile);
            string other = fixture.make_backup_stage(fixture.other);
            ProfileDeletion.cleanup_backup_stage(fixture.profile, stage);
            ProfileDeletion.cleanup_backup_stage(fixture.profile, stage);
            fail_if(exists(stage));
            fail_if_not(exists(second));
            fail_if_not(exists(other));
            contents_equal(Path.build_filename(fixture.profile, "omemo.key"), "test key payload");
        });
    }

    private void test_backup_cleanup_rejection() {
        with_fixture((fixture) => {
            string other = fixture.make_backup_stage(fixture.other);
            string unmarked = fixture.make_backup_stage(null);
            foreach (string stage in new string[] {other, unmarked, fixture.profile}) {
                bool rejected = false;
                try { ProfileDeletion.cleanup_backup_stage(fixture.profile, stage); }
                catch (Error e) { rejected = true; }
                fail_if_not(rejected);
                fail_if_not(exists(stage));
            }
            string owned = fixture.make_backup_stage(fixture.profile);
            string alias = Path.build_filename(fixture.temporary, "dinox-backup-stage-" + Uuid.string_random());
            if (!make_link(alias, owned)) return;
            bool rejected = false;
            try { ProfileDeletion.cleanup_backup_stage(fixture.profile, alias); }
            catch (IOError.INVALID_DATA e) { rejected = true; }
            fail_if_not(rejected);
            fail_if_not(exists(owned));
            string marker = Path.build_filename(unmarked, ".dinox-backup-owner");
            if (!make_link(marker, Path.build_filename(owned, ".dinox-backup-owner"))) return;
            rejected = false;
            try { ProfileDeletion.cleanup_backup_stage(fixture.profile, unmarked); }
            catch (IOError.INVALID_DATA e) { rejected = true; }
            fail_if_not(rejected);
            contents_equal(Path.build_filename(owned, ".dinox-backup-owner"), fixture.profile);
        });
    }

    private void test_child_link() {
        with_fixture((fixture) => {
            string alias = Path.build_filename(fixture.profile, "external-directory");
            if (!make_link(alias, fixture.other)) return;
            ProfileDeletion.delete_tree(File.new_for_path(fixture.profile));
            fail_if(exists(fixture.profile));
            contents_equal(Path.build_filename(fixture.other, "sentinel"), "keep until requested");
        });
    }

    private void test_root_link() {
        with_fixture((fixture) => {
            string alias = Path.build_filename(fixture.root, "directory-alias");
            if (!make_link(alias, fixture.other)) return;
            bool rejected = false;
            try { ProfileDeletion.delete_contents(alias); }
            catch (Error e) { rejected = true; }
            fail_if_not(rejected, "NOFOLLOW on enumeration children alone does not protect a linked root");
            fail_if_not(exists(alias));
            contents_equal(Path.build_filename(fixture.other, "sentinel"), "keep until requested");
        });
    }

    private void test_request_link() {
        with_fixture((fixture) => {
            string target = Path.build_filename(fixture.other, "delete-request");
            FileUtils.set_contents(target, "1\npanic\n");
            if (!make_link(fixture.request, target)) return;
            bool rejected = false;
            try { fixture.apply(); }
            catch (IOError.INVALID_DATA e) { rejected = true; }
            fail_if_not(rejected);
            contents_equal(target, "1\npanic\n");
            contents_equal(Path.build_filename(fixture.profile, "omemo.key"), "test key payload");
        });
    }

#if !WINDOWS
    private void test_direct_backup_owner_retry() {
        with_fixture((fixture) => {
            string stage = fixture.make_backup_stage(fixture.profile);
            string payload_dir = Path.build_filename(stage, "payload");
            fail_if(DirUtils.create(payload_dir, 0700) != 0);
            string payload = Path.build_filename(payload_dir, "private.db");
            FileUtils.set_contents(payload, "private snapshot payload");
            string probe = Path.build_filename(payload_dir, "permission-probe");
            FileUtils.set_contents(probe, "permission probe");
            fail_if(FileUtils.chmod(payload_dir, 0500) != 0);
            try {
                bool enforced = false;
                try { File.new_for_path(probe).delete(); }
                catch (IOError.PERMISSION_DENIED e) { enforced = true; }
                if (!enforced) {
                    GLib.Test.skip("Current privileges bypass directory write permissions");
                    return;
                }
                bool rejected = false;
                try { ProfileDeletion.cleanup_backup_stage(fixture.profile, stage); }
                catch (Error e) { rejected = true; }
                fail_if_not(rejected);
                contents_equal(Path.build_filename(stage, ".dinox-backup-owner"), fixture.profile);
                contents_equal(payload, "private snapshot payload");
                fail_if(exists(fixture.request));
            } finally {
                FileUtils.chmod(payload_dir, 0700);
            }
            ProfileDeletion.cleanup_backup_stage(fixture.profile, stage);
            fail_if(exists(stage));
            contents_equal(Path.build_filename(fixture.profile, "omemo.key"), "test key payload");
        });
    }

    private void test_backup_owner_retry() {
        with_fixture((fixture) => {
            string stage = fixture.make_backup_stage(fixture.profile);
            string protected_dir = Path.build_filename(stage, "protected-payload");
            fail_if(DirUtils.create(protected_dir, 0700) != 0);
            string payload = Path.build_filename(protected_dir, "private.db");
            FileUtils.set_contents(payload, "private snapshot payload");
            string probe = Path.build_filename(protected_dir, "permission-probe");
            FileUtils.set_contents(probe, "permission probe");
            fail_if(FileUtils.chmod(protected_dir, 0500) != 0);
            try {
                bool enforced = false;
                try { File.new_for_path(probe).delete(); }
                catch (IOError.PERMISSION_DENIED e) { enforced = true; }
                if (!enforced) {
                    GLib.Test.skip("Current privileges bypass directory write permissions");
                    return;
                }
                ProfileDeletion.schedule(fixture.profile, true);
                bool rejected = false;
                try { fixture.apply(); }
                catch (Error e) { rejected = true; }
                fail_if_not(rejected);
                contents_equal(Path.build_filename(stage, ".dinox-backup-owner"), fixture.profile);
                contents_equal(payload, "private snapshot payload");
                contents_equal(fixture.request, "1\npanic\n");
                contents_equal(Path.build_filename(fixture.profile, "omemo.key"), "test key payload");
            } finally {
                FileUtils.chmod(protected_dir, 0700);
            }
            fail_if_not(fixture.apply());
            fail_if(exists(stage));
            fail_if(exists(fixture.request));
            fail_if(exists(fixture.profile));
        });
    }
#endif
}

}

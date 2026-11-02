using Dino.Security;

namespace Dino.Test {

class ProfileRestoreTest : Gee.TestCase {
    public ProfileRestoreTest() {
        base("ProfileRestore");
        add_test("schedule_preserves_live_profile_until_apply", test_schedule_then_apply);
        add_test("resume_before_first_rename", test_resume_before_first_rename);
        add_test("resume_after_old_profile_rename", test_resume_after_old_rename);
        add_test("resume_after_new_profile_rename", test_resume_after_new_rename);
        add_test("resume_after_installed_manifest", test_resume_installed);
        add_test("missing_stage_after_crash_restores_old_profile", test_restore_rollback);
        add_test("invalid_stage_never_changes_live_files", test_invalid_stage);
        add_test("manifest_cannot_escape_profile_parent", test_invalid_manifest);
        add_test("pending_restore_cannot_be_overwritten", test_pending_conflict);
        add_test("fresh_profile_and_other_target_basename", test_fresh_profile);
        add_test("extra_staging_entries_are_not_deleted", test_extra_stage_entries);
        add_test("wipe_removes_only_marked_artifacts_of_its_profile", test_cleanup_owned);
        add_test("maintenance_cleanup_only_removes_completed_token", test_cleanup_completed);
        add_test("discard_only_unpublished_owned_staging", test_discard_stage);
#if !WINDOWS
        add_test("failed_cleanup_retains_ownership_until_payload_is_gone", test_failed_cleanup);
        add_test("failed_second_rename_restores_original_profile", test_second_rename_failure);
        add_test("staged_symlink_is_rejected_without_following", test_stage_symlink);
        add_test("manifest_symlink_is_not_followed", test_manifest_symlink);
#endif
    }

    private class Fixture : Object {
        public string root;
        public string profile;
        public string token;
        public string stage;
        public string staged;
        public string manifest;
        public string rollback;

        public Fixture(bool existing = true, string basename = "dinox") throws Error {
            root = DirUtils.make_tmp("dinox-profile-restore-XXXXXX");
            profile = Path.build_filename(root, basename);
            token = Uuid.string_random();
            stage = Path.build_filename(root, "dinox-restore-stage-" + token);
            staged = Path.build_filename(stage, "dinox");
            manifest = Path.build_filename(root, "." + basename + "-restore-pending");
            rollback = Path.build_filename(root, "." + basename + "-restore-rollback-" + token);
            if (existing) {
                DirUtils.create(profile, 0700);
                FileUtils.set_contents(Path.build_filename(profile, "dino.db"), "old database");
                FileUtils.set_contents(Path.build_filename(profile, "dino.db-wal"), "old live WAL");
                FileUtils.set_contents(Path.build_filename(profile, "omemo.db"), "old identity and sessions");
                FileUtils.set_contents(Path.build_filename(profile, "omemo.key"), "old key");
            }
            DirUtils.create_with_parents(staged, 0700);
            FileUtils.set_contents(Path.build_filename(staged, "dino.db"), "restored database");
            FileUtils.set_contents(Path.build_filename(staged, "omemo.db"), "restored identity and sessions");
            FileUtils.set_contents(Path.build_filename(staged, "omemo.key"), "restored key");
        }

        public void set_phase(string phase) throws Error {
            var data = new KeyFile();
            data.load_from_file(manifest, KeyFileFlags.NONE);
            data.set_string("Restore", "phase", phase);
            FileUtils.set_contents(manifest, data.to_data());
            // Reconstruct the ownership marker persisted immediately before
            // the first rename when exercising process-crash states.
            var owner = new KeyFile();
            owner.set_string("Restore", "profile", Path.get_basename(profile));
            owner.set_string("Restore", "token", token);
            FileUtils.set_contents(Path.build_filename(profile, ".dinox-restore-rollback"), owner.to_data());
        }

        public void cleanup() {
            try { remove_fixture_tree(root); } catch (Error e) { warning("Restore test cleanup failed: %s", e.message); }
        }
    }

    private static void remove_fixture_tree(string path) throws Error {
        var file = File.new_for_path(path);
        var entry = file.query_info(FileAttribute.STANDARD_TYPE, FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
        if (entry.get_file_type() == FileType.DIRECTORY) {
            var children = file.enumerate_children(FileAttribute.STANDARD_NAME, FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
            FileInfo? child;
            while ((child = children.next_file()) != null)
                remove_fixture_tree(Path.build_filename(path, child.get_name()));
        }
        file.delete();
    }

    private void contents_equal(string path, string expected) throws Error {
        string contents;
        FileUtils.get_contents(path, out contents);
        fail_if_not_eq_str(expected, contents);
    }

    private void assert_old_profile(string profile) throws Error {
        contents_equal(Path.build_filename(profile, "dino.db"), "old database");
        contents_equal(Path.build_filename(profile, "dino.db-wal"), "old live WAL");
        contents_equal(Path.build_filename(profile, "omemo.db"), "old identity and sessions");
        contents_equal(Path.build_filename(profile, "omemo.key"), "old key");
    }

    private void assert_new_profile(Fixture fixture) throws Error {
        contents_equal(Path.build_filename(fixture.profile, "dino.db"), "restored database");
        contents_equal(Path.build_filename(fixture.profile, "omemo.db"), "restored identity and sessions");
        contents_equal(Path.build_filename(fixture.profile, "omemo.key"), "restored key");
        contents_equal(Path.build_filename(fixture.profile, ".restore_pending"), "1");
        fail_if(FileUtils.test(Path.build_filename(fixture.profile, "dino.db-wal"), FileTest.EXISTS),
            "The old WAL must stay with the old database, not the restored profile");
        fail_if(FileUtils.test(fixture.manifest, FileTest.EXISTS));
        fail_if(ProfileRestore.apply_pending(fixture.profile), "Completed restore must be idempotent");
    }

    private void test_schedule_then_apply() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture();
            ProfileRestore.schedule(fixture.profile, fixture.stage);
            assert_old_profile(fixture.profile);
            fail_if(FileUtils.test(Path.build_filename(fixture.profile, ".restore_pending"), FileTest.EXISTS));
            fail_if_not(ProfileRestore.apply_pending(fixture.profile));
            assert_new_profile(fixture);
            assert_old_profile(fixture.rollback);
        } catch (Error e) { fail_if_reached(e.message); }
        finally { if (fixture != null) fixture.cleanup(); }
    }

    private void test_resume_before_first_rename() { test_resume(0, false); }
    private void test_resume_after_old_rename() { test_resume(1, false); }
    private void test_resume_after_new_rename() { test_resume(2, false); }
    private void test_resume_installed() { test_resume(2, true); }

    private void test_resume(int renamed, bool installed) {
        Fixture? fixture = null;
        try {
            fixture = new Fixture();
            ProfileRestore.schedule(fixture.profile, fixture.stage);
            fixture.set_phase(installed ? "installed" : "moving");
            if (renamed >= 1) fail_if(FileUtils.rename(fixture.profile, fixture.rollback) != 0);
            if (renamed >= 2) fail_if(FileUtils.rename(fixture.staged, fixture.profile) != 0);
            fail_if_not(ProfileRestore.apply_pending(fixture.profile));
            assert_new_profile(fixture);
            assert_old_profile(fixture.rollback);
        } catch (Error e) { fail_if_reached(e.message); }
        finally { if (fixture != null) fixture.cleanup(); }
    }

    private void test_restore_rollback() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture();
            ProfileRestore.schedule(fixture.profile, fixture.stage);
            fixture.set_phase("moving");
            fail_if(FileUtils.rename(fixture.profile, fixture.rollback) != 0);
            FileUtils.remove(Path.build_filename(fixture.staged, "dino.db"));
            bool failed = false;
            try { ProfileRestore.apply_pending(fixture.profile); } catch (Error e) { failed = true; }
            fail_if_not(failed);
            assert_old_profile(fixture.profile);
            fail_if_not(FileUtils.test(fixture.manifest, FileTest.EXISTS));
            fail_if(FileUtils.test(fixture.rollback, FileTest.EXISTS));
        } catch (Error e) { fail_if_reached(e.message); }
        finally { if (fixture != null) fixture.cleanup(); }
    }

    private void test_invalid_stage() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture();
            FileUtils.remove(Path.build_filename(fixture.staged, "dino.db"));
            bool failed = false;
            try { ProfileRestore.schedule(fixture.profile, fixture.stage); } catch (Error e) { failed = true; }
            fail_if_not(failed);
            assert_old_profile(fixture.profile);
            fail_if(FileUtils.test(fixture.manifest, FileTest.EXISTS));
            failed = false;
            try { ProfileRestore.schedule(fixture.profile, fixture.profile); } catch (Error e) { failed = true; }
            fail_if_not(failed);
            assert_old_profile(fixture.profile);
        } catch (Error e) { fail_if_reached(e.message); }
        finally { if (fixture != null) fixture.cleanup(); }
    }

    private void test_invalid_manifest() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture();
            ProfileRestore.schedule(fixture.profile, fixture.stage);
            var data = new KeyFile();
            data.load_from_file(fixture.manifest, KeyFileFlags.NONE);
            data.set_string("Restore", "token", "../../outside");
            FileUtils.set_contents(fixture.manifest, data.to_data());
            bool failed = false;
            try { ProfileRestore.apply_pending(fixture.profile); } catch (Error e) { failed = true; }
            fail_if_not(failed);
            assert_old_profile(fixture.profile);
            contents_equal(Path.build_filename(fixture.staged, "dino.db"), "restored database");
        } catch (Error e) { fail_if_reached(e.message); }
        finally { if (fixture != null) fixture.cleanup(); }
    }

    private void test_pending_conflict() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture();
            ProfileRestore.schedule(fixture.profile, fixture.stage);
            string before;
            FileUtils.get_contents(fixture.manifest, out before);
            bool failed = false;
            try { ProfileRestore.schedule(fixture.profile, fixture.stage); } catch (Error e) { failed = true; }
            fail_if_not(failed);
            contents_equal(fixture.manifest, before);
            assert_old_profile(fixture.profile);
        } catch (Error e) { fail_if_reached(e.message); }
        finally { if (fixture != null) fixture.cleanup(); }
    }

    private void test_fresh_profile() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture(false, "Custom profile ü");
            ProfileRestore.schedule(fixture.profile, fixture.stage);
            fail_if(FileUtils.test(fixture.profile, FileTest.EXISTS));
            fail_if_not(ProfileRestore.apply_pending(fixture.profile));
            assert_new_profile(fixture);
            fail_if(FileUtils.test(fixture.rollback, FileTest.EXISTS));
        } catch (Error e) { fail_if_reached(e.message); }
        finally { if (fixture != null) fixture.cleanup(); }
    }

    private void test_extra_stage_entries() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture();
            string retained = Path.build_filename(fixture.stage, "keep.txt");
            FileUtils.set_contents(retained, "outside staged profile");
            ProfileRestore.schedule(fixture.profile, fixture.stage);
            fail_if_not(ProfileRestore.apply_pending(fixture.profile));
            contents_equal(retained, "outside staged profile");
            fail_if_not(FileUtils.test(Path.build_filename(fixture.stage, ".dinox-restore-stage"), FileTest.EXISTS));
            assert_old_profile(fixture.rollback);
        } catch (Error e) { fail_if_reached(e.message); }
        finally { if (fixture != null) fixture.cleanup(); }
    }

    private void test_cleanup_owned() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture();
            ProfileRestore.schedule(fixture.profile, fixture.stage);
            fail_if_not(ProfileRestore.apply_pending(fixture.profile));
            string own_stage = Path.build_filename(fixture.root, "dinox-restore-stage-" + Uuid.string_random());
            ProfileRestore.prepare_stage(fixture.profile, own_stage);
            FileUtils.set_contents(Path.build_filename(own_stage, "unfinished"), "own private data");
            string other_profile = Path.build_filename(fixture.root, "another-profile");
            string other_stage = Path.build_filename(fixture.root, "dinox-restore-stage-" + Uuid.string_random());
            ProfileRestore.prepare_stage(other_profile, other_stage);
            string unmarked = Path.build_filename(fixture.root, ".dinox-restore-rollback-" + Uuid.string_random());
            DirUtils.create(unmarked, 0700);
            FileUtils.set_contents(Path.build_filename(unmarked, "proof"), "not owned");
            ProfileRestore.cleanup_owned_artifacts(fixture.profile);
            fail_if(FileUtils.test(fixture.rollback, FileTest.EXISTS));
            fail_if(FileUtils.test(own_stage, FileTest.EXISTS));
            fail_if_not(FileUtils.test(other_stage, FileTest.IS_DIR));
            contents_equal(Path.build_filename(unmarked, "proof"), "not owned");
            contents_equal(Path.build_filename(fixture.profile, "omemo.key"), "restored key");
            ProfileRestore.cleanup_owned_artifacts(fixture.profile);
        } catch (Error e) { fail_if_reached(e.message); }
        finally { if (fixture != null) fixture.cleanup(); }
    }

    private void test_cleanup_completed() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture();
            ProfileRestore.schedule(fixture.profile, fixture.stage);
            fail_if_not(ProfileRestore.apply_pending(fixture.profile));
            bool failed = false;
            try { ProfileRestore.cleanup_completed(fixture.profile, Uuid.string_random()); }
            catch (Error e) { failed = true; }
            fail_if_not(failed);
            assert_old_profile(fixture.rollback);
            ProfileRestore.cleanup_completed(fixture.profile, fixture.token);
            fail_if(FileUtils.test(fixture.rollback, FileTest.EXISTS));
            contents_equal(Path.build_filename(fixture.profile, "omemo.key"), "restored key");
            ProfileRestore.cleanup_completed(fixture.profile, fixture.token);
        } catch (Error e) { fail_if_reached(e.message); }
        finally { if (fixture != null) fixture.cleanup(); }
    }

    private void test_discard_stage() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture();
            string stage = Path.build_filename(fixture.root, "dinox-restore-stage-" + Uuid.string_random());
            ProfileRestore.prepare_stage(fixture.profile, stage);
            FileUtils.set_contents(Path.build_filename(stage, "unfinished"), "private contents");
            ProfileRestore.discard_stage(fixture.profile, stage);
            fail_if(FileUtils.test(stage, FileTest.EXISTS));
            ProfileRestore.discard_stage(fixture.profile, stage);
            ProfileRestore.schedule(fixture.profile, fixture.stage);
            bool failed = false;
            try { ProfileRestore.discard_stage(fixture.profile, fixture.stage); }
            catch (Error e) { failed = true; }
            fail_if_not(failed);
            assert_old_profile(fixture.profile);
            fail_if_not(ProfileRestore.has_pending(fixture.profile));
            ProfileRestore.cleanup_owned_artifacts(fixture.profile);
            fail_if(ProfileRestore.has_pending(fixture.profile));
            fail_if(FileUtils.test(fixture.stage, FileTest.EXISTS));
            assert_old_profile(fixture.profile);
        } catch (Error e) { fail_if_reached(e.message); }
        finally { if (fixture != null) fixture.cleanup(); }
    }

#if !WINDOWS
    private void test_failed_cleanup() {
        // Completed maintenance, explicit wipe, and abandoned staging all
        // need ownership to survive a partially successful recursive delete.
        for (int operation = 0; operation < 3; operation++) {
            Fixture? fixture = null;
            string? protected_dir = null;
            try {
                fixture = new Fixture();
                string artifact;
                string marker;
                if (operation == 2) {
                    artifact = Path.build_filename(fixture.root, "dinox-restore-stage-" + Uuid.string_random());
                    ProfileRestore.prepare_stage(fixture.profile, artifact);
                    marker = ".dinox-restore-stage";
                } else {
                    ProfileRestore.schedule(fixture.profile, fixture.stage);
                    fail_if_not(ProfileRestore.apply_pending(fixture.profile));
                    artifact = fixture.rollback;
                    marker = ".dinox-restore-rollback";
                }
                protected_dir = Path.build_filename(artifact, "blocked");
                fail_if(DirUtils.create(protected_dir, 0700) != 0);
                string secret = Path.build_filename(protected_dir, "old.key");
                FileUtils.set_contents(secret, "old private key");
                fail_if(FileUtils.chmod(protected_dir, 0500) != 0);
                var access = File.new_for_path(protected_dir).query_info(
                    FileAttribute.ACCESS_CAN_WRITE, FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
                if (access.get_attribute_boolean(FileAttribute.ACCESS_CAN_WRITE)) {
                    GLib.Test.skip("Permission-failure fixture requires an unprivileged process");
                    return;
                }
                bool failed = false;
                try {
                    if (operation == 0) ProfileRestore.cleanup_completed(fixture.profile, fixture.token);
                    else if (operation == 1) ProfileRestore.cleanup_owned_artifacts(fixture.profile);
                    else ProfileRestore.discard_stage(fixture.profile, artifact);
                } catch (Error e) { failed = true; }
                fail_if_not(failed, "A protected remaining payload must fail cleanup");
                contents_equal(secret, "old private key");
                fail_if_not(FileUtils.test(Path.build_filename(artifact, marker), FileTest.IS_REGULAR),
                    "Ownership must remain while old private keys could not be deleted");
                fail_if(FileUtils.chmod(protected_dir, 0700) != 0);
                if (operation == 0) ProfileRestore.cleanup_completed(fixture.profile, fixture.token);
                else if (operation == 1) ProfileRestore.cleanup_owned_artifacts(fixture.profile);
                else ProfileRestore.discard_stage(fixture.profile, artifact);
                fail_if(FileUtils.test(artifact, FileTest.EXISTS), "Cleanup must be safely retryable");
            } catch (Error e) { fail_if_reached(e.message); }
            finally {
                if (protected_dir != null) FileUtils.chmod(protected_dir, 0700);
                if (fixture != null) fixture.cleanup();
            }
        }
    }

    private void test_second_rename_failure() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture();
            ProfileRestore.schedule(fixture.profile, fixture.stage);
            // Reading/validating still works, but rename out of this source
            // directory fails. The parent remains writable for the rollback.
            fail_if(FileUtils.chmod(fixture.stage, 0500) != 0);
            var access = File.new_for_path(fixture.stage).query_info(
                FileAttribute.ACCESS_CAN_WRITE, FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
            if (access.get_attribute_boolean(FileAttribute.ACCESS_CAN_WRITE)) {
                GLib.Test.skip("Permission-failure fixture requires an unprivileged process");
                return;
            }
            bool failed = false;
            try { ProfileRestore.apply_pending(fixture.profile); } catch (Error e) { failed = true; }
            fail_if_not(failed, "Read-only stage must fail the second rename");
            assert_old_profile(fixture.profile);
            fail_if(FileUtils.test(fixture.rollback, FileTest.EXISTS));
            fail_if_not(ProfileRestore.has_pending(fixture.profile));
            fail_if(FileUtils.chmod(fixture.stage, 0700) != 0);
            fail_if_not(ProfileRestore.apply_pending(fixture.profile), "Repairing the stage permits a safe retry");
            assert_new_profile(fixture);
            assert_old_profile(fixture.rollback);
        } catch (Error e) { fail_if_reached(e.message); }
        finally {
            if (fixture != null) {
                FileUtils.chmod(fixture.stage, 0700);
                fixture.cleanup();
            }
        }
    }

    private void test_stage_symlink() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture();
            string outside = Path.build_filename(fixture.root, "outside.txt");
            FileUtils.set_contents(outside, "must not change");
            fail_if(FileUtils.symlink(outside, Path.build_filename(fixture.staged, "linked")) != 0);
            bool failed = false;
            try { ProfileRestore.schedule(fixture.profile, fixture.stage); } catch (Error e) { failed = true; }
            fail_if_not(failed);
            contents_equal(outside, "must not change");
            assert_old_profile(fixture.profile);
        } catch (Error e) { fail_if_reached(e.message); }
        finally { if (fixture != null) fixture.cleanup(); }
    }

    private void test_manifest_symlink() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture();
            string outside = Path.build_filename(fixture.root, "outside.txt");
            FileUtils.set_contents(outside, "must not change");
            fail_if(FileUtils.symlink(outside, fixture.manifest) != 0);
            bool failed = false;
            try { ProfileRestore.apply_pending(fixture.profile); } catch (Error e) { failed = true; }
            fail_if_not(failed);
            contents_equal(outside, "must not change");
            assert_old_profile(fixture.profile);
        } catch (Error e) { fail_if_reached(e.message); }
        finally { if (fixture != null) fixture.cleanup(); }
    }
#endif
}

}

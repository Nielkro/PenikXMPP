namespace Dino.Test {

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
    TestSuite.get_root().add_suite(new WeakMapTest().get_suite());
    TestSuite.get_root().add_suite(new JidTest().get_suite());
    TestSuite.get_root().add_suite(new FileManagerTest().get_suite());
    TestSuite.get_root().add_suite(new FileSendTargetScopeTest().get_suite());
    TestSuite.get_root().add_suite(new StickersTest().get_suite());
    TestSuite.get_root().add_suite(new SecurityTest().get_suite());
    TestSuite.get_root().add_suite(new KeyManagerRecoveryTest().get_suite());
    TestSuite.get_root().add_suite(new ProfileRestoreTest().get_suite());
    TestSuite.get_root().add_suite(new ProfileMaintenanceTest().get_suite());
    TestSuite.get_root().add_suite(new ProfileDeletionTest().get_suite());
    TestSuite.get_root().add_suite(new ProfileDataSafetyTest().get_suite());
    TestSuite.get_root().add_suite(new MessageSnapshotTest().get_suite());
    TestSuite.get_root().add_suite(new MessageDiagnosticsPersistenceTest().get_suite());
    TestSuite.get_root().add_suite(new HistoryDiagnosticsTest().get_suite());
    TestSuite.get_root().add_suite(new LocaleSearchPathTest().get_suite());
    // Security Audit Tests (spec-based, expected to FAIL = bugs found)
    TestSuite.get_root().add_suite(new Dino.SecurityAudit.KeyDerivationAudit().get_suite());
    TestSuite.get_root().add_suite(new Dino.SecurityAudit.KeyManagerAudit().get_suite());
    TestSuite.get_root().add_suite(new Dino.SecurityAudit.TokenStorageAudit().get_suite());
    TestSuite.get_root().add_suite(new Dino.SecurityAudit.JSONInjectionAudit().get_suite());
    // Tier 4 Security Audit Tests
    TestSuite.get_root().add_suite(new Dino.Test.FileTransferAudit().get_suite());
    TestSuite.get_root().add_suite(new Dino.Test.SrtpAudit().get_suite());
    // Phase 10: Test Suite Expansion
    TestSuite.get_root().add_suite(new Dino.Test.EntityAudit().get_suite());
    TestSuite.get_root().add_suite(new Dino.Test.PresenceAudit().get_suite());
    TestSuite.get_root().add_suite(new Dino.Test.AvatarAudit().get_suite());
    TestSuite.get_root().add_suite(new Dino.Test.AccountRemovalAudit().get_suite());
    TestSuite.get_root().add_suite(new Dino.Test.ConnectionManagerAudit().get_suite());
    TestSuite.get_root().add_suite(new Dino.Test.RosterManagerTest().get_suite());
    TestSuite.get_root().add_suite(new Dino.Test.ConversationSettingsTest().get_suite());
    TestSuite.get_root().add_suite(new Dino.Test.FeedsTest().get_suite());
    TestSuite.get_root().add_suite(new Dino.Test.DisplayedStateAudit().get_suite());
    TestSuite.get_root().add_suite(new Dino.Test.MucManagerAudit().get_suite());
    TestSuite.get_root().add_suite(new Dino.Test.MucVoiceRequestManagerAudit().get_suite());
    TestSuite.get_root().add_suite(new Dino.Test.MucOccupantReducerAudit().get_suite());
    TestSuite.get_root().add_suite(new Dino.Test.MucOccupantWorkerAudit().get_suite());
    TestSuite.get_root().add_suite(new Dino.Test.CallStateAudit().get_suite());
    TestSuite.get_root().add_suite(new Dino.Test.CallInviteIngressAudit().get_suite());
    TestSuite.get_root().add_suite(new Dino.Test.JmiLifecycleAudit().get_suite());
    TestSuite.get_root().add_suite(new Dino.Test.InvitesTest().get_suite());
    TestSuite.get_root().add_suite(new Dino.Test.ServerAdministrationTest().get_suite());
    TestSuite.get_root().add_suite(new Dino.Test.UserSearchTest().get_suite());
    TestSuite.get_root().add_suite(new Dino.Test.PasswordChangeTest().get_suite());
    TestSuite.get_root().add_suite(new Dino.Test.RegistrationFormTest().get_suite());
    TestSuite.get_root().add_suite(new Dino.Test.OutgoingEncryptionTest().get_suite());
    TestSuite.get_root().add_suite(new Dino.Test.ReplyIntegrityTest().get_suite());
    TestSuite.get_root().add_suite(new Dino.Test.MessageCorrectionTest().get_suite());
    TestSuite.get_root().add_suite(new Dino.Test.ArchiveRetractionTest().get_suite());
    TestSuite.get_root().add_suite(new Dino.Test.EmojiFallbackTest().get_suite());
    TestSuite.get_root().add_suite(new Dino.Test.MessageMentionsTest().get_suite());
    TestSuite.get_root().add_suite(new Dino.Test.RemoteXep0490SmokeTest().get_suite());
    TestSuite.get_root().add_suite(new Dino.Test.RemotePrivateMucSmokeTest().get_suite());
    TestSuite.get_root().add_suite(new Dino.Test.RemoteJingleS5bSmokeTest().get_suite());
    return GLib.Test.run();
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

bool fail_if_not(bool exp, string? reason = null) {
    return fail_if(!exp, reason);
}

bool fail_if_not_eq_str(string? left, string? right, string? reason = null) {
    bool nullcheck = (left == null) != (right == null);
    string l = left ?? "(null)";
    string r = right ?? "(null)";
    return fail_if(nullcheck || l != r, @"$(reason != null ? reason + ": " : "")'$l' != '$r'");
}


// Migration fixtures start from a current database and reconstruct selected
// old tables. Account columns must match that historical schema too, or the
// real upgrade correctly rejects duplicate v59 SASL columns. No DROP COLUMN
// dependency, so the same fixtures work with older supported SQLCipher builds.
internal void rebuild_account_fixture_at_version(Database db, long version) throws Error {
    assert(version >= 38 && version < 59);
    remove_archive_retraction_fixture_column(db);
    db.exec("ALTER TABLE account RENAME TO account_post59_fixture");
    db.account.create_table_at_version(version);
    db.exec("""
INSERT INTO account (
    id, bare_jid, resourcepart, password, alias, enabled, roster_version,
    mam_earliest_synced, custom_host, custom_port, proxy_type, proxy_host,
    proxy_port, proxy_user, proxy_pass, require_channel_binding)
SELECT id, bare_jid, resourcepart, password, alias, enabled, roster_version,
    mam_earliest_synced, custom_host, custom_port, proxy_type, proxy_host,
    proxy_port, proxy_user, proxy_pass, require_channel_binding
FROM account_post59_fixture;
DROP TABLE account_post59_fixture;
""");
}

// Historical fixtures must not retain the v60 column before upgrading. Preserve
// their existing columns, defaults and keys without requiring DROP COLUMN.
internal void remove_archive_retraction_fixture_column(Database db) throws Error {
    var definitions = new Gee.ArrayList<string>();
    var names = new Gee.ArrayList<string>();
    bool found = false;
    var columns_query = db.query_sql("PRAGMA table_info(message)");
    Qlite.Row? row;
    while ((row = columns_query.get_next()) != null) {
        string name = row.get_text("name");
        if (name == "archive_retracted") { found = true; continue; }
        string quoted = "\"" + name.replace("\"", "\"\"") + "\"";
        names.add(quoted);
        string definition = quoted + " " + row.get_text("type");
        if (row.get_integer("pk") != 0) definition += " PRIMARY KEY";
        if (row.get_integer("notnull") != 0) definition += " NOT NULL";
        string? value = row.get_text("dflt_value");
        if (value != null) definition += " DEFAULT " + value;
        definitions.add(definition);
    }
    if (!found) return;
    string columns = string.joinv(",", names.to_array());
    db.exec("CREATE TABLE message_pre60_fixture (" + string.joinv(",", definitions.to_array()) + ")");
    db.exec("INSERT INTO message_pre60_fixture (" + columns + ") SELECT " + columns + " FROM message");
    db.exec("DROP TABLE message; ALTER TABLE message_pre60_fixture RENAME TO message");
}

}

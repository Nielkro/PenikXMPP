using Dino.Entities;
using Dino.Plugins.OpenPgp;
using Gee;
using Xmpp;

namespace OpenPgp.KeyManagementRuntime {

private string test_root;
private string key_fingerprint;
private string secret_file;
private string public_file;
private const string KEY_UID = "Imported Legacy <legacy@outside.test>";
private const string XMPP_KEY = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
private const string LEGACY_KEY = "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB";

private string run_gpg(string home, string[] options) throws Error {
    var args = new ArrayList<string>();
    args.add(GPGHelper.get_binary_path());
    args.add("--homedir");
    args.add(home);
    args.add("--batch");
    args.add("--yes");
    args.add("--pinentry-mode");
    args.add("loopback");
    args.add("--passphrase-fd");
    args.add("0");
    foreach (string option in options) args.add(option);
    string[] argv = new string[args.size];
    for (int i = 0; i < args.size; i++) argv[i] = args[i];
    var process = Dino.Plugins.OpenPgp.new_subprocess(argv,
        SubprocessFlags.STDIN_PIPE | SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
    string output;
    string errors;
    process.communicate_utf8("\n", null, out output, out errors);
    if (!process.get_successful()) throw new IOError.FAILED("Isolated GPG fixture failed: " + errors);
    return output;
}

private void prepare_fixture_key() throws Error {
    string producer = Path.build_filename(test_root, "producer");
    DirUtils.create_with_parents(producer, 0700);
    run_gpg(producer, { "--quick-generate-key", KEY_UID, "ed25519", "sign", "1d" });
    string listing = run_gpg(producer, { "--with-colons", "--list-secret-keys" });
    foreach (string line in listing.split("\n")) {
        string[] parts = line.split(":");
        if (parts.length > 9 && parts[0] == "fpr") {
            key_fingerprint = parts[9];
            break;
        }
    }
    if (key_fingerprint == null || key_fingerprint.length != 40)
        throw new IOError.FAILED("Fixture key has no full primary fingerprint");
    run_gpg(producer, { "--quick-add-key", key_fingerprint, "cv25519", "encr", "1d" });
    secret_file = Path.build_filename(test_root, "private-key.pgp");
    public_file = Path.build_filename(test_root, "public-key.pgp");
    run_gpg(producer, { "--output", secret_file, "--export-secret-keys", key_fingerprint });
    run_gpg(producer, { "--output", public_file, "--export", key_fingerprint });
}

private async void pause() {
    SourceFunc resume = pause.callback;
    Timeout.add(1, (owned) resume);
    yield;
}

private async void settle_ui() {
    SourceFunc resume = settle_ui.callback;
    Timeout.add(50, (owned) resume);
    yield;
}

private async void present_and_settle(KeyManagementDialog dialog) {
    dialog.present();
    yield settle_ui();
}

private void run_case(int scenario) {
    bool finished = false;
    var loop = new MainLoop();
    run_case_async.begin(scenario, (_, result) => {
        try { run_case_async.end(result); }
        catch (Error error) {
            GLib.Test.message("Key management fixture failed: %s", error.message);
            GLib.Test.fail();
        }
        finished = true;
        loop.quit();
    });
    if (!finished) loop.run();
}

private async void run_case_async(int scenario) throws Error {
    var core_db = new Dino.Database(":memory:", "isolated-key-management-ui");
    var db = new Dino.Plugins.OpenPgp.Database(":memory:", null);
    var first = new Account(new Jid("first@example.test"), "secret");
    var second = new Account(new Jid("second@example.test"), "secret");
    first.persist(core_db);
    second.persist(core_db);
    // Match the real application's Adw.Window dialog host. A bare Gtk.Window
    // makes Adw.Dialog fall back to an independent transient GtkWindow.
    var parent = new Adw.Window() { default_width = 540, default_height = 700 };
    parent.content = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
    parent.present();
    yield settle_ui();
    KeyManagementDialog? first_dialog = null;
    KeyManagementDialog? second_dialog = null;
    try {
        db.set_account_xmpp_key(first, XMPP_KEY);
        var info = new GpgKeyInfo(key_fingerprint, KEY_UID, 0, false, false, true, true,
            first.bare_jid.to_string());
        first_dialog = new KeyManagementDialog(parent, db, null, first);
        switch (scenario) {
        case 0:
            db.bind_private_key_to_account(first, key_fingerprint);
            yield present_and_settle((!) first_dialog);
            assert_true(((!) first_dialog).should_show_key_for_current_account(info));
            ((!) first_dialog).close();
            yield settle_ui();
            second_dialog = new KeyManagementDialog(parent, db, null, second);
            yield present_and_settle((!) second_dialog);
            assert_false(((!) second_dialog).should_show_key_for_current_account(info));
            assert_cmpstr(db.get_account_key_mode(first), CompareOperator.EQ,
                Dino.Plugins.OpenPgp.Database.ACCOUNT_KEY_MODE_XMPP);
            assert_cmpstr(db.get_account_xmpp_key(first), CompareOperator.EQ, XMPP_KEY);
            assert_null(db.get_account_legacy_key(first));
            assert_null(db.get_contact_key(first, first.bare_jid));
            break;
        case 1:
            yield present_and_settle((!) first_dialog);
            yield ((!) first_dialog).import_key_from_file(secret_file);
            assert_true(((!) first_dialog).is_open);
            assert_true(((!) first_dialog).should_show_key_for_current_account(info));
            assert_true(db.get_account_private_key_bindings(first).contains(key_fingerprint));
            assert_cmpuint((uint) db.get_account_private_key_bindings(second).size, CompareOperator.EQ, 0);
            assert_cmpstr(db.get_account_key_mode(first), CompareOperator.EQ,
                Dino.Plugins.OpenPgp.Database.ACCOUNT_KEY_MODE_XMPP);
            assert_cmpstr(db.get_account_xmpp_key(first), CompareOperator.EQ, XMPP_KEY);
            assert_null(db.get_account_legacy_key(first));
            assert_null(db.get_contact_key(first, first.bare_jid));
            assert_true(find_exact_title(parent, KEY_UID));
            assert_false(find_exact_title(parent, Markup.escape_text(KEY_UID)));
            dismiss_result(parent);
            yield settle_ui();
            Adw.ActionRow? select_legacy = find_action(parent, "Use for legacy XEP-0027/keyserver");
            assert_nonnull(select_legacy);
            ((!) select_legacy).activate();
            assert_cmpstr(db.get_account_key_mode(first), CompareOperator.EQ,
                Dino.Plugins.OpenPgp.Database.ACCOUNT_KEY_MODE_LEGACY);
            assert_cmpstr(db.get_account_legacy_key(first), CompareOperator.EQ, key_fingerprint);
            assert_cmpstr(db.get_account_xmpp_key(first), CompareOperator.EQ, XMPP_KEY);
            assert_null(db.get_account_key(second));
            break;
        case 2:
            // Seed the shared keyring independently of test execution order.
            // Importing only its public packet must not assign that private key.
            run_gpg(Path.build_filename(test_root, "consumer"), { "--import", secret_file });
            first_dialog = new KeyManagementDialog(parent, db, null, second);
            yield present_and_settle((!) first_dialog);
            yield ((!) first_dialog).import_key_from_file(public_file);
            assert_cmpuint((uint) db.get_account_private_key_bindings(second).size, CompareOperator.EQ, 0);
            assert_false(((!) first_dialog).should_show_key_for_current_account(info));
            assert_null(db.get_account_key(second));
            assert_null(db.get_contact_key(second, second.bare_jid));
            break;
        case 3:
            db.set_account_legacy_key(first, LEGACY_KEY);
            db.set_account_xmpp_key(first, XMPP_KEY);
            db.set_account_legacy_key(second, XMPP_KEY);
            var interactor = new Dino.StreamInteractor.for_tests(core_db);
            Dino.PresenceManager.start(interactor, core_db);
            var first_stream = new ScopeStream(first.bare_jid);
            var second_stream = new ScopeStream(second.bare_jid);
            interactor.connection_manager.set_connected_stream_for_tests(first, first_stream);
            interactor.connection_manager.set_connected_stream_for_tests(second, second_stream);
            var manager = new Xep0373KeyManager(interactor, db) { auto_publish_own_key = false };
            var legacy_module = new Dino.Plugins.OpenPgp.Module(db, first);
            first_dialog = new KeyManagementDialog(parent, db, manager, first, legacy_module, interactor);
            yield present_and_settle((!) first_dialog);
            bool disabled = yield ((!) first_dialog).disable_xmpp_account_key(XMPP_KEY);
            assert_true(disabled);
            assert_cmpstr(db.get_account_key_mode(first), CompareOperator.EQ,
                Dino.Plugins.OpenPgp.Database.ACCOUNT_KEY_MODE_LEGACY);
            assert_cmpstr(db.get_account_legacy_key(first), CompareOperator.EQ, LEGACY_KEY);
            assert_null(db.get_account_xmpp_key(first));
            assert_cmpstr(legacy_module.get_pending_private_key_id(), CompareOperator.EQ, LEGACY_KEY);
            // Presence sends run asynchronously after the stored mode changed.
            for (int tries = 0; first_stream.presence_count == 0 && tries < 100; tries++) yield pause();
            assert_cmpuint(first_stream.presence_count, CompareOperator.GT, 0);
            assert_cmpuint(second_stream.presence_count, CompareOperator.EQ, 0);
            assert_cmpstr(db.get_account_legacy_key(second), CompareOperator.EQ, XMPP_KEY);
            break;
        case 4:
            string oversized = Path.build_filename(test_root, "oversized-key.asc");
            var output = File.new_for_path(oversized).create(FileCreateFlags.PRIVATE);
            output.seek(16 * 1024 * 1024, SeekType.SET);
            output.write(new uint8[1]);
            output.close();
            yield present_and_settle((!) first_dialog);
            yield ((!) first_dialog).import_key_from_file(oversized);
            assert_true(((!) first_dialog).is_open);
            assert_cmpuint((uint) db.get_account_private_key_bindings(first).size, CompareOperator.EQ, 0);
            assert_cmpuint((uint) db.get_account_private_key_bindings(second).size, CompareOperator.EQ, 0);
            assert_cmpstr(db.get_account_xmpp_key(first), CompareOperator.EQ, XMPP_KEY);
            assert_null(db.get_account_legacy_key(first));
            assert_true(find_exact_label(parent,
                "The key file is too large. Choose an OpenPGP key file up to 16 MiB."));
            File.new_for_path(oversized).delete();
            break;
        case 5:
            db.set_account_legacy_key(second, key_fingerprint);
            db.bind_private_key_to_account(second, key_fingerprint);
            second.remove();
            // The OpenPGP DB is separate: account removal does not erase its
            // historical rows. They must not block a surviving account forever.
            assert_true(db.key_has_other_account_users(first, key_fingerprint));
            assert_false(db.key_has_other_account_users(first, key_fingerprint,
                existing_account_ids(core_db)));
            assert_cmpstr(db.get_account_xmpp_key(first), CompareOperator.EQ, XMPP_KEY);
            break;
        case 6:
            db.set_account_legacy_key(second, key_fingerprint);
            db.bind_private_key_to_account(second, key_fingerprint);
            second.enabled = false;
            var ids = existing_account_ids(core_db);
            assert_true(ids.contains(second.id));
            assert_true(db.key_has_other_account_users(first, key_fingerprint, ids));
            db.remove_account_legacy_key(second);
            assert_true(db.key_has_other_account_users(first, key_fingerprint, ids));
            db.unbind_private_key_from_account(second, key_fingerprint);
            assert_false(db.key_has_other_account_users(first, key_fingerprint, ids));
            break;
        }
    } finally {
        dismiss_result(parent);
        yield settle_ui();
        if (first_dialog != null) ((!) first_dialog).close();
        yield settle_ui();
        if (second_dialog != null) ((!) second_dialog).close();
        yield settle_ui();
        parent.destroy();
        yield pause();
        db.close();
        core_db.close();
    }
}

private void dismiss_result(Gtk.Widget widget) {
    if (widget is Gtk.Button && ((Gtk.Button) widget).label == "OK") {
        ((Gtk.Button) widget).clicked();
        return;
    }
    for (Gtk.Widget? child = widget.get_first_child(); child != null; child = ((!) child).get_next_sibling())
        dismiss_result((!) child);
}

private Gee.Set<int> existing_account_ids(Dino.Database db) {
    var ids = new HashSet<int>();
    foreach (Account account in db.get_accounts()) if (account.id > 0) ids.add(account.id);
    return ids;
}

private bool find_exact_title(Gtk.Widget widget, string title) {
    if (widget is Adw.PreferencesRow && ((Adw.PreferencesRow) widget).title == title) return true;
    for (Gtk.Widget? child = widget.get_first_child(); child != null; child = ((!) child).get_next_sibling())
        if (find_exact_title((!) child, title)) return true;
    return false;
}

private bool find_exact_label(Gtk.Widget widget, string text) {
    if (widget is Gtk.Label && ((Gtk.Label) widget).label == text) return true;
    for (Gtk.Widget? child = widget.get_first_child(); child != null; child = ((!) child).get_next_sibling())
        if (find_exact_label((!) child, text)) return true;
    return false;
}

private Adw.ActionRow? find_action(Gtk.Widget widget, string title) {
    if (widget is Adw.ActionRow && ((Adw.ActionRow) widget).title == title) return (Adw.ActionRow) widget;
    for (Gtk.Widget? child = widget.get_first_child(); child != null; child = ((!) child).get_next_sibling()) {
        Adw.ActionRow? result = find_action((!) child, title);
        if (result != null) return result;
    }
    return null;
}

private class ScopeStream : XmppStream {
    public uint presence_count = 0;

    public ScopeStream(Jid owner) {
        base(owner.domain_jid);
        var iq = new Iq.Module();
        add_module(iq);
        iq.attach(this);
        add_module(new Xmpp.Presence.Module());
        add_module(new Xmpp.Xep.Pubsub.Module());
        add_module(new Xmpp.Xep.OpenPgp.Module());
        var bind = new Bind.Flag() { my_jid = owner, finished = true };
        add_flag(bind);
    }

    public override async void connect() throws IOError { }
    public override async void disconnect() throws IOError { }
    public override async void setup() throws IOError { }
    public override async StanzaNode read() throws IOError {
        throw new IOError.NOT_CONNECTED("Isolated UI stream has no reader");
    }

    public override async void write_async(StanzaNode request, int io_priority = Priority.DEFAULT,
            Cancellable? cancellable = null) throws IOError {
        if (cancellable != null) cancellable.set_error_if_cancelled();
        if (request.name == "presence") { presence_count++; return; }
        if (request.name != "iq") return;
        var response = new StanzaNode.build("iq").put_attribute("type", "result")
            .put_attribute("id", request.get_attribute("id") ?? "");
        string? to = request.get_attribute("to");
        if (to != null) response.put_attribute("from", (!) to);
        StanzaNode? pubsub = request.get_subnode("pubsub", Xmpp.Xep.Pubsub.NS_URI);
        StanzaNode? items = pubsub != null ? ((!) pubsub).get_subnode("items", Xmpp.Xep.Pubsub.NS_URI) : null;
        if (items != null) {
            response.put_node(new StanzaNode.build("pubsub", Xmpp.Xep.Pubsub.NS_URI).add_self_xmlns()
                .put_node(new StanzaNode.build("items", Xmpp.Xep.Pubsub.NS_URI)
                    .put_attribute("node", ((!) items).get_attribute("node") ?? "")));
        }
        Idle.add(() => { received_iq_stanza(this, response); return Source.REMOVE; });
    }
}

private void remove_tree(File file) {
    try {
        if (file.query_file_type(FileQueryInfoFlags.NOFOLLOW_SYMLINKS) == FileType.DIRECTORY) {
            var children = file.enumerate_children("standard::name", FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
            FileInfo? info;
            while ((info = children.next_file()) != null) remove_tree(file.get_child(((!) info).get_name()));
            children.close();
        }
        file.delete();
    } catch (Error ignored) { }
}

private void stop_fixture_agents() {
    string? binary = Environment.find_program_in_path("gpgconf");
    if (binary == null) return;
    foreach (string name in new string[] { "producer", "consumer" }) {
        int status;
        string errors;
        Dino.Plugins.OpenPgp.run_bounded_subprocess(
            { (!) binary, "--homedir", Path.build_filename(test_root, name), "--kill", "all" },
            "", 5, out status, out errors, "isolated UI keyring shutdown");
    }
}

int main(string[] crt_args) {
#if WINDOWS
    // Match the application: MinGW's narrow CRT argv can lose Unicode paths.
    string[] win32_args = GLib.Win32.get_command_line();
    unowned string[] args = win32_args;
#else
    unowned string[] args = crt_args;
#endif
    try { test_root = DirUtils.make_tmp("dinox-pgp-account-ui-XXXXXX"); }
    catch (Error error) { stderr.printf("Cannot create isolated profile: %s\n", error.message); return 1; }
    string home = Path.build_filename(test_root, "consumer");
    DirUtils.create_with_parents(home, 0700);
    Environment.set_variable("GNUPGHOME", home, true);
    Environment.set_variable("XDG_DATA_HOME", Path.build_filename(test_root, "data"), true);
    Environment.set_variable("XDG_CACHE_HOME", Path.build_filename(test_root, "cache"), true);
    Environment.set_variable("XDG_CONFIG_HOME", Path.build_filename(test_root, "config"), true);
    Environment.set_variable("LANG", "C", true);
    Environment.set_variable("LANGUAGE", "C", true);
    Environment.set_variable("GIO_USE_PORTALS", "0", true);
    Environment.set_variable("GTK_USE_PORTAL", "0", true);
    Environment.set_variable("ADW_DISABLE_PORTAL", "1", true);
    Environment.set_variable("GIO_USE_VFS", "local", true);
    Environment.set_variable("GSETTINGS_BACKEND", "memory", true);
    Test.init(ref args);
    Gtk.init();
    Adw.init();
    Gtk.Settings.get_default().gtk_enable_animations = false;
    try {
        prepare_fixture_key();
        Test.add_func("/KeyManagementAccountScope/explicit_private_binding_is_not_an_activation", () => run_case(0));
        Test.add_func("/KeyManagementAccountScope/private_import_is_visible_without_switching_mode", () => run_case(1));
        Test.add_func("/KeyManagementAccountScope/public_import_does_not_assign_an_existing_private_key", () => run_case(2));
        Test.add_func("/KeyManagementAccountScope/xmpp_disable_restores_only_own_legacy_presence", () => run_case(3));
        Test.add_func("/KeyManagementAccountScope/oversized_import_is_rejected_without_assigning_keys", () => run_case(4));
        Test.add_func("/KeyManagementAccountScope/deleted_core_accounts_do_not_block_historical_key_assignments", () => run_case(5));
        Test.add_func("/KeyManagementAccountScope/disabled_core_accounts_still_protect_their_keys", () => run_case(6));
        int result = Test.run();
        GPGHelper.shutdown_workers();
        stop_fixture_agents();
        remove_tree(File.new_for_path(test_root));
        return result;
    } catch (Error error) {
        stderr.printf("Cannot prepare isolated GPG fixture: %s\n", error.message);
        GPGHelper.shutdown_workers();
        stop_fixture_agents();
        remove_tree(File.new_for_path(test_root));
        return 1;
    }
}

}

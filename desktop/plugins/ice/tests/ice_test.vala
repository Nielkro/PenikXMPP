using Gee;
using Xmpp;
using Xmpp.Xep;

namespace Dino.Plugins.Ice.Test {

private const string LOCAL_FULL_JID = "alice@example.test/dinox";
private const string PEER_FULL_JID = "bob@example.test/phone";

int main(string[] crt_args) {
#if WINDOWS
    // Match the application: MinGW's narrow CRT argv can lose Unicode paths.
    string[] win32_args = GLib.Win32.get_command_line();
    unowned string[] args = win32_args;
#else
    unowned string[] args = crt_args;
#endif
    GLib.Test.init(ref args);
    GLib.Test.set_nonfatal_assertions();
    GLib.Test.add_func("/IcePolicy/JingleS5B_account_without_proxy_keeps_direct_candidates", test_account_without_proxy_keeps_direct_candidates);
    GLib.Test.add_func("/IcePolicy/JingleS5B_socks5_account_blocks_direct_candidates", test_socks5_account_blocks_direct_candidates);
    GLib.Test.add_func("/IcePolicy/JingleS5B_tor_account_blocks_direct_candidates_with_default_uri", test_tor_account_blocks_direct_candidates_with_default_uri);
    GLib.Test.add_func("/IcePolicy/JingleS5B_stream_attach_without_proxy_keeps_direct_candidates", test_stream_attach_without_proxy_keeps_direct_candidates);
    GLib.Test.add_func("/IcePolicy/JingleS5B_stream_attach_socks5_blocks_direct_candidates", test_stream_attach_socks5_blocks_direct_candidates);
    GLib.Test.add_func("/IcePolicy/JingleS5B_stream_attach_tor_blocks_direct_candidates", test_stream_attach_tor_blocks_direct_candidates);
    GLib.Test.add_func("/IcePolicy/JingleS5B_stream_attach_without_proxy_incoming_parse_keeps_direct_candidates", test_stream_attach_without_proxy_incoming_parse_keeps_direct_candidates);
    GLib.Test.add_func("/IcePolicy/JingleS5B_stream_attach_socks5_incoming_parse_blocks_direct_candidates", test_stream_attach_socks5_incoming_parse_blocks_direct_candidates);
    GLib.Test.add_func("/IcePolicy/JingleS5B_stream_attach_tor_incoming_parse_blocks_direct_candidates", test_stream_attach_tor_incoming_parse_blocks_direct_candidates);
    GLib.Test.add_func("/IcePolicy/JingleS5B_missing_module_is_noop", test_missing_jingle_s5b_module_is_noop);
    GLib.Test.add_func("/IcePolicy/TURN_refresh_delay_uses_half_remaining_lifetime", test_turn_refresh_delay_uses_half_remaining_lifetime);
    GLib.Test.add_func("/IcePolicy/TURN_refresh_delay_rejects_near_or_past_expiry", test_turn_refresh_delay_rejects_near_or_past_expiry);
    GLib.Test.add_func("/IcePolicy/TURN_expiry_cleanup_delay_tracks_remaining_lifetime", test_turn_expiry_cleanup_delay_tracks_remaining_lifetime);
    return GLib.Test.run();
}

private void test_account_without_proxy_keeps_direct_candidates() {
    try {
        TestXmppStream stream = create_stream(true);
        var account = new Dino.Entities.Account(new Jid("alice@example.test"), "secret");
        account.proxy_type = "none";

        string? applied_proxy_uri = Dino.Plugins.Ice.apply_jingle_s5b_account_proxy_policy(account, stream);
        StanzaNode transport = create_s5b_transport(stream);

        fail_if(applied_proxy_uri != null, "normal account must not get an outbound S5B proxy URI");
        fail_if(count_candidates_by_type(transport, "direct") == 0, "normal account must keep local direct S5B candidates");
    } catch (Error e) {
        fail_if(true, @"normal account policy failed unexpectedly: $(e.message)");
    }
}

private void test_socks5_account_blocks_direct_candidates() {
    try {
        TestXmppStream stream = create_stream(true);
        var account = new Dino.Entities.Account(new Jid("alice@example.test"), "secret");
        account.proxy_type = "socks5";
        account.proxy_host = "127.0.0.1";
        account.proxy_port = 7777;

        string? applied_proxy_uri = Dino.Plugins.Ice.apply_jingle_s5b_account_proxy_policy(account, stream);
        StanzaNode transport = create_s5b_transport(stream);

        fail_if_not_eq_str("socks5://127.0.0.1:7777", applied_proxy_uri, "SOCKS5 account must apply exact outbound S5B proxy URI");
        fail_if(count_candidates_by_type(transport, "direct") != 0, "SOCKS5 account must suppress local direct S5B candidates");
    } catch (Error e) {
        fail_if(true, @"SOCKS5 account policy failed unexpectedly: $(e.message)");
    }
}

private void test_tor_account_blocks_direct_candidates_with_default_uri() {
    try {
        TestXmppStream stream = create_stream(true);
        var account = new Dino.Entities.Account(new Jid("alice@example.test"), "secret");
        account.proxy_type = "tor";
        account.proxy_host = "";
        account.proxy_port = 0;

        string? applied_proxy_uri = Dino.Plugins.Ice.apply_jingle_s5b_account_proxy_policy(account, stream);
        StanzaNode transport = create_s5b_transport(stream);

        fail_if_not_eq_str("socks5://127.0.0.1:9050", applied_proxy_uri, "Tor account must apply default local SOCKS5 URI");
        fail_if(count_candidates_by_type(transport, "direct") != 0, "Tor account must suppress local direct S5B candidates");
    } catch (Error e) {
        fail_if(true, @"Tor account policy failed unexpectedly: $(e.message)");
    }
}

private void test_missing_jingle_s5b_module_is_noop() {
    try {
        TestXmppStream stream = create_stream(false);
        var account = new Dino.Entities.Account(new Jid("alice@example.test"), "secret");
        account.proxy_type = "socks5";
        account.proxy_host = "127.0.0.1";
        account.proxy_port = 7777;

        string? applied_proxy_uri = Dino.Plugins.Ice.apply_jingle_s5b_account_proxy_policy(account, stream);

        fail_if(applied_proxy_uri != null, "missing Jingle S5B module must be a no-op");
    } catch (Error e) {
        fail_if(true, @"missing-module policy failed unexpectedly: $(e.message)");
    }
}

private void test_turn_refresh_delay_uses_half_remaining_lifetime() {
    DateTime now = new DateTime.from_unix_utc(1700000000);
    uint? delay = Dino.Plugins.Ice.calculate_turn_refresh_delay(now.add_seconds(3600), now);

    fail_if(delay == null, "one-hour TURN credentials should schedule a refresh");
    fail_if_not_eq_uint(1800, (!) delay, "TURN refresh should use half of the remaining lifetime");
}

private void test_turn_refresh_delay_rejects_near_or_past_expiry() {
    DateTime now = new DateTime.from_unix_utc(1700000000);

    fail_if(Dino.Plugins.Ice.calculate_turn_refresh_delay(null, now) != null,
        "missing TURN expiry must not schedule a refresh");
    fail_if(Dino.Plugins.Ice.calculate_turn_refresh_delay(now.add_seconds(240), now) != null,
        "near-expiring TURN credentials must not schedule a refresh");
    fail_if(Dino.Plugins.Ice.calculate_turn_refresh_delay(now.add_seconds(-60), now) != null,
        "expired TURN credentials must not wrap around into a huge refresh delay");
}

private void test_turn_expiry_cleanup_delay_tracks_remaining_lifetime() {
    DateTime now = new DateTime.from_unix_utc(1700000000);

    uint? cleanup_delay = Dino.Plugins.Ice.calculate_turn_expiry_cleanup_delay(now.add_seconds(240), now);
    fail_if(cleanup_delay == null, "near-expiring TURN credentials should schedule cleanup at expiry");
    fail_if_not_eq_uint(240, (!) cleanup_delay, "TURN cleanup should use remaining lifetime");
    fail_if(Dino.Plugins.Ice.calculate_turn_expiry_cleanup_delay(now.add_seconds(-60), now) != null,
        "expired TURN credentials must not schedule cleanup");
}

private void test_stream_attach_without_proxy_keeps_direct_candidates() {
    try {
        TestXmppStream stream = create_stream(true);
        var account = new Dino.Entities.Account(new Jid("alice@example.test"), "secret");
        account.proxy_type = "none";
        var module = stream.get_module<JingleSocks5Bytestreams.Module>(JingleSocks5Bytestreams.Module.IDENTITY);
        fail_if(module == null, "test stream must have a Jingle S5B module");
        ((!) module).set_network_policy(false, "socks5://127.0.0.1:7777");

        apply_policy_via_registered_plugin(account, stream);
        set_loopback_ip_address_handler(stream);
        StanzaNode transport = create_s5b_transport(stream);

        fail_if(count_candidates_by_type(transport, "direct") == 0,
            "registered ICE plugin stream-attach path must keep direct S5B candidates for normal accounts");
    } catch (Error e) {
        fail_if(true, @"stream-attach normal account policy failed unexpectedly: $(e.message)");
    }
}

private void test_stream_attach_socks5_blocks_direct_candidates() {
    try {
        TestXmppStream stream = create_stream(true);
        var account = new Dino.Entities.Account(new Jid("alice@example.test"), "secret");
        account.proxy_type = "socks5";
        account.proxy_host = "127.0.0.1";
        account.proxy_port = 7777;

        apply_policy_via_registered_plugin(account, stream);
        set_loopback_ip_address_handler(stream);
        StanzaNode transport = create_s5b_transport(stream);

        fail_if(count_candidates_by_type(transport, "direct") != 0,
            "registered ICE plugin stream-attach path must suppress direct S5B candidates for SOCKS5 accounts");
    } catch (Error e) {
        fail_if(true, @"stream-attach SOCKS5 account policy failed unexpectedly: $(e.message)");
    }
}

private void test_stream_attach_tor_blocks_direct_candidates() {
    try {
        TestXmppStream stream = create_stream(true);
        var account = new Dino.Entities.Account(new Jid("alice@example.test"), "secret");
        account.proxy_type = "tor";
        account.proxy_host = "";
        account.proxy_port = 0;

        apply_policy_via_registered_plugin(account, stream);
        set_loopback_ip_address_handler(stream);
        StanzaNode transport = create_s5b_transport(stream);

        fail_if(count_candidates_by_type(transport, "direct") != 0,
            "registered ICE plugin stream-attach path must suppress direct S5B candidates for Tor accounts");
    } catch (Error e) {
        fail_if(true, @"stream-attach Tor account policy failed unexpectedly: $(e.message)");
    }
}

private void test_stream_attach_without_proxy_incoming_parse_keeps_direct_candidates() {
    try {
        TestXmppStream stream = create_stream(true);
        var account = new Dino.Entities.Account(new Jid("alice@example.test"), "secret");
        account.proxy_type = "none";

        apply_policy_via_registered_plugin(account, stream);
        set_loopback_ip_address_handler(stream);
        StanzaNode accept_transport = parse_incoming_s5b_offer_transport(stream);

        fail_if(count_candidates_by_type(accept_transport, "direct") == 0,
            "registered ICE plugin incoming parse path must keep direct S5B candidates for normal accounts");
    } catch (Error e) {
        fail_if(true, @"incoming parse normal account policy failed unexpectedly: $(e.message)");
    }
}

private void test_stream_attach_socks5_incoming_parse_blocks_direct_candidates() {
    try {
        TestXmppStream stream = create_stream(true);
        var account = new Dino.Entities.Account(new Jid("alice@example.test"), "secret");
        account.proxy_type = "socks5";
        account.proxy_host = "127.0.0.1";
        account.proxy_port = 7777;

        apply_policy_via_registered_plugin(account, stream);
        set_loopback_ip_address_handler(stream);
        StanzaNode accept_transport = parse_incoming_s5b_offer_transport(stream);

        fail_if(count_candidates_by_type(accept_transport, "direct") != 0,
            "registered ICE plugin incoming parse path must suppress direct S5B candidates for SOCKS5 accounts");
    } catch (Error e) {
        fail_if(true, @"incoming parse SOCKS5 account policy failed unexpectedly: $(e.message)");
    }
}

private void test_stream_attach_tor_incoming_parse_blocks_direct_candidates() {
    try {
        TestXmppStream stream = create_stream(true);
        var account = new Dino.Entities.Account(new Jid("alice@example.test"), "secret");
        account.proxy_type = "tor";
        account.proxy_host = "";
        account.proxy_port = 0;

        apply_policy_via_registered_plugin(account, stream);
        set_loopback_ip_address_handler(stream);
        StanzaNode accept_transport = parse_incoming_s5b_offer_transport(stream);

        fail_if(count_candidates_by_type(accept_transport, "direct") != 0,
            "registered ICE plugin incoming parse path must suppress direct S5B candidates for Tor accounts");
    } catch (Error e) {
        fail_if(true, @"incoming parse Tor account policy failed unexpectedly: $(e.message)");
    }
}

private TestXmppStream create_stream(bool with_jingle_s5b) throws Error {
    var stream = new TestXmppStream(new Jid("example.test"));
    var socks5 = new Socks5Bytestreams.Module();
    stream.add_module(socks5);
    stream.add_flag(new Socks5Bytestreams.Flag());
    set_loopback_ip_address_handler(stream);
    if (with_jingle_s5b) {
        stream.add_module(new JingleSocks5Bytestreams.Module());
    }
    return stream;
}

private void set_loopback_ip_address_handler(TestXmppStream stream) {
    var socks5 = stream.get_module<Socks5Bytestreams.Module>(Socks5Bytestreams.Module.IDENTITY);
    fail_if(socks5 == null, "test stream must have a SOCKS5 module");
    ((!) socks5).set_local_ip_address_handler(() => {
        var addresses = new ArrayList<string>();
        addresses.add("127.0.0.1");
        return addresses;
    });
}

private void apply_policy_via_registered_plugin(Dino.Entities.Account account, TestXmppStream stream) throws Error {
    string db_path = Path.build_filename(Environment.get_tmp_dir(), "dinox-ice-policy-" + Uuid.string_random() + ".db");
    Dino.Database? db = null;

    try {
        db = new Dino.Database(db_path, "ice-policy-test");
        var stream_interactor = new Dino.StreamInteractor.for_tests((!) db);
        var app = new TestApplication(stream_interactor);
        var plugin = new Dino.Plugins.Ice.Plugin();

        plugin.registered(app);
        stream_interactor.stream_attached_modules(account, stream);
    } finally {
        if (db != null) {
            ((!) db).close();
        }
        FileUtils.remove(db_path);
        FileUtils.remove(db_path + "-shm");
        FileUtils.remove(db_path + "-wal");
    }
}

private StanzaNode create_s5b_transport(TestXmppStream stream) throws Error {
    var module = stream.get_module<JingleSocks5Bytestreams.Module>(JingleSocks5Bytestreams.Module.IDENTITY);
    fail_if(module == null, "test stream must have a Jingle S5B module");
    Jingle.TransportParameters parameters = ((!) module).create_transport_parameters(
        stream, 1, new Jid(LOCAL_FULL_JID), new Jid(PEER_FULL_JID));
    return parameters.to_transport_stanza_node("session-initiate");
}

private StanzaNode parse_incoming_s5b_offer_transport(TestXmppStream stream) throws Error {
    var module = stream.get_module<JingleSocks5Bytestreams.Module>(JingleSocks5Bytestreams.Module.IDENTITY);
    fail_if(module == null, "test setup must have a Jingle S5B module");
    var local_full_jid = new Jid(LOCAL_FULL_JID);
    var peer_full_jid = new Jid(PEER_FULL_JID);
    string sid = "incoming-s5b-" + Uuid.string_random();
    string dstaddr = JingleSocks5Bytestreams.calculate_dstaddr(sid, peer_full_jid, local_full_jid);
    StanzaNode incoming_transport = new StanzaNode.build("transport", "urn:xmpp:jingle:transports:s5b:1")
        .add_self_xmlns()
        .put_attribute("mode", "tcp")
        .put_attribute("sid", sid)
        .put_attribute("dstaddr", dstaddr)
        .put_node(new StanzaNode.build("candidate", "urn:xmpp:jingle:transports:s5b:1")
            .put_attribute("cid", "peer-direct")
            .put_attribute("host", "198.51.100.15")
            .put_attribute("jid", PEER_FULL_JID)
            .put_attribute("port", "7777")
            .put_attribute("priority", "8267775")
            .put_attribute("type", "direct"));
    Jingle.TransportParameters parameters = ((!) module).parse_transport_parameters(
        stream, 1, local_full_jid, peer_full_jid, incoming_transport);
    return parameters.to_transport_stanza_node("session-accept");
}

private int count_candidates_by_type(StanzaNode transport, string type_) {
    int count = 0;
    foreach (StanzaNode candidate in transport.get_subnodes("candidate", "urn:xmpp:jingle:transports:s5b:1")) {
        if (candidate.get_attribute("type") == type_) count++;
    }
    return count;
}

private bool fail_if(bool exp, string? reason = null) {
    if (exp) {
        if (reason != null) GLib.Test.message(reason);
        GLib.Test.fail();
        return true;
    }
    return false;
}

private bool fail_if_not_eq_str(string? left, string? right, string? reason = null) {
    bool nullcheck = (left == null) != (right == null);
    string l = left ?? "(null)";
    string r = right ?? "(null)";
    return fail_if(nullcheck || l != r, @"$(reason != null ? reason + ": " : "")'$l' != '$r'");
}

private bool fail_if_not_eq_uint(uint left, uint right, string? reason = null) {
    return fail_if(left != right, @"$(reason != null ? reason + ": " : "")$left != $right");
}

private class TestApplication : GLib.Application, Dino.Application {
    public Dino.Database db { get; set; }
    public string? db_key { get; set; }
    public Dino.Security.FileEncryption file_encryption { get; set; }
    public Dino.Entities.Settings settings { get; set; }
    public Dino.StreamInteractor stream_interactor { get; set; }
    public Dino.Plugins.Registry plugin_registry { get; set; default = new Dino.Plugins.Registry(); }
    public Dino.SearchPathGenerator? search_path_generator { get; set; }

    public TestApplication(Dino.StreamInteractor stream_interactor) {
        Object(application_id: "im.dinox.ice-test", flags: GLib.ApplicationFlags.NON_UNIQUE);
        this.stream_interactor = stream_interactor;
    }

    public void handle_uri(string jid, string query, Gee.Map<string, string> options) {
    }
}

private class TestXmppStream : XmppStream {
    public TestXmppStream(Jid remote_name) {
        base(remote_name);
    }

    public override async void connect() throws IOError {
    }

    public override async void disconnect() throws IOError {
    }

    public override async StanzaNode read() throws IOError {
        throw new IOError.NOT_CONNECTED("test stream has no reader");
    }

    public override async void write_async(StanzaNode node, int io_priority = Priority.DEFAULT, Cancellable? cancellable = null) throws IOError {
        if (cancellable != null) cancellable.set_error_if_cancelled();
    }

    public override async void setup() throws IOError {
    }
}

}

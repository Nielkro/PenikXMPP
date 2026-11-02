using Xmpp;

namespace Xmpp.Test {

class SaslSecurityTest : Gee.TestCase {
    private const string NS = "urn:ietf:params:xml:ns:xmpp-sasl";
    public SaslSecurityTest() {
        base("SaslSecurity");
        add_test("XEP0474_octet_sorted_hash_vectors", test_hash);
        add_test("PLAIN_requires_explicit_consent_and_never_overrides_pin", test_plain_policy);
        add_test("SCRAM_rejects_malformed_and_tampered_challenges", test_bad_challenges);
        add_test("SCRAM_rejects_invalid_or_unsolicited_success", test_bad_success);
        add_test("XEP0474_no_common_binding_requires_hash", test_binding_fallback);
        add_test("server_offer_snapshot_survives_feature_restart_without_cross_account_state", test_offer_snapshot);
    }

    private void test_hash() {
        // Independent hashlib vectors, including unknown advertised mechanisms.
        string[] mechanisms = {"SCRAM-SHA-1-PLUS", "SCRAM-SHA-1"};
        string[] types = {"tls-server-end-point", "tls-exporter"};
        assert_cmpstr(Sasl.Module.downgrade_hash("SCRAM-SHA-1-PLUS", mechanisms, true, types),
            CompareOperator.EQ, "G6k/rBLDqgOhRRaCuuatSDFkJ08=");
        assert_cmpstr(Sasl.Module.downgrade_hash("SCRAM-SHA-256", {"Z-UNKNOWN", "PLAIN", "SCRAM-SHA-256"}, false, {}),
            CompareOperator.EQ, "MV2v2aBXhNC/BFA2kU8nx1IP3UrPr8saRINsJ/dYXQQ=");
        assert_cmpstr(Sasl.Module.downgrade_hash("SCRAM-SHA-512", {"SCRAM-SHA-512"}, true, {}),
            CompareOperator.EQ, "WPLFdPJYY/eYr91DxqgFRSvMeYGhXzbi6Z2wDJQio01cOP4hLcHiE4BcN2TRNlQ2Bp+qBSshWaM6xzDK25v7CA==");
        assert_true(Sasl.Module.downgrade_hash("SCRAM-SHA-256", mechanisms, true, {}) !=
            Sasl.Module.downgrade_hash("SCRAM-SHA-256", mechanisms, false, {}));
    }

    private void test_offer_snapshot() {
        try {
            var stream = stream_with({"SCRAM-SHA-256-PLUS", "SCRAM-SHA-256"}, {"future-binding"});
            var module = new Sasl.Module("user", "fixture");
            module.received_features_node(stream);
            var flag = stream.get_flag(Sasl.Flag.IDENTITY);
            assert_true(flag.server_offers_channel_binding == true);
            assert_cmpstr(flag.mechanism, CompareOperator.EQ, "SCRAM-SHA-256");
            stream.features.sub_nodes.clear();
            assert_true(flag.server_offers_channel_binding == true);
            // A second account/connection gets its own negative or unknown result.
            var other = stream_with({"SCRAM-SHA-256"});
            new Sasl.Module("other", "fixture").received_features_node(other);
            assert_true(other.get_flag(Sasl.Flag.IDENTITY).server_offers_channel_binding == false);
            assert_true(new Sasl.Flag().server_offers_channel_binding == null);
            var rejected = stream_with({"PLAIN"});
            new Sasl.Module("user", "fixture").received_features_node(rejected);
            assert_true(rejected.get_flag(Sasl.Flag.IDENTITY).failed);
            assert_true(rejected.get_flag(Sasl.Flag.IDENTITY).server_offers_channel_binding == false);
        } catch (Error error) { fail_if_reached(error.message); }
    }

    private SaslAuditStream stream_with(string[] mechanisms, string[]? bindings = null) throws Error {
        var stream = new SaslAuditStream(new Jid("example.test"));
        var feature = new StanzaNode.build("mechanisms", NS);
        foreach (string method in mechanisms) feature.put_node(new StanzaNode.build("mechanism", NS).put_node(new StanzaNode.text(method)));
        stream.features.put_node(feature);
        if (bindings != null) {
            var cb = new StanzaNode.build("sasl-channel-binding", "urn:xmpp:sasl-cb:0");
            foreach (string type in bindings) cb.put_node(new StanzaNode.build("channel-binding", cb.ns_uri).put_attribute("type", type));
            stream.features.put_node(cb);
        }
        return stream;
    }

    private void test_plain_policy() {
        try {
            foreach (bool allow in new bool[]{false, true}) {
                foreach (bool seen in new bool[]{false, true}) {
                    var stream = stream_with({"PLAIN"});
                    var module = new Sasl.Module("user", "fixture") { allow_plain=allow, scram_seen=seen };
                    module.received_features_node(stream);
                    assert_cmpint(stream.writes.size, CompareOperator.EQ, 0);
                    assert_cmpstr(stream.get_flag(Sasl.Flag.IDENTITY).failure_reason, CompareOperator.EQ,
                        seen ? "plain-downgrade-blocked" : allow ? "plain-requires-tls" : "plain-disabled");
                    // Replayed features must never retry or clear the rejection.
                    module.received_features_node(stream);
                    assert_cmpint(stream.writes.size, CompareOperator.EQ, 0);
                }
            }
        } catch (Error error) { fail_if_reached(error.message); }
    }

    private StanzaNode response(string name, string text) {
        return new StanzaNode.build(name, NS).put_node(new StanzaNode.text(Base64.encode(text.data)));
    }

    private void test_bad_challenges() {
        try {
            foreach (string suffix in new string[]{
                ",h=wrong", ",h=", ",h=bad,h=bad", ",t=0303", ",t=0304,t=0304", ",t=0304x",
                ",m=required", ",i=4096", ",r=other", ",s=AA==", ",x=one,x=two", ",x=bad\nvalue"
            }) {
                var stream = stream_with({"SCRAM-SHA-256"});
                var module = new Sasl.Module("user", "fixture");
                module.received_features_node(stream);
                var flag = stream.get_flag(Sasl.Flag.IDENTITY);
                flag.tls_version = "0304";
                string first = "r=" + flag.client_nonce + "server,s=QSXCR+Q6sek8bf92,i=4096";
                module.received_nonza(stream, response("challenge", first + suffix));
                assert_true(flag.failed);
                assert_false(flag.finished);
                assert_cmpint(stream.writes.size, CompareOperator.EQ, 1);
                assert_false(module.scram_seen);
                module.received_nonza(stream, response("success", "v=AA=="));
                assert_false(flag.finished);
            }
            foreach (string count in new string[]{"0", "1", "4095", "1000001", "-4096", "4096x", "999999999999999999999"}) {
                var stream = stream_with({"SCRAM-SHA-256"});
                var module = new Sasl.Module("user", "fixture");
                module.received_features_node(stream);
                var flag = stream.get_flag(Sasl.Flag.IDENTITY);
                module.received_nonza(stream, response("challenge", "r=" + flag.client_nonce + "server,s=QSXCR+Q6sek8bf92,i=" + count));
                assert_true(flag.failed);
                assert_cmpint(stream.writes.size, CompareOperator.EQ, 1);
            }
        } catch (Error error) { fail_if_reached(error.message); }
    }

    private void test_bad_success() {
        try {
            foreach (string text in new string[]{"", "v=AA==", "v=AA==,v=AA==", "e=invalid-proof"}) {
                var stream = stream_with({"SCRAM-SHA-256"});
                var module = new Sasl.Module("user", "fixture");
                module.received_features_node(stream);
                int successes = 0;
                module.scram_authenticated.connect(() => successes++);
                module.received_nonza(stream, response("success", text));
                assert_true(stream.get_flag(Sasl.Flag.IDENTITY).failed);
                assert_cmpint(successes, CompareOperator.EQ, 0);
                assert_false(module.scram_seen);
            }
        } catch (Error error) { fail_if_reached(error.message); }
    }

    private void test_binding_fallback() {
        try {
            foreach (bool include_hash in new bool[]{false, true}) {
                var stream = stream_with({"SCRAM-SHA-256-PLUS", "SCRAM-SHA-256"}, {"future-binding"});
                var module = new Sasl.Module("user", "fixture");
                module.received_features_node(stream);
                var flag = stream.get_flag(Sasl.Flag.IDENTITY);
                assert_true(flag.require_advertised_hash);
                string challenge = "r=" + flag.client_nonce + "server,s=QSXCR+Q6sek8bf92,i=4096";
                if (include_hash) challenge += ",h=" + flag.advertised_hash;
                module.received_nonza(stream, response("challenge", challenge));
                assert_true(flag.failed == !include_hash);
                assert_cmpint(stream.writes.size, CompareOperator.EQ, include_hash ? 2 : 1);
            }
            var stream = stream_with({"SCRAM-SHA-256-PLUS", "SCRAM-SHA-256"}, {"future-binding"});
            var strict = new Sasl.Module("user", "fixture") { require_channel_binding=true };
            strict.received_features_node(stream);
            assert_cmpint(stream.writes.size, CompareOperator.EQ, 0);
            assert_cmpstr(stream.get_flag(Sasl.Flag.IDENTITY).failure_reason, CompareOperator.EQ, "channel-binding-required");
        } catch (Error error) { fail_if_reached(error.message); }
    }
}

private class SaslAuditStream : XmppStream {
    public Gee.List<StanzaNode> writes = new Gee.ArrayList<StanzaNode>();
    public SaslAuditStream(Jid remote) { base(remote); }
    public override async void connect() throws IOError {}
    public override async void disconnect() throws IOError {}
    public override async StanzaNode read() throws IOError { throw new IOError.CLOSED("fixture"); }
    public override async void setup() throws IOError {}
    public override async void write_async(StanzaNode node, int io_priority = Priority.DEFAULT, Cancellable? cancellable = null) throws IOError { writes.add(node); }
}
}

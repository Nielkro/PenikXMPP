namespace Xmpp.Test {

class SaslChannelBindingTest : Gee.TestCase {
    public SaslChannelBindingTest() {
        base("SASL channel binding");

        add_async_test("XEP0440_parse_channel_binding_types", (cb) => { test_parse_channel_binding_types.begin(cb); });
        add_test("XEP0440_choose_exporter_when_mutual", test_choose_exporter_when_mutual);
        add_test("XEP0440_choose_server_end_point_when_exporter_not_advertised", test_choose_server_end_point_when_exporter_not_advertised);
        add_test("XEP0440_reject_unknown_advertised_types", test_reject_unknown_advertised_types);
        add_test("SASL1_no_xep0440_does_not_guess_binding_type", test_no_xep0440_does_not_guess_binding_type);
        add_test("SASL1_fallback_to_bare_scram_uses_no_channel_binding_header", test_fallback_to_bare_scram_uses_no_channel_binding_header);
        add_test("SCRAM_escape_username", test_escape_scram_username);
    }

    private async void test_parse_channel_binding_types(Gee.TestFinishedCallback cb) {
        try {
            var stream = """
            <?xml version='1.0' encoding='UTF-8'?>
            <stream:stream
                    to='example.com'
                    xmlns='jabber:client'
                    xmlns:stream='http://etherx.jabber.org/streams'
                    version='1.0'>
                <stream:features>
                  <sasl-channel-binding xmlns='urn:xmpp:sasl-cb:0'>
                    <channel-binding type='tls-server-end-point'/>
                    <channel-binding type='tls-exporter'/>
                  </sasl-channel-binding>
                  <mechanisms xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>
                    <mechanism>SCRAM-SHA-256-PLUS</mechanism>
                    <mechanism>SCRAM-SHA-256</mechanism>
                  </mechanisms>
                </stream:features>
            </stream:stream>
            """;

            var reader = new StanzaReader.for_string(stream);
            yield reader.read_root_node();
            var features = yield reader.read_node();

            fail_if_not(Xmpp.Sasl.Module.has_channel_binding_feature(features));
            Gee.List<string> types = Xmpp.Sasl.Module.get_advertised_channel_binding_types(features);
            fail_if_not_eq_int(types.size, 2);
            fail_if_not(types.contains("tls-server-end-point"));
            fail_if_not(types.contains("tls-exporter"));
        } catch (Error e) {
            fail_if_reached("Unexpected error: " + e.message);
        }
        cb();
    }

    private Gee.List<string> list(string[] values) {
        Gee.List<string> ret = new Gee.ArrayList<string>();
        foreach (string value in values) ret.add(value);
        return ret;
    }

    private void test_choose_exporter_when_mutual() {
        string? chosen = Xmpp.Sasl.Module.choose_channel_binding_type(
            list({"tls-server-end-point", "tls-exporter"}),
            true,
            list({"tls-server-end-point", "tls-exporter"})
        );
        fail_if_not_eq_str(chosen, "tls-exporter");
    }

    private void test_choose_server_end_point_when_exporter_not_advertised() {
        string? chosen = Xmpp.Sasl.Module.choose_channel_binding_type(
            list({"tls-server-end-point"}),
            true,
            list({"tls-server-end-point", "tls-exporter"})
        );
        fail_if_not_eq_str(chosen, "tls-server-end-point");
    }

    private void test_reject_unknown_advertised_types() {
        string? chosen = Xmpp.Sasl.Module.choose_channel_binding_type(
            list({"tls-unique"}),
            true,
            list({"tls-server-end-point", "tls-exporter"})
        );
        fail_if_not(chosen == null);
    }

    private void test_no_xep0440_does_not_guess_binding_type() {
        string? chosen = Xmpp.Sasl.Module.choose_channel_binding_type(
            list({}),
            false,
            list({"tls-server-end-point", "tls-exporter"})
        );
        fail_if_not(chosen == null);
    }

    private void test_fallback_to_bare_scram_uses_no_channel_binding_header() {
        string header = Xmpp.Sasl.Module.choose_gs2_header(
            Xmpp.Sasl.Mechanism.SCRAM_SHA_1,
            null,
            true,
            true
        );
        fail_if_not_eq_str(header, "n,,");

        header = Xmpp.Sasl.Module.choose_gs2_header(
            Xmpp.Sasl.Mechanism.SCRAM_SHA_1,
            null,
            true,
            false
        );
        fail_if_not_eq_str(header, "y,,");

        header = Xmpp.Sasl.Module.choose_gs2_header(
            Xmpp.Sasl.Mechanism.SCRAM_SHA_1_PLUS,
            "tls-server-end-point",
            true,
            true
        );
        fail_if_not_eq_str(header, "p=tls-server-end-point,,");
    }

    private void test_escape_scram_username() {
        fail_if_not_eq_str(Xmpp.Sasl.Module.escape_scram_username("marloo"), "marloo");
        fail_if_not_eq_str(Xmpp.Sasl.Module.escape_scram_username("a=b,c"), "a=3Db=2Cc");
    }
}

}

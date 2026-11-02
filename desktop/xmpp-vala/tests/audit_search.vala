using Gee;
using Xmpp;
using Xmpp.Xep;

namespace Xmpp.Test {

class SearchAudit : Gee.TestCase {
    public SearchAudit() {
        base("SearchAudit");
        add_test("legacy_form_uses_only_advertised_fields", test_legacy_form);
        add_test("data_form_preserves_hidden_and_typed_values", test_data_form);
        add_test("legacy_form_without_fields_is_invalid", test_missing_fields);
        add_test("missing_required_field_blocks_submit", test_required_field);
        add_async_test("legacy_request_has_no_data_form", (cb) => { test_legacy_request.begin(cb); });
        add_async_test("data_form_request_has_no_legacy_fields", (cb) => { test_data_form_request.begin(cb); });
        add_async_test("empty_legacy_result_is_success", (cb) => { test_empty_legacy_result.begin(cb); });
        add_async_test("empty_data_form_result_is_success", (cb) => { test_empty_data_form_result.begin(cb); });
        add_async_test("iq_error_is_distinct_from_empty_result", (cb) => { test_iq_error.begin(cb); });
        add_async_test("unexpected_sender_is_rejected", (cb) => { test_unexpected_sender.begin(cb); });
        add_async_test("cancellation_ignores_late_response_and_allows_retry", (cb) => { test_cancel_then_retry.begin(cb); });
        add_async_test("discovery_request_cancellation_propagates", (cb) => { test_discovery_cancel.begin(cb); });
        add_async_test("empty_discovery_items_are_success", (cb) => { test_empty_discovery_items.begin(cb); });
        add_async_test("missing_discovery_items_are_invalid", (cb) => { test_invalid_discovery_items.begin(cb); });
        add_async_test("wrong_discovery_info_payload_is_invalid", (cb) => { test_invalid_discovery_info.begin(cb); });
        add_async_test("legacy_result_payload_is_validated", (cb) => { test_legacy_result_payload.begin(cb); });
        add_async_test("data_form_result_records_are_validated", (cb) => { test_data_form_result_records.begin(cb); });
    }

    internal static StanzaNode legacy_query() {
        var query = new StanzaNode.build("query", Search.NS_URI).add_self_xmlns();
        query.put_node(new StanzaNode.build("instructions", Search.NS_URI)
                .put_node(new StanzaNode.text("Search registered directory entries.")));
        query.put_node(new StanzaNode.build("nick", Search.NS_URI));
        query.put_node(new StanzaNode.build("email", Search.NS_URI));
        // Neither a foreign field nor an unrecognized legacy field is searchable.
        query.put_node(new StanzaNode.build("last", "urn:example:foreign"));
        query.put_node(new StanzaNode.build("unsupported", Search.NS_URI));
        return query;
    }

    internal static StanzaNode data_form_query() {
        var query = new StanzaNode.build("query", Search.NS_URI).add_self_xmlns();
        var x = new StanzaNode.build("x", DataForms.NS_URI).add_self_xmlns()
                .put_attribute("type", "form");
        x.put_node(field("FORM_TYPE", "hidden", Search.NS_URI));
        x.put_node(field("token", "hidden", "service-token"));
        x.put_node(field("search", "text-single", "monocles"));
        x.put_node(field("nick", "boolean", "1"));
        x.put_node(field("email", "boolean", null));
        var selection = field("category", "list-single", "people");
        selection.put_node(new StanzaNode.build("option", DataForms.NS_URI)
                .put_node(new StanzaNode.build("value", DataForms.NS_URI)
                .put_node(new StanzaNode.text("people"))));
        selection.put_node(new StanzaNode.build("option", DataForms.NS_URI)
                .put_node(new StanzaNode.build("value", DataForms.NS_URI)));
        x.put_node(selection);
        x.put_node(field("notice", "fixed", "Directory search"));
        query.put_node(x);
        return query;
    }

    private static StanzaNode field(string name, string type, string? value) {
        var node = new StanzaNode.build("field", DataForms.NS_URI)
                .put_attribute("var", name).put_attribute("type", type);
        if (value != null) {
            node.put_node(new StanzaNode.build("value", DataForms.NS_URI)
                    .put_node(new StanzaNode.text((!) value)));
        }
        return node;
    }

    private SearchAuditStream stream(string result_mode = "empty") throws Error {
        var stream = new SearchAuditStream(new Jid("example.test"));
        stream.result_mode = result_mode;
        var iq = new Iq.Module();
        stream.add_module(iq);
        iq.attach(stream);
        stream.add_module(new Search.Module());
        return stream;
    }

    private void test_legacy_form() {
        try {
            var form = new Search.Form.from_query(legacy_query());
            assert_true(form.is_legacy_form);
            assert_true(form.fields.size == 2);
            fail_if_not_eq_str(form.fields[0].var, "nick");
            fail_if_not_eq_str(form.fields[1].var, "email");
            fail_if_not_eq_str(form.instructions, "Search registered directory entries.");
            form.fields[0].set_value_string("monocles");
            StanzaNode query = form.get_submit_query_node();
            fail_if_not_eq_str(query.get_deep_string_content("nick"), "monocles");
            assert_null(query.get_subnode("email", Search.NS_URI));
            assert_null(query.get_subnode("x", DataForms.NS_URI));
        } catch (Error e) {
            fail_if_reached(e.message);
        }
    }

    private void test_data_form() {
        try {
            var form = new Search.Form.from_query(data_form_query());
            assert_false(form.is_legacy_form);
            fail_if_not_eq_str(form.form_type, Search.NS_URI);
            StanzaNode query = form.get_submit_query_node();
            StanzaNode? submit = query.get_subnode("x", DataForms.NS_URI);
            assert_nonnull(submit);
            if (submit == null) return;
            fail_if_not_eq_str(submit.get_attribute("type"), "submit");
            var submitted = DataForms.DataForm.create_from_node((!) submit);
            assert_nonnull(submitted);
            if (submitted == null) return;
            fail_if_not_eq_str(submitted.form_type, Search.NS_URI);
            assert_true(submitted.fields.size == 5);
            fail_if_not_eq_str(submitted.fields[0].var, "token");
            assert_true(submitted.fields[0].type_ == DataForms.DataForm.Type.HIDDEN);
            fail_if_not_eq_str(submitted.fields[0].get_value_string(), "service-token");
            fail_if_not_eq_str(submitted.fields[3].get_value_string(), "0");
            fail_if_not_eq_str(form.kind, "form");
            assert_true(form.fields[4].type_ == DataForms.DataForm.Type.LIST_SINGLE);
            var options = ((DataForms.DataForm.ListSingleField) form.fields[4]).options;
            assert_true(options.size == 2);
            fail_if_not_eq_str(options[0].label, "people");
            fail_if_not_eq_str(options[1].label, "");
            fail_if_not_eq_str(options[1].value, "");
            assert_null(query.get_subnode("nick", Search.NS_URI));
            // A second submission still has the original hidden values and types.
            assert_nonnull(form.get_submit_query_node().get_subnode("x", DataForms.NS_URI));
        } catch (Error e) {
            fail_if_reached(e.message);
        }
    }

    private void test_missing_fields() {
        try {
            new Search.Form.from_query(new StanzaNode.build("query", Search.NS_URI));
            fail_if_reached("A missing service form must not invent nick search");
        } catch (Error e) {
            assert_true(e is IOError.INVALID_DATA);
        }
    }

    private void test_required_field() {
        try {
            var query = data_form_query();
            var required = field("required", "text-single", null);
            required.put_node(new StanzaNode.build("required", DataForms.NS_URI));
            query.get_subnode("x", DataForms.NS_URI).put_node(required);
            var form = new Search.Form.from_query(query);
            form.get_submit_query_node();
            fail_if_reached("Required fields must be validated before sending");
        } catch (Error e) {
            assert_true(e is IOError.INVALID_ARGUMENT);
        }
    }

    private async void test_legacy_request(Gee.TestFinishedCallback done) {
        try {
            var s = stream("legacy-results");
            var service = new Jid("vjud.example.test");
            var module = s.get_module<Search.Module>(Search.Module.IDENTITY);
            var form = yield module.get_fields(s, service);
            form.fields[0].set_value_string("juliet");
            var results = yield module.search(s, service, form);
            assert_true(results.size == 1);
            fail_if_not_eq_str(results[0].jid.to_string(), "juliet@example.test");
            var sent = s.written_nodes[1].get_subnode("query", Search.NS_URI);
            assert_nonnull(sent);
            assert_null(sent.get_subnode("x", DataForms.NS_URI));
            fail_if_not_eq_str(sent.get_deep_string_content("nick"), "juliet");
            fail_if_not_eq_str(s.written_nodes[1].get_attribute("to"), "vjud.example.test");
            var reader = new StanzaReader.for_string(
                    "<stream:stream xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams'>" +
                    s.written_xml[0] + s.written_xml[1] + "</stream:stream>");
            yield reader.read_root_node();
            var wire_get = yield reader.read_node();
            var wire_set = yield reader.read_node();
            assert_nonnull(wire_get.get_subnode("query", Search.NS_URI));
            var wire_query = wire_set.get_subnode("query", Search.NS_URI);
            assert_nonnull(wire_query);
            fail_if_not_eq_str(wire_query.get_deep_string_content("nick"), "juliet");
            assert_null(wire_query.get_subnode("x", DataForms.NS_URI));
        } catch (Error e) {
            fail_if_reached(e.message);
        }
        done();
    }

    private async void test_data_form_request(Gee.TestFinishedCallback done) {
        try {
            var s = stream("data-results");
            s.extended_form = true;
            var module = s.get_module<Search.Module>(Search.Module.IDENTITY);
            var service = new Jid("vjud.example.test");
            var form = yield module.get_fields(s, service);
            var results = yield module.search(s, service, form);
            assert_true(results.size == 1);
            fail_if_not_eq_str(results[0].jid.to_string(), "juliet@example.test");
            var sent = s.written_nodes[1].get_subnode("query", Search.NS_URI);
            assert_nonnull(sent.get_subnode("x", DataForms.NS_URI));
            assert_null(sent.get_subnode("nick", Search.NS_URI));
            var reader = new StanzaReader.for_string(
                    "<stream:stream xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams'>" +
                    s.written_xml[1] + "</stream:stream>");
            yield reader.read_root_node();
            var wire_set = yield reader.read_node();
            var wire_query = wire_set.get_subnode("query", Search.NS_URI);
            assert_nonnull(wire_query);
            var wire_x = wire_query.get_subnode("x", DataForms.NS_URI);
            assert_nonnull(wire_x);
            var wire_form = DataForms.DataForm.create_from_node((!) wire_x);
            assert_nonnull(wire_form);
            if (wire_form == null) { done(); return; }
            fail_if_not_eq_str(wire_form.form_type, Search.NS_URI);
            assert_null(wire_query.get_subnode("nick", Search.NS_URI));
        } catch (Error e) {
            fail_if_reached(e.message);
        }
        done();
    }

    private async void test_empty_legacy_result(Gee.TestFinishedCallback done) {
        yield check_empty("empty");
        done();
    }

    private async void test_empty_data_form_result(Gee.TestFinishedCallback done) {
        yield check_empty("data-empty");
        done();
    }

    private async void check_empty(string mode) {
        try {
            var s = stream(mode);
            var form = new Search.Form.from_query(legacy_query());
            var results = yield s.get_module<Search.Module>(Search.Module.IDENTITY)
                    .search(s, new Jid("vjud.example.test"), form);
            assert_true(results.is_empty);
        } catch (Error e) {
            fail_if_reached(e.message);
        }
    }

    private async void test_iq_error(Gee.TestFinishedCallback done) {
        try {
            var s = stream("error");
            var form = new Search.Form.from_query(legacy_query());
            yield s.get_module<Search.Module>(Search.Module.IDENTITY)
                    .search(s, new Jid("vjud.example.test"), form);
            fail_if_reached("A service error must not appear as no matches");
        } catch (Error e) {
            assert_true(e is IOError.FAILED);
            assert_true(e.message.contains("service-unavailable"));
        }
        done();
    }

    private async void test_unexpected_sender(Gee.TestFinishedCallback done) {
        try {
            var s = stream("wrong-sender");
            var form = new Search.Form.from_query(legacy_query());
            yield s.get_module<Search.Module>(Search.Module.IDENTITY)
                    .search(s, new Jid("vjud.example.test"), form);
            fail_if_reached("A search result must come from its directory service");
        } catch (Error e) {
            assert_true(e is IOError.INVALID_DATA);
        }
        done();
    }

    private async void test_cancel_then_retry(Gee.TestFinishedCallback done) {
        try {
            var s = stream();
            var service = new Jid("vjud.example.test");
            var module = s.get_module<Search.Module>(Search.Module.IDENTITY);
            var cancellable = new Cancellable();
            s.cancel_on_write = cancellable;
            try {
                yield module.get_fields(s, service, cancellable);
                fail_if_reached("Cancelled search form request unexpectedly completed");
            } catch (Error e) {
                assert_true(e is IOError.CANCELLED);
            }
            s.cancel_on_write = null;
            // The response to the cancelled ID must not resume the old coroutine.
            s.received_iq_stanza(s, s.response(s.written_nodes[0]));
            var form = yield module.get_fields(s, service);
            assert_true(form.is_legacy_form);
            assert_true(s.written_nodes.size == 2);
        } catch (Error e) {
            fail_if_reached(e.message);
        }
        done();
    }

    private async void test_discovery_cancel(Gee.TestFinishedCallback done) {
        try {
            var s = stream();
            var disco = new ServiceDiscovery.Module();
            s.add_module(disco);
            var cancellable = new Cancellable();
            s.cancel_on_write = cancellable;
            yield disco.request_info_cancellable(s, new Jid("example.test"), cancellable);
            fail_if_reached("Discovery cancellation was swallowed");
        } catch (Error e) {
            assert_true(e is IOError.CANCELLED);
        }
        done();
    }

    private async void test_empty_discovery_items(Gee.TestFinishedCallback done) {
        try {
            var s = stream("disco-empty-items");
            var disco = new ServiceDiscovery.Module();
            var result = yield disco.request_items_cancellable(s,
                    new Jid("example.test"), null, null);
            assert_nonnull(result);
            assert_true(result.items.is_empty);
        } catch (Error e) {
            fail_if_reached(e.message);
        }
        done();
    }

    private async void test_invalid_discovery_items(Gee.TestFinishedCallback done) {
        try {
            var s = stream("disco-missing-query");
            var disco = new ServiceDiscovery.Module();
            yield disco.request_items_cancellable(s, new Jid("example.test"), null, null);
            fail_if_reached("A missing items payload must not look like no directory");
        } catch (Error e) {
            assert_true(e is IOError.INVALID_DATA);
        }
        done();
    }

    private async void test_invalid_discovery_info(Gee.TestFinishedCallback done) {
        try {
            var s = stream("disco-wrong-query");
            var disco = new ServiceDiscovery.Module();
            yield disco.request_info_cancellable(s, new Jid("example.test"), null);
            fail_if_reached("A wrong info payload must not look like unsupported search");
        } catch (Error e) {
            assert_true(e is IOError.INVALID_DATA);
        }
        done();
    }

    private async void test_legacy_result_payload(Gee.TestFinishedCallback done) {
        try {
            var form = new Search.Form.from_query(legacy_query());
            var service = new Jid("vjud.example.test");
            foreach (string mode in new string[] { "legacy-fields-instead-of-results", "legacy-bad-record" }) {
                var invalid = stream(mode);
                try {
                    yield invalid.get_module<Search.Module>(Search.Module.IDENTITY)
                            .search(invalid, service, form);
                    fail_if_reached("Malformed legacy results must not appear as no matches");
                } catch (Error e) {
                    assert_true(e is IOError.INVALID_DATA);
                }
            }
            var mixed = stream("legacy-bad-and-good");
            var results = yield mixed.get_module<Search.Module>(Search.Module.IDENTITY)
                    .search(mixed, service, form);
            assert_true(results.size == 1);
            fail_if_not_eq_str(results[0].jid.to_string(), "juliet@example.test");
        } catch (Error e) {
            fail_if_reached(e.message);
        }
        done();
    }

    private async void test_data_form_result_records(Gee.TestFinishedCallback done) {
        try {
            var form = new Search.Form.from_query(data_form_query());
            var service = new Jid("vjud.example.test");
            var invalid = stream("data-bad-record");
            try {
                yield invalid.get_module<Search.Module>(Search.Module.IDENTITY)
                        .search(invalid, service, form);
                fail_if_reached("Unusable data form records must not appear as no matches");
            } catch (Error e) {
                assert_true(e is IOError.INVALID_DATA);
            }
            var mixed = stream("data-bad-and-good");
            var results = yield mixed.get_module<Search.Module>(Search.Module.IDENTITY)
                    .search(mixed, service, form);
            assert_true(results.size == 1);
            fail_if_not_eq_str(results[0].jid.to_string(), "juliet@example.test");
        } catch (Error e) {
            fail_if_reached(e.message);
        }
        done();
    }
}

private class SearchAuditStream : XmppStream {
    public ArrayList<StanzaNode> written_nodes = new ArrayList<StanzaNode>();
    public ArrayList<string> written_xml = new ArrayList<string>();
    public string result_mode = "empty";
    public bool extended_form = false;
    public Cancellable? cancel_on_write = null;

    public SearchAuditStream(Jid remote_name) { base(remote_name); }
    public override async void connect() throws IOError { }
    public override async void disconnect() throws IOError { }
    public override async StanzaNode read() throws IOError {
        throw new IOError.NOT_CONNECTED("Test stream has no reader");
    }
    public override async void setup() throws IOError { }

    public override async void write_async(StanzaNode node,
            int io_priority = Priority.DEFAULT, Cancellable? cancellable = null) throws IOError {
        if (cancellable != null) ((!) cancellable).set_error_if_cancelled();
        // Exercise exactly the serializer used by StanzaWriter.write_node().
        written_xml.add(node.to_xml());
        written_nodes.add(node);
        if (cancel_on_write != null) {
            ((!) cancel_on_write).cancel();
            return;
        }
        Idle.add(() => {
            received_iq_stanza(this, response(node));
            return Source.REMOVE;
        });
    }

    public StanzaNode response(StanzaNode request) {
        var response = new StanzaNode.build("iq", "jabber:client")
                .put_attribute("type", "result")
                .put_attribute("id", request.get_attribute("id"))
                .put_attribute("from", request.get_attribute("to"));
        if (result_mode == "disco-empty-items") {
            response.put_node(new StanzaNode.build("query", ServiceDiscovery.NS_URI_ITEMS)
                    .add_self_xmlns());
            return response;
        }
        if (result_mode == "disco-missing-query") return response;
        if (result_mode == "disco-wrong-query") {
            response.put_node(new StanzaNode.build("query", Search.NS_URI).add_self_xmlns());
            return response;
        }
        if (request.get_attribute("type") == "get") {
            response.put_node(extended_form ? SearchAudit.data_form_query() : SearchAudit.legacy_query());
            return response;
        }
        if (result_mode == "error") {
            response.set_attribute("type", "error");
            response.put_node(new StanzaNode.build("error", "jabber:client")
                    .put_attribute("type", "cancel")
                    .put_node(new StanzaNode.build("service-unavailable",
                    "urn:ietf:params:xml:ns:xmpp-stanzas").add_self_xmlns()));
            return response;
        }
        if (result_mode == "wrong-sender") {
            response.set_attribute("from", "unrelated.example.test");
        }
        var query = new StanzaNode.build("query", Search.NS_URI).add_self_xmlns();
        if (result_mode == "legacy-fields-instead-of-results") {
            query.put_node(new StanzaNode.build("nick", Search.NS_URI));
            query.put_node(new StanzaNode.build("email", Search.NS_URI));
        }
        if (result_mode == "legacy-bad-and-good" || result_mode == "legacy-bad-record") {
            query.put_node(new StanzaNode.build("item", Search.NS_URI));
        }
        if (result_mode == "legacy-results" || result_mode == "legacy-bad-and-good") {
            query.put_node(new StanzaNode.build("item", Search.NS_URI)
                    .put_attribute("jid", "juliet@example.test")
                    .put_node(new StanzaNode.build("nick", Search.NS_URI)
                    .put_node(new StanzaNode.text("juliet"))));
        } else if (result_mode == "data-results" || result_mode == "data-empty" ||
                result_mode == "data-bad-record" || result_mode == "data-bad-and-good") {
            var x = new StanzaNode.build("x", DataForms.NS_URI).add_self_xmlns()
                    .put_attribute("type", "result");
            if (result_mode == "data-bad-record" || result_mode == "data-bad-and-good") {
                x.put_node(new StanzaNode.build("item", DataForms.NS_URI));
            }
            if (result_mode == "data-results" || result_mode == "data-bad-and-good") {
                x.put_node(new StanzaNode.build("item", DataForms.NS_URI)
                        .put_node(new StanzaNode.build("field", DataForms.NS_URI)
                        .put_attribute("var", "jid")
                        .put_node(new StanzaNode.build("value", DataForms.NS_URI)
                        .put_node(new StanzaNode.text("juliet@example.test")))));
            }
            query.put_node(x);
        }
        response.put_node(query);
        return response;
    }
}

}

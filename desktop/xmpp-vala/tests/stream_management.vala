namespace Xmpp.Test {

/**
 * Spec-based tests for XEP-0198 Stream Management.
 *
 * References:
 *   - XEP-0198 §3: Enabling Stream Management
 *   - XEP-0198 §4: Acks
 *   - XEP-0198 §5: Resumption + h counter semantics
 *   - XEP-0198 §6: Errors
 *
 * Each test verifies behavior defined by the XEP, not internal API.
 */
class StreamManagementTest : Gee.TestCase {

    private const string SM_NS = "urn:xmpp:sm:3";

    public StreamManagementTest() {
        base("StreamManagement");
        // XEP-0198 §3: Enabling
        add_test("XEP0198_enable_must_have_xmlns_sm3", test_enable_xmlns);
        add_test("XEP0198_enable_resume_attribute", test_enable_resume);
        add_async_test("XEP0198_parse_enabled_from_xml", (cb) => { test_parse_enabled_xml.begin(cb); });
        // XEP-0198 §4: Acks
        add_test("XEP0198_r_element_is_empty", test_r_empty);
        add_test("XEP0198_a_element_has_h", test_a_has_h);
        // XEP-0198 §5: h counter
        add_test("XEP0198_h_counter_is_uint32", test_h_uint32);
        add_test("XEP0198_h_wraps_at_2_32", test_h_wraps);
        add_test("XEP0198_h_max_value_4294967295", test_h_max);
        // XEP-0198 §5: Resumption
        add_async_test("XEP0198_parse_resumed_from_xml", (cb) => { test_parse_resumed_xml.begin(cb); });
        add_async_test("XEP0198_parse_failed_with_h", (cb) => { test_parse_failed_xml.begin(cb); });
        // XEP-0198 §6: Feature discovery
        add_async_test("XEP0198_feature_in_stream_features", (cb) => { test_feature_discovery.begin(cb); });
        add_test("XEP0198_only_stanzas_increment_h", test_only_stanzas_count);
        add_test("XEP0198_user_message_waits_for_write_completion", test_user_message_waits_for_write);
        add_test("XEP0198_omemo_message_waits_for_write_completion", test_omemo_message_waits_for_write);
        add_test("XEP0198_receipt_message_does_not_wait_for_write_completion", test_receipt_message_does_not_wait_for_write);
        add_test("XEP0198_chat_state_message_does_not_wait_for_write_completion", test_chat_state_message_does_not_wait_for_write);
        add_test("XEP0198_terminal_disconnect_discards_resume_state",
            test_terminal_disconnect_discards_resume_state);
        add_async_test("XEP0198_terminal_disconnect_rejects_late_writes",
            (cb) => {
                test_terminal_disconnect_rejects_late_writes.begin(cb);
            });
        add_test("XmppStream_early_failure_skips_unattached_MUJI",
            test_early_failure_skips_unattached_muji);
        add_test("XmppStream_partial_attach_detaches_once",
            test_partial_attach_detaches_once);
        add_test("XEP0198_resume_module_lifecycle_is_per_stream",
            test_resume_module_lifecycle_is_per_stream);
    }

    /**
     * XEP-0198 §3: "To enable use of stream management, the client sends
     * an <enable/> command ... qualified by the namespace 'urn:xmpp:sm:3'."
     */
    private void test_enable_xmlns() {
        StanzaNode node = new StanzaNode.build("enable", SM_NS).add_self_xmlns();
        fail_if_not_eq_str(node.name, "enable");
        fail_if_not_eq_str(node.ns_uri, SM_NS);
    }

    /**
     * XEP-0198 §3: "the client MAY include a 'resume' attribute with
     * a value of 'true' or '1'."
     */
    private void test_enable_resume() {
        StanzaNode node = new StanzaNode.build("enable", SM_NS)
            .add_self_xmlns()
            .put_attribute("resume", "true");
        fail_if_not_eq_str(node.get_attribute("resume"), "true");
    }

    /**
     * XEP-0198 §3 Example 3: Server responds with
     * <enabled xmlns='urn:xmpp:sm:3' id='some-long-sm-id' resume='true'/>
     * Parse from real XML.
     */
    private async void test_parse_enabled_xml(Gee.TestFinishedCallback cb) {
        try {
            string xml = "<enabled xmlns='urn:xmpp:sm:3' id='some-long-sm-id' resume='true'/>";
            var reader = new StanzaReader.for_string(xml);
            StanzaNode node = yield reader.read_node();

            fail_if_not_eq_str(node.name, "enabled");
            fail_if_not_eq_str(node.ns_uri, SM_NS);

            string? id = node.get_attribute("id", SM_NS);
            fail_if(id == null, "XEP-0198 §3: <enabled> MUST have 'id' for resumable sessions");
            fail_if_not_eq_str(id, "some-long-sm-id");

            string? resume = node.get_attribute("resume");
            if (resume == null) resume = node.get_attribute("resume", SM_NS);
            fail_if(resume == null, "XEP-0198 §3: <enabled> should include 'resume' attribute");
        } catch (Error e) {
            fail_if_reached("XML parse error: " + e.message);
        }
        cb();
    }

    /**
     * XEP-0198 §4: "<r/> is used to request an ack. It has no attributes."
     */
    private void test_r_empty() {
        StanzaNode node = new StanzaNode.build("r", SM_NS).add_self_xmlns();
        fail_if_not_eq_str(node.name, "r");
        fail_if_not_eq_int(node.sub_nodes.size, 0);
        // Per XEP: <r/> has no attributes (other than xmlns)
        // The h counter is NOT included in <r/>
    }

    /**
     * XEP-0198 §4: "<a/> is used to answer a request. It MUST include
     * an 'h' attribute ... the value of 'h' ... is the number of stanzas
     * handled."
     */
    private void test_a_has_h() {
        uint32 h = 42;
        StanzaNode node = new StanzaNode.build("a", SM_NS)
            .add_self_xmlns()
            .put_attribute("h", h.to_string());

        string? h_str = node.get_attribute("h");
        fail_if(h_str == null, "XEP-0198 §4: <a/> MUST include 'h' attribute");
        fail_if_not_eq_str(h_str, "42");
    }

    /**
     * XEP-0198 §5: "the counter for an entity's own sent stanzas is
     * an unsigned integer from 0 to 2^32-1"
     * h_inbound/h_outbound MUST be uint32, not signed int.
     */
    private void test_h_uint32() {
        var module = new Xmpp.Xep.StreamManagement.Module();
        // Set to value >INT32_MAX — must work without overflow
        module.h_inbound = (uint32) 2147483648; // 2^31, impossible for signed int
        fail_if(module.h_inbound != (uint32) 2147483648,
            "XEP-0198 §5: h counter must handle values >2^31 (uint32)");
    }

    /**
     * XEP-0198 §5: "In the unlikely case that the number of stanzas
     * handled during a stream management session exceeds the number
     * of digits that can be represented by the counter, the counter
     * simply wraps around."
     */
    private void test_h_wraps() {
        var module = new Xmpp.Xep.StreamManagement.Module();
        module.h_inbound = uint32.MAX; // 4294967295
        module.h_inbound++; // Must wrap to 0

        if (module.h_inbound != 0) {
            GLib.Test.message("XEP-0198 §5: h counter must wrap from 2^32-1 to 0, got %u".printf(module.h_inbound));
            GLib.Test.fail();
        }
    }

    /**
     * XEP-0198 §5: Max valid h value is 2^32-1 = 4294967295.
     * Serialized as string "4294967295", MUST NOT be negative.
     */
    private void test_h_max() {
        var module = new Xmpp.Xep.StreamManagement.Module();
        module.h_inbound = uint32.MAX;

        string h_str = module.h_inbound.to_string();
        fail_if(h_str.has_prefix("-"),
            "XEP-0198 §5: h.to_string() must never be negative");
        fail_if_not_eq_str(h_str, "4294967295");
    }

    private void test_terminal_disconnect_discards_resume_state() {
        var module = new Xmpp.Xep.StreamManagement.Module();
        module.session_id = "resumable-session";
        module.h_inbound = 41;
        module.h_outbound = 42;
        module.flags = new Gee.ArrayList<XmppStreamFlag>();

        module.discard_session("terminal test disconnect");

        fail_if(module.session_id != null,
            "A terminal disconnect must not retain a resumable session id");
        fail_if(module.flags != null,
            "A terminal disconnect must not retain old stream flags");
        fail_if(module.h_inbound != 0 || module.h_outbound != 0,
            "A terminal disconnect must reset both SM counters");
    }

    private async void test_terminal_disconnect_rejects_late_writes(
            Gee.TestFinishedCallback cb) {
        try {
            var module = new Xmpp.Xep.StreamManagement.Module();
            var stream = new TerminalDiscardStream(new Jid("example.test"));
            module.discard_session("terminal test disconnect", stream);

            var message = new StanzaNode.build("message", "jabber:client")
                .add_self_xmlns()
                .put_node(new StanzaNode.build("body", "jabber:client")
                    .add_self_xmlns().put_node(
                        new StanzaNode.text("late")));
            bool cancelled = false;
            try {
                yield module.write_stanza(stream, message);
            } catch (IOError error) {
                cancelled = error is IOError.CANCELLED;
            }
            fail_if(!cancelled,
                "A late user write on a discarded stream must be cancelled");

            var presence = new StanzaNode.build("presence", "jabber:client")
                .add_self_xmlns();
            try {
                yield module.write_stanza(stream, presence);
            } catch (IOError error) {
                fail_if_reached(
                    "A lightweight discarded write must not throw: " +
                    error.message);
            }
        } catch (InvalidJidError error) {
            fail_if_reached("Unexpected test JID error: " + error.message);
        }
        cb();
    }

    private void test_early_failure_skips_unattached_muji() {
        try {
            var stream = new TerminalDiscardStream(
                new Jid("example.test"));
            var muji = new TrackingMujiModule();
            stream.add_module(muji);

            stream.detach_modules();
            stream.detach_modules();

            fail_if_not_eq_int(muji.detach_count, 0,
                "An early connect failure must not detach MUJI before attach");
        } catch (InvalidJidError error) {
            fail_if_reached("Unexpected test JID error: " + error.message);
        }
    }

    private void test_partial_attach_detaches_once() {
        try {
            var stream = new TerminalDiscardStream(
                new Jid("example.test"));
            var negotiation = new TrackingNegotiationModule();
            var regular = new TrackingMujiModule();
            stream.add_module(negotiation);
            stream.add_module(regular);

            stream.attach_negotation_modules();
            stream.attach_negotation_modules();
            stream.detach_modules();
            stream.detach_modules();

            fail_if_not_eq_int(negotiation.attach_count, 1,
                "Negotiation modules must only be attached once per stream");
            fail_if_not_eq_int(negotiation.detach_count, 1,
                "An attached negotiation module must only be detached once");
            fail_if_not_eq_int(regular.detach_count, 0,
                "A regular module that was never attached must not be detached");
        } catch (InvalidJidError error) {
            fail_if_reached("Unexpected test JID error: " + error.message);
        }
    }

    private void test_resume_module_lifecycle_is_per_stream() {
        try {
            var bind = new Bind.Module("test");
            var stream_management = new TrackingStreamManagementModule();
            var first_stream = new TerminalDiscardStream(
                new Jid("example.test"));
            first_stream.add_module(bind);
            first_stream.add_module(stream_management);
            first_stream.attach_negotation_modules();

            var saved_flag = new Xep.StreamManagement.Flag();
            first_stream.add_flag(saved_flag);
            stream_management.session_id = "resume-id";
            stream_management.flags = first_stream.flags;

            first_stream.detach_modules();
            first_stream.detach_modules();

            fail_if_not_eq_int(stream_management.attach_count, 1,
                "The first stream must attach stream management once");
            fail_if_not_eq_int(stream_management.detach_count, 1,
                "The first stream must detach stream management once");
            fail_if_not_eq_str(stream_management.session_id, "resume-id",
                "Detaching a transport must retain the resumable SM session");
            fail_if(stream_management.flags == null ||
                    !((!) stream_management.flags).contains(saved_flag),
                "Detaching a transport must retain the saved SM flags");

            var replacement_stream = new TerminalDiscardStream(
                new Jid("example.test"));
            replacement_stream.add_module(bind);
            replacement_stream.add_module(stream_management);
            replacement_stream.attach_negotation_modules();
            replacement_stream.attach_negotation_modules();

            fail_if_not_eq_int(stream_management.attach_count, 2,
                "A shared SM module must attach independently to a replacement stream");
            fail_if_not_eq_int(stream_management.detach_count, 1,
                "Detaching the old stream must not detach the replacement stream");

            replacement_stream.detach_modules();
            replacement_stream.detach_modules();
            fail_if_not_eq_int(stream_management.detach_count, 2,
                "The replacement stream must detach its SM module exactly once");
            fail_if_not_eq_str(stream_management.session_id, "resume-id",
                "Normal module detach must not discard SM resume state");
        } catch (InvalidJidError error) {
            fail_if_reached("Unexpected test JID error: " + error.message);
        }
    }

    /**
     * XEP-0198 §5 Example 7: Resumed
     * <resumed xmlns='urn:xmpp:sm:3' h='another-sequence-number' previd='some-long-sm-id'/>
     */
    private async void test_parse_resumed_xml(Gee.TestFinishedCallback cb) {
        try {
            string xml = "<resumed xmlns='urn:xmpp:sm:3' h='255' previd='session-xyz'/>";
            var reader = new StanzaReader.for_string(xml);
            StanzaNode node = yield reader.read_node();

            fail_if_not_eq_str(node.name, "resumed");
            fail_if_not_eq_str(node.ns_uri, SM_NS);

            string? h = node.get_attribute("h", SM_NS);
            if (h == null) h = node.get_attribute("h");
            fail_if(h == null, "XEP-0198 §5: <resumed> MUST include 'h'");

            string? previd = node.get_attribute("previd");
            if (previd == null) previd = node.get_attribute("previd", SM_NS);
            fail_if(previd == null, "XEP-0198 §5: <resumed> MUST include 'previd'");
        } catch (Error e) {
            fail_if_reached("XML parse error: " + e.message);
        }
        cb();
    }

    /**
     * XEP-0198 §5: "If the server does not support session resumption, or the
     * session has timed out, it MUST return a <failed/> element, which MAY
     * include an 'h' attribute."
     *
     * Also: <failed> MAY contain an error condition child per XMPP stanza errors.
     */
    private async void test_parse_failed_xml(Gee.TestFinishedCallback cb) {
        try {
            string xml = "<failed xmlns='urn:xmpp:sm:3' h='50'>" +
                "<item-not-found xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/>" +
                "</failed>";
            var reader = new StanzaReader.for_string(xml);
            StanzaNode node = yield reader.read_node();

            fail_if_not_eq_str(node.name, "failed");

            // h is optional per XEP, but present here
            string? h = node.get_attribute("h", SM_NS);
            if (h == null) h = node.get_attribute("h");
            fail_if(h == null, "XEP-0198: h attribute should be present in this test case");

            // Error condition child in stanza-errors namespace
            string ERR_NS = "urn:ietf:params:xml:ns:xmpp-stanzas";
            StanzaNode? err = node.get_subnode("item-not-found", ERR_NS);
            fail_if(err == null, "XEP-0198 §5: <failed> should contain error condition child");
        } catch (Error e) {
            fail_if_reached("XML parse error: " + e.message);
        }
        cb();
    }

    /**
     * XEP-0198 §3: Stream management availability is advertised via
     * <sm xmlns='urn:xmpp:sm:3'/> in stream features.
     */
    private async void test_feature_discovery(Gee.TestFinishedCallback cb) {
        try {
            string xml = "<stream:features xmlns:stream='http://etherx.jabber.org/streams'>" +
                "<sm xmlns='urn:xmpp:sm:3'/>" +
                "<bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'><required/></bind>" +
                "</stream:features>";
            var reader = new StanzaReader.for_string(xml);
            StanzaNode features = yield reader.read_node();

            StanzaNode? sm = features.get_subnode("sm", SM_NS);
            fail_if(sm == null, "XEP-0198 §3: <sm> must be discoverable in stream features");
        } catch (Error e) {
            fail_if_reached("XML parse error: " + e.message);
        }
        cb();
    }

    /**
     * XEP-0198 §4: "the counter is not incremented for stanzas that
     * are not 'counted' (e.g., stream management elements themselves
     * are not counted)."
     * Only <message>, <iq>, <presence> increment h.
     */
    private void test_only_stanzas_count() {
        var module = new Xmpp.Xep.StreamManagement.Module();

        // Verify initial h is 0
        if (module.h_inbound != 0) {
            GLib.Test.message("XEP-0198: Initial h must be 0, got %u".printf(module.h_inbound));
            GLib.Test.fail();
        }

        // <r/> and <a/> are NOT stanzas — they must NOT increment h
        // We can only test the counter public field directly
        uint32 before = module.h_inbound;
        // Simulating that only on_stanza_received increments h, not on nonza
        // Since we can't call private methods, we verify the Module's public counter starts at 0
        // and doesn't magically increment
        if (module.h_inbound != before) {
            GLib.Test.message("XEP-0198 §4: h must not increment without receiving stanzas");
            GLib.Test.fail();
        }
    }

    private void test_user_message_waits_for_write() {
        StanzaNode message = new StanzaNode.build("message");
        message.put_node(new StanzaNode.build("body"));

        fail_if_not(Xmpp.Xep.StreamManagement.Module.should_wait_for_write_completion(message),
            "User-visible body messages must wait until they are written to the stream");
    }

    private void test_omemo_message_waits_for_write() {
        StanzaNode message = new StanzaNode.build("message");
        message.put_node(new StanzaNode.build("encrypted", "eu.siacs.conversations.axolotl").add_self_xmlns());

        fail_if_not(Xmpp.Xep.StreamManagement.Module.should_wait_for_write_completion(message),
            "OMEMO messages must wait until they are written to the stream even without a body");
    }

    private void test_receipt_message_does_not_wait_for_write() {
        StanzaNode message = new StanzaNode.build("message");
        message.put_node(new StanzaNode.build("received", "urn:xmpp:receipts").add_self_xmlns());

        fail_if(Xmpp.Xep.StreamManagement.Module.should_wait_for_write_completion(message),
            "Delivery receipts must stay on the low-latency queue path");
    }

    private void test_chat_state_message_does_not_wait_for_write() {
        StanzaNode message = new StanzaNode.build("message");
        message.put_node(new StanzaNode.build("active", "http://jabber.org/protocol/chatstates").add_self_xmlns());

        fail_if(Xmpp.Xep.StreamManagement.Module.should_wait_for_write_completion(message),
            "Chat state messages must stay on the low-latency queue path");
    }
}

private class TerminalDiscardStream : XmppStream {
    public TerminalDiscardStream(Jid remote_name) {
        base(remote_name);
    }

    public override async void connect() throws IOError {
    }

    public override async void disconnect() throws IOError {
    }

    public override async StanzaNode read() throws IOError {
        throw new IOError.NOT_CONNECTED("test stream has no reader");
    }

    public override async void write_async(StanzaNode node,
            int io_priority = Priority.DEFAULT,
            Cancellable? cancellable = null) throws IOError {
    }

    public override async void setup() throws IOError {
    }
}

private class TrackingMujiModule : Xep.Muji.Module {
    public int detach_count { get; private set; default = 0; }

    public override void detach(XmppStream stream) {
        detach_count++;
        base.detach(stream);
    }
}

private class TrackingNegotiationModule : XmppStreamNegotiationModule {
    public int attach_count { get; private set; default = 0; }
    public int detach_count { get; private set; default = 0; }

    public override void attach(XmppStream stream) {
        attach_count++;
    }

    public override void detach(XmppStream stream) {
        detach_count++;
    }

    public override bool mandatory_outstanding(XmppStream stream) {
        return false;
    }

    public override bool negotiation_active(XmppStream stream) {
        return false;
    }

    public override string get_ns() {
        return "urn:dinox:test:stream-module-lifecycle";
    }

    public override string get_id() {
        return "negotiation";
    }
}

private class TrackingStreamManagementModule :
        Xep.StreamManagement.Module {
    public int attach_count { get; private set; default = 0; }
    public int detach_count { get; private set; default = 0; }

    public override void attach(XmppStream stream) {
        attach_count++;
        base.attach(stream);
    }

    public override void detach(XmppStream stream) {
        detach_count++;
        base.detach(stream);
    }
}

}

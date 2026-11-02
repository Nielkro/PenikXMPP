namespace Xmpp.Test {

/**
 * Spec-based tests for XEP-0313 Message Archive Management.
 *
 * References:
 *   - XEP-0313 §3: Querying an archive
 *   - XEP-0313 §5: Querying an archive (IQ semantics)
 *   - XEP-0313 §5.3: <fin> element semantics
 *   - XEP-0059 (Result Set Management): <set>, <first>, <last>, <count>
 *   - XEP-0297 (Stanza Forwarding): <forwarded>
 *   - XEP-0203 (Delayed Delivery): <delay>
 */
class MAMTest : Gee.TestCase {

    private const string MAM_NS = "urn:xmpp:mam:2";
    private const string RSM_NS = "urn:xmpp:rsm";
    private const string FORWARD_NS = "urn:xmpp:forward:0";
    private const string DELAY_NS = "urn:xmpp:delay";
    private const string DATAFORMS_NS = "jabber:x:data";

    public MAMTest() {
        base("MAM");
        // XEP-0313 §3: Query construction
        add_test("XEP0313_query_namespace_is_mam2", test_query_namespace);
        add_test("XEP0313_query_must_carry_queryid", test_query_queryid);
        // XEP-0313 §5.3: <fin> semantics
        add_test("XEP0313_fin_complete_true", test_fin_complete);
        add_test("XEP0313_fin_absent_complete_means_incomplete", test_fin_incomplete);
        add_test("XEP0313_fin_rsm_first_last", test_fin_rsm_first_last);
        add_test("XEP0313_fin_missing_rsm_is_null", test_fin_missing_rsm);
        // XEP-0313 §4 + XEP-0297: Result wrapping
        add_async_test("XEP0313_parse_result_from_xml", (cb) => { test_parse_result_xml.begin(cb); });
        add_async_test("XEP0313_cancel_stops_IQ_waiter_and_query_results",
            (cb) => { test_cancelled_query_cleanup.begin(cb); });
        add_async_test("XEP0313_overlapping_pages_keep_queryid_active",
            (cb) => { test_overlapping_query_id_lifetime.begin(cb); });
        // XEP-0313 §4: MessageFlag data
        add_test("XEP0313_message_flag_fields", test_message_flag);
    }

    /**
     * XEP-0313 §3: Query element MUST be qualified by urn:xmpp:mam:2.
     */
    private void test_query_namespace() {
        StanzaNode query = new StanzaNode.build("query", MAM_NS).add_self_xmlns();
        fail_if_not_eq_str(query.ns_uri, MAM_NS);
        fail_if_not_eq_str(query.name, "query");
    }

    /**
     * XEP-0313 §3: "The <query/> element MAY contain a 'queryid' attribute."
     * When present, results reference it — verify it survives serialization.
     */
    private void test_query_queryid() {
        string qid = "unique-query-42";
        StanzaNode query = new StanzaNode.build("query", MAM_NS)
            .add_self_xmlns()
            .put_attribute("queryid", qid);

        string? retrieved = query.get_attribute("queryid");
        fail_if(retrieved == null, "XEP-0313: queryid attribute must be preserved");
        fail_if_not_eq_str(retrieved, qid);
    }

    /**
     * XEP-0313 §5.3: "If the MAM query has returned all ... results, the
     * complete attribute MUST be set to 'true'."
     */
    private void test_fin_complete() {
        StanzaNode fin = new StanzaNode.build("fin", MAM_NS)
            .add_self_xmlns()
            .put_attribute("complete", "true", MAM_NS)
            .put_node(
                new StanzaNode.build("set", RSM_NS).add_self_xmlns()
                    .put_node(new StanzaNode.build("first", RSM_NS).put_node(new StanzaNode.text("id-001")))
                    .put_node(new StanzaNode.build("last", RSM_NS).put_node(new StanzaNode.text("id-050")))
            );

        string? complete_str = fin.get_attribute("complete", MAM_NS);
        fail_if_not_eq_str(complete_str, "true");

        // XEP-0059: RSM <first> and <last> define the range of returned IDs
        StanzaNode? rsm = fin.get_subnode("set", RSM_NS);
        fail_if(rsm == null, "XEP-0059: RSM <set> must be present in <fin>");
        fail_if_not_eq_str(rsm.get_deep_string_content("first"), "id-001");
        fail_if_not_eq_str(rsm.get_deep_string_content("last"), "id-050");
    }

    /**
     * XEP-0313 §5.3: "If the 'complete' attribute is not included, or
     * its value is 'false', the client MUST assume that there are
     * additional results to be retrieved."
     */
    private void test_fin_incomplete() {
        StanzaNode fin = new StanzaNode.build("fin", MAM_NS).add_self_xmlns()
            .put_node(
                new StanzaNode.build("set", RSM_NS).add_self_xmlns()
                    .put_node(new StanzaNode.build("first", RSM_NS).put_node(new StanzaNode.text("a")))
                    .put_node(new StanzaNode.build("last", RSM_NS).put_node(new StanzaNode.text("z")))
            );

        bool complete = fin.get_attribute_bool("complete", false, MAM_NS);
        fail_if(complete, "XEP-0313 §5.3: Absent 'complete' attr MUST default to false (more results exist)");
    }

    /**
     * XEP-0059 §2.6: An empty <set/> (no <first>/<last>) indicates
     * zero results returned.
     */
    private void test_fin_rsm_first_last() {
        StanzaNode fin = new StanzaNode.build("fin", MAM_NS).add_self_xmlns()
            .put_node(new StanzaNode.build("set", RSM_NS).add_self_xmlns());

        StanzaNode? rsm = fin.get_subnode("set", RSM_NS);
        fail_if(rsm == null, "XEP-0059: RSM <set> must be present");

        string? first = rsm.get_deep_string_content("first");
        string? last = rsm.get_deep_string_content("last");
        fail_if(first != null, "XEP-0059: Empty RSM first must be null");
        fail_if(last != null, "XEP-0059: Empty RSM last must be null");
    }

    /**
     * XEP-0313: <fin> without RSM is possible but unusual.
     * Client must handle gracefully.
     */
    private void test_fin_missing_rsm() {
        StanzaNode fin = new StanzaNode.build("fin", MAM_NS).add_self_xmlns();
        StanzaNode? rsm = fin.get_subnode("set", RSM_NS);
        fail_if(rsm != null, "RSM should be null when not present");
    }

    /**
     * XEP-0313 §4 Example 2 + XEP-0297: MAM results are wrapped as:
     * <message>
     *   <result xmlns='urn:xmpp:mam:2' queryid='...' id='...'>
     *     <forwarded xmlns='urn:xmpp:forward:0'>
     *       <delay xmlns='urn:xmpp:delay' stamp='2010-07-10T23:08:25Z'/>
     *       <message from='...' to='...'><body>...</body></message>
     *     </forwarded>
     *   </result>
     * </message>
     *
     * Parse from real XML to verify XEP-0297 forwarding structure.
     */
    private async void test_parse_result_xml(Gee.TestFinishedCallback cb) {
        try {
            // Based on XEP-0313 Example 2 (simplified)
            string xml =
                "<result xmlns='urn:xmpp:mam:2' queryid='f27' id='28482-98726-73623'>" +
                  "<forwarded xmlns='urn:xmpp:forward:0'>" +
                    "<delay xmlns='urn:xmpp:delay' stamp='2010-07-10T23:08:25Z'/>" +
                    "<message xmlns='jabber:client' from='witch@shakespeare.lit' to='macbeth@shakespeare.lit'>" +
                      "<body>Hail to thee</body>" +
                    "</message>" +
                  "</forwarded>" +
                "</result>";

            var reader = new StanzaReader.for_string(xml);
            StanzaNode result = yield reader.read_node();

            // Verify result element
            fail_if_not_eq_str(result.name, "result");
            fail_if_not_eq_str(result.ns_uri, MAM_NS);

            string? qid = result.get_attribute("queryid", MAM_NS);
            if (qid == null) qid = result.get_attribute("queryid");
            fail_if(qid == null, "XEP-0313: <result> must have queryid");
            fail_if_not_eq_str(qid, "f27");

            string? mam_id = result.get_attribute("id", MAM_NS);
            if (mam_id == null) mam_id = result.get_attribute("id");
            fail_if(mam_id == null, "XEP-0313: <result> must have id");

            // Verify XEP-0297 forwarding structure
            StanzaNode? forwarded = result.get_subnode("forwarded", FORWARD_NS);
            fail_if(forwarded == null, "XEP-0297: <forwarded> must be present in <result>");

            // Verify XEP-0203 delay stamp
            StanzaNode? delay = forwarded.get_subnode("delay", DELAY_NS);
            fail_if(delay == null, "XEP-0203: <delay> must be present in <forwarded>");
            string? stamp = delay.get_attribute("stamp");
            if (stamp == null) stamp = delay.get_attribute("stamp", DELAY_NS);
            fail_if(stamp == null, "XEP-0203: delay must have 'stamp'");

            // Verify inner message
            StanzaNode? msg = forwarded.get_subnode("message", "jabber:client");
            if (msg == null) msg = forwarded.get_subnode("message");
            fail_if(msg == null, "XEP-0297: forwarded must contain inner <message>");
            fail_if_not_eq_str(msg.get_attribute("from"), "witch@shakespeare.lit");
        } catch (Error e) {
            fail_if_reached("XML parse error: " + e.message);
        }
        cb();
    }

    private async void test_cancelled_query_cleanup(
            Gee.TestFinishedCallback cb) {
        try {
            var stream = new MamCancellationStream(
                new Jid("example.test"));
            var iq_module = new Iq.Module();
            stream.add_module(iq_module);
            iq_module.attach(stream);

            var cancellable = new Cancellable();
            var parameters = new MessageArchiveManagement.V2.MamQueryParams
                .query_latest(new Jid("archive.example.test"), null, null);
            stream.cancel_on_write = cancellable;
            var cancellation = new MessageArchiveManagement
                .QueryCancellation(cancellable);
            MessageArchiveManagement.QueryResult result = yield
                MessageArchiveManagement.V2.query_archive(stream,
                    parameters, cancellation);

            fail_if(!result.error,
                "A cancelled MAM request must finish as an error");
            fail_if(stream.written_nodes.size != 1,
                "The cancellation audit must write exactly one archive IQ");
            fail_if(MessageArchiveManagement.Flag.get_flag(stream)
                    .active_query_ids.contains(parameters.query_id),
                "A cancelled MAM query id must be removed immediately");

            // A response racing in after cancellation must find no IQ waiter
            // and must not resurrect the archived-message acceptance window.
            stream.emit_late_result();
            while (MainContext.@default().pending()) {
                MainContext.@default().iteration(false);
            }
            fail_if(MessageArchiveManagement.Flag.get_flag(stream)
                    .active_query_ids.contains(parameters.query_id),
                "A late IQ result must not resurrect a cancelled MAM query");
        } catch (Error error) {
            fail_if_reached("Unexpected cancelled MAM query error: " +
                error.message);
        }
        cb();
    }

    private async void test_overlapping_query_id_lifetime(
            Gee.TestFinishedCallback cb) {
        try {
            var stream = new MamCancellationStream(
                new Jid("example.test"));
            var iq_module = new Iq.Module();
            stream.add_module(iq_module);
            iq_module.attach(stream);

            var first = new MessageArchiveManagement.V2.MamQueryParams
                .query_latest(new Jid("archive.example.test"), null, null);
            var second = new MessageArchiveManagement.V2.MamQueryParams
                .query_latest(new Jid("archive.example.test"), null, null);
            second.query_id = first.query_id;
            var first_cancellable = new Cancellable();
            var second_cancellable = new Cancellable();
            var first_cancellation = new MessageArchiveManagement
                .QueryCancellation(first_cancellable);
            var second_cancellation = new MessageArchiveManagement
                .QueryCancellation(second_cancellable);
            MessageArchiveManagement.QueryResult? first_result = null;
            MessageArchiveManagement.QueryResult? second_result = null;

            MessageArchiveManagement.V2.query_archive.begin(stream, first,
                first_cancellation, (obj, result) => {
                    first_result = MessageArchiveManagement.V2
                        .query_archive.end(result);
                });
            MessageArchiveManagement.V2.query_archive.begin(stream, second,
                second_cancellation, (obj, result) => {
                    second_result = MessageArchiveManagement.V2
                        .query_archive.end(result);
                });
            while (stream.written_nodes.size < 2) {
                Idle.add(test_overlapping_query_id_lifetime.callback);
                yield;
            }

            stream.emit_success_result(0);
            while (first_result == null) {
                Idle.add(test_overlapping_query_id_lifetime.callback);
                yield;
            }
            var low_barrier = new IdleSource();
            low_barrier.set_priority(Priority.LOW);
            low_barrier.set_callback(
                test_overlapping_query_id_lifetime.callback);
            low_barrier.attach(MainContext.ref_thread_default());
            yield;
            fail_if(!MessageArchiveManagement.Flag.get_flag(stream)
                    .active_query_ids.contains(first.query_id),
                "Finishing an older page must not deactivate an overlapping page with the same queryid");

            second_cancellable.cancel();
            while (second_result == null) {
                Idle.add(test_overlapping_query_id_lifetime.callback);
                yield;
            }
            fail_if(!((!) second_result).error,
                "The remaining overlapping page must observe cancellation");
            fail_if(MessageArchiveManagement.Flag.get_flag(stream)
                    .active_query_ids.contains(first.query_id),
                "The shared queryid must disappear after its final owner ends");
        } catch (Error error) {
            fail_if_reached("Unexpected overlapping MAM lifetime error: " +
                error.message);
        }
        cb();
    }

    /**
     * XEP-0313 §4: MessageFlag carries archive metadata.
     * Verify all required fields are preserved.
     */
    private void test_message_flag() {
        try {
            Jid sender = new Jid("archive@example.com");
            DateTime time = new DateTime.utc(2026, 2, 23, 10, 30, 0);
            var flag = new MessageArchiveManagement.MessageFlag(sender, time, "mam-id-1", "query-1");

            fail_if_not_eq_str(flag.sender_jid.to_string(), "archive@example.com");
            fail_if_not_eq_str(flag.mam_id, "mam-id-1");
            fail_if_not_eq_str(flag.query_id, "query-1");
            fail_if(flag.server_time == null, "XEP-0313: server_time must be preserved");
        } catch (InvalidJidError e) {
            fail_if_reached(@"JID error: $(e.message)");
        }
    }
}

private class MamCancellationStream : XmppStream {
    public Gee.ArrayList<StanzaNode> written_nodes =
        new Gee.ArrayList<StanzaNode>();
    public Cancellable? cancel_on_write { get; set; default = null; }

    public MamCancellationStream(Jid remote_name) {
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
        written_nodes.add(node);
        Idle.add(() => {
            if (cancel_on_write != null) ((!) cancel_on_write).cancel();
            return Source.REMOVE;
        });
    }

    public void emit_late_result() {
        if (written_nodes.is_empty) return;
        StanzaNode request = written_nodes[0];
        received_iq_stanza(this, new StanzaNode.build("iq", "jabber:client")
            .add_self_xmlns()
            .put_attribute("type", "result")
            .put_attribute("id", request.get_attribute("id")));
    }

    public void emit_success_result(int index) {
        if (index < 0 || index >= written_nodes.size) return;
        StanzaNode request = written_nodes[index];
        StanzaNode fin = new StanzaNode.build("fin",
                MessageArchiveManagement.NS_URI)
            .add_self_xmlns()
            .put_node(new StanzaNode.build("set",
                ResultSetManagement.NS_URI).add_self_xmlns());
        received_iq_stanza(this, new StanzaNode.build("iq", "jabber:client")
            .add_self_xmlns()
            .put_attribute("type", "result")
            .put_attribute("id", request.get_attribute("id"))
            .put_node(fin));
    }

    public override async void setup() throws IOError {
    }
}

}

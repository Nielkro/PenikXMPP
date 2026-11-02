using Xmpp;
using Xmpp.Xep;
using Gee;

/**
 * XEP-0313_2 (MAM v2 extensions) + XEP-0353 (Jingle Message Initiation) +
 * XEP-0425 (Message Moderation) audit tests.
 *
 * Tests MamQueryParams construction, JMI message node structure,
 * and moderation request structure.
 */
namespace Xmpp.Test {

class MamJmiModerationAudit : Gee.TestCase {
    private const string JMI_NS = "urn:xmpp:jingle-message:0";
    private const string MOD_NS = "urn:xmpp:message-moderate:1";
    private const string RETRACT_NS = "urn:xmpp:message-retract:1";

    public MamJmiModerationAudit() {
        base("MamJmiModAudit");
        // XEP-0313_2: MamQueryParams
        add_test("XEP0313v2_query_latest", test_mam_query_latest);
        add_test("XEP0313v2_query_between", test_mam_query_between);
        add_test("XEP0313v2_query_before", test_mam_query_before);
        add_test("XEP0313v2_query_id_unique", test_mam_query_id_unique);
        add_test("XEP0313v2_query_null_times", test_mam_query_null_times);
        add_test("XEP0313v2_ns2_extended_flag", test_mam_ns2_extended);
        // XEP-0353: JMI production codec and delivery semantics
        add_test("XEP0353_builder_action_matrix", test_jmi_builder_action_matrix);
        add_test("XEP0353_parser_action_matrix", test_jmi_parser_action_matrix);
        add_test("XEP0353_reason_tie_break_migration", test_jmi_reason_tie_break_migration);
        add_test("XEP0353_legacy_migrated_namespace", test_jmi_legacy_migrated_namespace);
        add_test("XEP0353_rejects_malformed", test_jmi_rejects_malformed);
        add_test("XEP0353_legacy_normal_type_tolerated", test_jmi_legacy_normal_type_tolerated);
        add_test("XEP0353_missing_store_is_noncanonical_but_accepted", test_jmi_missing_store_tolerated);
        add_test("XEP0353_delivery_classification", test_jmi_delivery_classification);
        add_test("XEP0353_delayed_delivery_classification",
            test_jmi_delayed_delivery_classification);
        add_test("XEP0353_delivery_priority",
            test_jmi_delivery_priority);
        add_async_test("XEP0353_forwarded_mam_and_carbon_semantics",
            (cb) => { test_jmi_forwarded_delivery_semantics.begin(cb); });
        add_test("XEP0353_ns_uri", test_jmi_ns_uri);
        add_test("XEP0353_accept_and_proceed_emit_distinct_signals", test_jmi_accept_proceed_distinct_signals);
        // XEP-0425: Moderation
        add_test("XEP0425_moderate_node_structure", test_mod_node_structure);
        add_test("XEP0425_moderate_ns_uri", test_mod_ns_uri);
        add_test("XEP0425_moderate_contains_retract", test_mod_contains_retract);
        add_test("XEP0425_moderate_message_id_attr", test_mod_message_id);
    }

    // ========== XEP-0313_2: MamQueryParams ==========

    private void test_mam_query_latest() {
        try {
            var server = new Jid("server.example.com");
            var start = new DateTime.utc(2025, 1, 1, 0, 0, 0);
            var params = new MessageArchiveManagement.V2.MamQueryParams.query_latest(server, start, "id-123");

            assert_true(params.mam_server.to_string() == "server.example.com");
            assert_nonnull(params.start);
            assert_true(params.start_id == "id-123");
            assert_null(params.end);
            assert_null(params.end_id);
            assert_nonnull(params.query_id);
        } catch (InvalidJidError e) {
            assert_not_reached();
        }
    }

    private void test_mam_query_between() {
        try {
            var server = new Jid("mam.example.com");
            var t1 = new DateTime.utc(2025, 1, 1, 0, 0, 0);
            var t2 = new DateTime.utc(2025, 6, 1, 0, 0, 0);
            var params = new MessageArchiveManagement.V2.MamQueryParams.query_between(
                server, t1, "start-id", t2, "end-id"
            );

            assert_true(params.start_id == "start-id");
            assert_true(params.end_id == "end-id");
            assert_nonnull(params.start);
            assert_nonnull(params.end);
        } catch (InvalidJidError e) {
            assert_not_reached();
        }
    }

    private void test_mam_query_before() {
        try {
            var server = new Jid("archive.example.com");
            var end_time = new DateTime.utc(2025, 3, 15, 12, 0, 0);
            var params = new MessageArchiveManagement.V2.MamQueryParams.query_before(
                server, end_time, "before-id"
            );

            assert_null(params.start);
            assert_null(params.start_id);
            assert_nonnull(params.end);
            assert_true(params.end_id == "before-id");
        } catch (InvalidJidError e) {
            assert_not_reached();
        }
    }

    private void test_mam_query_id_unique() {
        try {
            var server = new Jid("s.example.com");
            var p1 = new MessageArchiveManagement.V2.MamQueryParams.query_latest(server, null, null);
            var p2 = new MessageArchiveManagement.V2.MamQueryParams.query_latest(server, null, null);

            // Each query should have a unique ID
            assert_true(p1.query_id != p2.query_id);
        } catch (InvalidJidError e) {
            assert_not_reached();
        }
    }

    private void test_mam_query_null_times() {
        try {
            var server = new Jid("s.example.com");
            var params = new MessageArchiveManagement.V2.MamQueryParams.query_latest(server, null, null);

            assert_null(params.start);
            assert_null(params.start_id);
            assert_null(params.end);
            assert_null(params.end_id);
            assert_null(params.with);
        } catch (InvalidJidError e) {
            assert_not_reached();
        }
    }

    private void test_mam_ns2_extended() {
        try {
            var server = new Jid("s.example.com");
            var params = new MessageArchiveManagement.V2.MamQueryParams.query_latest(server, null, null);

            // Default is false
            assert_true(!params.use_ns2_extended);

            // Can be set
            params.use_ns2_extended = true;
            assert_true(params.use_ns2_extended);
        } catch (InvalidJidError e) {
            assert_not_reached();
        }
    }

    // ========== XEP-0353: JMI production codec ==========

    private void test_jmi_builder_action_matrix() {
        try {
            JingleMessageInitiation.Action[] actions = {
                JingleMessageInitiation.Action.PROPOSE,
                JingleMessageInitiation.Action.RINGING,
                JingleMessageInitiation.Action.RETRACT,
                JingleMessageInitiation.Action.LEGACY_ACCEPT,
                JingleMessageInitiation.Action.PROCEED,
                JingleMessageInitiation.Action.REJECT,
                JingleMessageInitiation.Action.FINISH
            };

            foreach (JingleMessageInitiation.Action action in actions) {
                MessageStanza message = build_canonical_jmi_message(
                    action, "builder-sid");
                StanzaNode? action_node = message.stanza.get_subnode(
                    jmi_action_name(action), JMI_NS);

                assert_true(message.type_ == MessageStanza.TYPE_CHAT);
                assert_nonnull(action_node);
                assert_true(((!) action_node).get_attribute("id") ==
                    "builder-sid");
                assert_nonnull(message.stanza.get_subnode("store",
                    "urn:xmpp:hints"));
                if (action == JingleMessageInitiation.Action.PROPOSE) {
                    assert_nonnull(((!) action_node).get_subnode(
                        "description", "urn:xmpp:jingle:apps:rtp:1"));
                }
            }
        } catch (Error e) {
            assert_not_reached();
        }
    }

    private void test_jmi_parser_action_matrix() {
        try {
            JingleMessageInitiation.Action[] actions = {
                JingleMessageInitiation.Action.PROPOSE,
                JingleMessageInitiation.Action.RINGING,
                JingleMessageInitiation.Action.RETRACT,
                JingleMessageInitiation.Action.LEGACY_ACCEPT,
                JingleMessageInitiation.Action.PROCEED,
                JingleMessageInitiation.Action.REJECT,
                JingleMessageInitiation.Action.FINISH
            };

            foreach (JingleMessageInitiation.Action action in actions) {
                JingleMessageInitiation.JmiEvent? parsed =
                    JingleMessageInitiation.Module.parse_message(
                        build_canonical_jmi_message(action, "parser-sid"));
                assert_nonnull(parsed);
                assert_true(((!) parsed).action == action);
                assert_true(((!) parsed).sid == "parser-sid");
                assert_true(((!) parsed).delivery ==
                    JingleMessageInitiation.Delivery.LIVE);
                assert_true(((!) parsed).has_store_hint);
            }
        } catch (Error e) {
            assert_not_reached();
        }
    }

    private void test_jmi_reason_tie_break_migration() {
        try {
            MessageStanza reject = JingleMessageInitiation.Module.build_message(
                new Jid("local@example.test/dinox"),
                JingleMessageInitiation.Action.REJECT, "rejected-sid", null,
                new JingleMessageInitiation.JmiReason(
                    Jingle.ReasonElement.EXPIRED, "Tie-Break"), true);
            set_incoming_addresses(reject);
            JingleMessageInitiation.JmiEvent? parsed_reject =
                JingleMessageInitiation.Module.parse_message(reject);

            assert_nonnull(parsed_reject);
            assert_true(((!) parsed_reject).tie_break);
            assert_nonnull(((!) parsed_reject).reason);
            assert_true(((!) ((!) parsed_reject).reason).condition ==
                Jingle.ReasonElement.EXPIRED);
            assert_true(((!) ((!) parsed_reject).reason).text == "Tie-Break");

            MessageStanza finish = JingleMessageInitiation.Module.build_message(
                new Jid("local@example.test/dinox"),
                JingleMessageInitiation.Action.FINISH, "old-sid", null,
                new JingleMessageInitiation.JmiReason(
                    Jingle.ReasonElement.EXPIRED, "Session migrated"),
                false, "new-sid");
            set_incoming_addresses(finish);
            JingleMessageInitiation.JmiEvent? parsed_finish =
                JingleMessageInitiation.Module.parse_message(finish);

            assert_nonnull(parsed_finish);
            assert_true(((!) parsed_finish).migrated_to_sid == "new-sid");
            assert_true(!((!) parsed_finish).legacy_migrated_namespace);
        } catch (Error e) {
            assert_not_reached();
        }
    }

    private void test_jmi_legacy_migrated_namespace() {
        try {
            MessageStanza finish = build_canonical_jmi_message(
                JingleMessageInitiation.Action.FINISH, "old-sid");
            StanzaNode? finish_node = finish.stanza.get_subnode("finish",
                JMI_NS);
            assert_nonnull(finish_node);
            ((!) finish_node).put_node(new StanzaNode.build("migrated",
                Jingle.NS_URI).put_attribute("to", "new-sid"));

            JingleMessageInitiation.JmiEvent? parsed =
                JingleMessageInitiation.Module.parse_message(finish);
            assert_nonnull(parsed);
            assert_true(((!) parsed).legacy_migrated_namespace);
            assert_true(((!) parsed).migrated_to_sid == "new-sid");
        } catch (Error e) {
            assert_not_reached();
        }
    }

    private void test_jmi_rejects_malformed() {
        try {
            MessageStanza wrong_type = build_canonical_jmi_message(
                JingleMessageInitiation.Action.PROPOSE, "wrong-type");
            wrong_type.type_ = MessageStanza.TYPE_GROUPCHAT;
            assert_null(JingleMessageInitiation.Module.parse_message(
                wrong_type));

            MessageStanza duplicate = build_canonical_jmi_message(
                JingleMessageInitiation.Action.PROPOSE, "duplicate");
            duplicate.stanza.put_node(new StanzaNode.build("ringing", JMI_NS)
                .add_self_xmlns().put_attribute("id", "duplicate", JMI_NS));
            assert_null(JingleMessageInitiation.Module.parse_message(
                duplicate));

            MessageStanza no_descriptions =
                JingleMessageInitiation.Module.build_message(
                    new Jid("local@example.test/dinox"),
                    JingleMessageInitiation.Action.PROPOSE,
                    "no-descriptions");
            set_incoming_addresses(no_descriptions);
            assert_null(JingleMessageInitiation.Module.parse_message(
                no_descriptions));

            MessageStanza blank_sid = new MessageStanza() {
                type_ = MessageStanza.TYPE_CHAT
            };
            set_incoming_addresses(blank_sid);
            blank_sid.stanza.put_node(new StanzaNode.build("ringing", JMI_NS)
                .add_self_xmlns().put_attribute("id", "  ", JMI_NS));
            assert_null(JingleMessageInitiation.Module.parse_message(
                blank_sid));

            MessageStanza reason_on_proceed =
                JingleMessageInitiation.Module.build_message(
                    new Jid("local@example.test/dinox"),
                    JingleMessageInitiation.Action.PROCEED, "bad-reason",
                    null, new JingleMessageInitiation.JmiReason(
                        Jingle.ReasonElement.SUCCESS));
            set_incoming_addresses(reason_on_proceed);
            assert_null(JingleMessageInitiation.Module.parse_message(
                reason_on_proceed));

            MessageStanza migrated_reject =
                JingleMessageInitiation.Module.build_message(
                    new Jid("local@example.test/dinox"),
                    JingleMessageInitiation.Action.REJECT, "bad-migration",
                    null, null, false, "new-sid");
            set_incoming_addresses(migrated_reject);
            assert_null(JingleMessageInitiation.Module.parse_message(
                migrated_reject));

            MessageStanza unknown_reason = build_canonical_jmi_message(
                JingleMessageInitiation.Action.REJECT, "unknown-reason");
            StanzaNode? reject_node = unknown_reason.stanza.get_subnode(
                "reject", JMI_NS);
            assert_nonnull(reject_node);
            ((!) reject_node).put_node(new StanzaNode.build("reason",
                Jingle.NS_URI).add_self_xmlns().put_node(
                    new StanzaNode.build("made-up-condition",
                        Jingle.NS_URI)));
            assert_null(JingleMessageInitiation.Module.parse_message(
                unknown_reason));
        } catch (Error e) {
            assert_not_reached();
        }
    }

    private void test_jmi_legacy_normal_type_tolerated() {
        try {
            MessageStanza omitted_type = build_canonical_jmi_message(
                JingleMessageInitiation.Action.PROPOSE, "omitted-type");
            StanzaAttribute? type_attribute =
                omitted_type.stanza.get_attribute_raw("type");
            assert_nonnull(type_attribute);
            omitted_type.stanza.attributes.remove((!) type_attribute);
            assert_true(omitted_type.type_ == MessageStanza.TYPE_NORMAL);
            assert_nonnull(JingleMessageInitiation.Module.parse_message(
                omitted_type));

            MessageStanza explicit_normal = build_canonical_jmi_message(
                JingleMessageInitiation.Action.PROPOSE, "normal-type");
            explicit_normal.type_ = MessageStanza.TYPE_NORMAL;
            assert_nonnull(JingleMessageInitiation.Module.parse_message(
                explicit_normal));

            MessageStanza headline = build_canonical_jmi_message(
                JingleMessageInitiation.Action.PROPOSE, "headline-type");
            headline.type_ = MessageStanza.TYPE_HEADLINE;
            assert_null(JingleMessageInitiation.Module.parse_message(
                headline));
        } catch (Error e) {
            assert_not_reached();
        }
    }

    private void test_jmi_missing_store_tolerated() {
        try {
            MessageStanza message = build_canonical_jmi_message(
                JingleMessageInitiation.Action.RINGING, "old-client-sid");
            StanzaNode? store = message.stanza.get_subnode("store",
                "urn:xmpp:hints");
            assert_nonnull(store);
            message.stanza.sub_nodes.remove((!) store);

            JingleMessageInitiation.JmiEvent? parsed =
                JingleMessageInitiation.Module.parse_message(message);
            assert_nonnull(parsed);
            assert_true(!((!) parsed).has_store_hint);
        } catch (Error e) {
            assert_not_reached();
        }
    }

    private void test_jmi_delivery_classification() {
        try {
            MessageStanza carbon = build_canonical_jmi_message(
                JingleMessageInitiation.Action.RINGING, "carbon-sid");
            carbon.add_flag(new MessageCarbons.MessageFlag(
                MessageCarbons.MessageFlag.TYPE_RECEIVED));
            JingleMessageInitiation.JmiEvent? parsed_carbon =
                JingleMessageInitiation.Module.parse_message(carbon);
            assert_nonnull(parsed_carbon);
            assert_true(((!) parsed_carbon).delivery ==
                JingleMessageInitiation.Delivery.CARBON_RECEIVED);

            MessageStanza sent_carbon = build_canonical_jmi_message(
                JingleMessageInitiation.Action.RINGING, "sent-carbon-sid");
            sent_carbon.add_flag(new MessageCarbons.MessageFlag(
                MessageCarbons.MessageFlag.TYPE_SENT));
            JingleMessageInitiation.JmiEvent? parsed_sent_carbon =
                JingleMessageInitiation.Module.parse_message(sent_carbon);
            assert_nonnull(parsed_sent_carbon);
            assert_true(((!) parsed_sent_carbon).delivery ==
                JingleMessageInitiation.Delivery.CARBON_SENT);

            DateTime archived_at = new DateTime.utc(2026, 8, 26, 1, 2, 3);
            MessageStanza mam = build_canonical_jmi_message(
                JingleMessageInitiation.Action.RINGING, "mam-sid");
            mam.add_flag(new MessageArchiveManagement.MessageFlag(
                new Jid("local@example.test"), archived_at, "mam-id",
                "query-id"));
            JingleMessageInitiation.JmiEvent? parsed_mam =
                JingleMessageInitiation.Module.parse_message(mam);
            assert_nonnull(parsed_mam);
            assert_true(((!) parsed_mam).delivery ==
                JingleMessageInitiation.Delivery.MAM);
            assert_nonnull(((!) parsed_mam).timestamp);
        } catch (Error e) {
            assert_not_reached();
        }
    }

    private void test_jmi_delayed_delivery_classification() {
        try {
            DateTime delayed_at = new DateTime.utc(2026, 8, 26, 2, 3, 4);
            MessageStanza delayed = build_canonical_jmi_message(
                JingleMessageInitiation.Action.RINGING, "delayed-sid");
            delayed.add_flag(new DelayedDelivery.MessageFlag(delayed_at));

            JingleMessageInitiation.JmiEvent? parsed =
                JingleMessageInitiation.Module.parse_message(delayed);
            assert_nonnull(parsed);
            assert_true(((!) parsed).delivery ==
                JingleMessageInitiation.Delivery.DELAYED);
            assert_nonnull(((!) parsed).timestamp);
            DateTime parsed_timestamp = (!) ((!) parsed).timestamp;
            assert_true(parsed_timestamp.compare(delayed_at) == 0);
        } catch (Error e) {
            assert_not_reached();
        }
    }

    private void test_jmi_delivery_priority() {
        try {
            DateTime delayed_at = new DateTime.utc(2026, 8, 26, 2, 3, 4);
            DateTime archived_at = new DateTime.utc(2026, 8, 26, 5, 6, 7);

            MessageStanza mam = build_canonical_jmi_message(
                JingleMessageInitiation.Action.RINGING, "priority-mam-sid");
            mam.add_flag(new DelayedDelivery.MessageFlag(delayed_at));
            mam.add_flag(new MessageCarbons.MessageFlag(
                MessageCarbons.MessageFlag.TYPE_RECEIVED));
            mam.add_flag(new MessageArchiveManagement.MessageFlag(
                new Jid("local@example.test"), archived_at, "priority-mam-id",
                "priority-query-id"));

            JingleMessageInitiation.JmiEvent? parsed_mam =
                JingleMessageInitiation.Module.parse_message(mam);
            assert_nonnull(parsed_mam);
            assert_true(((!) parsed_mam).delivery ==
                JingleMessageInitiation.Delivery.MAM);
            assert_nonnull(((!) parsed_mam).timestamp);
            DateTime parsed_mam_timestamp = (!) ((!) parsed_mam).timestamp;
            assert_true(parsed_mam_timestamp.compare(archived_at) == 0);

            MessageStanza carbon = build_canonical_jmi_message(
                JingleMessageInitiation.Action.RINGING,
                "priority-carbon-sid");
            carbon.add_flag(new DelayedDelivery.MessageFlag(delayed_at));
            carbon.add_flag(new MessageCarbons.MessageFlag(
                MessageCarbons.MessageFlag.TYPE_SENT));

            JingleMessageInitiation.JmiEvent? parsed_carbon =
                JingleMessageInitiation.Module.parse_message(carbon);
            assert_nonnull(parsed_carbon);
            assert_true(((!) parsed_carbon).delivery ==
                JingleMessageInitiation.Delivery.CARBON_SENT);
            assert_null(((!) parsed_carbon).timestamp);
        } catch (Error e) {
            assert_not_reached();
        }
    }

    private async void test_jmi_forwarded_delivery_semantics(
            Gee.TestFinishedCallback cb) {
        try {
            var stream = create_forwarding_jmi_stream();
            var message_module = (!) stream.get_module<MessageModule>(
                MessageModule.IDENTITY);
            var jmi = (!) stream.get_module<JingleMessageInitiation.Module>(
                JingleMessageInitiation.Module.IDENTITY);
            int event_count = 0;
            int proposed_count = 0;
            JingleMessageInitiation.Delivery? delivery = null;
            string? sid = null;

            jmi.event_received.connect((bound_stream, event) => {
                event_count++;
                delivery = event.delivery;
                sid = event.sid;
            });
            jmi.session_proposed.connect((from, to, sid, descriptions) => {
                proposed_count++;
            });

            MessageArchiveManagement.Flag.get_flag(stream)
                .active_query_ids.add("query-id");
            yield message_module.received_message_stanza_async(stream,
                build_mam_envelope(
                    build_forwarded_jmi_message("archived-sid"),
                    "query-id", "mam-1"));

            assert_true(event_count == 1);
            assert_true(proposed_count == 0);
            assert_true(delivery == JingleMessageInitiation.Delivery.MAM);
            assert_true(sid == "archived-sid");

            yield message_module.received_message_stanza_async(stream,
                build_carbon_envelope(
                    build_forwarded_jmi_message("carbon-sid")));

            assert_true(event_count == 2);
            assert_true(proposed_count == 1);
            assert_true(delivery ==
                JingleMessageInitiation.Delivery.CARBON_RECEIVED);
            assert_true(sid == "carbon-sid");

            yield message_module.received_message_stanza_async(stream,
                build_mam_envelope(
                    build_carbon_envelope(
                        build_forwarded_jmi_message("nested-sid")),
                    "query-id", "mam-2"));

            assert_true(event_count == 3);
            assert_true(proposed_count == 1);
            assert_true(delivery == JingleMessageInitiation.Delivery.MAM);
            assert_true(sid == "nested-sid");

            MessageStanza delayed = new MessageStanza.from_stanza(
                build_forwarded_jmi_message("delayed-forwarded-sid"),
                new Jid("local@example.test/dinox"));
            DelayedDelivery.Module.set_message_delay(delayed,
                new DateTime.utc(2026, 8, 26, 6, 7, 8));
            yield message_module.received_message_stanza_async(stream,
                delayed.stanza);

            assert_true(event_count == 4);
            assert_true(proposed_count == 1);
            assert_true(delivery ==
                JingleMessageInitiation.Delivery.DELAYED);
            assert_true(sid == "delayed-forwarded-sid");
        } catch (Error e) {
            assert_not_reached();
        }
        cb();
    }

    private void test_jmi_ns_uri() {
        assert_true(JingleMessageInitiation.NS_URI == "urn:xmpp:jingle-message:0");
    }

    private void test_jmi_accept_proceed_distinct_signals() {
        try {
            var stream = create_attached_jmi_stream();
            var jmi = (!) stream.get_module<JingleMessageInitiation.Module>(JingleMessageInitiation.Module.IDENTITY);

            int accepted_count = 0;
            int proceeded_count = 0;
            string? accepted_sid = null;
            string? proceeded_sid = null;

            jmi.session_accepted.connect((from, to, sid) => {
                accepted_count++;
                accepted_sid = sid;
            });
            jmi.session_proceeded.connect((from, to, sid) => {
                proceeded_count++;
                proceeded_sid = sid;
            });

            stream.emit_message(build_jmi_message("accept", "accept-sid"));
            drain_main_context();
            assert_true(accepted_count == 1);
            assert_true(proceeded_count == 0);
            assert_true(accepted_sid == "accept-sid");

            stream.emit_message(build_jmi_message("proceed", "proceed-sid"));
            drain_main_context();
            assert_true(accepted_count == 1);
            assert_true(proceeded_count == 1);
            assert_true(proceeded_sid == "proceed-sid");
        } catch (Error e) {
            assert_not_reached();
        }
    }

    // ========== XEP-0425: Moderation ==========

    private void test_mod_node_structure() {
        // Build a moderation IQ set as the module would
        var moderate = new StanzaNode.build("moderate", MOD_NS)
            .add_self_xmlns()
            .put_attribute("id", "msg-to-moderate")
            .put_node(new StanzaNode.build("retract", RETRACT_NS).add_self_xmlns());

        assert_true(moderate.name == "moderate");
        assert_true(moderate.get_attribute("id") == "msg-to-moderate");

        StanzaNode? retract = moderate.get_subnode("retract", RETRACT_NS);
        assert_nonnull(retract);
    }

    private void test_mod_ns_uri() {
        assert_true(MessageModeration.NS_URI == "urn:xmpp:message-moderate:1");
    }

    private void test_mod_contains_retract() {
        // The moderate stanza must contain a <retract/> child per XEP-0425
        var moderate = new StanzaNode.build("moderate", MOD_NS)
            .add_self_xmlns()
            .put_attribute("id", "test-msg");

        // Without retract — incomplete
        StanzaNode? no_retract = moderate.get_subnode("retract", RETRACT_NS);
        assert_null(no_retract);

        // Add retract
        moderate.put_node(new StanzaNode.build("retract", RETRACT_NS).add_self_xmlns());
        StanzaNode? has_retract = moderate.get_subnode("retract", RETRACT_NS);
        assert_nonnull(has_retract);
    }

    private void test_mod_message_id() {
        // Verify message_id attribute is required and correctly set
        var moderate = new StanzaNode.build("moderate", MOD_NS)
            .add_self_xmlns();
        // No id attribute
        assert_null(moderate.get_attribute("id"));

        moderate.put_attribute("id", "target-message-123");
        assert_true(moderate.get_attribute("id") == "target-message-123");
    }

    private JmiAuditStream create_attached_jmi_stream() throws Error {
        var stream = new JmiAuditStream(new Jid("example.test"));

        var bind_flag = new Bind.Flag();
        bind_flag.my_jid = new Jid("local@example.test/dinox");
        stream.add_flag(bind_flag);

        var iq = new Iq.Module();
        stream.add_module(iq);
        iq.attach(stream);

        var service_discovery = new ServiceDiscovery.Module.with_identity("client", "pc", "DinoX test");
        stream.add_module(service_discovery);
        service_discovery.attach(stream);

        var message = new MessageModule();
        stream.add_module(message);
        message.attach(stream);

        var jmi = new JingleMessageInitiation.Module();
        stream.add_module(jmi);
        jmi.attach(stream);

        return stream;
    }

    private JmiAuditStream create_forwarding_jmi_stream() throws Error {
        JmiAuditStream stream = create_attached_jmi_stream();

        var mam = new MessageArchiveManagement.Module();
        stream.add_module(mam);
        mam.attach(stream);

        var carbons = new MessageCarbons.Module();
        stream.add_module(carbons);
        carbons.attach(stream);

        var delayed = new DelayedDelivery.Module();
        stream.add_module(delayed);
        delayed.attach(stream);

        return stream;
    }

    private StanzaNode build_forwarded_jmi_message(string sid) {
        return new StanzaNode.build("message", "jabber:client")
            .put_attribute("from", "peer@example.test/phone")
            .put_attribute("to", "local@example.test/dinox")
            .put_attribute("type", MessageStanza.TYPE_CHAT)
            .put_node(new StanzaNode.build("propose", JMI_NS)
                .add_self_xmlns().put_attribute("id", sid, JMI_NS)
                .put_node(new StanzaNode.build("description",
                    "urn:xmpp:jingle:apps:rtp:1").add_self_xmlns()
                        .put_attribute("media", "audio")))
            .put_node(new StanzaNode.build("store", "urn:xmpp:hints")
                .add_self_xmlns());
    }

    private StanzaNode build_carbon_envelope(StanzaNode inner_message) {
        return new StanzaNode.build("message", "jabber:client")
            .put_attribute("from", "local@example.test")
            .put_attribute("to", "local@example.test/dinox")
            .put_node(new StanzaNode.build("received",
                "urn:xmpp:carbons:2").add_self_xmlns()
                .put_node(new StanzaNode.build("forwarded",
                    "urn:xmpp:forward:0").add_self_xmlns()
                    .put_node(inner_message)));
    }

    private StanzaNode build_mam_envelope(StanzaNode inner_message,
            string query_id, string mam_id) {
        return new StanzaNode.build("message", "jabber:client")
            .put_attribute("from", "local@example.test")
            .put_attribute("to", "local@example.test/dinox")
            .put_node(new StanzaNode.build("result",
                MessageArchiveManagement.NS_URI).add_self_xmlns()
                .put_attribute("queryid", query_id)
                .put_attribute("id", mam_id)
                .put_node(new StanzaNode.build("forwarded",
                    "urn:xmpp:forward:0").add_self_xmlns()
                    .put_node(new StanzaNode.build("delay",
                        DelayedDelivery.NS_URI).add_self_xmlns()
                        .put_attribute("stamp", "2026-08-26T01:02:03Z"))
                    .put_node(inner_message)));
    }

    private MessageStanza build_canonical_jmi_message(
            JingleMessageInitiation.Action action, string sid) throws Error {
        ArrayList<StanzaNode>? descriptions = null;
        if (action == JingleMessageInitiation.Action.PROPOSE) {
            descriptions = new ArrayList<StanzaNode>();
            descriptions.add(new StanzaNode.build("description",
                "urn:xmpp:jingle:apps:rtp:1").add_self_xmlns()
                    .put_attribute("media", "audio"));
        }

        MessageStanza message = JingleMessageInitiation.Module.build_message(
            new Jid("local@example.test/dinox"), action, sid,
            descriptions);
        set_incoming_addresses(message);
        return message;
    }

    private void set_incoming_addresses(MessageStanza message) throws Error {
        message.from = new Jid("peer@example.test/phone");
        message.to = new Jid("local@example.test/dinox");
    }

    private string jmi_action_name(JingleMessageInitiation.Action action) {
        switch (action) {
            case JingleMessageInitiation.Action.PROPOSE: return "propose";
            case JingleMessageInitiation.Action.RINGING: return "ringing";
            case JingleMessageInitiation.Action.RETRACT: return "retract";
            case JingleMessageInitiation.Action.LEGACY_ACCEPT: return "accept";
            case JingleMessageInitiation.Action.PROCEED: return "proceed";
            case JingleMessageInitiation.Action.REJECT: return "reject";
            case JingleMessageInitiation.Action.FINISH: return "finish";
        }
        assert_not_reached();
    }

    private StanzaNode build_jmi_message(string action, string sid) {
        return new StanzaNode.build("message", "jabber:client")
            .put_attribute("from", "peer@example.test/phone")
            .put_attribute("to", "local@example.test/dinox")
            .put_attribute("type", MessageStanza.TYPE_CHAT)
            .put_node(new StanzaNode.build(action, JMI_NS).add_self_xmlns().put_attribute("id", sid, JMI_NS));
    }

    private void drain_main_context() {
        MainContext context = MainContext.default();
        while (context.pending()) {
            context.iteration(false);
        }
    }
}

private class JmiAuditStream : XmppStream {
    public JmiAuditStream(Jid remote_name) {
        base(remote_name);
    }

    public void emit_message(StanzaNode node) {
        received_message_stanza(this, node);
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

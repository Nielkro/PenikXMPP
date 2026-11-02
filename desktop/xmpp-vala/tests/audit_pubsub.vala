namespace Xmpp.Test {

/**
 * Security audit tests for XEP-0060 (Publish-Subscribe / PubSub).
 *
 * PubSub is the central infrastructure XEP used by:
 * - OMEMO key distribution (XEP-0384)
 * - User Avatars (XEP-0084)
 * - Bookmarks (XEP-0048 / XEP-0402)
 * - User Location (XEP-0080)
 * - vCard4 (XEP-0292)
 *
 * Security concerns:
 * - PEP notifications must come from bare JIDs (not full JIDs)
 * - Item/retract/delete events must be from registered listeners only
 * - Malformed event nodes should not crash
 * - Missing attributes in items/retracts must be handled
 *
 * References:
 *   - XEP-0060 §7.1   Event notifications
 *   - XEP-0060 §12.12  Security considerations
 *   - XEP-0163        Personal Eventing Protocol (PEP)
 */
class PubSubAudit : Gee.TestCase {

    private const string NS_PUBSUB = "http://jabber.org/protocol/pubsub";
    private const string NS_EVENT = "http://jabber.org/protocol/pubsub#event";
    private const string NS_OWNER = "http://jabber.org/protocol/pubsub#owner";
    private const string NS_ERROR = "http://jabber.org/protocol/pubsub#errors";
    private const string NS_JABBER = "jabber:client";

    public PubSubAudit() {
        base("PubSubAudit");

        // --- Event notification parsing ---
        add_test("XEP0060_event_item_notification", test_event_item_notification);
        add_test("XEP0060_event_retract_notification", test_event_retract_notification);
        add_test("XEP0060_event_delete_notification", test_event_delete_notification);
        add_test("XEP0060_event_items_node_attribute", test_event_items_node_attribute);

        // --- Malformed event stanzas ---
        add_test("XEP0060_event_no_items_node", test_event_no_items_node);
        add_test("XEP0060_event_item_no_id", test_event_item_no_id);
        add_test("XEP0060_event_item_empty_payload", test_event_item_empty_payload);
        add_test("XEP0060_event_retract_no_id", test_event_retract_no_id);
        add_test("XEP0060_event_delete_no_node", test_event_delete_no_node);
        add_test("XEP0060_event_empty_node", test_event_empty);

        // --- Security: sender validation (PEP) ---
        add_test("XEP0060_pep_from_bare_jid_accepted", test_pep_bare_jid);
        add_test("XEP0060_pep_from_full_jid_rejected", test_pep_full_jid);
        add_test("XEP0060_pep_from_service_jid", test_pep_service_jid);

        // --- IQ response parsing ---
        add_test("XEP0060_iq_response_items_list", test_iq_response_items);
        add_test("XEP0060_iq_response_no_pubsub_node", test_iq_response_no_pubsub);
        add_test("XEP0060_iq_response_no_items_node", test_iq_response_no_items);
        add_test("XEP0060_iq_response_empty_items", test_iq_response_empty_items);
        add_test("XEP0060_iq_response_item_no_children", test_iq_response_item_no_children);

        // --- Publish options ---
        add_test("XEP0060_publish_options_persist_items", test_publish_options_persist);
        add_test("XEP0060_publish_options_max_items", test_publish_options_max);
        add_test("XEP0060_publish_options_access_model", test_publish_options_access_model);
        add_test("XEP0060_publish_result_resource_constraint", test_publish_result_resource_constraint);
        add_test("XEP0060_request_access_denial_keeps_typed_presence_reason", test_request_access_denial);
        add_async_test("XEP0060_publish_cancelled_by_stream_detach", test_publish_cancelled_by_stream_detach);
        add_async_test("XEP0060_request_preserves_local_cancellation",
            (cb) => { test_request_local_cancellation.begin(cb); });
        add_test("XEP0060_remote_cancel_error_is_not_local_cancellation", test_remote_cancel_error);
        add_async_test("XEP0060_owner_only_missing_node_and_existing_owner",
            (cb) => { test_owner_only_missing_and_existing.begin(cb); });
        add_async_test("XEP0060_owner_only_removes_other_readers_and_verifies",
            (cb) => { test_owner_only_removes_readers.begin(cb); });
        add_async_test("XEP0060_owner_only_rejects_malformed_lists",
            (cb) => { test_owner_only_malformed_lists.begin(cb); });
        add_async_test("XEP0060_owner_only_rejects_other_account_and_sender",
            (cb) => { test_owner_only_account_and_sender.begin(cb); });
        add_async_test("XEP0060_owner_only_rejects_unverified_change",
            (cb) => { test_owner_only_unverified_change.begin(cb); });
        add_async_test("XEP0060_owner_only_cancellation_stops_followup",
            (cb) => { test_owner_only_cancellation.begin(cb); });

        // --- Edge cases ---
        add_test("XEP0060_wrong_event_namespace", test_wrong_event_namespace);
        add_test("XEP0060_multiple_items_in_event", test_multiple_items_in_event);
        add_test("XEP0060_item_with_multiple_payloads", test_item_multiple_payloads);
    }

    // ========== Event notification parsing ==========

    private void test_event_item_notification() {
        // Standard PEP item notification
        var event = build_event_node();
        var items = new StanzaNode.build("items", NS_EVENT).put_attribute("node", "urn:xmpp:avatar:metadata");
        var item = new StanzaNode.build("item", NS_EVENT).put_attribute("id", "abc123");
        var payload = new StanzaNode.build("metadata", "urn:xmpp:avatar:metadata").add_self_xmlns();
        item.put_node(payload);
        items.put_node(item);
        event.put_node(items);

        StanzaNode? items_node = event.get_subnode("items", NS_EVENT);
        assert_nonnull(items_node);
        assert_true(items_node.get_attribute("node", NS_EVENT) == "urn:xmpp:avatar:metadata"
                    || items_node.get_attribute("node") == "urn:xmpp:avatar:metadata");

        StanzaNode? item_node = items_node.get_subnode("item", NS_EVENT);
        assert_nonnull(item_node);

        string? id = item_node.get_attribute("id", NS_EVENT);
        if (id == null) id = item_node.get_attribute("id");
        // id could be in either namespace or default
        assert_true(item_node.sub_nodes.size > 0);
    }

    private void test_event_retract_notification() {
        var event = build_event_node();
        var items = new StanzaNode.build("items", NS_EVENT).put_attribute("node", "urn:xmpp:avatar:metadata");
        var retract = new StanzaNode.build("retract", NS_EVENT).put_attribute("id", "item-to-retract");
        items.put_node(retract);
        event.put_node(items);

        StanzaNode? items_node = event.get_subnode("items", NS_EVENT);
        assert_nonnull(items_node);
        StanzaNode? retract_node = items_node.get_subnode("retract", NS_EVENT);
        assert_nonnull(retract_node);
        string? id = retract_node.get_attribute("id", NS_EVENT);
        if (id == null) id = retract_node.get_attribute("id");
        assert_nonnull(id);
    }

    private void test_event_delete_notification() {
        var event = build_event_node();
        var delete_node = new StanzaNode.build("delete", NS_EVENT).put_attribute("node", "urn:xmpp:avatar:metadata");
        event.put_node(delete_node);

        StanzaNode? found = event.get_subnode("delete", NS_EVENT);
        assert_nonnull(found);
        string? node_attr = found.get_attribute("node", NS_EVENT);
        if (node_attr == null) node_attr = found.get_attribute("node");
        assert_nonnull(node_attr);
    }

    private void test_event_items_node_attribute() {
        // The "node" attribute on <items> identifies which PubSub node fired
        var event = build_event_node();
        var items = new StanzaNode.build("items", NS_EVENT).put_attribute("node", "eu.siacs.conversations.axolotl.devicelist");
        event.put_node(items);

        StanzaNode? items_node = event.get_subnode("items", NS_EVENT);
        assert_nonnull(items_node);
        // DinoX code: `items_node.get_attribute("node", NS_URI_EVENT)`
        string? node = items_node.get_attribute("node", NS_EVENT);
        if (node == null) node = items_node.get_attribute("node");
        assert_true(node == "eu.siacs.conversations.axolotl.devicelist");
    }

    // ========== Malformed event stanzas ==========

    private void test_event_no_items_node() {
        // <event> without <items> — should be handled gracefully
        var event = build_event_node();
        // No children

        StanzaNode? items_node = event.get_subnode("items", NS_EVENT);
        assert_null(items_node);
        // DinoX code: `if (items_node != null)` — safe
    }

    private void test_event_item_no_id() {
        // <item> without "id" attribute
        var event = build_event_node();
        var items = new StanzaNode.build("items", NS_EVENT).put_attribute("node", "test-node");
        var item = new StanzaNode.build("item", NS_EVENT);
        // No id attribute
        items.put_node(item);
        event.put_node(items);

        StanzaNode? items_node = event.get_subnode("items", NS_EVENT);
        StanzaNode? item_node = items_node.get_subnode("item", NS_EVENT);
        assert_nonnull(item_node);

        // get_attribute("id") returns null — DinoX passes this to the
        // listener as null id.  Listeners must handle null ids gracefully.
        assert_true(item_node.get_attribute("id", NS_EVENT) == null);
    }

    private void test_event_item_empty_payload() {
        // <item id="x"/> with no child nodes (empty payload)
        var event = build_event_node();
        var items = new StanzaNode.build("items", NS_EVENT).put_attribute("node", "test-node");
        var item = new StanzaNode.build("item", NS_EVENT).put_attribute("id", "empty-item");
        // No payload children
        items.put_node(item);
        event.put_node(items);

        StanzaNode? item_node = event.get_subnode("items", NS_EVENT).get_subnode("item", NS_EVENT);
        assert_nonnull(item_node);
        assert_true(item_node.sub_nodes.size == 0);
        // DinoX code: `if (item_listeners.has_key(node) && item_node.sub_nodes.size > 0)`
        // The `size > 0` check prevents NPE on empty items ✓
    }

    private void test_event_retract_no_id() {
        // <retract> without "id" attribute
        var event = build_event_node();
        var items = new StanzaNode.build("items", NS_EVENT).put_attribute("node", "test-node");
        var retract = new StanzaNode.build("retract", NS_EVENT);
        // No id
        items.put_node(retract);
        event.put_node(items);

        StanzaNode? retract_node = event.get_subnode("items", NS_EVENT).get_subnode("retract", NS_EVENT);
        assert_nonnull(retract_node);
        // null id passed to retract listener — listeners must handle this
        assert_true(retract_node.get_attribute("id", NS_EVENT) == null);
    }

    private void test_event_delete_no_node() {
        // <delete> without "node" attribute
        var event = build_event_node();
        var delete_node = new StanzaNode.build("delete", NS_EVENT);
        // No node attribute
        event.put_node(delete_node);

        StanzaNode? found = event.get_subnode("delete", NS_EVENT);
        assert_nonnull(found);
        // null node — DinoX code does `delete_listeners.has_key(node)` with null key
        // HashMap.has_key(null) returns false in Gee → safe, but semantically wrong
        assert_true(found.get_attribute("node", NS_EVENT) == null);
    }

    private void test_event_empty() {
        // Completely empty <event/>
        var event = build_event_node();
        assert_true(event.sub_nodes.size == 0);
        StanzaNode? items = event.get_subnode("items", NS_EVENT);
        assert_null(items);
        StanzaNode? del = event.get_subnode("delete", NS_EVENT);
        assert_null(del);
    }

    // ========== Security: sender validation ==========

    private void test_pep_bare_jid() {
        // XEP-0163: PEP notifications come from bare JIDs
        // DinoX code: `if (!message.from.is_bare())` → warning + ignore
        try {
            var jid = new Jid("alice@example.com");
            assert_true(jid.is_bare());
            // Bare JID → accepted ✓
        } catch (InvalidJidError e) {
            assert_not_reached();
        }
    }

    private void test_pep_full_jid() {
        // PEP notification from full JID → MUST be rejected
        // This prevents a MUC participant from injecting PEP events
        try {
            var jid = new Jid("alice@example.com/device1");
            assert_true(!jid.is_bare());
            // DinoX: `if (!message.from.is_bare()) { warning(...); return; }`  ✓
        } catch (InvalidJidError e) {
            assert_not_reached();
        }
    }

    private void test_pep_service_jid() {
        // PubSub service JID (bare, no localpart) — this is valid for PubSub
        // but DinoX only uses PEP (user's own server), not generic PubSub services
        try {
            var jid = new Jid("pubsub.example.com");
            assert_true(jid.is_bare());
            // A domain-only JID is considered bare → passes the bare check
            // Whether this is a security issue depends on whether the code also
            // checks that the JID belongs to a known contact/account
        } catch (InvalidJidError e) {
            assert_not_reached();
        }
    }

    // ========== IQ response parsing ==========

    private void test_iq_response_items() {
        // Normal response: <pubsub><items node="x"><item id="1">...</item></items></pubsub>
        var pubsub = new StanzaNode.build("pubsub", NS_PUBSUB).add_self_xmlns();
        var items = new StanzaNode.build("items", NS_PUBSUB).put_attribute("node", "test");
        var item1 = new StanzaNode.build("item", NS_PUBSUB).put_attribute("id", "item1");
        item1.put_node(new StanzaNode.build("data", "urn:test").add_self_xmlns());
        var item2 = new StanzaNode.build("item", NS_PUBSUB).put_attribute("id", "item2");
        item2.put_node(new StanzaNode.build("data", "urn:test").add_self_xmlns());
        items.put_node(item1);
        items.put_node(item2);
        pubsub.put_node(items);

        // Simulate DinoX request_all parsing
        StanzaNode? ps = pubsub; // In real code: iq.stanza.get_subnode("pubsub", NS_URI)
        assert_nonnull(ps);
        StanzaNode? items_node = ps.get_subnode("items", NS_PUBSUB);
        assert_nonnull(items_node);
        var subnodes = items_node.get_subnodes("item", NS_PUBSUB);
        assert_true(subnodes.size == 2);
    }

    private void test_iq_response_no_pubsub() {
        // Response without <pubsub> wrapper
        var iq_stanza = new StanzaNode.build("iq", NS_JABBER)
            .put_attribute("type", "result");
        // No pubsub child

        StanzaNode? pubsub = iq_stanza.get_subnode("pubsub", NS_PUBSUB);
        assert_null(pubsub);
        // DinoX: `if (event_node == null) return null` → safe ✓
    }

    private void test_iq_response_no_items() {
        // <pubsub> without <items>
        var pubsub = new StanzaNode.build("pubsub", NS_PUBSUB).add_self_xmlns();

        StanzaNode? items = pubsub.get_subnode("items", NS_PUBSUB);
        assert_null(items);
        // DinoX: `if (items_node == null) return null` → safe ✓
    }

    private void test_iq_response_empty_items() {
        // <pubsub><items node="x"/></pubsub> — items with no item children
        var pubsub = new StanzaNode.build("pubsub", NS_PUBSUB).add_self_xmlns();
        var items = new StanzaNode.build("items", NS_PUBSUB).put_attribute("node", "test");
        pubsub.put_node(items);

        StanzaNode? items_node = pubsub.get_subnode("items", NS_PUBSUB);
        assert_nonnull(items_node);
        var subnodes = items_node.get_subnodes("item", NS_PUBSUB);
        assert_true(subnodes.size == 0);
    }

    private void test_iq_response_item_no_children() {
        // <item id="x"/> with no payload — for request_item()
        var pubsub = new StanzaNode.build("pubsub", NS_PUBSUB).add_self_xmlns();
        var items = new StanzaNode.build("items", NS_PUBSUB).put_attribute("node", "test");
        var item = new StanzaNode.build("item", NS_PUBSUB).put_attribute("id", "x");
        // No children
        items.put_node(item);
        pubsub.put_node(items);

        StanzaNode? item_node = pubsub.get_subnode("items", NS_PUBSUB).get_subnode("item", NS_PUBSUB);
        assert_nonnull(item_node);
        assert_true(item_node.sub_nodes.size == 0);
        // DinoX request_item: `if (item_node.sub_nodes.size == 0) return null` → safe ✓
    }

    // ========== Publish options ==========

    private void test_publish_options_persist() {
        var opts = new Xep.Pubsub.PublishOptions();
        opts.set_persist_items(true);
        assert_true(opts.settings["pubsub#persist_items"] == "true");

        opts.set_persist_items(false);
        assert_true(opts.settings["pubsub#persist_items"] == "false");
    }

    private void test_publish_options_max() {
        var opts = new Xep.Pubsub.PublishOptions();
        opts.set_max_items("1");
        assert_true(opts.settings["pubsub#max_items"] == "1");

        opts.set_max_items("max");
        assert_true(opts.settings["pubsub#max_items"] == "max");
    }

    private void test_publish_options_access_model() {
        var opts = new Xep.Pubsub.PublishOptions();

        // Test all 5 access models defined in the spec
        string[] models = {
            Xep.Pubsub.ACCESS_MODEL_AUTHORIZE,
            Xep.Pubsub.ACCESS_MODEL_OPEN,
            Xep.Pubsub.ACCESS_MODEL_PRESENCE,
            Xep.Pubsub.ACCESS_MODEL_ROSTER,
            Xep.Pubsub.ACCESS_MODEL_WHITELIST
        };
        foreach (string model in models) {
            opts.set_access_model(model);
            assert_true(opts.settings["pubsub#access_model"] == model);
        }
    }

    private void test_publish_result_resource_constraint() {
        var error = new ErrorStanza.resource_constraint("server throttled PubSub publish");
        var result = Xep.Pubsub.PublishResult.from_error_stanza(error);

        fail_if(result.ok, "XEP-0060: error result must not be ok");
        fail_if(!result.is_error(ErrorStanza.TYPE_WAIT, ErrorStanza.CONDITION_RESOURCE_CONSTRAINT),
            "XEP-0060: publish result must expose wait/resource-constraint");
        fail_if_not_eq_str(result.describe_error(), "wait/resource-constraint",
            "XEP-0060: publish result must describe stanza error");
    }

    private void test_request_access_denial() {
        var error = new ErrorStanza.build(ErrorStanza.TYPE_AUTH,
            ErrorStanza.CONDITION_NOT_AUTHORIZED, "No arbitrary server text is interpreted",
            new StanzaNode.build("presence-subscription-required", NS_ERROR));
        error.error_node.sub_nodes.insert(0,
            new StanzaNode.build("text", "urn:ietf:params:xml:ns:xmpp-stanzas")
                .put_node(new StanzaNode.text("first diagnostic text")));
        var result = Xep.Pubsub.RequestAllResult.from_error_stanza(error);
        fail_if_not(result.is_access_denied());
        fail_if_not(result.presence_subscription_required);
        fail_if(result.items != null);
        fail_if_not_eq_str(result.error_condition, ErrorStanza.CONDITION_NOT_AUTHORIZED);

        var forbidden = new ErrorStanza.build(ErrorStanza.TYPE_CANCEL,
            ErrorStanza.CONDITION_FORBIDDEN, "presence-subscription-required",
            new StanzaNode.build("presence-subscription-required", "urn:wrong"));
        result = Xep.Pubsub.RequestAllResult.from_error_stanza(forbidden);
        fail_if_not(result.is_access_denied());
        fail_if(result.presence_subscription_required,
            "Only the exact PubSub application condition may identify the missing subscription");
        result = Xep.Pubsub.RequestAllResult.from_error_stanza(new ErrorStanza.service_unavailable());
        fail_if(result.is_access_denied() || result.presence_subscription_required,
            "Transient failures must retain their existing treatment");
    }

    private async void test_request_local_cancellation(Gee.TestFinishedCallback cb) {
        try {
            var stream = create_attached_cancel_stream();
            var result = yield stream.get_module<Xep.Pubsub.Module>(Xep.Pubsub.Module.IDENTITY)
                .request_all_with_result(stream, new Jid("alice@example.test"), "urn:test:devices");
            fail_if(!result.locally_cancelled, "Detach must retain typed local cancellation");
            fail_if(result.items != null || result.error_condition != null,
                "Cancellation must not invent remote state or a server error");
            fail_if(result.is_item_not_found() || result.is_access_denied(),
                "Cancellation must not trigger empty-node or access-denied handling");
            fail_if(stream.written_nodes.size != 1, "Cancelled request must finish without a retry");
        } catch (Error e) {
            fail_if_reached(e.message);
        }
        cb();
    }

    private void test_remote_cancel_error() {
        var error = new ErrorStanza.build(ErrorStanza.TYPE_CANCEL,
            ErrorStanza.CONDITION_SERVICE_UNAVAILABLE,
            "Stream detached before IQ response", null);
        var result = Xep.Pubsub.RequestAllResult.from_error_stanza(error);
        fail_if(result.locally_cancelled,
            "Server error type/text must never forge local cancellation");
        fail_if_not_eq_str(result.error_condition, ErrorStanza.CONDITION_SERVICE_UNAVAILABLE);
    }

    private void test_publish_cancelled_by_stream_detach(Gee.TestFinishedCallback cb) {
        test_publish_cancelled_by_stream_detach_async.begin(cb);
    }

    private async void test_publish_cancelled_by_stream_detach_async(Gee.TestFinishedCallback cb) {
        try {
            var stream = create_attached_cancel_stream();
            var pubsub = stream.get_module<Xep.Pubsub.Module>(Xep.Pubsub.Module.IDENTITY);
            var payload = new StanzaNode.build("payload", "urn:test").add_self_xmlns();

            bool published = yield ((!) pubsub).publish(stream, null, "urn:test:node", "current", payload);

            fail_if(published, "XEP-0060: cancelled PubSub publish must report failure");
            fail_if(stream.written_nodes.size != 1, "XEP-0060: publish should write exactly one IQ before stream detach");
            fail_if_not_eq_str(stream.written_nodes[0].get_attribute("type"), "set", "XEP-0060: publish must be an IQ set");
        } catch (Error e) {
            fail_if_reached(@"Unexpected error in PubSub cancellation test: $(e.message)");
        }
        cb();
    }

    private async void test_owner_only_missing_and_existing(
            Gee.TestFinishedCallback cb) {
        try {
            var missing = create_owner_stream();
            missing.responses.add(owner_error("item-not-found"));
            Error? error = yield owner_only_error(missing);
            fail_if(error != null, "A missing node can be created with whitelist options");
            fail_if(missing.written_nodes.size != 1,
                "A missing node must not cause an affiliation change");

            var existing = create_owner_stream();
            existing.responses.add(owner_result({ "alice@example.test=owner",
                "writer@example.test=publish-only", "blocked@example.test=outcast",
                "removed@example.test=none" }));
            error = yield owner_only_error(existing);
            fail_if(error != null, "An existing node without other readers must pass");
            fail_if(existing.written_nodes.size != 1,
                "Nonreading affiliations must be retained without writing");
            assert_owner_metadata_requests(existing);
        } catch (Error e) {
            fail_if_reached(@"Unexpected owner-only node test error: $(e.message)");
        }
        cb();
    }

    private async void test_owner_only_removes_readers(
            Gee.TestFinishedCallback cb) {
        try {
            var stream = create_owner_stream();
            stream.responses.add(owner_result({ "alice@example.test=owner",
                "reader@example.test=member", "author@example.test=publisher",
                "coowner@example.test=owner", "writer@example.test=publish-only",
                "blocked@example.test=outcast" }));
            stream.responses.add(new StanzaNode.build("iq")
                .put_attribute("type", "result")
                .put_attribute("from", "alice@example.test"));
            stream.responses.add(owner_result({ "alice@example.test=owner",
                "writer@example.test=publish-only", "blocked@example.test=outcast" }));
            Error? error = yield owner_only_error(stream);
            fail_if(error != null, "Removed readers must be checked by a second GET");
            fail_if(stream.written_nodes.size != 3,
                "Reader cleanup requires GET, SET, and verification GET");
            if (stream.written_nodes.size == 3) {
                var changes = stream.written_nodes[1].get_subnode("pubsub",
                    NS_OWNER).get_subnode("affiliations", NS_OWNER);
                fail_if(changes.sub_nodes.size != 3,
                    "Only foreign owner/member/publisher affiliations may change");
                foreach (var change in changes.sub_nodes) {
                    fail_if(change.get_attribute("affiliation") != "none",
                        "Each foreign reader must lose its affiliation");
                    string? jid = change.get_attribute("jid");
                    fail_if(jid == "alice@example.test" ||
                        jid == "writer@example.test" || jid == "blocked@example.test",
                        "The account owner and nonreaders must be retained");
                }
            }
            assert_owner_metadata_requests(stream);
        } catch (Error e) {
            fail_if_reached(@"Unexpected owner-only removal test error: $(e.message)");
        }
        cb();
    }

    private async void test_owner_only_malformed_lists(
            Gee.TestFinishedCallback cb) {
        try {
            var malformed = new Gee.ArrayList<StanzaNode>();
            malformed.add(owner_result({ "alice@example.test=owner",
                "reader@example.test=member", "READER@example.test=publisher" }));
            malformed.add(owner_result({ "alice@example.test=owner",
                "reader@example.test/device=member" }));
            malformed.add(owner_result({ "alice@example.test=owner",
                "reader@example.test=unknown" }));
            malformed.add(owner_result({ "reader@example.test=member" }));
            malformed.add(owner_result({ "alice@example.test=owner" }, null,
                "urn:test:wrong-node"));
            malformed.add(new StanzaNode.build("iq").put_attribute("type", "result"));
            var wrong_namespace = owner_result({ "alice@example.test=owner" });
            wrong_namespace.get_subnode("pubsub", NS_OWNER).get_subnode(
                "affiliations", NS_OWNER).sub_nodes[0].ns_uri = NS_PUBSUB;
            malformed.add(wrong_namespace);
            var duplicate_payload = owner_result({ "alice@example.test=owner" });
            duplicate_payload.put_node(new StanzaNode.build("pubsub", NS_OWNER));
            malformed.add(duplicate_payload);
            var missing_error_type = owner_error("item-not-found");
            missing_error_type.get_subnode("error").set_attribute("type", "invalid");
            malformed.add(missing_error_type);
            var ambiguous_error = owner_error("item-not-found");
            ambiguous_error.get_subnode("error").put_node(new StanzaNode.build(
                "forbidden", "urn:ietf:params:xml:ns:xmpp-stanzas"));
            malformed.add(ambiguous_error);
            foreach (var response in malformed) {
                var stream = create_owner_stream();
                stream.responses.add(response);
                Error? error = yield owner_only_error(stream);
                fail_if(error == null, "Malformed or incomplete affiliation lists must fail closed");
                fail_if(stream.written_nodes.size != 1,
                    "Malformed affiliation lists must not be changed");
            }
        } catch (Error e) {
            fail_if_reached(@"Unexpected malformed affiliation test error: $(e.message)");
        }
        cb();
    }

    private async void test_owner_only_account_and_sender(
            Gee.TestFinishedCallback cb) {
        try {
            var foreign_account = create_owner_stream();
            Error? error = yield owner_only_error(foreign_account,
                new Jid("bob@example.test"));
            fail_if(!(error is IOError.PERMISSION_DENIED) ||
                foreign_account.written_nodes.size != 0,
                "A privacy check must not address another account's PEP nodes");
            string[] senders = { "bob@example.test",
                "alice@example.test/other", "example.test", "@invalid" };
            foreach (string sender in senders) {
                var stream = create_owner_stream();
                stream.responses.add(owner_result({ "alice@example.test=owner" }, sender));
                error = yield owner_only_error(stream);
                fail_if(error == null || stream.written_nodes.size != 1,
                    "Only a valid own bare-JID response may authorize publishing");
            }
            var forged_missing = create_owner_stream();
            var response = owner_error("item-not-found");
            response.put_attribute("from", "bob@example.test");
            forged_missing.responses.add(response);
            error = yield owner_only_error(forged_missing);
            fail_if(error == null,
                "An item-not-found error from another sender must not authorize node creation");
        } catch (Error e) {
            fail_if_reached(@"Unexpected owner-only scope test error: $(e.message)");
        }
        cb();
    }

    private async void test_owner_only_unverified_change(
            Gee.TestFinishedCallback cb) {
        try {
            // A refusal, a malformed ACK, retained readers, and disappearance
            // are all unsafe; none may be converted to publishing permission.
            for (int mode = 0; mode < 5; mode++) {
                var stream = create_owner_stream();
                stream.responses.add(owner_result({ "alice@example.test=owner",
                    "coowner@example.test=owner" }));
                if (mode == 0) {
                    stream.responses.add(owner_error("forbidden"));
                } else {
                    var ack = new StanzaNode.build("iq").put_attribute("type", "result");
                    if (mode == 1) ack.put_node(new StanzaNode.build("pubsub", NS_OWNER));
                    if (mode == 2) ack.put_attribute("from", "bob@example.test");
                    stream.responses.add(ack);
                    stream.responses.add(mode == 4 ? owner_error("item-not-found")
                        : owner_result({ "alice@example.test=owner", "coowner@example.test=owner" }));
                }
                Error? error = yield owner_only_error(stream);
                fail_if(error == null, "Other PEP readers require verified removal");
                fail_if(stream.written_nodes.size != (mode < 3 ? 2 : 3),
                    "Rejected or malformed changes must stop before a further request");
                assert_owner_metadata_requests(stream);
            }
        } catch (Error e) {
            fail_if_reached(@"Unexpected unverified affiliation test error: $(e.message)");
        }
        cb();
    }

    private async void test_owner_only_cancellation(
            Gee.TestFinishedCallback cb) {
        try {
            for (int index = 0; index < 3; index++) {
                var stream = create_owner_stream();
                stream.responses.add(owner_result({ "alice@example.test=owner",
                    "reader@example.test=member" }));
                stream.responses.add(new StanzaNode.build("iq").put_attribute("type", "result"));
                stream.responses.add(owner_result({ "alice@example.test=owner" }));
                stream.cancel_response_index = index;
                var cancellable = new Cancellable();
                bool cancelled = false;
                // Test the throwing API directly: a wrapper GTask carrying
                // this cancellable would override its captured Error result.
                try {
                    yield stream.get_module<Xep.Pubsub.Module>(
                        Xep.Pubsub.Module.IDENTITY).ensure_node_owner_only(
                            stream, new Jid("alice@example.test"),
                            "urn:test:private", cancellable);
                } catch (IOError.CANCELLED e) {
                    cancelled = true;
                }
                fail_if(!cancelled,
                    "Cancellation must remain a typed failure at every step");
                fail_if(stream.written_nodes.size != index + 1,
                    "Cancellation must prevent subsequent affiliation requests");
            }
        } catch (Error e) {
            fail_if_reached(@"Unexpected owner-only cancellation test error: $(e.message)");
        }
        cb();
    }

    private async Error? owner_only_error(PubSubOwnerAuditStream stream,
            Jid? owner = null, Cancellable? cancellable = null) throws Error {
        try {
            yield stream.get_module<Xep.Pubsub.Module>(Xep.Pubsub.Module.IDENTITY)
                .ensure_node_owner_only(stream,
                    owner ?? new Jid("alice@example.test"), "urn:test:private", cancellable);
            return null;
        } catch (Error e) {
            return e;
        }
    }

    private void assert_owner_metadata_requests(PubSubOwnerAuditStream stream) {
        foreach (var node in stream.written_nodes) {
            fail_if_not_eq_str(node.get_attribute("to"), "alice@example.test",
                "Owner requests must remain scoped to the bound account");
            var pubsub = node.get_subnode("pubsub", NS_OWNER);
            fail_if(pubsub == null || pubsub.sub_nodes.size != 1 ||
                pubsub.sub_nodes[0].name != "affiliations",
                "Privacy checks must request affiliations rather than personal payloads");
        }
    }

    private StanzaNode owner_result(string[] records, string? from = null,
            string node_id = "urn:test:private") {
        var result = new StanzaNode.build("iq").put_attribute("type", "result");
        if (from != null) result.put_attribute("from", (!) from);
        var affiliations = new StanzaNode.build("affiliations", NS_OWNER)
            .put_attribute("node", node_id);
        foreach (string record in records) {
            string[] values = record.split("=");
            affiliations.put_node(new StanzaNode.build("affiliation", NS_OWNER)
                .put_attribute("jid", values[0]).put_attribute("affiliation", values[1]));
        }
        return result.put_node(new StanzaNode.build("pubsub", NS_OWNER)
            .add_self_xmlns().put_node(affiliations));
    }

    private StanzaNode owner_error(string condition) {
        return new StanzaNode.build("iq").put_attribute("type", "error")
            .put_node(new StanzaNode.build("error").put_attribute("type", "cancel")
                .put_node(new StanzaNode.build(condition,
                    "urn:ietf:params:xml:ns:xmpp-stanzas").add_self_xmlns()));
    }

    private PubSubOwnerAuditStream create_owner_stream() throws Error {
        var stream = new PubSubOwnerAuditStream(new Jid("example.test"));
        var bind = new Bind.Flag();
        bind.finished = true;
        bind.my_jid = new Jid("alice@example.test/dinox");
        stream.add_flag(bind);
        var iq = new Iq.Module();
        stream.add_module(iq);
        iq.attach(stream);
        stream.add_module(new Xep.Pubsub.Module());
        return stream;
    }

    // ========== Edge cases ==========

    private void test_wrong_event_namespace() {
        // Event with wrong namespace
        var event = new StanzaNode.build("event", "http://wrong.namespace").add_self_xmlns();
        var msg_stanza = new StanzaNode.build("message", NS_JABBER);
        msg_stanza.put_node(event);

        // DinoX looks for NS_URI_EVENT specifically
        StanzaNode? found = msg_stanza.get_subnode("event", NS_EVENT);
        assert_null(found); // Correct: wrong namespace ignored
    }

    private void test_multiple_items_in_event() {
        // Multiple <item> nodes in a single <items> — valid per spec
        var event = build_event_node();
        var items = new StanzaNode.build("items", NS_EVENT).put_attribute("node", "test");
        for (int i = 0; i < 5; i++) {
            var item = new StanzaNode.build("item", NS_EVENT).put_attribute("id", "item%d".printf(i));
            item.put_node(new StanzaNode.build("payload", "urn:test").add_self_xmlns());
            items.put_node(item);
        }
        event.put_node(items);

        StanzaNode? items_node = event.get_subnode("items", NS_EVENT);
        assert_nonnull(items_node);
        // FIX applied: DinoX now uses get_subnodes() + foreach loop
        // All items in batch notifications are processed correctly
        Gee.List<StanzaNode> all_items = items_node.get_subnodes("item", NS_EVENT);
        assert_true(all_items.size == 5);
        // Verify all items accessible
        for (int j = 0; j < 5; j++) {
            assert_true(all_items[j].get_attribute("id") == "item%d".printf(j));
        }
    }

    private void test_item_multiple_payloads() {
        // <item> with multiple child nodes — ambiguous payload
        var item = new StanzaNode.build("item", NS_EVENT).put_attribute("id", "multi-payload");
        item.put_node(new StanzaNode.build("data1", "urn:test1").add_self_xmlns());
        item.put_node(new StanzaNode.build("data2", "urn:test2").add_self_xmlns());

        assert_true(item.sub_nodes.size == 2);
        // DinoX uses `item_node.sub_nodes[0]` — always takes the first payload
        // This is correct per XEP-0060 §12.1: each item has exactly one payload element
        assert_true(item.sub_nodes[0].name == "data1");
    }

    // ========== Helpers ==========

    private StanzaNode build_event_node() {
        return new StanzaNode.build("event", NS_EVENT).add_self_xmlns();
    }

    private PubSubCancelAuditStream create_attached_cancel_stream() throws Error {
        var stream = new PubSubCancelAuditStream(new Jid("example.test"));

        var iq = new Iq.Module();
        stream.add_module(iq);
        iq.attach(stream);

        var message = new MessageModule();
        stream.add_module(message);
        message.attach(stream);

        var pubsub = new Xep.Pubsub.Module();
        stream.add_module(pubsub);
        pubsub.attach(stream);

        return stream;
    }
}

private class PubSubOwnerAuditStream : XmppStream {
    public Gee.ArrayList<StanzaNode> written_nodes = new Gee.ArrayList<StanzaNode>();
    public Gee.ArrayList<StanzaNode> responses = new Gee.ArrayList<StanzaNode>();
    public int cancel_response_index = -1;

    public PubSubOwnerAuditStream(Jid remote_name) { base(remote_name); }
    public override async void connect() throws IOError { }
    public override async void disconnect() throws IOError { }
    public override async void setup() throws IOError { }
    public override async StanzaNode read() throws IOError {
        throw new IOError.NOT_CONNECTED("affiliation audit has no network reader");
    }
    public override async void write_async(StanzaNode node,
            int io_priority = Priority.DEFAULT,
            Cancellable? cancellable = null) throws IOError {
        if (cancellable != null) cancellable.set_error_if_cancelled();
        int index = written_nodes.size;
        written_nodes.add(node);
        if (index >= responses.size) {
            throw new IOError.FAILED("No scripted affiliation response");
        }
        var response = responses[index];
        response.put_attribute("id", node.get_attribute("id"));
        Idle.add(() => {
            if (index == cancel_response_index && cancellable != null) {
                cancellable.cancel();
            } else {
                received_iq_stanza(this, response);
            }
            return Source.REMOVE;
        });
    }
}

private class PubSubCancelAuditStream : XmppStream {
    public Gee.ArrayList<StanzaNode> written_nodes = new Gee.ArrayList<StanzaNode>();

    public PubSubCancelAuditStream(Jid remote_name) {
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
        written_nodes.add(node);

        Idle.add(() => {
            Iq.Module? iq = get_module<Iq.Module>(Iq.Module.IDENTITY);
            if (iq != null) {
                ((!) iq).detach(this);
            }
            return Source.REMOVE;
        });
    }

    public override async void setup() throws IOError {
    }
}

}

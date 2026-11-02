using Gee;

namespace Xmpp.Test {

/**
 * Phase 10 — Malformed Stanza Tests
 *
 * Tests every public XEP parser that processes untrusted network input
 * with malformed, empty, or missing-attribute stanzas.
 * Ensures graceful null returns or default values instead of crashes.
 *
 * Covers (parsers that had NO tests before):
 *   - XEP-0004 DataForms.create_from_node (9 tests)
 *   - XEP-0184 MessageDeliveryReceipts parsing (5 tests)
 *   - XEP-0333 ChatMarkers parsing and send pipeline (12 tests)
 *   - XEP-0359 UniqueStableStanzaIDs get_origin_id/get_stanza_id (6 tests)
 *   - XEP-0421 OccupantIds.get_occupant_id (4 tests)
 *   - XEP-0444 Reactions stanza parsing (4 tests)
 *   - XEP-0446 FileMetadataElement.get_file_metadata (8 tests)
 *   - XEP-0461 Replies.get_reply_to / set_reply_to (6 tests)
 */
class MalformedStanzaAudit : Gee.TestCase {

    public MalformedStanzaAudit() {
        base("MalformedStanzaAudit");

        // --- XEP-0004 Data Forms ---
        add_test("XEP0004_empty_x_node", test_df_empty_x);
        add_test("XEP0004_no_fields", test_df_no_fields);
        add_test("XEP0004_field_missing_type", test_df_field_missing_type);
        add_test("XEP0004_field_unknown_type", test_df_field_unknown_type);
        add_test("XEP0004_hidden_field_form_type", test_df_hidden_form_type);
        add_test("XEP0004_boolean_field_true_literal", test_df_boolean_true_literal);
        add_test("XEP0004_boolean_field_bad_value", test_df_boolean_bad_value);
        add_test("XEP0004_field_value_get_set", test_df_field_value_roundtrip);
        add_test("XEP0004_title_and_instructions", test_df_title_instructions);
        add_test("XEP0004_items_with_fields", test_df_items);

        // --- XEP-0184 Message Delivery Receipts ---
        add_test("XEP0184_requests_receipt_with_request", test_receipts_has_request);
        add_test("XEP0184_requests_receipt_without_request", test_receipts_no_request);
        add_test("XEP0184_requests_receipt_wrong_ns", test_receipts_wrong_ns);
        add_test("XEP0184_received_id_is_opaque", test_receipts_received_id_opaque);
        add_test("XEP0184_ambiguous_control_is_rejected",
            test_receipts_ambiguous_control_rejected);
        add_async_test("XEP0184_pipeline_requests_body_chat_once", (cb) => {
            test_receipts_pipeline_requests_body_chat_once.begin(cb);
        });
        add_async_test("XEP0184_and_XEP0333_pipeline_coexist", (cb) => {
            test_receipts_and_markers_pipeline_coexist.begin(cb);
        });

        // --- XEP-0333 Chat Markers ---
        add_test("XEP0333_requests_marking_with_markable", test_markers_has_markable);
        add_test("XEP0333_requests_marking_without_markable", test_markers_no_markable);
        add_test("XEP0333_requests_marking_wrong_ns", test_markers_wrong_ns);
        add_test("XEP0333_duplicate_markable_is_rejected",
            test_markers_duplicate_markable);
        add_test("XEP0333_control_stanza_is_not_markable",
            test_markers_control_stanza_not_markable);
        add_test("XEP0333_displayed_roundtrip", test_markers_displayed_roundtrip);
        add_test("XEP0333_displayed_id_is_opaque", test_markers_displayed_id_opaque);
        add_test("XEP0333_displayed_missing_id", test_markers_displayed_missing_id);
        add_test("XEP0333_displayed_empty_id", test_markers_displayed_empty_id);
        add_test("XEP0333_displayed_wrong_ns", test_markers_displayed_wrong_ns);
        add_test("XEP0333_ambiguous_marker_is_rejected",
            test_markers_ambiguous_marker_rejected);
        add_async_test("XEP0333_pipeline_preserves_existing_markable", (cb) => {
            test_markers_pipeline_preserves_markable.begin(cb);
        });
        add_async_test("XEP0333_pipeline_marks_body_chat_once", (cb) => {
            test_markers_pipeline_marks_body_chat_once.begin(cb);
        });
        add_async_test("XEP0333_pipeline_marks_body_groupchat_once", (cb) => {
            test_markers_pipeline_marks_body_groupchat_once.begin(cb);
        });
        add_async_test("XEP0333_pipeline_skips_control_stanzas", (cb) => {
            test_markers_pipeline_skips_control_stanzas.begin(cb);
        });

        // --- XEP-0359 Unique Stable Stanza IDs ---
        add_test("XEP0359_origin_id_present", test_sid_origin_present);
        add_test("XEP0359_origin_id_missing", test_sid_origin_missing);
        add_test("XEP0359_origin_id_no_id_attr", test_sid_origin_no_attr);
        add_test("XEP0359_stanza_id_matching_by", test_sid_stanza_match);
        add_test("XEP0359_stanza_id_wrong_by", test_sid_stanza_wrong_by);
        add_test("XEP0359_stanza_id_no_by_attr", test_sid_stanza_no_by);
        add_test("XEP0359_duplicate_authority_is_rejected",
            test_sid_duplicate_authority);

        // --- XEP-0421 Occupant IDs ---
        add_test("XEP0421_occupant_id_present", test_occid_present);
        add_test("XEP0421_occupant_id_missing", test_occid_missing);
        add_test("XEP0421_occupant_id_no_id_attr", test_occid_no_attr);
        add_test("XEP0421_occupant_id_wrong_ns", test_occid_wrong_ns);

        // --- XEP-0444 Reactions ---
        add_test("XEP0444_reactions_valid", test_reactions_valid);
        add_test("XEP0444_reactions_empty", test_reactions_empty);
        add_test("XEP0444_reactions_no_id", test_reactions_no_id);
        add_test("XEP0444_reactions_missing_node", test_reactions_missing);

        // --- XEP-0446 File Metadata ---
        add_test("XEP0446_metadata_full", test_fm_full);
        add_test("XEP0446_metadata_name_only", test_fm_name_only);
        add_test("XEP0446_metadata_empty_file", test_fm_empty_file);
        add_test("XEP0446_metadata_no_file_node", test_fm_no_file);
        add_test("XEP0446_metadata_bad_size", test_fm_bad_size);
        add_test("XEP0446_metadata_roundtrip", test_fm_roundtrip);
        add_test("XEP0446_metadata_media_type_compat", test_fm_media_type_compat);
        add_test("XEP0446_metadata_dimensions", test_fm_dimensions);

        // --- XEP-0461 Replies ---
        add_test("XEP0461_reply_to_roundtrip", test_reply_roundtrip);
        add_test("XEP0461_reply_to_missing", test_reply_missing);
        add_test("XEP0461_reply_to_no_to_attr", test_reply_no_to);
        add_test("XEP0461_reply_to_no_id_attr", test_reply_no_id);
        add_test("XEP0461_reply_to_invalid_jid", test_reply_invalid_jid);
        add_test("XEP0461_reply_to_empty_attrs", test_reply_empty_attrs);
    }

    // ===================== XEP-0004 Data Forms =====================

    private void test_df_empty_x() {
        // Empty <x> node should produce DataForm with no fields
        var node = new StanzaNode.build("x", Xep.DataForms.NS_URI).add_self_xmlns();
        var form = Xep.DataForms.DataForm.create_from_node(node);
        fail_if(form == null, "create_from_node should never return null");
        fail_if_not_eq_int(form.fields.size, 0, "Empty form should have 0 fields");
    }

    private void test_df_no_fields() {
        // Form with type attribute but no field subnodes
        var node = new StanzaNode.build("x", Xep.DataForms.NS_URI)
            .add_self_xmlns()
            .put_attribute("type", "form");
        var form = Xep.DataForms.DataForm.create_from_node(node);
        fail_if(form == null, "Form node should parse");
        fail_if_not_eq_int(form.fields.size, 0, "No fields expected");
    }

    private void test_df_field_missing_type() {
        // Field without type= attribute should default to text-single
        var field_node = new StanzaNode.build("field", Xep.DataForms.NS_URI)
            .put_attribute("var", "username");
        var value_node = new StanzaNode.build("value", Xep.DataForms.NS_URI)
            .put_node(new StanzaNode.text("alice"));
        field_node.put_node(value_node);

        var node = new StanzaNode.build("x", Xep.DataForms.NS_URI)
            .add_self_xmlns()
            .put_node(field_node);
        var form = Xep.DataForms.DataForm.create_from_node(node);
        fail_if_not_eq_int(form.fields.size, 1, "Should have 1 field");
        fail_if_not_eq_str(form.fields[0].get_value_string(), "alice",
            "Field value should be 'alice'");
    }

    private void test_df_field_unknown_type() {
        // Unknown field type should fall through to text-single
        var field_node = new StanzaNode.build("field", Xep.DataForms.NS_URI)
            .put_attribute("type", "invented-type")
            .put_attribute("var", "test");
        var node = new StanzaNode.build("x", Xep.DataForms.NS_URI)
            .add_self_xmlns()
            .put_node(field_node);
        var form = Xep.DataForms.DataForm.create_from_node(node);
        fail_if_not_eq_int(form.fields.size, 1, "Unknown type should still add field");
    }

    private void test_df_hidden_form_type() {
        // FORM_TYPE hidden field should be extracted to form_type property
        var field_node = new StanzaNode.build("field", Xep.DataForms.NS_URI)
            .put_attribute("type", "hidden")
            .put_attribute("var", "FORM_TYPE");
        field_node.put_node(new StanzaNode.build("value", Xep.DataForms.NS_URI)
            .put_node(new StanzaNode.text("urn:xmpp:test:form")));

        var node = new StanzaNode.build("x", Xep.DataForms.NS_URI)
            .add_self_xmlns()
            .put_node(field_node);
        var form = Xep.DataForms.DataForm.create_from_node(node);
        fail_if_not_eq_str(form.form_type, "urn:xmpp:test:form",
            "FORM_TYPE hidden field should set form_type");
        // FORM_TYPE field is NOT added to the fields list
        fail_if_not_eq_int(form.fields.size, 0,
            "FORM_TYPE should not appear in fields list");
    }

    private void test_df_boolean_bad_value() {
        // Boolean field with an invalid value should be false.
        var field_node = new StanzaNode.build("field", Xep.DataForms.NS_URI)
            .put_attribute("type", "boolean")
            .put_attribute("var", "notify");
        field_node.put_node(new StanzaNode.build("value", Xep.DataForms.NS_URI)
            .put_node(new StanzaNode.text("yes")));
        var node = new StanzaNode.build("x", Xep.DataForms.NS_URI)
            .add_self_xmlns()
            .put_node(field_node);
        var form = Xep.DataForms.DataForm.create_from_node(node);
        fail_if_not_eq_int(form.fields.size, 1, "Should have 1 boolean field");
        var bf = form.fields[0] as Xep.DataForms.DataForm.BooleanField;
        fail_if(bf == null, "Should be BooleanField");
        fail_if(bf.value, "Boolean field with 'yes' should be false");
    }

    private void test_df_boolean_true_literal() {
        var field_node = new StanzaNode.build("field", Xep.DataForms.NS_URI)
            .put_attribute("type", "boolean")
            .put_attribute("var", "notify");
        field_node.put_node(new StanzaNode.build("value", Xep.DataForms.NS_URI)
            .put_node(new StanzaNode.text("true")));
        var node = new StanzaNode.build("x", Xep.DataForms.NS_URI)
            .add_self_xmlns()
            .put_node(field_node);
        var form = Xep.DataForms.DataForm.create_from_node(node);
        var bf = form.fields[0] as Xep.DataForms.DataForm.BooleanField;
        fail_if(bf == null || !((!) bf).value,
            "Boolean field with the XEP-0004 'true' representation should be true");
    }

    private void test_df_field_value_roundtrip() {
        // Set value and retrieve it back
        var field = new Xep.DataForms.DataForm.Field();
        field.set_value_string("hello");
        fail_if_not_eq_str(field.get_value_string(), "hello",
            "Field value roundtrip should preserve content");
        // Overwrite
        field.set_value_string("world");
        fail_if_not_eq_str(field.get_value_string(), "world",
            "Field value overwrite should work");
    }

    private void test_df_title_instructions() {
        var node = new StanzaNode.build("x", Xep.DataForms.NS_URI)
            .add_self_xmlns();
        node.put_node(new StanzaNode.build("title", Xep.DataForms.NS_URI)
            .put_node(new StanzaNode.text("Registration")));
        node.put_node(new StanzaNode.build("instructions", Xep.DataForms.NS_URI)
            .put_node(new StanzaNode.text("Fill in the form")));
        var form = Xep.DataForms.DataForm.create_from_node(node);
        fail_if_not_eq_str(form.title, "Registration", "Title should be parsed");
        fail_if_not_eq_str(form.instructions, "Fill in the form",
            "Instructions should be parsed");
    }

    private void test_df_items() {
        // Data form with <item> sub-elements (search results style)
        var item_node = new StanzaNode.build("item", Xep.DataForms.NS_URI);
        var field1 = new StanzaNode.build("field", Xep.DataForms.NS_URI)
            .put_attribute("var", "jid")
            .put_attribute("type", "text-single");
        field1.put_node(new StanzaNode.build("value", Xep.DataForms.NS_URI)
            .put_node(new StanzaNode.text("user@example.com")));
        item_node.put_node(field1);

        var node = new StanzaNode.build("x", Xep.DataForms.NS_URI)
            .add_self_xmlns()
            .put_attribute("type", "result")
            .put_node(item_node);
        var form = Xep.DataForms.DataForm.create_from_node(node);
        fail_if_not_eq_int(form.items.size, 1, "Should have 1 item");
        fail_if_not_eq_int(form.items[0].size, 1, "Item should have 1 field");
    }

    // ===================== XEP-0184 Message Delivery Receipts =====================

    private void test_receipts_has_request() {
        var msg = new MessageStanza();
        msg.stanza.put_node(new StanzaNode.build("request", "urn:xmpp:receipts")
            .add_self_xmlns());
        fail_if_not(Xep.MessageDeliveryReceipts.Module.requests_receipt(msg),
            "Message with <request> should request receipt");
    }

    private void test_receipts_no_request() {
        var msg = new MessageStanza();
        msg.stanza.put_node(new StanzaNode.build("body")
            .put_node(new StanzaNode.text("Hello")));
        fail_if(Xep.MessageDeliveryReceipts.Module.requests_receipt(msg),
            "Message without <request> should not request receipt");
    }

    private void test_receipts_wrong_ns() {
        var msg = new MessageStanza();
        msg.stanza.put_node(new StanzaNode.build("request", "wrong:namespace")
            .add_self_xmlns());
        fail_if(Xep.MessageDeliveryReceipts.Module.requests_receipt(msg),
            "Message with <request> in wrong NS should not request receipt");
    }

    private void test_receipts_received_id_opaque() {
        const string opaque_id = "  receipt-42\t";
        StanzaNode? received = Xep.MessageDeliveryReceipts.Module
            .build_received_node(opaque_id);
        fail_if(received == null,
            "A non-blank opaque receipt ID should produce a node");
        if (received == null) return;

        var message = new MessageStanza();
        message.stanza.put_node((!) received);
        fail_if_not_eq_str(((!) received).get_attribute("id",
                Xep.MessageDeliveryReceipts.NS_URI), opaque_id,
            "XEP-0184 must copy the original message id verbatim");
        fail_if_not_eq_str(Xep.MessageDeliveryReceipts.Module
                .get_received_id(message), opaque_id,
            "XEP-0184 parsing must preserve an opaque message id");
    }

    private void test_receipts_ambiguous_control_rejected() {
        var duplicate = new MessageStanza();
        duplicate.stanza.put_node(new StanzaNode.build("received",
                Xep.MessageDeliveryReceipts.NS_URI).add_self_xmlns()
            .put_attribute("id", "one"));
        duplicate.stanza.put_node(new StanzaNode.build("received",
                Xep.MessageDeliveryReceipts.NS_URI).add_self_xmlns()
            .put_attribute("id", "two"));
        fail_if(Xep.MessageDeliveryReceipts.Module.get_received_id(
                duplicate) != null,
            "Multiple receipt nodes are ambiguous and must be ignored");

        var mixed = new MessageStanza();
        mixed.stanza.put_node(new StanzaNode.build("received",
                Xep.MessageDeliveryReceipts.NS_URI).add_self_xmlns()
            .put_attribute("id", "one"));
        mixed.stanza.put_node(new StanzaNode.build("request",
                Xep.MessageDeliveryReceipts.NS_URI).add_self_xmlns());
        fail_if(Xep.MessageDeliveryReceipts.Module.get_received_id(mixed) !=
                null,
            "A mixed request and receipt stanza must be ignored");

        var marker_request = new MessageStanza();
        marker_request.stanza.put_node(new StanzaNode.build("request",
                Xep.MessageDeliveryReceipts.NS_URI).add_self_xmlns());
        marker_request.stanza.put_node(new StanzaNode.build("displayed",
                Xep.ChatMarkers.NS_URI).add_self_xmlns()
            .put_attribute("id", "one"));
        fail_if(Xep.MessageDeliveryReceipts.Module.requests_receipt(
                marker_request),
            "A chat marker must never request a delivery-receipt response");
    }

    // ===================== XEP-0333 Chat Markers =====================

    private void test_markers_has_markable() {
        var msg = new MessageStanza();
        msg.stanza.put_node(new StanzaNode.build("markable", Xep.ChatMarkers.NS_URI)
            .add_self_xmlns());
        fail_if_not(Xep.ChatMarkers.Module.requests_marking(msg),
            "Message with <markable> should request marking");
    }

    private void test_markers_no_markable() {
        var msg = new MessageStanza();
        fail_if(Xep.ChatMarkers.Module.requests_marking(msg),
            "Empty message should not request marking");
    }

    private void test_markers_wrong_ns() {
        var msg = new MessageStanza();
        msg.stanza.put_node(new StanzaNode.build("markable", "wrong:ns").add_self_xmlns());
        fail_if(Xep.ChatMarkers.Module.requests_marking(msg),
            "Markable in wrong NS should not count");
    }

    private void test_markers_duplicate_markable() {
        var msg = new MessageStanza();
        msg.stanza.put_node(new StanzaNode.build("markable",
                Xep.ChatMarkers.NS_URI).add_self_xmlns());
        msg.stanza.put_node(new StanzaNode.build("markable",
                Xep.ChatMarkers.NS_URI).add_self_xmlns());
        fail_if(Xep.ChatMarkers.Module.requests_marking(msg),
            "Duplicate markable elements are ambiguous and must be ignored");
    }

    private void test_markers_control_stanza_not_markable() {
        var marker = new MessageStanza();
        marker.stanza.put_node(new StanzaNode.build("markable",
                Xep.ChatMarkers.NS_URI).add_self_xmlns());
        marker.stanza.put_node(new StanzaNode.build("displayed",
                Xep.ChatMarkers.NS_URI).add_self_xmlns()
            .put_attribute("id", "one"));
        fail_if(Xep.ChatMarkers.Module.requests_marking(marker),
            "A displayed marker must never request a marker response");

        var receipt = new MessageStanza();
        receipt.stanza.put_node(new StanzaNode.build("markable",
                Xep.ChatMarkers.NS_URI).add_self_xmlns());
        receipt.stanza.put_node(new StanzaNode.build("received",
                Xep.MessageDeliveryReceipts.NS_URI).add_self_xmlns()
            .put_attribute("id", "one"));
        fail_if(Xep.ChatMarkers.Module.requests_marking(receipt),
            "A delivery receipt must never request a marker response");
    }

    private void test_markers_displayed_roundtrip() {
        var msg = new MessageStanza();
        StanzaNode? displayed = Xep.ChatMarkers.Module.build_displayed_node("message-42");
        fail_if(displayed == null, "A non-empty displayed ID should produce a node");
        if (displayed == null) return;

        fail_if_not_eq_str(displayed.name, Xep.ChatMarkers.MARKER_DISPLAYED,
            "Displayed node name mismatch");
        fail_if_not_eq_str(displayed.ns_uri, Xep.ChatMarkers.NS_URI,
            "Displayed node namespace mismatch");
        msg.stanza.put_node(displayed);
        fail_if_not_eq_str(Xep.ChatMarkers.Module.get_displayed_id(msg), "message-42",
            "Displayed ID should roundtrip");
    }

    private void test_markers_displayed_id_opaque() {
        const string opaque_id = "  message-42\t";
        var msg = new MessageStanza();
        StanzaNode? displayed = Xep.ChatMarkers.Module.build_displayed_node(
            opaque_id);
        fail_if(displayed == null, "A displayed ID with surrounding whitespace should be valid");
        if (displayed == null) return;

        msg.stanza.put_node(displayed);
        fail_if_not_eq_str(displayed.get_attribute("id", Xep.ChatMarkers.NS_URI),
            opaque_id, "XEP-0333 must copy the original message id verbatim");
        fail_if_not_eq_str(Xep.ChatMarkers.Module.get_displayed_id(msg),
            opaque_id, "Built displayed IDs must remain opaque when parsed");

        var incoming = new MessageStanza();
        incoming.stanza.put_node(new StanzaNode.build(
            Xep.ChatMarkers.MARKER_DISPLAYED, Xep.ChatMarkers.NS_URI)
            .add_self_xmlns()
            .put_attribute("id", "  incoming-42\t"));
        fail_if_not_eq_str(Xep.ChatMarkers.Module.get_displayed_id(incoming),
            "  incoming-42\t", "Incoming displayed IDs must remain opaque");
    }

    private void test_markers_displayed_missing_id() {
        var missing = new MessageStanza();
        missing.stanza.put_node(new StanzaNode.build(
            Xep.ChatMarkers.MARKER_DISPLAYED, Xep.ChatMarkers.NS_URI).add_self_xmlns());
        fail_if(Xep.ChatMarkers.Module.get_displayed_id(missing) != null,
            "Displayed without an ID should be ignored");
        fail_if(Xep.ChatMarkers.Module.build_displayed_node(null) != null,
            "A missing displayed ID should not produce a node");
    }

    private void test_markers_displayed_empty_id() {
        var empty = new MessageStanza();
        empty.stanza.put_node(new StanzaNode.build(
            Xep.ChatMarkers.MARKER_DISPLAYED, Xep.ChatMarkers.NS_URI)
            .add_self_xmlns()
            .put_attribute("id", " \t "));
        fail_if(Xep.ChatMarkers.Module.get_displayed_id(empty) != null,
            "Displayed with an empty ID should be ignored");
        fail_if(Xep.ChatMarkers.Module.build_displayed_node(" \t ") != null,
            "An empty displayed ID should not produce a node");
    }

    private void test_markers_displayed_wrong_ns() {
        var msg = new MessageStanza();
        msg.stanza.put_node(new StanzaNode.build(
            Xep.ChatMarkers.MARKER_DISPLAYED, "wrong:ns")
            .add_self_xmlns()
            .put_attribute("id", "message-42"));
        fail_if(Xep.ChatMarkers.Module.get_displayed_id(msg) != null,
            "Displayed in the wrong namespace should be ignored");
    }

    private void test_markers_ambiguous_marker_rejected() {
        var duplicate = new MessageStanza();
        duplicate.stanza.put_node(new StanzaNode.build(
                Xep.ChatMarkers.MARKER_DISPLAYED, Xep.ChatMarkers.NS_URI)
            .add_self_xmlns().put_attribute("id", "one"));
        duplicate.stanza.put_node(new StanzaNode.build(
                Xep.ChatMarkers.MARKER_DISPLAYED, Xep.ChatMarkers.NS_URI)
            .add_self_xmlns().put_attribute("id", "two"));
        fail_if(Xep.ChatMarkers.Module.get_displayed_id(duplicate) != null,
            "Multiple displayed markers are ambiguous and must be ignored");

        var mixed = new MessageStanza();
        mixed.stanza.put_node(new StanzaNode.build(
                Xep.ChatMarkers.MARKER_DISPLAYED, Xep.ChatMarkers.NS_URI)
            .add_self_xmlns().put_attribute("id", "one"));
        mixed.stanza.put_node(new StanzaNode.build("received",
                Xep.ChatMarkers.NS_URI).add_self_xmlns()
            .put_attribute("id", "one"));
        fail_if(Xep.ChatMarkers.Module.get_displayed_id(mixed) != null,
            "Mixed marker generations are ambiguous and must be ignored");
    }

    private async void test_receipts_pipeline_requests_body_chat_once(
            Gee.TestFinishedCallback cb) {
        var msg = new MessageStanza();
        msg.type_ = MessageStanza.TYPE_CHAT;
        msg.body = "Hello";

        var listener = new Xep.MessageDeliveryReceipts.SendPipelineListener();
        XmppStream stream = new_chat_markers_test_stream();
        yield listener.run(stream, msg);
        yield listener.run(stream, msg);
        fail_if_not_eq_int(msg.stanza.get_subnodes("request",
                Xep.MessageDeliveryReceipts.NS_URI).size, 1,
            "A body chat should request exactly one delivery receipt");
        cb();
    }

    private async void test_receipts_and_markers_pipeline_coexist(
            Gee.TestFinishedCallback cb) {
        var msg = new MessageStanza();
        msg.type_ = MessageStanza.TYPE_CHAT;
        msg.body = "Hello";

        XmppStream stream = new_receipt_marker_pipeline_test_stream();
        MessageModule message_module = stream.get_module<MessageModule>(
            MessageModule.IDENTITY);
        yield message_module.send_pipeline.run(stream, msg);
        yield message_module.send_pipeline.run(stream, msg);
        fail_if_not_eq_int(msg.stanza.get_subnodes("request",
                Xep.MessageDeliveryReceipts.NS_URI).size, 1,
            "A body chat should retain its XEP-0184 request");
        fail_if_not_eq_int(msg.stanza.get_subnodes("markable",
                Xep.ChatMarkers.NS_URI).size, 1,
            "A body chat should also retain its XEP-0333 markable node");
        cb();
    }

    private static XmppStream new_receipt_marker_pipeline_test_stream() {
        XmppStream stream = new_chat_markers_test_stream();
        stream.add_flag(new Xep.ServiceDiscovery.Flag());
        stream.add_module(new Xep.ServiceDiscovery.Module.with_identity(
            "client", "pc", "DinoX receipt audit"));

        var message_module = new MessageModule();
        stream.add_module(message_module);
        message_module.attach(stream);

        var receipts = new Xep.MessageDeliveryReceipts.Module();
        stream.add_module(receipts);
        receipts.attach(stream);

        var markers = new Xep.ChatMarkers.Module();
        stream.add_module(markers);
        markers.attach(stream);
        return stream;
    }

    private async void test_markers_pipeline_preserves_markable(
            Gee.TestFinishedCallback cb) {
        var msg = new MessageStanza();
        msg.type_ = MessageStanza.TYPE_CHAT;
        msg.body = "Hello";
        msg.stanza.put_node(new StanzaNode.build("markable", Xep.ChatMarkers.NS_URI)
            .add_self_xmlns());

        var listener = new Xep.ChatMarkers.SendPipelineListener();
        yield listener.run(new_chat_markers_test_stream(), msg);
        fail_if_not_eq_int(msg.stanza.get_subnodes(
            "markable", Xep.ChatMarkers.NS_URI).size, 1,
            "The send pipeline must not duplicate an existing markable node");
        cb();
    }

    private async void test_markers_pipeline_marks_body_chat_once(
            Gee.TestFinishedCallback cb) {
        var msg = new MessageStanza();
        msg.type_ = MessageStanza.TYPE_CHAT;
        msg.body = "Hello";

        var listener = new Xep.ChatMarkers.SendPipelineListener();
        yield listener.run(new_chat_markers_test_stream(), msg);
        fail_if_not_eq_int(msg.stanza.get_subnodes(
            "markable", Xep.ChatMarkers.NS_URI).size, 1,
            "A body chat should receive exactly one markable node");
        fail_if_not_eq_int(msg.stanza.get_subnodes(
            "received", Xep.ChatMarkers.NS_URI).size, 0,
            "XEP-0333 1.0 must not emit legacy received markers");
        fail_if_not_eq_int(msg.stanza.get_subnodes(
            "acknowledged", Xep.ChatMarkers.NS_URI).size, 0,
            "XEP-0333 1.0 must not emit legacy acknowledged markers");
        cb();
    }

    private async void test_markers_pipeline_marks_body_groupchat_once(
            Gee.TestFinishedCallback cb) {
        var msg = new MessageStanza();
        msg.type_ = MessageStanza.TYPE_GROUPCHAT;
        msg.body = "Hello room";

        var listener = new Xep.ChatMarkers.SendPipelineListener();
        yield listener.run(new_chat_markers_test_stream(), msg);
        fail_if_not_eq_int(msg.stanza.get_subnodes(
            "markable", Xep.ChatMarkers.NS_URI).size, 1,
            "A body groupchat should request an interoperable displayed marker");
        cb();
    }

    private async void test_markers_pipeline_skips_control_stanzas(
            Gee.TestFinishedCallback cb) {
        var marker = new MessageStanza();
        marker.type_ = MessageStanza.TYPE_CHAT;
        marker.body = "Malformed marker payload";
        StanzaNode? displayed = Xep.ChatMarkers.Module.build_displayed_node("message-42");
        fail_if(displayed == null, "A valid displayed node should be available for the test");
        if (displayed != null) marker.stanza.put_node(displayed);

        var listener = new Xep.ChatMarkers.SendPipelineListener();
        var receipt_listener = new Xep.MessageDeliveryReceipts
            .SendPipelineListener();
        XmppStream stream = new_chat_markers_test_stream();
        yield listener.run(stream, marker);
        yield receipt_listener.run(stream, marker);
        fail_if_not_eq_int(marker.stanza.get_subnodes(
            "markable", Xep.ChatMarkers.NS_URI).size, 0,
            "A marker stanza must not receive a markable node");
        fail_if_not_eq_int(marker.stanza.get_subnodes("request",
                Xep.MessageDeliveryReceipts.NS_URI).size, 0,
            "A marker stanza must not request a delivery receipt");

        var receipt = new MessageStanza();
        receipt.type_ = MessageStanza.TYPE_CHAT;
        receipt.body = "Malformed receipt payload";
        StanzaNode? received = Xep.MessageDeliveryReceipts.Module
            .build_received_node("message-42");
        fail_if(received == null,
            "A valid receipt node should be available for the test");
        if (received != null) receipt.stanza.put_node((!) received);
        yield listener.run(stream, receipt);
        yield receipt_listener.run(stream, receipt);
        fail_if_not_eq_int(receipt.stanza.get_subnodes(
                "markable", Xep.ChatMarkers.NS_URI).size, 0,
            "A receipt stanza must not receive a markable node");
        fail_if_not_eq_int(receipt.stanza.get_subnodes("request",
                Xep.MessageDeliveryReceipts.NS_URI).size, 0,
            "A receipt stanza must not request another receipt");

        var control = new MessageStanza();
        control.type_ = MessageStanza.TYPE_CHAT;
        control.stanza.put_node(new StanzaNode.build(
            "active", "http://jabber.org/protocol/chatstates").add_self_xmlns());
        yield listener.run(stream, control);
        fail_if_not_eq_int(control.stanza.get_subnodes(
            "markable", Xep.ChatMarkers.NS_URI).size, 0,
            "A bodyless control stanza must not receive a markable node");
        cb();
    }

    private static XmppStream new_chat_markers_test_stream() {
        try {
            return new ChatMarkersAuditStream(new Jid("example.test"));
        } catch (InvalidJidError e) {
            fail_if_reached("Static test JID should be valid");
        }
        assert_not_reached();
    }

    // ===================== XEP-0359 Unique Stable Stanza IDs =====================

    private void test_sid_origin_present() {
        var msg = new MessageStanza();
        Xep.UniqueStableStanzaIDs.set_origin_id(msg, "orig-42");
        string? id = Xep.UniqueStableStanzaIDs.get_origin_id(msg);
        fail_if_not_eq_str(id, "orig-42", "Origin ID should roundtrip");
    }

    private void test_sid_origin_missing() {
        var msg = new MessageStanza();
        string? id = Xep.UniqueStableStanzaIDs.get_origin_id(msg);
        fail_if(id != null, "Missing origin-id should return null");
    }

    private void test_sid_origin_no_attr() {
        var msg = new MessageStanza();
        msg.stanza.put_node(new StanzaNode.build("origin-id", Xep.UniqueStableStanzaIDs.NS_URI)
            .add_self_xmlns());
        // No id= attribute
        string? id = Xep.UniqueStableStanzaIDs.get_origin_id(msg);
        fail_if(id != null, "origin-id without id attr should return null");
    }

    private void test_sid_stanza_match() {
        var msg = new MessageStanza();
        var stanza_id_node = new StanzaNode.build("stanza-id", Xep.UniqueStableStanzaIDs.NS_URI)
            .add_self_xmlns()
            .put_attribute("id", "server-id-99")
            .put_attribute("by", "room@conference.example.com");
        msg.stanza.put_node(stanza_id_node);

        try {
            var by = new Jid("room@conference.example.com");
            string? id = Xep.UniqueStableStanzaIDs.get_stanza_id(msg, by);
            fail_if_not_eq_str(id, "server-id-99", "Stanza ID should match by JID");
        } catch (InvalidJidError e) {
            fail_if_reached("JID should be valid");
        }
    }

    private void test_sid_stanza_wrong_by() {
        var msg = new MessageStanza();
        var stanza_id_node = new StanzaNode.build("stanza-id", Xep.UniqueStableStanzaIDs.NS_URI)
            .add_self_xmlns()
            .put_attribute("id", "server-id-99")
            .put_attribute("by", "room@conference.example.com");
        msg.stanza.put_node(stanza_id_node);

        try {
            var by = new Jid("other@example.com");
            string? id = Xep.UniqueStableStanzaIDs.get_stanza_id(msg, by);
            fail_if(id != null, "Stanza ID with wrong 'by' should return null");
        } catch (InvalidJidError e) {
            fail_if_reached("JID should be valid");
        }
    }

    private void test_sid_stanza_no_by() {
        var msg = new MessageStanza();
        var stanza_id_node = new StanzaNode.build("stanza-id", Xep.UniqueStableStanzaIDs.NS_URI)
            .add_self_xmlns()
            .put_attribute("id", "server-id-99");
        // No by= attribute
        msg.stanza.put_node(stanza_id_node);

        try {
            var by = new Jid("room@conference.example.com");
            string? id = Xep.UniqueStableStanzaIDs.get_stanza_id(msg, by);
            fail_if(id != null, "Stanza ID without 'by' attr should return null");
        } catch (InvalidJidError e) {
            fail_if_reached("JID should be valid");
        }
    }

    private void test_sid_duplicate_authority() {
        var msg = new MessageStanza();
        msg.stanza.put_node(new StanzaNode.build("stanza-id",
                Xep.UniqueStableStanzaIDs.NS_URI).add_self_xmlns()
            .put_attribute("id", "one")
            .put_attribute("by", "room@conference.example.com"));
        msg.stanza.put_node(new StanzaNode.build("stanza-id",
                Xep.UniqueStableStanzaIDs.NS_URI).add_self_xmlns()
            .put_attribute("id", "two")
            .put_attribute("by", "room@conference.example.com"));
        try {
            Jid by = new Jid("room@conference.example.com");
            fail_if(Xep.UniqueStableStanzaIDs.get_stanza_id(msg, by) != null,
                "Duplicate IDs from one authority must not be order-dependent");
        } catch (InvalidJidError error) {
            fail_if_reached("Static test JID should be valid");
        }
    }

    // ===================== XEP-0421 Occupant IDs =====================

    private void test_occid_present() {
        var stanza = new StanzaNode.build("presence");
        stanza.put_node(new StanzaNode.build("occupant-id", Xep.OccupantIds.NS_URI)
            .add_self_xmlns()
            .put_attribute("id", "occ-abc"));
        string? id = Xep.OccupantIds.get_occupant_id(stanza);
        fail_if_not_eq_str(id, "occ-abc", "Should return occupant ID");
    }

    private void test_occid_missing() {
        var stanza = new StanzaNode.build("presence");
        string? id = Xep.OccupantIds.get_occupant_id(stanza);
        fail_if(id != null, "Missing occupant-id should return null");
    }

    private void test_occid_no_attr() {
        var stanza = new StanzaNode.build("presence");
        stanza.put_node(new StanzaNode.build("occupant-id", Xep.OccupantIds.NS_URI)
            .add_self_xmlns());
        // No id= attribute
        string? id = Xep.OccupantIds.get_occupant_id(stanza);
        fail_if(id != null, "occupant-id without id attr should return null");
    }

    private void test_occid_wrong_ns() {
        var stanza = new StanzaNode.build("presence");
        stanza.put_node(new StanzaNode.build("occupant-id", "wrong:ns")
            .add_self_xmlns()
            .put_attribute("id", "occ-abc"));
        string? id = Xep.OccupantIds.get_occupant_id(stanza);
        fail_if(id != null, "occupant-id in wrong NS should return null");
    }

    // ===================== XEP-0444 Reactions =====================

    private void test_reactions_valid() {
        // Build a message with valid reactions
        var msg = new MessageStanza();
        var reactions_node = new StanzaNode.build("reactions", Xep.Reactions.NS_URI)
            .add_self_xmlns()
            .put_attribute("id", "msg-42");
        reactions_node.put_node(new StanzaNode.build("reaction", Xep.Reactions.NS_URI)
            .put_node(new StanzaNode.text("👍")));
        reactions_node.put_node(new StanzaNode.build("reaction", Xep.Reactions.NS_URI)
            .put_node(new StanzaNode.text("❤️")));
        msg.stanza.put_node(reactions_node);

        // Verify the stanza structure is correct
        var rn = msg.stanza.get_subnode("reactions", Xep.Reactions.NS_URI);
        fail_if(rn == null, "reactions node should exist");
        fail_if_not_eq_str(rn.get_attribute("id"), "msg-42", "id should be msg-42");
        var subnodes = rn.get_subnodes("reaction", Xep.Reactions.NS_URI);
        fail_if_not_eq_int(subnodes.size, 2, "Should have 2 reaction children");
    }

    private void test_reactions_empty() {
        // Reactions node present but no <reaction> children
        var msg = new MessageStanza();
        var reactions_node = new StanzaNode.build("reactions", Xep.Reactions.NS_URI)
            .add_self_xmlns()
            .put_attribute("id", "msg-42");
        msg.stanza.put_node(reactions_node);

        var rn = msg.stanza.get_subnode("reactions", Xep.Reactions.NS_URI);
        fail_if(rn == null, "reactions node should exist");
        var subnodes = rn.get_subnodes("reaction", Xep.Reactions.NS_URI);
        fail_if_not_eq_int(subnodes.size, 0, "Empty reactions should have 0 children");
    }

    private void test_reactions_no_id() {
        // Reactions node without id attribute
        var msg = new MessageStanza();
        var reactions_node = new StanzaNode.build("reactions", Xep.Reactions.NS_URI)
            .add_self_xmlns();
        msg.stanza.put_node(reactions_node);

        var rn = msg.stanza.get_subnode("reactions", Xep.Reactions.NS_URI);
        fail_if(rn == null, "reactions node should still exist");
        string? id = rn.get_attribute("id");
        fail_if(id != null, "Missing id attr should return null");
    }

    private void test_reactions_missing() {
        // No reactions node at all
        var msg = new MessageStanza();
        var rn = msg.stanza.get_subnode("reactions", Xep.Reactions.NS_URI);
        fail_if(rn != null, "No reactions node should return null");
    }

    // ===================== XEP-0446 File Metadata =====================

    private void test_fm_full() {
        // Full file metadata with all fields
        var parent = new StanzaNode.build("description", "urn:xmpp:jingle:apps:file-transfer:5");
        var file = new StanzaNode.build("file", Xep.FileMetadataElement.NS_URI).add_self_xmlns();
        file.put_node(new StanzaNode.build("name", Xep.FileMetadataElement.NS_URI)
            .put_node(new StanzaNode.text("photo.jpg")));
        file.put_node(new StanzaNode.build("media-type", Xep.FileMetadataElement.NS_URI)
            .put_node(new StanzaNode.text("image/jpeg")));
        file.put_node(new StanzaNode.build("size", Xep.FileMetadataElement.NS_URI)
            .put_node(new StanzaNode.text("12345")));
        file.put_node(new StanzaNode.build("desc", Xep.FileMetadataElement.NS_URI)
            .put_node(new StanzaNode.text("A nice photo")));
        file.put_node(new StanzaNode.build("width", Xep.FileMetadataElement.NS_URI)
            .put_node(new StanzaNode.text("1920")));
        file.put_node(new StanzaNode.build("height", Xep.FileMetadataElement.NS_URI)
            .put_node(new StanzaNode.text("1080")));
        parent.put_node(file);

        var metadata = Xep.FileMetadataElement.get_file_metadata(parent);
        fail_if(metadata == null, "Full metadata should parse");
        fail_if_not_eq_str(metadata.name, "photo.jpg", "Name mismatch");
        fail_if_not_eq_str(metadata.mime_type, "image/jpeg", "MIME type mismatch");
        fail_if_not(metadata.size == 12345, "Size mismatch");
        fail_if_not_eq_str(metadata.desc, "A nice photo", "Desc mismatch");
        fail_if_not_eq_int(metadata.width, 1920, "Width mismatch");
        fail_if_not_eq_int(metadata.height, 1080, "Height mismatch");
    }

    private void test_fm_name_only() {
        var parent = new StanzaNode.build("wrapper");
        var file = new StanzaNode.build("file", Xep.FileMetadataElement.NS_URI).add_self_xmlns();
        file.put_node(new StanzaNode.build("name", Xep.FileMetadataElement.NS_URI)
            .put_node(new StanzaNode.text("test.txt")));
        parent.put_node(file);

        var metadata = Xep.FileMetadataElement.get_file_metadata(parent);
        fail_if(metadata == null, "Minimal metadata should parse");
        fail_if_not_eq_str(metadata.name, "test.txt", "Name mismatch");
        fail_if(metadata.mime_type != null, "MIME should be null");
        fail_if_not(metadata.size == -1, "Size should be -1 default");
        fail_if_not_eq_int(metadata.width, -1, "Width should be -1");
        fail_if_not_eq_int(metadata.height, -1, "Height should be -1");
    }

    private void test_fm_empty_file() {
        // <file> node present but no children — should return metadata with defaults
        var parent = new StanzaNode.build("wrapper");
        parent.put_node(new StanzaNode.build("file", Xep.FileMetadataElement.NS_URI)
            .add_self_xmlns());
        var metadata = Xep.FileMetadataElement.get_file_metadata(parent);
        fail_if(metadata == null, "Empty file node should still return metadata");
        fail_if(metadata.name != null, "Name should be null");
    }

    private void test_fm_no_file() {
        // No <file> subnode at all
        var parent = new StanzaNode.build("wrapper");
        var metadata = Xep.FileMetadataElement.get_file_metadata(parent);
        fail_if(metadata != null, "No file node should return null");
    }

    private void test_fm_bad_size() {
        // Non-numeric size should parse to 0 (int64.parse returns 0 for bad input)
        var parent = new StanzaNode.build("wrapper");
        var file = new StanzaNode.build("file", Xep.FileMetadataElement.NS_URI).add_self_xmlns();
        file.put_node(new StanzaNode.build("size", Xep.FileMetadataElement.NS_URI)
            .put_node(new StanzaNode.text("not-a-number")));
        parent.put_node(file);

        var metadata = Xep.FileMetadataElement.get_file_metadata(parent);
        fail_if(metadata == null, "Bad size should not crash parser");
        // int64.parse("not-a-number") returns 0
        fail_if_not(metadata.size == 0, "Bad size should parse to 0");
    }

    private void test_fm_roundtrip() {
        // Build metadata via constructor, serialize to node, parse back
        var orig = new Xep.FileMetadataElement.FileMetadata();
        orig.name = "document.pdf";
        orig.mime_type = "application/pdf";
        orig.size = 999999;
        orig.desc = "Important document";

        StanzaNode stanza_node = orig.to_stanza_node();
        // Wrap in parent for get_file_metadata
        var parent = new StanzaNode.build("wrapper").put_node(stanza_node);
        var parsed = Xep.FileMetadataElement.get_file_metadata(parent);
        fail_if(parsed == null, "Roundtrip should parse");
        fail_if_not_eq_str(parsed.name, "document.pdf", "Name roundtrip");
        fail_if_not_eq_str(parsed.mime_type, "application/pdf", "MIME roundtrip");
        fail_if_not(parsed.size == 999999, "Size roundtrip");
        fail_if_not_eq_str(parsed.desc, "Important document", "Desc roundtrip");
    }

    private void test_fm_media_type_compat() {
        // Test backward-compat: media_type (underscore) vs media-type (hyphen)
        var parent = new StanzaNode.build("wrapper");
        var file = new StanzaNode.build("file", Xep.FileMetadataElement.NS_URI).add_self_xmlns();
        // Old-style media_type (underscore)
        file.put_node(new StanzaNode.build("media_type", Xep.FileMetadataElement.NS_URI)
            .put_node(new StanzaNode.text("text/plain")));
        parent.put_node(file);

        var metadata = Xep.FileMetadataElement.get_file_metadata(parent);
        fail_if(metadata == null, "Compat media_type should parse");
        fail_if_not_eq_str(metadata.mime_type, "text/plain",
            "media_type (underscore) should be accepted");
    }

    private void test_fm_dimensions() {
        var parent = new StanzaNode.build("wrapper");
        var file = new StanzaNode.build("file", Xep.FileMetadataElement.NS_URI).add_self_xmlns();
        file.put_node(new StanzaNode.build("width", Xep.FileMetadataElement.NS_URI)
            .put_node(new StanzaNode.text("640")));
        file.put_node(new StanzaNode.build("height", Xep.FileMetadataElement.NS_URI)
            .put_node(new StanzaNode.text("480")));
        file.put_node(new StanzaNode.build("length", Xep.FileMetadataElement.NS_URI)
            .put_node(new StanzaNode.text("30000")));
        parent.put_node(file);

        var metadata = Xep.FileMetadataElement.get_file_metadata(parent);
        fail_if(metadata == null, "Dimensions should parse");
        fail_if_not_eq_int(metadata.width, 640, "Width mismatch");
        fail_if_not_eq_int(metadata.height, 480, "Height mismatch");
        fail_if_not(metadata.length == 30000, "Length mismatch");
    }

    // ===================== XEP-0461 Replies =====================

    private void test_reply_roundtrip() {
        var msg = new MessageStanza();
        try {
            var reply_to = new Xep.Replies.ReplyTo(
                new Jid("alice@example.com"), "msg-123");
            Xep.Replies.set_reply_to(msg, reply_to);

            var parsed = Xep.Replies.get_reply_to(msg);
            fail_if(parsed == null, "Reply-to should roundtrip");
            fail_if_not_eq_str(parsed.to_jid.to_string(), "alice@example.com",
                "JID roundtrip");
            fail_if_not_eq_str(parsed.to_message_id, "msg-123",
                "Message ID roundtrip");
        } catch (InvalidJidError e) {
            fail_if_reached("JID should be valid");
        }
    }

    private void test_reply_missing() {
        var msg = new MessageStanza();
        var parsed = Xep.Replies.get_reply_to(msg);
        fail_if(parsed != null, "No reply node should return null");
    }

    private void test_reply_no_to() {
        var msg = new MessageStanza();
        var reply = new StanzaNode.build("reply", Xep.Replies.NS_URI)
            .add_self_xmlns()
            .put_attribute("id", "msg-123");
        // No to= attribute
        msg.stanza.put_node(reply);
        var parsed = Xep.Replies.get_reply_to(msg);
        fail_if(parsed != null, "Reply without 'to' should return null");
    }

    private void test_reply_no_id() {
        var msg = new MessageStanza();
        var reply = new StanzaNode.build("reply", Xep.Replies.NS_URI)
            .add_self_xmlns()
            .put_attribute("to", "alice@example.com");
        // No id= attribute
        msg.stanza.put_node(reply);
        var parsed = Xep.Replies.get_reply_to(msg);
        fail_if(parsed != null, "Reply without 'id' should return null");
    }

    private void test_reply_invalid_jid() {
        var msg = new MessageStanza();
        var reply = new StanzaNode.build("reply", Xep.Replies.NS_URI)
            .add_self_xmlns()
            .put_attribute("to", "@@@invalid@@@jid@@@")
            .put_attribute("id", "msg-123");
        msg.stanza.put_node(reply);
        var parsed = Xep.Replies.get_reply_to(msg);
        fail_if(parsed != null, "Reply with invalid JID should return null");
    }

    private void test_reply_empty_attrs() {
        var msg = new MessageStanza();
        var reply = new StanzaNode.build("reply", Xep.Replies.NS_URI)
            .add_self_xmlns()
            .put_attribute("to", "")
            .put_attribute("id", "");
        msg.stanza.put_node(reply);
        var parsed = Xep.Replies.get_reply_to(msg);
        // Empty JID string should fail JID parsing
        fail_if(parsed != null, "Reply with empty attrs should return null");
    }
}

private class ChatMarkersAuditStream : XmppStream {
    public ChatMarkersAuditStream(Jid remote_name) {
        base(remote_name);
    }

    public override async void connect() throws IOError {
    }

    public override async void disconnect() throws IOError {
    }

    public override async StanzaNode read() throws IOError {
        throw new IOError.NOT_CONNECTED("Test stream has no reader");
    }

    public override async void write_async(StanzaNode node,
            int io_priority = Priority.DEFAULT,
            Cancellable? cancellable = null) throws IOError {
    }

    public override async void setup() throws IOError {
    }
}

}

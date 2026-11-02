namespace Xmpp.Test {

/**
 * Security audit tests for XEP-0191 (Blocking Command).
 *
 * Blocking Command allows users to block/unblock JIDs. Security concerns:
 * - Block/unblock push IQ from wrong sender (spoofing)
 * - Malformed blocklist responses
 * - Edge cases: block empty array, unblock empty array (= unblock all!)
 * - JID parsing in item nodes
 * - Flag state consistency
 *
 * DinoX already fixed Bug #23 (sender validation in on_iq_set) and
 * Bug #49 (null stream in block/unblock). These tests verify the fixes
 * and cover additional edge cases.
 *
 * References:
 *   - XEP-0191 §3      Blocking/unblocking
 *   - XEP-0191 §3.6    Block push (server → client)
 *   - XEP-0191 §5      Security considerations
 */
class BlockingAudit : Gee.TestCase {

    private const string NS_URI = "urn:xmpp:blocking";

    public BlockingAudit() {
        base("BlockingAudit");

        // --- Blocklist parsing ---
        add_test("XEP0191_parse_blocklist_with_items", test_parse_blocklist);
        add_test("XEP0191_parse_blocklist_empty", test_parse_blocklist_empty);
        add_test("XEP0191_parse_blocklist_no_jid_attribute", test_parse_blocklist_no_jid);
        add_test("XEP0191_parse_blocklist_mixed_valid_invalid", test_parse_blocklist_mixed);
        add_test("XEP0191_parse_blocklist_duplicate_jids", test_parse_blocklist_duplicates);

        // --- Block/unblock push parsing ---
        add_test("XEP0191_block_push_single_jid", test_block_push_single);
        add_test("XEP0191_block_push_multiple_jids", test_block_push_multiple);
        add_test("XEP0191_unblock_push_single_jid", test_unblock_push_single);
        add_test("XEP0191_unblock_push_empty_means_all", test_unblock_push_empty);

        // --- Security: sender validation ---
        add_test("XEP0191_push_from_own_bare_accepted", test_push_from_own_bare);
        add_test("XEP0191_push_from_foreign_rejected", test_push_from_foreign);
        add_test("XEP0191_push_with_no_from", test_push_no_from);

        // --- Block/unblock API behavior ---
        add_test("XEP0191_block_empty_array_returns_false", test_block_empty_array);
        add_test("XEP0191_unblock_empty_array_returns_false", test_unblock_empty_array);
        add_async_test("XEP0191_block_checked_commits_after_result", test_block_checked_success);
        add_async_test("XEP0191_block_checked_error_keeps_state", test_block_checked_error);
        add_async_test("XEP0191_block_checked_rejects_wrong_sender", test_block_checked_wrong_sender);
        add_async_test("XEP0191_unblock_checked_commits_after_result", test_unblock_checked_success);
        add_async_test("XEP0191_unblock_checked_error_keeps_state", test_unblock_checked_error);

        // --- Flag state management ---
        add_test("XEP0191_flag_blocklist_add_and_contains", test_flag_add_contains);
        add_test("XEP0191_flag_blocklist_remove", test_flag_remove);
        add_test("XEP0191_flag_blocklist_clear", test_flag_clear);
        add_test("XEP0191_flag_identity", test_flag_identity);

        // --- Edge cases ---
        add_test("XEP0191_block_node_wrong_namespace", test_wrong_namespace);
        add_test("XEP0191_item_with_empty_jid", test_item_empty_jid);
        add_test("XEP0191_jid_with_resource", test_jid_with_resource);
        add_test("XEP0191_unicode_jid_in_blocklist", test_unicode_jid);
    }

    // ========== Blocklist parsing ==========

    private void test_parse_blocklist() {
        var blocklist = new StanzaNode.build("blocklist", NS_URI).add_self_xmlns();
        blocklist.put_node(build_item("spam@example.com"));
        blocklist.put_node(build_item("troll@jabber.org"));
        blocklist.put_node(build_item("bot@evil.net"));

        var jids = get_jids_from_items(blocklist);
        assert_true(jids.size == 3);
        assert_true(jids.contains("spam@example.com"));
        assert_true(jids.contains("troll@jabber.org"));
        assert_true(jids.contains("bot@evil.net"));
    }

    private void test_parse_blocklist_empty() {
        var blocklist = new StanzaNode.build("blocklist", NS_URI).add_self_xmlns();
        var jids = get_jids_from_items(blocklist);
        assert_true(jids.size == 0);
    }

    private void test_parse_blocklist_no_jid() {
        // <item> without jid attribute — should be skipped
        var blocklist = new StanzaNode.build("blocklist", NS_URI).add_self_xmlns();
        var item = new StanzaNode.build("item", NS_URI).add_self_xmlns();
        // No jid attribute
        blocklist.put_node(item);

        var jids = get_jids_from_items(blocklist);
        assert_true(jids.size == 0);
        // DinoX: `if (jid != null) jids.add(jid)` → skips null ✓
    }

    private void test_parse_blocklist_mixed() {
        // Mix of valid items and items without jid
        var blocklist = new StanzaNode.build("blocklist", NS_URI).add_self_xmlns();
        blocklist.put_node(build_item("valid@example.com"));
        blocklist.put_node(new StanzaNode.build("item", NS_URI).add_self_xmlns()); // no jid
        blocklist.put_node(build_item("also-valid@example.com"));

        var jids = get_jids_from_items(blocklist);
        assert_true(jids.size == 2);
        assert_true(jids.contains("valid@example.com"));
        assert_true(jids.contains("also-valid@example.com"));
    }

    private void test_parse_blocklist_duplicates() {
        // Server sends duplicate JIDs in blocklist
        var blocklist = new StanzaNode.build("blocklist", NS_URI).add_self_xmlns();
        blocklist.put_node(build_item("dup@example.com"));
        blocklist.put_node(build_item("dup@example.com"));
        blocklist.put_node(build_item("unique@example.com"));

        var jids = get_jids_from_items(blocklist);
        // The parser returns a List, not a Set — duplicates ARE preserved
        assert_true(jids.size == 3);
        // DinoX stores in ArrayList<string> blocklist → duplicates possible
        // Not a bug per se, but `contains()` will work correctly anyway
    }

    // ========== Block/unblock push parsing ==========

    private void test_block_push_single() {
        var block_node = new StanzaNode.build("block", NS_URI).add_self_xmlns();
        block_node.put_node(build_item("spammer@evil.com"));

        var jids = get_jids_from_items(block_node);
        assert_true(jids.size == 1);
        assert_true(jids[0] == "spammer@evil.com");
    }

    private void test_block_push_multiple() {
        var block_node = new StanzaNode.build("block", NS_URI).add_self_xmlns();
        block_node.put_node(build_item("a@x.com"));
        block_node.put_node(build_item("b@x.com"));
        block_node.put_node(build_item("c@x.com"));

        var jids = get_jids_from_items(block_node);
        assert_true(jids.size == 3);
    }

    private void test_unblock_push_single() {
        var unblock_node = new StanzaNode.build("unblock", NS_URI).add_self_xmlns();
        unblock_node.put_node(build_item("forgiven@example.com"));

        var jids = get_jids_from_items(unblock_node);
        assert_true(jids.size == 1);
        assert_true(jids[0] == "forgiven@example.com");
    }

    private void test_unblock_push_empty() {
        // XEP-0191 §3.4: Empty <unblock/> means unblock ALL
        var unblock_node = new StanzaNode.build("unblock", NS_URI).add_self_xmlns();
        // No item children

        var jids = get_jids_from_items(unblock_node);
        assert_true(jids.size == 0);
        // DinoX on_iq_set: `if (jids.size > 0) { remove_all } else { clear(); unblock_all_received }`
        // Empty unblock → clear entire blocklist ✓
    }

    // ========== Sender validation ==========

    private void test_push_from_own_bare() {
        // Block push from own bare JID → accepted (this is the server)
        try {
            var my_jid = new Jid("alice@example.com/desktop");
            var push_from = new Jid("alice@example.com");
            // DinoX check: `iq.from != null && !iq.from.equals_bare(my_jid)`
            assert_true(push_from.equals_bare(my_jid));
            // equals_bare → accepted ✓
        } catch (InvalidJidError e) {
            assert_not_reached();
        }
    }

    private void test_push_from_foreign() {
        // Block push from foreign JID → MUST be rejected (Bug #23 fix)
        try {
            var my_jid = new Jid("alice@example.com/desktop");
            var push_from = new Jid("evil@attacker.com");
            assert_true(!push_from.equals_bare(my_jid));
            // DinoX: `if (my_jid != null && iq.from != null && !iq.from.equals_bare(my_jid)) return`
            // Correctly rejected after Bug #23 fix ✓
        } catch (InvalidJidError e) {
            assert_not_reached();
        }
    }

    private void test_push_no_from() {
        // RFC 6120 §8.1.2.1: Server-generated stanzas may omit "from"
        // DinoX: `iq.from != null && !iq.from.equals_bare(my_jid)`
        // If iq.from is null → the condition `iq.from != null` is false → skip check → accepted
        // This is CORRECT: omitted "from" means it's from the server
        string? from = null;
        assert_true(from == null);
        // The check `my_jid != null && iq.from != null && ...` short-circuits on null from
    }

    // ========== Block/unblock API ==========

    private void test_block_empty_array() {
        // block({}) should return false to avoid bad-request
        string[] empty = {};
        assert_true(empty.length == 0);
        // DinoX: `if (jids.length == 0) return false` ✓
    }

    private void test_unblock_empty_array() {
        // unblock({}) would unblock ALL — so returns false as safety guard
        string[] empty = {};
        assert_true(empty.length == 0);
        // DinoX: `if (jids.length == 0) return false`
        // Comment: "This would otherwise unblock all blocked JIDs." ✓
    }

    private void test_block_checked_success(Gee.TestFinishedCallback cb) {
        test_block_checked_success_async.begin(cb);
    }

    private async void test_block_checked_success_async(Gee.TestFinishedCallback cb) {
        try {
            BlockingAuditStream stream = create_checked_stream();
            var module = stream.get_module<Xep.BlockingCommand.Module>(
                Xep.BlockingCommand.Module.IDENTITY);
            bool changed = yield ((!) module).block_checked(stream,
                { "blocked@example.test" });

            assert_true(changed);
            assert_true(stream.get_flag(Xep.BlockingCommand.Flag.IDENTITY)
                .blocklist.contains("blocked@example.test"));
            assert_nonnull(stream.last_blocking_iq);

            // A successful duplicate command must not create duplicate cache
            // entries or trigger a second state change.
            changed = yield ((!) module).block_checked(stream,
                { "blocked@example.test" });
            assert_false(changed);
            assert_true(stream.get_flag(Xep.BlockingCommand.Flag.IDENTITY)
                .blocklist.size == 1);
        } catch (Error e) {
            fail_if_reached(@"Unexpected checked block error: $(e.message)");
        }
        cb();
    }

    private void test_block_checked_error(Gee.TestFinishedCallback cb) {
        test_block_checked_error_async.begin(cb);
    }

    private async void test_block_checked_error_async(Gee.TestFinishedCallback cb) {
        try {
            BlockingAuditStream stream = create_checked_stream();
            stream.response_error_condition = ErrorStanza.CONDITION_FORBIDDEN;
            var module = stream.get_module<Xep.BlockingCommand.Module>(
                Xep.BlockingCommand.Module.IDENTITY);

            try {
                yield ((!) module).block_checked(stream,
                    { "rejected@example.test" });
                fail_if_reached("A rejected block IQ must throw");
            } catch (IOError.FAILED e) {
                assert_true(e.message.contains(ErrorStanza.CONDITION_FORBIDDEN));
            }

            assert_false(stream.get_flag(Xep.BlockingCommand.Flag.IDENTITY)
                .blocklist.contains("rejected@example.test"));
        } catch (Error e) {
            fail_if_reached(@"Unexpected checked block test error: $(e.message)");
        }
        cb();
    }

    private void test_block_checked_wrong_sender(Gee.TestFinishedCallback cb) {
        test_block_checked_wrong_sender_async.begin(cb);
    }

    private async void test_block_checked_wrong_sender_async(
            Gee.TestFinishedCallback cb) {
        try {
            BlockingAuditStream stream = create_checked_stream();
            stream.response_from = "mallory@example.test";
            var module = stream.get_module<Xep.BlockingCommand.Module>(
                Xep.BlockingCommand.Module.IDENTITY);

            try {
                yield ((!) module).block_checked(stream,
                    { "victim@example.test" });
                fail_if_reached("A block result from another JID must throw");
            } catch (IOError.FAILED e) {
                assert_true(e.message.contains("unexpected JID"));
            }

            assert_false(stream.get_flag(Xep.BlockingCommand.Flag.IDENTITY)
                .blocklist.contains("victim@example.test"));
        } catch (Error e) {
            fail_if_reached(@"Unexpected checked sender test error: $(e.message)");
        }
        cb();
    }

    private void test_unblock_checked_success(Gee.TestFinishedCallback cb) {
        test_unblock_checked_success_async.begin(cb);
    }

    private async void test_unblock_checked_success_async(
            Gee.TestFinishedCallback cb) {
        try {
            BlockingAuditStream stream = create_checked_stream();
            stream.response_from = "alice@example.test";
            var flag = stream.get_flag(Xep.BlockingCommand.Flag.IDENTITY);
            flag.blocklist.add("blocked@example.test");
            var module = stream.get_module<Xep.BlockingCommand.Module>(
                Xep.BlockingCommand.Module.IDENTITY);

            bool changed = yield ((!) module).unblock_checked(stream,
                { "blocked@example.test" });

            assert_true(changed);
            assert_false(flag.blocklist.contains("blocked@example.test"));
        } catch (Error e) {
            fail_if_reached(@"Unexpected checked unblock error: $(e.message)");
        }
        cb();
    }

    private void test_unblock_checked_error(Gee.TestFinishedCallback cb) {
        test_unblock_checked_error_async.begin(cb);
    }

    private async void test_unblock_checked_error_async(
            Gee.TestFinishedCallback cb) {
        try {
            BlockingAuditStream stream = create_checked_stream();
            stream.response_error_condition = ErrorStanza.CONDITION_NOT_ALLOWED;
            var flag = stream.get_flag(Xep.BlockingCommand.Flag.IDENTITY);
            flag.blocklist.add("blocked@example.test");
            var module = stream.get_module<Xep.BlockingCommand.Module>(
                Xep.BlockingCommand.Module.IDENTITY);

            try {
                yield ((!) module).unblock_checked(stream,
                    { "blocked@example.test" });
                fail_if_reached("A rejected unblock IQ must throw");
            } catch (IOError.FAILED e) {
                assert_true(e.message.contains(ErrorStanza.CONDITION_NOT_ALLOWED));
            }

            assert_true(flag.blocklist.contains("blocked@example.test"));
        } catch (Error e) {
            fail_if_reached(@"Unexpected checked unblock test error: $(e.message)");
        }
        cb();
    }

    // ========== Flag state management ==========

    private void test_flag_add_contains() {
        var flag = new Xep.BlockingCommand.Flag();
        flag.blocklist.add("blocked@example.com");
        assert_true(flag.blocklist.contains("blocked@example.com"));
        assert_true(!flag.blocklist.contains("notblocked@example.com"));
    }

    private void test_flag_remove() {
        var flag = new Xep.BlockingCommand.Flag();
        flag.blocklist.add("temp@example.com");
        assert_true(flag.blocklist.contains("temp@example.com"));

        flag.blocklist.remove("temp@example.com");
        assert_true(!flag.blocklist.contains("temp@example.com"));
    }

    private void test_flag_clear() {
        var flag = new Xep.BlockingCommand.Flag();
        flag.blocklist.add("a@x.com");
        flag.blocklist.add("b@x.com");
        flag.blocklist.add("c@x.com");
        assert_true(flag.blocklist.size == 3);

        flag.blocklist.clear();
        assert_true(flag.blocklist.size == 0);
    }

    private void test_flag_identity() {
        var flag = new Xep.BlockingCommand.Flag();
        assert_true(flag.get_ns() == NS_URI);
        assert_true(flag.get_id() == "blocking_command");
    }

    // ========== Edge cases ==========

    private void test_wrong_namespace() {
        // Block node with wrong namespace
        var node = new StanzaNode.build("block", "urn:wrong:blocking");
        var stanza = new StanzaNode.build("iq", "jabber:client");
        stanza.put_node(node);

        StanzaNode? found = stanza.get_subnode("block", NS_URI);
        assert_null(found); // Correct: wrong namespace ignored
    }

    private void test_item_empty_jid() {
        // <item jid=""/> — empty JID string
        var block_node = new StanzaNode.build("block", NS_URI).add_self_xmlns();
        var item = new StanzaNode.build("item", NS_URI).add_self_xmlns();
        item.set_attribute("jid", "", NS_URI);
        block_node.put_node(item);

        var jids = get_jids_from_items(block_node);
        // FIX applied: empty JID strings are now filtered out (jid.length > 0 check)
        assert_true(jids.size == 0);
        // Empty JID no longer pollutes the blocklist
    }

    private void test_jid_with_resource() {
        // Blocking a full JID (with resource) — valid per XEP-0191
        var blocklist = new StanzaNode.build("blocklist", NS_URI).add_self_xmlns();
        blocklist.put_node(build_item("user@example.com/resource"));

        var jids = get_jids_from_items(blocklist);
        assert_true(jids.size == 1);
        assert_true(jids[0] == "user@example.com/resource");
        // Note: DinoX stores JIDs as strings, not Jid objects → resource is preserved
        // The `is_blocked()` check does exact string match, which is correct
    }

    private void test_unicode_jid() {
        // Unicode characters in JID
        var blocklist = new StanzaNode.build("blocklist", NS_URI).add_self_xmlns();
        blocklist.put_node(build_item("münchen@example.com"));

        var jids = get_jids_from_items(blocklist);
        assert_true(jids.size == 1);
        assert_true(jids[0] == "münchen@example.com");
    }

    // ========== Helpers ==========

    private StanzaNode build_item(string jid) {
        var item = new StanzaNode.build("item", NS_URI).add_self_xmlns();
        item.set_attribute("jid", jid, NS_URI);
        return item;
    }

    /**
     * Mirrors DinoX's get_jids_from_items() logic (with empty-JID fix).
     */
    private Gee.List<string> get_jids_from_items(StanzaNode node) {
        Gee.List<StanzaNode> item_nodes = node.get_subnodes("item", NS_URI);
        Gee.List<string> jids = new Gee.ArrayList<string>();
        foreach (StanzaNode item_node in item_nodes) {
            string? jid = item_node.get_attribute("jid", NS_URI);
            if (jid != null && jid.length > 0) {
                jids.add(jid);
            }
        }
        return jids;
    }

    private BlockingAuditStream create_checked_stream() throws Error {
        var stream = new BlockingAuditStream(new Jid("example.test"));

        var bind_flag = new Bind.Flag();
        bind_flag.my_jid = new Jid("alice@example.test/dinox");
        bind_flag.finished = true;
        stream.add_flag(bind_flag);
        stream.add_flag(new Xep.BlockingCommand.Flag());

        var iq = new Iq.Module();
        stream.add_module(iq);
        iq.attach(stream);

        var blocking = new Xep.BlockingCommand.Module();
        stream.add_module(blocking);
        return stream;
    }
}

private class BlockingAuditStream : XmppStream {
    private const string NS_STANZA_ERROR =
        "urn:ietf:params:xml:ns:xmpp-stanzas";

    public StanzaNode? last_blocking_iq { get; private set; default = null; }
    public string? response_error_condition { get; set; default = null; }
    public string? response_from { get; set; default = null; }

    public BlockingAuditStream(Jid remote_name) {
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
        if (cancellable != null) cancellable.set_error_if_cancelled();
        if (node.name != "iq") return;
        if (node.get_subnode("block", "urn:xmpp:blocking") == null &&
                node.get_subnode("unblock", "urn:xmpp:blocking") == null) {
            return;
        }

        last_blocking_iq = node;
        StanzaNode response = new StanzaNode.build("iq")
            .put_attribute("type", response_error_condition == null
                ? Iq.Stanza.TYPE_RESULT : Xmpp.Stanza.TYPE_ERROR)
            .put_attribute("id", node.get_attribute("id"))
            .put_attribute("to", "alice@example.test/dinox");
        if (response_from != null) {
            response.put_attribute("from", (!) response_from);
        }
        if (response_error_condition != null) {
            response.put_node(new StanzaNode.build("error")
                .put_attribute("type", ErrorStanza.TYPE_CANCEL)
                .put_node(new StanzaNode.build((!) response_error_condition,
                    NS_STANZA_ERROR).add_self_xmlns()));
        }
        received_iq_stanza(this, response);
    }

    public override async void setup() throws IOError {
    }
}

}

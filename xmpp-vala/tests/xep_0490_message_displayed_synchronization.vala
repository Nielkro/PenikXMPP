namespace Xmpp.Test {

class MessageDisplayedSyncTest : Gee.TestCase {
    private const string NS_MDS = "urn:xmpp:mds:displayed:0";
    private const string NS_SID = "urn:xmpp:sid:0";

    public MessageDisplayedSyncTest() {
        base("MessageDisplayedSync");
        add_test("roundtrip", test_roundtrip);
        add_test("muc_pm_item_id", test_muc_pm_item_id);
        add_test("exactly_one_stanza_id", test_exactly_one_stanza_id);
        add_test("wrong_payload_namespace", test_wrong_payload_namespace);
        add_test("missing_stanza_id_attributes",
            test_missing_stanza_id_attributes);
        add_test("nested_stanza_id_payload_rejected",
            test_nested_stanza_id_payload_rejected);
        add_test("full_authority_rejected", test_full_authority_rejected);
        add_test("invalid_item_jid_rejected", test_invalid_item_jid_rejected);
        add_test("unsafe_address_character_rejected",
            test_unsafe_address_character_rejected);
        add_test("extra_item_payload_rejected", test_extra_item_payload_rejected);
        add_test("wrong_item_namespace_rejected",
            test_wrong_item_namespace_rejected);
        add_test("event_item_namespace_accepted",
            test_event_item_namespace_accepted);
        add_test("private_publish_options", test_private_publish_options);
        add_test("pep_sender_must_be_own_bare",
            test_pep_sender_must_be_own_bare);
        add_test("live_event_and_notify_feature",
            test_live_event_and_notify_feature);
        add_test("server_assist_wire_shape",
            test_server_assist_wire_shape);
        add_test("server_assist_requires_nonempty_marker",
            test_server_assist_requires_nonempty_marker);
        add_test("server_assist_rejects_full_item_id",
            test_server_assist_rejects_full_item_id);
        add_async_test("publish_requires_publish_options_support", (cb) => {
            test_publish_requires_publish_options_support.begin(cb);
        });
        add_async_test("fetch_all_roundtrip", (cb) => {
            test_fetch_all_roundtrip.begin(cb);
        });
        add_async_test("fetch_cancelled_during_reconnect", (cb) => {
            test_reconnect_cancellation.begin(false, cb);
        });
        add_async_test("publish_cancelled_during_reconnect", (cb) => {
            test_reconnect_cancellation.begin(true, cb);
        });
        add_async_test("server_assist_discovers_account_feature", (cb) => {
            test_server_assist_discovers_account_feature.begin(cb);
        });
        add_async_test("server_assist_requires_advertisement", (cb) => {
            test_server_assist_requires_advertisement.begin(cb);
        });
    }

    private void test_roundtrip() {
        Jid chat = jid("romeo@example.test");
        Jid by = jid("juliet@example.test");
        StanzaNode? payload = Xep.MessageDisplayedSynchronization.Module
            .build_payload("stable-1", by);
        fail_if(payload == null, "A valid MDS payload must be built");
        if (payload == null) return;

        StanzaNode item = new StanzaNode.build("item",
                Xep.Pubsub.NS_URI)
            .put_attribute("id", chat.to_string())
            .put_node((!) payload);
        Xep.MessageDisplayedSynchronization.DisplayedItem? parsed =
            Xep.MessageDisplayedSynchronization.Module.parse_item(item);
        fail_if(parsed == null, "A valid MDS item must parse");
        if (parsed == null) return;
        fail_if_not_eq_str(((!) parsed).chat.to_string(), chat.to_string());
        fail_if_not_eq_str(((!) parsed).stanza_id, "stable-1");
        fail_if_not_eq_str(((!) parsed).by.to_string(), by.to_string());
    }

    private void test_muc_pm_item_id() {
        StanzaNode item = make_item("room@conference.example.test/alice",
            "room-private-1", "juliet@example.test");
        Xep.MessageDisplayedSynchronization.DisplayedItem? parsed =
            Xep.MessageDisplayedSynchronization.Module.parse_item(item);
        fail_if(parsed == null || !((!) parsed).chat.is_full(),
            "MUC private-message item IDs must retain the occupant resource");
    }

    private void test_exactly_one_stanza_id() {
        StanzaNode displayed = new StanzaNode.build("displayed", NS_MDS)
            .add_self_xmlns()
            .put_node(make_stanza_id("one", "juliet@example.test"))
            .put_node(make_stanza_id("two", "juliet@example.test"));
        fail_if(Xep.MessageDisplayedSynchronization.Module.parse_payload(
                "romeo@example.test", displayed) != null,
            "Ambiguous MDS payloads must be rejected");
    }

    private void test_wrong_payload_namespace() {
        StanzaNode displayed = new StanzaNode.build("displayed",
                "urn:example:wrong")
            .put_node(make_stanza_id("one", "juliet@example.test"));
        fail_if(Xep.MessageDisplayedSynchronization.Module.parse_payload(
                "romeo@example.test", displayed) != null,
            "A lookalike payload in another namespace must be rejected");
    }

    private void test_missing_stanza_id_attributes() {
        StanzaNode missing_id = new StanzaNode.build("displayed", NS_MDS)
            .put_node(new StanzaNode.build("stanza-id", NS_SID)
                .put_attribute("by", "juliet@example.test"));
        fail_if(Xep.MessageDisplayedSynchronization.Module.parse_payload(
                "romeo@example.test", missing_id) != null,
            "A stanza-id without id must be rejected");

        StanzaNode missing_by = new StanzaNode.build("displayed", NS_MDS)
            .put_node(new StanzaNode.build("stanza-id", NS_SID)
                .put_attribute("id", "one"));
        fail_if(Xep.MessageDisplayedSynchronization.Module.parse_payload(
                "romeo@example.test", missing_by) != null,
            "A stanza-id without assigning authority must be rejected");
    }

    private void test_nested_stanza_id_payload_rejected() {
        StanzaNode displayed = new StanzaNode.build("displayed", NS_MDS)
            .put_node(make_stanza_id("one", "juliet@example.test")
                .put_node(new StanzaNode.build("unexpected",
                    "urn:example")));
        fail_if(Xep.MessageDisplayedSynchronization.Module.parse_payload(
                "romeo@example.test", displayed) != null,
            "A stanza-id element with nested payload must be rejected");
    }

    private void test_full_authority_rejected() {
        StanzaNode item = make_item("romeo@example.test", "one",
            "juliet@example.test/device");
        fail_if(Xep.MessageDisplayedSynchronization.Module.parse_item(item) !=
                null,
            "A resource JID cannot assign a stable server stanza id");
    }

    private void test_invalid_item_jid_rejected() {
        StanzaNode item = make_item("not a jid", "one",
            "juliet@example.test");
        fail_if(Xep.MessageDisplayedSynchronization.Module.parse_item(item) !=
                null,
            "An invalid chat item JID must be rejected");
    }

    private void test_unsafe_address_character_rejected() {
        StanzaNode unsafe_chat = make_item(
            "romeo\t@example.test", "one", "juliet@example.test");
        fail_if(Xep.MessageDisplayedSynchronization.Module.parse_item(
                unsafe_chat) != null,
            "Control whitespace in a chat address must be rejected");

        StanzaNode unsafe_authority = make_item(
            "romeo@example.test", "one", "juliet\n@example.test");
        fail_if(Xep.MessageDisplayedSynchronization.Module.parse_item(
                unsafe_authority) != null,
            "Control whitespace in the assigning authority must be rejected");
    }

    private void test_extra_item_payload_rejected() {
        StanzaNode item = make_item("romeo@example.test", "one",
            "juliet@example.test");
        item.put_node(new StanzaNode.build("unexpected", "urn:example"));
        fail_if(Xep.MessageDisplayedSynchronization.Module.parse_item(item) !=
                null,
            "An item with multiple payloads must be rejected");
    }

    private void test_wrong_item_namespace_rejected() {
        StanzaNode item = new StanzaNode.build("item", "urn:example:wrong")
            .put_attribute("id", "romeo@example.test")
            .put_node(new StanzaNode.build("displayed", NS_MDS)
                .put_node(make_stanza_id("one", "juliet@example.test")));
        fail_if(Xep.MessageDisplayedSynchronization.Module.parse_item(item) !=
                null,
            "A lookalike item outside the PubSub namespace must be rejected");
    }

    private void test_event_item_namespace_accepted() {
        StanzaNode item = new StanzaNode.build("item",
                Xep.Pubsub.NS_URI_EVENT)
            .put_attribute("id", "romeo@example.test")
            .put_node(new StanzaNode.build("displayed", NS_MDS)
                .put_node(make_stanza_id("one", "juliet@example.test")));
        fail_if(Xep.MessageDisplayedSynchronization.Module.parse_item(item) ==
                null,
            "A strict live PubSub event item must use the event namespace");
    }

    private void test_private_publish_options() {
        Xep.Pubsub.PublishOptions options =
            Xep.MessageDisplayedSynchronization.Module
                .required_publish_options();
        fail_if_not_eq_str(options.settings["pubsub#persist_items"], "true");
        fail_if_not_eq_str(options.settings["pubsub#max_items"], "max");
        fail_if_not_eq_str(
            options.settings["pubsub#send_last_published_item"], "never");
        fail_if_not_eq_str(options.settings["pubsub#access_model"],
            Xep.Pubsub.ACCESS_MODEL_WHITELIST);
    }

    private void test_pep_sender_must_be_own_bare() {
        Jid own = jid("juliet@example.test");
        fail_if_not(Xep.MessageDisplayedSynchronization.Module
                .is_trusted_pep_sender(own, jid("juliet@example.test")),
            "The account's own bare PEP sender must be accepted");
        fail_if(Xep.MessageDisplayedSynchronization.Module
                .is_trusted_pep_sender(own,
                    jid("juliet@example.test/device")),
            "A full-JID sender must be rejected");
        fail_if(Xep.MessageDisplayedSynchronization.Module
                .is_trusted_pep_sender(own, jid("mallory@example.test")),
            "Another bare JID must not update private MDS state");
    }

    private void test_live_event_and_notify_feature() {
        var stream = new MessageDisplayedSyncStream(
            jid("example.test"));
        var discovery = new Xep.ServiceDiscovery.Module.with_identity(
            "client", "pc", "DinoX test");
        var discovery_flag = new Xep.ServiceDiscovery.Flag();
        stream.add_flag(discovery_flag);
        stream.add_module(discovery);

        var bind_flag = new Bind.Flag();
        bind_flag.my_jid = jid("juliet@example.test/desktop");
        bind_flag.finished = true;
        stream.add_flag(bind_flag);

        var message_module = new MessageModule();
        var pubsub = new Xep.Pubsub.Module();
        var mds = new Xep.MessageDisplayedSynchronization.Module();
        stream.add_module(message_module);
        stream.add_module(pubsub);
        stream.add_module(mds);
        message_module.attach(stream);
        pubsub.attach(stream);
        mds.attach(stream);

        fail_if(!discovery_flag.own_features.contains(NS_MDS + "+notify"),
            "Attaching XEP-0490 must advertise its PubSub notify feature");

        Xep.MessageDisplayedSynchronization.DisplayedItem? received = null;
        mds.displayed_received.connect((bound_stream, item) => {
            received = item;
        });

        var message = new MessageStanza();
        message.from = jid("juliet@example.test");
        message.to = jid("juliet@example.test/desktop");
        StanzaNode item = new StanzaNode.build("item",
                Xep.Pubsub.NS_URI_EVENT)
            .put_attribute("id", "romeo@example.test")
            .put_node(new StanzaNode.build("displayed", NS_MDS)
                .put_node(make_stanza_id("stable-1",
                    "juliet@example.test")));
        message.stanza.put_node(new StanzaNode.build("event",
                Xep.Pubsub.NS_URI_EVENT)
            .put_node(new StanzaNode.build("items",
                    Xep.Pubsub.NS_URI_EVENT)
                .put_attribute("node", NS_MDS)
                .put_node(item)));
        message_module.received_message(stream, message);

        fail_if(received == null,
            "A valid event from the account bare JID must be delivered");
        if (received != null) {
            fail_if_not_eq_str(((!) received).stanza_id, "stable-1");
        }

        received = null;
        message.from = jid("mallory@example.test");
        message_module.received_message(stream, message);
        fail_if(received != null,
            "A foreign PEP sender must not update XEP-0490 state");

        mds.detach(stream);
        fail_if(discovery_flag.own_features.contains(NS_MDS + "+notify"),
            "Detaching XEP-0490 must remove its notify feature");
        pubsub.detach(stream);
        message_module.detach(stream);
    }

    private void test_server_assist_wire_shape() {
        fail_if_not_eq_str(
            Xep.MessageDisplayedSynchronization.SERVER_ASSIST_FEATURE,
            "urn:xmpp:mds:server-assist:0",
            "Server assist discovery must use the exact stable feature");

        MessageStanza? message = Xep.MessageDisplayedSynchronization.Module
            .build_server_assisted_message(jid("romeo@example.test"),
                "sender-wire-id", MessageStanza.TYPE_CHAT,
                "account-stable-id", jid("juliet@example.test"));
        fail_if(message == null,
            "A valid displayed marker should carry server assist");
        if (message == null) return;

        fail_if_not_eq_str(((!) message).to.to_string(),
            "romeo@example.test",
            "A combined 1:1 marker must target the bare item JID");
        fail_if_not_eq_int(((!) message).stanza.get_subnodes("displayed",
                Xep.ChatMarkers.NS_URI).size, 1,
            "The combined stanza must retain the contact-visible marker");
        Gee.List<StanzaNode> mds_nodes = ((!) message).stanza.get_subnodes(
            "displayed", NS_MDS);
        fail_if_not_eq_int(mds_nodes.size, 1,
            "The combined stanza must contain one server-visible MDS node");
        if (mds_nodes.size == 1) {
            Xep.MessageDisplayedSynchronization.DisplayedItem? item =
                Xep.MessageDisplayedSynchronization.Module.parse_payload(
                    "romeo@example.test", mds_nodes[0]);
            fail_if(item == null ||
                    ((!) item).stanza_id != "account-stable-id" ||
                    !((!) item).by.equals(jid("juliet@example.test")),
                "The assisted payload must preserve the stable (id, by)");
        }
    }

    private void test_server_assist_requires_nonempty_marker() {
        MessageStanza? message = Xep.MessageDisplayedSynchronization.Module
            .build_server_assisted_message(jid("romeo@example.test"),
                " \t ", MessageStanza.TYPE_CHAT, "account-stable-id",
                jid("juliet@example.test"));
        fail_if(message != null,
            "MDS must never create an otherwise-empty message");
    }

    private void test_server_assist_rejects_full_item_id() {
        MessageStanza? message = Xep.MessageDisplayedSynchronization.Module
            .build_server_assisted_message(
                jid("room@conference.example.test/alice"),
                "sender-wire-id", MessageStanza.TYPE_CHAT,
                "account-stable-id", jid("juliet@example.test"));
        fail_if(message != null,
            "MUC-PM full item IDs must remain on regular PubSub");
    }

    private async void test_publish_requires_publish_options_support(
            Gee.TestFinishedCallback cb) {
        try {
            var stream = create_iq_stream(false);
            Xep.MessageDisplayedSynchronization.Module mds = stream.get_module<
                Xep.MessageDisplayedSynchronization.Module>(
                    Xep.MessageDisplayedSynchronization.Module.IDENTITY);

            Xep.MessageDisplayedSynchronization.PublishResult result =
                yield mds.publish_displayed(stream,
                    jid("romeo@example.test"), "stable-1",
                    jid("juliet@example.test"));
            fail_if(result.ok || !result.unsupported,
                "A server without pubsub#publish-options must be rejected " +
                "as unsupported");
            fail_if(stream.written_nodes.size != 0,
                "Unsupported publication must stop before writing an IQ");
        } catch (Error error) {
            fail_if_reached("Unexpected XEP-0490 publish test error: " +
                error.message);
        }
        cb();
    }

    private async void test_reconnect_cancellation(bool publish,
            Gee.TestFinishedCallback cb) {
        try {
            for (int mode = 0; mode < 3; mode++) {
                var stream = create_iq_stream(true);
                var cancel = new Cancellable();
                stream.cancel_on_response = mode == 0 ? null : cancel;
                stream.detach_on_response = mode == 2;
                if (mode == 0) cancel.cancel();
                var mds = stream.get_module<Xep.MessageDisplayedSynchronization.Module>(
                    Xep.MessageDisplayedSynchronization.Module.IDENTITY);
                if (publish) {
                    var result = yield mds.publish_displayed(stream,
                        jid("romeo@example.test"), "stable-1", jid("juliet@example.test"), cancel);
                    fail_if(result != null && result.ok,
                        "A cancelled publication must not confirm synchronized read state");
                } else {
                    var result = yield mds.fetch_all(stream, cancel);
                    fail_if(result != null && result.ok,
                        "A cancelled fetch must not confirm an empty remote read state");
                }
                fail_if_not_eq_int(stream.written_nodes.size, mode == 0 ? 0 : 1,
                    "Cancellation must prevent further requests on the old stream");
            }
        } catch (Error e) {
            fail_if_reached(@"Unexpected read-state cancellation error: $(e.message)");
        }
        cb();
    }

    private async void test_fetch_all_roundtrip(
            Gee.TestFinishedCallback cb) {
        try {
            var stream = create_iq_stream(true);
            stream.fetch_items.add(make_item("romeo@example.test",
                "stable-1", "juliet@example.test"));
            stream.fetch_items.add(make_item(
                "room@conference.example.test", "stable-2",
                "room@conference.example.test"));
            Xep.MessageDisplayedSynchronization.Module mds = stream.get_module<
                Xep.MessageDisplayedSynchronization.Module>(
                    Xep.MessageDisplayedSynchronization.Module.IDENTITY);

            Xep.MessageDisplayedSynchronization.FetchResult result =
                yield mds.fetch_all(stream);
            fail_if(!result.ok || result.items.size != 2,
                "Fetch-all must return every valid persisted MDS item");
            fail_if(stream.written_nodes.size != 1,
                "Fetch-all must issue exactly one PubSub IQ");
            if (stream.written_nodes.size == 1) {
                StanzaNode request = stream.written_nodes[0];
                fail_if_not_eq_str(request.get_attribute("to"),
                    "juliet@example.test",
                    "MDS catch-up must query the account's own PEP service");
                StanzaNode? pubsub = request.get_subnode("pubsub",
                    Xep.Pubsub.NS_URI);
                StanzaNode? items = pubsub != null
                    ? ((!) pubsub).get_subnode("items", Xep.Pubsub.NS_URI)
                    : null;
                fail_if(items == null || ((!) items).get_attribute("node") !=
                        NS_MDS,
                    "MDS catch-up must request the displayed-state node");
            }
        } catch (Error error) {
            fail_if_reached("Unexpected XEP-0490 fetch test error: " +
                error.message);
        }
        cb();
    }

    private async void test_server_assist_discovers_account_feature(
            Gee.TestFinishedCallback cb) {
        try {
            var stream = create_iq_stream(true);
            var cache = new MessageDisplayedSyncServerAssistCapsCache();
            Xep.ServiceDiscovery.Module discovery = stream.get_module<
                Xep.ServiceDiscovery.Module>(
                    Xep.ServiceDiscovery.Module.IDENTITY);
            discovery.cache = cache;
            Xep.MessageDisplayedSynchronization.Module mds =
                stream.get_module<
                    Xep.MessageDisplayedSynchronization.Module>(
                        Xep.MessageDisplayedSynchronization.Module.IDENTITY);

            bool supported = yield mds.supports_server_assist(stream);
            fail_if(!supported,
                "The exact server-assist feature should be accepted");
            fail_if(cache.queried_jid == null ||
                    !((!) cache.queried_jid).equals(
                        jid("juliet@example.test")),
                "Server assist must be discovered on the account bare JID");
            fail_if_not_eq_str(cache.queried_feature,
                Xep.MessageDisplayedSynchronization.SERVER_ASSIST_FEATURE,
                "No legacy or draft server-assist namespace may be queried");
        } catch (Error error) {
            fail_if_reached("Unexpected server-assist discovery error: " +
                error.message);
        }
        cb();
    }

    private async void test_server_assist_requires_advertisement(
            Gee.TestFinishedCallback cb) {
        try {
            var stream = create_iq_stream(true);
            Xep.MessageDisplayedSynchronization.Module mds =
                stream.get_module<
                    Xep.MessageDisplayedSynchronization.Module>(
                        Xep.MessageDisplayedSynchronization.Module.IDENTITY);
            bool sent = yield mds.send_server_assisted_displayed(stream,
                jid("romeo@example.test"), "sender-wire-id",
                MessageStanza.TYPE_CHAT, "account-stable-id",
                jid("juliet@example.test"));
            fail_if(sent,
                "Server assist must fail closed without advertisement");
            fail_if(stream.written_nodes.size != 0,
                "An unsupported server must never receive the MDS payload");
        } catch (Error error) {
            fail_if_reached("Unexpected server-assist guard error: " +
                error.message);
        }
        cb();
    }

    private MessageDisplayedSyncIqStream create_iq_stream(
            bool supports_publish_options) throws Error {
        var stream = new MessageDisplayedSyncIqStream(jid("example.test"));
        var bind_flag = new Bind.Flag();
        bind_flag.my_jid = jid("juliet@example.test/desktop");
        bind_flag.finished = true;
        stream.add_flag(bind_flag);

        var iq = new Iq.Module();
        stream.add_module(iq);
        iq.attach(stream);

        var discovery = new Xep.ServiceDiscovery.Module.with_identity(
            "client", "pc", "DinoX test");
        discovery.cache = new MessageDisplayedSyncCapsCache(
            supports_publish_options);
        stream.add_module(discovery);
        stream.add_module(new Xep.Pubsub.Module());
        stream.add_module(new Xep.MessageDisplayedSynchronization.Module());
        return stream;
    }

    private StanzaNode make_item(string item_id, string stanza_id,
            string by) {
        return new StanzaNode.build("item", Xep.Pubsub.NS_URI)
            .put_attribute("id", item_id)
            .put_node(new StanzaNode.build("displayed", NS_MDS)
                .put_node(make_stanza_id(stanza_id, by)));
    }

    private StanzaNode make_stanza_id(string id, string by) {
        return new StanzaNode.build("stanza-id", NS_SID)
            .put_attribute("id", id)
            .put_attribute("by", by);
    }

    private Jid jid(string value) {
        try {
            return new Jid(value);
        } catch (InvalidJidError error) {
            assert_not_reached();
        }
    }
}

private class MessageDisplayedSyncStream : XmppStream {
    public MessageDisplayedSyncStream(Jid remote_name) {
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

private class MessageDisplayedSyncCapsCache : Object,
        Xep.ServiceDiscovery.CapsCache {
    private bool supports_publish_options;

    public MessageDisplayedSyncCapsCache(bool supports_publish_options) {
        this.supports_publish_options = supports_publish_options;
    }

    public async bool has_entity_feature(Jid jid, string feature) {
        return supports_publish_options && feature ==
            Xep.MessageDisplayedSynchronization.PUBLISH_OPTIONS_FEATURE;
    }

    public async Gee.Set<Xep.ServiceDiscovery.Identity>
            get_entity_identities(Jid jid) {
        return new Gee.HashSet<Xep.ServiceDiscovery.Identity>(
            Xep.ServiceDiscovery.Identity.hash_func,
            Xep.ServiceDiscovery.Identity.equals_func);
    }
}

private class MessageDisplayedSyncServerAssistCapsCache : Object,
        Xep.ServiceDiscovery.CapsCache {
    public Jid? queried_jid { get; private set; }
    public string? queried_feature { get; private set; }

    public async bool has_entity_feature(Jid jid, string feature) {
        queried_jid = jid;
        queried_feature = feature;
        return feature ==
            Xep.MessageDisplayedSynchronization.SERVER_ASSIST_FEATURE;
    }

    public async Gee.Set<Xep.ServiceDiscovery.Identity>
            get_entity_identities(Jid jid) {
        return new Gee.HashSet<Xep.ServiceDiscovery.Identity>(
            Xep.ServiceDiscovery.Identity.hash_func,
            Xep.ServiceDiscovery.Identity.equals_func);
    }
}

private class MessageDisplayedSyncIqStream : XmppStream {
    public Cancellable? cancel_on_response { get; set; }
    public bool detach_on_response { get; set; default = false; }
    public Gee.ArrayList<StanzaNode> written_nodes =
        new Gee.ArrayList<StanzaNode>();
    public Gee.ArrayList<StanzaNode> fetch_items =
        new Gee.ArrayList<StanzaNode>();

    public MessageDisplayedSyncIqStream(Jid remote_name) {
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
        written_nodes.add(node);

        Idle.add(() => {
            if (detach_on_response) get_module<Iq.Module>(Iq.Module.IDENTITY).detach(this);
            if (cancel_on_response != null) cancel_on_response.cancel();
            var response = new StanzaNode.build("iq", "jabber:client")
                .put_attribute("id", node.get_attribute("id"))
                .put_attribute("type", "result")
                .put_attribute("from", "juliet@example.test");
            StanzaNode? request_pubsub = node.get_subnode("pubsub",
                Xep.Pubsub.NS_URI);
            StanzaNode? request_items = request_pubsub != null
                ? ((!) request_pubsub).get_subnode("items", Xep.Pubsub.NS_URI)
                : null;
            if (request_items != null && ((!) request_items).get_attribute(
                    "node") == Xep.MessageDisplayedSynchronization.NS_URI) {
                var pubsub = new StanzaNode.build("pubsub", Xep.Pubsub.NS_URI)
                    .add_self_xmlns();
                var items = new StanzaNode.build("items", Xep.Pubsub.NS_URI)
                    .put_attribute("node",
                        Xep.MessageDisplayedSynchronization.NS_URI);
                foreach (StanzaNode item in fetch_items) items.put_node(item);
                pubsub.put_node(items);
                response.put_node(pubsub);
            }
            received_iq_stanza(this, response);
            return Source.REMOVE;
        });
    }

    public override async void setup() throws IOError {
    }
}

}

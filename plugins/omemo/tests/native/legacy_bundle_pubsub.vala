/*
 * Tests for legacy OMEMO v1 bundle PubSub item selection.
 *
 * Legacy OMEMO stores each device bundle in a node named
 * eu.siacs.conversations.axolotl.bundles:<device-id>. Real clients disagree
 * on the item id inside that node: Dino historically used "1", while
 * Conversations, Monal, Gajim and Monocles use "current". DinoX must accept
 * both and prefer the modern "current" item when both are present.
 */

using Dino.Plugins.Omemo;
using Xmpp;

namespace Omemo.Test {

class LegacyBundlePubSubTest : Gee.TestCase {

    private const string NS_PUBSUB = "http://jabber.org/protocol/pubsub";
    private const string NS_PUBSUB_OWNER = "http://jabber.org/protocol/pubsub#owner";
    private const string NS_DATA_FORMS = "jabber:x:data";
    private const string NS_OMEMO = "eu.siacs.conversations.axolotl";

    public LegacyBundlePubSubTest() {
        base("LegacyBundlePubSub");

        add_test("XEP0384v03_bundle_selects_current", test_selects_current);
        add_test("XEP0384v03_bundle_falls_back_to_legacy_one", test_falls_back_to_legacy_one);
        add_test("XEP0384v03_bundle_skips_empty_current", test_skips_empty_current);
        add_test("XEP0384v03_bundle_falls_back_to_first_payload", test_falls_back_to_first_payload);
        add_test("XEP0384v03_own_publish_resource_constraint_uses_long_backoff", test_resource_constraint_long_backoff);
        add_test("XEP0384v03_own_publish_other_errors_keep_short_backoff", test_other_errors_short_backoff);
        add_test("XEP0384v03_missing_own_devicelist_resource_constraint_defers_bundle_probe", test_missing_own_devicelist_resource_constraint_defers_bundle_probe);
        add_test("XEP0384v03_devicelist_retries_without_unknown_max_items_publish_option", test_devicelist_retries_without_unknown_max_items_publish_option);
        add_test("XEP0384v03_missing_new_device_bundle_retries_before_ignore", test_missing_new_device_bundle_retries_before_ignore);
        add_test("XEP0384v03_bundle_access_denial_finishes_jingle_wait_without_ignoring_or_retry", test_bundle_access_denial);
        add_test("XEP0384v03_transient_bundle_retry_survives_same_key_stream_replacement", test_transient_retry_replacement);
        add_test("XEP0384v03_cancelled_devicelist_is_not_failed_or_empty_state", test_devicelist_cancelled);
        add_test("XEP0384v03_remote_cancel_error_still_reports_failure", test_devicelist_remote_error);
        add_test("XEP0384v08_own_publish_resource_constraint_uses_long_backoff", test_v2_resource_constraint_long_backoff);
        add_test("XEP0384v08_own_publish_other_errors_keep_short_backoff", test_v2_other_errors_short_backoff);
        add_test("XEP0384v08_missing_own_devicelist_resource_constraint_defers_bundle_probe", test_v2_missing_own_devicelist_resource_constraint_defers_bundle_probe);
        add_test("XEP0384v08_own_devicelist_publish_resource_constraint_sets_retry_state", test_v2_devicelist_publish_resource_constraint_sets_retry_state);
        add_test("XEP0384v08_devicelist_retries_without_unknown_max_items_publish_option", test_v2_devicelist_retries_without_unknown_max_items_publish_option);
    }

    private StanzaNode item(string id, string marker) {
        return new StanzaNode.build("item", NS_PUBSUB)
            .put_attribute("id", id)
            .put_node(new StanzaNode.build("bundle", NS_OMEMO)
                .put_attribute("marker", marker));
    }

    private StanzaNode empty_item(string id) {
        return new StanzaNode.build("item", NS_PUBSUB)
            .put_attribute("id", id);
    }

    private Gee.ArrayList<StanzaNode> new_items() {
        var list = new Gee.ArrayList<StanzaNode>();
        return list;
    }

    private void test_selects_current() {
        var list = new_items();
        list.add(item("1", "stale"));
        list.add(item("current", "fresh"));
        string? selected_id = null;
        StanzaNode? payload = StreamModule.select_legacy_bundle_payload(list, out selected_id);

        fail_if(payload == null, "current payload must be selected");
        fail_if_not_eq_str(selected_id, "current", "must prefer item id current");
        fail_if_not_eq_str(((!)payload).get_attribute("marker"), "fresh", "must select fresh payload");
    }

    private void test_falls_back_to_legacy_one() {
        var list = new_items();
        list.add(item("1", "legacy"));
        string? selected_id = null;
        StanzaNode? payload = StreamModule.select_legacy_bundle_payload(list, out selected_id);

        fail_if(payload == null, "legacy item payload must be selected");
        fail_if_not_eq_str(selected_id, "1", "must support old Dino item id 1");
        fail_if_not_eq_str(((!)payload).get_attribute("marker"), "legacy", "must select legacy payload");
    }

    private void test_skips_empty_current() {
        var list = new_items();
        list.add(empty_item("current"));
        list.add(item("1", "legacy"));
        string? selected_id = null;
        StanzaNode? payload = StreamModule.select_legacy_bundle_payload(list, out selected_id);

        fail_if(payload == null, "legacy item must be selected when current is empty");
        fail_if_not_eq_str(selected_id, "1", "empty current must not shadow legacy payload");
        fail_if_not_eq_str(((!)payload).get_attribute("marker"), "legacy", "must select non-empty payload");
    }

    private void test_falls_back_to_first_payload() {
        var list = new_items();
        list.add(item("server-generated", "fallback"));
        string? selected_id = null;
        StanzaNode? payload = StreamModule.select_legacy_bundle_payload(list, out selected_id);

        fail_if(payload == null, "first valid payload must be selected");
        fail_if_not_eq_str(selected_id, "server-generated", "must return selected fallback id");
        fail_if_not_eq_str(((!)payload).get_attribute("marker"), "fallback", "must select fallback payload");
    }

    private void test_resource_constraint_long_backoff() {
        fail_if_not_eq_int((int) StreamModule.get_own_publish_retry_delay_for_error(
                ErrorStanza.TYPE_WAIT, ErrorStanza.CONDITION_RESOURCE_CONSTRAINT, 1),
            600, "wait/resource-constraint must not retry after 30 seconds");
        fail_if_not_eq_int((int) StreamModule.get_own_publish_retry_delay_for_error(
                ErrorStanza.TYPE_WAIT, ErrorStanza.CONDITION_RESOURCE_CONSTRAINT, 2),
            1800, "second wait/resource-constraint retry must remain throttled");
        fail_if_not_eq_int((int) StreamModule.get_own_publish_retry_delay_for_error(
                ErrorStanza.TYPE_WAIT, ErrorStanza.CONDITION_RESOURCE_CONSTRAINT, 3),
            3600, "later wait/resource-constraint retries must use hourly backoff");
    }

    private void test_other_errors_short_backoff() {
        fail_if_not_eq_int((int) StreamModule.get_own_publish_retry_delay_for_error(
                ErrorStanza.TYPE_CANCEL, ErrorStanza.CONDITION_FORBIDDEN, 1),
            30, "non-throttle errors keep existing first retry delay");
        fail_if_not_eq_int((int) StreamModule.get_own_publish_retry_delay_for_error(
                ErrorStanza.TYPE_CANCEL, ErrorStanza.CONDITION_FORBIDDEN, 2),
            60, "non-throttle errors keep existing second retry delay");
        fail_if_not_eq_int((int) StreamModule.get_own_publish_retry_delay_for_error(
                ErrorStanza.TYPE_CANCEL, ErrorStanza.CONDITION_FORBIDDEN, 4),
            300, "non-throttle errors keep existing max retry delay");
    }

    private void test_missing_new_device_bundle_retries_before_ignore() {
        try {
            Context context = new Context();
            Store store = setup_test_store_context(context);
            var stream = create_pubsub_test_stream(new Jid("alice@example.test/dinox"));
            var module = new StreamModule(store);
            stream.add_module(module);

            var remote = new Jid("bob@example.test");
            int32 device_id = 4242;
            string expected_node = NS_OMEMO + ".bundles:" + device_id.to_string();
            int requests = 0;
            int failures = 0;
            var loop = new MainLoop();

            stream.wrote_node.connect((outgoing) => {
                string? items_node = get_pubsub_child_node(outgoing, "items");
                if (items_node != expected_node) return;
                requests++;
                respond_empty_pubsub_items(stream, outgoing, (!) items_node);
            });
            module.bundle_fetch_failed.connect((jid, failed_device_id) => {
                if (!jid.equals_bare(remote) || failed_device_id != device_id) return;
                failures++;
                loop.quit();
            });

            uint timeout_id = Timeout.add_seconds(4, () => {
                loop.quit();
                return Source.REMOVE;
            });
            module.fetch_bundle(stream, remote, device_id, false);
            loop.run();
            if (timeout_id != 0) Source.remove(timeout_id);

            fail_if_not_eq_int(requests, 2,
                "newly advertised legacy device must get exactly one bundle publication grace retry");
            fail_if_not_eq_int(failures, 1,
                "missing bundle must become terminal only after the grace retry");
            fail_if(!module.is_ignored_device(remote, device_id),
                "device without a bundle after retry must be explicitly classified as unavailable");
            module.detach(stream);
        } catch (Error e) {
            fail_if_reached("legacy missing bundle retry test failed: %s".printf(e.message));
        }
    }

    private void test_bundle_access_denial() {
        PubSubTestXmppStream? stream = null;
        StreamModule? module = null;
        uint timeout = 0;
        uint retry_check = 0;
        try {
            Store store = setup_test_store_context(Plugin.get_context());
            var own = new Jid("alice@example.test/dinox");
            var peer = new Jid("bob@example.test");
            var test_stream = create_pubsub_test_stream(own);
            stream = test_stream;
            var test_module = new StreamModule(store);
            module = test_module;
            test_module.auto_publish_own_device_list = false;
            test_stream.add_module(test_module);
            int device_id = 4242;
            int requests = 0;
            int denials = 0;
            int old_failures = 0;
            test_module.bundle_access_denied.connect((jid, id, presence_required) => {
                fail_if_not(jid.equals_bare(peer));
                fail_if_not_eq_int(id, device_id);
                fail_if_not(presence_required);
                denials++;
            });
            test_module.bundle_fetch_failed.connect((jid, id) => old_failures++);
            test_stream.wrote_node.connect((outgoing) => {
                if (get_pubsub_child_node(outgoing, "items") != NS_OMEMO + ".bundles:4242") return;
                requests++;
                Idle.add(() => {
                    var request = new Iq.Stanza.from_stanza(outgoing, own);
                    var error = new ErrorStanza.build(ErrorStanza.TYPE_AUTH,
                        requests == 1 ? ErrorStanza.CONDITION_NOT_AUTHORIZED : ErrorStanza.CONDITION_FORBIDDEN,
                        null, new StanzaNode.build("presence-subscription-required",
                            "http://jabber.org/protocol/pubsub#errors"));
                    var response = new Iq.Stanza.error(request, error);
                    response.from = peer;
                    response.to = own;
                    test_stream.emit_iq_result(response.stanza);
                    return Source.REMOVE;
                });
            });
            var loop = new MainLoop();
            timeout = Timeout.add(3000, () => {
                timeout = 0;
                fail_if_reached("An access denial must finish the Jingle session waiter immediately");
                loop.quit();
                return Source.REMOVE;
            });
            GLib.Test.expect_message("xmpp-vala", GLib.LogLevelFlags.LEVEL_WARNING,
                "*Failed to request pubsub items*not-authorized*");
            bool completed = false;
            test_module.ensure_legacy_session_for_send.begin(test_stream, peer,
                device_id, new Cancellable(), (obj, res) => {
                fail_if(test_module.ensure_legacy_session_for_send.end(res));
                completed = true;
                loop.quit();
            });
            if (!completed) loop.run();
            GLib.Test.assert_expected_messages();
            if (timeout != 0) { Source.remove(timeout); timeout = 0; }
            fail_if_not(completed);
            fail_if_not_eq_int(requests, 1);
            fail_if_not_eq_int(denials, 1);
            fail_if(test_module.is_ignored_device(peer, device_id));
            fail_if(test_module.has_legacy_session_for_send(peer, device_id));
            fail_if(test_module.active_bundle_requests.contains("bob@example.test:4242"));

            // A deliberate later attempt is allowed, while neither denial
            // schedules the old transient retry or its counter-decrement path.
            GLib.Test.expect_message("xmpp-vala", GLib.LogLevelFlags.LEVEL_WARNING,
                "*Failed to request pubsub items*forbidden*");
            test_module.fetch_bundle(test_stream, peer, device_id, false);
            retry_check = Timeout.add(3200, () => {
                retry_check = 0;
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            GLib.Test.assert_expected_messages();
            fail_if_not_eq_int(requests, 2, "Access denial must not trigger the two-second transient retry");
            fail_if_not_eq_int(denials, 2);
            fail_if_not_eq_int(old_failures, 0, "Access denial must not release pending counters through continue_message_sending");
            fail_if(test_module.is_ignored_device(peer, device_id));
        } catch (Error e) { fail_if_reached(e.message); }
        finally {
            if (timeout != 0) Source.remove(timeout);
            if (retry_check != 0) Source.remove(retry_check);
            if (stream != null && module != null) {
                module.detach(stream);
                stream.get_module<Iq.Module>(Iq.Module.IDENTITY).detach(stream);
            }
        }
    }

    private void test_transient_retry_replacement() {
        PubSubTestXmppStream? old_stream = null;
        PubSubTestXmppStream? new_stream = null;
        StreamModule? module = null;
        uint timeout = 0;
        uint replace_source = 0;
        try {
            Store store = setup_test_store_context(Plugin.get_context());
            var own = new Jid("alice@example.test/dinox");
            var peer = new Jid("bob@example.test");
            var first = create_pubsub_test_stream(own);
            var second = create_pubsub_test_stream(own);
            old_stream = first;
            new_stream = second;
            var test_module = new StreamModule(store);
            module = test_module;
            test_module.auto_publish_own_device_list = false;
            first.add_module(test_module);
            int old_requests = 0;
            int current_requests = 0;
            var loop = new MainLoop();
            first.wrote_node.connect((outgoing) => {
                if (get_pubsub_child_node(outgoing, "items") != NS_OMEMO + ".bundles:4242") return;
                old_requests++;
                Idle.add(() => {
                    var request = new Iq.Stanza.from_stanza(outgoing, own);
                    var response = new Iq.Stanza.error(request, new ErrorStanza.service_unavailable());
                    response.from = peer;
                    response.to = own;
                    first.emit_iq_result(response.stanza);
                    return Source.REMOVE;
                });
            });
            second.wrote_node.connect((outgoing) => {
                if (get_pubsub_child_node(outgoing, "items") != NS_OMEMO + ".bundles:4242") return;
                int attempt = ++current_requests;
                Idle.add(() => {
                    var request = new Iq.Stanza.from_stanza(outgoing, own);
                    var error = attempt == 1 ? new ErrorStanza.service_unavailable()
                        : new ErrorStanza.build(ErrorStanza.TYPE_AUTH,
                            ErrorStanza.CONDITION_FORBIDDEN, null, null);
                    var response = new Iq.Stanza.error(request, error);
                    response.from = peer;
                    response.to = own;
                    second.emit_iq_result(response.stanza);
                    return Source.REMOVE;
                });
            });
            test_module.bundle_access_denied.connect((jid, device_id, presence_required) => loop.quit());
            GLib.Test.expect_message("xmpp-vala", GLib.LogLevelFlags.LEVEL_WARNING,
                "*Failed to request pubsub items*service-unavailable*");
            GLib.Test.expect_message("xmpp-vala", GLib.LogLevelFlags.LEVEL_WARNING,
                "*Failed to request pubsub items*service-unavailable*");
            GLib.Test.expect_message("xmpp-vala", GLib.LogLevelFlags.LEVEL_WARNING,
                "*Failed to request pubsub items*forbidden*");
            test_module.fetch_bundle(first, peer, 4242, false);
            replace_source = Timeout.add(100, () => {
                replace_source = 0;
                test_module.detach(first);
                first.get_module<Iq.Module>(Iq.Module.IDENTITY).detach(first);
                second.add_module(test_module);
                test_module.fetch_bundle(second, peer, 4242, false);
                return Source.REMOVE;
            });
            timeout = Timeout.add(4500, () => {
                timeout = 0;
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            GLib.Test.assert_expected_messages();
            fail_if_not_eq_int(old_requests, 1, "A replaced stream must not resume its pending retry");
            fail_if_not_eq_int(current_requests, 2,
                "An old same-key timer must not consume the replacement stream's transient retry");
            fail_if(test_module.active_bundle_requests.contains("bob@example.test:4242"));
            fail_if(test_module.is_ignored_device(peer, 4242));
        } catch (Error e) { fail_if_reached(e.message); }
        finally {
            if (timeout != 0) Source.remove(timeout);
            if (replace_source != 0) Source.remove(replace_source);
            if (old_stream != null) old_stream.get_module<Iq.Module>(Iq.Module.IDENTITY).detach(old_stream);
            if (new_stream != null && module != null) {
                module.detach(new_stream);
                new_stream.get_module<Iq.Module>(Iq.Module.IDENTITY).detach(new_stream);
            }
        }
    }

    private void test_v2_resource_constraint_long_backoff() {
        fail_if_not_eq_int((int) StreamModule2.get_own_publish_retry_delay_for_error(
                ErrorStanza.TYPE_WAIT, ErrorStanza.CONDITION_RESOURCE_CONSTRAINT, 1),
            600, "OMEMO 2 wait/resource-constraint must not retry after 30 seconds");
        fail_if_not_eq_int((int) StreamModule2.get_own_publish_retry_delay_for_error(
                ErrorStanza.TYPE_WAIT, ErrorStanza.CONDITION_RESOURCE_CONSTRAINT, 2),
            1800, "OMEMO 2 second wait/resource-constraint retry must remain throttled");
        fail_if_not_eq_int((int) StreamModule2.get_own_publish_retry_delay_for_error(
                ErrorStanza.TYPE_WAIT, ErrorStanza.CONDITION_RESOURCE_CONSTRAINT, 3),
            3600, "OMEMO 2 later wait/resource-constraint retries must use hourly backoff");
    }

    private void test_v2_other_errors_short_backoff() {
        fail_if_not_eq_int((int) StreamModule2.get_own_publish_retry_delay_for_error(
                ErrorStanza.TYPE_CANCEL, ErrorStanza.CONDITION_FORBIDDEN, 1),
            30, "OMEMO 2 non-throttle errors keep existing first retry delay");
        fail_if_not_eq_int((int) StreamModule2.get_own_publish_retry_delay_for_error(
                ErrorStanza.TYPE_CANCEL, ErrorStanza.CONDITION_FORBIDDEN, 2),
            60, "OMEMO 2 non-throttle errors keep existing second retry delay");
        fail_if_not_eq_int((int) StreamModule2.get_own_publish_retry_delay_for_error(
                ErrorStanza.TYPE_CANCEL, ErrorStanza.CONDITION_FORBIDDEN, 4),
            300, "OMEMO 2 non-throttle errors keep existing max retry delay");
    }

    private void test_missing_own_devicelist_resource_constraint_defers_bundle_probe() {
        try {
            Context context = new Context();
            Store store = setup_test_store_context(context);
            var stream = create_pubsub_test_stream(new Jid("alice@example.test/dinox"));
            var module = new StreamModule(store);
            stream.add_module(module);

            int device_publish_requests = 0;
            int bundle_pubsub_requests = 0;
            var loop = new MainLoop();
            stream.wrote_node.connect((outgoing) => {
                string? publish_node = get_pubsub_child_node(outgoing, "publish");
                if (publish_node == NS_OMEMO + ".devicelist") {
                    fail_if(outgoing.get_attribute("to") != null,
                        "own legacy OMEMO device-list publish must target the account PEP service without an explicit to JID");
                    device_publish_requests++;
                    Iq.Stanza request = new Iq.Stanza.from_stanza(outgoing, stream.get_flag(Bind.Flag.IDENTITY).my_jid);
                    var error_iq = new Iq.Stanza.error(request, new ErrorStanza.resource_constraint("server throttled legacy OMEMO publish"));
                    error_iq.from = stream.remote_name;
                    error_iq.to = stream.get_flag(Bind.Flag.IDENTITY).my_jid;
                    stream.emit_iq_result(error_iq.stanza);
                    return;
                }
                string? items_node = get_pubsub_child_node(outgoing, "items");
                if ((publish_node != null && ((!) publish_node).has_prefix(NS_OMEMO + ".bundles:")) ||
                        (items_node != null && ((!) items_node).has_prefix(NS_OMEMO + ".bundles:"))) {
                    bundle_pubsub_requests++;
                    respond_empty_pubsub_items(stream, outgoing, items_node ?? (!) publish_node);
                }
            });

            GLib.Test.expect_message("OMEMO", GLib.LogLevelFlags.LEVEL_WARNING,
                "*OMEMO: server deferred own device-list PubSub publish for node eu.siacs.conversations.axolotl.devicelist with wait/resource-constraint; retrying in 600 seconds");
            module.parse_device_list(stream, stream.get_flag(Bind.Flag.IDENTITY).my_jid.bare_jid, "current",
                new StanzaNode.build("list", NS_OMEMO).add_self_xmlns());
            module.publish_bundles_if_needed(stream, stream.get_flag(Bind.Flag.IDENTITY).my_jid.bare_jid);
            Timeout.add(100, () => {
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            GLib.Test.assert_expected_messages();

            fail_if_not_eq_int(device_publish_requests, 1,
                "missing own legacy OMEMO device id must attempt the device-list publish");
            fail_if_not_eq_int(bundle_pubsub_requests, 0,
                "legacy OMEMO bundle PubSub must wait until own device-list publish succeeds");
            module.detach(stream);
        } catch (Error e) {
            fail_if_reached("legacy OMEMO fake PubSub deferral test failed: %s".printf(e.message));
        }
    }

    private void test_v2_missing_own_devicelist_resource_constraint_defers_bundle_probe() {
        try {
            Context context = new Context();
            Store store = setup_test_store_context(context);
            var stream = create_pubsub_test_stream(new Jid("alice@example.test/dinox"));
            var module2 = new StreamModule2(store);
            stream.add_module(module2);

            int device_publish_requests = 0;
            int bundle_pubsub_requests = 0;
            var loop = new MainLoop();
            stream.wrote_node.connect((outgoing) => {
                string? publish_node = get_pubsub_child_node(outgoing, "publish");
                if (publish_node == Xmpp.Xep.Omemo.NODE_DEVICELIST_V2) {
                    fail_if(outgoing.get_attribute("to") != null,
                        "own OMEMO 2 device-list publish must target the account PEP service without an explicit to JID");
                    device_publish_requests++;
                    Iq.Stanza request = new Iq.Stanza.from_stanza(outgoing, stream.get_flag(Bind.Flag.IDENTITY).my_jid);
                    var error_iq = new Iq.Stanza.error(request, new ErrorStanza.resource_constraint("server throttled OMEMO 2 publish"));
                    error_iq.from = stream.remote_name;
                    error_iq.to = stream.get_flag(Bind.Flag.IDENTITY).my_jid;
                    stream.emit_iq_result(error_iq.stanza);
                    return;
                }
                string? items_node = get_pubsub_child_node(outgoing, "items");
                if (publish_node == Xmpp.Xep.Omemo.NODE_BUNDLES_V2 || items_node == Xmpp.Xep.Omemo.NODE_BUNDLES_V2) {
                    bundle_pubsub_requests++;
                    respond_empty_pubsub_items(stream, outgoing, items_node ?? (!) publish_node);
                }
            });

            GLib.Test.expect_message("OMEMO", GLib.LogLevelFlags.LEVEL_WARNING,
                "*OMEMO 2: server deferred own device-list PubSub publish for node urn:xmpp:omemo:2:devices with wait/resource-constraint; retrying in 600 seconds");
            module2.parse_device_list(stream, stream.get_flag(Bind.Flag.IDENTITY).my_jid.bare_jid, "current",
                new StanzaNode.build("devices", Xmpp.Xep.Omemo.NS_URI_V2).add_self_xmlns());
            module2.publish_bundles_if_needed(stream, stream.get_flag(Bind.Flag.IDENTITY).my_jid.bare_jid);
            Timeout.add(100, () => {
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            GLib.Test.assert_expected_messages();

            fail_if_not_eq_int(device_publish_requests, 1,
                "missing own OMEMO 2 device id must attempt the device-list publish");
            fail_if_not_eq_int(bundle_pubsub_requests, 0,
                "OMEMO 2 bundle PubSub must wait until own device-list publish succeeds");
            module2.detach(stream);
        } catch (Error e) {
            fail_if_reached("OMEMO 2 fake PubSub deferral test failed: %s".printf(e.message));
        }
    }

    private void test_devicelist_retries_without_unknown_max_items_publish_option() {
        try {
            Context context = new Context();
            Store store = setup_test_store_context(context);
            var own_jid = new Jid("alice@example.test/dinox");
            var stream = create_pubsub_test_stream(own_jid);
            var module = new StreamModule(store);
            stream.add_module(module);

            int publish_requests = 0;
            var loop = new MainLoop();
            stream.wrote_node.connect((outgoing) => {
                string? publish_node = get_pubsub_child_node(outgoing, "publish");
                if (publish_node != NS_OMEMO + ".devicelist") return;
                fail_if(outgoing.get_attribute("to") != null,
                    "own legacy OMEMO device-list max_items fallback path must not set an explicit to JID");
                publish_requests++;
                if (publish_requests == 1) {
                    fail_if(!stanza_contains(outgoing, "pubsub#max_items"),
                        "first legacy OMEMO device-list publish should request max_items when supported");
                    Iq.Stanza request = new Iq.Stanza.from_stanza(outgoing, own_jid);
                    var error_iq = new Iq.Stanza.error(request,
                        new ErrorStanza.resource_constraint("Unknown field 'pubsub#max_items' of type 'http://jabber.org/protocol/pubsub#publish-options'"));
                    error_iq.from = stream.remote_name;
                    error_iq.to = own_jid;
                    stream.emit_iq_result(error_iq.stanza);
                    return;
                }
                fail_if(stanza_contains(outgoing, "pubsub#max_items"),
                    "legacy OMEMO device-list fallback publish must omit unsupported max_items publish-option");
                respond_empty_iq_result(stream, outgoing);
                Timeout.add(50, () => {
                    loop.quit();
                    return Source.REMOVE;
                });
            });

            var devices = new Gee.ArrayList<int32>();
            devices.add((int32) store.local_registration_id);
            module.publish_own_devicelist(stream, own_jid.bare_jid, devices);
            loop.run();

            fail_if_not_eq_int(publish_requests, 2,
                "legacy OMEMO device-list publish must retry once without unsupported max_items");
            module.detach(stream);
        } catch (Error e) {
            fail_if_reached("legacy OMEMO max_items fallback test failed: %s".printf(e.message));
        }
    }

    private void test_v2_devicelist_publish_resource_constraint_sets_retry_state() {
        try {
            Context context = new Context();
            Store store = setup_test_store_context(context);
            var own_jid = new Jid("alice@example.test/dinox");
            var stream = create_pubsub_test_stream(own_jid);
            var module2 = new StreamModule2(store);
            stream.add_module(module2);

            int publish_requests = 0;
            var loop = new MainLoop();
            uint timeout_id = 0;
            timeout_id = Timeout.add_seconds(2, () => {
                timeout_id = 0;
                fail_if_reached("timed out waiting for OMEMO 2 PubSub publish retry state");
                loop.quit();
                return Source.REMOVE;
            });
            stream.wrote_node.connect((outgoing) => {
                if (!is_omemo2_devicelist_publish_iq(outgoing)) return;
                fail_if(outgoing.get_attribute("to") != null,
                    "own OMEMO 2 device-list publish retry path must not set an explicit to JID");
                publish_requests++;
                Iq.Stanza request = new Iq.Stanza.from_stanza(outgoing, own_jid);
                var error_iq = new Iq.Stanza.error(request, new ErrorStanza.resource_constraint("server throttled OMEMO 2 publish"));
                error_iq.from = stream.remote_name;
                error_iq.to = own_jid;
                stream.emit_iq_result(error_iq.stanza);
                Timeout.add(50, () => {
                    loop.quit();
                    return Source.REMOVE;
                });
            });

            var devices = new Gee.ArrayList<int32>();
            devices.add((int32) store.local_registration_id);
            GLib.Test.expect_message("OMEMO", GLib.LogLevelFlags.LEVEL_WARNING,
                "*OMEMO 2: server deferred own device-list PubSub publish for node urn:xmpp:omemo:2:devices with wait/resource-constraint; retrying in 600 seconds");
            module2.publish_own_devicelist(stream, own_jid.bare_jid, devices);
            loop.run();
            if (timeout_id != 0) Source.remove(timeout_id);
            GLib.Test.assert_expected_messages();

            fail_if_not_eq_int(publish_requests, 1, "OMEMO 2 device-list publish must be attempted exactly once before retry timer");
            module2.publish_own_devicelist(stream, own_jid.bare_jid, devices);
            fail_if_not_eq_int(publish_requests, 1,
                "OMEMO 2 wait/resource-constraint retry state must suppress immediate repeated publish attempts");
            module2.detach(stream);
        } catch (Error e) {
            fail_if_reached("OMEMO 2 fake PubSub retry test failed: %s".printf(e.message));
        }
    }

    private void test_v2_devicelist_retries_without_unknown_max_items_publish_option() {
        try {
            Context context = new Context();
            Store store = setup_test_store_context(context);
            var own_jid = new Jid("alice@example.test/dinox");
            var stream = create_pubsub_test_stream(own_jid);
            var module2 = new StreamModule2(store);
            stream.add_module(module2);

            int publish_requests = 0;
            var loop = new MainLoop();
            stream.wrote_node.connect((outgoing) => {
                if (!is_omemo2_devicelist_publish_iq(outgoing)) return;
                fail_if(outgoing.get_attribute("to") != null,
                    "own OMEMO 2 device-list max_items fallback path must not set an explicit to JID");
                publish_requests++;
                if (publish_requests == 1) {
                    fail_if(!stanza_contains(outgoing, "pubsub#max_items"),
                        "first OMEMO 2 device-list publish should request max_items when supported");
                    Iq.Stanza request = new Iq.Stanza.from_stanza(outgoing, own_jid);
                    var error_iq = new Iq.Stanza.error(request,
                        new ErrorStanza.resource_constraint("Unknown field 'pubsub#max_items' of type 'http://jabber.org/protocol/pubsub#publish-options'"));
                    error_iq.from = stream.remote_name;
                    error_iq.to = own_jid;
                    stream.emit_iq_result(error_iq.stanza);
                    return;
                }
                fail_if(stanza_contains(outgoing, "pubsub#max_items"),
                    "OMEMO 2 device-list fallback publish must omit unsupported max_items publish-option");
                respond_empty_iq_result(stream, outgoing);
                Timeout.add(50, () => {
                    loop.quit();
                    return Source.REMOVE;
                });
            });

            var devices = new Gee.ArrayList<int32>();
            devices.add((int32) store.local_registration_id);
            module2.publish_own_devicelist(stream, own_jid.bare_jid, devices);
            loop.run();

            fail_if_not_eq_int(publish_requests, 2,
                "OMEMO 2 device-list publish must retry once without unsupported max_items");
            module2.detach(stream);
        } catch (Error e) {
            fail_if_reached("OMEMO 2 max_items fallback test failed: %s".printf(e.message));
        }
    }

    private static bool is_omemo2_devicelist_publish_iq(StanzaNode iq) {
        return iq.name == "iq" && iq.get_attribute("type") == Iq.Stanza.TYPE_SET &&
            get_pubsub_child_node(iq, "publish") == Xmpp.Xep.Omemo.NODE_DEVICELIST_V2;
    }

    private void test_devicelist_cancelled() {
        var loop = new MainLoop();
        test_devicelist_cancelled_async.begin((_, res) => {
            test_devicelist_cancelled_async.end(res);
            loop.quit();
        });
        loop.run();
    }

    private async void test_devicelist_cancelled_async() {
        try {
            foreach (string target_address in new string[] { "alice@example.test", "bob@example.test" }) {
                var own = new Jid("alice@example.test/dinox");
                var target = new Jid(target_address);
                var first = create_pubsub_test_stream(own);
                var module = new StreamModule(setup_test_store_context(Plugin.get_context()));
                first.add_module(module);
                int loaded = 0;
                int failed = 0;
                int writes = 0;
                StanzaNode? old_request = null;
                module.device_list_loaded.connect((jid, devices) => { loaded++; });
                module.device_list_fetch_failed.connect((jid, error) => { failed++; });
                first.wrote_node.connect((outgoing) => {
                    writes++;
                    if (get_pubsub_child_node(outgoing, "items") != NS_OMEMO + ".devicelist") return;
                    old_request = outgoing;
                    Idle.add(() => {
                        // Leave OMEMO attached while the IQ cancellation resumes.
                        // A generation check alone cannot protect this window.
                        first.get_module<Iq.Module>(Iq.Module.IDENTITY).detach(first);
                        return Source.REMOVE;
                    });
                });
                var cancelled = yield module.request_user_devicelist(first, target);
                fail_if(cancelled.size != 0 || failed != 0 || loaded != 0,
                    "Local detach must finish without failed/loaded device-list signals");
                fail_if(writes != 1, "Cancellation must not bootstrap or publish an empty own list");
                module.detach(first);

                var second = create_pubsub_test_stream(own);
                module.auto_publish_own_device_list = false;
                second.add_module(module);
                int replacement_requests = 0;
                second.wrote_node.connect((outgoing) => {
                    if (get_pubsub_child_node(outgoing, "items") != NS_OMEMO + ".devicelist") return;
                    replacement_requests++;
                    Idle.add(() => {
                        var request = new Iq.Stanza.from_stanza(outgoing, own);
                        var payload = new StanzaNode.build("pubsub", NS_PUBSUB).put_node(
                            new StanzaNode.build("items", NS_PUBSUB)
                                .put_attribute("node", NS_OMEMO + ".devicelist").put_node(
                            new StanzaNode.build("item", NS_PUBSUB).put_attribute("id", "current").put_node(
                            new StanzaNode.build("list", NS_OMEMO).put_node(
                            new StanzaNode.build("device", NS_OMEMO).put_attribute("id", "4242")))));
                        var response = new Iq.Stanza.result(request, payload);
                        response.from = target;
                        response.to = own;
                        second.emit_iq_result(response.stanza);
                        return Source.REMOVE;
                    });
                });
                var devices = yield module.request_user_devicelist(second, target);
                fail_if(replacement_requests != 1 || devices.size != 1 || !devices.contains(4242),
                    "Replacement must fetch a fresh list, not reuse the cancelled request");
                fail_if(loaded != 1 || failed != 0, "Only the replacement may report loaded devices");
                if (old_request != null) {
                    respond_empty_pubsub_items(first, (!) old_request, NS_OMEMO + ".devicelist");
                }
                fail_if(loaded != 1 || failed != 0, "Late old response must not change replacement state");
                module.detach(second);
                second.get_module<Iq.Module>(Iq.Module.IDENTITY).detach(second);
            }
        } catch (Error e) {
            fail_if_reached(e.message);
        }
    }

    private void test_devicelist_remote_error() {
        var loop = new MainLoop();
        test_devicelist_remote_error_async.begin((_, res) => {
            test_devicelist_remote_error_async.end(res);
            loop.quit();
        });
        loop.run();
    }

    private async void test_devicelist_remote_error_async() {
        try {
            var own = new Jid("alice@example.test/dinox");
            var target = new Jid("bob@example.test");
            var stream = create_pubsub_test_stream(own);
            var module = new StreamModule(setup_test_store_context(Plugin.get_context()));
            module.auto_publish_own_device_list = false;
            stream.add_module(module);
            int failed = 0;
            int loaded = 0;
            module.device_list_loaded.connect((jid, devices) => { loaded++; });
            module.device_list_fetch_failed.connect((jid, error) => {
                failed++;
                fail_if(error.locally_cancelled, "Remote cancel error must remain a real failure");
                fail_if_not_eq_str(error.error_condition, ErrorStanza.CONDITION_SERVICE_UNAVAILABLE);
            });
            stream.wrote_node.connect((outgoing) => {
                if (get_pubsub_child_node(outgoing, "items") != NS_OMEMO + ".devicelist") return;
                Idle.add(() => {
                    var request = new Iq.Stanza.from_stanza(outgoing, own);
                    var response = new Iq.Stanza.error(request, new ErrorStanza.service_unavailable());
                    response.from = target;
                    response.to = own;
                    stream.emit_iq_result(response.stanza);
                    return Source.REMOVE;
                });
            });
            GLib.Test.expect_message("xmpp-vala", LogLevelFlags.LEVEL_WARNING,
                "*Failed to request pubsub items*service-unavailable*");
            GLib.Test.expect_message("OMEMO", LogLevelFlags.LEVEL_WARNING,
                "*device-list request failed*service-unavailable*");
            yield module.request_user_devicelist(stream, target);
            GLib.Test.assert_expected_messages();
            fail_if(failed != 1 || loaded != 0, "Real error must still wake waiters with failure");
            module.detach(stream);
            stream.get_module<Iq.Module>(Iq.Module.IDENTITY).detach(stream);
        } catch (Error e) {
            fail_if_reached(e.message);
        }
    }

    private static PubSubTestXmppStream create_pubsub_test_stream(Jid own_jid) throws Error {
        var stream = new PubSubTestXmppStream(new Jid("example.test"));
        var bind_flag = new Bind.Flag();
        bind_flag.my_jid = own_jid;
        stream.add_flag(bind_flag);
        stream.negotiation_complete = true;
        stream.add_module(new Iq.Module());
        stream.add_module(new Xmpp.Xep.ServiceDiscovery.Module.with_identity(
            Xmpp.Xep.ServiceDiscovery.Identity.CATEGORY_CLIENT,
            Xmpp.Xep.ServiceDiscovery.Identity.TYPE_PC,
            "DinoX Test"));
        stream.add_module(new MessageModule());
        stream.add_module(new Xmpp.Xep.Pubsub.Module());
        return stream;
    }

    private static string? get_pubsub_child_node(StanzaNode iq, string child_name) {
        if (iq.name != "iq") return null;
        StanzaNode? pubsub = iq.get_subnode("pubsub", Xmpp.Xep.Pubsub.NS_URI);
        if (pubsub == null) return null;
        StanzaNode? child = ((!) pubsub).get_subnode(child_name, Xmpp.Xep.Pubsub.NS_URI);
        if (child == null) return null;
        return ((!) child).get_attribute("node");
    }

    private static bool stanza_contains(StanzaNode node, string needle) {
        return node.to_string().contains(needle);
    }

    private static bool is_pubsub_owner_config_get_iq(StanzaNode iq) {
        if (iq.name != "iq" || iq.get_attribute("type") != Iq.Stanza.TYPE_GET) return false;
        StanzaNode? pubsub = iq.get_subnode("pubsub", NS_PUBSUB_OWNER);
        if (pubsub == null) return false;
        return ((!) pubsub).get_subnode("configure", NS_PUBSUB_OWNER) != null;
    }

    private static void respond_empty_iq_result(PubSubTestXmppStream stream, StanzaNode outgoing) {
        Iq.Stanza request = new Iq.Stanza.from_stanza(outgoing, stream.get_flag(Bind.Flag.IDENTITY).my_jid);
        Iq.Stanza result = new Iq.Stanza.result(request);
        result.from = stream.remote_name;
        result.to = stream.get_flag(Bind.Flag.IDENTITY).my_jid;
        stream.emit_iq_result(result.stanza);
    }

    private static void respond_empty_pubsub_items(PubSubTestXmppStream stream, StanzaNode outgoing, string node_id) {
        Iq.Stanza request = new Iq.Stanza.from_stanza(outgoing, stream.get_flag(Bind.Flag.IDENTITY).my_jid);
        StanzaNode pubsub = new StanzaNode.build("pubsub", Xmpp.Xep.Pubsub.NS_URI)
            .add_self_xmlns()
            .put_node(new StanzaNode.build("items", Xmpp.Xep.Pubsub.NS_URI)
                .put_attribute("node", node_id));
        Iq.Stanza result = new Iq.Stanza.result(request, pubsub);
        result.from = stream.remote_name;
        result.to = stream.get_flag(Bind.Flag.IDENTITY).my_jid;
        stream.emit_iq_result(result.stanza);
    }

    private static void respond_empty_pubsub_owner_config(PubSubTestXmppStream stream, StanzaNode outgoing) {
        Iq.Stanza request = new Iq.Stanza.from_stanza(outgoing, stream.get_flag(Bind.Flag.IDENTITY).my_jid);
        StanzaNode? request_pubsub = outgoing.get_subnode("pubsub", NS_PUBSUB_OWNER);
        StanzaNode? request_configure = request_pubsub != null ? ((!) request_pubsub).get_subnode("configure", NS_PUBSUB_OWNER) : null;
        string? node_id = request_configure != null ? ((!) request_configure).get_attribute("node") : null;

        StanzaNode configure = new StanzaNode.build("configure", NS_PUBSUB_OWNER);
        if (node_id != null) configure.put_attribute("node", (!) node_id);
        configure.put_node(new StanzaNode.build("x", NS_DATA_FORMS).add_self_xmlns().put_attribute("type", "form"));

        StanzaNode pubsub = new StanzaNode.build("pubsub", NS_PUBSUB_OWNER)
            .add_self_xmlns()
            .put_node(configure);
        Iq.Stanza result = new Iq.Stanza.result(request, pubsub);
        result.from = stream.remote_name;
        result.to = stream.get_flag(Bind.Flag.IDENTITY).my_jid;
        stream.emit_iq_result(result.stanza);
    }

    private class PubSubTestXmppStream : Xmpp.XmppStream {
        public signal void wrote_node(StanzaNode node);

        public PubSubTestXmppStream(Jid remote_name) {
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
            wrote_node(node);
            if (is_pubsub_owner_config_get_iq(node)) {
                respond_empty_pubsub_owner_config(this, node);
            }
        }

        public override async void setup() throws IOError {
        }

        public void emit_iq_result(StanzaNode node) {
            received_iq_stanza(this, node);
        }
    }
}

}

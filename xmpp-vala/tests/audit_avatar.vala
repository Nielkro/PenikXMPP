namespace Xmpp.Test {

class AvatarProtocolAudit : Gee.TestCase {
    private const string HASH = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    private const string CONTACT = "contact@example.test/resource";
    private const string NS_VCARD_UPDATE = "vcard-temp:x:update";
    private const string NS_PUBSUB = "http://jabber.org/protocol/pubsub";
    private const string NS_AVATAR_DATA = "urn:xmpp:avatar:data";
    private const string NS_AVATAR_METADATA = "urn:xmpp:avatar:metadata";

    public AvatarProtocolAudit() {
        base("AvatarProtocolAudit");
        add_test("XEP0153_nonempty_photo_announces_hash", test_nonempty_photo_announces_hash);
        add_test("XEP0153_empty_photo_removes_vcard_avatar", test_empty_photo_removes_avatar);
        add_test("XEP0153_outgoing_presence_announces_hash_to_contacts_and_MUC",
            test_outgoing_presence_announces_hash);
        add_test("XEP0153_unknown_and_known_empty_outgoing_state",
            test_outgoing_presence_unknown_and_empty_state);
        add_test("XEP0153_fresh_attach_resets_but_resume_retains_state",
            test_fresh_attach_and_resume_state);
        add_test("XEP0153_other_own_resources_reset_server_state",
            test_other_own_resources_reset_server_state);
        add_test("XEP0084_empty_metadata_removes_avatar",
            test_empty_metadata_removes_avatar);
        add_test("XEP0084_invalid_metadata_hash_is_ignored",
            test_invalid_metadata_hash_is_ignored);
        add_async_test("XEP0084_publish_data_before_metadata",
            test_publish_data_before_metadata);
        add_async_test("XEP0084_data_failure_suppresses_metadata",
            test_data_failure_suppresses_metadata);
        add_async_test("XEP0084_transport_timeout_preserves_ambiguity",
            test_transport_timeout_preserves_ambiguity);
        add_async_test("XEP0084_current_metadata_can_be_reverified",
            test_current_metadata_can_be_reverified);
        add_async_test("XEP0084_metadata_cancelled_during_reconnect",
            (cb) => { test_avatar_cancellation.begin(0, cb); });
        add_async_test("XEP0084_data_publish_cancelled_during_reconnect",
            (cb) => { test_avatar_cancellation.begin(1, cb); });
        add_async_test("XEP0084_metadata_publish_cancelled_during_reconnect",
            (cb) => { test_avatar_cancellation.begin(2, cb); });
        add_async_test("XEP0084_removal_cancelled_during_reconnect",
            (cb) => { test_avatar_cancellation.begin(3, cb); });
        add_async_test("XEP0084_unset_publishes_empty_metadata",
            test_unset_publishes_empty_metadata);
        add_async_test("XEP0054_publish_surfaces_server_error",
            test_vcard_publish_surfaces_server_error);
        add_async_test("XEP0054_checked_fetch_rejects_missing_vcard",
            (cb) => { test_vcard_fetch_missing_element.begin(cb); });
        add_async_test("XEP0054_checked_fetch_accepts_explicit_empty_vcard",
            (cb) => { test_vcard_fetch_explicit_empty.begin(cb); });
        add_async_test("XEP0054_checked_fetch_preserves_item_not_found",
            (cb) => { test_vcard_fetch_item_not_found.begin(cb); });
    }

    private void test_nonempty_photo_announces_hash() {
        try {
            Presence.Module presence;
            Xep.VCard.Module vcard;
            AvatarAuditStream stream = create_stream(out presence, out vcard);
            int hashes = 0;
            int removals = 0;
            string? received_hash = null;
            vcard.received_avatar_hash.connect((xmpp_stream, jid, hash) => {
                hashes++;
                received_hash = hash;
            });
            vcard.avatar_removed.connect((xmpp_stream, jid) => removals++);

            presence.received_presence(stream, build_presence(HASH));

            fail_if(hashes != 1, "XEP-0153 non-empty photo must emit one hash announcement");
            fail_if_not_eq_str(received_hash, HASH, "XEP-0153 hash must be preserved");
            fail_if(removals != 0, "Non-empty photo must not emit avatar removal");
        } catch (Error e) {
            fail_if_reached(@"Unexpected non-empty XEP-0153 test error: $(e.message)");
        }
    }

    private void test_empty_photo_removes_avatar() {
        try {
            Presence.Module presence;
            Xep.VCard.Module vcard;
            AvatarAuditStream stream = create_stream(out presence, out vcard);
            int hashes = 0;
            int removals = 0;
            Jid? removed_jid = null;
            vcard.received_avatar_hash.connect((xmpp_stream, jid, hash) => hashes++);
            vcard.avatar_removed.connect((xmpp_stream, jid) => {
                removals++;
                removed_jid = jid;
            });

            presence.received_presence(stream, build_presence(null));

            fail_if(hashes != 0, "Empty XEP-0153 photo must not emit a hash");
            fail_if(removals != 1, "Empty XEP-0153 photo must emit one removal");
            fail_if(removed_jid == null || !((!) removed_jid).equals(new Jid(CONTACT)),
                "XEP-0153 removal must retain the announcing full JID");
        } catch (Error e) {
            fail_if_reached(@"Unexpected empty XEP-0153 test error: $(e.message)");
        }
    }

    private void test_outgoing_presence_announces_hash() {
        try {
            Presence.Module presence;
            Xep.VCard.Module vcard;
            AvatarAuditStream stream = create_stream(out presence, out vcard);
            fail_if(!vcard.set_own_avatar_hash(HASH),
                "The first verified own-avatar state must be a transition");

            var broadcast = new Presence.Stanza();
            presence.pre_send_presence_stanza(stream, broadcast);
            assert_outgoing_photo_hash(broadcast, HASH,
                "Broadcast presence must advertise the vCard avatar hash");

            var muc_presence = new Presence.Stanza();
            muc_presence.to = new Jid("room@conference.example.test/nick");
            presence.pre_send_presence_stanza(stream, muc_presence);
            assert_outgoing_photo_hash(muc_presence, HASH,
                "Directed MUC presence must advertise the participant avatar hash");
        } catch (Error e) {
            fail_if_reached(@"Unexpected outgoing XEP-0153 test error: $(e.message)");
        }
    }

    private void test_outgoing_presence_unknown_and_empty_state() {
        try {
            Presence.Module presence;
            Xep.VCard.Module vcard;
            AvatarAuditStream stream = create_stream(out presence, out vcard);

            var unknown = new Presence.Stanza();
            presence.pre_send_presence_stanza(stream, unknown);
            StanzaNode? unknown_update = unknown.stanza.get_subnode("x",
                NS_VCARD_UPDATE);
            fail_if(unknown_update == null ||
                    ((!) unknown_update).get_subnode("photo",
                        NS_VCARD_UPDATE) != null,
                "An unverified server state must advertise support without a photo claim");

            fail_if(!vcard.set_own_avatar_hash(null),
                "A verified empty vCard must transition from unknown state");
            var empty = new Presence.Stanza();
            presence.pre_send_presence_stanza(stream, empty);
            StanzaNode? update = empty.stanza.get_subnode("x",
                NS_VCARD_UPDATE);
            StanzaNode? photo = update != null
                ? ((!) update).get_subnode("photo", NS_VCARD_UPDATE) : null;
            fail_if(photo == null || ((!) photo).get_string_content() != null,
                "A verified no-avatar state must advertise an empty photo element");
        } catch (Error e) {
            fail_if_reached(@"Unexpected empty outgoing XEP-0153 test error: $(e.message)");
        }
    }

    private void test_fresh_attach_and_resume_state() {
        try {
            Presence.Module first_presence;
            Xep.VCard.Module vcard;
            AvatarAuditStream first_stream = create_stream(out first_presence,
                out vcard);
            vcard.set_own_avatar_hash(HASH);
            vcard.detach(first_stream);
            first_presence.detach(first_stream);

            var fresh_stream = new AvatarAuditStream(
                new Jid("example.test"));
            var fresh_presence = new Presence.Module();
            fresh_stream.add_module(fresh_presence);
            fresh_presence.attach(fresh_stream);
            fresh_stream.add_module(vcard);
            vcard.attach(fresh_stream);
            var fresh_outgoing = new Presence.Stanza();
            fresh_presence.pre_send_presence_stanza(fresh_stream,
                fresh_outgoing);
            StanzaNode? fresh_update = fresh_outgoing.stanza.get_subnode("x",
                NS_VCARD_UPDATE);
            fail_if(fresh_update == null ||
                    ((!) fresh_update).get_subnode("photo",
                        NS_VCARD_UPDATE) != null,
                "A fresh stream must forget the previous session hash until vCard verification");
            vcard.set_own_avatar_hash(HASH);
            vcard.detach(fresh_stream);
            fresh_presence.detach(fresh_stream);

            var resumed_stream = new AvatarAuditStream(
                new Jid("example.test"));
            var resumed_flag = new Xep.StreamManagement.Flag();
            resumed_flag.resumed = true;
            resumed_stream.add_flag(resumed_flag);
            var resumed_presence = new Presence.Module();
            resumed_stream.add_module(resumed_presence);
            resumed_presence.attach(resumed_stream);
            resumed_stream.add_module(vcard);
            vcard.attach(resumed_stream);
            var resumed_outgoing = new Presence.Stanza();
            resumed_presence.pre_send_presence_stanza(resumed_stream,
                resumed_outgoing);
            assert_outgoing_photo_hash(resumed_outgoing, HASH,
                "A confirmed XEP-0198 resume must retain the verified session hash");

            fail_if(!vcard.invalidate_own_avatar_state(),
                "An ambiguous own-avatar operation must invalidate the verified hash");
            var invalidated_outgoing = new Presence.Stanza();
            resumed_presence.pre_send_presence_stanza(resumed_stream,
                invalidated_outgoing);
            StanzaNode? invalidated_update = invalidated_outgoing.stanza
                .get_subnode("x", NS_VCARD_UPDATE);
            fail_if(invalidated_update == null ||
                    ((!) invalidated_update).get_subnode("photo",
                        NS_VCARD_UPDATE) != null,
                "An invalidated resumed session must not announce the old hash");
            vcard.detach(resumed_stream);
            resumed_presence.detach(resumed_stream);
        } catch (Error e) {
            fail_if_reached(@"Unexpected XEP-0153 attach lifecycle error: $(e.message)");
        }
    }

    private void test_empty_metadata_removes_avatar() {
        try {
            var stream = new AvatarAuditStream(new Jid("example.test"));
            var avatars = new Xep.UserAvatars.Module();
            int removals = 0;
            avatars.avatar_removed.connect((xmpp_stream, jid) => removals++);
            avatars.on_pupsub_item(stream, new Jid("contact@example.test"),
                "", new StanzaNode.build("metadata", NS_AVATAR_METADATA)
                    .add_self_xmlns());
            fail_if(removals != 1,
                "Empty XEP-0084 metadata must remove the advertised avatar");
        } catch (Error e) {
            fail_if_reached(@"Unexpected empty XEP-0084 metadata error: $(e.message)");
        }
    }

    private void test_other_own_resources_reset_server_state() {
        try {
            Presence.Module presence;
            Xep.VCard.Module vcard;
            AvatarAuditStream stream = create_stream(out presence, out vcard);
            var bind = new Bind.Flag();
            bind.my_jid = new Jid("self@example.test/this");
            bind.finished = true;
            stream.add_flag(bind);
            Jid other = new Jid("self@example.test/other");
            int suspensions = 0;
            int refetches = 0;
            vcard.own_avatar_state_reset_requested.connect((xmpp_stream,
                    refetch) => {
                if (refetch) {
                    refetches++;
                } else {
                    suspensions++;
                }
                vcard.invalidate_own_avatar_state();
            });

            vcard.set_own_avatar_hash(HASH);
            var missing_update = new Presence.Stanza();
            missing_update.from = other;
            presence.received_presence(stream, missing_update);
            fail_if(suspensions != 1 || refetches != 0,
                "A nonconforming own resource must suspend hash advertisement without polling");
            var unknown = new Presence.Stanza();
            presence.pre_send_presence_stanza(stream, unknown);
            StanzaNode? unknown_update = unknown.stanza.get_subnode("x",
                NS_VCARD_UPDATE);
            fail_if(unknown_update == null ||
                    ((!) unknown_update).get_subnode("photo",
                        NS_VCARD_UPDATE) != null,
                "Suspended multi-resource state must advertise an empty update element");

            var ready_without_hash = new Presence.Stanza();
            ready_without_hash.from = other;
            ready_without_hash.stanza.put_node(new StanzaNode.build("x",
                NS_VCARD_UPDATE).add_self_xmlns());
            presence.received_presence(stream, ready_without_hash);
            fail_if(refetches != 1,
                "The last formerly nonconforming resource becoming ready must reverify vCard");

            vcard.set_own_avatar_hash(HASH);
            presence.received_presence(stream, build_presence_from(other,
                HASH));
            fail_if(refetches != 1,
                "An identical own-resource hash must not trigger a redundant readback");

            presence.received_presence(stream, build_presence_from(other,
                "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"));
            fail_if(refetches != 2,
                "A different own-resource hash must trigger server vCard readback");

            vcard.set_own_avatar_hash(HASH);
            presence.received_presence(stream, build_presence_from(other,
                null));
            fail_if(refetches != 3,
                "An empty own-resource photo must trigger server vCard readback");

            vcard.set_own_avatar_hash(HASH);
            presence.received_presence(stream, missing_update);
            var unavailable = new Presence.Stanza();
            unavailable.from = other;
            unavailable.type_ = Presence.Stanza.TYPE_UNAVAILABLE;
            presence.received_unavailable(stream, unavailable);
            fail_if(suspensions != 2 || refetches != 4,
                "Going offline must release the last nonconforming resource and reverify vCard");
        } catch (Error e) {
            fail_if_reached(@"Unexpected XEP-0153 multi-resource error: $(e.message)");
        }
    }

    private void test_invalid_metadata_hash_is_ignored() {
        try {
            var stream = new AvatarAuditStream(new Jid("example.test"));
            var avatars = new Xep.UserAvatars.Module();
            int hashes = 0;
            int removals = 0;
            avatars.received_avatar_hash.connect((xmpp_stream, jid, hash) =>
                hashes++);
            avatars.avatar_removed.connect((xmpp_stream, jid) => removals++);
            var metadata = new StanzaNode.build("metadata",
                NS_AVATAR_METADATA).add_self_xmlns();
            metadata.put_node(new StanzaNode.build("info",
                NS_AVATAR_METADATA)
                .put_attribute("id", "not-a-sha1")
                .put_attribute("type", "image/png"));

            avatars.on_pupsub_item(stream,
                new Jid("contact@example.test"), "not-a-sha1", metadata);
            fail_if(hashes != 0 || removals != 0,
                "Malformed PEP metadata must not verify or remove avatar state");
        } catch (Error e) {
            fail_if_reached(@"Unexpected invalid XEP-0084 hash error: $(e.message)");
        }
    }

    private void test_publish_data_before_metadata(Gee.TestFinishedCallback cb) {
        test_publish_data_before_metadata_async.begin(cb);
    }

    private async void test_publish_data_before_metadata_async(
            Gee.TestFinishedCallback cb) {
        try {
            AvatarPublishAuditStream stream = create_publish_stream();
            uint8[] image = { 1, 2, 3, 4 };
            bool published = yield Xep.UserAvatars.publish_png(stream, image,
                2, 2);
            fail_if(!published || stream.written_nodes.size != 2,
                "A successful avatar publish must confirm exactly two IQs");
            fail_if_not_eq_str(get_publish_node(stream.written_nodes[0]),
                NS_AVATAR_DATA,
                "Avatar data must be the first confirmed publish");
            fail_if_not_eq_str(get_publish_node(stream.written_nodes[1]),
                NS_AVATAR_METADATA,
                "Avatar metadata must follow the confirmed data publish");
        } catch (Error e) {
            fail_if_reached(@"Unexpected ordered XEP-0084 publish error: $(e.message)");
        }
        cb();
    }

    private void test_data_failure_suppresses_metadata(
            Gee.TestFinishedCallback cb) {
        test_data_failure_suppresses_metadata_async.begin(cb);
    }

    private async void test_data_failure_suppresses_metadata_async(
            Gee.TestFinishedCallback cb) {
        try {
            AvatarPublishAuditStream stream = create_publish_stream();
            stream.fail_response_index = 0;
            uint8[] image = { 5, 6, 7, 8 };
            bool published = yield Xep.UserAvatars.publish_png(stream, image,
                2, 2);
            fail_if(published || stream.written_nodes.size != 1,
                "Rejected avatar data must suppress the metadata announcement");
            fail_if_not_eq_str(get_publish_node(stream.written_nodes[0]),
                NS_AVATAR_DATA,
                "The only rejected IQ must be the avatar data publish");
        } catch (Error e) {
            fail_if_reached(@"Unexpected failed XEP-0084 data error: $(e.message)");
        }
        cb();
    }

    private void test_unset_publishes_empty_metadata(
            Gee.TestFinishedCallback cb) {
        test_unset_publishes_empty_metadata_async.begin(cb);
    }

    private void test_transport_timeout_preserves_ambiguity(
            Gee.TestFinishedCallback cb) {
        test_transport_timeout_preserves_ambiguity_async.begin(cb);
    }

    private async void test_transport_timeout_preserves_ambiguity_async(
            Gee.TestFinishedCallback cb) {
        try {
            uint8[] image = { 9, 10, 11, 12 };
            AvatarPublishAuditStream data_timeout = create_publish_stream();
            data_timeout.timeout_response_index = 0;
            GLib.Test.expect_message("xmpp-vala",
                GLib.LogLevelFlags.LEVEL_WARNING,
                "*synthetic PEP transport timeout*");
            Xep.UserAvatars.AvatarPublishResult data_result = yield
                Xep.UserAvatars.publish_png_with_result(data_timeout, image,
                    2, 2);
            GLib.Test.assert_expected_messages();
            fail_if(data_result.ok || data_result.ambiguous ||
                    data_timeout.written_nodes.size != 1,
                "An ambiguous data-only write must not imply an advertised avatar");

            AvatarPublishAuditStream metadata_timeout = create_publish_stream();
            metadata_timeout.timeout_response_index = 1;
            GLib.Test.expect_message("xmpp-vala",
                GLib.LogLevelFlags.LEVEL_WARNING,
                "*synthetic PEP transport timeout*");
            Xep.UserAvatars.AvatarPublishResult metadata_result = yield
                Xep.UserAvatars.publish_png_with_result(metadata_timeout,
                    image, 2, 2);
            GLib.Test.assert_expected_messages();
            fail_if(metadata_result.ok || !metadata_result.ambiguous ||
                    metadata_timeout.written_nodes.size != 2,
                "A metadata timeout must remain ambiguous after confirmed avatar data");
        } catch (Error e) {
            fail_if_reached(@"Unexpected XEP-0084 timeout audit error: $(e.message)");
        }
        cb();
    }

    private void test_current_metadata_can_be_reverified(
            Gee.TestFinishedCallback cb) {
        test_current_metadata_can_be_reverified_async.begin(cb);
    }

    private async void test_current_metadata_can_be_reverified_async(
            Gee.TestFinishedCallback cb) {
        try {
            AvatarPublishAuditStream stream = create_publish_stream();
            stream.metadata_query_hash = HASH;
            Xep.UserAvatars.AvatarMetadataResult current = yield
                Xep.UserAvatars.fetch_current_avatar(stream,
                    new Jid("self@example.test"));
            fail_if(!current.ok || current.hash != HASH,
                "A metadata state query must recover the server's current hash");

            stream.metadata_query_hash = null;
            stream.metadata_query_removed = true;
            Xep.UserAvatars.AvatarMetadataResult removed = yield
                Xep.UserAvatars.fetch_current_avatar(stream,
                    new Jid("self@example.test"));
            fail_if(!removed.ok || removed.hash != null,
                "Empty current metadata must verify the no-avatar state");
        } catch (Error e) {
            fail_if_reached(@"Unexpected XEP-0084 metadata sync error: $(e.message)");
        }
        cb();
    }

    private async void test_avatar_cancellation(int operation,
            Gee.TestFinishedCallback cb) {
        try {
            // Exercise the actual IQ/PubSub/GTask chain, including a late
            // reply after detach and cancellation after a valid server reply.
            for (int mode = 0; mode < 5; mode++) {
                var stream = create_publish_stream();
                var cancel = new Cancellable();
                stream.operation_cancellable = cancel;
                stream.metadata_query_hash = HASH;
                int index = operation == 2 ? 1 : 0;
                if (mode == 0) cancel.cancel();
                if (mode == 1 || mode == 3) stream.cancel_before_response_index = index;
                if (mode == 2) stream.cancel_after_response_index = index;
                if (mode >= 3) stream.detach_response_index = index;
                if (operation == 0) {
                    var result = yield Xep.UserAvatars.fetch_current_avatar(
                        stream, new Jid("self@example.test"), cancel);
                    fail_if(result != null && result.ok,
                        "An interrupted read must not confirm an avatar or its absence");
                } else {
                    Xep.UserAvatars.AvatarPublishResult? result;
                    if (operation == 3) {
                        result = yield Xep.UserAvatars.unset_avatar_with_result(stream, cancel);
                    } else {
                        result = yield Xep.UserAvatars.publish_png_with_result(
                            stream, { 1, 2, 3, 4 }, 2, 2, cancel);
                    }
                    fail_if(result != null && result.ok,
                        "An interrupted publication must not be reported as confirmed");
                    if (mode == 4 && operation >= 2) {
                        fail_if(result == null || !result.ambiguous,
                            "An unacknowledged metadata write must retain its ambiguous outcome");
                    }
                }
                fail_if_not_eq_int(stream.written_nodes.size, mode == 0 ? 0 : index + 1,
                    "Cancellation must stop subsequent requests on the old stream");
                // A fresh operation must still work after the cancelled one.
                var replacement = create_publish_stream();
                replacement.metadata_query_hash = HASH;
                var current = yield Xep.UserAvatars.fetch_current_avatar(
                    replacement, new Jid("self@example.test"));
                fail_if(current == null || !current.ok || current.hash != HASH,
                    "The new connection must be able to confirm its own avatar state");
            }
        } catch (Error e) {
            fail_if_reached(@"Unexpected avatar cancellation test error: $(e.message)");
        }
        cb();
    }

    private async void test_unset_publishes_empty_metadata_async(
            Gee.TestFinishedCallback cb) {
        try {
            AvatarPublishAuditStream stream = create_publish_stream();
            bool removed = yield Xep.UserAvatars.unset_avatar(stream);
            fail_if(!removed || stream.written_nodes.size != 1,
                "XEP-0084 removal must publish one confirmed metadata item");
            StanzaNode iq = stream.written_nodes[0];
            fail_if_not_eq_str(get_publish_node(iq), NS_AVATAR_METADATA,
                "XEP-0084 removal must target the metadata node");
            StanzaNode? pubsub = iq.get_subnode("pubsub", NS_PUBSUB);
            StanzaNode? publish = pubsub != null
                ? ((!) pubsub).get_subnode("publish", NS_PUBSUB) : null;
            StanzaNode? item = publish != null
                ? ((!) publish).get_subnode("item", NS_PUBSUB) : null;
            StanzaNode? metadata = item != null &&
                    ((!) item).sub_nodes.size == 1
                ? ((!) item).sub_nodes[0] : null;
            fail_if(item == null || ((!) item).get_attribute("id") != null ||
                    metadata == null || ((!) metadata).name != "metadata" ||
                    !((!) metadata).sub_nodes.is_empty,
                "XEP-0084 removal payload must be an id-less empty metadata element");
        } catch (Error e) {
            fail_if_reached(@"Unexpected XEP-0084 removal error: $(e.message)");
        }
        cb();
    }

    private void test_vcard_publish_surfaces_server_error(
            Gee.TestFinishedCallback cb) {
        test_vcard_publish_surfaces_server_error_async.begin(cb);
    }

    private async void test_vcard_publish_surfaces_server_error_async(
            Gee.TestFinishedCallback cb) {
        try {
            AvatarPublishAuditStream stream = create_publish_stream();
            stream.fail_response_index = 0;
            bool rejected = false;
            try {
                yield Xep.VCard.publish_vcard(stream,
                    new Xep.VCard.VCardInfo());
            } catch (IOError.FAILED e) {
                rejected = true;
            }
            fail_if(!rejected,
                "A vCard IQ error must be surfaced to the publishing caller");
        } catch (Error e) {
            fail_if_reached(@"Unexpected checked vCard publish error: $(e.message)");
        }
        cb();
    }

    private async void test_vcard_fetch_missing_element(
            Gee.TestFinishedCallback cb) {
        try {
            for (int mode = 0; mode < 2; mode++) {
                var stream = create_publish_stream();
                if (mode == 1) {
                    stream.vcard_query_payload = new StanzaNode.build("vCard",
                        "urn:test:wrong-vcard");
                }
                var retained = new Xep.VCard.VCardInfo();
                retained.photo = new Bytes({ 1, 2, 3 });
                bool rejected = false;
                try {
                    retained = yield Xep.VCard.fetch_vcard_checked(stream);
                } catch (IOError.INVALID_DATA e) {
                    rejected = true;
                }
                fail_if(!rejected,
                    "An IQ result without the actual vCard must not confirm absence");
                fail_if(retained == null || retained.photo == null ||
                    retained.photo.get_size() != 3,
                    "Malformed vCard results must not replace a retained avatar");
                fail_if(stream.written_nodes.size != 1,
                    "A checked fetch must make exactly one vCard GET");
            }
        } catch (Error e) {
            fail_if_reached(@"Unexpected missing vCard test error: $(e.message)");
        }
        cb();
    }

    private async void test_vcard_fetch_explicit_empty(
            Gee.TestFinishedCallback cb) {
        try {
            var stream = create_publish_stream();
            stream.vcard_query_payload = new StanzaNode.build("vCard", "vcard-temp")
                .add_self_xmlns();
            var result = yield Xep.VCard.fetch_vcard_checked(stream);
            fail_if(result == null || result.photo != null,
                "An explicit empty vCard is valid confirmed data without a photo");
        } catch (Error e) {
            fail_if_reached(@"Unexpected empty vCard test error: $(e.message)");
        }
        cb();
    }

    private async void test_vcard_fetch_item_not_found(
            Gee.TestFinishedCallback cb) {
        try {
            var stream = create_publish_stream();
            stream.vcard_query_not_found = true;
            var result = yield Xep.VCard.fetch_vcard_checked(stream);
            fail_if(result != null,
                "The explicit item-not-found error still confirms no stored vCard");
        } catch (Error e) {
            fail_if_reached(@"Unexpected missing vCard node test error: $(e.message)");
        }
        cb();
    }

    private void assert_outgoing_photo_hash(Presence.Stanza presence,
            string expected, string message) {
        StanzaNode? update = presence.stanza.get_subnode("x",
            NS_VCARD_UPDATE);
        StanzaNode? photo = update != null
            ? ((!) update).get_subnode("photo", NS_VCARD_UPDATE) : null;
        fail_if(photo == null || ((!) photo).get_string_content() != expected,
            message);
    }

    private AvatarPublishAuditStream create_publish_stream() throws Error {
        var stream = new AvatarPublishAuditStream(new Jid("example.test"));
        var iq = new Iq.Module();
        stream.add_module(iq);
        iq.attach(stream);
        stream.add_module(new Xep.Pubsub.Module());
        return stream;
    }

    private string? get_publish_node(StanzaNode iq) {
        StanzaNode? pubsub = iq.get_subnode("pubsub", NS_PUBSUB);
        StanzaNode? publish = pubsub != null
            ? ((!) pubsub).get_subnode("publish", NS_PUBSUB) : null;
        return publish != null ? ((!) publish).get_attribute("node") : null;
    }

    private AvatarAuditStream create_stream(out Presence.Module presence, out Xep.VCard.Module vcard) throws Error {
        var stream = new AvatarAuditStream(new Jid("example.test"));
        presence = new Presence.Module();
        stream.add_module(presence);
        presence.attach(stream);
        vcard = new Xep.VCard.Module();
        stream.add_module(vcard);
        vcard.attach(stream);
        return stream;
    }

    private Presence.Stanza build_presence(string? hash) throws Error {
        return build_presence_from(new Jid(CONTACT), hash);
    }

    private Presence.Stanza build_presence_from(Jid from,
            string? hash) throws Error {
        var stanza = new Presence.Stanza();
        stanza.from = from;
        var update = new StanzaNode.build("x", NS_VCARD_UPDATE).add_self_xmlns();
        var photo = new StanzaNode.build("photo", NS_VCARD_UPDATE);
        if (hash != null) photo.put_node(new StanzaNode.text((!) hash));
        update.put_node(photo);
        stanza.stanza.put_node(update);
        return stanza;
    }
}

private class AvatarAuditStream : XmppStream {
    public AvatarAuditStream(Jid remote_name) {
        base(remote_name);
    }

    public override async void connect() throws IOError {
    }

    public override async void disconnect() throws IOError {
    }

    public override async StanzaNode read() throws IOError {
        throw new IOError.NOT_CONNECTED("avatar audit stream has no reader");
    }

    public override async void write_async(StanzaNode node, int io_priority = Priority.DEFAULT, Cancellable? cancellable = null) throws IOError {
        if (cancellable != null) cancellable.set_error_if_cancelled();
    }

    public override async void setup() throws IOError {
    }
}

private class AvatarPublishAuditStream : XmppStream {
    private const string NS_PUBSUB = "http://jabber.org/protocol/pubsub";
    private const string NS_AVATAR_METADATA = "urn:xmpp:avatar:metadata";
    public Gee.ArrayList<StanzaNode> written_nodes =
        new Gee.ArrayList<StanzaNode>();
    public int fail_response_index { get; set; default = -1; }
    public int timeout_response_index { get; set; default = -1; }
    public int cancel_before_response_index { get; set; default = -1; }
    public int cancel_after_response_index { get; set; default = -1; }
    public int detach_response_index { get; set; default = -1; }
    public Cancellable? operation_cancellable { get; set; }
    public string? metadata_query_hash { get; set; default = null; }
    public bool metadata_query_removed { get; set; default = false; }
    public StanzaNode? vcard_query_payload { get; set; default = null; }
    public bool vcard_query_not_found { get; set; default = false; }

    public AvatarPublishAuditStream(Jid remote_name) {
        base(remote_name);
    }

    public override async void connect() throws IOError {
    }

    public override async void disconnect() throws IOError {
    }

    public override async StanzaNode read() throws IOError {
        throw new IOError.NOT_CONNECTED("avatar publish audit stream has no reader");
    }

    public override async void write_async(StanzaNode node,
            int io_priority = Priority.DEFAULT,
            Cancellable? cancellable = null) throws IOError {
        if (cancellable != null) cancellable.set_error_if_cancelled();
        int response_index = written_nodes.size;
        written_nodes.add(node);
        if (response_index == timeout_response_index) {
            throw new IOError.TIMED_OUT("synthetic PEP transport timeout");
        }
        Idle.add(() => {
            if (response_index == detach_response_index) {
                get_module<Iq.Module>(Iq.Module.IDENTITY).detach(this);
            }
            if (response_index == cancel_before_response_index) {
                operation_cancellable.cancel();
            }
            StanzaNode response = new StanzaNode.build("iq")
                .put_attribute("id", node.get_attribute("id"));
            bool is_vcard_query = node.get_attribute("type") == "get" &&
                node.get_subnode("vCard", "vcard-temp") != null;
            if (is_vcard_query && vcard_query_not_found) {
                response.put_attribute("type", "error")
                    .put_node(new StanzaNode.build("error")
                        .put_attribute("type", "cancel")
                        .put_node(new StanzaNode.build("item-not-found",
                            "urn:ietf:params:xml:ns:xmpp-stanzas")
                            .add_self_xmlns()));
            } else if (response_index == fail_response_index) {
                response.put_attribute("type", "error")
                    .put_node(new StanzaNode.build("error")
                        .put_attribute("type", "cancel")
                        .put_node(new StanzaNode.build("forbidden",
                            "urn:ietf:params:xml:ns:xmpp-stanzas")
                            .add_self_xmlns()));
            } else {
                response.put_attribute("type", "result");
                if (is_vcard_query && vcard_query_payload != null) {
                    response.put_node((!) vcard_query_payload);
                }
                StanzaNode? request_pubsub = node.get_subnode("pubsub",
                    NS_PUBSUB);
                StanzaNode? request_items = request_pubsub != null
                    ? ((!) request_pubsub).get_subnode("items", NS_PUBSUB)
                    : null;
                if (node.get_attribute("type") == "get" &&
                        request_items != null &&
                        ((!) request_items).get_attribute("node") ==
                            NS_AVATAR_METADATA) {
                    var pubsub = new StanzaNode.build("pubsub", NS_PUBSUB)
                        .add_self_xmlns();
                    var items = new StanzaNode.build("items", NS_PUBSUB)
                        .put_attribute("node", NS_AVATAR_METADATA);
                    if (metadata_query_hash != null ||
                            metadata_query_removed) {
                        var item = new StanzaNode.build("item", NS_PUBSUB);
                        if (metadata_query_hash != null) {
                            item.put_attribute("id", (!) metadata_query_hash);
                        }
                        var metadata = new StanzaNode.build("metadata",
                            NS_AVATAR_METADATA).add_self_xmlns();
                        if (metadata_query_hash != null) {
                            metadata.put_node(new StanzaNode.build("info",
                                NS_AVATAR_METADATA)
                                .put_attribute("id",
                                    (!) metadata_query_hash)
                                .put_attribute("type", "image/png"));
                        }
                        item.put_node(metadata);
                        items.put_node(item);
                    }
                    pubsub.put_node(items);
                    response.put_node(pubsub);
                }
            }
            received_iq_stanza(this, response);
            if (response_index == cancel_after_response_index) {
                operation_cancellable.cancel();
            }
            return Source.REMOVE;
        });
    }

    public override async void setup() throws IOError {
    }
}

}

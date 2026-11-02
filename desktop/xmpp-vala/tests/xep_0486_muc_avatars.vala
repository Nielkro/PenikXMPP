namespace Xmpp.Test {

class MucAvatarsTest : Gee.TestCase {
    private const string ROOM = "room@conference.example.test";
    private const string VALID_HASH =
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

    public MucAvatarsTest() {
        base("MucAvatarsTest");
        add_test("XEP0486_service_feature_is_explicit",
            test_service_feature);
        add_test("XEP0486_roominfo_absence_states_are_distinct",
            test_roominfo_absence_states);
        add_test("XEP0486_hashes_are_normalized_and_malformed_is_rejected",
            test_hash_validation);
        add_test("XEP0486_server_controlled_lists_are_bounded",
            test_server_controlled_limits);
        add_test("XEP0486_vcard_selection_is_hash_verified_and_prefers_png",
            test_vcard_selection);
        add_test("XEP0486_unexpected_iq_sender_is_rejected",
            test_sender_validation);
    }

    private void test_service_feature() {
        try {
            Xep.ServiceDiscovery.InfoResult unsupported = build_info(false,
                false, null);
            Xep.ServiceDiscovery.InfoResult supported = build_info(true,
                false, null);
            fail_if(Xep.MucAvatars.service_supports_room_avatars(unsupported),
                "A MUC service without vcard-temp must not enable room-avatar IQs");
            fail_if_not(Xep.MucAvatars.service_supports_room_avatars(supported),
                "The MUC service vcard-temp feature must enable XEP-0486 discovery");
        } catch (Error error) {
            fail_if_reached(@"Unexpected XEP-0486 service test error: $(error.message)");
        }
    }

    private void test_roominfo_absence_states() {
        try {
            Xep.MucAvatars.RoomAvatarInfo no_form =
                Xep.MucAvatars.parse_info_result(build_info(true, false,
                    null));
            fail_if(no_form.roominfo_form_present ||
                    no_form.hash_field_present || no_form.hashes_valid,
                "Missing roominfo is unsupported/unknown, not an avatar removal");

            Xep.MucAvatars.RoomAvatarInfo no_hash =
                Xep.MucAvatars.parse_info_result(build_info(true, true,
                    null));
            fail_if(!no_hash.roominfo_form_present ||
                    no_hash.hash_field_present || !no_hash.hashes_valid ||
                    no_hash.hash_count != 0,
                "A complete roominfo form without avatarhash must be an authoritative no-avatar state");
        } catch (Error error) {
            fail_if_reached(@"Unexpected XEP-0486 absence test error: $(error.message)");
        }
    }

    private void test_hash_validation() {
        try {
            Xep.MucAvatars.RoomAvatarInfo valid =
                Xep.MucAvatars.parse_info_result(build_info(true, true,
                    new string[] {
                        "  AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA  ",
                        VALID_HASH
                    }));
            fail_if(!valid.hashes_valid || valid.hash_count != 1 ||
                    valid.hash_at(0) != VALID_HASH,
                "Valid SHA-1 values must be normalized and deduplicated");

            Xep.MucAvatars.RoomAvatarInfo malformed =
                Xep.MucAvatars.parse_info_result(build_info(true, true,
                    new string[] { VALID_HASH, "not-a-sha1" }));
            fail_if(!malformed.roominfo_form_present ||
                    !malformed.hash_field_present || malformed.hashes_valid ||
                    malformed.hash_count != 0,
                "One malformed advertised hash must invalidate the complete field without publishing a partial set");
        } catch (Error error) {
            fail_if_reached(@"Unexpected XEP-0486 hash test error: $(error.message)");
        }
    }

    private void test_vcard_selection() {
        try {
            Bytes jpeg = new Bytes("jpeg-avatar".data);
            Bytes png = new Bytes("png-avatar".data);
            string jpeg_hash = Checksum.compute_for_bytes(
                ChecksumType.SHA1, jpeg);
            string png_hash = Checksum.compute_for_bytes(
                ChecksumType.SHA1, png);
            Xep.MucAvatars.RoomAvatarInfo advertised =
                Xep.MucAvatars.parse_info_result(build_info(true, true,
                    new string[] { jpeg_hash, png_hash }));

            var vcard = new StanzaNode.build("vCard",
                    Xep.MucAvatars.VCARD_NS_URI).add_self_xmlns()
                .put_node(build_photo("image/jpeg", jpeg))
                .put_node(build_photo("image/png", png))
                .put_node(build_photo("image/svg+xml", png));
            Xep.MucAvatars.FetchedRoomAvatar? selected =
                Xep.MucAvatars.select_advertised_avatar(vcard, advertised);
            fail_if(selected == null || ((!) selected).hash != png_hash ||
                    ((!) selected).media_type != "image/png",
                "The selected representation must be advertised, hash-verified and prefer PNG over JPEG/SVG");

            Xep.MucAvatars.RoomAvatarInfo wrong_hash =
                Xep.MucAvatars.parse_info_result(build_info(true, true,
                    new string[] { VALID_HASH }));
            fail_if(Xep.MucAvatars.select_advertised_avatar(vcard,
                    wrong_hash) != null,
                "Unadvertised vCard bytes must never enter the avatar cache");

            var typeless_vcard = new StanzaNode.build("vCard",
                    Xep.MucAvatars.VCARD_NS_URI).add_self_xmlns()
                .put_node(build_photo(null, png));
            fail_if(Xep.MucAvatars.select_advertised_avatar(typeless_vcard,
                    advertised) != null,
                "PHOTO/BINVAL without TYPE is malformed and must be ignored");
        } catch (Error error) {
            fail_if_reached(@"Unexpected XEP-0486 vCard test error: $(error.message)");
        }
    }

    private void test_server_controlled_limits() {
        try {
            string[] too_many_hashes = new string[9];
            for (int i = 0; i < too_many_hashes.length; i++) {
                too_many_hashes[i] = Checksum.compute_for_string(
                    ChecksumType.SHA1, i.to_string(), -1);
            }
            Xep.MucAvatars.RoomAvatarInfo excessive_hashes =
                Xep.MucAvatars.parse_info_result(build_info(true, true,
                    too_many_hashes));
            fail_if(excessive_hashes.hashes_valid,
                "An excessive number of advertised representations must fail closed");

            string[] too_many_values = new string[17];
            for (int i = 0; i < too_many_values.length; i++) {
                too_many_values[i] = VALID_HASH;
            }
            Xep.MucAvatars.RoomAvatarInfo excessive_values =
                Xep.MucAvatars.parse_info_result(build_info(true, true,
                    too_many_values));
            fail_if(excessive_values.hashes_valid,
                "Duplicate hash values must not bypass the per-field work limit");

            Bytes bytes = new Bytes("bounded-photo".data);
            string hash = Checksum.compute_for_bytes(ChecksumType.SHA1,
                bytes);
            Xep.MucAvatars.RoomAvatarInfo advertised =
                Xep.MucAvatars.parse_info_result(build_info(true, true,
                    new string[] { hash }));
            var vcard = new StanzaNode.build("vCard",
                Xep.MucAvatars.VCARD_NS_URI).add_self_xmlns();
            for (int i = 0; i < 9; i++) {
                vcard.put_node(build_photo("image/jpeg", bytes));
            }
            fail_if(Xep.MucAvatars.select_advertised_avatar(vcard,
                    advertised) != null,
                "An excessive PHOTO list must be rejected as one bounded unit");
        } catch (Error error) {
            fail_if_reached(@"Unexpected XEP-0486 limit test error: $(error.message)");
        }
    }

    private void test_sender_validation() {
        try {
            Jid room = new Jid(ROOM);
            Iq.Stanza request = new Iq.Stanza.get(new StanzaNode.build(
                "vCard", Xep.MucAvatars.VCARD_NS_URI).add_self_xmlns()) {
                    to = room,
                    from = new Jid("owner@example.test/dinox")
                };
            Iq.Stanza response = new Iq.Stanza.result(request);
            response.from = new Jid("other@conference.example.test");
            fail_if(Xep.MucAvatars.has_expected_sender(response, room),
                "A foreign room sender must not authorize avatar state");
            response.from = room;
            fail_if_not(Xep.MucAvatars.has_expected_sender(response, room),
                "The requested bare room sender must be accepted");
            Iq.Stanza senderless = new Iq.Stanza.result(request);
            fail_if(Xep.MucAvatars.has_expected_sender(senderless, room),
                "A sender-less IQ result must not authorize room-avatar state");
        } catch (Error error) {
            fail_if_reached(@"Unexpected XEP-0486 sender test error: $(error.message)");
        }
    }

    private Xep.ServiceDiscovery.InfoResult build_info(bool vcard_support,
            bool roominfo_form, string[]? hashes) throws Error {
        Jid room = new Jid(ROOM);
        Iq.Stanza request = new Iq.Stanza.get(new StanzaNode.build("query",
            Xep.ServiceDiscovery.NS_URI_INFO).add_self_xmlns()) {
                to = room,
                from = new Jid("owner@example.test/dinox")
            };
        var info = new Xep.ServiceDiscovery.InfoResult(request);
        info.iq.from = room;
        info.add_identity(new Xep.ServiceDiscovery.Identity("conference",
            "text", "Test Room"));
        info.add_feature("http://jabber.org/protocol/muc");
        if (vcard_support) info.add_feature(Xep.MucAvatars.VCARD_NS_URI);
        if (roominfo_form) {
            var form = new StanzaNode.build("x", Xep.DataForms.NS_URI)
                .add_self_xmlns()
                .put_attribute("type", "result")
                .put_node(build_field("FORM_TYPE", new string[] {
                    Xep.MucAvatars.ROOMINFO_FORM_TYPE
                }));
            if (hashes != null) {
                form.put_node(build_field(Xep.MucAvatars.AVATAR_HASH_FIELD,
                    (!) hashes));
            }
            info.iq.stanza.get_subnode("query",
                Xep.ServiceDiscovery.NS_URI_INFO).put_node(form);
        }
        return info;
    }

    private StanzaNode build_field(string field_var, string[] values) {
        var field = new StanzaNode.build("field", Xep.DataForms.NS_URI)
            .put_attribute("var", field_var);
        foreach (string value in values) {
            field.put_node(new StanzaNode.build("value",
                Xep.DataForms.NS_URI).put_node(new StanzaNode.text(value)));
        }
        return field;
    }

    private StanzaNode build_photo(string? media_type, Bytes bytes) {
        var photo = new StanzaNode.build("PHOTO",
            Xep.MucAvatars.VCARD_NS_URI);
        if (media_type != null) {
            photo.put_node(new StanzaNode.build("TYPE",
                Xep.MucAvatars.VCARD_NS_URI).put_node(
                new StanzaNode.text((!) media_type)));
        }
        return photo.put_node(new StanzaNode.build("BINVAL",
                Xep.MucAvatars.VCARD_NS_URI).put_node(new StanzaNode.text(
                    Base64.encode(bytes.get_data()))));
    }
}

}

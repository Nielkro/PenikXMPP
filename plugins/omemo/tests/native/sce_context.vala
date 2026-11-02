using Dino.Entities;
using Xmpp;

namespace Omemo.Test {

class SceContextTest : Gee.TestCase {
    public SceContextTest() {
        base("SceContext");
        add_test("optional_sender_and_time_are_accepted", () => context_case(0));
        add_test("wrong_authenticated_sender_is_rejected", () => context_case(1));
        add_test("group_destination_is_required", () => context_case(2));
        add_test("wrong_group_destination_is_rejected", () => context_case(3));
        add_test("historical_send_time_is_used", () => context_case(4));
        add_test("mismatched_send_time_is_reported_without_losing_content", () => context_case(5));
        add_test("random_padding_is_required", () => context_case(6));
        add_test("direct_received_destination_is_our_account", () => context_case(7));
        add_test("sent_carbon_destination_is_peer", () => context_case(8));
        add_test("malformed_or_duplicate_affixes_are_rejected", test_parse);
        add_test("body_requires_authenticated_client_namespace", test_body_namespace);
    }

    private void context_case(int scenario) {
        try {
            var account = new Account(new Jid("ours@example.test"), "test-only");
            var peer = new Jid("peer@example.test");
            var room = new Jid("room@conference.example.test");
            bool direct = scenario >= 7;
            var conversation = new Conversation(direct ? peer : room, account,
                direct ? Conversation.Type.CHAT : Conversation.Type.GROUPCHAT);
            var message = new Message(null) { account = account,
                direction = scenario == 8 ? Message.DIRECTION_SENT : Message.DIRECTION_RECEIVED,
                time = new DateTime.from_unix_utc(1600000000) };
            var envelope = new Xep.Sce.Envelope();
            envelope.to_jid = direct ? (scenario == 8 ? peer.to_string() : account.bare_jid.to_string()) : room.to_string();
            if (scenario == 1) envelope.from_jid = "wrong@example.test";
            if (scenario == 2) envelope.to_jid = null;
            if (scenario == 3) envelope.to_jid = "other@conference.example.test";
            if (scenario == 4) envelope.timestamp = message.time;
            if (scenario == 5) envelope.timestamp = new DateTime.now_utc();
            if (scenario == 6) envelope.has_padding = false;
            bool rejected = false;
            try {
                Dino.Plugins.Omemo.Omemo2Decrypt.validate_envelope_context(envelope,
                    scenario == 8 ? account.bare_jid : peer, message, conversation);
            } catch (Error error) { rejected = true; }
            fail_if_not(rejected == (scenario == 1 || scenario == 2 || scenario == 3 || scenario == 6),
                "SCE must enforce required/context affixes without requiring optional sender/time");
            if (scenario == 5) fail_if_not(message.encryption_time_mismatch, "Clock skew must be reported without losing authenticated content");
            if (scenario == 4) fail_if(message.encryption_time_mismatch, "Historical delivery must use historical time");
        } catch (Error error) { fail_if_reached(error.message); }
    }

    private Xep.Sce.Envelope? parse(string xml) {
        var loop = new MainLoop();
        Xep.Sce.Envelope? result = null;
        bool done = false;
        Xep.Sce.Envelope.from_xml.begin(xml.data, (_, response) => {
            result = Xep.Sce.Envelope.from_xml.end(response);
            done = true;
            loop.quit();
        });
        if (!done) loop.run();
        return result;
    }

    private void test_parse() {
        foreach (string malformed in new string[] {
            "<from/>", "<to/>", "<time/>", "<time stamp='invalid'/>",
            "<from jid='a@example.test'/><from jid='b@example.test'/>",
            "<content/>", "<rpad>a</rpad><rpad>b</rpad>"
        }) {
            fail_if(parse("<envelope xmlns='urn:xmpp:sce:1'><content/>" + malformed + "</envelope>") != null,
                "Malformed or ambiguous affixes must not become absent optional affixes");
        }
        var optional = parse("<envelope xmlns='urn:xmpp:sce:1'><content/><rpad>a</rpad></envelope>");
        fail_if(optional == null, "Optional sender/time must parse");
        var unpadded = parse("<envelope xmlns='urn:xmpp:sce:1'><content/></envelope>");
        fail_if(unpadded == null || ((!) unpadded).has_padding,
            "Generic SCE parsing must retain padding absence for OMEMO profile validation");
    }

    private void test_body_namespace() {
        var envelope = parse("<envelope xmlns='urn:xmpp:sce:1'><content><body xmlns='other'>forged</body></content><rpad>a</rpad></envelope>");
        fail_if(envelope == null || ((!) envelope).get_body() != null,
            "Wrong namespace must not be displayed as authenticated message body");
    }
}

}

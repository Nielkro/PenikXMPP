using Xmpp;

namespace Dino.Test {

public class InvitesTest : Gee.TestCase {
    public InvitesTest() {
        base("Invites");
        add_test("parse_xep0401_result", test_parse_xep0401_result);
        add_test("parse_expiry_alias", test_parse_expiry_alias);
        add_test("reject_executing_command", test_reject_executing_command);
        add_test("reject_missing_uri", test_reject_missing_uri);
        add_test("parse_user_invite_uri_options", test_parse_user_invite_uri_options);
    }

    private void test_parse_xep0401_result() {
        var command = build_command("completed", {
            "uri", "xmpp:romeo@example.com?roster;preauth=TOKEN;ibr=y",
            "landing-url", "https://example.com/invite/TOKEN",
            "expire", "2026-05-14T12:00:00Z"
        });

        InviteResult? result = InviteResult.from_command(command);
        fail_if(result == null, "expected invite result");
        fail_if_not_eq_str(result.uri, "xmpp:romeo@example.com?roster;preauth=TOKEN;ibr=y");
        fail_if_not_eq_str(result.landing_url, "https://example.com/invite/TOKEN");
        fail_if_not_eq_str(result.expires_at, "2026-05-14T12:00:00Z");
    }

    private void test_parse_expiry_alias() {
        var command = build_command("completed", {
            "uri", "xmpp:example.com?register;preauth=TOKEN",
            "expiry", "2026-05-14T12:00:00Z"
        });

        InviteResult? result = InviteResult.from_command(command);
        fail_if(result == null, "expected invite result");
        fail_if_not_eq_str(result.expires_at, "2026-05-14T12:00:00Z");
    }

    private void test_reject_executing_command() {
        var command = build_command("executing", {
            "uri", "xmpp:example.com?register;preauth=TOKEN"
        });
        fail_if(InviteResult.from_command(command) != null, "executing commands must not be accepted as invite results");
    }

    private void test_reject_missing_uri() {
        var command = build_command("completed", {
            "landing-url", "https://example.com/invite/TOKEN"
        });
        fail_if(InviteResult.from_command(command) != null, "invite result without uri must be rejected");
    }

    private void test_parse_user_invite_uri_options() {
        XmppUriInfo? info = parse_xmpp_uri("xmpp:romeo@example.com?roster;preauth=TOKEN;ibr=y;name=Romeo");
        fail_if(info == null, "expected parsed XMPP URI");
        fail_if_not_eq_str(info.jid, "romeo@example.com");
        fail_if(info.kind != XmppUriKind.CHAT, "roster query should be treated as chat/contact invite");
        fail_if_not_eq_str(info.options["preauth"], "TOKEN");
        fail_if_not_eq_str(info.options["ibr"], "y");
        fail_if_not_eq_str(info.options["name"], "Romeo");
    }

    private Xep.AdHocCommands.Command build_command(string status, string[] fields) {
        StanzaNode node = new StanzaNode.build("command", Xep.AdHocCommands.NS_URI)
            .add_self_xmlns()
            .put_attribute("node", InviteManager.USER_INVITE_NODE)
            .put_attribute("status", status);
        StanzaNode x = new StanzaNode.build("x", Xep.DataForms.NS_URI)
            .add_self_xmlns()
            .put_attribute("type", "result");
        for (int i = 0; i + 1 < fields.length; i += 2) {
            x.put_node(field(fields[i], fields[i + 1]));
        }
        node.put_node(x);
        return Xep.AdHocCommands.Command.from_node(node);
    }

    private StanzaNode field(string var_name, string value) {
        return new StanzaNode.build("field", Xep.DataForms.NS_URI)
            .put_attribute("var", var_name)
            .put_attribute("type", "text-single")
            .put_node(new StanzaNode.build("value", Xep.DataForms.NS_URI)
                .put_node(new StanzaNode.text(value)));
    }
}

}

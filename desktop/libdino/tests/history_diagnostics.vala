using Dino.Entities;
using Xmpp;

namespace Dino.Test {

class HistoryDiagnosticsTest : Gee.TestCase {
    public HistoryDiagnosticsTest() {
        base("HistoryDiagnostics");
        add_test("archive_trace_excludes_content_and_preserves_state", test_archive_trace);
        add_test("live_message_is_not_in_archive_trace", test_live_message);
        add_test("untrusted_identifiers_cannot_inject_log_records", test_identifier_safety);
    }

    private void test_archive_trace() {
        try {
            var account = new Account(new Jid("owner@example.test"), "private-password") { id = 7 };
            var room = new Jid("room@conference.example.test");
            var cleared = new DateTime.from_unix_utc(1700000000);
            var conversation = new Conversation(room, account, Conversation.Type.GROUPCHAT) {
                id = 12, history_cleared_at = cleared, message_expiry_seconds = 3600
            };
            var message = new Entities.Message("private-decrypted-body") {
                account = account, counterpart = room, stanza_id = "sender-id",
                encryption = Encryption.OMEMO, decryption_failed = true
            };
            var stanza = new MessageStanza("sender-id");
            stanza.body = "private-wire-body";
            stanza.stanza.put_node(new StanzaNode.build("encrypted", "urn:xmpp:omemo:2")
                .put_node(new StanzaNode.text("private-ciphertext")));
            stanza.add_flag(new Xmpp.MessageArchiveManagement.MessageFlag(
                room, cleared.add_seconds(-1), "archive-id", "query-id"));
            stanza.set_data<string>("dinox-history-trace-origin", "automatic");
            string before_xml = stanza.stanza.to_string();
            bool before_policy = MessageProcessor.archive_replay_is_outside_history_policy(stanza, conversation);
            string? output = HistoryDiagnostics.format_message("admit-archive", message, stanza, conversation);
            if (fail_if(output == null, "MAM provenance must be traceable")) return;
            foreach (string secret in new string[] {account.password, message.body, stanza.body, "private-ciphertext"}) {
                fail_if(((!) output).contains(secret), "Trace must never serialize content or credentials");
            }
            foreach (string field in new string[] {"account=7", "conversation=12", "origin=automatic",
                    "archive_id=archive-id", "stanza_id=sender-id", "query=query-id",
                    "cleared_at=1700000000", "archive_time=1699999999", "decryption_failed=true"}) {
                fail_if_not(((!) output).contains(field), "Trace must retain diagnostic provenance");
            }
            fail_if_not_eq_str(stanza.stanza.to_string(), before_xml);
            fail_if_not_eq_str(message.body, "private-decrypted-body");
            fail_if(message.id != -1, "Formatting must not persist a message");
            fail_if(conversation.history_cleared_at != cleared, "Formatting must not reset the clear boundary");
            fail_if(!before_policy || !MessageProcessor.archive_replay_is_outside_history_policy(stanza, conversation),
                "Tracing must not admit deleted archive messages");
        } catch (Error error) { fail_if_reached(error.message); }
    }

    private void test_live_message() {
        try {
            var account = new Account(new Jid("owner@example.test"), "private-password");
            var conversation = new Conversation(new Jid("peer@example.test"), account, Conversation.Type.CHAT);
            var message = new Entities.Message("private-live-message") { account = account };
            var stanza = new MessageStanza("live-id");
            stanza.body = message.body;
            fail_if(HistoryDiagnostics.format_message("listener-completed", message, stanza, conversation) != null,
                "Archive diagnosis must not record unrelated live messages");
        } catch (Error error) { fail_if_reached(error.message); }
    }

    private void test_identifier_safety() {
        string hostile = "id\nHISTORY_TRACE event=forged\r\t secret=1";
        string escaped = HistoryDiagnostics.token(hostile);
        fail_if(escaped.contains("\n") || escaped.contains("\r") || escaped.contains("\t") || escaped.contains(" "),
            "Remote identifiers must remain one escaped log field");
        fail_if_not_eq_str(Uri.unescape_string(escaped), hostile);
        string long_id = string.nfill(500, 'x');
        string first = HistoryDiagnostics.token(long_id + "a");
        string second = HistoryDiagnostics.token(long_id + "b");
        fail_if(first.length > 160 || second.length > 160, "Remote identifiers must have bounded output");
        fail_if(first == second, "Truncated identifiers need a correlation digest");
        fail_if_not_eq_str(first, HistoryDiagnostics.token(long_id + "a"));
    }
}

}

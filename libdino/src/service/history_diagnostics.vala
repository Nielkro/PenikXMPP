using Dino.Entities;
using Xmpp;

namespace Dino {

// Opt-in metadata tracing for first-start/archive regressions. Never serialize
// stanzas, message bodies, credentials, keys or cryptographic session records.
internal class HistoryDiagnostics : Object {
    internal static bool enabled() {
        return Environment.get_variable("DINOX_TRACE_HISTORY") == "1";
    }

    internal static string token(string? value) {
        if (value == null) return "-";
        string escaped = Uri.escape_string(value, null, false);
        if (escaped.length <= 160) return escaped;
        return escaped.substring(0, 128) + "~" +
            Checksum.compute_for_string(ChecksumType.SHA256, value).substring(0, 16);
    }

    internal static string stamp(DateTime? value) {
        return value != null ? value.to_unix().to_string() : "-";
    }

    internal static void write(string metadata) {
        if (enabled()) GLib.message("HISTORY_TRACE %s", metadata);
    }

    internal static string? format_message(string stage, Entities.Message message,
            MessageStanza stanza, Conversation conversation, string? listener = null) {
        var mam = Xmpp.MessageArchiveManagement.MessageFlag.get_flag(stanza);
        if (mam == null) return null;
        return "event=%s account=%d conversation=%d type=%d peer=%s archive=%s query=%s origin=%s archive_id=%s stanza_id=%s archive_time=%s cleared_at=%s expiry_seconds=%d message_id=%d encryption=%d decryption_failed=%s listener=%s".printf(
            token(stage), message.account.id, conversation.id, (int) conversation.type_,
            token(conversation.counterpart.to_string()), token(mam.sender_jid.to_string()),
            token(mam.query_id), token(stanza.get_data<string>("dinox-history-trace-origin")),
            token(mam.mam_id), token(message.stanza_id), stamp(mam.server_time),
            stamp(conversation.history_cleared_at), conversation.message_expiry_seconds,
            message.id, (int) message.encryption, message.decryption_failed.to_string(), token(listener));
    }

    internal static void received(string stage, Entities.Message message,
            MessageStanza stanza, Conversation conversation, string? listener = null) {
        if (!enabled()) return;
        string? metadata = format_message(stage, message, stanza, conversation, listener);
        if (metadata != null) write(metadata);
    }

    internal static void query(string stage, Account account,
            Xmpp.MessageArchiveManagement.V2.MamQueryParams query,
            string origin, string? page_before,
            Xmpp.MessageArchiveManagement.QueryResult? result = null) {
        if (!enabled()) return;
        write("event=%s account=%d archive=%s query=%s origin=%s with=%s start=%s end=%s start_id=%s end_id=%s page_before=%s max_items=%d first=%s last=%s complete=%s error=%s malformed=%s".printf(
            token(stage), account.id, token(query.mam_server.to_string()), token(query.query_id),
            token(origin), token(query.with != null ? query.with.to_string() : null),
            stamp(query.start), stamp(query.end), token(query.start_id), token(query.end_id),
            token(page_before), query.max_items, token(result != null ? result.first : null),
            token(result != null ? result.last : null),
            result != null ? result.complete.to_string() : "-",
            result != null ? result.error.to_string() : "-",
            result != null ? result.malformed.to_string() : "-"));
    }
}

}

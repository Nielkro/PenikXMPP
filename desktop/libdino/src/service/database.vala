/*
 * Copyright (C) 2025 Ralf Peter <dinox@handwerker.jetzt>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

using Gee;
using Qlite;
using Xmpp;

using Dino.Entities;

namespace Dino {

public class Database : Qlite.Database {
    private const int VERSION = 60;
    private const string FILE_ENCRYPTION_SETTING = "file_encryption_key";

    /** Existing files use the password originally supplied to FileEncryption.
     * Store it inside the encrypted database before any password change, so
     * database rekeying never changes the independent file encryption secret. */
    public string get_or_create_file_encryption_key(string original_key) throws Error {
        return ensure_file_encryption_key(this, original_key);
    }

    internal static string ensure_file_encryption_key(Qlite.Database database, string original_key) throws Error {
        if (original_key.length == 0) throw new IOError.INVALID_ARGUMENT("File encryption key must not be empty");
        database.exec_prepared("INSERT OR IGNORE INTO settings (key, value) VALUES (?, ?)",
            { FILE_ENCRYPTION_SETTING, original_key });
        string[] values = database.query_column_checked("SELECT value FROM settings WHERE key = ?", { FILE_ENCRYPTION_SETTING });
        if (values.length != 1 || values[0].length == 0)
            throw new IOError.INVALID_DATA("Stored file encryption key is missing or invalid");
        return values[0];
    }

    /** Operates on an offline staged database. Account IDs, account/global
     * settings, roster and local sticker libraries remain valid across reset. */
    internal static void reset_local_history(Qlite.Database database) throws Error {
        string[] history_tables = { "content_item", "body_meta", "message_occupant_id", "message_correction",
            "reply", "real_jid", "reaction", "muc_displayed_state", "file_hashes", "file_thumbnails",
            "sfs_sources", "file_transfer", "call_jmi_proposal", "call_jmi_sid", "call_counterpart",
            "call", "undecrypted", "message" };
        database.exec("PRAGMA secure_delete = ON");
        database.exec("BEGIN IMMEDIATE");
        try {
            foreach (string name in history_tables) {
                if (database.query_column_checked("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", { name }).length == 0)
                    continue;
                database.exec("DELETE FROM \"" + name + "\"");
            }
            // Keep settings for existing conversations and a clear-history
            // boundary so archive catchup does not immediately refill them.
            database.exec_prepared("UPDATE conversation SET read_up_to = NULL, read_up_to_item = -1, history_cleared_at = ?",
                { new DateTime.now_utc().to_unix().to_string() });
            database.exec("COMMIT");
        } catch (Error e) {
            try { database.exec("ROLLBACK"); } catch (Error ignored) { }
            throw e;
        }
        database.exec("VACUUM");
    }

    public class AccountTable : Table {
        public Column<int> id = new Column.Integer("id") { primary_key = true, auto_increment = true };
        public Column<string> bare_jid = new Column.Text("bare_jid") { unique = true, not_null = true };
        public Column<string> resourcepart = new Column.Text("resourcepart");
        public Column<string> password = new Column.Text("password");
        public Column<string> alias = new Column.Text("alias");
        public Column<bool> enabled = new Column.BoolInt("enabled");
        public Column<string> roster_version = new Column.Text("roster_version") { min_version=2 };
        // no longer used. all usages already removed. remove db column at some point.
        public Column<long> mam_earliest_synced = new Column.Long("mam_earliest_synced") { min_version=4 };
        public Column<string> custom_host = new Column.Text("custom_host") { min_version=31 };
        public Column<int> custom_port = new Column.Integer("custom_port") { min_version=31 };
        public Column<string> proxy_type = new Column.Text("proxy_type") { min_version=36, default="'none'" };
        public Column<string> proxy_host = new Column.Text("proxy_host") { min_version=36 };
        public Column<int> proxy_port = new Column.Integer("proxy_port") { min_version=36 };
        public Column<string> proxy_user = new Column.Text("proxy_user") { min_version=38 };
        public Column<string> proxy_pass = new Column.Text("proxy_pass") { min_version=38 };
        public Column<bool> require_channel_binding = new Column.BoolInt("require_channel_binding") { min_version=37, default="0" };

        public Column<bool> allow_plain = new Column.BoolInt("allow_plain") { min_version=59, default="0" };
        public Column<bool> scram_seen = new Column.BoolInt("scram_seen") { min_version=59, default="0" };

        internal AccountTable(Database db) {
            base(db, "account");
            init({id, bare_jid, resourcepart, password, alias, enabled, roster_version, mam_earliest_synced, custom_host, custom_port, proxy_type, proxy_host, proxy_port, proxy_user, proxy_pass, require_channel_binding, allow_plain, scram_seen});
        }
    }

    public class JidTable : Table {
        public Column<int> id = new Column.Integer("id") { primary_key = true, auto_increment = true };
        public Column<string> bare_jid = new Column.Text("bare_jid") { unique = true, not_null = true };

        internal JidTable(Database db) {
            base(db, "jid");
            init({id, bare_jid});
        }
    }

    public class EntityTable : Table {
        public Column<int> id = new Column.Integer("id") { primary_key = true, auto_increment = true };
        public Column<int> account_id = new Column.Integer("account_id");
        public Column<int> jid_id = new Column.Integer("jid_id");
        public Column<string> resource = new Column.Text("resource");
        public Column<string> caps_hash = new Column.Text("caps_hash");
        public Column<long> last_seen = new Column.Long("last_seen");

        internal EntityTable(Database db) {
            base(db, "entity");
            init({id, account_id, jid_id, resource, caps_hash, last_seen});
            unique({account_id, jid_id, resource}, "IGNORE");
        }
    }

    public class ContentItemTable : Table {
        public Column<int> id = new Column.Integer("id") { primary_key = true, auto_increment = true };
        public Column<int> conversation_id = new Column.Integer("conversation_id") { not_null = true };
        public Column<long> time = new Column.Long("time") { not_null = true };
        public Column<long> local_time = new Column.Long("local_time") { not_null = true };
        public Column<int> content_type = new Column.Integer("content_type") { not_null = true };
        public Column<int> foreign_id = new Column.Integer("foreign_id") { not_null = true };
        public Column<bool> hide = new Column.BoolInt("hide") { default = "0", not_null = true, min_version = 9 };

        internal ContentItemTable(Database db) {
            base(db, "content_item");
            init({id, conversation_id, time, local_time, content_type, foreign_id, hide});
            index("contentitem_conversation_hide_time_idx", {conversation_id, hide, time});
            unique({content_type, foreign_id}, "IGNORE");
        }
    }

    public class MessageTable : Table {
        public Column<int> id = new Column.Integer("id") { primary_key = true, auto_increment = true };
        public Column<string> stanza_id = new Column.Text("stanza_id");
        public Column<string> server_id = new Column.Text("server_id") { min_version=10 };
        public Column<string> sender_stanza_id =
            new Column.Text("sender_stanza_id") { min_version = 49 };
        public Column<string> stable_id = new Column.Text("stable_id") {
            min_version = 48
        };
        public Column<string> stable_id_by = new Column.Text("stable_id_by") {
            min_version = 48
        };
        public Column<int> account_id = new Column.Integer("account_id") { not_null = true };
        public Column<int> counterpart_id = new Column.Integer("counterpart_id") { not_null = true };
        public Column<string> counterpart_resource = new Column.Text("counterpart_resource");
        public Column<string> our_resource = new Column.Text("our_resource");
        public Column<bool> direction = new Column.BoolInt("direction") { not_null = true };
        public Column<int> type_ = new Column.Integer("type");
        public Column<long> time = new Column.Long("time");
        public Column<long> local_time = new Column.Long("local_time");
        public Column<string> body = new Column.Text("body");
        public Column<bool> archive_retracted = new Column.BoolInt("archive_retracted") {
            min_version = 60, default = "0", not_null = true
        };
        public Column<int> encryption = new Column.Integer("encryption");
        public Column<string> encryption_protocol = new Column.Text("encryption_protocol") { min_version=41 };
        public Column<bool> decryption_failed = new Column.BoolInt("decryption_failed") { min_version=54, default="0", not_null=true };
        public Column<bool> encryption_time_mismatch = new Column.BoolInt("encryption_time_mismatch") { min_version=54, default="0", not_null=true };
        public Column<int> mention_state = new Column.Integer("mention_state") {
            min_version = 57, default = "0", not_null = true
        };
        public Column<int> marked = new Column.Integer("marked");
        public Column<bool> markable = new Column.BoolInt("markable") {
            min_version = 47,
            default = "0",
            not_null = true
        };

        internal MessageTable(Database db) {
            base(db, "message");
            init({id, stanza_id, server_id, sender_stanza_id, stable_id,
                stable_id_by,
                account_id, counterpart_id, our_resource, counterpart_resource, direction,
                type_, time, local_time, body, archive_retracted, encryption, encryption_protocol,
                decryption_failed, encryption_time_mismatch, mention_state, marked, markable});

            // get latest messages
            index("message_account_counterpart_time_idx", {account_id, counterpart_id, time});
            index("message_archive_retracted_idx", {account_id, counterpart_id, type_, archive_retracted});
            index("message_account_counterpart_direction_localtime_idx",
                {account_id, counterpart_id, type_, direction, local_time,
                    id});
            index("message_account_counterpart_mentions_idx",
                {account_id, counterpart_id, type_, direction, mention_state});

            // deduplication
            index("message_account_counterpart_stanzaid_idx", {account_id, counterpart_id, stanza_id});
            index("message_account_counterpart_serverid_idx", {account_id, counterpart_id, server_id});
            index("message_account_counterpart_senderid_idx",
                {account_id, counterpart_id, sender_stanza_id});
            index("message_account_counterpart_stableid_idx",
                {account_id, counterpart_id, stable_id, stable_id_by});

            // message by marked
            index("message_account_marked_idx", {account_id, marked});

            fts({body});
        }
    }

    public class MessageOccupantId : Table {
        public Column<int> id = new Column.Integer("id") { primary_key = true, auto_increment = true };
        public Column<int> message_id = new Column.Integer("message_id") { not_null = true };
        public Column<int> occupant_id = new Column.Integer("occupant_id") { not_null = true };

        internal MessageOccupantId(Database db) {
            base(db, "message_occupant_id");
            init({id, message_id, occupant_id});

            index("message_id_occupant_id", { message_id, occupant_id });
        }
    }

    public class BodyMeta : Table {
        public Column<int> id = new Column.Integer("id") { primary_key = true, auto_increment = true };
        public Column<int> message_id = new Column.Integer("message_id");
        public Column<int> from_char = new Column.Integer("from_char");
        public Column<int> to_char = new Column.Integer("to_char");
        public Column<string> info_type = new Column.Text("info_type");
        public Column<string> info = new Column.Text("info");

        internal BodyMeta(Database db) {
            base(db, "body_meta");
            init({id, message_id, from_char, to_char, info_type, info});
            index("body_meta_message_id_idx", {message_id});
        }
    }

    public class MessageCorrectionTable : Table {
        public Column<int> id = new Column.Integer("id") { primary_key = true, auto_increment = true };
        public Column<int> message_id = new Column.Integer("message_id") { unique=true };
        public Column<string> to_stanza_id = new Column.Text("to_stanza_id");

        internal MessageCorrectionTable(Database db) {
            base(db, "message_correction");
            init({id, message_id, to_stanza_id});
            index("message_correction_to_stanza_id_idx", {to_stanza_id});
        }
    }

    public class ReplyTable : Table {
        public Column<int> id = new Column.Integer("id") { primary_key = true, auto_increment = true };
        public Column<int> message_id = new Column.Integer("message_id") { not_null = true, unique=true };
        public Column<int> quoted_content_item_id = new Column.Integer("quoted_message_id");
        public Column<string?> quoted_message_stanza_id = new Column.Text("quoted_message_stanza_id");
        public Column<string?> quoted_message_from = new Column.Text("quoted_message_from");

        internal ReplyTable(Database db) {
            base(db, "reply");
            init({id, message_id, quoted_content_item_id, quoted_message_stanza_id, quoted_message_from});
            index("reply_quoted_content_item_id", {quoted_content_item_id});
            index("reply_quoted_message_stanza_id", {quoted_message_stanza_id});
        }
    }

    public class RealJidTable : Table {
        public Column<int> message_id = new Column.Integer("message_id") { primary_key = true };
        public Column<string> real_jid = new Column.Text("real_jid");

        internal RealJidTable(Database db) {
            base(db, "real_jid");
            init({message_id, real_jid});
        }
    }

    public class OccupantIdTable : Table {
        public Column<int> id = new Column.Integer("id") { primary_key = true };
        public Column<int> account_id = new Column.Integer("account_id") { not_null = true };
        public Column<string> last_nick = new Column.Text("last_nick");
        public Column<int> jid_id = new Column.Integer("jid_id");
        public Column<string> occupant_id = new Column.Text("occupant_id");

        internal OccupantIdTable(Database db) {
            base(db, "occupant_id");
            init({id, account_id, last_nick, jid_id, occupant_id});
            unique({account_id, jid_id, occupant_id}, "REPLACE");
        }
    }

    public class UndecryptedTable : Table {
        public Column<int> message_id = new Column.Integer("message_id");
        public Column<int> type_ = new Column.Integer("type");
        public Column<string> data = new Column.Text("data");

        internal UndecryptedTable(Database db) {
            base(db, "undecrypted");
            init({message_id, type_, data});
            index("undecrypted_message_id_idx", {message_id});
        }
    }

    public class FileTransferTable : Table {
        public Column<int> id = new Column.Integer("id") { primary_key = true, auto_increment = true };
        public Column<string> file_sharing_id = new Column.Text("file_sharing_id") { min_version=28 };
        public Column<int> account_id = new Column.Integer("account_id") { not_null = true };
        public Column<int> counterpart_id = new Column.Integer("counterpart_id") { not_null = true };
        public Column<string> counterpart_resource = new Column.Text("counterpart_resource");
        public Column<string> our_resource = new Column.Text("our_resource");
        public Column<bool> direction = new Column.BoolInt("direction") { not_null = true };
        public Column<long> time = new Column.Long("time");
        public Column<long> local_time = new Column.Long("local_time");
        public Column<int> encryption = new Column.Integer("encryption");
        public Column<string> file_name = new Column.Text("file_name");
        public Column<string> path = new Column.Text("path");
        public Column<string> mime_type = new Column.Text("mime_type");
        public Column<long> size = new Column.Long("size");
        public Column<int> state = new Column.Integer("state");
        public Column<string> encryption_protocol = new Column.Text("encryption_protocol") { min_version=41 };
        public Column<int> provider = new Column.Integer("provider");
        public Column<string> info = new Column.Text("info");
        // Local database relation to the chat message that announced this
        // transfer. Keep it separate from `info`, which belongs to the
        // transport and may contain a URL or a Jingle session identifier.
        public Column<int> message_id = new Column.Integer("message_id") { default = "-1", min_version = 51 };
        public Column<long> modification_date = new Column.Long("modification_date") { default = "-1", min_version=28 };
        public Column<int> width = new Column.Integer("width") { default = "-1", min_version=28 };
        public Column<int> height = new Column.Integer("height") { default = "-1", min_version=28 };
        public Column<long> length = new Column.Integer("length") { default = "-1", min_version=28 };
        public Column<int> retry_count = new Column.Integer("retry_count") { default = "0", min_version=42 };
        public Column<long> next_retry_time = new Column.Long("next_retry_time") { default = "0", min_version=42 };
        public Column<long> last_attempt_time = new Column.Long("last_attempt_time") { default = "0", min_version=42 };

        public Column<bool> is_sticker = new Column.BoolInt("is_sticker") { default = "0", not_null = true, min_version = 35 };
        public Column<string> sticker_pack_id = new Column.Text("sticker_pack_id") { min_version = 35 };
        public Column<string> sticker_pack_jid = new Column.Text("sticker_pack_jid") { min_version = 35 };
        public Column<string> sticker_pack_node = new Column.Text("sticker_pack_node") { min_version = 35 };

        internal FileTransferTable(Database db) {
            base(db, "file_transfer");
            init({id, file_sharing_id, account_id, counterpart_id, counterpart_resource, our_resource, direction,
                time, local_time, encryption, file_name, path, mime_type, size, state, encryption_protocol, provider, info, message_id, modification_date,
                width, height, length, retry_count, next_retry_time, last_attempt_time, is_sticker, sticker_pack_id, sticker_pack_jid, sticker_pack_node});
            index("file_transfer_account_counterpart_idx", {account_id, counterpart_id});
            index("file_transfer_info_idx", {info});
            index("file_transfer_message_id_idx", {message_id});
        }
    }

    public class StickerPackTable : Table {
        public Column<int> id = new Column.Integer("id") { primary_key = true, auto_increment = true, min_version = 35 };
        public Column<int> account_id = new Column.Integer("account_id") { not_null = true, min_version = 35 };
        public Column<string> pack_id = new Column.Text("pack_id") { not_null = true, min_version = 35 };
        public Column<string> source_jid = new Column.Text("source_jid") { min_version = 35 };
        public Column<string> source_node = new Column.Text("source_node") { min_version = 35 };
        public new Column<string> name = new Column.Text("name") { min_version = 35 };
        public Column<string> summary = new Column.Text("summary") { min_version = 35 };
        public Column<bool> restricted = new Column.BoolInt("restricted") { default = "0", not_null = true, min_version = 35 };

        internal StickerPackTable(Database db) {
            base(db, "sticker_pack");
            init({id, account_id, pack_id, source_jid, source_node, name, summary, restricted});
            unique({account_id, pack_id}, "REPLACE");
            index("sticker_pack_account_pack_idx", {account_id, pack_id});
        }
    }

    public class StickerItemTable : Table {
        public Column<int> id = new Column.Integer("id") { primary_key = true, auto_increment = true, min_version = 35 };
        public Column<int> account_id = new Column.Integer("account_id") { not_null = true, min_version = 35 };
        public Column<string> pack_id = new Column.Text("pack_id") { not_null = true, min_version = 35 };
        public Column<int> position = new Column.Integer("position") { not_null = true, min_version = 35 };
        public Column<string> desc = new Column.Text("desc") { min_version = 35 };
        public Column<string> media_type = new Column.Text("media_type") { min_version = 35 };
        public Column<string> hash_algo = new Column.Text("hash_algo") { min_version = 35 };
        public Column<string> hash_value = new Column.Text("hash_value") { min_version = 35 };
        public Column<string> source_url = new Column.Text("source_url") { min_version = 35 };
        public Column<string> local_path = new Column.Text("local_path") { min_version = 35 };

        internal StickerItemTable(Database db) {
            base(db, "sticker_item");
            init({id, account_id, pack_id, position, desc, media_type, hash_algo, hash_value, source_url, local_path});
            index("sticker_item_account_pack_pos_idx", {account_id, pack_id, position});
        }
    }

    public class FileHashesTable : Table {
        public Column<int> id = new Column.Integer("id");
        public Column<string> algo = new Column.Text("algo") { not_null = true };
        public Column<string> value = new Column.Text("value") { not_null = true };

        internal FileHashesTable(Database db) {
            base(db, "file_hashes");
            init({id, algo, value});
            unique({id, algo}, "REPLACE");
        }
    }

    public class FileThumbnailsTable : Table {
        public Column<int> id = new Column.Integer("id");
        // TODO store data as bytes, not as data uri
        public Column<string> uri = new Column.Text("uri") { not_null = true };
        public Column<string> mime_type = new Column.Text("mime_type");
        public Column<int> width = new Column.Integer("width");
        public Column<int> height = new Column.Integer("height");

        internal FileThumbnailsTable(Database db) {
            base(db, "file_thumbnails");
            init({id, uri, mime_type, width, height});
        }
    }

    public class SourcesTable : Table {
        public Column<int> file_transfer_id = new Column.Integer("file_transfer_id");
        public Column<string> type = new Column.Text("type") { not_null = true };
        public Column<string> data = new Column.Text("data") { not_null = true };

        internal SourcesTable(Database db) {
            base(db, "sfs_sources");
            init({file_transfer_id, type, data});
            index("sfs_sources_file_transfer_id_idx", {file_transfer_id});
        }
    }

    public class CallTable : Table {
        public Column<int> id = new Column.Integer("id") { primary_key = true, auto_increment = true };
        public Column<int> account_id = new Column.Integer("account_id") { not_null = true };
        public Column<int> counterpart_id = new Column.Integer("counterpart_id") { not_null = true };
        public Column<string> counterpart_resource = new Column.Text("counterpart_resource");
        public Column<string> our_resource = new Column.Text("our_resource");
        public Column<bool> direction = new Column.BoolInt("direction") { not_null = true };
        public Column<long> time = new Column.Long("time") { not_null = true };
        public Column<long> local_time = new Column.Long("local_time") { not_null = true };
        public Column<long> end_time = new Column.Long("end_time");
        public Column<int> encryption = new Column.Integer("encryption") { min_version=21 };
        public Column<int> state = new Column.Integer("state");

        internal CallTable(Database db) {
            base(db, "call");
            init({id, account_id, counterpart_id, counterpart_resource, our_resource, direction, time, local_time, end_time, encryption, state});
        }
    }

    public class CallCounterpartTable : Table {
        public Column<int> id = new Column.Integer("id") { primary_key = true, auto_increment = true };
        public Column<int> call_id = new Column.Integer("call_id") { not_null = true };
        public Column<int> jid_id = new Column.Integer("jid_id") { not_null = true };
        public Column<string> resource = new Column.Text("resource");

        internal CallCounterpartTable(Database db) {
            base(db, "call_counterpart");
            init({call_id, jid_id, resource});
            index("call_counterpart_call_jid_idx", {call_id});
        }
    }

    /** Stable XEP-0353 lifecycle identities belonging to one call row. */
    internal class CallJmiSidTable : Table {
        public Column<int> id = new Column.Integer("id") {
            primary_key = true, auto_increment = true, min_version = 52
        };
        public Column<int> call_id = new Column.Integer("call_id") {
            not_null = true, min_version = 52
        };
        public Column<int> account_id = new Column.Integer("account_id") {
            not_null = true, min_version = 52
        };
        public Column<string> sid = new Column.Text("sid") {
            not_null = true, min_version = 52
        };

        internal CallJmiSidTable(Database db) {
            base(db, "call_jmi_sid");
            init({id, call_id, account_id, sid});
            unique({account_id, sid}, "IGNORE");
            index("call_jmi_sid_call_idx", {call_id});
        }
    }

    /**
     * Restart-safe ownership for an unresolved incoming XEP-0353 proposal.
     * The ordinary call row remains a history projection; this row is the
     * explicit proof that it may be made actionable again.
     */
    internal class CallJmiProposalTable : Table {
        public Column<int> id = new Column.Integer("id") {
            primary_key = true, auto_increment = true, min_version = 53
        };
        public Column<int> call_id = new Column.Integer("call_id") {
            not_null = true, min_version = 53
        };
        public Column<int> account_id = new Column.Integer("account_id") {
            not_null = true, min_version = 53
        };
        public Column<int> conversation_id = new Column.Integer(
            "conversation_id") { not_null = true, min_version = 53 };
        public Column<string> sid = new Column.Text("sid") {
            not_null = true, min_version = 53
        };
        public Column<string> proposal_source = new Column.Text(
            "proposal_source") { not_null = true, min_version = 53 };
        public Column<string> proposal_target = new Column.Text(
            "proposal_target") { not_null = true, min_version = 53 };
        public Column<long> started_at = new Column.Long("started_at") {
            not_null = true, min_version = 53
        };
        public Column<long> expires_at = new Column.Long("expires_at") {
            not_null = true, min_version = 53
        };
        public Column<bool> audio_requested = new Column.BoolInt(
            "audio_requested") { not_null = true, min_version = 53 };
        public Column<bool> video_requested = new Column.BoolInt(
            "video_requested") { not_null = true, min_version = 53 };

        internal CallJmiProposalTable(Database db) {
            base(db, "call_jmi_proposal");
            init({id, call_id, account_id, conversation_id, sid,
                proposal_source, proposal_target, started_at, expires_at,
                audio_requested, video_requested});
            unique({call_id}, "IGNORE");
            unique({account_id, sid}, "IGNORE");
            index("call_jmi_proposal_account_idx", {account_id});
        }
    }

    public class ConversationTable : Table {
        public Column<int> id = new Column.Integer("id") { primary_key = true, auto_increment = true };
        public Column<int> account_id = new Column.Integer("account_id") { not_null = true };
        public Column<int> jid_id = new Column.Integer("jid_id") { not_null = true };
        public Column<string> resource = new Column.Text("resource") { min_version=1 };
        public Column<bool> active = new Column.BoolInt("active");
        public Column<long> active_last_changed = new Column.Integer("active_last_changed") { not_null=true, default="0", min_version=23 };
        public Column<long> last_active = new Column.Long("last_active");
        public Column<int> type_ = new Column.Integer("type");
        public Column<int> encryption = new Column.Integer("encryption");
        public Column<int> read_up_to = new Column.Integer("read_up_to");
        public Column<int> read_up_to_item = new Column.Integer("read_up_to_item") { not_null=true, default="-1", min_version=15 };
        public Column<int> notification = new Column.Integer("notification") { min_version=3 };
        public Column<int> send_typing = new Column.Integer("send_typing") { min_version=3 };
        public Column<int> send_marker = new Column.Integer("send_marker") { min_version=3 };
        public Column<int> pinned = new Column.Integer("pinned") { default="0", min_version=25 };
        public Column<long> history_cleared_at = new Column.Long("history_cleared_at") { default="0", min_version=32 };
        public Column<int> message_expiry_seconds = new Column.Integer("message_expiry_seconds") { default="0", min_version=34 };
        public Column<int> muc_history_days = new Column.Integer("muc_history_days") {
            default = "0", not_null = true, min_version = 56
        };
        // Stable binding for a private MUC thread. The visible full JID only
        // contains room/nick and can be reused by another occupant.
        public Column<string> muc_pm_peer_identity = new Column.Text("muc_pm_peer_identity") { min_version=46 };

        internal ConversationTable(Database db) {
            base(db, "conversation");
            init({id, account_id, jid_id, resource, active, active_last_changed, last_active, type_, encryption, read_up_to, read_up_to_item, notification, send_typing, send_marker, pinned, history_cleared_at, message_expiry_seconds, muc_history_days, muc_pm_peer_identity});
            int groupchat_pm_type = (int) Conversation.Type.GROUPCHAT_PM;
            add_post_statement(@"CREATE UNIQUE INDEX IF NOT EXISTS conversation_identity_idx ON conversation (account_id, jid_id, type, CASE WHEN type = $groupchat_pm_type THEN COALESCE(resource, '') ELSE '' END)");
        }
    }

    public class AvatarTable : Table {
        public Column<int> jid_id = new Column.Integer("jid_id");
        public Column<int> account_id = new Column.Integer("account_id");
        public Column<string> hash = new Column.Text("hash");
        public Column<int> type_ = new Column.Integer("type");

        internal AvatarTable(Database db) {
            base(db, "contact_avatar");
            init({jid_id, account_id, hash, type_});
            unique({jid_id, account_id, type_}, "REPLACE");
        }
    }

    public class EntityIdentityTable : Table {
        public Column<string> entity = new Column.Text("entity");
        public Column<string> category = new Column.Text("category");
        public Column<string> type = new Column.Text("type");
        public Column<string> entity_name = new Column.Text("name");

        internal EntityIdentityTable(Database db) {
            base(db, "entity_identity");
            init({entity, category, entity_name, type});
            unique({entity, category, type}, "IGNORE");
            index("entity_identity_idx", {entity});
        }
    }

    public class EntityFeatureTable : Table {
        public Column<string> entity = new Column.Text("entity");
        public Column<string> feature = new Column.Text("feature");

        internal EntityFeatureTable(Database db) {
            base(db, "entity_feature");
            init({entity, feature});
            unique({entity, feature}, "IGNORE");
            index("entity_feature_idx", {entity});
        }
    }

    public class RosterTable : Table {
        public Column<int> account_id = new Column.Integer("account_id");
        public Column<string> jid = new Column.Text("jid");
        public Column<string> handle = new Column.Text("name");
        public Column<string> subscription = new Column.Text("subscription");
        public Column<string> ask = new Column.Text("ask") { min_version=29 };
        public Column<string> groups = new Column.Text("groups") { min_version=44 };

        internal RosterTable(Database db) {
            base(db, "roster");
            init({account_id, jid, handle, subscription, ask, groups});
            unique({account_id, jid}, "IGNORE");
        }
    }

    public class MamCatchupTable : Table {
        public Column<int> id = new Column.Integer("id") { primary_key = true, auto_increment = true };
        public Column<int> account_id = new Column.Integer("account_id") { not_null = true };
        public Column<string> server_jid = new Column.Text("server_jid") { not_null = true };
        public Column<string> from_id = new Column.Text("from_id") { not_null = true };
        public Column<long> from_time = new Column.Long("from_time") { not_null = true };
        public Column<bool> from_end = new Column.BoolInt("from_end") { not_null = true };
        public Column<string> to_id = new Column.Text("to_id") { not_null = true };
        public Column<long> to_time = new Column.Long("to_time") { not_null = true };

        internal MamCatchupTable(Database db) {
            base(db, "mam_catchup");
            init({id, account_id, server_jid, from_end, from_id, from_time, to_id, to_time});
        }
    }

    public class ReactionTable : Table {
        public Column<int> id = new Column.Integer("id") { primary_key = true, auto_increment = true };
        public Column<int> account_id = new Column.Integer("account_id") { not_null = true };
        public Column<int> occupant_id = new Column.Integer("occupant_id");
        public Column<int> content_item_id = new Column.Integer("content_item_id") { not_null = true };
        public Column<long> time = new Column.Long("time") { not_null = true };
        public Column<int> jid_id = new Column.Integer("jid_id");
        public Column<string> emojis = new Column.Text("emojis");

        internal ReactionTable(Database db) {
            base(db, "reaction");
            init({id, account_id, occupant_id, content_item_id, time, jid_id, emojis});
            unique({account_id, content_item_id, jid_id}, "REPLACE");
            unique({account_id, content_item_id, occupant_id}, "REPLACE");
        }
    }

    /** Latest XEP-0333 groupchat displayed pointer per verified reader. */
    public class MucDisplayedStateTable : Table {
        public Column<int> id = new Column.Integer("id") {
            primary_key = true, auto_increment = true
        };
        public Column<int> conversation_id = new Column.Integer(
            "conversation_id") { not_null = true };
        public Column<int> reader_jid_id = new Column.Integer(
            "reader_jid_id") { not_null = true };
        public Column<int> target_message_id = new Column.Integer(
            "target_message_id") { not_null = true };

        internal MucDisplayedStateTable(Database db) {
            base(db, "muc_displayed_state");
            init({id, conversation_id, reader_jid_id, target_message_id});
            unique({conversation_id, reader_jid_id}, "REPLACE");
            index("muc_displayed_state_target_idx", {target_message_id});
        }
    }

    public class SettingsTable : Table {
        public Column<int> id = new Column.Integer("id") { primary_key = true, auto_increment = true };
        public Column<string> key = new Column.Text("key") { unique = true, not_null = true };
        public Column<string> value = new Column.Text("value");

        internal SettingsTable(Database db) {
            base(db, "settings");
            init({id, key, value});
        }
    }

    public class AccountSettingsTable : Table {
        public Column<int> id = new Column.Integer("id") { primary_key = true, auto_increment = true };
        public Column<int> account_id = new Column.Integer("account_id") { not_null = true };
        public Column<string> key = new Column.Text("key") { not_null = true };
        public Column<string> value = new Column.Text("value");

        internal AccountSettingsTable(Database db) {
            base(db, "account_settings");
            init({id, account_id, key, value});
            unique({account_id, key}, "REPLACE");
        }

        public string? get_value(int account_id, string key) {
            var row_opt = select({value})
                .with(this.account_id, "=", account_id)
                .with(this.key, "=", key)
                .single()
                .row();
            if (row_opt.is_present()) return row_opt[value];
            return null;
        }
    }

    public class ConversationSettingsTable : Table {
        public Column<int> id = new Column.Integer("id") { primary_key = true, auto_increment = true };
        public Column<int> conversation_id = new Column.Integer("conversation_id") {not_null=true};
        public Column<string> key = new Column.Text("key") { not_null=true };
        public Column<string> value = new Column.Text("value");

        internal ConversationSettingsTable(Database db) {
            base(db, "conversation_settings");
            init({id, conversation_id, key, value});
            index("settings_conversationid_key", { conversation_id, key }, true);
        }

        public string? get_value(int conversation_id, string key) {
            var row_opt = select({value})
                .with(this.conversation_id, "=", conversation_id)
                .with(this.key, "=", key)
                .single()
                .row();
            if (row_opt.is_present()) return row_opt[value];
            return null;
        }
    }

    public class PinnedCertificateTable : Table {
        public Column<int> id = new Column.Integer("id") { primary_key = true, auto_increment = true };
        public Column<string> domain = new Column.Text("domain") { not_null = true };
        public Column<string> fingerprint_sha256 = new Column.Text("fingerprint_sha256") { not_null = true };
        public Column<string> issuer = new Column.Text("issuer");
        public Column<long> not_valid_before = new Column.Long("not_valid_before");
        public Column<long> not_valid_after = new Column.Long("not_valid_after");
        public Column<long> pinned_at = new Column.Long("pinned_at") { not_null = true };
        public Column<int> tls_flags = new Column.Integer("tls_flags");

        internal PinnedCertificateTable(Database db) {
            base(db, "pinned_certificate");
            init({id, domain, fingerprint_sha256, issuer, not_valid_before, not_valid_after, pinned_at, tls_flags});
            unique({domain}, "REPLACE");
        }

        public bool is_pinned(string domain, string fingerprint) {
            var row_opt = select({fingerprint_sha256})
                .with(this.domain, "=", domain)
                .with(this.fingerprint_sha256, "=", fingerprint)
                .single()
                .row();
            return row_opt.is_present();
        }

        public string? get_pinned_fingerprint(string domain) {
            var row_opt = select({fingerprint_sha256})
                .with(this.domain, "=", domain)
                .single()
                .row();
            if (row_opt.is_present()) return row_opt[fingerprint_sha256];
            return null;
        }
    }

    public AccountTable account { get; private set; }
    public JidTable jid { get; private set; }
    public EntityTable entity { get; private set; }
    public ContentItemTable content_item { get; private set; }
    public MessageTable message { get; private set; }
    public MessageOccupantId message_occupant_id { get; private set; }
    public BodyMeta body_meta { get; private set; }
    public ReplyTable reply { get; private set; }
    public MessageCorrectionTable message_correction { get; private set; }
    public RealJidTable real_jid { get; private set; }
    public OccupantIdTable occupantid { get; private set; }
    public FileTransferTable file_transfer { get; private set; }
    public FileHashesTable file_hashes { get; private set; }
    public FileThumbnailsTable file_thumbnails { get; private set; }
    public SourcesTable sfs_sources { get; private set; }
    public CallTable call { get; private set; }
    public CallCounterpartTable call_counterpart { get; private set; }
    internal CallJmiSidTable call_jmi_sid { get; private set; }
    internal CallJmiProposalTable call_jmi_proposal { get; private set; }
    public ConversationTable conversation { get; private set; }
    public AvatarTable avatar { get; private set; }
    public EntityIdentityTable entity_identity { get; private set; }
    public EntityFeatureTable entity_feature { get; private set; }
    public RosterTable roster { get; private set; }
    public MamCatchupTable mam_catchup { get; private set; }
    public ReactionTable reaction { get; private set; }
    public MucDisplayedStateTable muc_displayed_state { get; private set; }
    public SettingsTable settings { get; private set; }
    public AccountSettingsTable account_settings { get; private set; }
    public ConversationSettingsTable conversation_settings { get; private set; }
    public PinnedCertificateTable pinned_certificate { get; private set; }
    public StickerPackTable sticker_pack { get; private set; }
    public StickerItemTable sticker_item { get; private set; }
    public Feeds.SubscriptionTable feed_subscription { get; private set; }
    public Feeds.SeenTable feed_seen { get; private set; }

    public Map<int, Jid> jid_table_cache = new HashMap<int, Jid>();
    public Map<Jid, int> jid_table_reverse = new HashMap<Jid, int>(Jid.hash_func, Jid.equals_func);
    public Map<int, Account> account_table_cache = new HashMap<int, Account>();

    public Database(string fileName, string key) throws Error {
        base(fileName, VERSION);
        account = new AccountTable(this);
        jid = new JidTable(this);
        entity = new EntityTable(this);
        content_item = new ContentItemTable(this);
        message = new MessageTable(this);
        message_occupant_id = new MessageOccupantId(this);
        body_meta = new BodyMeta(this);
        message_correction = new MessageCorrectionTable(this);
        reply = new ReplyTable(this);
        occupantid = new OccupantIdTable(this);
        real_jid = new RealJidTable(this);
        file_transfer = new FileTransferTable(this);
        file_hashes = new FileHashesTable(this);
        file_thumbnails = new FileThumbnailsTable(this);
        sfs_sources = new SourcesTable(this);
        call = new CallTable(this);
        call_counterpart = new CallCounterpartTable(this);
        call_jmi_sid = new CallJmiSidTable(this);
        call_jmi_proposal = new CallJmiProposalTable(this);
        conversation = new ConversationTable(this);
        avatar = new AvatarTable(this);
        entity_identity = new EntityIdentityTable(this);
        entity_feature = new EntityFeatureTable(this);
        roster = new RosterTable(this);
        mam_catchup = new MamCatchupTable(this);
        reaction = new ReactionTable(this);
        muc_displayed_state = new MucDisplayedStateTable(this);
        settings = new SettingsTable(this);
        account_settings = new AccountSettingsTable(this);
        conversation_settings = new ConversationSettingsTable(this);
        pinned_certificate = new PinnedCertificateTable(this);
        sticker_pack = new StickerPackTable(this);
        sticker_item = new StickerItemTable(this);
        feed_subscription = new Feeds.SubscriptionTable(this);
        feed_seen = new Feeds.SeenTable(this);
        init({ account, jid, entity, content_item, message, message_occupant_id, body_meta, message_correction, reply, real_jid, occupantid, file_transfer, file_hashes, file_thumbnails, sfs_sources, call, call_counterpart, call_jmi_sid, call_jmi_proposal, conversation, avatar, entity_identity, entity_feature, roster, mam_catchup, reaction, muc_displayed_state, settings, account_settings, conversation_settings, pinned_certificate, sticker_pack, sticker_item, feed_subscription, feed_seen }, key, false);

        try {
            // WAL + synchronous already set in qlite before migration; re-assert here for clarity
            exec("PRAGMA journal_mode = WAL");
            exec("PRAGMA synchronous = NORMAL");
            exec("PRAGMA secure_delete = ON");
        } catch (Error e) {
            error("Failed to set database properties: %s", e.message);
        }

        cleanup_orphaned_content_items();
        cleanup_orphaned_muc_displayed_states();
        if (HistoryDiagnostics.enabled()) {
            HistoryDiagnostics.write("event=database-open schema=%d".printf(VERSION));
        }
    }

    private void cleanup_orphaned_muc_displayed_states() {
        try {
            exec("DELETE FROM muc_displayed_state WHERE conversation_id NOT IN (SELECT id FROM conversation) OR target_message_id NOT IN (SELECT id FROM message)");
        } catch (Error e) {
            warning("Failed to clean up orphaned MUC displayed states: %s",
                e.message);
        }
    }

    internal void cleanup_orphaned_content_items() {
        try {
            exec("""
                DELETE FROM content_item WHERE
                    (content_type = 1 AND foreign_id NOT IN (SELECT id FROM message)) OR
                    (content_type = 2 AND foreign_id NOT IN (SELECT id FROM file_transfer)) OR
                    (content_type = 3 AND foreign_id NOT IN (SELECT id FROM call)) OR
                    content_type NOT IN (1, 2, 3)
            """);
        } catch (Error e) {
            warning("Failed to clean up orphaned content items: %s", e.message);
        }

        try {
            exec("UPDATE conversation SET read_up_to_item = -1 WHERE read_up_to_item > 0 AND read_up_to_item NOT IN (SELECT id FROM content_item)");
        } catch (Error e) {
            warning("Failed to fix dangling read_up_to_item: %s", e.message);
        }
    }

    public override void migrate(long oldVersion) {
        if (HistoryDiagnostics.enabled()) {
            HistoryDiagnostics.write("event=database-migration old_schema=%s target_schema=%d".printf(
                oldVersion.to_string(), VERSION));
        }
        // new table columns are added, outdated columns are still present
        if (oldVersion < 7) {
            message.fts_rebuild();
        }
        if (oldVersion < 8) {
            try {
                exec("""
                insert into content_item (conversation_id, time, local_time, content_type, foreign_id, hide)
                select conversation.id, message.time, message.local_time, 1, message.id, 0
                from message join conversation on
                    message.account_id=conversation.account_id and
                    message.counterpart_id=conversation.jid_id and
                    message.type=conversation.type+1 and
                    (message.counterpart_resource=conversation.resource or message.type != 3)
                where
                    message.body not in (select info from file_transfer where info not null) and
                    message.id not in (select info from file_transfer where info not null)
                union
                select conversation.id, message.time, message.local_time, 2, file_transfer.id, 0
                from file_transfer
                join message on
                    file_transfer.info=message.id
                join conversation on
                    file_transfer.account_id=conversation.account_id and
                    file_transfer.counterpart_id=conversation.jid_id and
                    message.type=conversation.type+1 and
                    (message.counterpart_resource=conversation.resource or message.type != 3)""");
            } catch (Error e) {
                error("Failed to upgrade to database version 8: %s", e.message);
            }
        }
        if (oldVersion < 9) {
            try {
                exec("""
                insert into content_item (conversation_id, time, local_time, content_type, foreign_id, hide)
                select conversation.id, message.time, message.local_time, 1, message.id, 1
                from message join conversation on
                    message.account_id=conversation.account_id and
                    message.counterpart_id=conversation.jid_id and
                    message.type=conversation.type+1 and
                    (message.counterpart_resource=conversation.resource or message.type != 3)
                where
                    message.body in (select info from file_transfer where info not null) or
                    message.id in (select info from file_transfer where info not null)""");
            } catch (Error e) {
                error("Failed to upgrade to database version 9: %s", e.message);
            }
        }
        if (oldVersion < 11) {
            try {
                exec("""
                insert into mam_catchup (account_id, from_end, from_time, to_time)
                select id, 1, 0, mam_earliest_synced from account where mam_earliest_synced not null and mam_earliest_synced > 0""");
            } catch (Error e) {
                error("Failed to upgrade to database version 11: %s", e.message);
            }
        }
        if (oldVersion < 12) {
            try {
                exec("delete from avatar");
            } catch (Error e) {
                error("Failed to upgrade to database version 12: %s", e.message);
            }
        }
        if (oldVersion < 15) {
            // Initialize `conversation.read_up_to_item` with the content item id corresponding to the `read_up_to` message.
            try {
                exec("update conversation set read_up_to_item=ifnull((select content_item.id from content_item where content_item.foreign_id=conversation.read_up_to and content_type=1), -1);");
            } catch (Error e) {
                error("Failed to upgrade to database version 15: %s", e.message);
            }
        }
        if (oldVersion < 16) {
            try {
                exec("DROP TABLE contact_avatar");
                avatar.create_table_at_version(VERSION);
            } catch (Error e) {
                error("Failed to upgrade to database version 16: %s", e.message);
            }
        }
        if (oldVersion < 17) {
            try {
                exec("DROP INDEX IF EXISTS contentitem_localtime_counterpart_idx");
                exec("CREATE INDEX IF NOT EXISTS contentitem_conversation_hide_localtime_time_idx ON content_item (conversation_id, hide, local_time, time)");
            } catch (Error e) {
                error("Failed to upgrade to database version 17: %s", e.message);
            }
        }
        if (oldVersion < 18) {
            try {
                exec("DROP INDEX IF EXISTS contentitem_conversation_hide_localtime_time_idx");
                exec("CREATE INDEX IF NOT EXISTS contentitem_conversation_hide_time_idx ON content_item (conversation_id, hide, time)");

                exec("DROP INDEX IF EXISTS message_account_counterpart_localtime_idx");
                exec("CREATE INDEX IF NOT EXISTS message_account_counterpart_time_idx ON message (account_id, counterpart_id, time)");

                exec("DROP INDEX IF EXISTS filetransfer_localtime_counterpart_idx");
            } catch (Error e) {
                error("Failed to upgrade to database version 18: %s", e.message);
            }
        }
        if (oldVersion < 22) {
            try {
                exec("INSERT INTO call_counterpart (call_id, jid_id, resource) SELECT id, counterpart_id, counterpart_resource FROM call");
            } catch (Error e) {
                error("Failed to upgrade to database version 22: %s", e.message);
            }
//                exec("ALTER TABLE call RENAME TO call2");
//                call.create_table_at_version(VERSION);
//                exec("INSERT INTO call (id, account_id, our_resource, direction, time, local_time, end_time, encryption, state)
//                            SELECT id, account_id, our_resource, direction, time, local_time, end_time, encryption, state
//                            FROM call2");
//                exec("DROP TABLE call2");
        }
        if (oldVersion < 23) {
            try {
                exec("ALTER TABLE mam_catchup RENAME TO mam_catchup2");
                mam_catchup.create_table_at_version(VERSION);
                exec("""INSERT INTO mam_catchup (id, account_id, server_jid, from_id, from_time, from_end, to_id, to_time)
                                SELECT mam_catchup2.id, account_id, bare_jid, ifnull(from_id, ""), from_time, ifnull(from_end, 0), ifnull(to_id, ""), to_time
                                FROM mam_catchup2 JOIN account ON mam_catchup2.account_id=account.id""");
                exec("DROP TABLE mam_catchup2");
            } catch (Error e) {
                error("Failed to upgrade to database version 23 (mam_catchup): %s", e.message);
            }

            try {
                long active_last_updated = (long) new DateTime.now_utc().to_unix();
                exec(@"UPDATE conversation SET active_last_changed=$active_last_updated WHERE active_last_changed=0");
            } catch (Error e) {
                error("Failed to upgrade to database version 23 (conversation): %s", e.message);
            }
        }
        if (oldVersion < 38) {
            // B1: Remove duplicate conversations — keep the one with the lower id
            try {
                exec("""DELETE FROM conversation WHERE id NOT IN (
                    SELECT MIN(id) FROM conversation GROUP BY account_id, jid_id, type)""");
            } catch (Error e) {
                warning("Failed to clean up duplicate conversations: %s", e.message);
            }

            // B1: Add UNIQUE constraint on (account_id, jid_id, type)
            try {
                exec("CREATE UNIQUE INDEX IF NOT EXISTS conversation_account_jid_type_idx ON conversation (account_id, jid_id, type)");
            } catch (Error e) {
                warning("Failed to create unique conversation index: %s", e.message);
            }

            // O2: Add missing file_transfer indexes
            try {
                exec("CREATE INDEX IF NOT EXISTS file_transfer_account_counterpart_idx ON file_transfer (account_id, counterpart_id)");
            } catch (Error e) {
                warning("Failed to create file_transfer index: %s", e.message);
            }

            // B2: Clean up orphaned messages (messages without content_items that have empty or url-only bodies)
            try {
                exec("""DELETE FROM message WHERE id NOT IN (
                    SELECT foreign_id FROM content_item WHERE content_type = 1)
                    AND body IS NOT NULL AND (body = '' OR body LIKE 'aesgcm://%')""");
            } catch (Error e) {
                warning("Failed to clean up orphaned messages: %s", e.message);
            }

            // B3: Clean up orphaned real_jid entries referencing deleted messages
            try {
                exec("DELETE FROM real_jid WHERE message_id NOT IN (SELECT id FROM message)");
            } catch (Error e) {
                warning("Failed to clean up orphaned real_jid entries: %s", e.message);
            }
        }
        if (oldVersion < 39) {
            // O3: Migrate FTS4 → FTS5 for message full-text search (only if FTS5 available)
            if (fts5_available) {
                try {
                    // Drop old FTS4 virtual table and triggers
                    exec("DROP TABLE IF EXISTS _fts_message");
                    exec("DROP TRIGGER IF EXISTS _fts_bu_message");
                    exec("DROP TRIGGER IF EXISTS _fts_bd_message");
                    exec("DROP TRIGGER IF EXISTS _fts_au_message");
                    exec("DROP TRIGGER IF EXISTS _fts_ai_message");

                    // Create new FTS5 virtual table
                    exec("CREATE VIRTUAL TABLE IF NOT EXISTS _fts_message USING fts5(body, content='message', content_rowid='rowid', tokenize='unicode61')");

                    // Create FTS5 content-sync triggers
                    exec("CREATE TRIGGER IF NOT EXISTS _fts_bu_message BEFORE UPDATE ON message BEGIN INSERT INTO _fts_message(_fts_message, rowid, body) VALUES('delete', old.rowid, old.body); END");
                    exec("CREATE TRIGGER IF NOT EXISTS _fts_bd_message BEFORE DELETE ON message BEGIN INSERT INTO _fts_message(_fts_message, rowid, body) VALUES('delete', old.rowid, old.body); END");
                    exec("CREATE TRIGGER IF NOT EXISTS _fts_au_message AFTER UPDATE ON message BEGIN INSERT INTO _fts_message(rowid, body) VALUES(new.rowid, new.body); END");
                    exec("CREATE TRIGGER IF NOT EXISTS _fts_ai_message AFTER INSERT ON message BEGIN INSERT INTO _fts_message(rowid, body) VALUES(new.rowid, new.body); END");

                    // Rebuild FTS5 index from existing messages
                    exec("INSERT INTO _fts_message(_fts_message) VALUES('rebuild')");

                    print("Database: Migrated FTS4 → FTS5 for message search.\n");
                } catch (Error e) {
                    warning("Failed to migrate FTS4 → FTS5: %s", e.message);
                }
            } else {
                // FTS5 not available — keep FTS4, just rebuild index
                message.fts_rebuild();
            }
        }
        if (oldVersion < 40) {
            // B4: Clean up orphaned content_items referencing non-existent messages
            // This can happen when messages are deleted but content_items remain
            // (e.g. from the old persist()/last_insert_rowid() bug)
            try {
                exec("DELETE FROM content_item WHERE content_type = 1 AND foreign_id NOT IN (SELECT id FROM message)");
            } catch (Error e) {
                warning("Failed to clean up orphaned content_items: %s", e.message);
            }

            // B5: Fix conversation read_up_to_item pointing to deleted content_items
            try {
                exec("UPDATE conversation SET read_up_to_item = -1 WHERE read_up_to_item > 0 AND read_up_to_item NOT IN (SELECT id FROM content_item)");
            } catch (Error e) {
                warning("Failed to fix dangling read_up_to_item: %s", e.message);
            }

            // B6: Fix conversation read_up_to pointing to deleted messages
            try {
                exec("UPDATE conversation SET read_up_to = NULL WHERE read_up_to IS NOT NULL AND read_up_to NOT IN (SELECT id FROM message)");
            } catch (Error e) {
                warning("Failed to fix dangling read_up_to: %s", e.message);
            }
        }
        if (oldVersion < 43) {
            try {
                exec("DROP TABLE IF EXISTS tmp_groupchat_conversation_canonical");
                exec("DROP TABLE IF EXISTS tmp_groupchat_conversation_survivor");
                exec("""
                    INSERT OR IGNORE INTO jid (bare_jid)
                    SELECT DISTINCT CASE
                        WHEN instr(jid.bare_jid, '/') > 0 THEN substr(jid.bare_jid, 1, instr(jid.bare_jid, '/') - 1)
                        ELSE jid.bare_jid
                    END
                    FROM conversation
                    JOIN jid ON conversation.jid_id = jid.id
                    WHERE conversation.type = 1
                """);
                exec("""
                    CREATE TEMP TABLE tmp_groupchat_conversation_canonical AS
                    SELECT
                        conversation.id AS conversation_id,
                        conversation.account_id AS account_id,
                        canonical_jid.id AS canonical_jid_id
                    FROM conversation
                    JOIN jid AS stored_jid ON conversation.jid_id = stored_jid.id
                    JOIN jid AS canonical_jid ON canonical_jid.bare_jid = CASE
                        WHEN instr(stored_jid.bare_jid, '/') > 0 THEN substr(stored_jid.bare_jid, 1, instr(stored_jid.bare_jid, '/') - 1)
                        ELSE stored_jid.bare_jid
                    END
                    WHERE conversation.type = 1
                """);
                exec("""
                    CREATE TEMP TABLE tmp_groupchat_conversation_survivor AS
                    SELECT
                        account_id,
                        canonical_jid_id,
                        MIN(conversation_id) AS survivor_id
                    FROM tmp_groupchat_conversation_canonical
                    GROUP BY account_id, canonical_jid_id
                """);
                exec("""
                    UPDATE conversation
                    SET
                        active = (
                            SELECT MAX(duplicate.active)
                            FROM conversation AS duplicate
                            JOIN tmp_groupchat_conversation_canonical AS duplicate_canonical ON duplicate.id = duplicate_canonical.conversation_id
                            JOIN tmp_groupchat_conversation_survivor AS survivor ON survivor.account_id = duplicate_canonical.account_id
                                AND survivor.canonical_jid_id = duplicate_canonical.canonical_jid_id
                            WHERE survivor.survivor_id = conversation.id
                        ),
                        active_last_changed = (
                            SELECT MAX(duplicate.active_last_changed)
                            FROM conversation AS duplicate
                            JOIN tmp_groupchat_conversation_canonical AS duplicate_canonical ON duplicate.id = duplicate_canonical.conversation_id
                            JOIN tmp_groupchat_conversation_survivor AS survivor ON survivor.account_id = duplicate_canonical.account_id
                                AND survivor.canonical_jid_id = duplicate_canonical.canonical_jid_id
                            WHERE survivor.survivor_id = conversation.id
                        ),
                        last_active = NULLIF((
                            SELECT MAX(IFNULL(duplicate.last_active, 0))
                            FROM conversation AS duplicate
                            JOIN tmp_groupchat_conversation_canonical AS duplicate_canonical ON duplicate.id = duplicate_canonical.conversation_id
                            JOIN tmp_groupchat_conversation_survivor AS survivor ON survivor.account_id = duplicate_canonical.account_id
                                AND survivor.canonical_jid_id = duplicate_canonical.canonical_jid_id
                            WHERE survivor.survivor_id = conversation.id
                        ), 0),
                        resource = COALESCE((
                            SELECT duplicate.resource
                            FROM conversation AS duplicate
                            JOIN tmp_groupchat_conversation_canonical AS duplicate_canonical ON duplicate.id = duplicate_canonical.conversation_id
                            JOIN tmp_groupchat_conversation_survivor AS survivor ON survivor.account_id = duplicate_canonical.account_id
                                AND survivor.canonical_jid_id = duplicate_canonical.canonical_jid_id
                            WHERE survivor.survivor_id = conversation.id
                                AND duplicate.resource IS NOT NULL
                                AND duplicate.resource != ''
                            ORDER BY duplicate.active DESC, IFNULL(duplicate.last_active, 0) DESC, duplicate.active_last_changed DESC, duplicate.id ASC
                            LIMIT 1
                        ), conversation.resource),
                        encryption = COALESCE((
                            SELECT duplicate.encryption
                            FROM conversation AS duplicate
                            JOIN tmp_groupchat_conversation_canonical AS duplicate_canonical ON duplicate.id = duplicate_canonical.conversation_id
                            JOIN tmp_groupchat_conversation_survivor AS survivor ON survivor.account_id = duplicate_canonical.account_id
                                AND survivor.canonical_jid_id = duplicate_canonical.canonical_jid_id
                            WHERE survivor.survivor_id = conversation.id
                                AND duplicate.encryption IS NOT NULL
                                AND duplicate.encryption != 0
                                AND duplicate.encryption != 5
                            ORDER BY duplicate.active DESC, IFNULL(duplicate.last_active, 0) DESC, duplicate.active_last_changed DESC, duplicate.id ASC
                            LIMIT 1
                        ), conversation.encryption),
                        read_up_to = COALESCE((
                            SELECT duplicate.read_up_to
                            FROM conversation AS duplicate
                            JOIN tmp_groupchat_conversation_canonical AS duplicate_canonical ON duplicate.id = duplicate_canonical.conversation_id
                            JOIN tmp_groupchat_conversation_survivor AS survivor ON survivor.account_id = duplicate_canonical.account_id
                                AND survivor.canonical_jid_id = duplicate_canonical.canonical_jid_id
                            WHERE survivor.survivor_id = conversation.id
                                AND duplicate.read_up_to IS NOT NULL
                            ORDER BY duplicate.active DESC, IFNULL(duplicate.last_active, 0) DESC, duplicate.active_last_changed DESC, duplicate.id ASC
                            LIMIT 1
                        ), conversation.read_up_to),
                        read_up_to_item = (
                            SELECT MAX(duplicate.read_up_to_item)
                            FROM conversation AS duplicate
                            JOIN tmp_groupchat_conversation_canonical AS duplicate_canonical ON duplicate.id = duplicate_canonical.conversation_id
                            JOIN tmp_groupchat_conversation_survivor AS survivor ON survivor.account_id = duplicate_canonical.account_id
                                AND survivor.canonical_jid_id = duplicate_canonical.canonical_jid_id
                            WHERE survivor.survivor_id = conversation.id
                        ),
                        notification = COALESCE((
                            SELECT duplicate.notification
                            FROM conversation AS duplicate
                            JOIN tmp_groupchat_conversation_canonical AS duplicate_canonical ON duplicate.id = duplicate_canonical.conversation_id
                            JOIN tmp_groupchat_conversation_survivor AS survivor ON survivor.account_id = duplicate_canonical.account_id
                                AND survivor.canonical_jid_id = duplicate_canonical.canonical_jid_id
                            WHERE survivor.survivor_id = conversation.id
                                AND duplicate.notification IS NOT NULL
                            ORDER BY CASE WHEN duplicate.notification != 0 THEN 0 ELSE 1 END, duplicate.active DESC, IFNULL(duplicate.last_active, 0) DESC, duplicate.active_last_changed DESC, duplicate.id ASC
                            LIMIT 1
                        ), conversation.notification),
                        send_typing = COALESCE((
                            SELECT duplicate.send_typing
                            FROM conversation AS duplicate
                            JOIN tmp_groupchat_conversation_canonical AS duplicate_canonical ON duplicate.id = duplicate_canonical.conversation_id
                            JOIN tmp_groupchat_conversation_survivor AS survivor ON survivor.account_id = duplicate_canonical.account_id
                                AND survivor.canonical_jid_id = duplicate_canonical.canonical_jid_id
                            WHERE survivor.survivor_id = conversation.id
                                AND duplicate.send_typing IS NOT NULL
                            ORDER BY CASE WHEN duplicate.send_typing != 0 THEN 0 ELSE 1 END, duplicate.active DESC, IFNULL(duplicate.last_active, 0) DESC, duplicate.active_last_changed DESC, duplicate.id ASC
                            LIMIT 1
                        ), conversation.send_typing),
                        send_marker = COALESCE((
                            SELECT duplicate.send_marker
                            FROM conversation AS duplicate
                            JOIN tmp_groupchat_conversation_canonical AS duplicate_canonical ON duplicate.id = duplicate_canonical.conversation_id
                            JOIN tmp_groupchat_conversation_survivor AS survivor ON survivor.account_id = duplicate_canonical.account_id
                                AND survivor.canonical_jid_id = duplicate_canonical.canonical_jid_id
                            WHERE survivor.survivor_id = conversation.id
                                AND duplicate.send_marker IS NOT NULL
                            ORDER BY CASE WHEN duplicate.send_marker != 0 THEN 0 ELSE 1 END, duplicate.active DESC, IFNULL(duplicate.last_active, 0) DESC, duplicate.active_last_changed DESC, duplicate.id ASC
                            LIMIT 1
                        ), conversation.send_marker),
                        pinned = (
                            SELECT MAX(duplicate.pinned)
                            FROM conversation AS duplicate
                            JOIN tmp_groupchat_conversation_canonical AS duplicate_canonical ON duplicate.id = duplicate_canonical.conversation_id
                            JOIN tmp_groupchat_conversation_survivor AS survivor ON survivor.account_id = duplicate_canonical.account_id
                                AND survivor.canonical_jid_id = duplicate_canonical.canonical_jid_id
                            WHERE survivor.survivor_id = conversation.id
                        ),
                        history_cleared_at = (
                            SELECT MAX(duplicate.history_cleared_at)
                            FROM conversation AS duplicate
                            JOIN tmp_groupchat_conversation_canonical AS duplicate_canonical ON duplicate.id = duplicate_canonical.conversation_id
                            JOIN tmp_groupchat_conversation_survivor AS survivor ON survivor.account_id = duplicate_canonical.account_id
                                AND survivor.canonical_jid_id = duplicate_canonical.canonical_jid_id
                            WHERE survivor.survivor_id = conversation.id
                        ),
                        message_expiry_seconds = (
                            SELECT MAX(duplicate.message_expiry_seconds)
                            FROM conversation AS duplicate
                            JOIN tmp_groupchat_conversation_canonical AS duplicate_canonical ON duplicate.id = duplicate_canonical.conversation_id
                            JOIN tmp_groupchat_conversation_survivor AS survivor ON survivor.account_id = duplicate_canonical.account_id
                                AND survivor.canonical_jid_id = duplicate_canonical.canonical_jid_id
                            WHERE survivor.survivor_id = conversation.id
                        )
                    WHERE id IN (SELECT survivor_id FROM tmp_groupchat_conversation_survivor)
                """);
                exec("""
                    UPDATE content_item
                    SET conversation_id = (
                        SELECT survivor.survivor_id
                        FROM tmp_groupchat_conversation_canonical AS duplicate_canonical
                        JOIN tmp_groupchat_conversation_survivor AS survivor ON survivor.account_id = duplicate_canonical.account_id
                            AND survivor.canonical_jid_id = duplicate_canonical.canonical_jid_id
                        WHERE duplicate_canonical.conversation_id = content_item.conversation_id
                    )
                    WHERE conversation_id IN (
                        SELECT duplicate_canonical.conversation_id
                        FROM tmp_groupchat_conversation_canonical AS duplicate_canonical
                        JOIN tmp_groupchat_conversation_survivor AS survivor ON survivor.account_id = duplicate_canonical.account_id
                            AND survivor.canonical_jid_id = duplicate_canonical.canonical_jid_id
                        WHERE duplicate_canonical.conversation_id != survivor.survivor_id
                    )
                """);
                exec("""
                    DELETE FROM conversation_settings
                    WHERE conversation_id IN (
                        SELECT duplicate_canonical.conversation_id
                        FROM tmp_groupchat_conversation_canonical AS duplicate_canonical
                        JOIN tmp_groupchat_conversation_survivor AS survivor ON survivor.account_id = duplicate_canonical.account_id
                            AND survivor.canonical_jid_id = duplicate_canonical.canonical_jid_id
                        WHERE duplicate_canonical.conversation_id != survivor.survivor_id
                    )
                    AND EXISTS (
                        SELECT 1
                        FROM tmp_groupchat_conversation_canonical AS duplicate_canonical
                        JOIN tmp_groupchat_conversation_survivor AS survivor ON survivor.account_id = duplicate_canonical.account_id
                            AND survivor.canonical_jid_id = duplicate_canonical.canonical_jid_id
                        JOIN conversation_settings AS survivor_setting ON survivor_setting.conversation_id = survivor.survivor_id
                            AND survivor_setting.key = conversation_settings.key
                        WHERE duplicate_canonical.conversation_id = conversation_settings.conversation_id
                            AND duplicate_canonical.conversation_id != survivor.survivor_id
                    )
                """);
                exec("""
                    DELETE FROM conversation_settings
                    WHERE conversation_id IN (
                        SELECT duplicate_canonical.conversation_id
                        FROM tmp_groupchat_conversation_canonical AS duplicate_canonical
                        JOIN tmp_groupchat_conversation_survivor AS survivor ON survivor.account_id = duplicate_canonical.account_id
                            AND survivor.canonical_jid_id = duplicate_canonical.canonical_jid_id
                        WHERE duplicate_canonical.conversation_id != survivor.survivor_id
                    )
                    AND id NOT IN (
                        SELECT MIN(duplicate_setting.id)
                        FROM conversation_settings AS duplicate_setting
                        JOIN tmp_groupchat_conversation_canonical AS duplicate_canonical ON duplicate_canonical.conversation_id = duplicate_setting.conversation_id
                        JOIN tmp_groupchat_conversation_survivor AS survivor ON survivor.account_id = duplicate_canonical.account_id
                            AND survivor.canonical_jid_id = duplicate_canonical.canonical_jid_id
                        WHERE duplicate_canonical.conversation_id != survivor.survivor_id
                        GROUP BY survivor.survivor_id, duplicate_setting.key
                    )
                """);
                exec("""
                    UPDATE conversation_settings
                    SET conversation_id = (
                        SELECT survivor.survivor_id
                        FROM tmp_groupchat_conversation_canonical AS duplicate_canonical
                        JOIN tmp_groupchat_conversation_survivor AS survivor ON survivor.account_id = duplicate_canonical.account_id
                            AND survivor.canonical_jid_id = duplicate_canonical.canonical_jid_id
                        WHERE duplicate_canonical.conversation_id = conversation_settings.conversation_id
                    )
                    WHERE conversation_id IN (
                        SELECT duplicate_canonical.conversation_id
                        FROM tmp_groupchat_conversation_canonical AS duplicate_canonical
                        JOIN tmp_groupchat_conversation_survivor AS survivor ON survivor.account_id = duplicate_canonical.account_id
                            AND survivor.canonical_jid_id = duplicate_canonical.canonical_jid_id
                        WHERE duplicate_canonical.conversation_id != survivor.survivor_id
                    )
                """);
                exec("""
                    DELETE FROM conversation
                    WHERE id IN (
                        SELECT duplicate_canonical.conversation_id
                        FROM tmp_groupchat_conversation_canonical AS duplicate_canonical
                        JOIN tmp_groupchat_conversation_survivor AS survivor ON survivor.account_id = duplicate_canonical.account_id
                            AND survivor.canonical_jid_id = duplicate_canonical.canonical_jid_id
                        WHERE duplicate_canonical.conversation_id != survivor.survivor_id
                    )
                """);
                exec("""
                    UPDATE conversation
                    SET jid_id = (
                        SELECT canonical_jid_id
                        FROM tmp_groupchat_conversation_survivor
                        WHERE survivor_id = conversation.id
                    )
                    WHERE id IN (SELECT survivor_id FROM tmp_groupchat_conversation_survivor)
                """);
                exec("DROP TABLE IF EXISTS tmp_groupchat_conversation_canonical");
                exec("DROP TABLE IF EXISTS tmp_groupchat_conversation_survivor");
            } catch (Error e) {
                error("Failed to canonicalize groupchat conversations: %s", e.message);
            }
        }
        if (oldVersion < 44) {
            try {
                exec("DELETE FROM roster");
                exec("UPDATE account SET roster_version = NULL");
            } catch (Error e) {
                error("Failed to invalidate roster cache for roster groups: %s", e.message);
            }
        }
        if (oldVersion < 45) {
            // Private MUC conversations are identified by the full occupant JID.
            // The old table-level UNIQUE constraint omitted `resource`, so PMs
            // with different occupants of the same room collided. Rebuild the
            // table to replace that immutable SQLite auto-index with an
            // expression index: bare identity for normal/group chats, full
            // identity for private MUC occupant conversations.
            try {
                exec("DROP TABLE IF EXISTS conversation_identity_v44");
                exec("ALTER TABLE conversation RENAME TO conversation_identity_v44");
                conversation.create_table_at_version(VERSION);
                exec("""
                    INSERT INTO conversation (
                        id, account_id, jid_id, resource, active,
                        active_last_changed, last_active, type, encryption,
                        read_up_to, read_up_to_item, notification, send_typing,
                        send_marker, pinned, history_cleared_at,
                        message_expiry_seconds
                    )
                    SELECT
                        id, account_id, jid_id, resource, active,
                        active_last_changed, last_active, type, encryption,
                        read_up_to, read_up_to_item, notification, send_typing,
                        send_marker, pinned, history_cleared_at,
                        message_expiry_seconds
                    FROM conversation_identity_v44
                """);
                exec("DROP TABLE conversation_identity_v44");
            } catch (Error e) {
                error("Failed to migrate private MUC conversation identities: %s", e.message);
            }
        }
        if (oldVersion < 51) {
            // `file_transfer.info` historically mixed local message IDs with
            // transport state. Provider 1 is direct Jingle and must never be
            // interpreted as a message relation. Providers 0 (HTTP) and 2
            // (SFS) used canonical decimal message IDs; HTTP additionally
            // stored `url:<URL>` for received legacy file messages.
            //
            // URL rows are linked only when the existing database proves one
            // exact candidate: same content-item conversation, account,
            // counterpart, message type, sender side, timestamp and body. A
            // duplicate or incomplete match deliberately remains at -1.
            try {
                exec("""
                    WITH relation_candidates AS (
                        SELECT
                            transfer.id AS transfer_id,
                            candidate.id AS message_id
                        FROM file_transfer AS transfer
                        JOIN content_item AS file_item
                            ON file_item.content_type = 2
                            AND file_item.foreign_id = transfer.id
                        JOIN conversation AS target_conversation
                            ON target_conversation.id = file_item.conversation_id
                        JOIN message AS candidate
                            ON candidate.id = CAST(transfer.info AS INTEGER)
                        WHERE transfer.message_id <= 0
                            AND transfer.provider IN (0, 2)
                            AND typeof(transfer.info) = 'text'
                            AND transfer.info GLOB '[1-9]*'
                            AND transfer.info NOT GLOB '*[^0-9]*'
                            AND length(transfer.info) <= 10
                            AND CAST(transfer.info AS INTEGER)
                                BETWEEN 1 AND 2147483647
                            AND printf('%d', CAST(transfer.info AS INTEGER)) =
                                transfer.info
                            AND target_conversation.account_id =
                                transfer.account_id
                            AND target_conversation.jid_id =
                                transfer.counterpart_id
                            AND candidate.account_id = transfer.account_id
                            AND candidate.counterpart_id =
                                transfer.counterpart_id
                            AND candidate.direction = transfer.direction
                            AND candidate.type =
                                target_conversation.type + 1
                            AND (candidate.type != 3 OR (
                                candidate.counterpart_resource IS
                                    target_conversation.resource
                                AND transfer.counterpart_resource IS
                                    target_conversation.resource
                            ))
                            AND (
                                (transfer.direction = 0 AND
                                    candidate.counterpart_resource IS
                                        transfer.counterpart_resource)
                                OR
                                (transfer.direction = 1 AND
                                    (candidate.type = 3 OR
                                        candidate.our_resource IS
                                            transfer.our_resource))
                            )

                        UNION ALL

                        SELECT
                            transfer.id AS transfer_id,
                            candidate.id AS message_id
                        FROM file_transfer AS transfer
                        JOIN content_item AS file_item
                            ON file_item.content_type = 2
                            AND file_item.foreign_id = transfer.id
                        JOIN conversation AS target_conversation
                            ON target_conversation.id = file_item.conversation_id
                        JOIN message AS candidate
                            ON candidate.account_id = transfer.account_id
                            AND candidate.counterpart_id =
                                transfer.counterpart_id
                            AND candidate.direction = transfer.direction
                            AND candidate.time = transfer.time
                            AND candidate.local_time = transfer.local_time
                            AND candidate.body = substr(transfer.info, 5)
                        WHERE transfer.message_id <= 0
                            AND transfer.provider = 0
                            AND (
                                transfer.info GLOB 'url:http://*'
                                OR transfer.info GLOB 'url:https://*'
                                OR transfer.info GLOB 'url:aesgcm://*'
                            )
                            AND target_conversation.account_id =
                                transfer.account_id
                            AND target_conversation.jid_id =
                                transfer.counterpart_id
                            AND candidate.type =
                                target_conversation.type + 1
                            AND (candidate.type != 3 OR (
                                candidate.counterpart_resource IS
                                    target_conversation.resource
                                AND transfer.counterpart_resource IS
                                    target_conversation.resource
                            ))
                            AND (
                                (transfer.direction = 0 AND
                                    candidate.counterpart_resource IS
                                        transfer.counterpart_resource)
                                OR
                                (transfer.direction = 1 AND
                                    (candidate.type = 3 OR
                                        candidate.our_resource IS
                                            transfer.our_resource))
                            )
                    ), unambiguous_relations AS (
                        SELECT
                            transfer_id,
                            MIN(message_id) AS message_id
                        FROM relation_candidates
                        GROUP BY transfer_id
                        HAVING COUNT(*) = 1
                    )
                    UPDATE file_transfer
                    SET message_id = (
                        SELECT unambiguous_relations.message_id
                        FROM unambiguous_relations
                        WHERE unambiguous_relations.transfer_id =
                            file_transfer.id
                    )
                    WHERE id IN (
                        SELECT transfer_id FROM unambiguous_relations
                    );

                    -- Older private-MUC sends stored the room nick as the
                    -- transfer's local resource, while the type='chat'
                    -- message correctly stored the account resource. Once an
                    -- exact relation has been proved above, normalise the
                    -- transfer so future row loads preserve the same sender.
                    UPDATE file_transfer
                    SET our_resource = (
                        SELECT candidate.our_resource
                        FROM message AS candidate
                        WHERE candidate.id = file_transfer.message_id
                    )
                    WHERE direction = 1
                        AND message_id > 0
                        AND EXISTS (
                            SELECT 1
                            FROM content_item AS file_item
                            JOIN conversation AS target_conversation
                                ON target_conversation.id =
                                    file_item.conversation_id
                            JOIN message AS candidate
                                ON candidate.id = file_transfer.message_id
                            WHERE file_item.content_type = 2
                                AND file_item.foreign_id = file_transfer.id
                                AND target_conversation.type = 2
                                AND candidate.type = 3
                                AND candidate.account_id =
                                    file_transfer.account_id
                                AND candidate.counterpart_id =
                                    file_transfer.counterpart_id
                                AND candidate.direction =
                                    file_transfer.direction
                                AND candidate.counterpart_resource IS
                                    file_transfer.counterpart_resource
                        )
                """);
            } catch (Error e) {
                error("Failed to migrate file-to-message relations: %s",
                    e.message);
            }
        }
        if (oldVersion < 55) {
            // Older MAM ranges may claim global archive exhaustion from a
            // time-filtered page, or continuity across a room leave/rejoin
            // gap. Neither condition has reliable persisted provenance.
            // Rebuild only synchronization coverage through normal bounded
            // MAM and deduplication; all local messages, keys, settings and
            // clear-history boundaries remain intact.
            try {
                exec("DELETE FROM mam_catchup");
            } catch (Error e) {
                error("Failed to invalidate legacy MAM coverage: %s",
                    e.message);
            }
        }
    }

    public ArrayList<Account> get_accounts() {
        ArrayList<Account> ret = new ArrayList<Account>(Account.equals_func);
        foreach(Row row in account.select()) {
            try {
                Account account = new Account.from_row(this, row);
                if (account_table_cache.has_key(account.id)) {
                    account = account_table_cache[account.id];
                }
                ret.add(account);
                account_table_cache[account.id] = account;
            } catch (InvalidJidError e) {
                warning("Ignoring account with invalid Jid: %s", e.message);
            }
        }
        return ret;
    }

    public Account? get_account_by_id(int id) {
        if (account_table_cache.has_key(id)) {
            return account_table_cache[id];
        } else {
            Row? row = account.row_with(account.id, id).inner;
            if (row != null) {
                try {
                    Account a = new Account.from_row(this, row);
                    account_table_cache[a.id] = a;
                    return a;
                } catch (InvalidJidError e) {
                    warning("Ignoring account with invalid Jid: %s", e.message);
                }
            }
            return null;
        }
    }

    public int add_content_item(Conversation conversation, DateTime time, DateTime local_time, int content_type, int foreign_id, bool hide) {
        return (int) content_item.insert()
            .value(content_item.conversation_id, conversation.id)
            .value(content_item.local_time, (long) local_time.to_unix())
            .value(content_item.time, (long) time.to_unix())
            .value(content_item.content_type, content_type)
            .value(content_item.foreign_id, foreign_id)
            .value(content_item.hide, hide)
            .perform();
    }

    public Gee.List<Message> get_messages(Jid jid, Account account, Message.Type? type, int count, DateTime? before, DateTime? after, int id) {
        QueryBuilder select = message.select();

        if (before != null) {
            if (id > 0) {
                select.where(@"time < ? OR (time = ? AND message.id < ?)", { before.to_unix().to_string(), before.to_unix().to_string(), id.to_string() });
            } else {
                select.with(message.time, "<", (long) before.to_unix());
            }
        }
        if (after != null) {
            if (id > 0) {
                select.where(@"time > ? OR (time = ? AND message.id > ?)", { after.to_unix().to_string(), after.to_unix().to_string(), id.to_string() });
            } else {
                select.with(message.time, ">", (long) after.to_unix());
            }
        } else {
            select.order_by(message.time, "DESC");
        }

        select.with(message.counterpart_id, "=", get_jid_id(jid))
                .with(message.account_id, "=", account.id)
                .limit(count);
        if (jid.resourcepart != null) {
            select.with(message.counterpart_resource, "=", jid.resourcepart);
        }
        if (type != null) {
            select.with(message.type_, "=", (int) type);
        }

        select.outer_join_with(real_jid, real_jid.message_id, message.id);
        select.outer_join_with(message_correction, message_correction.message_id, message.id);

        LinkedList<Message> ret = new LinkedList<Message>();
        foreach (Row row in select) {
            try {
                ret.insert(0, new Message.from_row(this, row));
            } catch (InvalidJidError e) {
                warning("Ignoring message with invalid Jid: %s", e.message);
            }
        }
        return ret;
    }

    public Message? get_message_by_id(int id) {
        Row? row = message.row_with(message.id, id).inner;
        if (row != null) {
            try {
                return new Message.from_row(this, row);
            } catch (InvalidJidError e) {
                warning("Ignoring message with invalid Jid: %s", e.message);
            }
        }
        return null;
    }

    public ArrayList<Conversation> get_conversations(Account account) {
        ArrayList<Conversation> ret = new ArrayList<Conversation>();
        foreach (Row row in conversation.select().with(conversation.account_id, "=", account.id)) {
            try {
                ret.add(new Conversation.from_row(this, row));
            } catch (InvalidJidError e) {
                warning("Ignoring conversation with invalid Jid: %s", e.message);
            }
        }
        return ret;
    }

    public int get_jid_id(Jid jid_obj) {
        var bare_jid = jid_obj.bare_jid;
        if (jid_table_reverse.has_key(bare_jid)) {
            return jid_table_reverse[bare_jid];
        } else {
            Row? row = jid.row_with(jid.bare_jid, jid_obj.bare_jid.to_string()).inner;
            if (row != null) {
                int id = row[jid.id];
                jid_table_cache[id] = bare_jid;
                jid_table_reverse[bare_jid] = id;
                return id;
            } else {
                return add_jid(jid_obj);
            }
        }
    }

    public Jid? get_jid_by_id(int id) throws InvalidJidError {
        if (jid_table_cache.has_key(id)) {
            return jid_table_cache[id];
        } else {
            string? bare_jid = jid.select({jid.bare_jid}).with(jid.id, "=", id)[jid.bare_jid];
            if (bare_jid != null) {
                Jid jid_parsed = new Jid(bare_jid);
                jid_table_cache[id] = jid_parsed;

                // Only store fully normalized Jids for reverse lookup
                if (jid_parsed.to_string() == bare_jid) {
                    jid_table_reverse[jid_parsed] = id;
                }
                return jid_parsed;
            }
            return null;
        }
    }

    private int add_jid(Jid jid_obj) {
        Jid bare_jid = jid_obj.bare_jid;
        int id = (int) jid.insert().value(jid.bare_jid, bare_jid.to_string()).perform();
        jid_table_cache[id] = bare_jid;
        jid_table_reverse[bare_jid] = id;
        return id;
    }

    public int purge_caches() throws Error {
        int total_deleted = 0;
        exec("SAVEPOINT dinox_clear_caches");
        try {
            foreach (string table in new string[] { "entity", "entity_identity",
                    "entity_feature", "contact_avatar", "file_thumbnails" }) {
                exec("DELETE FROM " + table);
                total_deleted += changes();
            }
            // Roster+version form one persisted protocol state, not disposable
            // cache. Local sticker libraries and undecrypted messages may have
            // no server copy. History sync/cutoff markers also remain intact.
            exec("RELEASE dinox_clear_caches");
        } catch (Error err) {
            exec("ROLLBACK TO dinox_clear_caches");
            exec("RELEASE dinox_clear_caches");
            throw err;
        }
        exec("VACUUM");
        return total_deleted;
    }
}

}

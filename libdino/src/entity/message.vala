using Gee;
using Xmpp;

namespace Dino.Entities {

public class Message : Object {

    public const bool DIRECTION_SENT = true;
    public const bool DIRECTION_RECEIVED = false;

    public enum Marked {
        NONE,
        RECEIVED,
        READ,
        ACKNOWLEDGED,
        UNSENT,
        WONTSEND,
        SENDING,
        SENT,
        ERROR
    }

    public static Marked[] MARKED_RECEIVED = new Marked[] { Marked.READ, Marked.RECEIVED, Marked.ACKNOWLEDGED };

    public enum Type {
        ERROR,
        CHAT,
        GROUPCHAT,
        GROUPCHAT_PM,
        UNKNOWN;

        public bool is_muc_semantic() {
            return this == GROUPCHAT || this == GROUPCHAT_PM;
        }
    }

    public int id { get; set; default = -1; }
    public Account account { get; set; }
    public Jid? counterpart { get; set; }
    public Jid? ourpart { get; set; }
    public Jid? from {
        get { return direction == DIRECTION_SENT ? ourpart : counterpart; }
    }
    public Jid? to {
        get { return direction == DIRECTION_SENT ? counterpart : ourpart; }
    }
    public bool direction { get; set; }
    public Jid? real_jid { get; set; }
    public int occupant_db_id { get; set; default=-1; }
    public Type type_ { get; set; default = Type.UNKNOWN; }
    private string? body_;
    public string? body {
        get { return body_; }
        set { body_ = value != null ? value.make_valid() : null; }
    }
    public string? stanza_id { get; set; }
    public string? server_id { get; set; }
    /** Exact, unmodified id attribute chosen by the message sender. */
    public string? sender_stanza_id { get; set; }
    public string? stable_id { get; private set; }
    public Jid? stable_id_by { get; private set; }
    public DateTime? time { get; set; }
    /** UTC **/
    public DateTime? local_time { get; set; }
    public Encryption encryption { get; set; default = Encryption.NONE; }
    public string? encryption_protocol { get; set; }
    /** Locally generated receive diagnostic, never inferred from user text. */
    public bool decryption_failed { get; set; default = false; }
    /** A trusted room archive has removed this message or its correction chain. */
    public bool archive_retracted { get; set; default = false; }
    public bool encryption_time_mismatch { get; set; default = false; }
    public string? delivery_error_text { get; set; }
    public bool markable { get; set; default = false; }
    private Marked marked_ = Marked.NONE;
    public Marked marked {
        get { return marked_; }
        set {
            if (value == Marked.RECEIVED && marked == Marked.READ) return;
            marked_ = value;
        }
    }
    public string? edit_to = null;
    public int quoted_item_id { get; private set; default=0; }
    
    public enum MentionState {
        UNKNOWN,
        NONE,
        MENTIONED
    }

    // UNKNOWN identifies old rows without mention provenance. Newly received
    // rows retain both positive and negative results across nickname changes.
    public MentionState mention_state { get; set; default = MentionState.UNKNOWN; }
    public bool has_mention {
        get { return mention_state == MentionState.MENTIONED; }
        set { mention_state = value ? MentionState.MENTIONED : MentionState.NONE; }
    }

    private Gee.List<Xep.FallbackIndication.Fallback> fallbacks = null;
    private Gee.List<Xep.MessageMarkup.Span> markups = null;

    private Database? db;
    private bool setting_marked_from_storage = false;

    public Message(string? body) {
        this.body = body;
    }

    public Message.from_row(Database db, Qlite.Row row) throws InvalidJidError {
        this.db = db;

        id = row[db.message.id];
        account = db.get_account_by_id(row[db.message.account_id]);
        stanza_id = row[db.message.stanza_id];
        server_id = row[db.message.server_id];
        sender_stanza_id = row[db.message.sender_stanza_id];
        stable_id = row[db.message.stable_id];
        string? stable_id_by_string = row[db.message.stable_id_by];
        if (stable_id_by_string != null) {
            stable_id_by = new Jid((!) stable_id_by_string);
        }
        type_ = (Message.Type) row[db.message.type_];

        counterpart = db.get_jid_by_id(row[db.message.counterpart_id]);
        string counterpart_resource = row[db.message.counterpart_resource];
        if (counterpart_resource != null) counterpart = counterpart.with_resource(counterpart_resource);

        string our_resource = row[db.message.our_resource];
        if (type_ == Type.GROUPCHAT && our_resource != null) {
            ourpart = counterpart.with_resource(our_resource);
        } else if (our_resource != null) {
            ourpart = account.bare_jid.with_resource(our_resource);
        } else {
            ourpart = account.bare_jid;
        }
        direction = row[db.message.direction];
        time = new DateTime.from_unix_utc(row[db.message.time]);
        local_time = new DateTime.from_unix_utc(row[db.message.local_time]);
        body = row[db.message.body];
        archive_retracted = row[db.message.archive_retracted];
        marked = (Message.Marked) row[db.message.marked];
        encryption = (Encryption) row[db.message.encryption];
        encryption_protocol = row[db.message.encryption_protocol];
        decryption_failed = row[db.message.decryption_failed];
        encryption_time_mismatch = row[db.message.encryption_time_mismatch];
        markable = row[db.message.markable];
        int stored_mention_state = row[db.message.mention_state];
        if (stored_mention_state >= MentionState.UNKNOWN &&
                stored_mention_state <= MentionState.MENTIONED) {
            mention_state = (MentionState) stored_mention_state;
        }

        string? real_jid_str = row[db.real_jid.real_jid];
        if (real_jid_str != null) real_jid = new Jid(real_jid_str);

        occupant_db_id = db.message_occupant_id.occupant_id.is_null(row)
            ? -1 : row[db.message_occupant_id.occupant_id];

        edit_to = row[db.message_correction.to_stanza_id];
        quoted_item_id = row[db.reply.quoted_content_item_id];

        notify.connect(on_update);
    }

    public void persist(Database db) {
        if (id != -1) return;

        this.db = db;
        Qlite.InsertBuilder builder = db.message.insert()
            .value(db.message.account_id, account.id)
            .value(db.message.counterpart_id, db.get_jid_id(counterpart))
            .value(db.message.counterpart_resource, counterpart.resourcepart)
            .value(db.message.our_resource, ourpart.resourcepart)
            .value(db.message.direction, direction)
            .value(db.message.type_, type_)
            .value(db.message.time, (long) time.to_unix())
            .value(db.message.local_time, (long) local_time.to_unix())
            .value(db.message.body, body)
            .value(db.message.archive_retracted, archive_retracted)
            .value(db.message.encryption, encryption)
            .value(db.message.decryption_failed, decryption_failed)
            .value(db.message.encryption_time_mismatch, encryption_time_mismatch)
            .value(db.message.marked, marked)
            .value(db.message.markable, markable)
            .value(db.message.mention_state, (int) mention_state);
        if (stanza_id != null) builder.value(db.message.stanza_id, stanza_id);
        if (server_id != null) builder.value(db.message.server_id, server_id);
        if (sender_stanza_id != null) {
            builder.value(db.message.sender_stanza_id, sender_stanza_id);
        }
        if (stable_id != null) builder.value(db.message.stable_id, stable_id);
        if (stable_id_by != null) {
            builder.value(db.message.stable_id_by,
                ((!) stable_id_by).to_string());
        }
        if (encryption_protocol != null) builder.value(db.message.encryption_protocol, encryption_protocol);
        id = (int) builder.perform();

        if (real_jid != null) {
            db.real_jid.insert()
                .value(db.real_jid.message_id, id)
                .value(db.real_jid.real_jid, real_jid.to_string())
                .perform();
        }

        if (occupant_db_id != -1) {
            db.message_occupant_id.insert()
                .value(db.message_occupant_id.occupant_id, occupant_db_id)
                .value(db.message_occupant_id.message_id, id)
                .perform();
        }
        notify.connect(on_update);
    }

    /** Replace the XEP-0359 id and authority as one database unit. */
    internal void set_stable_reference(string stable_id, Jid by) {
        if (stable_id.strip().length == 0 || !by.is_bare()) return;

        if (id != -1 && db != null) {
            ((!) db).message.update()
                .with(((!) db).message.id, "=", id)
                .set(((!) db).message.stable_id, stable_id)
                .set(((!) db).message.stable_id_by, by.to_string())
                .perform();
        }

        this.stable_id = stable_id;
        this.stable_id_by = by;
    }

    /** Update the cached object after MessageStorage already wrote the row. */
    internal void set_marked_from_storage(Marked marked) {
        setting_marked_from_storage = true;
        this.marked = marked;
        setting_marked_from_storage = false;
    }

    /**
     * Persist the unresolved XEP-0461 target before attempting local lookup.
     * Keeping the wire id and sender lets a later MAM/live parent resolve the
     * edge without accepting an id collision from another sender.
     */
    public void set_quoted_reference(string quoted_message_stanza_id,
            Jid quoted_message_from) {
        if (id == -1) {
            warning("Message needs to be persisted before setting quoted reference");
            return;
        }

        this.quoted_item_id = 0;

        db.reply.upsert()
                .value(db.reply.message_id, id, true)
                .value_null(db.reply.quoted_content_item_id)
                .value(db.reply.quoted_message_stanza_id,
                    quoted_message_stanza_id)
                .value(db.reply.quoted_message_from,
                    quoted_message_from.to_string())
                .perform();
    }

    /**
     * Resolve a reply to a local ContentItem while retaining its wire
     * provenance when available. Existing raw provenance is deliberately not
     * cleared: deletion/thread code must be able to distinguish a known local
     * edge from an id-only legacy edge.
     */
    public void set_quoted_item(int quoted_content_item_id,
            string? quoted_message_stanza_id = null,
            Jid? quoted_message_from = null) {
        if (id == -1) {
            warning("Message needs to be persisted before setting quoted item");
            return;
        }

        this.quoted_item_id = quoted_content_item_id;

        Qlite.UpsertBuilder builder = db.reply.upsert()
                .value(db.reply.message_id, id, true)
                .value(db.reply.quoted_content_item_id,
                    quoted_content_item_id);
        if (quoted_message_stanza_id != null) {
            builder.value(db.reply.quoted_message_stanza_id,
                (!) quoted_message_stanza_id);
        }
        if (quoted_message_from != null) {
            builder.value(db.reply.quoted_message_from,
                ((!) quoted_message_from).to_string());
        }
        builder.perform();
    }

    public Gee.List<Xep.FallbackIndication.Fallback> get_fallbacks() {
        if (fallbacks != null) return fallbacks;
        fetch_body_meta();

        return fallbacks;
    }

    public Gee.List<Xep.MessageMarkup.Span> get_markups() {
        if (markups != null) return markups;
        fetch_body_meta();

        return markups;
    }

    public void persist_markups(Gee.List<Xep.MessageMarkup.Span> markups, int message_id) {
        this.markups = markups;

        foreach (var span in markups) {
            foreach (var ty in span.types) {
                db.body_meta.insert()
                        .value(db.body_meta.info_type, Xep.MessageMarkup.NS_URI)
                        .value(db.body_meta.message_id, message_id)
                        .value(db.body_meta.info, Xep.MessageMarkup.span_type_to_str(ty))
                        .value(db.body_meta.from_char, span.start_char)
                        .value(db.body_meta.to_char, span.end_char)
                        .perform();
            }
        }
    }

    private void fetch_body_meta() {
        if (db == null) {
            this.fallbacks = new ArrayList<Xep.FallbackIndication.Fallback>();
            this.markups = new ArrayList<Xep.MessageMarkup.Span>();
            return;
        }

        var fallbacks_by_ns = new HashMap<string, ArrayList<Xep.FallbackIndication.FallbackLocation>>();
        var markups = new ArrayList<Xep.MessageMarkup.Span>();

        foreach (Qlite.Row row in db.body_meta.select().with(db.body_meta.message_id, "=", id)) {
            switch (row[db.body_meta.info_type]) {
                case Xep.FallbackIndication.NS_URI:
                    string ns_uri = row[db.body_meta.info];
                    if (!fallbacks_by_ns.has_key(ns_uri)) {
                        fallbacks_by_ns[ns_uri] = new ArrayList<Xep.FallbackIndication.FallbackLocation>();
                    }
                    fallbacks_by_ns[ns_uri].add(new Xep.FallbackIndication.FallbackLocation.partial_body(row[db.body_meta.from_char], row[db.body_meta.to_char]));
                    break;
                case Xep.MessageMarkup.NS_URI:
                    var types = new ArrayList<Xep.MessageMarkup.SpanType>();
                    types.add(Xep.MessageMarkup.str_to_span_type(row[db.body_meta.info]));
                    markups.add(new Xep.MessageMarkup.Span() { types=types, start_char=row[db.body_meta.from_char], end_char=row[db.body_meta.to_char] });
                    break;
            }
        }

        var fallbacks = new ArrayList<Xep.FallbackIndication.Fallback>();
        foreach (string ns_uri in fallbacks_by_ns.keys) {
            fallbacks.add(new Xep.FallbackIndication.Fallback(ns_uri, fallbacks_by_ns[ns_uri]));
        }
        this.fallbacks = fallbacks;
        this.markups = markups;
    }

    public void set_fallbacks(Gee.List<Xep.FallbackIndication.Fallback> fallbacks) {
        if (id == -1) {
            warning("Message needs to be persisted before setting fallbacks");
            return;
        }

        this.fallbacks = fallbacks;

        foreach (var fallback in fallbacks) {
            foreach (var location in fallback.locations) {
                db.body_meta.insert()
                        .value(db.body_meta.message_id, id)
                        .value(db.body_meta.info_type, Xep.FallbackIndication.NS_URI)
                        .value(db.body_meta.info, fallback.ns_uri)
                        .value(db.body_meta.from_char, location.from_char)
                        .value(db.body_meta.to_char, location.to_char)
                        .perform();
            }
        }

    }

    public void set_type_string(string type) {
    switch (type) {
            case Xmpp.MessageStanza.TYPE_CHAT:
                type_ = Type.CHAT; break;
            case Xmpp.MessageStanza.TYPE_GROUPCHAT:
                type_ = Type.GROUPCHAT; break;
        }
    }

    public new string get_type_string() {
    switch (type_) {
            case Type.CHAT:
            case Type.GROUPCHAT_PM:
                return Xmpp.MessageStanza.TYPE_CHAT;
            case Type.GROUPCHAT:
                return Xmpp.MessageStanza.TYPE_GROUPCHAT;
            default:
                return Xmpp.MessageStanza.TYPE_NORMAL;
        }
    }

    public bool equals(Message? m) {
        if (m == null) return false;
        return equals_func(this, m);
    }

    public static bool equals_func(Message m1, Message m2) {
        if (m1.stanza_id == m2.stanza_id &&
                m1.body == m2.body) {
            return true;
        }
        return false;
    }

    public static uint hash_func(Message message) {
        if (message.body == null) return 0;
        return message.body.hash();
    }

    private void on_update(Object o, ParamSpec sp) {
        Qlite.UpdateBuilder update_builder = db.message.update().with(db.message.id, "=", id);
        switch (sp.name) {
            case "stanza-id":
                update_builder.set(db.message.stanza_id, stanza_id); break;
            case "server-id":
                update_builder.set(db.message.server_id, server_id); break;
            case "sender-stanza-id":
                if (sender_stanza_id == null) {
                    update_builder.set_null(db.message.sender_stanza_id);
                } else {
                    update_builder.set(db.message.sender_stanza_id,
                        (!) sender_stanza_id);
                }
                break;
            case "counterpart":
                update_builder.set(db.message.counterpart_id, db.get_jid_id(counterpart));
                update_builder.set(db.message.counterpart_resource, counterpart.resourcepart); break;
            case "ourpart":
                update_builder.set(db.message.our_resource, ourpart.resourcepart); break;
            case "direction":
                update_builder.set(db.message.direction, direction); break;
            case "type-":
                update_builder.set(db.message.type_, type_); break;
            case "time":
                update_builder.set(db.message.time, (long) time.to_unix()); break;
            case "local-time":
                update_builder.set(db.message.local_time, (long) local_time.to_unix()); break;
            case "body":
                update_builder.set(db.message.body, body); break;
            case "archive-retracted":
                update_builder.set(db.message.archive_retracted, archive_retracted); break;
            case "encryption":
                update_builder.set(db.message.encryption, encryption); break;
            case "encryption-protocol":
                update_builder.set(db.message.encryption_protocol, encryption_protocol); break;
            case "decryption-failed":
                update_builder.set(db.message.decryption_failed, decryption_failed); break;
            case "encryption-time-mismatch":
                update_builder.set(db.message.encryption_time_mismatch, encryption_time_mismatch); break;
            case "mention-state":
                update_builder.set(db.message.mention_state, (int) mention_state); break;
            case "marked":
                if (setting_marked_from_storage) return;
                update_builder.set(db.message.marked, marked); break;
            case "markable":
                update_builder.set(db.message.markable, markable); break;
            default:
                return;
        }
        update_builder.perform();

        if (sp.get_name() == "real-jid" && real_jid != null) {
            db.real_jid.upsert()
                .value(db.real_jid.message_id, id, true)
                .value(db.real_jid.real_jid, real_jid.to_string())
                .perform();
        }

        if (sp.get_name() == "quoted-item-id") {
            db.reply.upsert()
                .value(db.reply.message_id, id, true)
                .value(db.reply.quoted_content_item_id, quoted_item_id)
                .perform();
        }

        if (sp.get_name() == "message-occupant-id" && occupant_db_id != -1) {
            db.message_occupant_id.upsert()
                .value(db.message_occupant_id.occupant_id, occupant_db_id, true)
                .value(db.message_occupant_id.message_id, id)
                .perform();
        }
    }
}

}

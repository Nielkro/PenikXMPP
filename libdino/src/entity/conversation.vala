/*
 * Copyright (C) 2025 Ralf Peter <dinox@handwerker.jetzt>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

using Xmpp;

namespace Dino.Entities {

public class Conversation : Object {

    private const string MUC_STATUS_MESSAGES_SETTING = "show_muc_status_messages";

    public signal void object_updated(Conversation conversation);

    public enum Type {
        CHAT,
        GROUPCHAT,
        GROUPCHAT_PM;

        public bool is_muc_semantic() {
            return this == GROUPCHAT || this == GROUPCHAT_PM;
        }
    }

    public int id { get; set; }
    public Type type_ { get; set; }
    public Account account { get; private set; }
    public Jid counterpart { get; private set; }
    public string? nickname { get; set; }
    public bool active { get; set; default = false; }
    public DateTime active_last_changed { get; private set; }
    private DateTime? _last_active;
    public DateTime? last_active {
        get { return _last_active; }
        set {
            if (_last_active == null ||
                    (value != null && value.difference(_last_active) > 0)) {
                _last_active = value;
            }
        }
    }
    public Encryption encryption { get; set; default = Encryption.UNKNOWN; }
    public Message? read_up_to { get; set; }
    public int read_up_to_item { get; set; default=-1; }
    private bool setting_read_state = false;

    public enum NotifySetting { DEFAULT, ON, OFF, HIGHLIGHT }
    public NotifySetting notify_setting { get; set; default = NotifySetting.DEFAULT; }

    public enum Setting { DEFAULT, ON, OFF }
    public Setting send_typing { get; set; default = Setting.DEFAULT; }
    public Setting send_marker { get; set; default = Setting.DEFAULT; }
    public bool show_muc_status_messages { get; set; default = false; }

    public int pinned { get; set; default = 0; }
    
    public DateTime? history_cleared_at { get; set; default = null; }
    
    public int message_expiry_seconds { get; set; default = 0; }
    private int muc_history_days_ = 0;
    public int muc_history_days {
        get { return muc_history_days_; }
        set { muc_history_days_ = value >= 0 && value <= 365 ? value : 0; }
    }

    // For GROUPCHAT_PM, room/nick is an address, not a durable person
    // identity. This binding prevents a later occupant reusing the same nick
    // from inheriting the previous private thread.
    public string? muc_pm_peer_identity { get; set; default = null; }

    private Database? db;
    private int persisted_identity_id = 0;
    private int persisted_identity_account_id = 0;
    private string? persisted_identity_jid_localpart = null;
    private string? persisted_identity_jid_domainpart = null;
    private string? persisted_identity_jid_resourcepart = null;
    private string? persisted_identity_account_localpart = null;
    private string? persisted_identity_account_domainpart = null;

    public Conversation(Jid jid, Account account, Type type) {
        this.account = account;
        this.counterpart = jid;
        this.type_ = type;
    }

    public Conversation.from_row(Database db, Qlite.Row row) throws InvalidJidError {
        this.db = db;

        id = row[db.conversation.id];
        type_ = (Conversation.Type) row[db.conversation.type_];
        account = db.get_account_by_id(row[db.conversation.account_id]);
        string? resource = row[db.conversation.resource];
        counterpart = db.get_jid_by_id(row[db.conversation.jid_id]);
        if (type_ == Conversation.Type.GROUPCHAT) counterpart = counterpart.bare_jid;
        if (type_ == Conversation.Type.GROUPCHAT_PM) counterpart = counterpart.with_resource(resource);
        nickname = type_ == Conversation.Type.GROUPCHAT ? resource : null;
        active = row[db.conversation.active];
        active_last_changed = new DateTime.from_unix_utc(row[db.conversation.active_last_changed]);
        int64? last_active = row[db.conversation.last_active];
        if (last_active != null) this.last_active = new DateTime.from_unix_utc(last_active);
        encryption = (Encryption) row[db.conversation.encryption];
        int? read_up_to = row[db.conversation.read_up_to];
        if (read_up_to != null) this.read_up_to = db.get_message_by_id(read_up_to);
        read_up_to_item = row[db.conversation.read_up_to_item];
        notify_setting = (NotifySetting) row[db.conversation.notification];
        send_typing = (Setting) row[db.conversation.send_typing];
        send_marker = (Setting) row[db.conversation.send_marker];
        if (type_ == Type.GROUPCHAT) {
            string? show_muc_status_messages_value = db.conversation_settings
                    .get_value(id, MUC_STATUS_MESSAGES_SETTING);
            show_muc_status_messages = show_muc_status_messages_value == "true";
        }
        pinned = row[db.conversation.pinned];
        int64? history_cleared = row[db.conversation.history_cleared_at];
        if (history_cleared != null && history_cleared > 0) {
            this.history_cleared_at = new DateTime.from_unix_utc(history_cleared);
        }
        message_expiry_seconds = row[db.conversation.message_expiry_seconds];
        muc_history_days = row[db.conversation.muc_history_days];
        muc_pm_peer_identity = row[db.conversation.muc_pm_peer_identity];

        remember_persisted_identity();
        notify.connect(on_update);
    }

    public void persist(Database db) {
        this.db = db;
        this.active_last_changed = new DateTime.now_utc();

        var insert = db.conversation.insert()
                .value(db.conversation.account_id, account.id)
                .value(db.conversation.jid_id, db.get_jid_id(counterpart))
                .value(db.conversation.type_, type_)
                .value(db.conversation.encryption, encryption)
                .value(db.conversation.active, active)
                .value(db.conversation.active_last_changed, (long) active_last_changed.to_unix())
                .value(db.conversation.notification, notify_setting)
                .value(db.conversation.send_typing, send_typing)
                .value(db.conversation.send_marker, send_marker)
                .value(db.conversation.pinned, pinned);
        if (read_up_to != null) {
            insert.value(db.conversation.read_up_to, read_up_to.id);
        }
        if (read_up_to_item != -1) {
            insert.value(db.conversation.read_up_to_item, read_up_to_item);
        }
        if (nickname != null) {
            insert.value(db.conversation.resource, nickname);
        }
        if (counterpart.is_full()) {
            insert.value(db.conversation.resource, counterpart.resourcepart);
        }
        if (last_active != null) {
            insert.value(db.conversation.last_active, (long) last_active.to_unix());
        }
        if (history_cleared_at != null) {
            insert.value(db.conversation.history_cleared_at, (long) history_cleared_at.to_unix());
        }
        insert.value(db.conversation.message_expiry_seconds, message_expiry_seconds);
        insert.value(db.conversation.muc_history_days, muc_history_days);
        if (muc_pm_peer_identity != null) {
            insert.value(db.conversation.muc_pm_peer_identity,
                (!) muc_pm_peer_identity);
        }
        // The conversation identity index intentionally uses different keys
        // for bare chats and full-JID MUC PMs. Always resolve the persisted
        // row after INSERT OR IGNORE instead of trusting last_insert_rowid(),
        // which remains stale when SQLite ignores a duplicate insert.
        insert.or("IGNORE").perform();
        var persisted_row_query = db.conversation.select({db.conversation.id})
                .with(db.conversation.account_id, "=", account.id)
                .with(db.conversation.jid_id, "=", db.get_jid_id(counterpart))
                .with(db.conversation.type_, "=", type_);
        if (type_ == Type.GROUPCHAT_PM) {
            if (counterpart.resourcepart != null) {
                persisted_row_query.with(db.conversation.resource, "=", counterpart.resourcepart);
            } else {
                persisted_row_query.with_null(db.conversation.resource);
            }
        }
        int? persisted_id = persisted_row_query.single().row().get(db.conversation.id);
        if (persisted_id == null) {
            critical("Failed to resolve persisted conversation identity for %s", counterpart.to_string());
            id = 0;
        } else {
            id = (!) persisted_id;
        }
        if (show_muc_status_messages && id > 0) {
            persist_muc_status_messages_setting();
        }
        remember_persisted_identity();
        notify.connect(on_update);
    }

    private void remember_persisted_identity() {
        persisted_identity_id = id;
        persisted_identity_account_id = account.id;
        persisted_identity_jid_localpart = counterpart.localpart;
        persisted_identity_jid_domainpart = counterpart.domainpart;
        persisted_identity_jid_resourcepart = counterpart.resourcepart;
        persisted_identity_account_localpart = account.bare_jid.localpart;
        persisted_identity_account_domainpart = account.bare_jid.domainpart;
    }

    internal bool matches_persisted_identity(Database owner) {
        return db == owner && id > 0 && id == persisted_identity_id &&
            account.id == persisted_identity_account_id &&
            counterpart.localpart == persisted_identity_jid_localpart &&
            counterpart.domainpart == persisted_identity_jid_domainpart &&
            counterpart.resourcepart == persisted_identity_jid_resourcepart &&
            account.bare_jid.localpart == persisted_identity_account_localpart &&
            account.bare_jid.domainpart == persisted_identity_account_domainpart;
    }

    public void mark_active_now() {
        active_last_changed = new DateTime.now_utc();
        if (db != null && id > 0) {
            db.conversation.update()
                    .with(db.conversation.id, "=", id)
                    .set(db.conversation.active_last_changed, (long) active_last_changed.to_unix())
                    .perform();
        }
    }

    /** Persist both read pointers in one database update. */
    public void set_read_state(Message? message, int content_item_id) {
        if (read_up_to == message && read_up_to_item == content_item_id) return;

        if (db != null && id > 0) {
            var update = ((!) db).conversation.update()
                .with(((!) db).conversation.id, "=", id)
                .set(((!) db).conversation.read_up_to_item, content_item_id);
            if (message != null) {
                update.set(((!) db).conversation.read_up_to,
                    ((!) message).id);
            } else {
                update.set_null(((!) db).conversation.read_up_to);
            }
            update.perform();
        }

        setting_read_state = true;
        read_up_to = message;
        read_up_to_item = content_item_id;
        setting_read_state = false;
    }

    public NotifySetting get_notification_setting(StreamInteractor stream_interactor) {
        if (!Application.get_default().settings.notifications) return NotifySetting.OFF;
        return notify_setting != NotifySetting.DEFAULT ? notify_setting : get_notification_default_setting(stream_interactor);
    }

    public NotifySetting get_notification_default_setting(StreamInteractor stream_interactor) {
        if (!Application.get_default().settings.notifications) return NotifySetting.OFF;

        if (type_ == Type.GROUPCHAT) {
            if (stream_interactor.get_module<MucManager>(MucManager.IDENTITY).is_private_room(this.account, this.counterpart)) {
                return NotifySetting.ON;
            } else {
                return NotifySetting.HIGHLIGHT;
            }
        }
        return NotifySetting.ON;
    }

    public Setting get_send_typing_setting(StreamInteractor stream_interactor) {
        if (send_typing != Setting.DEFAULT) return send_typing;

        if (stream_interactor.get_module<MucManager>(MucManager.IDENTITY).is_public_room(this.account, this.counterpart)) return Setting.OFF;

        return Application.get_default().settings.send_typing ? Setting.ON : Setting.OFF;
    }

    public Setting get_send_marker_setting(StreamInteractor stream_interactor) {
        if (send_marker != Setting.DEFAULT) return send_marker;

        if (stream_interactor.get_module<MucManager>(MucManager.IDENTITY).is_public_room(this.account, this.counterpart)) return Setting.OFF;

        return Application.get_default().settings.send_marker ? Setting.ON : Setting.OFF;
    }

    public bool equals(Conversation? conversation) {
        if (conversation == null) return false;
        return equals_func(this, conversation);
    }

    public static bool equals_func(Conversation conversation1, Conversation conversation2) {
        return conversation1.counterpart.equals(conversation2.counterpart) && conversation1.account.equals(conversation2.account) && conversation1.type_ == conversation2.type_;
    }

    public static uint hash_func(Conversation conversation) {
        return conversation.counterpart.to_string().hash() ^ conversation.account.bare_jid.to_string().hash();
    }

    private void on_update(Object o, ParamSpec sp) {
        if (setting_read_state && (sp.name == "read-up-to" ||
                sp.name == "read-up-to-item")) {
            return;
        }
        var update = db.conversation.update().with(db.conversation.id, "=", id);
        switch (sp.name) {
            case "type-":
                update.set(db.conversation.type_, type_); break;
            case "encryption":
                update.set(db.conversation.encryption, encryption); break;
            case "read-up-to":
                if (read_up_to != null) {
                    update.set(db.conversation.read_up_to, read_up_to.id);
                } else {
                    update.set_null(db.conversation.read_up_to);
                }
                break;
            case "read-up-to-item":
                // -1 is the persisted sentinel for "no content item read".
                // The column is NOT NULL, so turning the sentinel into SQL
                // NULL aborts in Qlite (notably when a MUC PM nickname is
                // rebound after the previous thread had been read).
                update.set(db.conversation.read_up_to_item, read_up_to_item);
                break;
            case "nickname":
                update.set(db.conversation.resource, nickname); break;
            case "active":
                update.set(db.conversation.active, active);
                active_last_changed = new DateTime.now_utc();
                update.set(db.conversation.active_last_changed, (long) active_last_changed.to_unix());
                break;
            case "last-active":
                if (last_active != null) {
                    update.set(db.conversation.last_active, (long) last_active.to_unix());
                } else {
                    update.set_null(db.conversation.last_active);
                }
                break;
            case "notify-setting":
                update.set(db.conversation.notification, notify_setting); break;
            case "send-typing":
                update.set(db.conversation.send_typing, send_typing); break;
            case "send-marker":
                update.set(db.conversation.send_marker, send_marker); break;
            case "show-muc-status-messages":
                persist_muc_status_messages_setting();
                return;
            case "pinned":
                update.set(db.conversation.pinned, pinned); break;
            case "history-cleared-at":
                if (history_cleared_at != null) {
                    update.set(db.conversation.history_cleared_at, (long) history_cleared_at.to_unix());
                } else {
                    update.set_null(db.conversation.history_cleared_at);
                }
                break;
            case "message-expiry-seconds":
                update.set(db.conversation.message_expiry_seconds, message_expiry_seconds); break;
            case "muc-history-days":
                update.set(db.conversation.muc_history_days, muc_history_days); break;
            case "muc-pm-peer-identity":
                if (muc_pm_peer_identity != null) {
                    update.set(db.conversation.muc_pm_peer_identity,
                        (!) muc_pm_peer_identity);
                } else {
                    update.set_null(db.conversation.muc_pm_peer_identity);
                }
                break;
        }
        update.perform();
    }

    private void persist_muc_status_messages_setting() {
        if (db == null || id <= 0 || type_ != Type.GROUPCHAT) return;
        db.conversation_settings.upsert()
                .value(db.conversation_settings.conversation_id, id, true)
                .value(db.conversation_settings.key,
                    MUC_STATUS_MESSAGES_SETTING, true)
                .value(db.conversation_settings.value,
                    show_muc_status_messages.to_string())
                .perform();
    }
}

}

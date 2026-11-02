using Gee;
using Xmpp;

using Xmpp;
using Dino.Entities;

namespace Dino.Plugins.OpenPgp {

private class PrivateMucFileBodyUrlKeyMaterial : Object {
    public GPGHelper.Key[] keys;
    public string protocol;
    public Jid recipient_jid;

    public PrivateMucFileBodyUrlKeyMaterial(GPGHelper.Key[] keys, string protocol, Jid recipient_jid) {
        this.keys = keys;
        this.protocol = protocol;
        this.recipient_jid = recipient_jid;
    }
}

public class Manager : StreamInteractionModule, Object {
    public static ModuleIdentity<Manager> IDENTITY = new ModuleIdentity<Manager>("pgp_manager");
    public string id { get { return IDENTITY.id; } }

    public signal void key_state_changed(Account account, Jid? jid);

    public const string MESSAGE_ENCRYPTED = "pgp";
    public const string FILE_PROTOCOL_XEP0027 = "openpgp:xep0027";
    public const string FILE_PROTOCOL_XEP0374 = "openpgp:xep0374";
    
    // XEP-0374 namespace for Service Discovery
    private const string NS_OPENPGP_IM = "urn:xmpp:openpgp:im:0";

    private StreamInteractor stream_interactor;
    private Database db;
    private HashMap<string, string> pgp_key_ids = new HashMap<string, string>();
    private HashMap<string, string> legacy_presence_key_ids = new HashMap<string, string>();
    private HashSet<string> xep0373_key_tokens = new HashSet<string>();
    private ReceivedMessageListener received_message_listener = new ReceivedMessageListener();
    
    // Key cache to avoid synchronous GPG calls during message encryption
    // Maps key_id -> GPGHelper.Key (or null if key not valid)
    private HashMap<string, GPGHelper.Key?> key_cache = new HashMap<string, GPGHelper.Key?>();
    private Mutex key_cache_mutex = Mutex();
    private HashMap<string, PrivateMucFileBodyUrlKeyMaterial> pending_private_muc_file_body_url_keys =
        new HashMap<string, PrivateMucFileBodyUrlKeyMaterial>();
    
    // XEP-0373 key manager reference - set by plugin after initialization
    public Xep0373KeyManager? xep0373_manager { get; set; default = null; }

    public static void start(StreamInteractor stream_interactor, Database db) {
        Manager m = new Manager(stream_interactor, db);
        stream_interactor.add_module(m);
    }

    public static string key_mode_to_file_protocol(string key_mode) {
        return key_mode == Database.ACCOUNT_KEY_MODE_LEGACY ? FILE_PROTOCOL_XEP0027 : FILE_PROTOCOL_XEP0374;
    }

    public static string file_protocol_to_key_mode(string? protocol, string fallback_mode) {
        if (protocol == FILE_PROTOCOL_XEP0027) return Database.ACCOUNT_KEY_MODE_LEGACY;
        if (protocol == FILE_PROTOCOL_XEP0374) return Database.ACCOUNT_KEY_MODE_XMPP;
        return fallback_mode;
    }

    public string get_selected_file_protocol(Account account) {
        return key_mode_to_file_protocol(db.get_account_key_mode(account));
    }

    private Manager(StreamInteractor stream_interactor, Database db) {
        this.stream_interactor = stream_interactor;
        this.db = db;

        stream_interactor.account_added.connect(on_account_added);
        stream_interactor.get_module<MessageProcessor>(MessageProcessor.IDENTITY).received_pipeline.connect(received_message_listener);
        stream_interactor.get_module<MessageProcessor>(MessageProcessor.IDENTITY).pre_message_send.connect(check_encypt);
    }
    
    /**
     * Check if a contact supports XEP-0374 via Dino's EntityInfo cache
     * Uses synchronous lookup - safe and fast
     */
    private bool check_xep0374_support(Account account, Jid jid) {
        if (db.contact_supports_xep0374(account, jid.bare_jid)) {
            debug("OpenPGP: %s supports XEP-0374 (OpenPGP DB)", jid.to_string());
            return true;
        }

        // Use Dino's built-in EntityInfo cache (populated via XEP-0115 Entity Capabilities)
        var entity_info = stream_interactor.get_module<EntityInfo>(EntityInfo.IDENTITY);
        if (entity_info == null) {
            debug("OpenPGP: EntityInfo module not available, cannot check XEP-0374 support");
            return false;
        }
        
        // Try cached lookup first (synchronous, crash-safe)
        bool has_feature = entity_info.has_feature_cached(account, jid.bare_jid, NS_OPENPGP_IM);
        if (has_feature) {
            debug("OpenPGP: %s supports XEP-0374 (cached)", jid.to_string());
            return true;
        }
        
        // Also check offline DB cache for known contacts
        has_feature = entity_info.has_feature_offline(account, jid.bare_jid, NS_OPENPGP_IM);
        if (has_feature) {
            debug("OpenPGP: %s supports XEP-0374 (offline DB)", jid.to_string());
            return true;
        }

        // Entity capabilities for 1:1 contacts are normally learned per full
        // resource, while conversations are keyed by bare JID.  Check the known
        // online resources before falling back to legacy XEP-0027.
        var presence_manager = stream_interactor.get_module<PresenceManager>(PresenceManager.IDENTITY);
        Gee.List<Jid>? full_jids = presence_manager != null ? presence_manager.get_full_jids(jid.bare_jid, account) : null;
        if (full_jids != null) {
            foreach (Jid full_jid in full_jids) {
                if (entity_info.has_feature_cached(account, full_jid, NS_OPENPGP_IM) ||
                        entity_info.has_feature_offline(account, full_jid, NS_OPENPGP_IM)) {
                    debug("OpenPGP: %s supports XEP-0374 via resource %s", jid.to_string(), full_jid.to_string());
                    return true;
                }
            }
        }
        
        debug("OpenPGP: %s does NOT support XEP-0374 according to the current cache", jid.to_string());
        return false;
    }

    public void mark_xep0373_key_received(Account account, Jid jid) {
        xep0373_key_tokens.add(get_xep0373_key_token(account, jid));
    }

    public void forget_xep0373_key_refresh(Account account, Jid jid) {
        xep0373_key_tokens.remove(get_xep0373_key_token(account, jid));
    }

    private Jid get_contact_storage_jid(Account account, Jid jid) {
        return is_groupchat_occupant(jid, account) ? jid : jid.bare_jid;
    }

    private bool is_groupchat_occupant(Jid jid, Account account) {
        MucManager? muc_manager = stream_interactor.get_module<MucManager>(MucManager.IDENTITY);
        return muc_manager != null && ((!) muc_manager).is_groupchat_occupant(jid, account);
    }

    private string get_legacy_presence_resource_token(Account account, Jid jid) {
        Jid storage_jid = get_contact_storage_jid(account, jid);
        if (storage_jid.equals(jid)) {
            return "%d|%s|".printf(account.id, storage_jid.to_string());
        }
        return "%d|%s|%s".printf(account.id, storage_jid.to_string(), jid.resourcepart ?? "");
    }

    private string get_legacy_presence_bare_prefix(Account account, Jid jid) {
        Jid storage_jid = get_contact_storage_jid(account, jid);
        return "%d|%s|".printf(account.id, storage_jid.to_string());
    }

    private string get_pgp_key_token(Account account, Jid jid) {
        Jid storage_jid = get_contact_storage_jid(account, jid);
        return "%d|%s".printf(account.id, storage_jid.bare_jid.to_string());
    }

    private string get_xep0373_key_token(Account account, Jid jid) {
        Jid storage_jid = get_contact_storage_jid(account, jid);
        return "%d|%s".printf(account.id, storage_jid.to_string());
    }

    private bool legacy_presence_resource_still_announces(Account account, Jid jid, string key_id) {
        string token = get_legacy_presence_resource_token(account, jid);
        lock (pgp_key_ids) {
            return legacy_presence_key_ids.has_key(token) && legacy_presence_key_ids[token] == key_id;
        }
    }

    private bool has_legacy_presence_resource(Account account, Jid jid) {
        string prefix = get_legacy_presence_bare_prefix(account, jid);
        foreach (string token in legacy_presence_key_ids.keys) {
            if (token.has_prefix(prefix)) return true;
        }
        return false;
    }

    private void prune_stale_legacy_presence_resources_locked(Account account, Jid jid) {
        Jid storage_jid = get_contact_storage_jid(account, jid);
        if (storage_jid.equals(jid)) return;

        var presence_manager = stream_interactor.get_module<PresenceManager>(PresenceManager.IDENTITY);
        Gee.List<Jid>? full_jids = presence_manager != null ? presence_manager.get_full_jids(storage_jid, account) : null;
        string prefix = get_legacy_presence_bare_prefix(account, storage_jid);

        var available_tokens = new HashSet<string>();
        if (full_jids != null) {
            foreach (Jid full_jid in full_jids) {
                available_tokens.add(get_legacy_presence_resource_token(account, full_jid));
            }
        }

        var stale_tokens = new ArrayList<string>();
        foreach (string token in legacy_presence_key_ids.keys) {
            if (!token.has_prefix(prefix)) continue;
            if (full_jids == null || !available_tokens.contains(token)) {
                stale_tokens.add(token);
            }
        }
        foreach (string token in stale_tokens) {
            legacy_presence_key_ids.unset(token);
        }
    }

    private bool contact_key_requires_xep0374(Account account, Jid jid) {
        Jid search_jid = is_groupchat_occupant(jid, account) ? jid : jid.bare_jid;
        return db.has_contact_xmpp_key(account, search_jid);
    }

    public bool contact_xmpp_key_was_refreshed_this_session(Account account, Jid jid) {
        return xep0373_key_tokens.contains(get_xep0373_key_token(account, jid));
    }

    public bool incoming_xep0374_message_matches_openpgp_conversation(Account account, MessageStanza message) {
        if (message.from == null || message.to == null) return false;

        ConversationManager? conversation_manager = stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY);
        if (conversation_manager == null) return false;

        Conversation? conversation = ((!) conversation_manager).approx_conversation_for_stanza(
            (!) message.from, (!) message.to, account, message.type_ ?? MessageStanza.TYPE_CHAT);
        if (conversation != null &&
                ((!) conversation).type_ == Conversation.Type.CHAT &&
                MessageProcessor.is_account_archive_message(account, message)) {
            // Old messages retain their original encryption protocol. The
            // receive path still verifies the account's sender key, signature
            // and recipient; it never switches the current chat preference.
            return true;
        }
        if (conversation == null || ((!) conversation).encryption != Encryption.PGP) {
            var archive = Xmpp.MessageArchiveManagement.MessageFlag.get_flag(message);
            warning("OpenPGP receive: refusing XEP-0374 stanza because the matching conversation is not OpenPGP-selected account=%d sender=%s stanza=%s mode=%d chat_type=%d mam=%s archive_sender=%s carbon=%s",
                    account.id, ((!) message.from).to_string(), message.id ?? "-",
                    conversation != null ? (int) ((!) conversation).encryption : -1,
                    conversation != null ? (int) ((!) conversation).type_ : -1,
                    archive != null ? "true" : "false",
                    archive != null ? archive.sender_jid.to_string() : "-",
                    Xmpp.Xep.MessageCarbons.MessageFlag.get_flag(message) != null ? "true" : "false");
            return false;
        }
        return true;
    }

    internal bool incoming_xep0374_message_is_account_archive_chat(Account account, MessageStanza message) {
        if (!MessageProcessor.is_account_archive_message(account, message)) return false;

        var conversation_manager = stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY);
        if (conversation_manager == null) return false;
        Conversation? conversation = conversation_manager.approx_conversation_for_stanza(
            (!) message.from, (!) message.to, account, message.type_ ?? MessageStanza.TYPE_CHAT);
        return conversation != null && ((!) conversation).type_ == Conversation.Type.CHAT;
    }

    public async bool ensure_fresh_xep0373_contact_key(Account account, Jid jid) {
        if (contact_xmpp_key_was_refreshed_this_session(account, jid)) return true;
        if (xep0373_manager == null) return false;

        Jid search_jid = is_groupchat_occupant(jid, account) ? jid : jid.bare_jid;
        // Receiving an XEP-0374 stanza is a concrete trust boundary, not a
        // passive UI readiness probe.  Bypass the once-per-session lazy fetch
        // cache so an earlier missing-key lookup cannot block acceptance after
        // the sender publishes a key later in the same session.  Do not clear
        // existing trust state on an automatic receive-time miss.
        bool imported = yield xep0373_manager.request_keys_for_incoming_message(account, search_jid);
        return imported && contact_xmpp_key_was_refreshed_this_session(account, search_jid);
    }

    public void mark_legacy_contact_activity(Account account, Jid jid) {
        Jid search_jid = get_contact_storage_jid(account, jid);
        string? key_id = db.get_contact_legacy_key(account, search_jid);
        if (key_id == null || key_id.length == 0) return;
        if (!legacy_key_has_email_uid((!) key_id)) return;

        notify_key_state_changed(account, search_jid);
        debug("OpenPGP: Refreshed legacy XEP-0027 UI state for %s after encrypted contact activity",
                search_jid.to_string());
    }

    public void refresh_active_openpgp_conversations(Account account, Jid? jid = null) {
        Account account_copy = account;
        Jid? jid_copy = jid;
        Idle.add(() => {
            refresh_active_openpgp_conversations_now(account_copy, jid_copy);
            return Source.REMOVE;
        });
    }

    private void refresh_active_openpgp_conversations_now(Account account, Jid? jid = null) {
        var cm = stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY);
        if (cm == null) return;

        Jid? changed_jid = jid != null ? ((!) jid).bare_jid : null;
        foreach (Conversation conversation in cm.get_active_conversations(account)) {
            if (conversation.encryption != Encryption.PGP) continue;
            if (changed_jid != null &&
                    conversation.type_ == Conversation.Type.CHAT &&
                    !conversation.counterpart.bare_jid.equals((!) changed_jid)) {
                continue;
            }
            debug("OpenPGP: Refreshing active encryption status for %s after key state change",
                    conversation.counterpart.to_string());
            conversation.notify_property("encryption");
        }
    }

    public void invalidate_active_xep0373_contact_refreshes(Account account) {
        if (xep0373_manager == null) return;

        var cm = stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY);
        if (cm == null) return;

        foreach (Conversation conversation in cm.get_active_conversations(account)) {
            if (conversation.encryption != Encryption.PGP || conversation.type_ != Conversation.Type.CHAT) continue;

            Jid contact_jid = conversation.counterpart.bare_jid;
            xep0373_key_tokens.remove(get_xep0373_key_token(account, contact_jid));
            xep0373_manager.invalidate_lazy_key_request(account, contact_jid);
        }
    }

    public void notify_key_state_changed(Account account, Jid? jid = null) {
        key_state_changed(account, jid);
        refresh_active_openpgp_conversations(account, jid);
    }

    private void reset_legacy_presence_state(Account account) {
        string account_prefix = "%d|".printf(account.id);
        lock (pgp_key_ids) {
            var stale_key_tokens = new ArrayList<string>();
            foreach (string token in pgp_key_ids.keys) {
                if (token.has_prefix(account_prefix)) stale_key_tokens.add(token);
            }
            foreach (string token in stale_key_tokens) {
                pgp_key_ids.unset(token);
            }

            var stale_presence_tokens = new ArrayList<string>();
            foreach (string token in legacy_presence_key_ids.keys) {
                if (token.has_prefix(account_prefix)) stale_presence_tokens.add(token);
            }
            foreach (string token in stale_presence_tokens) {
                legacy_presence_key_ids.unset(token);
            }
        }
        db.clear_contact_legacy_key_announcements(account);
        notify_key_state_changed(account);
    }

    private bool contact_key_allows_legacy(Account account, Jid jid) {
        Jid search_jid = is_groupchat_occupant(jid, account) ? jid : jid.bare_jid;
        string? key_id = db.get_contact_legacy_key(account, search_jid);
        if (key_id == null || key_id.length == 0) return false;
        if (!db.contact_legacy_key_is_announced(account, search_jid)) return false;
        return legacy_key_has_email_uid((!) key_id);
    }

    private bool legacy_key_has_email_uid(string key_id) {
        try {
            return GPGHelper.key_has_email_uid(key_id);
        } catch (Error e) {
            debug("OpenPGP: Legacy key %s has no usable email user ID: %s", key_id, e.message);
            return false;
        }
    }

    private bool account_key_is_valid_for_mode(Account account, string account_key_mode, string key_id, out string reason) {
        reason = "";
        try {
            if (account_key_mode == Database.ACCOUNT_KEY_MODE_XMPP) {
                if (!GPGHelper.key_has_xmpp_uid(key_id, account.bare_jid.to_string())) {
                    reason = _("The selected OpenPGP-for-XMPP account key does not contain the required xmpp: user ID for this account.");
                    return false;
                }
            } else if (!GPGHelper.key_has_email_uid(key_id)) {
                reason = _("The selected legacy OpenPGP/XEP-0027 account key has no email user ID for keyserver use.");
                return false;
            }
        } catch (Error e) {
            reason = _("OpenPGP account key validation failed: %s").printf(e.message);
            return false;
        }
        return true;
    }

    public bool can_encrypt_for_selected_openpgp_mode(Conversation conversation, out string reason) {
        reason = "";

        string account_key_mode = db.get_account_key_mode(conversation.account);
        string? own_key_for_mode = db.get_account_key_for_mode(conversation.account, account_key_mode);
        if (own_key_for_mode == null || own_key_for_mode.length == 0) {
            reason = account_key_mode == Database.ACCOUNT_KEY_MODE_LEGACY
                ? _("No legacy OpenPGP/XEP-0027 account key is active.")
                : _("No OpenPGP-for-XMPP account key is active.");
            return false;
        }

        if (!account_key_is_valid_for_mode(conversation.account, account_key_mode, (!) own_key_for_mode, out reason)) {
            return false;
        }

        if (conversation.type_ == Conversation.Type.CHAT) {
            if (account_key_mode == Database.ACCOUNT_KEY_MODE_XMPP) {
                if (!db.has_contact_xmpp_key(conversation.account, conversation.counterpart.bare_jid)) {
                    reason = _("This contact has no OpenPGP-for-XMPP key.");
                    return false;
                }
                if (!contact_xmpp_key_is_verified_for_encryption(conversation.account, conversation.counterpart.bare_jid, out reason)) {
                    return false;
                }
                if (!contact_xmpp_key_was_refreshed_this_session(conversation.account, conversation.counterpart)) {
                    if (xep0373_manager != null) {
                        xep0373_manager.request_keys_if_needed.begin(conversation.account, conversation.counterpart.bare_jid);
                    }
                    reason = _("The contact's OpenPGP-for-XMPP key has not been refreshed yet.");
                    return false;
                }
            } else {
                if (!db.has_contact_legacy_key(conversation.account, conversation.counterpart.bare_jid)) {
                    reason = _("This contact has no legacy OpenPGP/XEP-0027 key.");
                    return false;
                }
                if (!db.contact_legacy_key_is_announced(conversation.account, conversation.counterpart.bare_jid)) {
                    reason = _("This contact has a stored legacy OpenPGP/XEP-0027 key, but it is not currently active.");
                    return false;
                }
            }
        } else if (conversation.type_ == Conversation.Type.GROUPCHAT) {
            GPGHelper.Key[] keys;
            try {
                keys = get_key_fprs(conversation);
            } catch (Error e) {
                reason = _("OpenPGP key lookup failed: %s").printf(e.message);
                return false;
            }
            if (keys.length <= 1) {
                reason = _("No OpenPGP keys are available for the group members.");
                return false;
            }
        } else if (conversation.type_ == Conversation.Type.GROUPCHAT_PM) {
            Gee.List<Jid> recipients;
            if (!try_get_private_muc_file_recipient_key_readiness(conversation, out recipients, out reason)) {
                return false;
            }
        }

        return true;
    }

    internal bool try_get_private_muc_file_recipient_candidates(Conversation conversation, out Gee.List<Jid> recipients, out string reason) {
        recipients = new ArrayList<Jid>(Jid.equals_bare_func);
        reason = "";

        if (conversation.type_ == Conversation.Type.GROUPCHAT_PM) {
            Jid? real_jid = get_private_muc_pm_real_recipient_jid(conversation, out reason);
            if (real_jid == null) return false;

            recipients.add(((!) real_jid).bare_jid);
            return true;
        }
        if (conversation.type_ != Conversation.Type.GROUPCHAT) {
            reason = "OpenPGP private-MUC file recipient resolution only applies to groupchat conversations";
            return false;
        }

        MucManager? muc_manager = stream_interactor.get_module<MucManager>(MucManager.IDENTITY);
        if (muc_manager == null) {
            reason = "MUC manager is not available";
            return false;
        }

        if (!((!) muc_manager).has_live_private_room_features(conversation.account, conversation.counterpart)) {
            reason = "OpenPGP MUC file transfers require live private members-only non-anonymous room features";
            return false;
        }

        if (!((!) muc_manager).has_complete_private_muc_affiliation_snapshot(conversation.account, conversation.counterpart)) {
            reason = "OpenPGP private-MUC file transfers require completed member, admin and owner affiliation queries";
            return false;
        }

        Gee.List<Jid>? members = ((!) muc_manager).get_private_muc_member_affiliation_snapshot(conversation.account, conversation.counterpart);
        if (members == null) {
            reason = "OpenPGP private-MUC file transfers require a cached affiliation snapshot";
            return false;
        }

        // Candidate discovery only. A complete affiliation snapshot proves the
        // member/admin/owner lists were refreshed, but not OpenPGP key readiness
        // or group-file-send enablement.
        foreach (Jid member in (!) members) {
            Jid member_bare = member.bare_jid;
            if (member_bare.equals_bare(conversation.account.bare_jid)) continue;
            if (!recipients.contains(member_bare)) recipients.add(member_bare);
        }

        if (recipients.size == 0) {
            reason = "OpenPGP private-MUC file transfers require at least one other known member";
            return false;
        }
        return true;
    }

    private Jid? get_private_muc_pm_real_recipient_jid(Conversation conversation, out string reason) {
        reason = "";

        if (conversation.type_ != Conversation.Type.GROUPCHAT_PM) {
            reason = "OpenPGP MUC-PM file recipient resolution only applies to private MUC message conversations";
            return null;
        }
        if (conversation.counterpart.resourcepart == null || conversation.counterpart.resourcepart == "") {
            reason = "OpenPGP MUC-PM file transfers require a full room/nick recipient JID";
            return null;
        }

        MucManager? muc_manager = stream_interactor.get_module<MucManager>(MucManager.IDENTITY);
        if (muc_manager == null) {
            reason = "MUC manager is not available";
            return null;
        }

        Jid? real_jid = ((!) muc_manager).get_real_jid(conversation.counterpart, conversation.account);
        if (real_jid == null) {
            reason = "OpenPGP MUC-PM file transfers require a cached real JID for the room occupant";
            return null;
        }
        if (!((!) muc_manager).has_live_private_room_features(conversation.account, conversation.counterpart.bare_jid)) {
            reason = "OpenPGP MUC-PM file transfers require live private members-only non-anonymous room features";
            return null;
        }

        Jid recipient_jid = ((!) real_jid).bare_jid;
        if (recipient_jid.equals_bare(conversation.account.bare_jid)) {
            reason = "OpenPGP MUC-PM file transfers must not target the local account JID";
            return null;
        }

        return recipient_jid;
    }

    internal bool try_get_private_muc_file_recipient_key_readiness(Conversation conversation, out Gee.List<Jid> recipients, out string reason) {
        recipients = new ArrayList<Jid>(Jid.equals_bare_func);
        reason = "";

        Gee.List<Jid> candidates;
        if (!try_get_private_muc_file_recipient_candidates(conversation, out candidates, out reason)) {
            return false;
        }

        string account_key_mode = db.get_account_key_mode(conversation.account);
        string? own_key_for_mode = db.get_account_key_for_mode(conversation.account, account_key_mode);
        if (own_key_for_mode == null || ((!) own_key_for_mode).length == 0) {
            reason = account_key_mode == Database.ACCOUNT_KEY_MODE_LEGACY
                ? "OpenPGP private-MUC file transfers require an active legacy OpenPGP/XEP-0027 account key"
                : "OpenPGP private-MUC file transfers require an active OpenPGP-for-XMPP account key";
            return false;
        }

        string missing_keys = "";
        string stale_keys = "";
        string unverified_keys = "";
        string inactive_legacy_keys = "";
        foreach (Jid candidate in candidates) {
            Jid recipient_jid = candidate.bare_jid;
            if (account_key_mode == Database.ACCOUNT_KEY_MODE_XMPP) {
                if (!db.has_contact_xmpp_key(conversation.account, recipient_jid)) {
                    missing_keys = append_private_muc_key_readiness_jid(missing_keys, recipient_jid);
                    continue;
                }
                string trust_reason;
                if (!contact_xmpp_key_is_verified_for_encryption(conversation.account, recipient_jid, out trust_reason)) {
                    unverified_keys = append_private_muc_key_readiness_jid(unverified_keys, recipient_jid);
                    continue;
                }
                if (!contact_xmpp_key_was_refreshed_this_session(conversation.account, recipient_jid)) {
                    stale_keys = append_private_muc_key_readiness_jid(stale_keys, recipient_jid);
                }
            } else {
                if (!db.has_contact_legacy_key(conversation.account, recipient_jid)) {
                    missing_keys = append_private_muc_key_readiness_jid(missing_keys, recipient_jid);
                    continue;
                }
                if (!db.contact_legacy_key_is_announced(conversation.account, recipient_jid)) {
                    inactive_legacy_keys = append_private_muc_key_readiness_jid(inactive_legacy_keys, recipient_jid);
                }
            }
        }

        if (missing_keys.length > 0) {
            reason = account_key_mode == Database.ACCOUNT_KEY_MODE_LEGACY
                ? "OpenPGP private-MUC file transfers require legacy OpenPGP/XEP-0027 keys for all recipients; missing: %s".printf(missing_keys)
                : "OpenPGP private-MUC file transfers require OpenPGP-for-XMPP keys for all recipients; missing: %s".printf(missing_keys);
            return false;
        }
        if (stale_keys.length > 0) {
            reason = "OpenPGP private-MUC file transfers require XEP-0373 contact keys refreshed in this session; stale: %s".printf(stale_keys);
            return false;
        }
        if (unverified_keys.length > 0) {
            reason = "OpenPGP private-MUC file transfers require verified XEP-0373 contact keys; unverified or changed: %s".printf(unverified_keys);
            return false;
        }
        if (inactive_legacy_keys.length > 0) {
            reason = "OpenPGP private-MUC file transfers require currently announced legacy OpenPGP/XEP-0027 keys; inactive: %s".printf(inactive_legacy_keys);
            return false;
        }

        recipients = candidates;
        return true;
    }

    internal GPGHelper.Key[] get_private_muc_file_recipient_key_fprs(Conversation conversation) throws Error {
        Gee.List<Jid> recipients;
        string reason;
        if (!try_get_private_muc_file_recipient_key_readiness(conversation, out recipients, out reason)) {
            throw new IOError.FAILED(reason);
        }

        string account_key_mode = db.get_account_key_mode(conversation.account);
        var key_ids = new Gee.ArrayList<string>();
        string? account_key = db.get_account_key_for_mode(conversation.account, account_key_mode);
        if (account_key == null || ((!) account_key).length == 0) {
            throw new IOError.FAILED("OpenPGP private-MUC file transfers require an account key for the selected mode");
        }
        add_key_id_once(key_ids, (!) account_key);

        foreach (Jid recipient in recipients) {
            Jid recipient_jid = recipient.bare_jid;
            string? key_id = account_key_mode == Database.ACCOUNT_KEY_MODE_LEGACY
                ? db.get_contact_legacy_key(conversation.account, recipient_jid)
                : db.get_contact_xmpp_key(conversation.account, recipient_jid);
            if (key_id == null || ((!) key_id).length == 0) {
                throw new IOError.FAILED("OpenPGP private-MUC file recipient key disappeared for %s".printf(recipient_jid.to_string()));
            }
            add_key_id_once(key_ids, (!) key_id);
        }

        if (key_ids.size <= 1) {
            throw new IOError.FAILED("OpenPGP private-MUC file transfers require at least one non-account recipient key");
        }

        var keys = new Gee.ArrayList<GPGHelper.Key>();
        foreach (string key_id in key_ids) {
            keys.add(new GPGHelper.Key(key_id));
        }
        return key_list_to_array(keys);
    }

    internal Jid get_private_muc_file_body_url_recipient_jid(Conversation conversation) throws Error {
        string reason;
        if (conversation.type_ == Conversation.Type.GROUPCHAT_PM) {
            Jid? real_jid = get_private_muc_pm_real_recipient_jid(conversation, out reason);
            if (real_jid == null) throw new IOError.FAILED(reason);
            return (!) real_jid;
        }
        if (conversation.type_ == Conversation.Type.GROUPCHAT) {
            return conversation.counterpart;
        }

        throw new IOError.FAILED("OpenPGP private-MUC file body URL recipient snapshots require a MUC conversation");
    }

    internal void stage_private_muc_file_body_url_key_material(Conversation conversation, string body_url,
            GPGHelper.Key[] keys, string protocol, Jid recipient_jid) {
        if (body_url.length == 0) return;
        pending_private_muc_file_body_url_keys[build_private_muc_file_body_url_key(conversation, body_url)] =
            new PrivateMucFileBodyUrlKeyMaterial(keys, protocol, recipient_jid);
    }

    private bool consume_private_muc_file_body_url_key_material(Conversation conversation, string body_url,
            out GPGHelper.Key[] keys, out string protocol, out Jid? recipient_jid) {
        keys = new GPGHelper.Key[0];
        protocol = "";
        recipient_jid = null;
        if (body_url.length == 0) return false;

        string map_key = build_private_muc_file_body_url_key(conversation, body_url);
        PrivateMucFileBodyUrlKeyMaterial? material = pending_private_muc_file_body_url_keys.get(map_key);
        if (material == null) return false;

        pending_private_muc_file_body_url_keys.unset(map_key);
        keys = ((!) material).keys;
        protocol = ((!) material).protocol;
        recipient_jid = ((!) material).recipient_jid;
        return true;
    }

    private static string build_private_muc_file_body_url_key(Conversation conversation, string body_url) {
        return "%s\n%s\n%s".printf(
            conversation.account.bare_jid.to_string(),
            conversation.counterpart.to_string(),
            body_url);
    }

    private static string append_private_muc_key_readiness_jid(string existing, Jid jid) {
        if (existing.length == 0) return jid.to_string();
        return existing + ", " + jid.to_string();
    }

    private static void add_key_id_once(Gee.List<string> key_ids, string key_id) {
        if (!key_ids.contains(key_id)) key_ids.add(key_id);
    }

    public async bool refresh_xep0374_support(Account account, Jid jid) {
        var entity_info = stream_interactor.get_module<EntityInfo>(EntityInfo.IDENTITY);
        if (entity_info == null) return false;

        if (yield entity_info.has_feature(account, jid.bare_jid, NS_OPENPGP_IM)) {
            update_xep0374_support(account, jid.bare_jid, true);
            return true;
        }

        var presence_manager = stream_interactor.get_module<PresenceManager>(PresenceManager.IDENTITY);
        Gee.List<Jid>? full_jids = presence_manager != null ? presence_manager.get_full_jids(jid.bare_jid, account) : null;
        if (full_jids != null) {
            foreach (Jid full_jid in full_jids) {
                if (yield entity_info.has_feature(account, full_jid, NS_OPENPGP_IM)) {
                    update_xep0374_support(account, jid.bare_jid, true);
                    return true;
                }
            }
        }

        update_xep0374_support(account, jid.bare_jid, false);
        return false;
    }

    private void update_xep0374_support(Account account, Jid jid, bool supports) {
        bool previous_supports = db.contact_supports_xep0374(account, jid.bare_jid);
        db.set_contact_supports_xep0374(account, jid.bare_jid, supports);
        if (previous_supports != supports) {
            key_state_changed(account, jid.bare_jid);
            refresh_active_openpgp_conversations(account, jid.bare_jid);
        }
    }
    
    /**
     * Get a cached key, returns null if not in cache or invalid
     */
    private GPGHelper.Key? get_cached_key(string key_id) {
        key_cache_mutex.lock();
        GPGHelper.Key? key = null;
        if (key_cache.has_key(key_id)) {
            key = key_cache[key_id];
        }
        key_cache_mutex.unlock();
        return key;
    }
    
    /**
     * Check if a key is in the cache
     */
    private bool is_key_cached(string key_id) {
        key_cache_mutex.lock();
        bool has = key_cache.has_key(key_id);
        key_cache_mutex.unlock();
        return has;
    }
    
    /**
     * Add a key to the cache (can be null for invalid keys)
     */
    public void cache_key(string key_id, GPGHelper.Key? key) {
        key_cache_mutex.lock();
        key_cache[key_id] = key;
        key_cache_mutex.unlock();
        if (key != null) {
            debug("OpenPGP: Cached key %s (fpr: %s)", key_id, key.fpr);
        } else {
            debug("OpenPGP: Cached null for key %s (invalid)", key_id);
        }
    }
    
    /**
     * Pre-load a key into cache in background thread
     */
    public void preload_key_async(string key_id) {
        if (is_key_cached(key_id)) return;
        
        string key_id_copy = key_id;
        new Thread<void*>("openpgp-preload-key", () => {
            try {
                var key = GPGHelper.get_public_key(key_id_copy);
                cache_key(key_id_copy, key);
            } catch (Error e) {
                debug("OpenPGP: Failed to preload key %s: %s", key_id_copy, e.message);
                cache_key(key_id_copy, null);
            }
            return null;
        });
    }

    public GPGHelper.Key[] get_key_fprs(Conversation conversation) throws Error {
        if (conversation == null) {
            throw new IOError.FAILED("No conversation provided");
        }

        if (conversation.type_ == Conversation.Type.GROUPCHAT) {
            return get_private_muc_file_recipient_key_fprs(conversation);
        }
        
        Gee.List<string> keys = new Gee.ArrayList<string>();
        
        string account_key_mode = db.get_account_key_mode(conversation.account);
        string? account_key = db.get_account_key_for_mode(conversation.account, account_key_mode);
        if (account_key != null) {
            keys.add(account_key);
            debug("OpenPGP get_key_fprs: Added account key %s for mode %s", account_key, account_key_mode);
        } else {
            debug("OpenPGP get_key_fprs: No account key configured for mode %s!", account_key_mode);
        }
        
        string? contact_key_id = get_key_id(conversation.account, conversation.counterpart);
        if (contact_key_id != null) {
            keys.add(contact_key_id);
            debug("OpenPGP get_key_fprs: Added contact key %s for %s", contact_key_id, conversation.counterpart.to_string());
        } else {
            debug("OpenPGP get_key_fprs: No contact key for %s!", conversation.counterpart.to_string());
        }
        
        debug("OpenPGP get_key_fprs: Total %d key IDs to encrypt to", keys.size);
        
        // Build array of Key objects for encryption.
        // Use cached keys when available, otherwise construct Key directly from
        // the DB key ID. GPG accepts fingerprints, long key IDs, and short key
        // IDs as -r recipient identifiers, so a full key listing round-trip
        // through the worker queue is NOT needed at send time.
        //
        // The cache is only an optimization. It must not be authoritative for
        // sending, because a transient startup/import/GPG-agent failure can cache
        // a null key while the key is already present by the time the user sends.
        // Let the final GPG encrypt call validate the configured fingerprints.
        var valid_keys = new Gee.ArrayList<GPGHelper.Key>();
        
        foreach (string key_id in keys) {
            GPGHelper.Key? key = get_cached_key(key_id);
            if (key != null) {
                valid_keys.add(key);
                debug("OpenPGP get_key_fprs: Got cached key %s", key.fpr);
            } else {
                // Not in cache, or cached as null after a transient failure:
                // construct Key directly from the DB key ID.
                // GPG will validate the key during encryption; if the key does
                // not exist in the keyring, encryption will fail and the message
                // will be marked WONTSEND with the real GPG error.
                key = new GPGHelper.Key(key_id);
                valid_keys.add(key);
                if (is_key_cached(key_id)) {
                    debug("OpenPGP get_key_fprs: Key %s cached as invalid, retrying directly for send", key_id);
                } else {
                    debug("OpenPGP get_key_fprs: Using key ID %s directly (cache cold)", key_id);
                    // Start background preload so the full Key is cached for next time.
                    preload_key_async(key_id);
                }
            }
        }

        debug("OpenPGP get_key_fprs: Returning %d valid keys", valid_keys.size);
        return key_list_to_array(valid_keys);
    }

    private static GPGHelper.Key[] key_list_to_array(Gee.List<GPGHelper.Key> keys) {
        GPGHelper.Key[] ret = new GPGHelper.Key[keys.size];
        int i = 0;
        foreach (GPGHelper.Key key in keys) {
            ret[i++] = key;
        }
        return ret;
    }

    internal void pre_message_send_for_tests(Entities.Message message, Xmpp.MessageStanza message_stanza, Conversation conversation) {
        check_encypt(message, message_stanza, conversation);
    }

    private void check_encypt(Entities.Message message, Xmpp.MessageStanza message_stanza, Conversation conversation) {
        debug("OpenPGP check_encypt: message.encryption=%d, PGP=%d, to=%s", 
              (int)message.encryption, (int)Encryption.PGP, conversation.counterpart.to_string());
        try {
            if (message.encryption == Encryption.PGP) {
                debug("OpenPGP check_encypt: Encryption IS PGP, getting keys...");
                GPGHelper.Key[] keys;
                string private_muc_file_protocol = "";
                Jid? private_muc_file_recipient_jid = null;
                bool private_muc_file_body_url = false;
                if (conversation.type_ == Conversation.Type.GROUPCHAT ||
                        conversation.type_ == Conversation.Type.GROUPCHAT_PM) {
                    string body_url = message.body ?? "";
                    if (consume_private_muc_file_body_url_key_material(conversation, body_url, out keys,
                            out private_muc_file_protocol, out private_muc_file_recipient_jid)) {
                        private_muc_file_body_url = true;
                    } else if (conversation.type_ == Conversation.Type.GROUPCHAT) {
                        warning("OpenPGP send blocked: private-MUC file body URL key material missing account=%s counterpart=%s stanza=%s",
                                conversation.account.bare_jid.to_string(), conversation.counterpart.to_string(), message.stanza_id);
                        message.marked = Entities.Message.Marked.WONTSEND;
                        return;
                    } else {
                        keys = get_key_fprs(conversation);
                    }
                } else {
                    keys = get_key_fprs(conversation);
                }
                debug("OpenPGP check_encypt: Got %d keys to encrypt to", keys.length);
                foreach (var k in keys) {
                    debug("OpenPGP check_encypt: -> Key: %s (uid: %s)", k.fpr, k.uid ?? "none");
                }
                if (keys.length == 0) {
                    warning("OpenPGP send blocked: no recipient keys for account=%s counterpart=%s stanza=%s",
                            conversation.account.bare_jid.to_string(), conversation.counterpart.to_string(), message.stanza_id);
                }
                XmppStream? stream = stream_interactor.get_stream(conversation.account);
                if (stream != null) {
                    bool encrypted = false;
                    string account_key_mode = db.get_account_key_mode(conversation.account);
                    if (private_muc_file_body_url) {
                        Module? openpgp_module = stream.get_module<Module>(Module.IDENTITY);
                        if (openpgp_module == null) {
                            warning("OpenPGP send blocked: stream OpenPGP module is missing for private-MUC file message account=%s stanza=%s",
                                    conversation.account.bare_jid.to_string(), message.stanza_id);
                            message.marked = Entities.Message.Marked.WONTSEND;
                            return;
                        }

                        if (private_muc_file_protocol == FILE_PROTOCOL_XEP0374) {
                            if (private_muc_file_recipient_jid == null) {
                                warning("OpenPGP send blocked: private-MUC file body URL recipient snapshot missing account=%s counterpart=%s stanza=%s",
                                        conversation.account.bare_jid.to_string(), conversation.counterpart.to_string(), message.stanza_id);
                                message.marked = Entities.Message.Marked.WONTSEND;
                                return;
                            }
                            encrypted = openpgp_module.encrypt_0374(message_stanza, (!) private_muc_file_recipient_jid, keys);
                            if (encrypted) {
                                message.encryption_protocol = FILE_PROTOCOL_XEP0374;
                                debug("OpenPGP: Private-MUC file body URL encrypted with XEP-0374 format to %s", ((!) private_muc_file_recipient_jid).to_string());
                            }
                        } else if (private_muc_file_protocol == FILE_PROTOCOL_XEP0027) {
                            encrypted = openpgp_module.encrypt(message_stanza, keys);
                            if (encrypted) {
                                message.encryption_protocol = FILE_PROTOCOL_XEP0027;
                                debug("OpenPGP: Private-MUC file body URL encrypted with XEP-0027 format to %s", conversation.counterpart.to_string());
                            }
                        } else {
                            warning("OpenPGP send blocked: private-MUC file body URL has unknown protocol snapshot account=%s counterpart=%s protocol=%s stanza=%s",
                                    conversation.account.bare_jid.to_string(), conversation.counterpart.to_string(),
                                    private_muc_file_protocol, message.stanza_id);
                            message.marked = Entities.Message.Marked.WONTSEND;
                            return;
                        }

                        if (!encrypted) {
                            warning("OpenPGP send blocked: private-MUC file body URL encryption failed account=%s counterpart=%s keys=%d stanza=%s",
                                    conversation.account.bare_jid.to_string(), conversation.counterpart.to_string(), keys.length, message.stanza_id);
                            message.marked = Entities.Message.Marked.WONTSEND;
                        }
                        return;
                    }

                    string? own_key_for_mode = db.get_account_key_for_mode(conversation.account, account_key_mode);
                    bool must_use_0374 = contact_key_requires_xep0374(conversation.account, conversation.counterpart);
                    bool has_matching_recipient_key = account_key_mode == Database.ACCOUNT_KEY_MODE_XMPP
                        ? must_use_0374
                        : contact_key_allows_legacy(conversation.account, conversation.counterpart);
                    
                    // Check if contact supports XEP-0374 via Service Discovery cache
                    bool supports_0374 = check_xep0374_support(conversation.account, conversation.counterpart);

                    if (own_key_for_mode == null || own_key_for_mode.length == 0) {
                        warning("OpenPGP send blocked: no own account key for selected OpenPGP mode account=%s mode=%s stanza=%s",
                                conversation.account.bare_jid.to_string(), account_key_mode, message.stanza_id);
                        message.marked = Entities.Message.Marked.WONTSEND;
                        return;
                    }

                    string own_key_reason;
                    if (!account_key_is_valid_for_mode(conversation.account, account_key_mode, (!) own_key_for_mode, out own_key_reason)) {
                        warning("OpenPGP send blocked: invalid own account key for selected mode account=%s mode=%s key=%s reason=%s stanza=%s",
                                conversation.account.bare_jid.to_string(), account_key_mode, (!) own_key_for_mode, own_key_reason, message.stanza_id);
                        message.marked = Entities.Message.Marked.WONTSEND;
                        return;
                    }

                    if (!has_matching_recipient_key) {
                        warning("OpenPGP send blocked: no recipient key for selected OpenPGP mode account=%s counterpart=%s mode=%s stanza=%s",
                                conversation.account.bare_jid.to_string(), conversation.counterpart.to_string(), account_key_mode, message.stanza_id);
                        message.marked = Entities.Message.Marked.WONTSEND;
                        return;
                    }

                    if (account_key_mode == Database.ACCOUNT_KEY_MODE_XMPP) {
                        if (conversation.type_ == Conversation.Type.CHAT) {
                            string trust_reason;
                            if (!contact_xmpp_key_is_verified_for_encryption(conversation.account, conversation.counterpart.bare_jid, out trust_reason)) {
                                warning("OpenPGP send blocked: XEP-0373 contact key is not verified account=%s counterpart=%s reason=%s stanza=%s",
                                        conversation.account.bare_jid.to_string(), conversation.counterpart.to_string(), trust_reason, message.stanza_id);
                                message.marked = Entities.Message.Marked.WONTSEND;
                                return;
                            }
                        }
                        if (conversation.type_ == Conversation.Type.CHAT &&
                                !contact_xmpp_key_was_refreshed_this_session(conversation.account, conversation.counterpart)) {
                            warning("OpenPGP send blocked: XEP-0373 contact key has not been refreshed this session account=%s counterpart=%s stanza=%s",
                                    conversation.account.bare_jid.to_string(), conversation.counterpart.to_string(), message.stanza_id);
                            if (xep0373_manager != null) {
                                xep0373_manager.request_keys_if_needed.begin(conversation.account, conversation.counterpart.bare_jid);
                            }
                            message.marked = Entities.Message.Marked.WONTSEND;
                            return;
                        }

                        if (!(supports_0374 || must_use_0374)) {
                            warning("OpenPGP send blocked: account is configured for OpenPGP for XMPP but counterpart has no XEP-0373/0374 key account=%s counterpart=%s stanza=%s",
                                    conversation.account.bare_jid.to_string(), conversation.counterpart.to_string(), message.stanza_id);
                            message.marked = Entities.Message.Marked.WONTSEND;
                            return;
                        }

                        // Use XEP-0374 format (signcrypt) - modern, more secure
                        Module? openpgp_module = stream.get_module<Module>(Module.IDENTITY);
                        if (openpgp_module == null) {
                            warning("OpenPGP send blocked: stream OpenPGP module is missing for account=%s stanza=%s",
                                    conversation.account.bare_jid.to_string(), message.stanza_id);
                            message.marked = Entities.Message.Marked.WONTSEND;
                            return;
                        }
                        encrypted = openpgp_module.encrypt_0374(message_stanza, conversation.counterpart, keys);
                        if (encrypted) {
                            message.encryption_protocol = FILE_PROTOCOL_XEP0374;
                            debug("OpenPGP: Message encrypted with XEP-0374 format (signcrypt) to %s", conversation.counterpart.to_string());
                        } else {
                            warning("OpenPGP send blocked: XEP-0374 encryption failed for account=%s counterpart=%s keys=%d supports_0374=%s requires_0374=%s stanza=%s",
                                    conversation.account.bare_jid.to_string(), conversation.counterpart.to_string(), keys.length,
                                    supports_0374.to_string(), must_use_0374.to_string(), message.stanza_id);
                            message.marked = Entities.Message.Marked.WONTSEND;
                            return;
                        }
                    } else {
                        if (!contact_key_allows_legacy(conversation.account, conversation.counterpart)) {
                            warning("OpenPGP send blocked: account is configured for legacy XEP-0027 but counterpart only has an OpenPGP-for-XMPP key account=%s counterpart=%s stanza=%s",
                                    conversation.account.bare_jid.to_string(), conversation.counterpart.to_string(), message.stanza_id);
                            message.marked = Entities.Message.Marked.WONTSEND;
                            return;
                        }

                        // Fall back to XEP-0027 format (legacy) - widely supported
                        Module? openpgp_module = stream.get_module<Module>(Module.IDENTITY);
                        if (openpgp_module == null) {
                            warning("OpenPGP send blocked: stream OpenPGP module is missing for legacy fallback account=%s stanza=%s",
                                    conversation.account.bare_jid.to_string(), message.stanza_id);
                            message.marked = Entities.Message.Marked.WONTSEND;
                            return;
                        }
                        encrypted = openpgp_module.encrypt(message_stanza, keys);
                        if (encrypted) {
                            message.encryption_protocol = FILE_PROTOCOL_XEP0027;
                            debug("OpenPGP: Message encrypted with XEP-0027 format (legacy) to %s", conversation.counterpart.to_string());
                        }
                    }
                    
                    if (!encrypted) {
                        warning("OpenPGP send blocked: encryption failed for account=%s counterpart=%s keys=%d stanza=%s",
                                conversation.account.bare_jid.to_string(), conversation.counterpart.to_string(), keys.length, message.stanza_id);
                        message.marked = Entities.Message.Marked.WONTSEND;
                    }
                } else {
                    warning("OpenPGP send blocked: no stream for account=%s stanza=%s",
                            conversation.account.bare_jid.to_string(), message.stanza_id);
                }
            }
        } catch (Error e) {
            warning("OpenPGP send blocked: exception while encrypting stanza=%s: %s", message.stanza_id, e.message);
            message.marked = Entities.Message.Marked.WONTSEND;
        }
    }

    public string? get_key_id(Account account, Jid jid) {
        Jid search_jid = is_groupchat_occupant(jid, account) ? jid : jid.bare_jid;
        string account_key_mode = db.get_account_key_mode(account);
        string? key_id = db.get_contact_key_for_mode(account, search_jid, account_key_mode);
        if (key_id != null && account_key_mode == Database.ACCOUNT_KEY_MODE_LEGACY && !legacy_key_has_email_uid((!) key_id)) {
            debug("OpenPGP: Ignoring legacy key %s for %s because it has no email user ID",
                    (!) key_id, search_jid.to_string());
            key_id = null;
        }
        if (key_id != null && account_key_mode == Database.ACCOUNT_KEY_MODE_LEGACY && !db.contact_legacy_key_is_announced(account, search_jid)) {
            debug("OpenPGP: Ignoring stored legacy key %s for %s because it is not currently active",
                    (!) key_id, search_jid.to_string());
            key_id = null;
        }
        if (key_id != null && account_key_mode == Database.ACCOUNT_KEY_MODE_XMPP &&
                !db.contact_xmpp_key_is_verified(account, search_jid)) {
            debug("OpenPGP: Ignoring XMPP key %s for %s because it is not verified",
                    (!) key_id, search_jid.to_string());
            return null;
        }
        
        // If no XMPP key is found locally while the account is configured for
        // OpenPGP for XMPP, try to fetch it via XEP-0373 (PubSub).
        if (key_id == null && account_key_mode == Database.ACCOUNT_KEY_MODE_XMPP && xep0373_manager != null) {
            debug("OpenPGP: No local key for %s, requesting via XEP-0373", search_jid.to_string());
            xep0373_manager.request_keys_if_needed.begin(account, search_jid);
            // Note: This is async, so the key won't be immediately available.
            // The user may need to retry or the next message will use the fetched key.
        }
        
        return key_id;
    }

    private bool contact_xmpp_key_is_verified_for_encryption(Account account, Jid jid, out string reason) {
        reason = "";
        Jid search_jid = get_contact_storage_jid(account, jid);
        if (db.contact_xmpp_key_is_verified(account, search_jid)) return true;

        string trust_state = db.get_contact_xmpp_trust_state(account, search_jid);
        reason = trust_state == Database.XMPP_TRUST_CHANGED
            ? _("This contact's OpenPGP-for-XMPP key changed. Verify the fingerprint in contact details before sending.")
            : _("This contact's OpenPGP-for-XMPP key is not verified. Verify the fingerprint in contact details before sending.");
        return false;
    }

    private void on_account_added(Account account) {
        stream_interactor.module_manager.get_module<Module>(account, Module.IDENTITY).received_jid_key_id.connect((stream, jid, key_id) => {
            on_jid_key_received(account, jid, key_id);
        });
        stream_interactor.module_manager.get_module<Module>(account, Module.IDENTITY).received_jid_without_legacy_key.connect((stream, jid) => {
            on_jid_without_legacy_key(account, jid);
        });
        stream_interactor.module_manager.get_module<Module>(account, Module.IDENTITY).legacy_presence_state_reset.connect((stream) => {
            reset_legacy_presence_state(account);
        });
    }

    private void on_jid_key_received(Account account, Jid jid, string key_id) {
        bool is_new_key = false;
        Jid set_jid = get_contact_storage_jid(account, jid);
        lock (pgp_key_ids) {
            string token = get_pgp_key_token(account, jid);
            if (!pgp_key_ids.has_key(token) || pgp_key_ids[token] != key_id) {
                is_new_key = true;
            }
            pgp_key_ids[token] = key_id;
            legacy_presence_key_ids[get_legacy_presence_resource_token(account, jid)] = key_id;
        }

        if (db.contact_legacy_key_matches(account, set_jid, key_id)) {
            db.set_contact_legacy_key_announced(account, set_jid, true);
            notify_key_state_changed(account, set_jid);
        }
        
        // If we got a new key_id from presence, check if we already have it in the GPG keyring.
        // If not, try to download it from a keyserver automatically.
        if (is_new_key || !db.contact_legacy_key_matches(account, set_jid, key_id)) {
            string key_id_copy = key_id;
            Jid jid_copy = jid;
            Jid set_jid_copy = set_jid;
            new Thread<void*>("auto-fetch-pgp-key", () => {
                try {
                    // First check if we already have this key
                    GPGHelper.Key? existing = GPGHelper.get_public_key(key_id_copy);
                    if (existing != null) {
                        debug("OpenPGP: Key %s for %s already in keyring", key_id_copy, jid_copy.to_string());
                        // Cache it for fast access
                        Idle.add(() => {
                            cache_key(key_id_copy, existing);
                            cache_key(existing.fpr, existing);
                            if (legacy_key_has_email_uid(existing.fpr)) {
                                bool still_announced = legacy_presence_resource_still_announces(account, jid_copy, key_id_copy);
                                db.set_contact_key(account, set_jid_copy, existing.fpr,
                                        still_announced ? Database.KEY_SOURCE_XEP0027 : Database.KEY_SOURCE_KEYSERVER,
                                        false, still_announced);
                                notify_key_state_changed(account, set_jid_copy);
                            } else {
                                debug("OpenPGP: Refusing legacy presence key %s for %s: no email user ID",
                                        existing.fpr, set_jid_copy.to_string());
                                on_jid_without_legacy_key(account, jid_copy);
                            }
                            return false;
                        });
                        return null;
                    }
                } catch (Error e) {
                    // Key not found locally — that's expected, try keyserver
                    debug("OpenPGP: Key %s not in keyring: %s", key_id_copy, e.message);
                }
                
                // Key not in keyring — try to download from keyserver
                debug("OpenPGP: Auto-fetching key %s for %s from keyserver", key_id_copy, jid_copy.to_string());
                try {
                    bool found = GPGHelper.download_key_from_keyserver(key_id_copy);
                    if (found) {
                        debug("OpenPGP: Auto-fetched key %s for %s from keyserver!", key_id_copy, jid_copy.to_string());
                        GPGHelper.invalidate_secret_keys_cache();
                        
                        // Cache the newly imported key and notify UI
                        Idle.add(() => {
                            try {
                                GPGHelper.Key? key = GPGHelper.get_public_key(key_id_copy);
                                cache_key(key_id_copy, key);
                                if (key != null) {
                                    cache_key(key.fpr, key);
                                    if (legacy_key_has_email_uid(key.fpr)) {
                                        bool still_announced = legacy_presence_resource_still_announces(account, jid_copy, key_id_copy);
                                        db.set_contact_key(account, set_jid_copy, key.fpr, Database.KEY_SOURCE_KEYSERVER, false, still_announced);
                                        notify_key_state_changed(account, set_jid_copy);
                                    } else {
                                        debug("OpenPGP: Refusing keyserver key %s for %s: no email user ID",
                                                key.fpr, set_jid_copy.to_string());
                                        on_jid_without_legacy_key(account, jid_copy);
                                    }
                                }
                            } catch (Error e) {
                                debug("OpenPGP: Failed to cache auto-fetched key: %s", e.message);
                            }
                            return false;
                        });
                    } else {
                        debug("OpenPGP: Key %s for %s not found on keyserver", key_id_copy, jid_copy.to_string());
                    }
                } catch (Error e) {
                    debug("OpenPGP: Keyserver fetch failed for %s: %s", key_id_copy, e.message);
                }
                return null;
            });
        }
    }

    private void on_jid_without_legacy_key(Account account, Jid jid) {
        Account account_copy = account;
        Jid jid_copy = jid;
        Idle.add(() => {
            process_jid_without_legacy_key(account_copy, jid_copy);
            return Source.REMOVE;
        });
    }

    private void process_jid_without_legacy_key(Account account, Jid jid) {
        Jid set_jid = get_contact_storage_jid(account, jid);
        bool any_resource_announces;
        lock (pgp_key_ids) {
            pgp_key_ids.unset(get_pgp_key_token(account, jid));
            legacy_presence_key_ids.unset(get_legacy_presence_resource_token(account, jid));
            prune_stale_legacy_presence_resources_locked(account, jid);
            any_resource_announces = has_legacy_presence_resource(account, jid);
        }
        if (!any_resource_announces) {
            db.set_contact_legacy_key_announced(account, set_jid, false);
            notify_key_state_changed(account, set_jid);
        }
    }

    private class ReceivedMessageListener : MessageListener {

        public string[] after_actions_const = new string[]{ };
        public override string action_group { get { return "DECRYPT"; } }
        public override string[] after_actions { get { return after_actions_const; } }

        public override async bool run(Entities.Message message, Xmpp.MessageStanza stanza, Conversation conversation) {
            if (MessageFlag.get_flag(stanza) != null && MessageFlag.get_flag(stanza).decrypted) {
                message.encryption = Encryption.PGP;
                message.encryption_protocol = MessageFlag.get_flag(stanza).protocol;
            }
            return false;
        }
    }
}

}

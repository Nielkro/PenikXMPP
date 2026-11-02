using Dino.Entities;
using Gtk;
using Qlite;
using Xmpp;

namespace Dino.Plugins.Omemo {

// Helper function for async sleep
private async void sleep_async(uint milliseconds) {
    Timeout.add(milliseconds, () => {
        sleep_async.callback();
        return false;
    });
    yield;
}

public class EncryptionListEntry : Plugins.EncryptionListEntry, Object {
    private Plugin plugin;
    private Database db;

    public EncryptionListEntry(Plugin plugin) {
        this.plugin = plugin;
        this.db = plugin.db;
    }

    public Entities.Encryption encryption { get {
        return Entities.Encryption.OMEMO;
    }}

    public string name { get {
        return "OMEMO";
    }}

    public Plugins.ConversationEncryptionTrust get_conversation_trust(Entities.Conversation conversation) {
        if (conversation.account.id <= 0) return Plugins.ConversationEncryptionTrust.UNKNOWN;
        var recipients = new Gee.HashSet<Jid>(Jid.hash_bare_func, Jid.equals_bare_func);
        if (conversation.type_ == Conversation.Type.CHAT) {
            recipients.add(conversation.counterpart.bare_jid);
        } else if (conversation.type_ == Conversation.Type.GROUPCHAT) {
            Dino.Application? app = plugin.app;
            if (app == null) return Plugins.ConversationEncryptionTrust.UNKNOWN;
            var muc = app.stream_interactor.get_module<MucManager>(MucManager.IDENTITY);
            if (muc == null || !muc.has_live_private_room_features(conversation.account, conversation.counterpart) ||
                    !muc.has_complete_private_muc_affiliation_snapshot(conversation.account, conversation.counterpart)) {
                return Plugins.ConversationEncryptionTrust.UNKNOWN;
            }
            Gee.List<Jid>? members = muc.get_private_muc_member_affiliation_snapshot(
                conversation.account, conversation.counterpart);
            if (members == null) return Plugins.ConversationEncryptionTrust.UNKNOWN;
            foreach (Jid member in members) {
                if (!member.equals_bare(conversation.account.bare_jid)) recipients.add(member.bare_jid);
            }
            // An empty or own-only room cannot prove another identity's trust.
            if (recipients.size == 0) return Plugins.ConversationEncryptionTrust.UNKNOWN;
        } else {
            return Plugins.ConversationEncryptionTrust.UNKNOWN;
        }

        try {
            Row? identity = db.identity.select().with(db.identity.account_id, "=", conversation.account.id)
                .single().iterator().get_next_checked();
            if (identity == null) return Plugins.ConversationEncryptionTrust.UNKNOWN;
            int identity_id = ((!) identity)[db.identity.id];
            int own_device_id = ((!) identity)[db.identity.device_id];
            if (identity_id <= 0) return Plugins.ConversationEncryptionTrust.UNKNOWN;

            bool all_verified = true;
            bool needs_attention = false;
            bool complete = true;
            foreach (Jid recipient in recipients) {
                if (accumulate_cached_device_trust(conversation.account, identity_id, own_device_id, recipient,
                        ref all_verified, ref needs_attention) == 0) complete = false;
            }
            // Include known active other devices of our account. An absent own
            // list is not evidence of freshness; this API reports cached trust
            // only and deliberately never requests a device list or bundle.
            if (!recipients.contains(conversation.account.bare_jid)) {
                accumulate_cached_device_trust(conversation.account, identity_id, own_device_id,
                    conversation.account.bare_jid, ref all_verified, ref needs_attention);
            }
            if (needs_attention) return Plugins.ConversationEncryptionTrust.NEEDS_ATTENTION;
            if (!complete) return Plugins.ConversationEncryptionTrust.UNKNOWN;
            return all_verified ? Plugins.ConversationEncryptionTrust.VERIFIED : Plugins.ConversationEncryptionTrust.TRUSTED;
        } catch (Error e) {
            return Plugins.ConversationEncryptionTrust.UNKNOWN;
        }
    }

    private int accumulate_cached_device_trust(Account account, int identity_id, int own_device_id,
            Jid jid, ref bool all_verified, ref bool needs_attention) throws Error {
        int count = 0;
        var iterator = db.identity_meta.with_address(identity_id, jid.bare_jid.to_string())
            .with(db.identity_meta.now_active, "=", true).iterator();
        Row? device;
        while ((device = iterator.get_next_checked()) != null) {
            Row row = (!) device;
            if (jid.equals_bare(account.bare_jid) && row[db.identity_meta.device_id] == own_device_id) continue;
            count++;
            string? key = row[db.identity_meta.identity_key_public_base64];
            TrustLevel trust = (TrustLevel) row[db.identity_meta.trust_level];
            if (key == null || key.length == 0 || row[db.identity_meta.identity_key_changed] ||
                    (trust != TrustLevel.TRUSTED && trust != TrustLevel.VERIFIED)) needs_attention = true;
            if (trust != TrustLevel.VERIFIED) all_verified = false;
        }
        return count;
    }

    public Object? get_encryption_icon(Entities.Conversation conversation, ContentItem content_item) {
        return null;
    }

    public string? get_encryption_icon_name(Entities.Conversation conversation, ContentItem content_item) {
        if (content_item.encryption != encryption) return null;

        int identity_id = db.identity.get_id(conversation.account.id);
        if (identity_id <= 0) return null;
        RowOption row = db.content_item_meta.select( { db.identity_meta.trust_level } ).with(db.content_item_meta.content_item_id, "=", content_item.id)
            .with(db.content_item_meta.identity_id, "=", identity_id)
            .join_on(db.identity_meta, @"$(db.identity_meta.identity_id)=$(db.content_item_meta.identity_id) AND $(db.identity_meta.address_name)=$(db.content_item_meta.address_name) AND $(db.identity_meta.device_id)=$(db.content_item_meta.device_id) AND $(db.identity_meta.identity_key_public_base64)=$(db.content_item_meta.key_public)")
            .single().row();


        if (row.is_present() && (TrustLevel) row[db.identity_meta.trust_level] == TrustLevel.VERIFIED) {
            return "dino-security-high-symbolic";
        }
        return null;
    }

    public void encryption_activated(Entities.Conversation conversation, owned Plugins.SetInputFieldStatus input_status_callback) {
        encryption_activated_async.begin(conversation, (owned) input_status_callback);
    }

    internal static Plugins.InputFieldStatus private_muc_verification_input_status() {
        return new Plugins.InputFieldStatus(
            _("Verifying private room members…"),
            Plugins.InputFieldStatus.MessageType.INFO,
            Plugins.InputFieldStatus.InputState.NO_SEND);
    }

    internal static Plugins.InputFieldStatus private_muc_ready_input_status() {
        return new Plugins.InputFieldStatus("",
            Plugins.InputFieldStatus.MessageType.NONE,
            Plugins.InputFieldStatus.InputState.NORMAL);
    }

    public async void encryption_activated_async(Entities.Conversation conversation, owned Plugins.SetInputFieldStatus input_status_callback) {
        if (conversation.type_ == Conversation.Type.GROUPCHAT_PM) {
            input_status_callback(new Plugins.InputFieldStatus(_("Can't use encryption in a groupchat private message."), Plugins.InputFieldStatus.MessageType.ERROR, Plugins.InputFieldStatus.InputState.NO_SEND));
            return;
        }
        
        // Check if our own OMEMO identity is initialized
        int identity_id = db.identity.get_id(conversation.account.id);
        if (identity_id < 0) {
            // Identity not yet created - OMEMO is still initializing (e.g. after Panic Wipe)
            input_status_callback(new Plugins.InputFieldStatus(_("OMEMO is initializing, please wait a moment..."), Plugins.InputFieldStatus.MessageType.INFO, Plugins.InputFieldStatus.InputState.NO_SEND));
            
            // Wait for initialization (up to 5 seconds)
            for (int i = 0; i < 10; i++) {
                yield sleep_async(500);
                identity_id = db.identity.get_id(conversation.account.id);
                if (identity_id >= 0) break;
            }
            
            if (identity_id < 0) {
                input_status_callback(new Plugins.InputFieldStatus(_("OMEMO initialization failed. Please try again."), Plugins.InputFieldStatus.MessageType.ERROR, Plugins.InputFieldStatus.InputState.NO_SEND));
                return;
            }
            // Clear the "initializing" message
            input_status_callback(new Plugins.InputFieldStatus("", Plugins.InputFieldStatus.MessageType.NONE, Plugins.InputFieldStatus.InputState.NORMAL));
        }
        
        Manager omemo_manager = plugin.app.stream_interactor.get_module<Manager>(Manager.IDENTITY);

        if (conversation.type_ == Conversation.Type.GROUPCHAT) {
            // Keep the composer closed while the authoritative member snapshot
            // and fresh device lists are being verified. Otherwise a message
            // sent in this window is permanently classified as WONTSEND by the
            // fail-closed send-time guard.
            input_status_callback(private_muc_verification_input_status());
            PrivateMucKeyReadinessResult result = yield omemo_manager
                .ensure_private_muc_keys_for_conversation(conversation);
            string? error = null;
            switch (result.status) {
                case PrivateMucKeyReadinessStatus.READY:
                    input_status_callback(private_muc_ready_input_status());
                    return;
                case PrivateMucKeyReadinessStatus.ROOM_INFO_PENDING:
                    // The join owns the current disco request. Keep the
                    // verification block; room_info_updated will re-run this
                    // check without superseding that request.
                    return;
                case PrivateMucKeyReadinessStatus.NOT_PRIVATE:
                    error = _("OMEMO can't be used in public (non-members-only) rooms.");
                    break;
                case PrivateMucKeyReadinessStatus.NO_OTHER_MEMBER:
                    error = _("No other room members are available for OMEMO encryption.");
                    break;
                case PrivateMucKeyReadinessStatus.MEMBER_UNSUPPORTED:
                    error = _("A member does not support OMEMO: %s").printf(
                        result.member != null
                            ? ((!) result.member).to_string() : "?");
                    break;
                case PrivateMucKeyReadinessStatus.SNAPSHOT_UNAVAILABLE:
                case PrivateMucKeyReadinessStatus.STALE:
                default:
                    error = _("The private room member list could not be verified.");
                    break;
            }
            input_status_callback(new Plugins.InputFieldStatus((!) error,
                Plugins.InputFieldStatus.MessageType.ERROR,
                Plugins.InputFieldStatus.InputState.NO_SEND));
            return;
        }

        if (!(yield omemo_manager.ensure_get_keys_for_jid(conversation.account, conversation.counterpart.bare_jid))) {
            input_status_callback(new Plugins.InputFieldStatus(_("This contact does not support OMEMO encryption"), Plugins.InputFieldStatus.MessageType.ERROR, Plugins.InputFieldStatus.InputState.NO_SEND));
        }
    }

}
}

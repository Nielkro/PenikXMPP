using Gee;
using Gtk;

using Dino.Entities;
using Xmpp;

namespace Dino.Plugins.OpenPgp {

private class EncryptionListEntry : Plugins.EncryptionListEntry, Object {
    private const uint XEP0373_KEY_CHECK_TIMEOUT_SECONDS = 45;

    private StreamInteractor stream_interactor;
    private Database db;
    private Xep0373KeyManager? xep0373_manager = null;

    public EncryptionListEntry(StreamInteractor stream_interactor, Database db) {
        this.stream_interactor = stream_interactor;
        this.db = db;
    }
    
    // Allow plugin to set XEP-0373 manager reference
    public void set_xep0373_manager(Xep0373KeyManager? manager) {
        this.xep0373_manager = manager;
    }

    public Entities.Encryption encryption { get {
        return Encryption.PGP;
    }}

    public string name { get {
        return "OpenPGP";
    }}

    public Plugins.ConversationEncryptionTrust get_conversation_trust(Entities.Conversation conversation) {
        // Group verification has no matching recipient-key aggregate here.
        // Do not call Manager.get_key_id(): it can fetch keys or consult GPG.
        if (conversation.account.id <= 0 || conversation.type_ != Conversation.Type.CHAT) {
            return Plugins.ConversationEncryptionTrust.UNKNOWN;
        }
        Jid jid = conversation.counterpart.bare_jid;
        string mode = db.get_account_key_mode(conversation.account);
        string? key = db.get_contact_key_for_mode(conversation.account, jid, mode);
        if (key == null || key.length == 0) return Plugins.ConversationEncryptionTrust.UNKNOWN;
        if (mode == Database.ACCOUNT_KEY_MODE_LEGACY) {
            // Signed presence/key availability is not manual identity verification.
            return db.contact_legacy_key_is_announced(conversation.account, jid)
                ? Plugins.ConversationEncryptionTrust.TRUSTED : Plugins.ConversationEncryptionTrust.UNKNOWN;
        }
        return db.contact_xmpp_key_is_verified(conversation.account, jid)
            ? Plugins.ConversationEncryptionTrust.VERIFIED : Plugins.ConversationEncryptionTrust.NEEDS_ATTENTION;
    }

    public Object? get_encryption_icon(Entities.Conversation conversation, ContentItem content_item) {
        if (conversation == null) return null;
        return null;
    }

    public string? get_encryption_icon_name(Entities.Conversation conversation, ContentItem content_item) {
        if (conversation == null) return null;
        return null;
    }

    public void encryption_activated(Entities.Conversation conversation, owned Plugins.SetInputFieldStatus input_status_callback) {
        // Null check to prevent assertion failures
        if (conversation == null) {
            input_status_callback(new Plugins.InputFieldStatus(_("No conversation selected."), Plugins.InputFieldStatus.MessageType.ERROR, Plugins.InputFieldStatus.InputState.NO_SEND));
            return;
        }
        
        // Run key checks in background to avoid blocking UI
        string account_key_mode = db.get_account_key_mode(conversation.account);
        string? account_key = db.get_account_key_for_mode(conversation.account, account_key_mode);
        
        if (account_key == null || account_key.length == 0) {
            input_status_callback(new Plugins.InputFieldStatus(_("You didn't configure OpenPGP for this account. You can do that in the Accounts Dialog."), Plugins.InputFieldStatus.MessageType.ERROR, Plugins.InputFieldStatus.InputState.NO_SEND));
            return;
        }
        
        // Only XMPP/OpenPGP account keys are announced through XEP-0373.
        // Legacy XEP-0027 keys are announced by signed presence/keyserver.
        if (account_key_mode == Database.ACCOUNT_KEY_MODE_XMPP && xep0373_manager != null) {
            debug("OpenPGP: Re-publishing own key for encryption activation");
            xep0373_manager.republish_key(conversation.account);
        }

        if (conversation.type_ == Conversation.Type.CHAT) {
            validate_chat_openpgp.begin(conversation, (owned) input_status_callback);
        } else if (conversation.type_ == Conversation.Type.GROUPCHAT) {
            // Run MUC key checks in background thread
            Gee.List<Jid> muc_jids = new Gee.ArrayList<Jid>();
            Gee.List<Jid>? occupants = stream_interactor.get_module<MucManager>(MucManager.IDENTITY).get_occupants(conversation.counterpart, conversation.account);
            if (occupants != null) muc_jids.add_all(occupants);
            Gee.List<Jid>? offline_members = stream_interactor.get_module<MucManager>(MucManager.IDENTITY).get_offline_members(conversation.counterpart, conversation.account);
            if (offline_members != null) muc_jids.add_all(offline_members);

            // Preload account key for MUC
            string? muc_account_key = db.get_account_key_for_mode(conversation.account, db.get_account_key_mode(conversation.account));
            if (muc_account_key != null) {
                var manager = stream_interactor.get_module<Manager>(Manager.IDENTITY);
                if (manager != null) {
                    manager.preload_key_async(muc_account_key);
                }
            }

            // Check MUC member keys in background
            check_muc_keys_async.begin(conversation.account, muc_jids, (owned) input_status_callback);
        }
    }

    private async void validate_chat_openpgp(Entities.Conversation conversation, owned Plugins.SetInputFieldStatus input_status_callback) {
        var manager = stream_interactor.get_module<Manager>(Manager.IDENTITY);
        if (manager == null) {
            input_status_callback(new Plugins.InputFieldStatus(_("OpenPGP manager not available."), Plugins.InputFieldStatus.MessageType.ERROR, Plugins.InputFieldStatus.InputState.NO_SEND));
            return;
        }

        string account_key_mode = db.get_account_key_mode(conversation.account);
        string? key_id = db.get_contact_key_for_mode(conversation.account, conversation.counterpart.bare_jid, account_key_mode);
        if (account_key_mode == Database.ACCOUNT_KEY_MODE_XMPP) {
            if (xep0373_manager == null) {
                input_status_callback(new Plugins.InputFieldStatus(_("OpenPGP-for-XMPP key manager not available."), Plugins.InputFieldStatus.MessageType.ERROR, Plugins.InputFieldStatus.InputState.NO_SEND));
                return;
            }

            if (manager.contact_xmpp_key_was_refreshed_this_session(conversation.account, conversation.counterpart)) {
                key_id = db.get_contact_xmpp_key(conversation.account, conversation.counterpart.bare_jid);
            } else {
                debug("OpenPGP: Refreshing XMPP-published key for %s before selecting message format...", conversation.counterpart.to_string());
                input_status_callback(new Plugins.InputFieldStatus(_("Checking OpenPGP key via PubSub..."), Plugins.InputFieldStatus.MessageType.INFO, Plugins.InputFieldStatus.InputState.NO_SEND));
                bool key_check_finished = false;
                bool key_check_timed_out = false;
                uint timeout_id = 0;
                timeout_id = Timeout.add_seconds(XEP0373_KEY_CHECK_TIMEOUT_SECONDS, () => {
                    if (key_check_finished) return Source.REMOVE;
                    key_check_timed_out = true;
                    timeout_id = 0;
                    input_status_callback(new Plugins.InputFieldStatus(
                        _("Checking the OpenPGP-for-XMPP key via PubSub timed out. Try again, or switch to legacy XEP-0027 if the contact has a keyserver key."),
                        Plugins.InputFieldStatus.MessageType.ERROR,
                        Plugins.InputFieldStatus.InputState.NO_SEND));
                    return Source.REMOVE;
                });
                yield xep0373_manager.request_keys_if_needed(conversation.account, conversation.counterpart.bare_jid);
                key_check_finished = true;
                if (timeout_id != 0) {
                    Source.remove(timeout_id);
                }
                if (key_check_timed_out) return;
                if (!manager.contact_xmpp_key_was_refreshed_this_session(conversation.account, conversation.counterpart)) {
                    input_status_callback(new Plugins.InputFieldStatus(_("This contact's OpenPGP-for-XMPP key has not been refreshed yet. Try again after the contact republishes it, or use the refresh button in contact details."), Plugins.InputFieldStatus.MessageType.ERROR, Plugins.InputFieldStatus.InputState.NO_SEND));
                    return;
                }
                key_id = db.get_contact_xmpp_key(conversation.account, conversation.counterpart.bare_jid);
            }
        }

        if (key_id == null) {
            if (account_key_mode == Database.ACCOUNT_KEY_MODE_LEGACY) {
                input_status_callback(new Plugins.InputFieldStatus(_("This contact has no legacy OpenPGP/XEP-0027 key. Switch your OpenPGP key usage to DinoX / OpenPGP for XMPP."), Plugins.InputFieldStatus.MessageType.ERROR, Plugins.InputFieldStatus.InputState.NO_SEND));
            } else {
                input_status_callback(new Plugins.InputFieldStatus(_("This contact has no OpenPGP-for-XMPP key. Switch to a legacy XEP-0027 key or ask the contact to publish an OpenPGP-for-XMPP key."), Plugins.InputFieldStatus.MessageType.ERROR, Plugins.InputFieldStatus.InputState.NO_SEND));
            }
            return;
        }

        if (account_key_mode == Database.ACCOUNT_KEY_MODE_XMPP &&
                !db.contact_xmpp_key_is_verified(conversation.account, conversation.counterpart.bare_jid)) {
            string trust_state = db.get_contact_xmpp_trust_state(conversation.account, conversation.counterpart.bare_jid);
            input_status_callback(new Plugins.InputFieldStatus(
                trust_state == Database.XMPP_TRUST_CHANGED
                    ? _("This contact's OpenPGP-for-XMPP key changed. Verify the fingerprint in contact details before sending.")
                    : _("This contact's OpenPGP-for-XMPP key is not verified. Verify the fingerprint in contact details before sending."),
                Plugins.InputFieldStatus.MessageType.ERROR,
                Plugins.InputFieldStatus.InputState.NO_SEND));
            return;
        }

        if (account_key_mode == Database.ACCOUNT_KEY_MODE_LEGACY &&
                !db.contact_legacy_key_is_announced(conversation.account, conversation.counterpart.bare_jid)) {
            input_status_callback(new Plugins.InputFieldStatus(_("This contact has a stored legacy OpenPGP/XEP-0027 key, but it is not currently active."), Plugins.InputFieldStatus.MessageType.ERROR, Plugins.InputFieldStatus.InputState.NO_SEND));
            return;
        }

        string key_id_copy = key_id;
        SourceFunc callback = validate_chat_openpgp.callback;
        GPGHelper.Key? key = null;
        new Thread<void*>("openpgp-check-key", () => {
            try {
                key = GPGHelper.get_public_key(key_id_copy);
            } catch (Error e) {
                debug("OpenPGP: Key check failed: %s", e.message);
            }
            Idle.add((owned) callback);
            return null;
        });
        yield;

        manager.cache_key(key_id_copy, key);
        if (key == null) {
            input_status_callback(new Plugins.InputFieldStatus(_("This contact's OpenPGP key is not in your keyring."), Plugins.InputFieldStatus.MessageType.ERROR, Plugins.InputFieldStatus.InputState.NO_SEND));
            return;
        }

        bool supports_0374 = account_key_mode == Database.ACCOUNT_KEY_MODE_XMPP
            ? yield manager.refresh_xep0374_support(conversation.account, conversation.counterpart.bare_jid)
            : false;
        bool known_legacy_contact_key = db.has_contact_legacy_key(conversation.account, conversation.counterpart.bare_jid);
        bool legacy_contact_key_announced = db.contact_legacy_key_is_announced(conversation.account, conversation.counterpart.bare_jid);
        bool known_xmpp_contact_key = db.has_contact_xmpp_key(conversation.account, conversation.counterpart.bare_jid);
        if (account_key_mode == Database.ACCOUNT_KEY_MODE_XMPP && !known_xmpp_contact_key) {
            input_status_callback(new Plugins.InputFieldStatus(_("This contact has no OpenPGP-for-XMPP key. Switch to a legacy XEP-0027 key or ask the contact to publish an OpenPGP-for-XMPP key."), Plugins.InputFieldStatus.MessageType.ERROR, Plugins.InputFieldStatus.InputState.NO_SEND));
            return;
        }
        if (account_key_mode == Database.ACCOUNT_KEY_MODE_LEGACY && !known_legacy_contact_key) {
            input_status_callback(new Plugins.InputFieldStatus(_("This contact has no legacy OpenPGP/XEP-0027 key. Switch your OpenPGP key usage to DinoX / OpenPGP for XMPP."), Plugins.InputFieldStatus.MessageType.ERROR, Plugins.InputFieldStatus.InputState.NO_SEND));
            return;
        }
        if (account_key_mode == Database.ACCOUNT_KEY_MODE_LEGACY && !legacy_contact_key_announced) {
            input_status_callback(new Plugins.InputFieldStatus(_("This contact has a stored legacy OpenPGP/XEP-0027 key, but it is not currently active."), Plugins.InputFieldStatus.MessageType.ERROR, Plugins.InputFieldStatus.InputState.NO_SEND));
            return;
        }

        if (account_key_mode == Database.ACCOUNT_KEY_MODE_XMPP && !supports_0374) {
            debug("OpenPGP: Contact key was fetched via XEP-0373; allowing XEP-0374 send even though disco support is not cached.");
        }

        string ready_message;
        if (account_key_mode == Database.ACCOUNT_KEY_MODE_LEGACY) {
            ready_message = _("Legacy OpenPGP (XEP-0027/keyserver) is active for outgoing messages.");
        } else {
            ready_message = _("OpenPGP for XMPP (XEP-0373/0374) is active for outgoing messages.");
        }
        input_status_callback(new Plugins.InputFieldStatus(ready_message, Plugins.InputFieldStatus.MessageType.INFO, Plugins.InputFieldStatus.InputState.NORMAL));
    }
    
    // Async check MUC member keys
    private async void check_muc_keys_async(Account account, Gee.List<Jid> muc_jids, owned Plugins.SetInputFieldStatus input_status_callback) {
        var manager = stream_interactor.get_module<Manager>(Manager.IDENTITY);
        if (manager == null) {
            input_status_callback(new Plugins.InputFieldStatus(_("OpenPGP manager not available."), Plugins.InputFieldStatus.MessageType.ERROR, Plugins.InputFieldStatus.InputState.NO_SEND));
            return;
        }
        
        // Collect all key IDs first (this is fast, just DB lookup)
        var key_ids_to_check = new Gee.ArrayList<string>();
        foreach (Jid jid in muc_jids) {
            string? key_id = manager.get_key_id(account, jid);
            if (key_id == null) {
                input_status_callback(new Plugins.InputFieldStatus(_("A member's OpenPGP key is not configured: %s").printf(jid.to_string()), Plugins.InputFieldStatus.MessageType.ERROR, Plugins.InputFieldStatus.InputState.NO_SEND));
                return;
            }
            if (!key_ids_to_check.contains(key_id)) {
                key_ids_to_check.add(key_id);
            }
        }
        
        // Check keys in background thread
        new Thread<void*>("openpgp-check-muc-keys", () => {
            string? missing_key = null;
            
            foreach (string key_id in key_ids_to_check) {
                try {
                    var key = GPGHelper.get_public_key(key_id);
                    // Cache the result
                    Idle.add(() => {
                        if (manager != null) {
                            manager.cache_key(key_id, key);
                        }
                        return false;
                    });
                    
                    if (key == null) {
                        missing_key = key_id;
                        break;
                    }
                } catch (Error e) {
                    debug("OpenPGP: Failed to check MUC key %s: %s", key_id, e.message);
                    missing_key = key_id;
                    break;
                }
            }
            
            Idle.add(() => {
                if (missing_key != null) {
                    input_status_callback(new Plugins.InputFieldStatus(_("A member's OpenPGP key is not in your keyring: %s").printf(missing_key), Plugins.InputFieldStatus.MessageType.ERROR, Plugins.InputFieldStatus.InputState.NO_SEND));
                } else {
                    input_status_callback(new Plugins.InputFieldStatus("", Plugins.InputFieldStatus.MessageType.NONE, Plugins.InputFieldStatus.InputState.NORMAL));
                }
                return false;
            });
            
            return null;
        });
    }
    
}

}

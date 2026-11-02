using Gee;

namespace Dino.Plugins {

public class Registry {
    private Object media_message_recorder_provider_lock = new Object();
    private Object media_message_playback_provider_lock = new Object();
    public HashMap<Entities.Encryption, EncryptionListEntry> encryption_list_entries = new HashMap<Entities.Encryption, EncryptionListEntry>();
    public HashMap<string, CallEncryptionEntry> call_encryption_entries = new HashMap<string, CallEncryptionEntry>();
    public ArrayList<AccountSettingsEntry> account_settings_entries = new ArrayList<AccountSettingsEntry>();
    public ArrayList<EncryptionPreferencesEntry> encryption_preferences_entries = new ArrayList<EncryptionPreferencesEntry>();
    public ArrayList<ContactDetailsProvider> contact_details_entries = new ArrayList<ContactDetailsProvider>();
    public Map<string, TextCommand> text_commands = new HashMap<string, TextCommand>();
    public Gee.List<ConversationAdditionPopulator> conversation_addition_populators = new ArrayList<ConversationAdditionPopulator>();
    public Gee.List<NotificationPopulator> notification_populators = new ArrayList<NotificationPopulator>();
    public Gee.List<NetworkStatusProvider> network_status_providers = new ArrayList<NetworkStatusProvider>();
    public Gee.List<AccountRemovalProvider> account_removal_providers = new ArrayList<AccountRemovalProvider>();
    public Gee.Collection<ConversationTitlebarEntry> conversation_titlebar_entries = new Gee.TreeSet<ConversationTitlebarEntry>((a, b) => {
        if (a.id == b.id) return 0;
        if (a.order < b.order) return -1;
        if (a.order > b.order) return 1;
        return a.id.collate(b.id);
    });
    public VideoCallPlugin? video_call_plugin;
    public JmiCallEnginePlugin? jmi_call_engine_plugin;
    public MujiCallEnginePlugin? muji_call_engine_plugin;
    public MediaMessageRecorderProvider? media_message_recorder_provider;
    public MediaMessagePlaybackProvider? media_message_playback_provider;

    public signal void network_status_provider_registered(NetworkStatusProvider provider);
    public signal void media_message_recorder_provider_registered(MediaMessageRecorderProvider provider);
    public signal void media_message_playback_provider_registered(MediaMessagePlaybackProvider provider);
    /** A plugin learned new key material relevant to an encrypted chat. */
    public signal void encryption_readiness_changed(
        Entities.Encryption encryption, Entities.Account account,
        Xmpp.Jid counterpart);
    /** Local trust display changed; null counterpart means the whole account.
     *  Observers must only reread cached trust, never activate encryption. */
    public signal void encryption_trust_changed(
        Entities.Encryption encryption, Entities.Account account,
        Xmpp.Jid? counterpart);

    public bool register_encryption_list_entry(EncryptionListEntry entry) {
        lock(encryption_list_entries) {
            if (encryption_list_entries.has_key(entry.encryption)) return false;

            encryption_list_entries[entry.encryption] = entry;
            return true;
        }
    }

    public bool register_call_entryption_entry(string ns, CallEncryptionEntry entry) {
        lock (call_encryption_entries) {
            call_encryption_entries[ns] = entry;
        }
        return true;
    }

    public bool register_encryption_preferences_entry(EncryptionPreferencesEntry entry) {
        lock(encryption_preferences_entries) {
            foreach(var e in encryption_preferences_entries) {
                if (e.id == entry.id) return false;
            }
            encryption_preferences_entries.add(entry);
            // TODO: Order by priority
//            encryption_preferences_entries.sort((a,b) => b.name.collate(a.name));
            return true;
        }
    }

    public bool register_contact_details_entry(ContactDetailsProvider entry) {
        lock(contact_details_entries) {
            foreach(ContactDetailsProvider e in contact_details_entries) {
                if (e.id == entry.id) return false;
            }
            contact_details_entries.add(entry);
            return true;
        }
    }

    public bool register_contact_titlebar_entry(ConversationTitlebarEntry entry) {
        lock(conversation_titlebar_entries) {
            foreach(ConversationTitlebarEntry e in conversation_titlebar_entries) {
                if (e.id == entry.id) return false;
            }
            conversation_titlebar_entries.add(entry);
            return true;
        }
    }

    public bool register_conversation_addition_populator(ConversationAdditionPopulator populator) {
        lock (conversation_addition_populators) {
            foreach(ConversationItemPopulator p in conversation_addition_populators) {
                if (p.id == populator.id) return false;
            }
            conversation_addition_populators.add(populator);
            return true;
        }
    }

    public bool register_notification_populator(NotificationPopulator populator) {
        lock (notification_populators) {
            foreach(NotificationPopulator p in notification_populators) {
                if (p.id == populator.id) return false;
            }
            notification_populators.add(populator);
            return true;
        }
    }

    public bool register_network_status_provider(NetworkStatusProvider provider) {
        lock (network_status_providers) {
            foreach(NetworkStatusProvider p in network_status_providers) {
                if (p.id == provider.id) return false;
            }
            network_status_providers.add(provider);
        }
        network_status_provider_registered(provider);
        return true;
    }

    public bool register_media_message_recorder_provider(MediaMessageRecorderProvider provider) {
        lock (media_message_recorder_provider_lock) {
            if (media_message_recorder_provider != null) {
                return false;
            }
            media_message_recorder_provider = provider;
        }
        media_message_recorder_provider_registered(provider);
        return true;
    }

    public bool register_media_message_playback_provider(MediaMessagePlaybackProvider provider) {
        lock (media_message_playback_provider_lock) {
            if (media_message_playback_provider != null) return false;
            media_message_playback_provider = provider;
        }
        media_message_playback_provider_registered(provider);
        return true;
    }

    public bool register_account_removal_provider(AccountRemovalProvider provider) {
        lock (account_removal_providers) {
            foreach(AccountRemovalProvider p in account_removal_providers) {
                if (p.id == provider.id) return false;
            }
            account_removal_providers.add(provider);
            return true;
        }
    }
}

}

using Dino.Entities;
using Dino.Security;

namespace Dino {

public string get_version() { return VERSION; }
public string get_short_version() {
    if (!VERSION.contains("~")) return VERSION;
    return VERSION.split("~")[0] + "+";
}

public interface Application : GLib.Application {

    public abstract Database db { get; set; }
    public abstract string? db_key { get; set; }
    public abstract FileEncryption file_encryption { get; set; }
    public abstract Dino.Entities.Settings settings { get; set; }
    public abstract StreamInteractor stream_interactor { get; set; }
    public abstract Plugins.Registry plugin_registry { get; set; }
    public abstract SearchPathGenerator? search_path_generator { get; set; }

    internal static string print_xmpp;
    private static bool core_options_registered = false;

    private const OptionEntry[] options = {
        { "print-xmpp", 0, 0, OptionArg.STRING, ref print_xmpp, "Print XMPP stanzas identified by DESC to stderr", "DESC" },
        { null }
    };

    public abstract void handle_uri(string jid, string query, Gee.Map<string, string> options);

    // UI implementations can exclude asynchronous account removal from a
    // whole-profile backup without changing non-UI/test application behavior.
    public virtual bool begin_account_change() { return true; }
    public virtual void end_account_change() { }

    public signal void configure_preferences(Object dialog);

    /**
     * Emitted when the user opens the MQTT Bot manager for a specific account.
     * The mqtt plugin connects to this signal and presents its dialog.
     *
     * @param account  The XMPP account whose MQTT connection to manage
     * @param window   The parent window (for dialog presentation)
     */
    public signal void open_account_mqtt_manager(Entities.Account account, Object window);

    public void ensure_core_options_registered() {
        if (core_options_registered) return;
        add_main_option_entries(options);
        core_options_registered = true;
    }

    public void init() throws Error {
        ensure_core_options_registered();

        if (DirUtils.create_with_parents(get_storage_dir(), 0700) == -1) {
            throw new Error(-1, 0, "Could not create storage dir \"%s\": %s", get_storage_dir(), FileUtils.error_from_errno(errno).to_string());
        }

        if (this.db_key == null) {
            throw new Error(-1, 0, "Database key missing: DinoX requires a password to open the encrypted database.");
        }

        this.db = new Database(Path.build_filename(get_storage_dir(), "dino.db"), (!)this.db_key);
        this.file_encryption = new FileEncryption(this.db.get_or_create_file_encryption_key((!)this.db_key));
        this.settings = new Dino.Entities.Settings.from_db(db);
        this.stream_interactor = new StreamInteractor(db);

        MessageProcessor.start(stream_interactor, db);
        MessageStorage.start(stream_interactor, db);
        PresenceManager.start(stream_interactor, db);
        BlockingManager.start(stream_interactor);
        Calls.start(stream_interactor, db);
        ConversationManager.start(stream_interactor, db);
        OccupantIdStore.start(stream_interactor, db);
        MucManager.start(stream_interactor, db);
        MucInviteManager.start(stream_interactor);
        MucVoiceRequestManager.start(stream_interactor);
        AvatarManager.start(stream_interactor, db, file_encryption);
        RosterManager.start(stream_interactor, db);
        FileManager.start(stream_interactor, db, file_encryption);
        CallStore.start(stream_interactor, db);
        ContentItemStore.start(stream_interactor, db);
        DisplayedStateManager.start(stream_interactor, settings, db);
        CounterpartInteractionManager.start(stream_interactor);
        ChatInteraction.start(stream_interactor);
        NotificationEvents.start(stream_interactor);
        SearchProcessor.start(stream_interactor, db);
        Register.start(stream_interactor, db);
        InviteManager.start(stream_interactor);
        ServerAdministrationManager.start(stream_interactor);
        EntityInfo.start(stream_interactor, db);
        MucRoomAvatarManager.start(stream_interactor);
        Service.EntityTime.start(stream_interactor, db);
        MessageCorrection.start(stream_interactor, db);
        FileTransferStorage.start(stream_interactor, db);
        Reactions.start(stream_interactor, db);
        Replies.start(stream_interactor, db);
        FallbackBody.start(stream_interactor, db);
        ContactModels.start(stream_interactor);
        MessageDeletion.start(stream_interactor, db);
        StatelessFileSharing.start(stream_interactor, db);
        Stickers.start(stream_interactor, db, file_encryption);
        Feeds.Service.start(stream_interactor, db);

        create_actions();

        // Apply debug log options and restore account connections once the main loop is running.
        stream_interactor.connection_manager.log_options = print_xmpp;
        Idle.add(() => {
            restore();
            return false;
        });

        shutdown.connect(() => {
            stream_interactor.get_module<Feeds.Service>(Feeds.Service.IDENTITY).shutdown();
            stream_interactor.connection_manager.make_offline_all();
            MucManager? muc_manager = stream_interactor.get_module<MucManager>(MucManager.IDENTITY);
            if (muc_manager != null) ((!) muc_manager).shutdown();
        });
        open.connect((files, hint) => {
            if (files.length != 1) {
                warning("Can't handle more than one URI at once.");
                return;
            }
            File file = files[0];
            if (!file.has_uri_scheme("xmpp")) {
                warning("xmpp:-URI expected");
                return;
            }
            string uri = file.get_uri();
            XmppUriInfo? info = parse_xmpp_uri(uri);
            if (info == null) {
                warning("Invalid URI");
                return;
            }
            activate();
            handle_uri(info.jid, info.query, info.options);
        });
    }

    public static string get_storage_dir() {
        return Path.build_filename(Environment.get_user_data_dir(), "dinox");
    }

    public static unowned Application get_default() {
        return (Dino.Application) GLib.Application.get_default();
    }

    public void create_actions() {
        SimpleAction accept_subscription_action = new SimpleAction("accept-subscription", VariantType.INT32);
        accept_subscription_action.activate.connect((variant) => {
            Conversation? conversation = stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY).get_conversation_by_id(variant.get_int32());
            if (conversation == null || conversation.type_ != Conversation.Type.CHAT) return;
            accept_subscription.begin(conversation);
        });
        add_action(accept_subscription_action);
    }

    private async void accept_subscription(Conversation conversation) {
        PresenceManager presence = stream_interactor.get_module<PresenceManager>(PresenceManager.IDENTITY);
        RosterManager roster = stream_interactor.get_module<RosterManager>(RosterManager.IDENTITY);
        try {
            if (roster.get_roster_item(conversation.account, conversation.counterpart) == null &&
                    !(yield roster.add_jid_async(conversation.account, conversation.counterpart, null))) {
                presence.subscription_action_failed(conversation.counterpart.bare_jid, conversation.account);
                return;
            }
            yield presence.request_mutual_subscription(conversation.account, conversation.counterpart, true);
        } catch (IOError e) {
            presence.subscription_action_failed(conversation.counterpart.bare_jid, conversation.account);
        }
    }

    protected void add_connection(Account account) {
        if ((get_flags() & ApplicationFlags.IS_SERVICE) == ApplicationFlags.IS_SERVICE) hold();
        stream_interactor.connect_account(account);
    }

    protected void remove_connection(Account account) {
        if ((get_flags() & ApplicationFlags.IS_SERVICE) == ApplicationFlags.IS_SERVICE) release();
        stream_interactor.disconnect_account.begin(account);
    }

    private void restore() {
        foreach (Account account in db.get_accounts()) {
            if (account.enabled) add_connection(account);
        }
    }
}

}

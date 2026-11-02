using Gee;

using Xmpp;
using Dino.Entities;

namespace Dino {

public class StreamInteractor : Object {

    internal bool is_test_instance { get; private set; default = false; }

    public signal void account_added(Account account);
    public signal void account_removed(Account account);
    public signal void stream_resumed(Account account, XmppStream stream);
    public signal void stream_negotiated(Account account, XmppStream stream);
    public signal void stream_attached_modules(Account account, XmppStream stream);

    public ModuleManager module_manager;
    public ConnectionManager connection_manager;
    private ArrayList<StreamInteractionModule> modules = new ArrayList<StreamInteractionModule>();

    public StreamInteractor(Database db) {
        module_manager = new ModuleManager();
        connection_manager = new ConnectionManager(module_manager, db);

        connection_manager.stream_opened.connect(on_stream_opened);
        connection_manager.stream_attached_modules.connect((account, stream) => {
            stream_attached_modules(account, stream);
        });
    }

    internal StreamInteractor.for_tests(Database db) {
        is_test_instance = true;
        module_manager = new ModuleManager();
        connection_manager = new ConnectionManager.for_tests(module_manager, db);

        connection_manager.stream_opened.connect(on_stream_opened);
        connection_manager.stream_attached_modules.connect((account, stream) => {
            stream_attached_modules(account, stream);
        });
    }

    public void connect_account(Account account) {
        module_manager.initialize(account);
        account_added(account);
        connection_manager.connect_account(account);
    }

    public async void disconnect_account(Account account) {
        yield connection_manager.disconnect_account(account);
        account_removed(account);
        module_manager.remove(account);
    }

    public ArrayList<Account> get_accounts() {
        ArrayList<Account> ret = new ArrayList<Account>(Account.equals_func);
        foreach (Account account in connection_manager.get_managed_accounts()) {
            ret.add(account);
        }
        return ret;
    }

    public XmppStream? get_stream(Account account) {
        return connection_manager.get_stream(account);
    }

    // User actions must belong to the current managed account row. Account's
    // general equality deliberately compares only the bare JID, so a stale
    // dialog for a deleted/recreated account cannot use that equality here.
    public XmppStream? get_connected_stream_for_action(Account account) {
        if (!account.enabled) return null;
        foreach (Account managed in connection_manager.get_managed_accounts()) {
            if (managed != account &&
                    (account.id <= 0 || managed.id != account.id)) continue;
            if (!managed.enabled || !managed.bare_jid.equals_bare(account.bare_jid)) return null;
            XmppStream? stream = connection_manager.get_stream(managed);
            if (stream == null || !((!) stream).negotiation_complete) return null;
            Xmpp.Bind.Flag? bind = ((!) stream).get_flag(Xmpp.Bind.Flag.IDENTITY);
            if (bind == null || ((!) bind).my_jid == null ||
                    !((!) bind).my_jid.equals_bare(account.bare_jid)) return null;
            return stream;
        }
        return null;
    }

    public void add_module(StreamInteractionModule module) {
        modules.add(module);
    }

    public T? get_module<T>(SimpleIdentity? identity) {
        if (identity == null) return null;
        foreach (StreamInteractionModule module in modules) {
             if (identity.matches(module)) return (T) module;
        }
        return null;
    }

    public new T? get<T>() {
        foreach (StreamInteractionModule module in modules) {
            if (module.get_type() == typeof(T)) return (T?) module;
        }
        return null;
    }

    private void on_stream_opened(Account account, XmppStream stream) {
        stream.stream_negotiated.connect( (stream) => {
            var flag = stream.get_flag(Xep.StreamManagement.Flag.IDENTITY);
            if (!connection_manager.mark_stream_session_resolved(account,
                    stream)) return;
            if (flag == null || flag.resumed == false) {
                stream_negotiated(account, stream);
            } else if (flag != null && flag.resumed == true) {
                stream_resumed(account, stream);
            }
        });
    }
}

public class SimpleIdentity : Object {
    public string id { get; protected set; }
    public SimpleIdentity(string id) { this.id = id; }
    public bool matches(StreamInteractionModule module) {
        return module.id == id;
    }
}

public class ModuleIdentity<T> : SimpleIdentity {
    public ModuleIdentity(string id) {
        base(id);
    }

    public T? cast(StreamInteractionModule module) {
        return (T) module;
    }
}

public interface StreamInteractionModule : Object {
    public abstract string id { get; }
}

}

using Gee;

using Xmpp;
using Dino.Entities;

namespace Dino {

public class BlockingManager : StreamInteractionModule, Object {
    public static ModuleIdentity<BlockingManager> IDENTITY = new ModuleIdentity<BlockingManager>("blocking_manager");
    public string id { get { return IDENTITY.id; } }

    public signal void block_changed(Account account, Jid jid);

    private StreamInteractor stream_interactor;

    public static void start(StreamInteractor stream_interactor) {
        BlockingManager m = new BlockingManager(stream_interactor);
        stream_interactor.add_module(m);
    }

    private BlockingManager(StreamInteractor stream_interactor) {
        this.stream_interactor = stream_interactor;
        
        stream_interactor.stream_negotiated.connect((account, stream) => {
            stream.get_module<Xmpp.Xep.BlockingCommand.Module>(Xmpp.Xep.BlockingCommand.Module.IDENTITY).block_push_received.connect((stream, jids) => {
                foreach (string jid_str in jids) {
                    try {
                        block_changed(account, new Jid(jid_str));
                    } catch (Error e) {
                        warning("BlockingManager: Failed to process block push for %s: %s", jid_str, e.message);
                    }
                }
            });
            stream.get_module<Xmpp.Xep.BlockingCommand.Module>(Xmpp.Xep.BlockingCommand.Module.IDENTITY).unblock_push_received.connect((stream, jids) => {
                foreach (string jid_str in jids) {
                    try {
                        block_changed(account, new Jid(jid_str));
                    } catch (Error e) {
                        warning("BlockingManager: Failed to process unblock push for %s: %s", jid_str, e.message);
                    }
                }
            });
        });
    }

    public bool is_blocked(Account account, Jid jid) {
        XmppStream stream = stream_interactor.get_stream(account);
        return stream != null && stream.get_module<Xmpp.Xep.BlockingCommand.Module>(Xmpp.Xep.BlockingCommand.Module.IDENTITY).is_blocked(stream, jid.to_string());
    }

    public async void block_checked(Account account, Jid jid) throws GLib.Error {
        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream == null) throw new IOError.NOT_CONNECTED("No active stream for account");
        var module = ((!) stream).get_module<Xmpp.Xep.BlockingCommand.Module>(Xmpp.Xep.BlockingCommand.Module.IDENTITY);
        if (module == null) throw new IOError.NOT_SUPPORTED("Blocking command module is not available");
        bool changed = yield ((!) module).block_checked((!) stream, { jid.to_string() });
        if (changed) block_changed(account, jid);
    }

    public async void unblock_checked(Account account, Jid jid) throws GLib.Error {
        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream == null) throw new IOError.NOT_CONNECTED("No active stream for account");
        var module = ((!) stream).get_module<Xmpp.Xep.BlockingCommand.Module>(Xmpp.Xep.BlockingCommand.Module.IDENTITY);
        if (module == null) throw new IOError.NOT_SUPPORTED("Blocking command module is not available");
        bool changed = yield ((!) module).unblock_checked((!) stream, { jid.to_string() });
        if (changed) block_changed(account, jid);
    }

    public void block(Account account, Jid jid) {
        block_checked.begin(account, jid, (_, res) => {
            try {
                block_checked.end(res);
            } catch (GLib.Error e) {
                warning("Failed to block %s: %s", jid.to_string(), e.message);
            }
        });
    }

    public void unblock(Account account, Jid jid) {
        unblock_checked.begin(account, jid, (_, res) => {
            try {
                unblock_checked.end(res);
            } catch (GLib.Error e) {
                warning("Failed to unblock %s: %s", jid.to_string(), e.message);
            }
        });
    }

    public bool is_supported(Account account) {
        XmppStream stream = stream_interactor.get_stream(account);
        return stream != null && stream.get_module<Xmpp.Xep.BlockingCommand.Module>(Xmpp.Xep.BlockingCommand.Module.IDENTITY).is_supported(stream);
    }
}

}

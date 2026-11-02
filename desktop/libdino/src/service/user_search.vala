using Gee;
using Xmpp;
using Dino.Entities;

namespace Dino {

public class UserSearch : Object {
    private StreamInteractor stream_interactor;

    public UserSearch(StreamInteractor stream_interactor) {
        this.stream_interactor = stream_interactor;
    }

    private XmppStream require_stream(Account account, Cancellable? cancellable) throws Error {
        if (cancellable != null) ((!) cancellable).set_error_if_cancelled();
        XmppStream? stream = stream_interactor.get_connected_stream_for_action(account);
        if (stream == null) throw new IOError.NOT_CONNECTED("Account is not connected");
        return (!) stream;
    }

    private void check_stream(Account account, XmppStream stream,
            Cancellable? cancellable) throws Error {
        if (cancellable != null) ((!) cancellable).set_error_if_cancelled();
        if (stream_interactor.get_connected_stream_for_action(account) != stream) {
            throw new IOError.NOT_CONNECTED("Account connection changed during search");
        }
    }

    public async virtual Jid? find_search_component(Account account,
            Cancellable? cancellable = null) throws Error {
        XmppStream stream = require_stream(account, cancellable);
        var disco = stream.get_module<Xmpp.Xep.ServiceDiscovery.Module>(
                Xmpp.Xep.ServiceDiscovery.Module.IDENTITY);
        if (disco == null) throw new IOError.NOT_SUPPORTED("Service discovery is unavailable");
        Jid server = account.bare_jid.domain_jid;
        Error? discovery_error = null;

        try {
            var info = yield disco.request_info_cancellable(stream, server, cancellable);
            check_stream(account, stream, cancellable);
            if (info != null && info.features.contains(Xmpp.Xep.Search.NS_URI)) return server;
        } catch (Error e) {
            check_stream(account, stream, cancellable);
            discovery_error = e.copy();
            debug("Search discovery on %s did not complete: %s", server.to_string(), e.message);
        }

        var items = yield disco.request_items_cancellable(stream, server, null, cancellable);
        check_stream(account, stream, cancellable);
        if (items == null) throw new IOError.INVALID_DATA("Discovery returned no service list");
        var checked = new HashSet<Jid>(Jid.hash_func, Jid.equals_func);
        checked.add(server);
        foreach (var item in items.items) {
            // A disco node is not an independently addressable search service.
            if (item.node != null && item.node != "") continue;
            if (!checked.add(item.jid)) continue;
            try {
                var info = yield disco.request_info_cancellable(stream, item.jid, cancellable);
                check_stream(account, stream, cancellable);
                if (info != null && info.features.contains(Xmpp.Xep.Search.NS_URI)) return item.jid;
            } catch (Error e) {
                check_stream(account, stream, cancellable);
                discovery_error = e.copy();
                // One unavailable component must not hide another working directory.
                debug("Search discovery on %s did not complete: %s", item.jid.to_string(), e.message);
            }
        }
        if (discovery_error != null) throw (!) discovery_error;
        return null;
    }

    public async virtual Xmpp.Xep.Search.Form get_search_fields(Account account, Jid search_jid,
            Cancellable? cancellable = null) throws Error {
        XmppStream stream = require_stream(account, cancellable);
        var search = stream.get_module<Xmpp.Xep.Search.Module>(Xmpp.Xep.Search.Module.IDENTITY);
        if (search == null) throw new IOError.NOT_SUPPORTED("Directory search is unavailable");
        var form = yield search.get_fields(stream, search_jid, cancellable);
        check_stream(account, stream, cancellable);
        return form;
    }

    public async virtual Gee.List<Xmpp.Xep.Search.Item> perform_search(Account account, Jid search_jid,
            Xmpp.Xep.Search.Form form, Cancellable? cancellable = null) throws Error {
        XmppStream stream = require_stream(account, cancellable);
        var search = stream.get_module<Xmpp.Xep.Search.Module>(Xmpp.Xep.Search.Module.IDENTITY);
        if (search == null) throw new IOError.NOT_SUPPORTED("Directory search is unavailable");
        var results = yield search.search(stream, search_jid, form, cancellable);
        check_stream(account, stream, cancellable);
        return results;
    }
}

}

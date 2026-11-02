using Gee;

namespace Xmpp.Xep.ServiceDiscovery {

public const string NS_URI = "http://jabber.org/protocol/disco";
public const string NS_URI_INFO = NS_URI + "#info";
public const string NS_URI_ITEMS = NS_URI + "#items";

public class Module : XmppStreamModule, Iq.Handler {
    public static ModuleIdentity<Module> IDENTITY = new ModuleIdentity<Module>(NS_URI, "0030_service_discovery_module");

    private HashMap<Jid, Future<InfoResult?>> active_info_requests = new HashMap<Jid, Future<InfoResult?>>(Jid.hash_func, Jid.equals_func);

    public Identity own_identity;
    public CapsCache cache;

    public Module.with_identity(string category, string type, string? name = null) {
        this.own_identity = new Identity(category, type, name);
    }

    public void add_feature(XmppStream stream, string feature) {
        stream.get_flag(Flag.IDENTITY).add_own_feature(feature);
    }

    public void remove_feature(XmppStream stream, string feature) {
        Flag? flag = stream.get_flag(Flag.IDENTITY);
        if (flag != null) {
                flag.remove_own_feature(feature);
        }
    }

    public void add_feature_notify(XmppStream stream, string feature) {
        add_feature(stream, feature + "+notify");
    }

    public void remove_feature_notify(XmppStream stream, string feature) {
        remove_feature(stream, feature + "+notify");
    }

    public async bool has_entity_feature(XmppStream stream, Jid jid, string feature) {
        return yield this.cache.has_entity_feature(jid, feature);
    }

    public async Gee.Set<Identity>? get_entity_identities(XmppStream stream, Jid jid) {
        return yield this.cache.get_entity_identities(jid);
    }

    public async InfoResult? request_info(XmppStream stream, Jid jid) {
        return yield request_info_internal(stream, jid, true);
    }

    // Keep request_info's public async signature stable: Vala callers may use
    // begin(stream, jid, callback), where adding an optional parameter changes
    // callback binding at compile time.
    public async InfoResult? request_info_fresh(XmppStream stream, Jid jid) {
        return yield request_info_internal(stream, jid, false);
    }

    // A caller-owned request must not share cancellation with the coalesced
    // discovery requests used by the rest of the stream.
    public async InfoResult? request_info_cancellable(XmppStream stream, Jid jid,
            Cancellable? cancellable) throws Error {
        var iq = new Iq.Stanza.get(new StanzaNode.build("query", NS_URI_INFO)
                .add_self_xmlns()) { to = jid };
        Iq.Stanza response = yield stream.get_module<Iq.Module>(Iq.Module.IDENTITY)
                .send_iq_async(stream, iq, Priority.DEFAULT, cancellable);
        validate_cancellable_response(response, jid);
        InfoResult? result = InfoResult.create_from_iq(response);
        if (result == null) {
            throw new IOError.INVALID_DATA("Discovery response has no valid info payload");
        }
        return result;
    }

    private async InfoResult? request_info_internal(XmppStream stream, Jid jid,
            bool coalesce) {
        if (!coalesce) {
            Iq.Stanza fresh_iq = new Iq.Stanza.get(new StanzaNode.build(
                "query", NS_URI_INFO).add_self_xmlns()) { to=jid };
            try {
                Iq.Stanza fresh_response = yield stream.get_module<Iq.Module>(
                    Iq.Module.IDENTITY).send_iq_async(stream, fresh_iq);
                return InfoResult.create_from_iq(fresh_response);
            } catch (IOError e) {
                log_request_io_error("request_info", e);
                return null;
            }
        }

        var future = active_info_requests[jid];
        if (future == null) {
            var promise = new Promise<InfoResult?>();
            future = promise.future;
            active_info_requests[jid] = future;

            Iq.Stanza iq = new Iq.Stanza.get(new StanzaNode.build("query", NS_URI_INFO).add_self_xmlns()) { to=jid };
            try {
                Iq.Stanza iq_response = yield stream.get_module<Iq.Module>(Iq.Module.IDENTITY).send_iq_async(stream, iq);
                InfoResult? result = InfoResult.create_from_iq(iq_response);
                promise.set_value(result);
            } catch (IOError e) {
                log_request_io_error("request_info", e);
                promise.set_value(null);
            }
            active_info_requests.unset(jid);
        }

        try {
            InfoResult? res = yield future.wait_async();
            return res;
        } catch (FutureError error) {
            warning("Future error when waiting for info request result: %s", error.message);
            return null;
        }
    }

    public async ItemsResult? request_items(XmppStream stream, Jid jid, string? node = null) {
        StanzaNode query_node = new StanzaNode.build("query", NS_URI_ITEMS).add_self_xmlns();
        if (node != null && node != "") {
            query_node.put_attribute("node", node);
        }
        Iq.Stanza iq = new Iq.Stanza.get(query_node) { to=jid };

        try {
            Iq.Stanza iq_result = yield stream.get_module<Iq.Module>(Iq.Module.IDENTITY).send_iq_async(stream, iq);
            debug("Disco Items Response from %s: %s", jid.to_string(), iq_result.stanza.to_string());
            ItemsResult? result = ItemsResult.create_from_iq(iq_result);
            return result;
        } catch (IOError e) {
            log_request_io_error("request_items", e);
            return null;
        }
    }

    public async ItemsResult? request_items_cancellable(XmppStream stream, Jid jid,
            string? node, Cancellable? cancellable) throws Error {
        var query = new StanzaNode.build("query", NS_URI_ITEMS).add_self_xmlns();
        if (node != null && node != "") query.put_attribute("node", node);
        var iq = new Iq.Stanza.get(query) { to = jid };
        Iq.Stanza response = yield stream.get_module<Iq.Module>(Iq.Module.IDENTITY)
                .send_iq_async(stream, iq, Priority.DEFAULT, cancellable);
        validate_cancellable_response(response, jid);
        ItemsResult? result = ItemsResult.create_from_iq(response);
        if (result == null) {
            throw new IOError.INVALID_DATA("Discovery response has no valid items payload");
        }
        return result;
    }

    private void validate_cancellable_response(Iq.Stanza response, Jid target) throws Error {
        if (response.from == null || !((!) response.from).equals(target)) {
            throw new IOError.INVALID_DATA("Discovery response has an unexpected sender");
        }
        if (response.is_error()) {
            ErrorStanza? error = response.get_error();
            throw new IOError.FAILED("Discovery service returned %s".printf(
                    error != null ? ((!) error).condition : "unknown-error"));
        }
    }

    private void log_request_io_error(string operation, IOError error) {
        if (error is IOError.CANCELLED || error is IOError.TIMED_OUT) {
            debug("%s did not complete: %s", operation, error.message);
        } else {
            warning("IOError in %s: %s", operation, error.message);
        }
    }

    public async void on_iq_get(XmppStream stream, Iq.Stanza iq) {
        StanzaNode? query_node = iq.stanza.get_subnode("query", NS_URI_INFO);
        if (query_node != null) {
            send_query_result(stream, iq);
        }
    }

    public override void attach(XmppStream stream) {
        stream.add_flag(new Flag());
        stream.get_flag(Flag.IDENTITY).add_own_identity(own_identity);

        stream.get_module<Iq.Module>(Iq.Module.IDENTITY).register_for_namespace(NS_URI_INFO, this);
        add_feature(stream, NS_URI_INFO);
    }

    public override void detach(XmppStream stream) {
        active_info_requests.clear();

        Flag? flag = stream.get_flag(Flag.IDENTITY);
        if (flag != null) flag.remove_own_identity(own_identity);

        stream.get_module<Iq.Module>(Iq.Module.IDENTITY).unregister_from_namespace(NS_URI_INFO, this);
        remove_feature(stream, NS_URI_INFO);
    }

    public static void require(XmppStream stream) {
        if (stream.get_module<Module>(IDENTITY) == null) stream.add_module(new ServiceDiscovery.Module());
    }

    public override string get_ns() { return NS_URI; }
    public override string get_id() { return IDENTITY.id; }

    private void send_query_result(XmppStream stream, Iq.Stanza iq_request) {
        InfoResult query_result = new ServiceDiscovery.InfoResult(iq_request);
        query_result.features = stream.get_flag(Flag.IDENTITY).own_features;
        query_result.identities = stream.get_flag(Flag.IDENTITY).own_identities;
        stream.get_module<Iq.Module>(Iq.Module.IDENTITY).send_iq(stream, query_result.iq);
    }
}

public interface CapsCache : Object {
    public abstract async bool has_entity_feature(Jid jid, string feature);
    public abstract async Gee.Set<Identity> get_entity_identities(Jid jid);
}

}

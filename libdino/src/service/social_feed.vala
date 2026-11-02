using Gee;
using Xmpp;
using Dino.Entities;

namespace Dino.Feeds {

public class Social : Object {
    public const string NS = "urn:xmpp:pubsub-social-feed:1";
    public const string MICROBLOG = "urn:xmpp:microblog:0";
    private const string OWNER = "http://jabber.org/protocol/pubsub#owner";
    private StreamInteractor interactor;
    private Store store;
    private HashMap<int, MessageModule> listeners = new HashMap<int, MessageModule>();
    private HashMap<int, ulong> listener_ids = new HashMap<int, ulong>();
    public signal void updated(Account account, string source, string node);

    public Social(StreamInteractor interactor, Store store) {
        this.interactor = interactor;
        this.store = store;
        interactor.stream_attached_modules.connect(attach);
        interactor.account_removed.connect(remove_listener);
    }

    private void remove_listener(Account account) {
        if (!listeners.has_key(account.id)) return;
        listeners[account.id].disconnect(listener_ids[account.id]);
        listeners.unset(account.id); listener_ids.unset(account.id);
    }

    public void shutdown() {
        interactor.stream_attached_modules.disconnect(attach);
        interactor.account_removed.disconnect(remove_listener);
        foreach (int account_id in listeners.keys) listeners[account_id].disconnect(listener_ids[account_id]);
        listeners.clear(); listener_ids.clear();
    }

    private void attach(Account account, XmppStream stream) {
        remove_listener(account);
        var disco = stream.get_module<Xep.ServiceDiscovery.Module>(Xep.ServiceDiscovery.Module.IDENTITY);
        disco.add_feature(stream, NS);
        disco.add_feature(stream, MICROBLOG);
        disco.add_feature_notify(stream, MICROBLOG);
        var module = stream.get_module<MessageModule>(MessageModule.IDENTITY);
        listeners[account.id] = module;
        listener_ids[account.id] = module.received_message.connect((s, message) => {
            if (interactor.get_stream(account) != s || message.from == null || !message.from.is_bare()) return;
            StanzaNode? event = message.stanza.get_subnode("event", Xep.Pubsub.NS_URI_EVENT);
            if (event == null) return;
            foreach (StanzaNode child in ((!) event).sub_nodes) {
                if (child.ns_uri != Xep.Pubsub.NS_URI_EVENT) continue;
                if (child.name != "items" && child.name != "delete" && child.name != "purge") continue;
                string? node = child.get_attribute("node");
                if (node == null) continue;
                // Treat payloads as invalidations. A bounded authenticated IQ
                // fetch also handles payload-less events and retractions.
                foreach (Subscription subscription in store.list()) {
                    if (subscription.enabled && subscription.account_id == account.id &&
                            subscription.source == message.from.to_string() && subscription.node == node) {
                        updated(account, subscription.source, subscription.node);
                        break;
                    }
                }
            }
        });
    }

    private XmppStream connected(Account account) throws Error {
        XmppStream? stream = interactor.get_connected_stream_for_action(account);
        if (stream == null) throw new IOError.NOT_CONNECTED(GLib.dgettext("dino", "The selected account is not connected."));
        return (!) stream;
    }

    private void current(Account account, XmppStream stream) throws Error {
        if (connected(account) != stream) throw new IOError.CANCELLED(GLib.dgettext("dino", "The account connection changed. Check the feed before retrying."));
    }

    public static Jid service_jid(string value) throws Error {
        var jid = new Jid(value.strip());
        if (!jid.is_bare()) throw new IOError.INVALID_ARGUMENT(GLib.dgettext("dino", "Use a bare XMPP address without a resource."));
        return jid;
    }

    public async ArrayList<Entry> read(Account account, string source, string node, Cancellable? cancellable = null) throws Error {
        Jid jid = service_jid(source);
        if (node == "" || node.length > 1024) throw new IOError.INVALID_ARGUMENT(GLib.dgettext("dino", "Invalid PubSub node."));
        XmppStream stream = connected(account);
        var result = yield stream.get_module<Xep.Pubsub.Module>(Xep.Pubsub.Module.IDENTITY)
            .request_all_with_result_cancellable(stream, jid, node, 100, Xep.Pubsub.RequestPurpose.OPTIONAL_NODE_QUERY, cancellable);
        current(account, stream);
        if (cancellable != null) ((!) cancellable).set_error_if_cancelled();
        // A personal feed need not exist before its first publication. Keep
        // this distinct from an empty existing feed and do not subscribe to it.
        if (result.items == null && result.error_condition == ErrorStanza.CONDITION_ITEM_NOT_FOUND) {
            if (jid.equals_bare(account.bare_jid) && node == MICROBLOG)
                throw new IOError.NOT_FOUND(GLib.dgettext("dino", "Your account has no XMPP feed yet. Use “Write a post in my feed…” to create one."));
            throw new IOError.NOT_FOUND(GLib.dgettext("dino", "The server could not find this XMPP feed. Check the address and node."));
        }
        if (result.items == null) throw new IOError.FAILED(GLib.dgettext("dino", "Cannot read this XMPP feed: %s").printf(result.error_condition ?? result.error_text ?? "unknown error"));
        var entries = new ArrayList<Entry>();
        yield FileTransferWorker.run("social-feed-parser", () => {
          int total_bytes = 0;
          foreach (StanzaNode item in (!) result.items) {
            if (entries.size >= 100) break;
            string? item_id = item.get_attribute("id");
            StanzaNode? atom = item.get_subnode("entry", ATOM);
            if (item_id == null || item_id.length > 1024 || atom == null) continue;
            try {
                string xml = ((!) atom).to_xml();
                total_bytes += xml.length;
                if (total_bytes > MAX_BYTES) break;
                var parsed = Parser.parse(xml);
                if (parsed.is_empty) continue;
                Entry entry = parsed[0];
                if (entry.id == "") continue;
                entry.item_id = (!) item_id;
                if (entry.link == "") entry.link = item_uri(jid.to_string(), node, entry.item_id);
                entries.add(entry);
            } catch (Error e) { debug("Ignoring malformed social feed item: %s", e.message); }
          }
        });
        current(account, stream);
        if (cancellable != null) ((!) cancellable).set_error_if_cancelled();
        return entries;
    }

    public static string item_uri(string source, string node, string item) {
        return "xmpp:" + Uri.escape_string(source, "@", false) + "?;node=" + Uri.escape_string(node, null, false) + ";item=" + Uri.escape_string(item, null, false);
    }

    private async Iq.Stanza checked_iq(Account account, XmppStream stream, Iq.Stanza iq) throws Error {
        Iq.Stanza? reply = yield stream.get_module<Iq.Module>(Iq.Module.IDENTITY).send_iq_async(stream, iq);
        current(account, stream);
        if (reply == null) throw new IOError.FAILED(GLib.dgettext("dino", "No XMPP response. Check the feed before retrying."));
        if (((!) reply).is_error()) {
            ErrorStanza? error = ((!) reply).get_error();
            throw new IOError.FAILED(GLib.dgettext("dino", "XMPP feed request failed: %s").printf(error != null ? ((!) error).condition : "unknown error"));
        }
        return (!) reply;
    }

    public async void subscribe(Account account, string source, string node) throws Error {
        Jid jid = service_jid(source);
        XmppStream stream = connected(account);
        foreach (Subscription existing in store.list()) {
            if (existing.account_id == account.id && existing.source == jid.to_string() && existing.node == node)
                throw new IOError.EXISTS(GLib.dgettext("dino", "This account already subscribes to that feed."));
        }
        // Verify this is a readable Atom feed before subscribing.
        yield read(account, source, node);
        current(account, stream);
        var subscription = new StanzaNode.build("subscribe", Xep.Pubsub.NS_URI)
            .put_attribute("node", node).put_attribute("jid", account.bare_jid.to_string());
        var iq = new Iq.Stanza.set(new StanzaNode.build("pubsub", Xep.Pubsub.NS_URI).add_self_xmlns().put_node(subscription));
        iq.to = jid;
        Iq.Stanza response = yield checked_iq(account, stream, iq);
        StanzaNode? pubsub = response.stanza.get_subnode("pubsub", Xep.Pubsub.NS_URI);
        StanzaNode? state = pubsub != null ? ((!) pubsub).get_subnode("subscription", Xep.Pubsub.NS_URI) : null;
        string value = state != null ? ((!) state).get_attribute("subscription") ?? "" : "";
        if (value != "subscribed" && value != "pending") throw new IOError.FAILED(GLib.dgettext("dino", "The server did not confirm the feed subscription."));
        int id = store.add(account.id, jid.to_string(), node, 0, 0, 30, new ArrayList<Entry>(), ((!) state).get_attribute("subid") ?? "");
        store.checked(id, value);
    }

    public async void unsubscribe(Account account, Subscription subscription) throws Error {
        if (subscription.account_id != account.id) throw new IOError.PERMISSION_DENIED(GLib.dgettext("dino", "The subscription belongs to another account."));
        XmppStream stream = connected(account);
        var command = new StanzaNode.build("unsubscribe", Xep.Pubsub.NS_URI)
            .put_attribute("node", subscription.node).put_attribute("jid", account.bare_jid.to_string());
        if (subscription.subid != "") command.put_attribute("subid", subscription.subid);
        var iq = new Iq.Stanza.set(new StanzaNode.build("pubsub", Xep.Pubsub.NS_URI).add_self_xmlns().put_node(command));
        iq.to = service_jid(subscription.source);
        yield checked_iq(account, stream, iq);
        store.remove(subscription.id);
    }

    public static StanzaNode make_post(Account account, string item_id, string title, string body, string? reply_uri = null, string? reply_atom_id = null) {
        string time = new DateTime.now_utc().format_iso8601();
        var entry = new StanzaNode.build("entry", ATOM).add_self_xmlns();
        entry.put_node(new StanzaNode.build("id", ATOM).put_node(new StanzaNode.text("urn:uuid:" + item_id)));
        entry.put_node(new StanzaNode.build("title", ATOM).put_attribute("type", "text").put_node(new StanzaNode.text(title)));
        entry.put_node(new StanzaNode.build("content", ATOM).put_attribute("type", "text").put_node(new StanzaNode.text(body)));
        entry.put_node(new StanzaNode.build("published", ATOM).put_node(new StanzaNode.text(time)));
        entry.put_node(new StanzaNode.build("updated", ATOM).put_node(new StanzaNode.text(time)));
        entry.put_node(new StanzaNode.build("author", ATOM)
            .put_node(new StanzaNode.build("name", ATOM).put_node(new StanzaNode.text(account.bare_jid.to_string())))
            .put_node(new StanzaNode.build("uri", ATOM).put_node(new StanzaNode.text("xmpp:" + account.bare_jid.to_string()))));
        if (reply_uri != null && reply_atom_id != null) entry.put_node(new StanzaNode.build("in-reply-to", "http://purl.org/syndication/thread/1.0")
            .add_self_xmlns().put_attribute("ref", (!) reply_atom_id).put_attribute("href", (!) reply_uri));
        return entry;
    }

    public async void publish(Account account, string item_id, string title, string body, bool public_feed, string? reply_uri = null, string? reply_atom_id = null) throws Error {
        if (!title.validate() || !body.validate())
            throw new IOError.INVALID_DATA(GLib.dgettext("dino", "The text contains invalid Unicode."));
        if (title.strip() == "" || body.strip() == "" || title.length > 1000 || body.length > 16000)
            throw new IOError.INVALID_ARGUMENT(GLib.dgettext("dino", "A post needs a title and text (maximum 16000 bytes)."));
        XmppStream stream = connected(account);
        var pubsub = stream.get_module<Xep.Pubsub.Module>(Xep.Pubsub.Module.IDENTITY);
        string access = public_feed ? Xep.Pubsub.ACCESS_MODEL_OPEN : Xep.Pubsub.ACCESS_MODEL_PRESENCE;
        // Never make an existing private feed public as a side effect of one
        // post. Users must choose its existing visibility or change it outside
        // this composer. Missing nodes are created using publish-options.
        var iq = new Iq.Stanza.get(new StanzaNode.build("pubsub", OWNER).add_self_xmlns()
            .put_node(new StanzaNode.build("configure", OWNER).put_attribute("node", MICROBLOG)));
        iq.to = account.bare_jid;
        Iq.Stanza? response = yield stream.get_module<Iq.Module>(Iq.Module.IDENTITY).send_iq_async(stream, iq);
        current(account, stream);
        if (response == null) throw new IOError.FAILED(GLib.dgettext("dino", "Could not check the feed visibility."));
        if (((!) response).is_error()) {
            ErrorStanza? error = ((!) response).get_error();
            if (error == null || ((!) error).condition != ErrorStanza.CONDITION_ITEM_NOT_FOUND)
                throw new IOError.PERMISSION_DENIED(GLib.dgettext("dino", "Could not check the feed visibility."));
        } else {
            StanzaNode? form = ((!) response).stanza.get_deep_subnode(OWNER + ":pubsub", OWNER + ":configure", "jabber:x:data:x");
            string? actual = null;
            if (form != null) foreach (StanzaNode field in ((!) form).get_subnodes("field", "jabber:x:data")) {
                if (field.get_attribute("var") == "pubsub#access_model") actual = field.get_subnode("value", "jabber:x:data")?.get_string_content();
            }
            if (actual != access) throw new IOError.PERMISSION_DENIED(GLib.dgettext("dino", "The existing feed has a different visibility. Select its current visibility; DinoX will not change access to older posts."));
        }
        var options = new Xep.Pubsub.PublishOptions().set_access_model(access).set_persist_items(true)
            .set_max_items("max").set_send_last_published_item("never");
        options.settings["pubsub#type"] = MICROBLOG;
        options.settings["pubsub#notify_retract"] = "true";
        options.settings["pubsub#deliver_payloads"] = "false";
        var result = yield pubsub.publish_with_result(stream, account.bare_jid, MICROBLOG, item_id,
            make_post(account, item_id, title, body, reply_uri, reply_atom_id), options, false);
        current(account, stream);
        if (!result.ok) throw new IOError.FAILED(GLib.dgettext("dino", "Publishing failed: ") + result.describe_error());
        updated(account, account.bare_jid.to_string(), MICROBLOG);
    }

    public async void retract(Account account, string item_id) throws Error {
        XmppStream stream = connected(account);
        var result = yield stream.get_module<Xep.Pubsub.Module>(Xep.Pubsub.Module.IDENTITY)
            .retract_item_with_result(stream, account.bare_jid, MICROBLOG, item_id);
        current(account, stream);
        if (!result.ok) throw new IOError.FAILED(GLib.dgettext("dino", "Removing the post failed: ") + result.describe_error());
        updated(account, account.bare_jid.to_string(), MICROBLOG);
    }
}
}

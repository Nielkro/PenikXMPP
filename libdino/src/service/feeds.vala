using Gee;
using Xmpp;
using Dino.Entities;

namespace Dino.Feeds {

public class Download : Object {
    public ArrayList<Entry> entries = new ArrayList<Entry>();
    public string etag = "";
    public string modified = "";
    public bool unchanged;
}

public class Service : Object, StreamInteractionModule {
    public static ModuleIdentity<Service> IDENTITY = new ModuleIdentity<Service>("feeds");
    public string id { get { return IDENTITY.id; } }
    public Store store { get; private set; }
    public Social social { get; private set; }
    public signal void changed();
    private StreamInteractor interactor;
    private Database db;
    private AccountHttpSessionPool sessions = new AccountHttpSessionPool("feeds");
    private Cancellable lifetime = new Cancellable();
    private uint timer;
    private bool polling;

    public static void start(StreamInteractor interactor, Database db) {
        interactor.add_module(new Service(interactor, db));
    }

    private Service(StreamInteractor interactor, Database db) {
        this.interactor = interactor;
        this.db = db;
        store = new Store(db);
        social = new Social(interactor, store);
        timer = Timeout.add_seconds(15, () => { poll.begin(); return Source.CONTINUE; });
    }

    public void shutdown() {
        if (timer != 0) { Source.remove(timer); timer = 0; }
        lifetime.cancel();
        social.shutdown();
        sessions.shutdown();
    }

    private string route(Account account) throws Error {
        if (lifetime.is_cancelled() || interactor.get_connected_stream_for_action(account) == null)
            throw new IOError.NOT_CONNECTED(GLib.dgettext("dino", "The selected account is not connected."));
        string? proxy = build_socks5_proxy_uri(account);
        if ((account.proxy_type == "socks5" || account.proxy_type == "tor") && proxy == null)
            throw new IOError.NOT_CONNECTED(GLib.dgettext("dino", "The selected proxy is unavailable."));
        return proxy ?? "direct";
    }

    public async Download fetch(Account account, string url, string etag = "", string modified = "", Cancellable? cancellable = null) throws Error {
        string expected_route = route(account);
        XmppStream? expected_stream = interactor.get_connected_stream_for_action(account);
        var request_cancel = new Cancellable();
        ulong cancel_id = cancellable != null ? ((!) cancellable).connect(() => request_cancel.cancel()) : 0;
        ulong lifetime_id = lifetime.connect(() => request_cancel.cancel());
        ulong notify_id = account.notify.connect(() => {
            try { if (route(account) != expected_route) request_cancel.cancel(); } catch (Error e) { request_cancel.cancel(); }
        });
        int64 started = get_monotonic_time();
        uint watchdog = Timeout.add_seconds(1, () => {
            if (get_monotonic_time() - started > 30 * TimeSpan.SECOND ||
                    interactor.get_connected_stream_for_action(account) != expected_stream) request_cancel.cancel();
            return Source.CONTINUE;
        });
        var result = new Download();
        try {
            string current = Parser.http_url(url);
            Soup.Session session = (Soup.Session) sessions.get_session(account);
            for (int redirects = 0; redirects <= 5; redirects++) {
                request_cancel.set_error_if_cancelled();
                if (route(account) != expected_route) throw new IOError.CANCELLED(GLib.dgettext("dino", "The account route changed."));
                var message = new Soup.Message("GET", current);
                message.flags = Soup.MessageFlags.NO_REDIRECT;
                message.request_headers.replace("Accept", "application/atom+xml, application/rss+xml, application/xml, text/xml;q=0.9");
                if (etag != "") message.request_headers.replace("If-None-Match", etag);
                if (modified != "") message.request_headers.replace("If-Modified-Since", modified);
                InputStream input = yield session.send_async(message, Priority.DEFAULT, request_cancel);
                try {
                    uint status = message.status_code;
                    if (status == 304) { result.unchanged = true; return result; }
                    if (status >= 300 && status < 400) {
                        string? location = message.response_headers.get_one("Location");
                        if (location == null) throw new IOError.INVALID_DATA(GLib.dgettext("dino", "Feed redirect has no destination."));
                        string next = Parser.http_url((!) location, current);
                        if (current.has_prefix("https:") && !next.has_prefix("https:"))
                            throw new IOError.PERMISSION_DENIED(GLib.dgettext("dino", "Refusing an insecure feed redirect."));
                        current = next;
                        continue;
                    }
                    if (status != 200) throw new IOError.FAILED(GLib.dgettext("dino", "Feed HTTP status %u").printf(status));
                    if (message.response_headers.get_content_length() > MAX_BYTES) throw new IOError.INVALID_DATA(GLib.dgettext("dino", "Feed exceeds 2 MiB."));
                    var data = new ByteArray();
                    while (true) {
                        Bytes bytes = yield input.read_bytes_async(16384, Priority.DEFAULT, request_cancel);
                        if (bytes.get_size() == 0) break;
                        if (data.len + bytes.get_size() > MAX_BYTES) throw new IOError.INVALID_DATA(GLib.dgettext("dino", "Feed exceeds 2 MiB."));
                        data.append(bytes.get_data());
                    }
                    data.append({0});
                    HashTable<string, string>? parameters;
                    message.response_headers.get_content_type(out parameters);
                    string? charset = parameters != null ? ((!) parameters)["charset"] : null;
                    string xml = Parser.decode(data.data[0:data.len - 1], charset);
                    ArrayList<Entry>? entries = null;
                    yield FileTransferWorker.run("feed-parser", () => { entries = Parser.parse(xml, current); });
                    request_cancel.set_error_if_cancelled();
                    if (route(account) != expected_route) throw new IOError.CANCELLED(GLib.dgettext("dino", "The account route changed."));
                    result.entries = (!) entries;
                    result.etag = message.response_headers.get_one("ETag") ?? "";
                    result.modified = message.response_headers.get_one("Last-Modified") ?? "";
                    return result;
                } finally { try { input.close(null); } catch (Error ignored) { } }
            }
            throw new IOError.TOO_MANY_LINKS(GLib.dgettext("dino", "Too many feed redirects."));
        } finally {
            Source.remove(watchdog);
            account.disconnect(notify_id);
            lifetime.disconnect(lifetime_id);
            if (cancellable != null && cancel_id != 0) ((!) cancellable).disconnect(cancel_id);
        }
    }

    public bool can_send(Conversation target) {
        if (interactor.get_connected_stream_for_action(target.account) == null || !target.active) return false;
        if (target.counterpart.domainpart == "mqtt.local" ||
                (target.encryption != Encryption.NONE && target.encryption != Encryption.PGP && target.encryption != Encryption.OMEMO)) return false;
        var blocking = interactor.get_module<BlockingManager>(BlockingManager.IDENTITY);
        if (blocking != null && blocking.is_blocked(target.account, target.counterpart)) return false;
        if (target.type_ == Conversation.Type.CHAT) return true;
        if (target.type_ != Conversation.Type.GROUPCHAT) return false;
        var muc = interactor.get_module<MucManager>(MucManager.IDENTITY);
        if (muc == null) return false;
        Jid? own = muc.get_own_jid(target.counterpart, target.account);
        return own != null && muc.is_joined(target.counterpart, target.account) && muc.get_role((!) own, target.account) != Xep.Muc.Role.VISITOR;
    }

    // No await between target validation, persistent queue insertion and
    // deduplication. Encryption and actual delivery stay in MessageProcessor.
    public void send(Conversation target, string text, int subscription_id = 0, string item_key = "") throws Error {
        if (!text.validate()) throw new IOError.INVALID_DATA(GLib.dgettext("dino", "The text contains invalid Unicode."));
        if (text.strip() == "" || text.length > 16000) throw new IOError.INVALID_ARGUMENT(GLib.dgettext("dino", "The message is empty or too long."));
        if (!can_send(target)) throw new IOError.PERMISSION_DENIED(GLib.dgettext("dino", "The selected chat cannot send messages now."));
        if (subscription_id != 0) {
            Subscription? subscription = store.get(subscription_id);
            if (subscription == null || !((!) subscription).enabled || ((!) subscription).target_id != target.id ||
                    ((!) subscription).account_id != target.account.id || ((!) subscription).encryption != (int) target.encryption)
                throw new IOError.PERMISSION_DENIED(GLib.dgettext("dino", "The subscription target or encryption changed."));
            if (store.seen(subscription_id, item_key)) return;
        }
        var processor = interactor.get_module<MessageProcessor>(MessageProcessor.IDENTITY);
        var content = interactor.get_module<ContentItemStore>(ContentItemStore.IDENTITY);
        Entities.Message message;
        db.exec("BEGIN IMMEDIATE");
        try {
            if (subscription_id != 0) store.mark_seen(subscription_id, item_key);
            message = processor.create_out_message(text, target);
            content.insert_message(message, target);
            db.exec("COMMIT");
        } catch (Error e) {
            try { db.exec("ROLLBACK"); } catch (Error ignored) { }
            throw e;
        }
        processor.send_xmpp_message(message, target);
        processor.message_sent(message, target);
    }

    private async void poll() {
        if (polling || lifetime.is_cancelled()) return;
        polling = true;
        try {
            foreach (Subscription subscription in store.list()) {
                if (lifetime.is_cancelled()) break;
                if (!subscription.enabled || subscription.is_xmpp || new DateTime.now_utc().to_unix() - subscription.checked < subscription.interval * 60) continue;
                Account? account = db.get_account_by_id(subscription.account_id);
                Conversation? target = interactor.get_module<ConversationManager>(ConversationManager.IDENTITY).get_conversation_by_id(subscription.target_id);
                if (account == null || target == null || target.account.id != subscription.account_id || !can_send(target)) continue;
                try {
                    if (subscription.encryption != (int) target.encryption) {
                        store.set_enabled(subscription.id, false, subscription.encryption);
                        store.checked(subscription.id, "encryption-changed");
                        changed();
                        continue;
                    }
                    Download download = yield fetch((!) account, subscription.source, subscription.etag, subscription.modified, lifetime);
                    if (download.unchanged) { store.checked(subscription.id, "ok"); continue; }
                    int sent = 0;
                    bool remaining = false;
                    for (int i = download.entries.size - 1; i >= 0; i--) {
                        Entry entry = download.entries[i];
                        if (store.seen(subscription.id, entry.key())) continue;
                        if (sent == 5) { remaining = true; break; }
                        send((!) target, entry.message(), subscription.id, entry.key());
                        sent++;
                    }
                    store.checked(subscription.id, "ok", remaining ? "" : download.etag, remaining ? "" : download.modified);
                } catch (Error e) {
                    try { store.checked(subscription.id, e.message); } catch (Error ignored) { }
                }
                changed();
            }
        } finally { polling = false; }
    }
}
}

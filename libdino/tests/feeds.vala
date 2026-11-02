using Dino.Entities;
using Xmpp;
using Xmpp.Xep;

namespace Dino.Test {

[CCode (cname = "soup_server_message_set_response", cheader_filename = "libsoup/soup.h")]
private extern void set_feed_server_response(Soup.ServerMessage message, string? content_type,
    Soup.MemoryUse memory_use, string response_body, size_t response_length);

class FeedsTest : Gee.TestCase {
    public FeedsTest() {
        base("Feeds");
        add_test("rss_content_encoded_unicode_and_dedup", rss);
        add_test("atom_namespaces_xhtml_and_relative_links", atom);
        add_test("rss1_namespaces", rss1);
        add_test("unsafe_xml_and_urls_rejected", unsafe_input);
        add_test("xml_encoding_declarations_and_utf16", encodings);
        add_test("shortening_preserves_grapheme_clusters", graphemes);
        add_test("unicode_endianness_and_windows1251", unicode_encodings);
        add_test("invalid_and_truncated_unicode_rejected", invalid_unicode);
        add_test("subscription_scope_restart_and_cleanup", persistence);
        add_test("automatic_queue_deduplicates_and_preserves_target_encryption", queue);
        add_test("social_read_publish_and_visibility_boundary", protocol);
        add_test("http_limits_redirects_cancellation_and_conditional_get", http);
    }

    private void rss() {
        try {
            var entries = Feeds.Parser.parse("""<rss version="2.0" xmlns:c="http://purl.org/rss/1.0/modules/content/"><channel>
              <item><guid>x</guid><title>Новая версия &amp; Grüße</title><link>https://example.test/release</link><description></description><c:encoded><![CDATA[<p>Hallo Игорь &#128578;</p><script>alert('bad')</script><table><tr><td>ARM64</td><td>M152</td></tr></table>]]></c:encoded></item>
              <item><guid>x</guid><title>Duplicate</title></item></channel></rss>""");
            fail_if(entries.size != 1);
            fail_if_not_eq_str("Новая версия & Grüße", entries[0].title);
            fail_if(!entries[0].text.contains("Игорь 🙂") || !entries[0].text.contains("ARM64 | M152"));
            fail_if(entries[0].text.contains("alert") || entries[0].text.contains("<table>"));
            fail_if(!entries[0].message().has_suffix("https://example.test/release"));
            fail_if_not_eq_str("Прив…", Feeds.shorten("Привет", 4));
        } catch (Error e) { fail_if_reached(e.message); }
    }
    private void atom() {
        try {
            var entries = Feeds.Parser.parse("""<a:feed xmlns:a="http://www.w3.org/2005/Atom" xml:base="https://example.test/blog/">
              <a:entry><a:id>urn:uuid:test</a:id><a:title type="xhtml"><div xmlns="http://www.w3.org/1999/xhtml"><b>日本語</b> текст</div></a:title>
              <a:content type="xhtml"><div xmlns="http://www.w3.org/1999/xhtml"><p>Ignored alternative</p></div></a:content><a:content type="text">Preferred &lt;literal&gt;</a:content><a:link href="../post"/><a:updated>2026-10-22T12:00:00Z</a:updated></a:entry></a:feed>""");
            fail_if(entries.size != 1);
            fail_if_not_eq_str("日本語 текст", entries[0].title);
            fail_if_not_eq_str("Preferred <literal>", entries[0].text);
            fail_if_not_eq_str("https://example.test/post", entries[0].link);
            fail_if_not_eq_str("2026-10-22T12:00:00Z", entries[0].published);
        } catch (Error e) { fail_if_reached(e.message); }
    }
    private void rss1() {
        try {
            var entries = Feeds.Parser.parse("""<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns="http://purl.org/rss/1.0/"><item><title>RSS 1</title><link>https://example.test/1</link><description>First</description></item></rdf:RDF>""");
            fail_if(entries.size != 1 || entries[0].title != "RSS 1");
        } catch (Error e) { fail_if_reached(e.message); }
    }
    private void unsafe_input() {
        string[] xmls = {"<!DOCTYPE rss [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><rss><channel>&x;</channel></rss>", "<html>Not a feed</html>", "<rss><channel></rss>", string.nfill(Feeds.MAX_BYTES + 1, 'x')};
        foreach (string xml in xmls) {
            bool rejected = false;
            try { Feeds.Parser.parse(xml); } catch (Error e) { rejected = true; }
            fail_if(!rejected, "unsafe or malformed XML was accepted");
        }
        foreach (string url in new string[] {"file:///tmp/feed", "javascript:alert(1)", "https://secret@example.test/"}) {
            bool rejected = false;
            try { Feeds.Parser.http_url(url); } catch (Error e) { rejected = true; }
            fail_if(!rejected, "unsafe URL was accepted");
        }
    }

    private void encodings() {
        try {
            string xml = "<?xml version='1.0' encoding='ISO-8859-1'?><rss><channel><item><title>Grüße</title></item></channel></rss>";
            size_t size;
            string latin = GLib.convert(xml, xml.length, "ISO-8859-1", "UTF-8", null, out size);
            var parsed = Feeds.Parser.parse(Feeds.Parser.decode(((uint8[]) latin)[0:size]));
            fail_if(parsed.size != 1 || parsed[0].title != "Grüße");
            string utf16 = GLib.convert(xml.replace("ISO-8859-1", "UTF-16"), -1, "UTF-16", "UTF-8", null, out size);
            parsed = Feeds.Parser.parse(Feeds.Parser.decode(((uint8[]) utf16)[0:size]));
            fail_if(parsed.size != 1 || parsed[0].title != "Grüße");
        } catch (Error e) { fail_if_reached(e.message); }
    }

    private void graphemes() {
        fail_if_not_eq_str("Café…", Feeds.shorten("Café weiter", 4));
        fail_if_not_eq_str("é", Feeds.shorten("é", 1));
        fail_if_not_eq_str("👩🏽‍💻…", Feeds.shorten("👩🏽‍💻🙂", 1));
        fail_if_not_eq_str("🇩🇪…", Feeds.shorten("🇩🇪🇺🇦", 1));
        fail_if_not_eq_str("й…", Feeds.shorten("йога", 1));
        fail_if_not_eq_str("日本…", Feeds.shorten("日本語", 2));
        fail_if_not_eq_str("A\r\n…", Feeds.shorten("A\r\nB", 2));
        fail_if_not_eq_str("", Feeds.shorten("", 0));
        fail_if_not_eq_str("…", Feeds.shorten("Привет", 0));
        fail_if_not_eq_str("…", Feeds.shorten("Привет", -1));
    }

    private void unicode_encodings() {
        try {
            foreach (string encoding in new string[] {"UTF-16LE", "UTF-16BE", "UTF-32LE", "UTF-32BE", "UTF-8", "WINDOWS-1251"}) {
                string title = encoding == "WINDOWS-1251" ? "Привет, Игорь" : "Привет, Grüße, 日本語 👩🏽‍💻";
                string xml = "<?xml version='1.0' encoding='%s'?><rss><channel><item><title>%s</title></item></channel></rss>".printf(encoding, title);
                size_t size;
                string encoded = GLib.convert(xml, xml.length, encoding, "UTF-8", null, out size);
                foreach (bool with_bom in new bool[] {false, true}) {
                    var bytes = new ByteArray();
                    if (with_bom) {
                        switch (encoding) {
                            case "UTF-16LE": bytes.append({0xff, 0xfe}); break;
                            case "UTF-16BE": bytes.append({0xfe, 0xff}); break;
                            case "UTF-32LE": bytes.append({0xff, 0xfe, 0, 0}); break;
                            case "UTF-32BE": bytes.append({0, 0, 0xfe, 0xff}); break;
                            case "UTF-8": bytes.append({0xef, 0xbb, 0xbf}); break;
                            default: break;
                        }
                    }
                    bytes.append(((uint8[]) encoded)[0:size]);
                    var entries = Feeds.Parser.parse(Feeds.Parser.decode(bytes.data));
                    fail_if(entries.size != 1);
                    if (entries.size == 1) fail_if_not_eq_str(title, entries[0].title, encoding);
                }
            }
        } catch (Error e) { fail_if_reached(e.message); }
    }

    private void invalid_unicode() {
        uint8[] bad_utf8 = {0xc3, 0x28};
        uint8[] partial_utf16 = {0xff, 0xfe, 0x3c};
        uint8[] partial_utf32 = {0xff, 0xfe, 0, 0, 0x3c};
        uint8[] embedded_nul = {0x3c, 0x61, 0, 0x3e};
        expect_invalid_unicode(bad_utf8);
        expect_invalid_unicode(partial_utf16);
        expect_invalid_unicode(partial_utf32);
        expect_invalid_unicode(embedded_nul);
    }

    private void expect_invalid_unicode(uint8[] bytes) {
        bool rejected = false;
        try { Feeds.Parser.decode(bytes); } catch (Error e) { rejected = true; }
        fail_if(!rejected, "Invalid/truncated input must fail instead of silently dropping bytes");
    }

    private void persistence() {
        string? directory = null; Database? db = null;
        try {
            directory = DirUtils.make_tmp("dinox-feeds-XXXXXX");
            string path = Path.build_filename((!) directory, "dino.db");
            db = new Database(path, "feed-tests");
            var account = new Account(new Jid("alice@example.test"), "secret"); account.persist((!) db);
            var other = new Account(new Jid("bob@example.test"), "secret"); other.persist((!) db);
            // Upgrade an encrypted version-57 profile without losing accounts.
            rebuild_account_fixture_at_version((!) db, 57);
            ((!) db).exec("DROP TABLE feed_seen; DROP TABLE feed_subscription; UPDATE _meta SET int_val = 57 WHERE name = 'version'");
            ((!) db).close(); db = new Database(path, "feed-tests");
            fail_if(((!) db).query_column_checked("SELECT id FROM account").length != 2);
            var store = new Feeds.Store((!) db);
            var initial = new Gee.ArrayList<Feeds.Entry>(); initial.add(new Feeds.Entry() { id = "old", title = "Existing" });
            int first = store.add(account.id, "https://example.test/feed", "", 0, (int) Encryption.OMEMO, 30, initial);
            int second = store.add(other.id, "https://example.test/feed", "", 0, (int) Encryption.OMEMO, 30, new Gee.ArrayList<Feeds.Entry>());
            fail_if(!store.seen(first, initial[0].key()) || store.seen(second, initial[0].key()));
            ((!) db).exec("BEGIN IMMEDIATE"); store.mark_seen(first, "rolled-back"); ((!) db).exec("ROLLBACK");
            fail_if(store.seen(first, "rolled-back"));
            store.set_enabled(first, false, (int) Encryption.OMEMO);
            store.checked(first, "test-state", "etag", "modified");
            int64 last_check = store.get(first).checked;
            store.set_interval(first, account.id, 1440);
            foreach (int minutes in new int[] {0, 4, 1441}) {
                bool rejected = false;
                try { store.set_interval(first, account.id, minutes); } catch (Error e) { rejected = true; }
                fail_if(!rejected);
            }
            bool wrong_account = false;
            try { store.set_interval(first, other.id, 5); } catch (Error e) { wrong_account = true; }
            fail_if(!wrong_account || store.get(second).interval != 30);
            ((!) db).close(); db = new Database(path, "feed-tests"); store = new Feeds.Store((!) db);
            fail_if(!store.seen(first, initial[0].key()) || store.get(first).enabled);
            fail_if(store.get(first).interval != 1440 || store.get(first).checked != last_check ||
                store.get(first).status != "test-state" || store.get(first).etag != "etag" ||
                store.get(first).encryption != (int) Encryption.OMEMO);
            ((!) db).exec_prepared("DELETE FROM account WHERE id = ?", {account.id.to_string()});
            fail_if(store.get(first) != null || store.get(second) == null);
            fail_if(store.seen(first, initial[0].key()), "removed account retained deduplication data");
        } catch (Error e) { fail_if_reached(e.message); }
        finally { cleanup(db, directory); }
    }

    private void protocol() { run_async(0); }
    private void queue() {
        string? directory = null; Database? db = null; Feeds.Service? service = null;
        FeedTestStream? stream = null;
        try {
            directory = DirUtils.make_tmp("dinox-feed-queue-XXXXXX");
            db = new Database(Path.build_filename((!) directory, "dino.db"), "feed-tests");
            var account = new Account(new Jid("alice@example.test"), "secret") { enabled = true }; account.persist((!) db);
            var target = new Conversation(new Jid("bob@example.test"), account, Conversation.Type.CHAT) { active = true, encryption = Encryption.OMEMO }; target.persist((!) db);
            var other = new Conversation(new Jid("carol@example.test"), account, Conversation.Type.CHAT) { active = true, encryption = Encryption.OMEMO }; other.persist((!) db);
            var interactor = new StreamInteractor.for_tests((!) db);
            MessageProcessor.start(interactor, (!) db); MessageStorage.start(interactor, (!) db);
            interactor.add_module(new ContentItemStore.for_tests(interactor, (!) db));
            stream = new FeedTestStream(); bind(interactor, account, (!) stream);
            Feeds.Service.start(interactor, (!) db); service = interactor.get_module<Feeds.Service>(Feeds.Service.IDENTITY);
            int calls = 0;
            interactor.get_module<MessageProcessor>(MessageProcessor.IDENTITY).pre_message_send.connect((message, stanza, conversation) => {
                fail_if(conversation.id != target.id || message.encryption != Encryption.OMEMO);
                // Simulate an encryption provider waiting for trusted devices.
                message.marked = Message.Marked.UNSENT; calls++;
            });
            int id = service.store.add(account.id, "https://example.test/feed", "", target.id, (int) target.encryption, 30, new Gee.ArrayList<Feeds.Entry>());
            uint8[] invalid_text = {0xc3, 0x28, 0};
            bool invalid_rejected = false;
            try { service.send(target, (string) invalid_text, id, "invalid"); } catch (Error e) { invalid_rejected = true; }
            fail_if(!invalid_rejected || calls != 0 || service.store.seen(id, "invalid"));
            fail_if(((!) db).query_column_checked("SELECT id FROM message").length != 0);
            service.send(target, "Unicode: Привет", id, "new");
            service.send(target, "Unicode: Привет", id, "new");
            fail_if(calls != 1 || ((!) db).query_column_checked("SELECT id FROM message").length != 1);
            fail_if(((!) db).query_column_checked("SELECT id FROM content_item").length != 1);
            bool wrong_target = false;
            try { service.send(other, "Must not send", id, "other"); } catch (Error e) { wrong_target = true; }
            fail_if(!wrong_target || service.store.seen(id, "other"));
            target.encryption = Encryption.NONE; bool changed = false;
            try { service.send(target, "Must not leak plaintext", id, "changed"); } catch (Error e) { changed = true; }
            fail_if(!changed || calls != 1 || service.store.seen(id, "changed"));
            target.encryption = Encryption.OMEMO; service.store.set_enabled(id, false, (int) Encryption.OMEMO);
            bool paused = false;
            try { service.send(target, "Must not send after pause", id, "paused"); } catch (Error e) { paused = true; }
            fail_if(!paused || service.store.seen(id, "paused"));
        } catch (Error e) { fail_if_reached(e.message); }
        finally { if (service != null) service.shutdown(); if (stream != null) stream.get_module<Iq.Module>(Iq.Module.IDENTITY).detach(stream); cleanup(db, directory); }
    }
    private async void protocol_async() throws Error {
        string directory = DirUtils.make_tmp("dinox-social-XXXXXX");
        var db = new Database(Path.build_filename(directory, "dino.db"), "feed-tests");
        var stream = new FeedTestStream();
        try {
            var account = new Account(new Jid("alice@example.test"), "secret") { enabled = true }; account.persist(db);
            var interactor = new StreamInteractor.for_tests(db); bind(interactor, account, stream);
            var store = new Feeds.Store(db); var social = new Feeds.Social(interactor, store);
            uint8[] invalid_text = {0xc3, 0x28, 0};
            bool invalid_rejected = false;
            try { yield social.publish(account, "invalid", "Title", (string) invalid_text, false); } catch (Error e) { invalid_rejected = true; }
            fail_if(!invalid_rejected || stream.published != 0);
            stream.read_error = "item-not-found";
            foreach (string address in new string[] {"alice@example.test", "bob@example.test"}) {
                bool missing = false;
                try { yield social.read(account, address, Feeds.Social.MICROBLOG); }
                catch (Error e) { missing = e is IOError.NOT_FOUND && !e.message.contains("item-not-found"); }
                fail_if(!missing, "A missing feed needs a readable error, without a warning or fabricated empty feed");
            }
            bool missing_subscription = false;
            try { yield social.subscribe(account, "bob@example.test", Feeds.Social.MICROBLOG); }
            catch (Error e) { missing_subscription = e is IOError.NOT_FOUND; }
            fail_if(!missing_subscription || store.list().size != 0 || stream.published != 0);
            stream.read_error = "forbidden";
            GLib.Test.expect_message("xmpp-vala", GLib.LogLevelFlags.LEVEL_WARNING, "*IQ error forbidden*");
            bool forbidden = false;
            try { yield social.read(account, "bob@example.test", Feeds.Social.MICROBLOG); }
            catch (Error e) { forbidden = e is IOError.FAILED && e.message.contains("forbidden"); }
            GLib.Test.assert_expected_messages();
            fail_if(!forbidden, "Permission failures must remain visible errors and warnings");
            stream.read_error = null;
            var entries = yield social.read(account, "alice@example.test", Feeds.Social.MICROBLOG);
            fail_if(entries.size != 1 || entries[0].item_id != "wire-id" || entries[0].id != "urn:uuid:atom-id");
            if (entries.size != 1) return;
            fail_if(!entries[0].link.has_suffix("item=wire-id"));
            yield social.subscribe(account, "alice@example.test", Feeds.Social.MICROBLOG);
            fail_if(store.list().size != 1);
            int notifications = 0;
            social.updated.connect((a, source, node) => { notifications++; });
            interactor.stream_attached_modules(account, stream);
            fail_if(!stream.get_flag<ServiceDiscovery.Flag>(ServiceDiscovery.Flag.IDENTITY).own_features.contains(Feeds.Social.NS));
            var event = new MessageStanza() { from = account.bare_jid, type_ = MessageStanza.TYPE_HEADLINE };
            event.stanza.put_node(new StanzaNode.build("event", Pubsub.NS_URI_EVENT)
                .put_node(new StanzaNode.build("items", Pubsub.NS_URI_EVENT).put_attribute("node", Feeds.Social.MICROBLOG)
                    .put_node(new StanzaNode.build("item", Pubsub.NS_URI_EVENT).put_attribute("id", "no-payload"))));
            stream.get_module<MessageModule>(MessageModule.IDENTITY).received_message(stream, event);
            interactor.stream_attached_modules(account, stream); // module reuse on reconnect must not duplicate callbacks
            stream.get_module<MessageModule>(MessageModule.IDENTITY).received_message(stream, event);
            fail_if(notifications != 2);
            event.from = new Jid("mallory@example.test");
            stream.get_module<MessageModule>(MessageModule.IDENTITY).received_message(stream, event);
            fail_if(notifications != 2, "Unsubscribed sender invalidated the feed");
            yield social.unsubscribe(account, store.list()[0]); fail_if(store.list().size != 0);
            yield social.publish(account, "fixed-id", "Grüße", "Привет", false,
                Feeds.Social.item_uri("bob@example.test", Feeds.Social.MICROBLOG, "wire-id"), "urn:uuid:original");
            fail_if(stream.published != 1 || stream.last_post == null);
            var post = (!) stream.last_post;
            fail_if_not_eq_str("urn:uuid:fixed-id", post.get_subnode("id", Feeds.ATOM).get_string_content());
            fail_if_not_eq_str("urn:uuid:original", post.get_subnode("in-reply-to", "http://purl.org/syndication/thread/1.0").get_attribute("ref"));
            bool blocked = false;
            try { yield social.publish(account, "other-id", "Public", "Must not send", true); } catch (Error e) { blocked = true; }
            fail_if(!blocked || stream.published != 1, "A post changed an existing private feed's visibility");
            yield social.retract(account, "fixed-id"); fail_if(stream.retracted != 1);
            social.shutdown();
        } finally { stream.get_module<Iq.Module>(Iq.Module.IDENTITY).detach(stream); cleanup(db, directory); }
    }

    private void http() { run_async(1); }
    private async void http_async() throws Error {
        string directory = DirUtils.make_tmp("dinox-feed-http-XXXXXX");
        var db = new Database(Path.build_filename(directory, "dino.db"), "feed-tests");
        var stream = new FeedTestStream();
        var server = new Soup.Server("server-header", "DinoX-feed-test", null);
        Feeds.Service? service = null;
        try {
            int requests = 0;
            var account = new Account(new Jid("alice@example.test"), "secret") { enabled = true }; account.persist(db);
            server.add_handler(null, (s, message, path, query) => {
                requests++;
                if (path == "/redirect") { message.set_redirect(302, "/feed"); return; }
                if (path == "/change") account.proxy_type = "socks5";
                if (message.get_request_headers().get_one("If-None-Match") == "tag") { message.set_status(304, null); return; }
                message.set_status(200, null);
                string body = path == "/large" ? string.nfill(Feeds.MAX_BYTES + 1, 'x') : "<rss><channel><item><guid>x</guid><title>HTTP ✓</title></item></channel></rss>";
                set_feed_server_response(message, "application/rss+xml", Soup.MemoryUse.COPY, body, body.length);
                message.get_response_headers().replace("ETag", "tag");
            });
            server.listen_local(0, 0);
            string base_uri = server.get_uris().data.to_string();
            var interactor = new StreamInteractor.for_tests(db); bind(interactor, account, stream);
            Feeds.Service.start(interactor, db); service = interactor.get_module<Feeds.Service>(Feeds.Service.IDENTITY);
            var result = yield ((!) service).fetch(account, base_uri + "redirect");
            fail_if(result.entries.size != 1 || result.entries[0].title != "HTTP ✓");
            result = yield ((!) service).fetch(account, base_uri + "feed", result.etag);
            fail_if(!result.unchanged);
            bool oversized = false;
            try { yield ((!) service).fetch(account, base_uri + "large"); } catch (Error e) { oversized = true; }
            fail_if(!oversized);
            var cancelled = new Cancellable(); cancelled.cancel(); bool stopped = false;
            try { yield ((!) service).fetch(account, base_uri + "feed", "", "", cancelled); } catch (Error e) { stopped = e is IOError.CANCELLED; }
            fail_if(!stopped);
            bool route_changed = false;
            try { yield ((!) service).fetch(account, base_uri + "change"); } catch (Error e) { route_changed = e is IOError.CANCELLED; }
            fail_if(!route_changed, "A route change did not cancel the old request");
            var unused = new SocketListener();
            uint16 port = unused.add_any_inet_port(null); unused.close();
            account.proxy_host = "127.0.0.1"; account.proxy_port = port;
            int requests_before = requests; bool proxy_failed = false;
            try { yield ((!) service).fetch(account, base_uri + "feed"); } catch (Error e) { proxy_failed = true; }
            fail_if(!proxy_failed || requests != requests_before, "An unavailable SOCKS5 proxy fell back to direct HTTP");
            account.enabled = false; bool offline = false;
            try { yield ((!) service).fetch(account, base_uri + "feed"); } catch (Error e) { offline = true; }
            fail_if(!offline, "An offline account fetched a feed");
        } finally { if (service != null) ((!) service).shutdown(); server.disconnect(); stream.get_module<Iq.Module>(Iq.Module.IDENTITY).detach(stream); cleanup(db, directory); }
    }

    private async void execute(int which) throws Error {
        if (which == 0) yield protocol_async(); else yield http_async();
    }
    private void run_async(int which) {
        bool done = false; Error? failure = null; bool expired = false;
        var timer = new TimeoutSource(10000); timer.set_callback(() => { expired = true; return Source.REMOVE; }); timer.attach(null);
        execute.begin(which, (obj, result) => { try { execute.end(result); } catch (Error e) { failure = e; } done = true; });
        while (!done && !expired) MainContext.default().iteration(true);
        timer.destroy(); fail_if(expired, "Feed test timed out");
        fail_if(failure != null, failure != null ? failure.message : null);
    }
    private static void bind(StreamInteractor interactor, Account account, FeedTestStream stream) throws Error {
        var flag = new Bind.Flag(); flag.my_jid = account.bare_jid.with_resource("test"); flag.finished = true;
        stream.add_flag(flag); stream.negotiation_complete = true;
        interactor.connection_manager.set_connected_stream_for_tests(account, stream);
    }
    private static void cleanup(Database? db, string? directory) {
        if (db != null) ((!) db).close();
        if (directory == null) return;
        string path = Path.build_filename((!) directory, "dino.db");
        FileUtils.remove(path); FileUtils.remove(path + "-wal"); FileUtils.remove(path + "-shm"); DirUtils.remove((!) directory);
    }
}

private class FeedTestStream : XmppStream {
    public string? read_error;
    public int published;
    public int retracted;
    public StanzaNode? last_post;
    public FeedTestStream() throws Error {
        base(new Jid("example.test"));
        add_module(new Iq.Module()); add_module(new Pubsub.Module());
        add_module(new MessageModule());
        add_module(new ServiceDiscovery.Module.with_identity("client", "pc", "Feed fixture"));
        add_flag(new ServiceDiscovery.Flag());
        get_module<Iq.Module>(Iq.Module.IDENTITY).attach(this);
    }
    public override async void connect() throws IOError { }
    public override async void disconnect() throws IOError { }
    public override async void setup() throws IOError { }
    public override async StanzaNode read() throws IOError { throw new IOError.NOT_CONNECTED("Fixture stream"); }
    public override async void write_async(StanzaNode request, int priority = Priority.DEFAULT, Cancellable? cancellable = null) throws IOError {
        request.to_xml();
        var response = new StanzaNode.build("iq", "jabber:client").put_attribute("type", "result")
            .put_attribute("id", request.get_attribute("id")).put_attribute("from", request.get_attribute("to"));
        var pubsub = request.get_subnode("pubsub", Pubsub.NS_URI);
        if (pubsub != null) {
            var result = new StanzaNode.build("pubsub", Pubsub.NS_URI).add_self_xmlns();
            if (pubsub.get_subnode("items", Pubsub.NS_URI) != null) {
                if (read_error != null) {
                    response.set_attribute("type", "error");
                    response.put_node(new StanzaNode.build("error", "jabber:client").put_attribute("type", "cancel")
                        .put_node(new StanzaNode.build((!) read_error, "urn:ietf:params:xml:ns:xmpp-stanzas").add_self_xmlns()));
                    Idle.add(() => { received_iq_stanza(this, response); return Source.REMOVE; });
                    return;
                }
                var entry = new StanzaNode.build("entry", Feeds.ATOM).add_self_xmlns()
                    .put_node(new StanzaNode.build("id", Feeds.ATOM).put_node(new StanzaNode.text("urn:uuid:atom-id")))
                    .put_node(new StanzaNode.build("title", Feeds.ATOM).put_node(new StanzaNode.text("Fixture")));
                result.put_node(new StanzaNode.build("items", Pubsub.NS_URI).put_attribute("node", Feeds.Social.MICROBLOG)
                    .put_node(new StanzaNode.build("item", Pubsub.NS_URI).put_attribute("id", "wire-id").put_node(entry)));
            }
            if (pubsub.get_subnode("subscribe", Pubsub.NS_URI) != null)
                result.put_node(new StanzaNode.build("subscription", Pubsub.NS_URI).put_attribute("subscription", "subscribed"));
            var publish = pubsub.get_subnode("publish", Pubsub.NS_URI);
            if (publish != null) { published++; last_post = publish.get_subnode("item", Pubsub.NS_URI).get_subnode("entry", Feeds.ATOM); }
            if (pubsub.get_subnode("retract", Pubsub.NS_URI) != null) retracted++;
            response.put_node(result);
        } else {
            const string owner = "http://jabber.org/protocol/pubsub#owner";
            var form = new StanzaNode.build("x", "jabber:x:data").add_self_xmlns().put_attribute("type", "form")
                .put_node(new StanzaNode.build("field", "jabber:x:data").put_attribute("var", "pubsub#access_model")
                    .put_node(new StanzaNode.build("value", "jabber:x:data").put_node(new StanzaNode.text("presence"))));
            response.put_node(new StanzaNode.build("pubsub", owner).add_self_xmlns()
                .put_node(new StanzaNode.build("configure", owner).put_attribute("node", Feeds.Social.MICROBLOG).put_node(form)));
        }
        Idle.add(() => { received_iq_stanza(this, response); return Source.REMOVE; });
    }
}
}

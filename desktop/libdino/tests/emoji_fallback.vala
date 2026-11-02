using Xmpp;
using Xmpp.Xep;
using Dino.Entities;

namespace Dino.Test {
class EmojiFallbackTest : Gee.TestCase {
    public EmojiFallbackTest() {
        base("EmojiFallback");
        add_test("inline_images_keep_text_without_creating_transfers", () => { check(false); });
        add_test("mixed_emoji_and_regular_file_keep_text_and_attachment", () => { check(true); });
        add_test("emoji_text_survives_attached_sources", () => { check(false, true); });
        add_test("empty_source_elements_do_not_hide_emoji_text", () => { check(false, true, true); });
    }
    private void check(bool mixed, bool attached_sources = false, bool empty_sources = false) {
        CorrectionTestContext? context = null;
        var previous = GLib.Application.get_default();
        try {
            context = new CorrectionTestContext(true);
            var application = new EmojiTestApplication(context.db, context.stream_interactor);
            GLib.Application.set_default(application);
            RosterManager.start(context.stream_interactor, context.db);
            Dino.StatelessFileSharing.start(context.stream_interactor, context.db);
            var message = context.create_message("Hi :wave:", false, "emoji", context.time);
            var wire = new MessageStanza("emoji") { from=message.from, to=message.to, body=message.body, type_="chat" };
            wire.stanza.put_node(new StanzaNode.build("markup", MessageMarkup.NS_URI)
                .put_node(new StanzaNode.build("span", MessageMarkup.NS_URI)
                    .put_attribute("start", "3").put_attribute("end", "9")
                    .put_node(new StanzaNode.build("emoji", MessageMarkup.EMOJI_NS_URI)
                        .put_node(new StanzaNode.build("hash", CryptographicHashes.NS_URI)
                            .put_attribute("algo", "sha-256").put_node(new StanzaNode.text("AQIDBA=="))))));
            add_share(wire, "AQIDBA==");
            if (mixed) add_share(wire, "BQYHCA==");
            if (attached_sources) {
                var sources = new StanzaNode.build("sources", Xep.StatelessFileSharing.NS_URI);
                if (!empty_sources) sources.put_node(HttpSchemeForUrlData.to_stanza_node("https://example.test/image.png"));
                wire.stanza.put_node(sources);
                wire.stanza.put_node(MessageAttaching.to_stanza_node("earlier-file-message"));
            }
            bool done = false; bool stopped = false;
            var loop = new MainLoop();
            context.processor.received_pipeline.run.begin(message, wire, context.conversation, null, (obj, res) => {
                stopped = context.processor.received_pipeline.run.end(res); done = true; loop.quit();
            });
            if (!done) loop.run();
            assert_false(stopped);
            assert_true(message.get_markups().is_empty);
            var item = context.store.get_item_by_foreign(context.conversation, 1, message.id) as MessageItem;
            assert_nonnull(item); assert_cmpstr(item.message.body, CompareOperator.EQ, "Hi :wave:");
            assert_true(context.db.file_transfer.select().count() == (mixed ? 1 : 0));
            assert_true(context.db.content_item.select()
                .with(context.db.content_item.content_type, "=", 2).count() == (mixed ? 1 : 0));
        } catch (Error e) { fail_if_reached(e.message); }
        GLib.Application.set_default(previous);
        if (context != null) context.close();
    }
    private void add_share(MessageStanza stanza, string hash) {
        var metadata = new FileMetadataElement.FileMetadata() {name="image.png", mime_type="image/png", size=100};
        metadata.hashes.add(new CryptographicHashes.Hash.with_checksum(ChecksumType.SHA256, hash));
        stanza.stanza.put_node(new StanzaNode.build("file-sharing", Xep.StatelessFileSharing.NS_URI)
            .put_node(metadata.to_stanza_node()));
    }
    private class EmojiTestApplication : GLib.Application, Dino.Application {
        public Database db { get; set; }
        public string? db_key { get; set; }
        public Dino.Security.FileEncryption file_encryption { get; set; }
        public Dino.Entities.Settings settings { get; set; }
        public StreamInteractor stream_interactor { get; set; }
        public Dino.Plugins.Registry plugin_registry { get; set; default=new Dino.Plugins.Registry(); }
        public SearchPathGenerator? search_path_generator { get; set; }
        public EmojiTestApplication(Database db, StreamInteractor interactor) {
            Object(application_id: "im.dinox.emoji-test", flags: GLib.ApplicationFlags.NON_UNIQUE);
            this.db = db; stream_interactor = interactor;
            settings = new Dino.Entities.Settings.from_db(db);
        }
        public void handle_uri(string jid, string query, Gee.Map<string, string> options) { }
    }
}
}

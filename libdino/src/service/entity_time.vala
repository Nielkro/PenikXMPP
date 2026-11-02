using GLib;
using Dino.Entities;

namespace Dino.Service {

    public class EntityTime : Object, StreamInteractionModule, Xmpp.Iq.Handler {
        public const string IDENTITY_STRING = "entity_time";
        public static ModuleIdentity<EntityTime> IDENTITY = new ModuleIdentity<EntityTime>(IDENTITY_STRING);

        public string id { get { return IDENTITY_STRING; } }

        private const string XMLNS = "urn:xmpp:time";

        private StreamInteractor stream_interactor;
        private Database db;

        public static EntityTime start(StreamInteractor stream_interactor, Database db) {
            EntityTime m = new EntityTime(stream_interactor, db);
            stream_interactor.add_module(m);
            return m;
        }

        private Gee.Map<Xmpp.XmppStream, Account> stream_account = new Gee.HashMap<Xmpp.XmppStream, Account>();

        public EntityTime(StreamInteractor stream_interactor, Database db) {
            this.stream_interactor = stream_interactor;
            this.db = db;
            
            stream_interactor.stream_attached_modules.connect((account, stream) => {
                stream_account[stream] = account;
                stream.get_module<Xmpp.Iq.Module>(Xmpp.Iq.Module.IDENTITY).register_for_namespace(XMLNS, this);
                
                // Add feature to disco
                var disco = stream.get_module<Xmpp.Xep.ServiceDiscovery.Module>(Xmpp.Xep.ServiceDiscovery.Module.IDENTITY);
                if (disco != null) disco.add_feature(stream, XMLNS);
            });
        }
        
        public async void on_iq_get(Xmpp.XmppStream stream, Xmpp.Iq.Stanza query) {
            Account? account = stream_account[stream];
            if (account == null) return;

            string custom_tz = db.account_settings.get_value(account.id, "timezone") ?? "system";
            var iq_module = stream.get_module<Xmpp.Iq.Module>(Xmpp.Iq.Module.IDENTITY);
            if (iq_module == null) return;
            
            // If user has disabled timezone sharing for privacy
            if (custom_tz == "disabled") {
                var error_iq = new Xmpp.Iq.Stanza.error(query, new Xmpp.ErrorStanza.service_unavailable()) { to = query.from };
                iq_module.send_iq(stream, error_iq);
                return;
            }
            
            var result = new Xmpp.Iq.Stanza.result(query);
            
            var time_el = new Xmpp.StanzaNode.build("time");
            time_el.set_attribute("xmlns", XMLNS);
            
            // Send current local time by default
            var now = new DateTime.now_local();
            
            if (custom_tz != "system" && custom_tz != "") {
                try {
                    var tz = new TimeZone.identifier(custom_tz);
                    now = new DateTime.now(tz);
                } catch (Error e) {
                    // Fallback to local time
                }
            }
            
            // Format tzo like +02:00 or -06:00
            TimeSpan offset = now.get_utc_offset();
            int hours = (int)(offset / TimeSpan.HOUR);
            int minutes = (int)((offset % TimeSpan.HOUR) / TimeSpan.MINUTE).abs();
            string tzo_str = "%s%02d:%02d".printf(hours >= 0 ? "+" : "-", hours.abs(), minutes);
            var tzo_el = new Xmpp.StanzaNode.build("tzo");
            tzo_el.val = tzo_str;
            time_el.put_node(tzo_el);

            // Format UTC string
            string utc_str = now.to_utc().format("%Y-%m-%dT%H:%M:%SZ");
            var utc_el = new Xmpp.StanzaNode.build("utc");
            utc_el.val = utc_str;
            time_el.put_node(utc_el);

            result.stanza.put_node(time_el);
            iq_module.send_iq(stream, result);
        }

        public async string? request_time(Account account, Xmpp.Jid target) {
            Xmpp.XmppStream stream = stream_interactor.connection_manager.get_stream(account);
            if (stream == null) return null;

            var time_el = new Xmpp.StanzaNode.build("time");
            time_el.set_attribute("xmlns", XMLNS);
            
            var iq = new Xmpp.Iq.Stanza.get(time_el);
            iq.to = target;

            try {
                var iq_module = stream.get_module<Xmpp.Iq.Module>(Xmpp.Iq.Module.IDENTITY);
                if (iq_module != null) {
                    Xmpp.Iq.Stanza response = yield iq_module.send_iq_async(stream, iq);
                    if (response.type_ == Xmpp.Iq.Stanza.TYPE_RESULT) {
                        var resp_el = response.stanza.get_subnode("time", XMLNS);
                        if (resp_el != null) {
                            var tzo_el = resp_el.get_subnode("tzo");
                            if (tzo_el != null) {
                                return tzo_el.val;
                            }
                        }
                    }
                }
            } catch (Error e) {
                // Not supported or timeout
            }
            return null;
        }
    }
}

using Gee;
using Xmpp.Xep;

namespace Xmpp.MessageArchiveManagement {

public const string NS_URI = "urn:xmpp:mam:2";

public class QueryResult {
    public bool error { get; set; default=false; }
    public bool malformed { get; set; default=false; }
    public bool complete { get; set; default=false; }
    public string? first { get; set; }
    public string? last { get; set; }
}

/**
 * Keeps request cancellation out of Vala's generated outer GTask.
 *
 * A bare Cancellable parameter makes GTask override a deliberately returned
 * QueryResult with NULL as soon as cancellation wins.  MAM instead needs to
 * translate that cancellation into QueryResult.error after closing the IQ
 * waiter and active-query window.
 */
public class QueryCancellation {
    public Cancellable? cancellable { get; private set; }

    public QueryCancellation(Cancellable? cancellable) {
        this.cancellable = cancellable;
    }
}

public class Module : XmppStreamModule {
    public static ModuleIdentity<Module> IDENTITY = new ModuleIdentity<Module>(NS_URI, "0313_message_archive_management");

    public signal void feature_available(XmppStream stream);

    private ReceivedPipelineListener received_pipeline_listener = new ReceivedPipelineListener();

    public override void attach(XmppStream stream) {
        stream.get_module<MessageModule>(MessageModule.IDENTITY).received_pipeline.connect(received_pipeline_listener);
        stream.stream_negotiated.connect(on_stream_negotiated);
    }

    public override void detach(XmppStream stream) {
        stream.get_module<MessageModule>(MessageModule.IDENTITY).received_pipeline.disconnect(received_pipeline_listener);
        stream.stream_negotiated.disconnect(on_stream_negotiated);
    }

    public override string get_ns() { return NS_URI; }
    public override string get_id() { return IDENTITY.id; }

    private void on_stream_negotiated(XmppStream stream) {
        query_availability.begin(stream, (_, res) => {
            query_availability.end(res);
        });
    }

    private async void query_availability(XmppStream stream) {
        Jid own_jid = stream.get_flag(Bind.Flag.IDENTITY).my_jid.bare_jid;
        bool mam_available = yield stream.get_module<ServiceDiscovery.Module>(ServiceDiscovery.Module.IDENTITY).has_entity_feature(stream, own_jid, NS_URI);
        if (mam_available) {
            feature_available(stream);
        }
    }
}

    internal StanzaNode create_base_query(XmppStream stream, string? queryid, Gee.List<DataForms.DataForm.Field> fields) {
        DataForms.DataForm data_form = new DataForms.DataForm();

        DataForms.DataForm.HiddenField form_type_field = new DataForms.DataForm.HiddenField() { var="FORM_TYPE" };
        form_type_field.set_value_string(NS_URI);
        data_form.add_field(form_type_field);

        foreach (var field in fields) {
            data_form.add_field(field);
        }

        StanzaNode query_node = new StanzaNode.build("query", NS_URI).add_self_xmlns().put_node(data_form.get_submit_node());
        query_node.put_attribute("queryid", queryid);
        return query_node;
    }

    internal async QueryResult query_archive(XmppStream stream, Jid? mam_server,
            StanzaNode query_node,
            QueryCancellation? cancellation = null) {

        var res = new QueryResult();
        Flag flag = Flag.get_flag(stream);
        MainContext owner_context = MainContext.ref_thread_default();
        string? query_id = query_node.get_attribute("queryid");
        if (flag == null || query_id == null) { res.error = true; return res; }
        flag.begin_active_query(query_id);

        // Build and send query
        Iq.Stanza iq = new Iq.Stanza.set(query_node) { to=mam_server };

        Iq.Stanza result_iq;
        try {
            result_iq = yield stream.get_module<Iq.Module>(Iq.Module.IDENTITY)
                .send_iq_async(stream, iq, Priority.LOW,
                    cancellation != null
                        ? ((!) cancellation).cancellable : null);
        } catch (GLib.Error e) {
            // Once the owning request is cancelled or fails, late result
            // messages must not keep entering the history pipeline.
            flag.end_active_query(query_id);
            if (!(e is IOError.CANCELLED)) {
                warning("Failed to query archive: %s", e.message);
            }
            res.error = true;
            return res;
        }

        // Result messages precede the final IQ on the wire, but their pipeline
        // callbacks can still be queued.  Keep the query accepted until a
        // low-priority idle, on every successful-IQ parse path (including
        // malformed responses), instead of leaking it on early returns.
        var cleanup_source = new IdleSource();
        cleanup_source.set_priority(Priority.LOW);
        cleanup_source.set_callback(() => {
            flag.end_active_query(query_id);
            return Source.REMOVE;
        });
        cleanup_source.attach(owner_context);

        // An error IQ cannot acknowledge a query, even if it also contains
        // a syntactically valid fin/RSM payload.
        if (result_iq.is_error()) { res.error = true; return res; }

        // Parse the response IQ into a QueryResult.
        StanzaNode? fin_node = result_iq.stanza.get_subnode("fin", NS_URI);
        if (fin_node == null) { res.malformed = true; return res; }

        StanzaNode? rsm_node = fin_node.get_subnode("set", Xmpp.ResultSetManagement.NS_URI);
        if (rsm_node == null) { res.malformed = true; return res; }

        res.first = rsm_node.get_deep_string_content("first");
        res.last = rsm_node.get_deep_string_content("last");
        if ((res.first == null) != (res.last == null)) { res.malformed = true; return res; }
        res.complete = fin_node.get_attribute_bool("complete", false, NS_URI);

        return res;
    }

public class ReceivedPipelineListener : StanzaListener<MessageStanza> {

    private string[] after_actions_const = new string[] {};

    public override string action_group { get { return "EXTRACT_MESSAGE_1"; } }
    public override string[] after_actions { get { return after_actions_const; } }

    public override async bool run(XmppStream stream, MessageStanza message) {
        Flag flag = Flag.get_flag(stream);

        StanzaNode? message_node = message.stanza.get_deep_subnode(NS_URI + ":result", StanzaForwarding.NS_URI + ":forwarded", Xmpp.NS_URI + ":message");
        if (message_node != null) {
            StanzaNode? forward_node = message.stanza.get_deep_subnode(NS_URI + ":result", StanzaForwarding.NS_URI + ":forwarded", DelayedDelivery.NS_URI + ":delay");
            DateTime? datetime = DelayedDelivery.get_time_for_node(forward_node);
            string? mam_id = message.stanza.get_deep_attribute(NS_URI + ":result", NS_URI + ":id");
            string? query_id = message.stanza.get_deep_attribute(NS_URI + ":result", NS_URI + ":queryid");

            if (query_id == null) {
                warning("Received MAM message without queryid from %s, ignoring", message.from.to_string());
                return true;
            }

            if (!flag.active_query_ids.contains(query_id)) {
                warning("Received MAM message from %s with unknown query id %s, ignoring", message.from.to_string(), query_id ?? "<none>");
                return true;
            }
            Jid? inner_from = null;
            try {
                inner_from = new Jid(message_node.get_attribute("from"));
            } catch (InvalidJidError e) {
                warning("Received MAM message with invalid from attribute in forwarded message from %s, ignoring", message.from.to_string());
                return true;
            }
            if (!message.from.equals(stream.get_flag(Bind.Flag.IDENTITY).my_jid.bare_jid) && !message.from.equals_bare(inner_from)) {
                warning("Received MAM message from %s illegally impersonating %s, ignoring", message.from.to_string(), inner_from.to_string());
                return true;
            }

            message.add_flag(new MessageFlag(message.from, datetime, mam_id, query_id));

            message.stanza = message_node;
            message.rerun_parsing = true;
        }
        return false;
    }
}

public class Flag : XmppStreamFlag {
    public static FlagIdentity<Flag> IDENTITY = new FlagIdentity<Flag>(NS_URI, "message_archive_management");
    public bool cought_up { get; set; default=false; }
    public Gee.Set<string> active_query_ids { get; set; default = new HashSet<string>(); }
    private HashMap<string, uint> active_query_refcounts =
        new HashMap<string, uint>();

    internal void begin_active_query(string query_id) {
        uint count = active_query_refcounts.has_key(query_id)
            ? active_query_refcounts[query_id] : 0;
        active_query_refcounts[query_id] = count + 1;
        active_query_ids.add(query_id);
    }

    internal void end_active_query(string query_id) {
        if (!active_query_refcounts.has_key(query_id)) return;
        uint count = active_query_refcounts[query_id];
        if (count <= 1) {
            active_query_refcounts.unset(query_id);
            active_query_ids.remove(query_id);
        } else {
            active_query_refcounts[query_id] = count - 1;
        }
    }

    public static Flag get_flag(XmppStream stream) {
        Flag? flag = stream.get_flag(Flag.IDENTITY);
        if (flag == null) {
            flag = new Flag();
            stream.add_flag(flag);
        }
        return flag;
    }

    public override string get_ns() { return NS_URI; }
    public override string get_id() { return IDENTITY.id; }
}

public class MessageFlag : Xmpp.MessageFlag {
    public const string ID = "message_archive_management";

    public Jid sender_jid { get; private set; }
    public DateTime? server_time { get; private set; }
    public string? mam_id { get; private set; }
    public string? query_id { get; private set; }

    public MessageFlag(Jid sender_jid, DateTime? server_time, string? mam_id, string? query_id) {
        this.sender_jid = sender_jid;
        this.server_time = server_time;
        this.mam_id = mam_id;
        this.query_id = query_id;
    }

    public static MessageFlag? get_flag(MessageStanza message) { return (MessageFlag) message.get_flag(NS_URI, ID); }

    public override string get_ns() { return NS_URI; }
    public override string get_id() { return ID; }
}

}

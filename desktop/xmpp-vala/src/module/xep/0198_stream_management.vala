using Gee;

namespace Xmpp.Xep.StreamManagement  {

public const string NS_URI = "urn:xmpp:sm:3";

public class Module : XmppStreamNegotiationModule, WriteNodeFunc {
    public static ModuleIdentity<Module> IDENTITY = new ModuleIdentity<Module>(NS_URI, "0198_stream_management");

    public uint32 h_inbound = 0;
    public uint32 h_outbound = 0;

    private const int MAX_IN_FLIGHT_STANZAS = 1024;

    public string? session_id { get; set; default=null; }
    public Gee.List<XmppStreamFlag> flags = null;
    private HashMap<uint32, QueueItem> in_flight_stanzas = new HashMap<uint32, QueueItem>();
    private weak XmppStream? terminally_discarded_stream = null;
    private Gee.Queue<QueueItem> node_queue = new PriorityQueue<QueueItem>((a, b) => {
        return a.io_priority - b.io_priority;
    });

    private class QueueItem {
        public StanzaNode node;
        public int io_priority;
        public Cancellable? cancellable;
        public Promise<void*> write_promise;
        public Promise<void*> ack_promise;
        private bool write_finished = false;
        private bool ack_finished = false;

        public QueueItem(StanzaNode node, int io_priority, Cancellable? cancellable) {
            this.node = node;
            this.io_priority = io_priority;
            this.cancellable = cancellable;
            this.write_promise = new Promise<void*>();
            this.ack_promise = new Promise<void*>();
        }

        public void complete_write() {
            if (write_finished) return;
            write_finished = true;
            write_promise.set_value(null);
        }

        public void fail_write(Error error) {
            if (write_finished) return;
            write_finished = true;
            write_promise.set_exception(error);
        }

        public void complete_ack() {
            if (ack_finished) return;
            ack_finished = true;
            ack_promise.set_value(null);
        }

        public void fail_ack(Error error) {
            if (ack_finished) return;
            ack_finished = true;
            ack_promise.set_exception(error);
        }
    }

    public async void write_stanza(XmppStream stream, StanzaNode node, int io_priority = Priority.DEFAULT, Cancellable? cancellable = null) throws IOError {
        Future<void*> future = enqueue_stanza(stream, node, io_priority, cancellable);
        if (!should_wait_for_write_completion(node)) return;

        // User-visible content must not be marked as sent before it was
        // actually written to the stream. Lightweight state/receipt/marker
        // messages still use the low-latency queue path above.
        try {
            yield future.wait_async();
        } catch (FutureError e) {
            if (e is FutureError.ABANDON_PROMISE) {
                throw new IOError.FAILED("Future abandoned: %s".printf(e.message));
            } else if (e is FutureError.EXCEPTION) {
                if (future.exception is IOError) {
                    throw (IOError) future.exception;
                } else {
                    throw new IOError.FAILED("Unknown error %s".printf(future.exception.message));
                }
            } else {
                throw new IOError.FAILED("Unknown future error: %s".printf(e.message));
            }
        }
    }

    public static bool should_wait_for_write_completion(StanzaNode node) {
        if (node.name != "message") return false;

        return node.get_subnode("body", "jabber:client") != null ||
            node.get_subnode("encrypted", "eu.siacs.conversations.axolotl") != null ||
            node.get_subnode("encrypted", "urn:xmpp:omemo:2") != null ||
            node.get_subnode("openpgp", "urn:xmpp:openpgp:0") != null ||
            node.get_subnode("x", "jabber:x:encrypted") != null ||
            node.get_subnode("file-sharing", "urn:xmpp:sfs:0") != null ||
            node.get_subnode("x", "jabber:x:oob") != null;
    }

    private Future<void*> enqueue_stanza(XmppStream stream, StanzaNode node, int io_priority, Cancellable? cancellable) {
        var queue_item = new QueueItem(node, io_priority, cancellable);
        if (stream == terminally_discarded_stream) {
            var error = new IOError.CANCELLED(
                "Stream-management session was discarded");
            queue_item.fail_write(error);
            queue_item.fail_ack(error);
            return queue_item.write_promise.future;
        }
        node_queue.offer(queue_item);
        check_queue(stream);
        return queue_item.write_promise.future;
    }

    internal async void write_node(XmppStream stream, StanzaNode node, int io_priority = Priority.DEFAULT, Cancellable? cancellable = null) {
        if (stream == terminally_discarded_stream) return;
        StanzaWriter? writer = ((IoXmppStream)stream).writer;
        if (writer == null) return;
        try {
            stream.log.node("OUT", node, stream);
            if (node.name == "message" || node.name == "iq" || node.name == "presence") {
                var r_node = new StanzaNode.build("r", NS_URI).add_self_xmlns();
                stream.log.node("OUT", r_node, stream);
                yield ((!)writer).write_nodes(node, r_node, io_priority, cancellable);
            } else {
                yield ((!)writer).write_node(node, io_priority, cancellable);
            }
        } catch (IOError e) { }
    }

    private async void write_queue_item(XmppStream stream, QueueItem queue_item) {
        StanzaWriter? writer = ((IoXmppStream)stream).writer;
        if (writer == null) {
            IOError error = new IOError.NOT_CONNECTED("trying to write, but no stream open");
            queue_item.fail_write(error);
            queue_item.fail_ack(error);
            return;
        }
        try {
            StanzaNode node = queue_item.node;
            stream.log.node("OUT", node, stream);
            if (node.name == "message" || node.name == "iq" || node.name == "presence") {
                var r_node = new StanzaNode.build("r", NS_URI).add_self_xmlns();
                stream.log.node("OUT", r_node, stream);
                yield ((!)writer).write_nodes(node, r_node, queue_item.io_priority, queue_item.cancellable);
            } else {
                yield ((!)writer).write_node(node, queue_item.io_priority, queue_item.cancellable);
            }
            queue_item.complete_write();
        } catch (IOError e) {
            queue_item.fail_write(e);
            queue_item.fail_ack(e);
        }
    }

    private void check_queue(XmppStream stream) {
        while (!node_queue.is_empty && in_flight_stanzas.size < MAX_IN_FLIGHT_STANZAS) {
            QueueItem queue_item = node_queue.poll();
            try {
                if (queue_item.cancellable != null) queue_item.cancellable.set_error_if_cancelled();
            } catch (IOError e) {
                queue_item.fail_write(e);
                queue_item.fail_ack(e);
                continue;
            }
            StanzaNode node = queue_item.node;

            if (node.name == "message" || node.name == "iq" || node.name == "presence") {
                in_flight_stanzas[++h_outbound] = queue_item;
            }
            write_queue_item.begin(stream, queue_item);
        }
    }

    public override void attach(XmppStream stream) {
        stream.get_module<Bind.Module>(Bind.Module.IDENTITY).bound_to_resource.connect(check_enable);
        stream.received_features_node.connect(check_resume);

        stream.received_nonza.connect(on_received_nonza);
        stream.received_message_stanza.connect(on_stanza_received);
        stream.received_presence_stanza.connect(on_stanza_received);
        stream.received_iq_stanza.connect(on_stanza_received);
    }

    public override void detach(XmppStream stream) {
        stream.get_module<Bind.Module>(Bind.Module.IDENTITY).bound_to_resource.disconnect(check_enable);
        stream.received_features_node.disconnect(check_resume);

        stream.received_nonza.disconnect(on_received_nonza);
        stream.received_message_stanza.disconnect(on_stanza_received);
        stream.received_presence_stanza.disconnect(on_stanza_received);
        stream.received_iq_stanza.disconnect(on_stanza_received);
    }

    public static void require(XmppStream stream) {
        if (stream.get_module<Module>(IDENTITY) == null) stream.add_module(new Module());
    }

    /**
     * Forget a resumable session after an explicit terminal disconnect.
     * Queued/in-flight work belongs to that session and must never be replayed
     * by a later fresh login.
     */
    public void discard_session(string reason =
            "Stream-management session was discarded",
            XmppStream? discarded_stream = null) {
        terminally_discarded_stream = discarded_stream;
        foreach (QueueItem item in in_flight_stanzas.values) {
            item.fail_write(new IOError.CANCELLED(reason));
            item.fail_ack(new IOError.CANCELLED(reason));
        }
        in_flight_stanzas.clear();
        while (!node_queue.is_empty) {
            QueueItem item = node_queue.poll();
            item.fail_write(new IOError.CANCELLED(reason));
            item.fail_ack(new IOError.CANCELLED(reason));
        }
        session_id = null;
        flags = null;
        h_inbound = 0;
        h_outbound = 0;
    }

    public override bool mandatory_outstanding(XmppStream stream) { return false; }

    public override bool negotiation_active(XmppStream stream) {
        return stream.has_flag(Flag.IDENTITY) && !stream.get_flag(Flag.IDENTITY).finished;
    }

    public override string get_ns() { return NS_URI; }
    public override string get_id() { return IDENTITY.id; }

    private void on_stanza_received(XmppStream stream, StanzaNode node) {
        h_inbound++;
    }

    private void check_resume(XmppStream stream) {
        if (stream == terminally_discarded_stream) return;
        if (stream_has_sm_feature(stream) && session_id != null) {
            StanzaNode node = new StanzaNode.build("resume", NS_URI).add_self_xmlns()
                .put_attribute("h", h_inbound.to_string())
                .put_attribute("previd", session_id);
            write_node.begin(stream, node);
            stream.add_flag(new Flag());
        }
    }

    private void check_enable(XmppStream stream) {
        if (stream == terminally_discarded_stream) return;
        if (stream_has_sm_feature(stream) && session_id == null) {
            StanzaNode node = new StanzaNode.build("enable", NS_URI).add_self_xmlns().put_attribute("resume", "true");
            write_node.begin(stream, node);
            stream.add_flag(new Flag());
            h_outbound = 0;
        }
    }

    private void on_received_nonza(XmppStream stream, StanzaNode node) {
        if (stream == terminally_discarded_stream && node.ns_uri == NS_URI &&
                node.name in new string[]{"enabled", "resumed"}) return;
        if (node.ns_uri == NS_URI) {
            if (node.name == "r") {
                send_ack(stream);
            } else if (node.name == "a") {
                handle_ack(stream, node);
            } else if (node.name in new string[]{"enabled", "resumed", "failed"}) {
                stream.get_flag(Flag.IDENTITY).finished = true;

                if (node.name == "enabled") {
                    h_inbound = 0;
                    session_id = node.get_attribute("id", NS_URI);
                    flags = stream.flags;
                    ((IoXmppStream)stream).write_obj = this;
                } else if (node.name == "resumed") {
                    stream.get_flag(Flag.IDENTITY).resumed = true;

                    foreach (XmppStreamFlag flag in flags) {
                        stream.add_flag(flag);
                    }

                    string? h_resumed = node.get_attribute("h", NS_URI);
                    if (h_resumed != null) {
                        h_outbound = (uint32) uint64.parse(h_resumed);
                        handle_incoming_h(stream, h_outbound);
                    }
                    foreach (var id in in_flight_stanzas.keys) {
                        node_queue.add(in_flight_stanzas[id]);
                    }
                    in_flight_stanzas.clear();
                    check_queue(stream);
                    ((IoXmppStream)stream).write_obj = this;
                } else if (node.name == "failed") {
                    session_id = null;
                    string? h_acked = node.get_attribute("h", NS_URI);
                    if (h_acked != null) {
                        h_outbound = (uint32) uint64.parse(h_acked);
                        handle_incoming_h(stream, h_outbound);
                    }
                    foreach (var id in in_flight_stanzas.keys) {
                        in_flight_stanzas[id].fail_ack(new IOError.FAILED("Stanza not acked and session not resumed"));
                    }
                    in_flight_stanzas.clear();
                    check_queue(stream);
                    stream.received_features_node(stream);
                }
            }
        }
    }

    private void send_ack(XmppStream stream) {
        StanzaNode node = new StanzaNode.build("a", NS_URI).add_self_xmlns().put_attribute("h", h_inbound.to_string());
        write_node.begin(stream, node);
    }

    private void handle_ack(XmppStream stream, StanzaNode node) {
        string? h_acked = node.get_attribute("h", NS_URI);
        if (h_acked == null) return;  // XEP-0198: h attribute is required, ignore malformed ack
        uint32 parsed_h = (uint32) uint64.parse(h_acked);
        handle_incoming_h(stream, parsed_h);
        check_queue(stream);
    }

    private void handle_incoming_h(XmppStream stream, uint32 h) {
        var remove_nrs = new ArrayList<uint32>();
        foreach (uint32 nr in in_flight_stanzas.keys) {
            // Handle uint32 wraparound: nr is acked if distance(nr, h) is small
            // Simple case: nr <= h (no wraparound)
            // Wraparound: h wrapped past 0, nr is near 2^32-1
            uint32 diff = h - nr;  // unsigned subtraction wraps correctly
            if (diff < 0x80000000) {
                remove_nrs.add(nr);
            }
        }
        foreach (uint32 nr in remove_nrs) {
            in_flight_stanzas[nr].complete_ack();
            in_flight_stanzas.unset(nr);
        }
    }

    private bool stream_has_sm_feature(XmppStream stream) {
        return stream.features.get_subnode("sm", NS_URI) != null;
    }
}

public class Flag : XmppStreamFlag {
    public static FlagIdentity<Flag> IDENTITY = new FlagIdentity<Flag>(NS_URI, "stream_management");
    public bool finished = false;
    public bool resumed = false;

    public override string get_ns() { return NS_URI; }
    public override string get_id() { return IDENTITY.id; }
}

}

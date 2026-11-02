using Gee;

namespace Xmpp.Iq {
    private const string NS_URI = "jabber:client";

    public class Module : XmppStreamNegotiationModule {
        public static ModuleIdentity<Module> IDENTITY = new ModuleIdentity<Module> (NS_URI, "iq_module"); // vala-lint=naming-convention

        public signal void preprocess_incoming_iq_set_get (XmppStream stream, Stanza iq_stanza);
        public signal void preprocess_outgoing_iq_set_get (XmppStream stream, Stanza iq_stanza);

        private HashMap<string, PendingRequest> pending_requests = new HashMap<string, PendingRequest> ();
        private HashMap<string, PendingRequest> response_listeners = new HashMap<string, PendingRequest> ();
        private ArrayList<OutgoingRequestFilter> outgoing_request_filters = new ArrayList<OutgoingRequestFilter> ();
        private ArrayList<IncomingRequestFilter> incoming_request_filters = new ArrayList<IncomingRequestFilter> ();
        private uint64 attachment_generation = 0;
        private weak XmppStream? attached_stream = null;
        private HashMap<string, ArrayList<Handler>> namespace_registrants = new HashMap<string, ArrayList<Handler>> ();
        private HashMap<string, ArrayList<Interceptor>> namespace_interceptors = new HashMap<string, ArrayList<Interceptor>> ();

        public void add_outgoing_request_filter (OutgoingRequestFilter filter) {
            if (!outgoing_request_filters.contains (filter)) outgoing_request_filters.add (filter);
        }

        public void remove_outgoing_request_filter (OutgoingRequestFilter filter) {
            outgoing_request_filters.remove (filter);
        }

        public void add_incoming_request_filter (IncomingRequestFilter filter) {
            if (!incoming_request_filters.contains (filter)) incoming_request_filters.add (filter);
        }

        public void remove_incoming_request_filter (IncomingRequestFilter filter) {
            incoming_request_filters.remove (filter);
        }

        public async Iq.Stanza send_iq_async (XmppStream stream, Iq.Stanza iq, int io_priority = Priority.DEFAULT, Cancellable? cancellable = null) throws IOError {
            if (iq.type_ != Iq.Stanza.TYPE_GET && iq.type_ != Iq.Stanza.TYPE_SET) {
                throw new IOError.INVALID_ARGUMENT ("send_iq_async requires GET or SET IQ stanza");
            }
            if (pending_requests.has_key (iq.id)) {
                throw new IOError.PENDING ("An IQ request with this id is already pending");
            }
            SourceFunc resume = send_iq_async.callback;
            var waiter = new PendingRequest (this, stream, iq, attachment_generation, null, (owned) resume);
            pending_requests[iq.id] = waiter;
            waiter.watch_cancellable (cancellable);
            prepare_and_send.begin (waiter, io_priority);
            yield;
            if (waiter.pending_error != null) throw (!) waiter.pending_error;
            return (!) waiter.return_stanza;
        }

        public delegate void OnResult (XmppStream stream, Iq.Stanza iq);
        public void send_iq (XmppStream stream, Iq.Stanza iq, owned OnResult? listener = null, int io_priority = Priority.DEFAULT, Cancellable? cancellable = null) {
            if (iq.type_ != Iq.Stanza.TYPE_GET && iq.type_ != Iq.Stanza.TYPE_SET) {
                // Responses never enter request filters (including security failures).
                preprocess_outgoing_iq_set_get (stream, iq);
                stream.write_node (iq.stanza, io_priority);
                return;
            }
            if (pending_requests.has_key (iq.id)) {
                if (listener != null) {
                    var rejected = local_failure (iq);
                    listener (stream, rejected);
                }
                return;
            }
            var waiter = new PendingRequest (this, stream, iq, attachment_generation, (owned) listener, null);
            pending_requests[iq.id] = waiter;
            waiter.watch_cancellable (cancellable);
            prepare_and_send.begin (waiter, io_priority);
        }

        // Local callback response; the failure marker is never part of wire XML.
        public static Iq.Stanza local_failure (Iq.Stanza request, IOError? error = null,
                LocalFailurePhase phase = LocalFailurePhase.UNKNOWN) {
            var failure = new Iq.Stanza.error (request, new ErrorStanza.not_acceptable (
                "IQ request could not be sent")) {
                    locally_failed = true,
                    local_failure_phase = phase,
                    local_failure_code = error != null ? ((!) error).code : -1
                };
            // Server-directed IQs legitimately omit their target; JID setters
            // require a value even though their getters may return null.
            if (request.to != null) failure.from = request.to;
            return failure;
        }

        private bool request_is_current (PendingRequest request) {
            return !request.completed && request.generation == attachment_generation &&
                (attached_stream == null || attached_stream == request.stream) &&
                pending_requests[request.iq_id] == request;
        }

        private async void prepare_and_send (PendingRequest request, int io_priority) {
            try {
                if (attached_stream != null && attached_stream != request.stream)
                    throw new IOError.CANCELLED ("IQ request belongs to a replaced stream");
                request.check_cancelled ();
                var filters = new ArrayList<OutgoingRequestFilter> ();
                filters.add_all (outgoing_request_filters);
                foreach (OutgoingRequestFilter filter in filters) {
                    yield filter.prepare_send (request.stream, request.iq, request.cancellable);
                    request.check_cancelled ();
                    if (!request_is_current (request) || !outgoing_request_filters.contains (filter)) {
                        throw new IOError.CANCELLED ("IQ preparation is no longer current");
                    }
                }
                if (!request_is_current (request)) return;
                preprocess_outgoing_iq_set_get (request.stream, request.iq);
                request.check_cancelled ();
                if (!request_is_current (request)) return;
                if (request.iq.id != request.iq_id ||
                    (request.iq.type_ != Iq.Stanza.TYPE_GET && request.iq.type_ != Iq.Stanza.TYPE_SET)) {
                    throw new IOError.INVALID_ARGUMENT ("IQ preparation changed the request identity");
                }
                // Replies cannot complete a request while its filters are still waiting.
                response_listeners[request.iq_id] = request;
                request.phase = LocalFailurePhase.WRITE;
                yield request.stream.write_async (request.iq.stanza, io_priority, request.cancellable);
                if (request.completed) return;
                request.phase = LocalFailurePhase.AWAIT_RESPONSE;
                if (!request.expects_response) request.complete_success (null);
            } catch (GLib.Error error) {
                request.complete_error (error);
            }
        }

        private void remove_request (PendingRequest request) {
            if (pending_requests[request.iq_id] == request) pending_requests.unset (request.iq_id);
            if (response_listeners[request.iq_id] == request) response_listeners.unset (request.iq_id);
        }

        public void register_for_namespace (string namespace, Handler module) {
            if (!namespace_registrants.has_key (namespace)) {
                namespace_registrants.set (namespace, new ArrayList<Handler> ());
            }
            namespace_registrants[namespace].add (module);
        }

        public void unregister_from_namespace (string namespace, Handler module) {
            ArrayList<Handler>? handlers = namespace_registrants[namespace];
            if (handlers != null) handlers.remove (module);
        }

        public void register_interceptor_for_namespace (string namespace, Interceptor interceptor) {
            if (!namespace_interceptors.has_key (namespace)) {
                namespace_interceptors.set (namespace, new ArrayList<Interceptor> ());
            }
            namespace_interceptors[namespace].add (interceptor);
        }

        public void unregister_interceptor_from_namespace (string namespace, Interceptor interceptor) {
            ArrayList<Interceptor>? interceptors = namespace_interceptors[namespace];
            if (interceptors != null) interceptors.remove (interceptor);
        }

        public override void attach (XmppStream stream) {
            if (attached_stream == stream) return;
            if (attached_stream != null) detach ((!) attached_stream);
            attached_stream = stream;
            attachment_generation++;
            stream.received_iq_stanza.connect (on_received_iq_stanza);
        }

        public override void detach (XmppStream stream) {
            stream.received_iq_stanza.disconnect (on_received_iq_stanza);
            if (attached_stream == stream) {
                attachment_generation++;
                attached_stream = null;
            }
            var requests = new ArrayList<PendingRequest> ();
            requests.add_all (pending_requests.values);
            foreach (PendingRequest request in requests) {
                if (request.stream == stream) {
                    request.complete_error (new IOError.CANCELLED ("Stream detached before IQ response"));
                }
            }
        }

        public override bool mandatory_outstanding (XmppStream stream) { return false; }

        public override bool negotiation_active (XmppStream stream) { return false; }

        public override string get_ns () { return NS_URI; }
        public override string get_id () { return IDENTITY.id; }

        private void on_received_iq_stanza (XmppStream stream, StanzaNode node) {
            process_received_iq_stanza.begin (stream, node, (_, res) => {
                process_received_iq_stanza.end (res);
            });
        }

        private async void process_received_iq_stanza (XmppStream stream, StanzaNode node) {
            Iq.Stanza iq = new Iq.Stanza.from_stanza (node, stream.has_flag (Bind.Flag.IDENTITY) ? stream.get_flag (Bind.Flag.IDENTITY).my_jid : null);

            if (iq.type_ == Iq.Stanza.TYPE_RESULT || iq.is_error ()) {
                if (response_listeners.has_key (iq.id)) {
                    PendingRequest? listener = response_listeners.get (iq.id);
                    if (listener != null && listener.stream == stream) listener.complete_success (iq);
                }
            } else {
                Gee.List<StanzaNode> children = node.get_all_subnodes ();
                if (children.size == 1 && (namespace_interceptors.has_key (children[0].ns_uri) || namespace_registrants.has_key (children[0].ns_uri))) {
                    bool has_handler_namespace = namespace_registrants.has_key (children[0].ns_uri);
                    preprocess_incoming_iq_set_get (stream, iq);
                    try {
                        var filters = new ArrayList<IncomingRequestFilter> ();
                        filters.add_all (incoming_request_filters);
                        foreach (IncomingRequestFilter filter in filters) filter.prepare_receive (stream, iq);
                    } catch (GLib.Error error) {
                        // A security veto occurs before normal interception.
                        // Let the owner retire only its matching pending
                        // operation without parsing or applying the payload.
                        // Namespace observers do not send the error response;
                        // this module owns that single protocol reply.
                        if (attached_stream == null || attached_stream == stream) {
                            var observers = new ArrayList<Interceptor> ();
                            Gee.List<Interceptor>? registered = namespace_interceptors[children[0].ns_uri];
                            if (registered != null) observers.add_all ((!) registered);
                            foreach (Interceptor observer in observers) {
                                observer.on_iq_request_rejected (stream, iq);
                            }
                        }
                        send_iq (stream, new Iq.Stanza.error (iq,
                            new ErrorStanza.not_acceptable ("IQ request failed security checks")) { to = iq.from });
                        return;
                    }

                    Gee.List<Interceptor>? interceptors = namespace_interceptors[children[0].ns_uri];
                    if (interceptors != null) {
                        foreach (Interceptor interceptor in interceptors) {
                            bool handled = false;
                            if (iq.type_ == Iq.Stanza.TYPE_GET) {
                                handled = yield interceptor.try_handle_iq_get (stream, iq);
                            } else if (iq.type_ == Iq.Stanza.TYPE_SET) {
                                handled = yield interceptor.try_handle_iq_set (stream, iq);
                            }
                            if (handled) return;
                        }
                    }

                    Gee.List<Handler>? handlers = namespace_registrants[children[0].ns_uri];
                    if (has_handler_namespace && handlers != null) {
                        foreach (Handler handler in handlers) {
                            if (iq.type_ == Iq.Stanza.TYPE_GET) {
                                yield handler.on_iq_get (stream, iq);
                            } else if (iq.type_ == Iq.Stanza.TYPE_SET) {
                                yield handler.on_iq_set (stream, iq);
                            }
                        }
                    } else {
                        Iq.Stanza unavailable_error = new Iq.Stanza.error( iq, new ErrorStanza.service_unavailable( )) { to=iq.from };
                        send_iq (stream, unavailable_error);
                    }
                } else {
                    // Send error if we don't handle the NS of the IQ get/set payload (RFC6120 10.3.3 (2))
                    Iq.Stanza unavailable_error = new Iq.Stanza.error( iq, new ErrorStanza.service_unavailable( )) { to=iq.from };
                    send_iq (stream, unavailable_error);
                }
            }
        }

        private class PendingRequest : Object {
            public Iq.Stanza? return_stanza { get; private set; default = null; }
            public IOError? pending_error { get; private set; default = null; }
            public bool completed { get; private set; default = false; }
            public LocalFailurePhase phase = LocalFailurePhase.PREPARE;
            public Cancellable cancellable = new Cancellable ();
            public XmppStream stream;
            public Iq.Stanza iq;
            public string iq_id;
            public uint64 generation;
            public bool expects_response { get { return on_result != null || resume_callback != null; } }

            private Module module;
            private OnResult? on_result;
            private SourceFunc? resume_callback;
            private TimeoutSource? timeout_source = null;
            private CancellableSource? cancellable_source = null;
            private CancellableSource? internal_cancellable_source = null;
            private Cancellable? caller_cancellable = null;
            private MainContext owner_context;
            private LocalFailurePhase failure_phase = LocalFailurePhase.UNKNOWN;

            public PendingRequest (Module module, XmppStream stream, Iq.Stanza iq, uint64 generation,
                    owned OnResult? on_result, owned SourceFunc? resume_callback) {
                this.module = module;
                this.stream = stream;
                this.iq = iq;
                this.iq_id = iq.id;
                this.generation = generation;
                this.on_result = (owned) on_result;
                this.resume_callback = (owned) resume_callback;
                owner_context = MainContext.ref_thread_default ();
                // The transport receives this combined token. It may cancel
                // it itself even when its asynchronous write already returned.
                var cancellation = new CancellableSource (cancellable);
                cancellation.set_callback ((cancelled) => {
                    complete_error (new IOError.CANCELLED ("IQ transport was cancelled"));
                    return Source.REMOVE;
                });
                internal_cancellable_source = cancellation;
                cancellation.attach (owner_context);
                var timeout_source = new TimeoutSource.seconds (30);
                timeout_source.set_callback (() => {
                    complete_error (new IOError.TIMED_OUT ("Timed out preparing or waiting for IQ response"));
                    return Source.REMOVE;
                });
                this.timeout_source = timeout_source;
                timeout_source.attach (owner_context);
            }

            public void check_cancelled () throws IOError {
                cancellable.set_error_if_cancelled ();
                if (caller_cancellable != null) ((!) caller_cancellable).set_error_if_cancelled ();
            }

            public void watch_cancellable (Cancellable? caller_cancellable) {
                this.caller_cancellable = caller_cancellable;
                if (caller_cancellable == null || completed) return;
                if (caller_cancellable.is_cancelled ()) {
                    complete_error (new IOError.CANCELLED ("IQ request was cancelled"));
                    return;
                }
                var source = new CancellableSource ((!) caller_cancellable);
                source.set_callback ((cancelled) => {
                    complete_error (new IOError.CANCELLED ("IQ request was cancelled"));
                    return Source.REMOVE;
                });
                cancellable_source = source;
                source.attach (owner_context);
            }

            public void complete_success (Iq.Stanza? stanza) {
                if (!mark_completed ()) return;
                return_stanza = stanza;
                schedule_completion ();
            }

            public void complete_error (GLib.Error error) {
                if (!mark_completed ()) return;
                failure_phase = phase;
                if (error is IOError) pending_error = (IOError) error.copy ();
                else pending_error = new IOError.FAILED ("IQ request could not be prepared or sent");
                cancellable.cancel ();
                schedule_completion ();
            }

            private bool mark_completed () {
                if (completed) return false;
                completed = true;
                module.remove_request (this);
                if (timeout_source != null) {
                    ((!) timeout_source).destroy ();
                    timeout_source = null;
                }
                if (cancellable_source != null) {
                    ((!) cancellable_source).destroy ();
                    cancellable_source = null;
                }
                if (internal_cancellable_source != null) {
                    ((!) internal_cancellable_source).destroy ();
                    internal_cancellable_source = null;
                }
                return true;
            }

            private void schedule_completion () {
                var idle_source = new IdleSource ();
                idle_source.set_callback (() => {
                    SourceFunc? resume = (owned) resume_callback;
                    OnResult? listener = (owned) on_result;
                    if (resume != null) ((!) resume) ();
                    else if (listener != null) ((!) listener) (stream,
                        pending_error != null ? local_failure (iq, pending_error, failure_phase) : (!) return_stanza);
                    return Source.REMOVE;
                });
                idle_source.attach (owner_context);
            }
        }
    }

    // Filters are asynchronous only on the outgoing side: key discovery must finish
    // before a request carrying security-sensitive payload can reach the wire.
    public interface OutgoingRequestFilter : Object {
        public abstract async void prepare_send (XmppStream stream, Iq.Stanza iq, Cancellable cancellable) throws GLib.Error;
    }

    public interface IncomingRequestFilter : Object {
        public abstract void prepare_receive (XmppStream stream, Iq.Stanza iq) throws GLib.Error;
    }

    public interface Interceptor : Object {
        // A matching request failed an incoming security filter. This is a
        // local lifecycle notification, not permission to process the payload
        // or send a second IQ response. Existing interceptors may ignore it.
        public virtual void on_iq_request_rejected (XmppStream stream, Iq.Stanza iq) { }

        public async virtual bool try_handle_iq_get (XmppStream stream, Iq.Stanza iq) {
            return false;
        }

        public async virtual bool try_handle_iq_set (XmppStream stream, Iq.Stanza iq) {
            return false;
        }
    }

    public interface Handler : Object {
        public async virtual void on_iq_get (XmppStream stream, Iq.Stanza iq) {
            Iq.Stanza bad_request = new Iq.Stanza.error (iq, new ErrorStanza.bad_request ("unexpected IQ get for this namespace"));
            stream.get_module<Module> (Module.IDENTITY).send_iq (stream, bad_request);
        }
        public async virtual void on_iq_set (XmppStream stream, Iq.Stanza iq) {
            Iq.Stanza bad_request = new Iq.Stanza.error (iq, new ErrorStanza.bad_request ("unexpected IQ set for this namespace"));
            stream.get_module<Module> (Module.IDENTITY).send_iq (stream, bad_request);
        }
    }

}

using Gee;
using Xmpp;
using Xmpp.Xep;

namespace Xmpp.Xep.JingleFileTransfer {

private const string NS_URI = "urn:xmpp:jingle:apps:file-transfer:5";

public class Module : Jingle.ContentType, XmppStreamModule {

    public signal void file_incoming(XmppStream stream, FileTransfer file_transfer);
    private HashMap<int, FileTransfer> send_transfers = new HashMap<int, FileTransfer>();
    private HashMap<string, FileTransfer> send_transfers_by_token = new HashMap<string, FileTransfer>();
    private HashMap<int, bool> pending_cancel_send_transfers = new HashMap<int, bool>();
    private HashMap<string, bool> pending_cancel_send_transfers_by_token = new HashMap<string, bool>();
    public uint offer_wait_timeout_seconds = 15;

    public static Xmpp.ModuleIdentity<Module> IDENTITY = new Xmpp.ModuleIdentity<Module>(NS_URI, "0234_jingle_file_transfer");
    public SessionInfoType session_info_type = new SessionInfoType();

    public override void attach(XmppStream stream) {
        stream.get_module<ServiceDiscovery.Module>(ServiceDiscovery.Module.IDENTITY).add_feature(stream, NS_URI);
        stream.get_module<Jingle.Module>(Jingle.Module.IDENTITY).register_content_type(this);
        stream.get_module<Jingle.Module>(Jingle.Module.IDENTITY).register_session_info_type(session_info_type);
    }
    public override void detach(XmppStream stream) {
        stream.get_module<ServiceDiscovery.Module>(ServiceDiscovery.Module.IDENTITY).remove_feature(stream, NS_URI);
    }

    public string ns_uri { get { return NS_URI; } }
    public Jingle.TransportType required_transport_type { get { return Jingle.TransportType.STREAMING; } }
    public uint8 required_components { get { return 1; } }

    public Jingle.ContentParameters parse_content_parameters(StanzaNode description) throws Jingle.IqError {
        return Parameters.parse(this, description);
    }

    public Jingle.ContentParameters create_content_parameters(Object object) throws Jingle.IqError {
        assert_not_reached();
    }

    public async bool is_available(XmppStream stream, Jid full_jid) {
        bool? has_feature = yield stream.get_module<ServiceDiscovery.Module>(ServiceDiscovery.Module.IDENTITY).has_entity_feature(stream, full_jid, NS_URI);
        if (has_feature == null || !(!)has_feature) {
            return false;
        }
        return yield stream.get_module<Jingle.Module>(Jingle.Module.IDENTITY).is_available(stream, required_transport_type, required_components, full_jid);
    }

    public static StanzaNode create_file_description(string basename, int64 size, string? media_type = null) throws Jingle.IqError {
        if (size < 0) {
            throw new Jingle.IqError.BAD_REQUEST("negative file size is invalid");
        }

        StanzaNode file_node;
        StanzaNode description = new StanzaNode.build("description", NS_URI)
            .add_self_xmlns()
            .put_node(file_node = new StanzaNode.build("file", NS_URI)
                .put_node(new StanzaNode.build("name", NS_URI).put_node(new StanzaNode.text(basename)))
                .put_node(new StanzaNode.build("size", NS_URI).put_node(new StanzaNode.text(size.to_string()))));
        if (media_type != null) {
            file_node.put_node(new StanzaNode.build("media-type", NS_URI).put_node(new StanzaNode.text((!) media_type)));
        }
        // TODO(hrxi): Add the mandatory hash field

        return description;
    }

    public async FileTransfer offer_file_stream(XmppStream stream, Jid receiver_full_jid, InputStream input_stream, string basename, int64 size, int transfer_id = -1, string? transfer_token = null, string? precondition_name = null, Object? precondition_options = null) throws Jingle.Error {
        StanzaNode description;
        try {
            description = create_file_description(basename, size);
        } catch (Xmpp.Xep.Jingle.IqError e) {
            throw new Jingle.Error.BAD_REQUEST(e.message);
        }

        Parameters parameters;
        try {
            parameters = Parameters.parse(this, description);
        } catch (Xmpp.Xep.Jingle.IqError e) {
            throw new Jingle.Error.BAD_REQUEST(e.message);
        }

        Jingle.Module jingle_module = stream.get_module<Jingle.Module>(Jingle.Module.IDENTITY);

        Jingle.Transport? transport = yield jingle_module.select_transport(stream, required_transport_type, required_components, receiver_full_jid, Set.empty());
        if (transport == null) {
            throw new Jingle.Error.NO_SHARED_PROTOCOLS("No suitable transports");
        }
        Jingle.SecurityPrecondition? precondition = jingle_module.get_security_precondition(precondition_name);
        if (precondition_name != null && precondition == null) {
            throw new Jingle.Error.UNSUPPORTED_SECURITY("No suitable security precondiiton found");
        }
        Jid? my_jid = stream.get_flag(Bind.Flag.IDENTITY).my_jid;
        if (my_jid == null) {
            throw new Jingle.Error.GENERAL("Couldn't determine own JID");
        }
        Jingle.TransportParameters transport_params = transport.create_transport_parameters(stream, required_components, my_jid, receiver_full_jid);
        Jingle.SecurityParameters? security_params = precondition != null ? precondition.create_security_parameters(stream, my_jid, receiver_full_jid, precondition_options) : null;

        Jingle.Content content = new Jingle.Content.initiate_sent("a-file-offer", Jingle.Senders.INITIATOR,
                this, parameters,
                transport, transport_params,
                precondition, security_params,
                my_jid, receiver_full_jid);

        ArrayList<Jingle.Content> contents = new ArrayList<Jingle.Content>();
        contents.add(content);


        Jingle.Session? session = null;
        bool session_terminated = false;
        try {
            session = yield jingle_module.create_session(stream, contents, receiver_full_jid);
            FileTransfer file_transfer = new FileTransfer(session, content, parameters);
            if (transfer_id > 0) {
                send_transfers[transfer_id] = file_transfer;
            } else if (transfer_token != null && transfer_token != "") {
                send_transfers_by_token[transfer_token] = file_transfer;
            }

            bool cancel_after_registration = false;
            if (transfer_id > 0) {
                if (pending_cancel_send_transfers.has_key(transfer_id)) {
                    cancel_after_registration = true;
                }
            } else if (transfer_token != null && transfer_token != "") {
                if (pending_cancel_send_transfers_by_token.has_key((!) transfer_token)) {
                    cancel_after_registration = true;
                }
            }

            if (cancel_after_registration) {
                session_terminated = true;
                file_transfer.cancel();
                send_transfers.unset(transfer_id);
                if (transfer_token != null && transfer_token != "") {
                    send_transfers_by_token.unset((!) transfer_token);
                }
                throw new Jingle.Error.GENERAL("Transfer was cancelled before offer negotiation");
            }

            // Wait for the counterpart to accept our offer or for local/peer
            // termination to prevent long-running hangs on cancel.
            bool offer_finalized = false;
            uint timeout_id = 0;
            string? termination_reason = null;
            ulong content_notify_id = 0;
            ulong session_terminated_id = 0;

            content_notify_id = content.notify["state"].connect(() => {
                if (offer_finalized) return;
                if (content.state == Jingle.Content.State.ACCEPTED) {
                    offer_finalized = true;
                    termination_reason = "offer accepted";
                    if (content_notify_id != 0) {
                        content.disconnect(content_notify_id);
                        content_notify_id = 0;
                    }
                    if (session_terminated_id != 0) {
                        session.disconnect(session_terminated_id);
                        session_terminated_id = 0;
                    }
                    if (timeout_id != 0) {
                        Source.remove(timeout_id);
                        timeout_id = 0;
                    }
                    Idle.add(offer_file_stream.callback);
                }
            });

            session_terminated_id = session.terminated.connect((stream, we_terminated, reason_name, reason_text) => {
                if (offer_finalized) return;
                session_terminated = true;
                termination_reason = we_terminated ? "local session termination" : (reason_name ?? reason_text ?? "session terminated");
                offer_finalized = true;
                if (content_notify_id != 0) {
                    content.disconnect(content_notify_id);
                    content_notify_id = 0;
                }
                if (session_terminated_id != 0) {
                    session.disconnect(session_terminated_id);
                    session_terminated_id = 0;
                }
                if (timeout_id != 0) {
                    Source.remove(timeout_id);
                    timeout_id = 0;
                }
                Idle.add(offer_file_stream.callback);
            });

            if (offer_wait_timeout_seconds > 0) {
                uint timeout_ms = offer_wait_timeout_seconds * 1000;
                timeout_id = Timeout.add(timeout_ms, () => {
                    if (offer_finalized) return Source.REMOVE;
                    session_terminated = true;
                    offer_finalized = true;
                    termination_reason = "offer timeout";
                    if (content_notify_id != 0) {
                        content.disconnect(content_notify_id);
                        content_notify_id = 0;
                    }
                    if (session_terminated_id != 0) {
                        session.disconnect(session_terminated_id);
                        session_terminated_id = 0;
                    }
                    timeout_id = 0;
                    if (session != null && session.state != Jingle.Session.State.ENDED) {
                        session.terminate(Jingle.ReasonElement.TIMEOUT, null, "session accept timeout");
                    }
                    Idle.add(offer_file_stream.callback);
                    return Source.REMOVE;
                });
            }

            if (!offer_finalized) {
                yield;
            }

            if (content_notify_id != 0) {
                content.disconnect(content_notify_id);
                content_notify_id = 0;
            }
            if (session_terminated_id != 0) {
                session.disconnect(session_terminated_id);
                session_terminated_id = 0;
            }
            if (timeout_id != 0) {
                Source.remove(timeout_id);
                timeout_id = 0;
            }

            if (content.state != Jingle.Content.State.ACCEPTED) {
                if (termination_reason == null) {
                    throw new Jingle.Error.GENERAL("Offer did not reach accepted state");
                }
                throw new Jingle.Error.GENERAL(@"Offer did not reach accepted state: $(termination_reason)");
            }

            // Send the file data
            Jingle.StreamingConnection connection = content.component_connections[1] as Jingle.StreamingConnection;
            if (connection == null || connection.stream == null) {
                warning("Connection or stream is null");
                throw new Jingle.Error.GENERAL("No stream available for file transfer");
            }
            IOStream io_stream = yield connection.stream.wait_async();
            // Keep the unused input side open until session cleanup. Security
            // wrappers such as JET share the same underlying transport, and an
            // early half-close can abort the output before its AEAD tag is
            // flushed on Windows.
            yield io_stream.output_stream.splice_async(input_stream, OutputStreamSpliceFlags.CLOSE_SOURCE|OutputStreamSpliceFlags.CLOSE_TARGET);
            yield connection.terminate(true);
            return file_transfer;
        } catch (Error e) {
            if (session != null && !session_terminated && session.state != Jingle.Session.State.ENDED) {
                session.terminate(Jingle.ReasonElement.FAILED_TRANSPORT, e.message, e.message);
            }
            throw new Jingle.Error.GENERAL("Couldn't send file via Jingle: %s", e.message);
        } finally {
            if (transfer_id > 0) {
                send_transfers.unset(transfer_id);
                pending_cancel_send_transfers.unset(transfer_id);
            } else if (transfer_token != null && transfer_token != "") {
                send_transfers_by_token.unset(transfer_token);
                pending_cancel_send_transfers_by_token.unset((!) transfer_token);
            }
        }
    }

    public override string get_ns() { return NS_URI; }
    public override string get_id() { return IDENTITY.id; }

    public bool cancel_send_transfer(int transfer_id) {
        if (pending_cancel_send_transfers.has_key(transfer_id)) {
            return false;
        }
        FileTransfer? file_transfer = send_transfers[transfer_id];
        if (file_transfer == null) {
            pending_cancel_send_transfers[transfer_id] = true;
            return true;
        }
        ((!) file_transfer).cancel();
        send_transfers.unset(transfer_id);
        pending_cancel_send_transfers[transfer_id] = true;
        return true;
    }

    public bool cancel_send_transfer_token(string transfer_token) {
        if (pending_cancel_send_transfers_by_token.has_key(transfer_token)) {
            return false;
        }
        FileTransfer? file_transfer = send_transfers_by_token[transfer_token];
        if (file_transfer == null) {
            pending_cancel_send_transfers_by_token[transfer_token] = true;
            return true;
        }
        ((!) file_transfer).cancel();
        send_transfers_by_token.unset(transfer_token);
        pending_cancel_send_transfers_by_token[transfer_token] = true;
        return true;
    }
}

public class SessionInfoType : Jingle.SessionInfoNs, Object {

    public string ns_uri { get { return NS_URI; } }

    public void handle_content_session_info(XmppStream stream, Jingle.Session session, StanzaNode info, Iq.Stanza iq) throws Jingle.IqError {
        switch (info.name) {
            case "received":
                break;
            case "checksum":
                // TODO(hrxi): handle hash
                break;
            default:
                throw new Jingle.IqError.UNSUPPORTED_INFO(@"unsupported file transfer info $(info.name)");
        }
    }

}

public class Parameters : Jingle.ContentParameters, Object {

    Module parent;
    string? media_type;
    public string? name { get; private set; }
    public int64 size { get; private set; }
    public StanzaNode original_description { get; private set; }

    public Parameters(Module parent, StanzaNode original_description, string? media_type, string? name, int64 size) {
        this.parent = parent;
        this.original_description = original_description;
        this.media_type = media_type;
        this.name = name;
        this.size = size;
    }

    public static Parameters parse(Module parent, StanzaNode description) throws Jingle.IqError {
        Gee.List<StanzaNode> files = description.get_subnodes("file", NS_URI);
        if (files.size != 1) {
            throw new Jingle.IqError.BAD_REQUEST("there needs to be exactly one file node");
        }
        StanzaNode file = files[0];
        StanzaNode? media_type_node = file.get_subnode("media-type", NS_URI);
        StanzaNode? name_node = file.get_subnode("name", NS_URI);
        StanzaNode? size_node = file.get_subnode("size", NS_URI);
        string? media_type = media_type_node != null ? media_type_node.get_string_content() : null;
        string? name = name_node != null ? name_node.get_string_content() : null;
        string? size_raw = size_node != null ? size_node.get_string_content() : null;
        // TODO(hrxi): For some reason, the ?:-expression does not work due to a type error.
        //int64? size = size_raw != null ? int64.parse(size_raw) : null; // TODO(hrxi): this has no error handling
        if (size_raw == null) {
            // Jingle file transfers (XEP-0234) theoretically SHOULD send a
            // file size, however, we do require it in order to reliably find
            // the end of the file transfer.
            throw new Jingle.IqError.BAD_REQUEST("file offer without file size");
        }
        int64 size = int64.parse(size_raw);
        if (size < 0) {
            throw new Jingle.IqError.BAD_REQUEST("negative file size is invalid");
        }

        return new Parameters(parent, description, media_type, name, size);
    }

    public StanzaNode get_description_node() {
        return original_description;
    }

    public async void handle_proposed_content(XmppStream stream, Jingle.Session session, Jingle.Content content) {
        parent.file_incoming(stream, new FileTransfer(session, content, this));
    }

    public void modify(XmppStream stream, Jingle.Session session, Jingle.Content content, Jingle.Senders senders) { }

    public void accept(XmppStream stream, Jingle.Session session, Jingle.Content content) { }

    public void handle_accept(XmppStream stream, Jingle.Session session, Jingle.Content content, StanzaNode description_node) { }

    public void terminate(bool we_terminated, string? reason_name, string? reason_text) { }
}

// Does nothing except wrapping a stream input side to signal EOF after
// reading `max_size` bytes while keeping transfer ownership in the Jingle
// session lifecycle.
private class FileTransferInputStream : InputStream {

    public signal void closed(bool complete);

    InputStream inner;
    int64 remaining_size;
    bool failed = false;
    bool authenticated = false;
    bool closed_once = false;
    bool is_closing = false;

    public FileTransferInputStream(InputStream inner, int64 max_size) {
        this.inner = inner;
        this.remaining_size = max_size;

        Jingle.AuthenticatedInputStream? authenticated_stream = inner as Jingle.AuthenticatedInputStream;
        if (authenticated_stream != null) {
            ((!) authenticated_stream).set_expected_plaintext_size(max_size);
        }
    }

    private ssize_t update_remaining(ssize_t read) throws IOError {
        if (read == 0 && remaining_size > 0) {
            failed = true;
            throw new IOError.FAILED("File transfer ended before declared size");
        }
        if (read > 0) {
            this.remaining_size -= read;
        }
        return read;
    }

    private bool is_complete() {
        return !failed && remaining_size <= 0;
    }

    private void authenticate_inner_before_eof(Cancellable? cancellable = null) throws IOError {
        if (failed || authenticated || remaining_size > 0) return;
        Jingle.AuthenticatedInputStream? authenticated_stream = inner as Jingle.AuthenticatedInputStream;
        if (authenticated_stream == null) {
            authenticated = true;
            return;
        }
        try {
            ((!) authenticated_stream).authenticate(cancellable);
            authenticated = true;
        } catch (IOError e) {
            failed = true;
            throw e;
        }
    }

    private async void authenticate_inner_before_eof_async(int io_priority = GLib.Priority.DEFAULT, Cancellable? cancellable = null) throws IOError {
        if (failed || authenticated || remaining_size > 0) return;
        Jingle.AuthenticatedInputStream? authenticated_stream = inner as Jingle.AuthenticatedInputStream;
        if (authenticated_stream == null) {
            authenticated = true;
            return;
        }
        try {
            yield ((!) authenticated_stream).authenticate_async(io_priority, cancellable);
            authenticated = true;
        } catch (IOError e) {
            failed = true;
            throw e;
        }
    }

    public override ssize_t read(uint8[] buffer_, Cancellable? cancellable = null) throws IOError {
        unowned uint8[] buffer = buffer_;
        if (remaining_size <= 0) {
            authenticate_inner_before_eof(cancellable);
            return 0;
        }
        if (buffer.length > remaining_size) {
            buffer = buffer[0:remaining_size];
        }
        return update_remaining(inner.read(buffer, cancellable));
    }

    public override async ssize_t read_async(uint8[]? buffer_, int io_priority = GLib.Priority.DEFAULT, Cancellable? cancellable = null) throws IOError {
        unowned uint8[] buffer = buffer_;
        if (remaining_size <= 0) {
            yield authenticate_inner_before_eof_async(io_priority, cancellable);
            return 0;
        }
        if (buffer.length > remaining_size) {
            buffer = buffer[0:remaining_size];
        }
        return update_remaining(yield inner.read_async(buffer, io_priority, cancellable));
    }

    public override bool close(Cancellable? cancellable = null) throws IOError {
        if (closed_once || is_closing) return true;
        is_closing = true;
        bool close_result = true;
        IOError? close_error = null;
        try {
            authenticate_inner_before_eof(cancellable);
        } catch (IOError e) {
            close_error = e;
        }
        try {
            if (!inner.close(cancellable)) close_result = false;
        } catch (IOError.CLOSED e) {
        } catch (IOError e) {
            if (close_error == null) close_error = e;
        }
        // Transport teardown happens in Jingle session/content terminate.
        // Keep half-close here intentionally empty to avoid platform-specific
        // output-side close races while still emitting the stream completion.
        try {
            // no-op: full transport close is handled by session termination.
        } finally {
            closed_once = true;
            is_closing = false;
            closed(is_complete());
        }
        if (close_error != null) throw (!) close_error;
        return close_result;
    }

    public override async bool close_async(int io_priority = GLib.Priority.DEFAULT, Cancellable? cancellable = null) throws IOError {
        if (closed_once || is_closing) return true;
        is_closing = true;
        bool close_result = true;
        IOError? close_error = null;
        try {
            yield authenticate_inner_before_eof_async(io_priority, cancellable);
        } catch (IOError e) {
            close_error = e;
        }
        try {
            if (!yield inner.close_async(io_priority, cancellable)) close_result = false;
        } catch (IOError.CLOSED e) {
        } catch (IOError e) {
            if (close_error == null) close_error = e;
        }
        // Transport teardown happens in Jingle session/content terminate.
        // Keep half-close here intentionally empty to avoid platform-specific
        // output-side close races while still emitting the stream completion.
        try {
            // no-op: full transport close is handled by session termination.
        } finally {
            closed_once = true;
            is_closing = false;
            closed(is_complete());
        }
        if (close_error != null) throw (!) close_error;
        return close_result;
    }
}

public class FileTransfer : Object {
    public signal void terminated(bool we_terminated, string? reason_name, string? reason_text);

    Jingle.Session session;
    Jingle.Content content;
    Parameters parameters;

    public Jid peer { get { return session.peer_full_jid; } }
    public string? file_name { get { return parameters.name; } }
    public int64 size { get { return parameters.size; } }
    public Jingle.SecurityParameters? security { get { return session.security; } }
    public string transport_ns_uri { get { return content.transport.ns_uri; } }
    public bool is_ended { get { return session.state == Jingle.Session.State.ENDED; } }

    public InputStream? stream { get; private set; }

    public FileTransfer(Jingle.Session session, Jingle.Content content, Parameters parameters) {
        this.session = session;
        this.content = content;
        this.parameters = parameters;

        session.terminated.connect((stream, we_terminated, reason_name, reason_text) => {
            terminated(we_terminated, reason_name, reason_text);
        });
    }

    public async void accept(XmppStream stream) throws IOError {
        content.accept();

        Jingle.StreamingConnection? connection = null;
        foreach (Jingle.ComponentConnection component_connection in content.component_connections.values) {
            connection = component_connection as Jingle.StreamingConnection;
            break;
        }
        if (connection == null) {
            throw new IOError.FAILED("No streaming connection available for file transfer");
        }
        try {
            IOStream io_stream = yield connection.stream.wait_async();
            FileTransferInputStream ft_stream = new FileTransferInputStream(io_stream.input_stream, size);
            ft_stream.closed.connect((complete) => {
                if (complete) {
                    session.terminate(Jingle.ReasonElement.SUCCESS, null, null);
                } else {
                    session.terminate(Jingle.ReasonElement.FAILED_TRANSPORT, "File transfer ended before declared size", "incomplete file transfer");
                }
            });
            this.stream = ft_stream;
        } catch (FutureError.EXCEPTION e) {
            string error_message = connection.stream.exception.message;
            if (error_message == "Jingle connection failed") {
                debug("Error accepting Jingle file-transfer: %s", error_message);
            } else {
                warning("Error accepting Jingle file-transfer: %s", error_message);
            }
            throw new IOError.FAILED(error_message);
        } catch (FutureError e) {
            warning("FutureError accepting Jingle file-transfer: %s", e.message);
            throw new IOError.FAILED(e.message);
        }
    }

    public void cancel() {
        session.terminate(Jingle.ReasonElement.CANCEL, null, "user-cancelled");
    }

    public void reject(XmppStream stream) {
        content.reject();
    }
}

}

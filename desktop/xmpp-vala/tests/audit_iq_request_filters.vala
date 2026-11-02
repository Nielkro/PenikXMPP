namespace Xmpp.Test {

class IqRequestFilterAudit : Gee.TestCase {
    private const string TEST_NS = "urn:dinox:test:iq-request-filter";

    public IqRequestFilterAudit () {
        base ("IqRequestFilterAudit");
        add_async_test ("callback_waits_for_filter_then_writes_once", (cb) => test_held_success (false, cb));
        add_async_test ("async_waits_for_filter_then_writes_once", (cb) => test_held_success (true, cb));
        add_async_test ("callback_filter_failure_is_local_error_without_write", (cb) => test_failure (false, cb));
        add_async_test ("async_filter_failure_throws_without_write", (cb) => test_failure (true, cb));
        add_async_test ("addressless_server_request_failure_is_safe", (cb) => test_failure (false, cb, true));
        add_async_test ("callback_write_timeout_preserves_write_phase", test_write_failure);
        // Run the real 30-second timeout in a separate test process so unrelated
        // mock requests from earlier cases cannot expire while it waits.
        if (Environment.get_variable ("DINOX_TEST_IQ_RESPONSE_TIMEOUT") == "1") {
            add_async_test ("callback_response_timeout_preserves_await_response_phase", test_response_timeout, 40000);
        }
        add_async_test ("callback_cancel_ignores_late_filter_success", (cb) => test_cancel (false, false, cb));
        add_async_test ("async_cancel_ignores_late_filter_success", (cb) => test_cancel (true, false, cb));
        add_async_test ("callback_detach_ignores_late_filter_success", (cb) => test_cancel (false, true, cb));
        add_async_test ("async_detach_ignores_late_filter_success", (cb) => test_cancel (true, true, cb));
        add_async_test ("duplicate_id_during_preparation_cannot_write", test_duplicate);
        add_async_test ("cancel_immediately_before_filter_release_cannot_write", test_cancel_immediately);
        add_async_test ("replacement_stream_survives_late_old_detach", test_replacement_stream);
        add_async_test ("transport_can_cancel_combined_token_after_write", test_transport_cancellation);
        add_async_test ("explicit_old_stream_request_is_rejected", test_stale_stream_send);
        add_async_test ("result_and_error_responses_bypass_filters", test_responses_bypass);
        add_async_test ("ordinary_iq_keeps_preprocess_and_reply", test_no_filters);
        add_async_test ("incoming_filter_rejection_prevents_handler", (cb) => test_incoming (true, cb));
        add_async_test ("incoming_filter_allow_preserves_handler", (cb) => test_incoming (false, cb));
        add_async_test ("incoming_filter_veto_notifies_only_namespace_owner_once", (cb) => test_rejected_owner (true, cb));
        add_async_test ("incoming_filter_allow_does_not_notify_rejection_owner", (cb) => test_rejected_owner (false, cb));
        add_test ("wire_cannot_forge_local_failure_marker", test_local_marker);
        add_test ("local_failure_details_do_not_change_wire_xml", test_local_failure_metadata);
    }

    private delegate void Completion (Iq.Stanza? result, GLib.Error? error);

    private void send_request (bool use_async, Iq.Module module, RequestFilterStream stream,
            Iq.Stanza request, owned Completion completion, Cancellable? cancellable = null) {
        if (use_async) {
            module.send_iq_async.begin (stream, request, Priority.DEFAULT, cancellable, (_, res) => {
                try { completion (module.send_iq_async.end (res), null); }
                catch (GLib.Error error) { completion (null, error); }
            });
        } else {
            module.send_iq (stream, request, (_, result) => completion (result, null), Priority.DEFAULT, cancellable);
        }
    }

    private void test_held_success (bool use_async, Gee.TestFinishedCallback cb) {
        var stream = make_stream ();
        var module = attach_module (stream);
        var filter = new HeldRequestFilter ();
        module.add_outgoing_request_filter (filter);
        int preprocess = 0;
        module.preprocess_outgoing_iq_set_get.connect (() => preprocess++);
        int completions = 0;
        var request = make_request ("held-success");
        send_request (use_async, module, stream, request, (result, error) => {
            completions++;
            fail_if (error != null || result == null, "Successful request must deliver its reply");
            if (result != null) fail_if (((!) result).locally_failed, "A real reply is not a local failure");
        });
        fail_if_not_eq_int (filter.calls, 1, "Filter should start immediately");
        fail_if_not_eq_int (stream.written_nodes.size, 0, "Held security preparation must prevent any wire write");
        fail_if_not_eq_int (preprocess, 0, "Existing synchronous preprocess runs only after asynchronous preparation");
        // A guessed response before preparation has finished must not bypass the gate.
        stream.emit_result (request);
        fail_if_not_eq_int (completions, 0, "Early reply cannot complete an unprepared request");
        filter.release ();
        fail_if_not_eq_int (stream.written_nodes.size, 1, "Prepared request must reach the wire exactly once");
        fail_if_not_eq_int (preprocess, 1, "Existing preprocess signal must still run once");
        stream.emit_result (request);
        finish (() => {
            fail_if_not_eq_int (completions, 1, "Reply callback must run exactly once");
            fail_if_not_eq_int (stream.written_nodes.size, 1, "Reply must not cause another request write");
        }, cb);
    }

    private void test_failure (bool use_async, Gee.TestFinishedCallback cb, bool addressless = false) {
        var stream = make_stream ();
        var module = attach_module (stream);
        var filter = new HeldRequestFilter () { reject = true };
        module.add_outgoing_request_filter (filter);
        int completions = 0;
        Iq.Stanza request = addressless ? new Iq.Stanza.set (
            new StanzaNode.build ("payload", TEST_NS).add_self_xmlns (), "server-directed") : make_request ("held-reject");
        send_request (use_async, module, stream, request, (result, error) => {
            completions++;
            if (use_async) fail_if (error == null, "Async preparation failure must throw");
            else {
                fail_if (result == null || !((!) result).is_error () || !((!) result).locally_failed,
                    "Callback preparation failure must be an identifiable local IQ error");
                if (result != null) {
                    fail_if (((!) result).local_failure_phase != Iq.LocalFailurePhase.PREPARE,
                        "Filter failure must retain its preparation phase");
                    fail_if_not_eq_int (((!) result).local_failure_code, IOError.PERMISSION_DENIED,
                        "Filter failure must retain its typed local error code");
                }
            }
        });
        filter.release ();
        finish (() => {
            fail_if_not_eq_int (completions, 1, "Rejected request must complete exactly once");
            fail_if_not_eq_int (stream.written_nodes.size, 0, "Rejected request must never reach the wire");
        }, cb);
    }

    private void test_write_failure (Gee.TestFinishedCallback cb) {
        var stream = make_stream ();
        stream.fail_write = true;
        var module = attach_module (stream);
        int completions = 0;
        send_request (false, module, stream, make_request ("write-timeout"), (result, error) => {
            completions++;
            fail_if (result == null || !((!) result).locally_failed,
                "Write failure must deliver a local callback error");
            if (result != null) {
                fail_if (((!) result).local_failure_phase != Iq.LocalFailurePhase.WRITE,
                    "A timeout during write must never become a response timeout");
                fail_if_not_eq_int (((!) result).local_failure_code, IOError.TIMED_OUT,
                    "Write timeout must retain its typed local error code");
            }
        });
        finish (() => {
            fail_if_not_eq_int (completions, 1, "Failed write must notify exactly once");
            fail_if_not_eq_int (stream.written_nodes.size, 0, "Failed write must not record a sent request");
        }, cb);
    }

    private void test_response_timeout (Gee.TestFinishedCallback cb) {
        var stream = make_stream ();
        var module = attach_module (stream);
        var request = make_request ("response-timeout");
        int completions = 0;
        bool finished = false;
        // Exercise the real 30-second request timeout without changing production timing.
        uint watchdog = Timeout.add_seconds (35, () => {
            if (!finished) {
                finished = true;
                module.detach (stream);
                fail_if_reached ("Written request did not time out within the bounded wait");
                cb ();
            }
            return Source.REMOVE;
        });
        module.send_iq (stream, request, (_, result) => {
            completions++;
            if (finished) return;
            finished = true;
            Source.remove (watchdog);
            fail_if (!result.locally_failed, "Unanswered written request must fail locally");
            fail_if (result.local_failure_phase != Iq.LocalFailurePhase.AWAIT_RESPONSE,
                "Only a successfully written request may time out awaiting its response");
            fail_if_not_eq_int (result.local_failure_code, IOError.TIMED_OUT,
                "Unanswered request must retain its timeout code");
            stream.emit_result (request);
            finish (() => {
                fail_if_not_eq_int (completions, 1, "Late reply must not complete a timed-out request twice");
                fail_if_not_eq_int (stream.written_nodes.size, 1, "Response timeout must preserve exactly one successful write");
            }, cb);
        });
        fail_if_not_eq_int (stream.written_nodes.size, 1, "Response timeout test must first write its request");
    }

    private void test_cancel (bool use_async, bool detach, Gee.TestFinishedCallback cb) {
        var stream = make_stream ();
        var module = attach_module (stream);
        var filter = new HeldRequestFilter ();
        var cancellable = new Cancellable ();
        module.add_outgoing_request_filter (filter);
        int completions = 0;
        var request = make_request ("held-cancel");
        send_request (use_async, module, stream, request, (result, error) => {
            completions++;
            if (use_async) fail_if (!(error is IOError.CANCELLED), "Cancelled async request must preserve cancellation");
            else fail_if (result == null || !((!) result).locally_failed, "Cancelled callback request must be a local failure");
        }, cancellable);
        if (detach) {
            module.detach (stream);
            // Reattaching the module cannot revive work from its preceding stream generation.
            module.attach (stream);
        } else cancellable.cancel ();
        Timeout.add (10, () => {
            filter.release ();
            stream.emit_result (request);
            finish (() => {
                fail_if_not_eq_int (completions, 1, "Cancellation plus late completion must notify only once");
                fail_if_not_eq_int (stream.written_nodes.size, 0, "Late preparation must not write after cancellation or detach");
            }, cb);
            return Source.REMOVE;
        });
    }

    private void test_duplicate (Gee.TestFinishedCallback cb) {
        var stream = make_stream ();
        var module = attach_module (stream);
        var filter = new HeldRequestFilter ();
        module.add_outgoing_request_filter (filter);
        int first_completions = 0;
        int rejected_completions = 0;
        var request = make_request ("duplicate");
        module.send_iq (stream, request, (_, result) => {
            first_completions++;
            fail_if (result.locally_failed, "Duplicate must not replace the original callback");
        });
        module.send_iq (stream, make_request ("duplicate"), (_, result) => {
            rejected_completions++;
            fail_if (!result.locally_failed, "Duplicate callback request must be rejected locally");
        });
        module.send_iq_async.begin (stream, make_request ("duplicate"), Priority.DEFAULT, null, (_, res) => {
            try {
                module.send_iq_async.end (res);
                fail_if_reached ("Duplicate async request must fail");
            } catch (IOError.PENDING error) { rejected_completions++; }
            catch (GLib.Error error) { fail_if_reached ("Wrong duplicate error"); }
        });
        fail_if_not_eq_int (filter.calls, 1, "Duplicate requests must not start another preparation");
        filter.release ();
        stream.emit_result (request);
        finish (() => {
            fail_if_not_eq_int (first_completions, 1, "Original callback must remain registered");
            fail_if_not_eq_int (rejected_completions, 2, "Both duplicate API paths must reject");
            fail_if_not_eq_int (stream.written_nodes.size, 1, "Duplicate IQ id must never produce a second write");
        }, cb);
    }

    private void test_cancel_immediately (Gee.TestFinishedCallback cb) {
        var stream = make_stream ();
        var module = attach_module (stream);
        var filter = new HeldRequestFilter ();
        var cancellable = new Cancellable ();
        module.add_outgoing_request_filter (filter);
        int completions = 0;
        send_request (false, module, stream, make_request ("immediate-cancel"), (result, error) => {
            completions++;
            fail_if (result == null || !((!) result).locally_failed, "Immediate cancellation must be a local failure");
        }, cancellable);
        cancellable.cancel ();
        // No main-context dispatch between caller cancellation and late filter completion.
        filter.release ();
        finish (() => {
            fail_if_not_eq_int (completions, 1, "Immediate cancellation must notify exactly once");
            fail_if_not_eq_int (stream.written_nodes.size, 0, "Pending CancellableSource dispatch must not permit a write");
        }, cb);
    }

    private void test_replacement_stream (Gee.TestFinishedCallback cb) {
        var old_stream = make_stream ();
        var module = attach_module (old_stream);
        var filter = new HeldRequestFilter ();
        module.add_outgoing_request_filter (filter);
        int old_completions = 0;
        int new_completions = 0;
        var old_request = make_request ("reused-id");
        module.send_iq (old_stream, old_request, (_, result) => {
            old_completions++;
            fail_if (!result.locally_failed, "Replacement must cancel old pending preparation");
        });
        var new_stream = make_stream ();
        new_stream.add_module (module);
        module.attach (new_stream);
        module.remove_outgoing_request_filter (filter);
        var new_request = make_request ("reused-id");
        module.send_iq (new_stream, new_request, (_, result) => {
            new_completions++;
            fail_if (result.locally_failed, "Late old-stream cleanup must not cancel the replacement request");
        });
        module.detach (old_stream);
        filter.release ();
        old_stream.emit_result (old_request);
        new_stream.emit_result (new_request);
        finish (() => {
            fail_if_not_eq_int (old_completions, 1, "Old request must complete once as cancelled");
            fail_if_not_eq_int (new_completions, 1, "Replacement request must receive its own response");
            fail_if_not_eq_int (old_stream.written_nodes.size, 0, "Old preparation must never write after replacement");
            fail_if_not_eq_int (new_stream.written_nodes.size, 1, "Replacement request must write exactly once");
        }, cb);
    }

    private void test_transport_cancellation (Gee.TestFinishedCallback cb) {
        var stream = make_stream ();
        var module = attach_module (stream);
        stream.cancel_after_write = true;
        int completions = 0;
        send_request (true, module, stream, make_request ("transport-cancel"), (result, error) => {
            completions++;
            fail_if (!(error is IOError.CANCELLED), "Transport token cancellation must preserve typed cancellation");
        }, new Cancellable ());
        finish (() => {
            fail_if_not_eq_int (completions, 1, "Cancellation after write returns must finish the waiter promptly");
            fail_if_not_eq_int (stream.written_nodes.size, 1, "Transport cancellation must not repeat the write");
        }, cb);
    }

    private void test_stale_stream_send (Gee.TestFinishedCallback cb) {
        var old_stream = make_stream ();
        var module = attach_module (old_stream);
        var replacement = make_stream ();
        replacement.add_module (module);
        module.attach (replacement);
        int completions = 0;
        send_request (false, module, old_stream, make_request ("stale-stream"), (result, error) => {
            completions++;
            fail_if (result == null || !((!) result).locally_failed, "An explicit stale-stream request must fail locally");
        });
        finish (() => {
            fail_if_not_eq_int (completions, 1, "Explicit stale-stream rejection must finish promptly");
            fail_if_not_eq_int (old_stream.written_nodes.size, 0, "A request on a replaced stream must never be written");
            fail_if_not_eq_int (replacement.written_nodes.size, 0, "A stale request must not be redirected to the replacement");
        }, cb);
    }

    private void test_responses_bypass (Gee.TestFinishedCallback cb) {
        var stream = make_stream ();
        var module = attach_module (stream);
        var filter = new HeldRequestFilter ();
        module.add_outgoing_request_filter (filter);
        var request = make_request ("response");
        module.send_iq (stream, new Iq.Stanza.result (request));
        module.send_iq (stream, new Iq.Stanza.error (request, new ErrorStanza.not_acceptable ()));
        finish (() => {
            fail_if_not_eq_int (filter.calls, 0, "IQ responses must bypass outgoing request filters");
            fail_if_not_eq_int (stream.written_nodes.size, 2, "Both IQ response types must still be sent");
        }, cb);
    }

    private void test_no_filters (Gee.TestFinishedCallback cb) {
        var stream = make_stream ();
        var module = attach_module (stream);
        int preprocess = 0;
        int completions = 0;
        module.preprocess_outgoing_iq_set_get.connect ((s, iq) => {
            preprocess++;
            iq.stanza.put_attribute ("test-preprocessed", "yes");
        });
        var request = make_request ("no-filter");
        module.send_iq (stream, request, (_, result) => completions++);
        fail_if_not_eq_int (stream.written_nodes.size, 1, "Ordinary request must still write immediately");
        fail_if_not_eq_str (stream.written_nodes[0].get_attribute ("test-preprocessed"), "yes", "Preprocess mutation must reach the wire");
        stream.emit_result (request);
        finish (() => {
            fail_if_not_eq_int (preprocess, 1, "Ordinary request keeps its preprocess signal");
            fail_if_not_eq_int (completions, 1, "Ordinary request keeps its response callback");
        }, cb);
    }

    private void test_incoming (bool reject, Gee.TestFinishedCallback cb) {
        var stream = make_stream ();
        var module = attach_module (stream);
        var filter = new ReceiveRequestFilter () { reject = reject };
        var handler = new FilterAuditHandler ();
        module.add_incoming_request_filter (filter);
        module.register_for_namespace (TEST_NS, handler);
        int preprocess = 0;
        module.preprocess_incoming_iq_set_get.connect (() => preprocess++);
        var request = make_request ("incoming");
        request.from = stream.remote_name;
        stream.received_iq_stanza (stream, request.stanza);
        finish (() => {
            fail_if_not_eq_int (preprocess, 1, "Existing incoming preprocess must still run");
            fail_if_not_eq_int (filter.calls, 1, "Incoming request must enter its filter");
            fail_if_not_eq_int (handler.calls, reject ? 0 : 1, "Rejected security request must not reach its handler");
            fail_if_not_eq_int (stream.written_nodes.size, reject ? 1 : 0, "Rejected incoming request should return exactly one IQ error");
            if (reject && stream.written_nodes.size > 0) {
                var response = new Iq.Stanza.from_stanza (stream.written_nodes[0], null);
                fail_if (!response.is_error (), "Rejected incoming request must return an IQ error");
                fail_if (response.locally_failed, "Wire error must not acquire a local transport marker");
            }
        }, cb);
    }

    private void test_local_marker () {
        var node = new StanzaNode.build ("iq").put_attribute ("type", "error")
            .put_attribute ("id", "forged").put_attribute ("locally-failed", "true")
            .put_attribute ("locally_failed", "true")
            .put_attribute ("local-failure-phase", "AWAIT_RESPONSE")
            .put_attribute ("local_failure_phase", "3")
            .put_attribute ("local-failure-code", "24")
            .put_attribute ("local_failure_code", "24");
        var result = new Iq.Stanza.from_stanza (node, null);
        fail_if (result.locally_failed, "Local transport failure metadata must never be decoded from XML");
        fail_if (result.local_failure_phase != Iq.LocalFailurePhase.UNKNOWN,
            "Wire XML must never supply a local failure phase");
        fail_if_not_eq_int (result.local_failure_code, -1, "Wire XML must never supply a local error code");
    }

    private void test_local_failure_metadata () {
        var request = make_request ("local-metadata");
        var unclassified = Iq.Module.local_failure (request);
        var classified = Iq.Module.local_failure (request,
            new IOError.TIMED_OUT ("Private error details"), Iq.LocalFailurePhase.AWAIT_RESPONSE);
        fail_if (unclassified.local_failure_phase != Iq.LocalFailurePhase.UNKNOWN,
            "Existing local failure callers must retain an unknown phase");
        fail_if_not_eq_int (unclassified.local_failure_code, -1,
            "Existing local failure callers must retain an unknown error code");
        fail_if (classified.local_failure_phase != Iq.LocalFailurePhase.AWAIT_RESPONSE,
            "Classified local failure must retain its process-only phase");
        fail_if_not_eq_int (classified.local_failure_code, IOError.TIMED_OUT,
            "Classified local failure must retain its process-only error code");
        fail_if_not_eq_str (classified.stanza.to_string (), unclassified.stanza.to_string (),
            "Failure classification and private exception details must not change the wire XML");
        var parsed = new Iq.Stanza.from_stanza (classified.stanza, null);
        fail_if (parsed.locally_failed || parsed.local_failure_phase != Iq.LocalFailurePhase.UNKNOWN,
            "Serializing and reparsing must discard all local failure classification");
        fail_if_not_eq_int (parsed.local_failure_code, -1,
            "Serializing and reparsing must discard the local error code");
    }

    private void test_rejected_owner (bool reject, Gee.TestFinishedCallback cb) {
        var stream = make_stream ();
        var module = attach_module (stream);
        var filter = new ReceiveRequestFilter () { reject = reject };
        var owner = new RejectionLifecycleInterceptor ();
        var unrelated = new RejectionLifecycleInterceptor ();
        var handler = new FilterAuditHandler ();
        module.add_incoming_request_filter (filter);
        module.register_interceptor_for_namespace (TEST_NS, owner);
        module.register_interceptor_for_namespace (TEST_NS + ":unrelated", unrelated);
        module.register_for_namespace (TEST_NS, handler);
        var request = make_request ("rejection-owner");
        request.from = stream.remote_name;
        stream.received_iq_stanza (stream, request.stanza);
        finish (() => {
            fail_if_not_eq_int (owner.rejected, reject ? 1 : 0,
                "Only an actual security veto must notify the matching owner exactly once");
            fail_if_not_eq_int (owner.handled, reject ? 0 : 1,
                "Rejected requests must not reach normal interception");
            fail_if_not_eq_int (unrelated.rejected, 0,
                "A security veto must not affect owners of another namespace");
            fail_if_not_eq_int (unrelated.handled, 0);
            fail_if_not_eq_int (handler.calls, reject ? 0 : 1,
                "A lifecycle notification must not apply the rejected request");
            fail_if_not_eq_int (stream.written_nodes.size, reject ? 1 : 0,
                "The IQ module owns exactly one error response to a rejected request");
            if (reject) fail_if_not_eq_str (owner.rejected_id ?? "", request.id,
                "The owner must be notified about the exact original request");
        }, cb);
    }

    private static Iq.Stanza make_request (string id) {
        var request = new Iq.Stanza.set (new StanzaNode.build ("payload", TEST_NS).add_self_xmlns (), id);
        request.stanza.put_attribute ("from", "alice@example.test/desktop");
        request.stanza.put_attribute ("to", "bob@example.test/phone");
        return request;
    }

    private static RequestFilterStream make_stream () {
        try { return new RequestFilterStream (new Jid ("example.test")); }
        catch (InvalidJidError error) { assert_not_reached (); }
    }

    private static Iq.Module attach_module (RequestFilterStream stream) {
        var module = new Iq.Module ();
        stream.add_module (module);
        module.attach (stream);
        return module;
    }

    private delegate void Assertions ();
    private static void finish (owned Assertions assertions, Gee.TestFinishedCallback cb) {
        Timeout.add (30, () => {
            assertions ();
            cb ();
            return Source.REMOVE;
        });
    }
}

private class HeldRequestFilter : Object, Iq.OutgoingRequestFilter {
    public int calls = 0;
    public bool reject = false;
    private SourceFunc? continuation;

    public async void prepare_send (XmppStream stream, Iq.Stanza iq, Cancellable cancellable) throws GLib.Error {
        calls++;
        continuation = prepare_send.callback;
        yield;
        // Deliberately ignores cancellation so the IQ module must guard late completion itself.
        if (reject) throw new IOError.PERMISSION_DENIED ("Test security preparation rejected");
    }

    public void release () {
        SourceFunc? callback = (owned) continuation;
        if (callback != null) ((!) callback) ();
    }
}

private class ReceiveRequestFilter : Object, Iq.IncomingRequestFilter {
    public int calls = 0;
    public bool reject = false;
    public void prepare_receive (XmppStream stream, Iq.Stanza iq) throws GLib.Error {
        calls++;
        if (reject) throw new IOError.PERMISSION_DENIED ("Test receive security rejected");
    }
}

private class RejectionLifecycleInterceptor : Object, Iq.Interceptor {
    public int rejected = 0;
    public int handled = 0;
    public string? rejected_id = null;

    public void on_iq_request_rejected (XmppStream stream, Iq.Stanza iq) {
        rejected++;
        rejected_id = iq.id;
    }

    public async bool try_handle_iq_set (XmppStream stream, Iq.Stanza iq) {
        handled++;
        return false;
    }
}

private class FilterAuditHandler : Object, Iq.Handler {
    public int calls = 0;
    public async void on_iq_set (XmppStream stream, Iq.Stanza iq) { calls++; }
}

private class RequestFilterStream : XmppStream {
    public Gee.ArrayList<StanzaNode> written_nodes = new Gee.ArrayList<StanzaNode> ();
    public bool cancel_after_write = false;
    public bool fail_write = false;
    public RequestFilterStream (Jid remote_name) { base (remote_name); }
    public void emit_result (Iq.Stanza request) {
        received_iq_stanza (this, new Iq.Stanza.result (request).stanza);
    }
    public override async void connect () throws IOError { }
    public override async void disconnect () throws IOError { }
    public override async StanzaNode read () throws IOError { throw new IOError.NOT_CONNECTED ("No test reader"); }
    public override async void write_async (StanzaNode node, int io_priority = Priority.DEFAULT, Cancellable? cancellable = null) throws IOError {
        if (cancellable != null) cancellable.set_error_if_cancelled ();
        if (fail_write) throw new IOError.TIMED_OUT ("Test write timed out");
        written_nodes.add (node);
        if (cancel_after_write && cancellable != null) {
            Idle.add (() => {
                cancellable.cancel ();
                return Source.REMOVE;
            });
        }
    }
    public override async void setup () throws IOError { }
}

}

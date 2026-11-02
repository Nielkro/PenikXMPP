using Gee;

namespace Xmpp.Test {

class MucVoiceRequestAudit : Gee.TestCase {
    private const string ROOM = "voice@conference.example.test";
    private const string OTHER_ROOM = "other@conference.example.test";
    private const string LOCAL_FULL = "moderator@example.test/dinox";
    private const string REQUESTER = "visitor@example.test/phone";
    private const string INVITEE = "invitee@example.test/phone";
    private const string REQUEST_NS =
        "http://jabber.org/protocol/muc#request";

    public MucVoiceRequestAudit() {
        base("MucVoiceRequestAudit");
        add_async_test("XEP0045_voice_request_requires_authoritative_form",
            test_requires_authoritative_form);
        add_async_test("XEP0045_voice_request_send_is_correlated",
            test_send_is_correlated);
        add_async_test("XEP0045_voice_request_error_is_exactly_correlated",
            test_error_is_exactly_correlated);
        add_async_test("XEP0045_voice_request_write_failure_is_reported",
            test_write_failure_is_reported);
        add_async_test("XEP0045_voice_request_timeout_precedes_late_write",
            test_timeout_precedes_late_write);
        add_async_test("XEP0045_voice_request_detach_clears_correlation",
            test_detach_clears_correlation);
        add_async_test("XEP0045_voice_approval_submission_is_correlated",
            test_approval_submission_is_correlated);
        add_async_test("XEP0045_mediated_invite_error_is_exactly_correlated",
            test_invite_error_is_exactly_correlated);
        add_async_test("XEP0045_mediated_invite_write_failure_clears_correlation",
            test_invite_write_failure_clears_correlation);
        add_async_test("XEP0045_mediated_invite_detach_clears_correlation",
            test_invite_detach_clears_correlation);
        add_async_test("XEP0045_room_leave_clears_pending_message_operations",
            test_room_leave_clears_pending_message_operations);
    }

    private void test_send_is_correlated(Gee.TestFinishedCallback cb) {
        test_send_is_correlated_async.begin(cb);
    }

    private async void test_send_is_correlated_async(
            Gee.TestFinishedCallback cb) {
        try {
            VoiceRequestAuditStream stream = create_stream();
            Xep.Muc.Module muc = (!) stream.get_module<Xep.Muc.Module>(
                Xep.Muc.Module.IDENTITY);
            var written = new Promise<StanzaNode>();
            var completed = new Promise<string>();
            Jid expected_room = new Jid(ROOM);
            ulong write_handler = stream.message_written.connect((node) => {
                if (!written.future.ready) written.set_value(node);
            });
            muc.voice_request_sent.connect((_, room, correlation_id) => {
                fail_if_not(room.equals(expected_room),
                    "Voice send completion must retain the bare room");
                if (!completed.future.ready) {
                    completed.set_value(correlation_id);
                }
            });

            string returned_id = muc.request_voice(stream, new Jid(ROOM));
            StanzaNode sent = yield written.future.wait_async();
            string completed_id = yield completed.future.wait_async();
            GLib.SignalHandler.disconnect(stream, write_handler);

            fail_if_not_eq_str(returned_id, sent.get_attribute("id"),
                "request_voice must return the stanza correlation ID");
            fail_if_not_eq_str(completed_id, returned_id,
                "Local send completion must retain the stanza correlation ID");
        } catch (Error e) {
            fail_if_reached(@"Unexpected voice request send error: $(e.message)");
        }
        cb();
    }

    private void test_requires_authoritative_form(
            Gee.TestFinishedCallback cb) {
        test_requires_authoritative_form_async.begin(cb);
    }

    private async void test_requires_authoritative_form_async(
            Gee.TestFinishedCallback cb) {
        try {
            VoiceRequestAuditStream stream = create_stream();
            MessageModule messages = (!) stream.get_module<MessageModule>(
                MessageModule.IDENTITY);
            Xep.Muc.Module muc = (!) stream.get_module<Xep.Muc.Module>(
                Xep.Muc.Module.IDENTITY);
            int received = 0;
            string? received_room = null;
            string? received_requester = null;
            string? received_nick = null;
            string? received_stanza_id = null;
            muc.voice_request_received.connect((_, room, requester, nick,
                    stanza_id) => {
                received++;
                received_room = room.to_string();
                received_requester = requester.to_string();
                received_nick = nick;
                received_stanza_id = stanza_id;
            });

            yield messages.received_message_stanza_async(stream,
                build_request_form(ROOM, REQUEST_NS, "participant", true,
                    "form"));
            fail_if(received != 1,
                "One authoritative voice request must be emitted once");
            fail_if_not_eq_str(received_room, ROOM,
                "Voice request room must be the bare stanza sender");
            fail_if_not_eq_str(received_requester, REQUESTER,
                "The exact request JID must survive for the approval response");
            fail_if_not_eq_str(received_nick, "Visitor",
                "Voice request nickname must survive parsing");
            fail_if_not_eq_str(received_stanza_id, "voice-request-1",
                "Voice request stanza id must reach deduplication consumers");

            yield messages.received_message_stanza_async(stream,
                build_request_form(ROOM + "/forged", REQUEST_NS,
                    "participant", true, "form"));
            yield messages.received_message_stanza_async(stream,
                build_request_form(OTHER_ROOM, REQUEST_NS, "participant",
                    true, "form"));
            yield messages.received_message_stanza_async(stream,
                build_request_form(ROOM, REQUEST_NS, "moderator", true,
                    "form"));
            yield messages.received_message_stanza_async(stream,
                build_request_form(ROOM, REQUEST_NS, "participant", true,
                    "submit"));
            yield messages.received_message_stanza_async(stream,
                build_request_form(ROOM, REQUEST_NS, "participant", false,
                    "form"));
            StanzaNode already_allowed = build_request_form(ROOM,
                REQUEST_NS, "participant", true, "form");
            set_form_value(already_allowed, "muc#request_allow", "true");
            yield messages.received_message_stanza_async(stream,
                already_allowed);

            var archived_request = new MessageStanza.from_stanza(
                build_request_form(ROOM, REQUEST_NS, "participant", true,
                    "form"),
                new Jid(LOCAL_FULL));
            archived_request.add_flag(
                new MessageArchiveManagement.MessageFlag(new Jid(ROOM),
                    new DateTime.now_utc(), "archived-request", "query-1"));
            yield messages.received_pipeline.run(stream, archived_request);

            StanzaNode delayed_request = build_request_form(ROOM, REQUEST_NS,
                "participant", true, "form");
            delayed_request.put_node(new StanzaNode.build("delay",
                Xep.DelayedDelivery.NS_URI).add_self_xmlns());
            yield messages.received_message_stanza_async(stream,
                delayed_request);
            fail_if(received != 1,
                "Forged, unjoined, malformed, archived, delayed, or non-request forms must be ignored");
        } catch (Error e) {
            fail_if_reached(@"Unexpected voice request parser error: $(e.message)");
        }
        cb();
    }

    private void test_error_is_exactly_correlated(
            Gee.TestFinishedCallback cb) {
        test_error_is_exactly_correlated_async.begin(cb);
    }

    private async void test_error_is_exactly_correlated_async(
            Gee.TestFinishedCallback cb) {
        try {
            VoiceRequestAuditStream stream = create_stream();
            MessageModule messages = (!) stream.get_module<MessageModule>(
                MessageModule.IDENTITY);
            Xep.Muc.Module muc = (!) stream.get_module<Xep.Muc.Module>(
                Xep.Muc.Module.IDENTITY);
            int failures = 0;
            string? condition = null;
            string? detail = null;
            string? failed_correlation = null;
            Jid expected_room = new Jid(ROOM);
            muc.voice_request_failed.connect((_, room, correlation_id,
                    error_condition, error_text) => {
                fail_if(!room.equals(expected_room),
                    "Voice failure must retain the requested room");
                failures++;
                failed_correlation = correlation_id;
                condition = error_condition;
                detail = error_text;
            });

            StanzaNode sent = yield request_and_wait_for_write(stream, muc);
            string? stanza_id = sent.get_attribute("id");
            fail_if(stanza_id == null,
                "Outbound voice request must have a correlation ID");
            fail_if_not_eq_str(sent.get_attribute("to"), ROOM,
                "Outbound voice request must target the bare room");
            fail_if_not_eq_str(get_form_value(sent, "FORM_TYPE"),
                REQUEST_NS, "Outbound request must declare its form type");
            fail_if_not_eq_str(get_form_field_type(sent, "FORM_TYPE"),
                "hidden", "Outbound FORM_TYPE must be an XEP-0004 hidden field");
            fail_if_not_eq_str(get_form_value(sent, "muc#role"),
                "participant", "Outbound request must ask for participant role");

            yield messages.received_message_stanza_async(stream,
                build_error((!) stanza_id, "attacker.example.test",
                    ErrorStanza.CONDITION_RESOURCE_CONSTRAINT, "wait"));
            yield messages.received_message_stanza_async(stream,
                build_error("unrelated-id", ROOM,
                    ErrorStanza.CONDITION_RESOURCE_CONSTRAINT, "wait"));
            fail_if(failures != 0,
                "Wrong sender or stanza ID must not consume a pending request");

            yield messages.received_message_stanza_async(stream,
                build_error((!) stanza_id, ROOM,
                    ErrorStanza.CONDITION_RESOURCE_CONSTRAINT,
                    "Please wait before requesting voice again"));
            fail_if(failures != 1,
                "Exact room and stanza ID must report one voice-request failure");
            fail_if_not_eq_str(failed_correlation, stanza_id,
                "Voice request failure must retain the stanza correlation ID");
            fail_if_not_eq_str(condition,
                ErrorStanza.CONDITION_RESOURCE_CONSTRAINT,
                "The stanza error condition must reach the UI layer");
            fail_if_not_eq_str(detail,
                "Please wait before requesting voice again",
                "The server's human-readable error must reach the UI layer");

            yield messages.received_message_stanza_async(stream,
                build_error((!) stanza_id, ROOM,
                    ErrorStanza.CONDITION_RESOURCE_CONSTRAINT, "duplicate"));
            fail_if(failures != 1,
                "A consumed correlation must not report duplicate failures");
        } catch (Error e) {
            fail_if_reached(@"Unexpected voice request correlation error: $(e.message)");
        }
        cb();
    }

    private void test_write_failure_is_reported(Gee.TestFinishedCallback cb) {
        test_write_failure_is_reported_async.begin(cb);
    }

    private async void test_write_failure_is_reported_async(
            Gee.TestFinishedCallback cb) {
        try {
            VoiceRequestAuditStream stream = create_stream();
            Xep.Muc.Module muc = (!) stream.get_module<Xep.Muc.Module>(
                Xep.Muc.Module.IDENTITY);
            stream.fail_message_writes = true;
            var failed = new Promise<string>();
            string? failed_id = null;
            muc.voice_request_failed.connect((_, room, correlation_id,
                    condition, text) => {
                failed_id = correlation_id;
                if (!failed.future.ready) failed.set_value(condition);
            });

            string returned_id = muc.request_voice(stream, new Jid(ROOM));
            string condition = yield failed.future.wait_async();
            fail_if_not_eq_str(condition, "send-failed",
                "A local transport failure must not disappear silently");
            fail_if_not_eq_str(failed_id, returned_id,
                "A local write failure must retain its stanza correlation ID");
        } catch (Error e) {
            fail_if_reached(@"Unexpected voice request write error: $(e.message)");
        }
        cb();
    }

    private void test_detach_clears_correlation(Gee.TestFinishedCallback cb) {
        test_detach_clears_correlation_async.begin(cb);
    }

    private void test_timeout_precedes_late_write(
            Gee.TestFinishedCallback cb) {
        test_timeout_precedes_late_write_async.begin(cb);
    }

    private async void test_timeout_precedes_late_write_async(
            Gee.TestFinishedCallback cb) {
        try {
            VoiceRequestAuditStream stream = create_stream();
            Xep.Muc.Module muc = (!) stream.get_module<Xep.Muc.Module>(
                Xep.Muc.Module.IDENTITY);
            stream.hold_message_writes = true;
            muc.set_voice_request_timeout_for_tests(10);

            var write_started = new Promise<bool>();
            var write_completed = new Promise<bool>();
            var failure = new Promise<string>();
            int sent = 0;
            string? failed_condition = null;
            string? failed_text = "unexpected";
            stream.message_write_started.connect((node) => {
                if (!write_started.future.ready) {
                    write_started.set_value(true);
                }
            });
            stream.message_written.connect((node) => {
                if (!write_completed.future.ready) {
                    write_completed.set_value(true);
                }
            });
            muc.voice_request_sent.connect(() => { sent++; });
            muc.voice_request_failed.connect((_, room, correlation_id,
                    condition, text) => {
                failed_condition = condition;
                failed_text = text;
                if (!failure.future.ready) {
                    failure.set_value(correlation_id);
                }
            });

            string correlation_id = muc.request_voice(stream,
                new Jid(ROOM));
            yield write_started.future.wait_async();
            string failed_id = yield failure.future.wait_async();
            fail_if_not_eq_str(failed_id, correlation_id,
                "A local-write timeout must retain its stanza correlation ID");
            fail_if_not_eq_str(failed_condition, "send-failed",
                "A local-write timeout must be reported as send-failed");
            fail_if(failed_text != null || sent != 0,
                "The timeout must have no server text and must not emit SENT");

            stream.release_message_writes();
            yield write_completed.future.wait_async();
            yield wait_milliseconds(20);
            fail_if(sent != 0,
                "A write completing after its timeout must not emit stale SENT");
        } catch (Error e) {
            fail_if_reached(@"Unexpected late voice write error: $(e.message)");
        }
        cb();
    }

    private async void test_detach_clears_correlation_async(
            Gee.TestFinishedCallback cb) {
        try {
            VoiceRequestAuditStream stream = create_stream();
            MessageModule messages = (!) stream.get_module<MessageModule>(
                MessageModule.IDENTITY);
            Xep.Muc.Module muc = (!) stream.get_module<Xep.Muc.Module>(
                Xep.Muc.Module.IDENTITY);
            int failures = 0;
            muc.voice_request_failed.connect(() => { failures++; });
            StanzaNode sent = yield request_and_wait_for_write(stream, muc);
            string stanza_id = (!) sent.get_attribute("id");

            muc.detach(stream);
            yield messages.received_message_stanza_async(stream,
                build_error(stanza_id, ROOM,
                    ErrorStanza.CONDITION_RESOURCE_CONSTRAINT, "late"));
            fail_if(failures != 0,
                "A detached stream must not retain or report stale correlations");
        } catch (Error e) {
            fail_if_reached(@"Unexpected voice request detach error: $(e.message)");
        }
        cb();
    }

    private void test_approval_submission_is_correlated(
            Gee.TestFinishedCallback cb) {
        test_approval_submission_is_correlated_async.begin(cb);
    }

    private async void test_approval_submission_is_correlated_async(
            Gee.TestFinishedCallback cb) {
        try {
            VoiceRequestAuditStream stream = create_stream();
            MessageModule messages = (!) stream.get_module<MessageModule>(
                MessageModule.IDENTITY);
            Xep.Muc.Module muc = (!) stream.get_module<Xep.Muc.Module>(
                Xep.Muc.Module.IDENTITY);
            var written = new Promise<StanzaNode>();
            var completed = new Promise<bool>();
            ulong write_handler = stream.message_written.connect((node) => {
                if (!written.future.ready) written.set_value(node);
            });
            int failures = 0;
            string? failed_correlation = null;
            muc.voice_request_response_failed.connect((_, room, correlation,
                    condition, text) => {
                failures++;
                failed_correlation = correlation;
            });

            muc.respond_to_voice_request.begin(stream, new Jid(ROOM),
                new Jid(REQUESTER), "Visitor", true, "request-42",
                (_, res) => {
                    try {
                        muc.respond_to_voice_request.end(res);
                        completed.set_value(true);
                    } catch (Error e) {
                        fail_if_reached(@"Approval write failed: $(e.message)");
                        completed.set_value(false);
                    }
                });
            StanzaNode sent = yield written.future.wait_async();
            fail_if_not(yield completed.future.wait_async(),
                "Approval submission must finish writing");
            GLib.SignalHandler.disconnect(stream, write_handler);

            fail_if_not_eq_str(sent.get_attribute("to"), ROOM,
                "Approval submission must target the bare room");
            fail_if_not_eq_str(get_form_value(sent, "FORM_TYPE"),
                REQUEST_NS, "Approval must retain the voice form type");
            fail_if_not_eq_str(get_form_field_type(sent, "FORM_TYPE"),
                "hidden", "Approval FORM_TYPE must be hidden");
            fail_if_not_eq_str(get_form_value(sent, "muc#jid"), REQUESTER,
                "Approval must echo the exact requester JID");
            fail_if_not_eq_str(get_form_value(sent, "muc#roomnick"),
                "Visitor", "Approval must echo the exact room nickname");
            fail_if_not_eq_str(get_form_value(sent, "muc#request_allow"),
                "true", "Approval must explicitly grant the request");

            string stanza_id = (!) sent.get_attribute("id");
            yield messages.received_message_stanza_async(stream,
                build_error(stanza_id, ROOM, ErrorStanza.CONDITION_FORBIDDEN,
                    "moderator permission changed"));
            fail_if(failures != 1,
                "A server rejection of an approval must be reported once");
            fail_if_not_eq_str(failed_correlation, "request-42",
                "Approval failure must retain the application request ID");

            var denial_written = new Promise<StanzaNode>();
            var denial_completed = new Promise<bool>();
            ulong denial_write_handler = stream.message_written.connect(
                (node) => {
                    if (!denial_written.future.ready) {
                        denial_written.set_value(node);
                    }
                });
            muc.respond_to_voice_request.begin(stream, new Jid(ROOM),
                new Jid(REQUESTER), "Visitor", false, "request-43",
                (_, res) => {
                    try {
                        muc.respond_to_voice_request.end(res);
                        denial_completed.set_value(true);
                    } catch (Error e) {
                        fail_if_reached(@"Denial write failed: $(e.message)");
                        denial_completed.set_value(false);
                    }
                });
            StanzaNode denied = yield denial_written.future.wait_async();
            fail_if_not(yield denial_completed.future.wait_async(),
                "Denial submission must finish writing");
            GLib.SignalHandler.disconnect(stream, denial_write_handler);
            fail_if_not_eq_str(get_form_value(denied,
                    "muc#request_allow"), "false",
                "A rejected voice request must explicitly serialize allow=false");
        } catch (Error e) {
            fail_if_reached(@"Unexpected voice approval error: $(e.message)");
        }
        cb();
    }

    private void test_invite_error_is_exactly_correlated(
            Gee.TestFinishedCallback cb) {
        test_invite_error_is_exactly_correlated_async.begin(cb);
    }

    private async void test_invite_error_is_exactly_correlated_async(
            Gee.TestFinishedCallback cb) {
        try {
            var muc = new Xep.Muc.Module();
            VoiceRequestAuditStream stream = create_stream(muc);
            VoiceRequestAuditStream other_stream = create_stream(muc);
            MessageModule messages = (!) stream.get_module<MessageModule>(
                MessageModule.IDENTITY);
            MessageModule other_messages = (!)
                other_stream.get_module<MessageModule>(MessageModule.IDENTITY);
            int failures = 0;
            string? failed_room = null;
            string? failed_invitee = null;
            string? condition = null;
            string? detail = null;
            muc.invite_failed.connect((failed_stream, room, invitee,
                    error_condition, error_text) => {
                fail_if(failed_stream != stream,
                    "A mediated-invite failure must retain its exact stream");
                failures++;
                failed_room = room.to_string();
                failed_invitee = invitee.to_string();
                condition = error_condition;
                detail = error_text;
            });

            StanzaNode sent = yield invite_and_wait_for_write(stream, muc);
            string? stanza_id = sent.get_attribute("id");
            fail_if(stanza_id == null,
                "Outbound mediated invite must have a correlation ID");
            fail_if_not_eq_str(sent.get_attribute("to"), ROOM,
                "Mediated invite must target the bare room");
            fail_if_not_eq_str(get_mediated_invitee(sent),
                new Jid(INVITEE).bare_jid.to_string(),
                "Mediated invite must serialize the invitee as a bare JID");

            yield messages.received_message_stanza_async(stream,
                build_error((!) stanza_id, OTHER_ROOM,
                    ErrorStanza.CONDITION_FORBIDDEN, "wrong room"));
            yield messages.received_message_stanza_async(stream,
                build_error("unrelated-invite-id", ROOM,
                    ErrorStanza.CONDITION_FORBIDDEN, "wrong id"));
            yield other_messages.received_message_stanza_async(other_stream,
                build_error((!) stanza_id, ROOM,
                    ErrorStanza.CONDITION_FORBIDDEN, "wrong stream"));
            fail_if(failures != 0,
                "Wrong invite ID, room, or stream must not consume the pending invite");

            yield messages.received_message_stanza_async(stream,
                build_error((!) stanza_id, ROOM,
                    ErrorStanza.CONDITION_FORBIDDEN,
                    "Only administrators may invite contacts"));
            fail_if(failures != 1,
                "Exact invite ID, room, and stream must report one failure");
            fail_if_not_eq_str(failed_room, ROOM,
                "Invite failure must retain the bare room");
            fail_if_not_eq_str(failed_invitee,
                new Jid(INVITEE).bare_jid.to_string(),
                "Invite failure must retain the bare invitee");
            fail_if_not_eq_str(condition, ErrorStanza.CONDITION_FORBIDDEN,
                "Invite failure must retain the stanza condition");
            fail_if_not_eq_str(detail,
                "Only administrators may invite contacts",
                "Invite failure must retain the server error text");

            yield messages.received_message_stanza_async(stream,
                build_error((!) stanza_id, ROOM,
                    ErrorStanza.CONDITION_FORBIDDEN, "duplicate"));
            fail_if(failures != 1,
                "A consumed invite correlation must ignore duplicate errors");
        } catch (Error e) {
            fail_if_reached(@"Unexpected mediated invite correlation error: $(e.message)");
        }
        cb();
    }

    private void test_invite_write_failure_clears_correlation(
            Gee.TestFinishedCallback cb) {
        test_invite_write_failure_clears_correlation_async.begin(cb);
    }

    private async void test_invite_write_failure_clears_correlation_async(
            Gee.TestFinishedCallback cb) {
        try {
            VoiceRequestAuditStream stream = create_stream();
            MessageModule messages = (!) stream.get_module<MessageModule>(
                MessageModule.IDENTITY);
            Xep.Muc.Module muc = (!) stream.get_module<Xep.Muc.Module>(
                Xep.Muc.Module.IDENTITY);
            int failures = 0;
            muc.invite_failed.connect(() => { failures++; });
            stream.fail_message_writes = true;
            bool write_failed = false;
            try {
                yield muc.invite(stream, new Jid(ROOM), new Jid(INVITEE));
            } catch (IOError e) {
                write_failed = true;
            }
            fail_if_not(write_failed,
                "A mediated-invite transport failure must reach the caller");
            fail_if(stream.last_message_attempt == null,
                "The failed invite write must expose its attempted stanza");
            string? stanza_id = ((!) stream.last_message_attempt)
                .get_attribute("id");
            fail_if(stanza_id == null,
                "The failed invite write must still have a stanza ID");

            stream.fail_message_writes = false;
            yield messages.received_message_stanza_async(stream,
                build_error((!) stanza_id, ROOM,
                    ErrorStanza.CONDITION_FORBIDDEN, "late"));
            fail_if(failures != 0,
                "A write-failed invite must not retain a late-error correlation");
        } catch (Error e) {
            fail_if_reached(@"Unexpected mediated invite write error: $(e.message)");
        }
        cb();
    }

    private void test_invite_detach_clears_correlation(
            Gee.TestFinishedCallback cb) {
        test_invite_detach_clears_correlation_async.begin(cb);
    }

    private async void test_invite_detach_clears_correlation_async(
            Gee.TestFinishedCallback cb) {
        try {
            VoiceRequestAuditStream stream = create_stream();
            MessageModule messages = (!) stream.get_module<MessageModule>(
                MessageModule.IDENTITY);
            Xep.Muc.Module muc = (!) stream.get_module<Xep.Muc.Module>(
                Xep.Muc.Module.IDENTITY);
            int failures = 0;
            muc.invite_failed.connect(() => { failures++; });
            StanzaNode sent = yield invite_and_wait_for_write(stream, muc);
            string stanza_id = (!) sent.get_attribute("id");

            muc.detach(stream);
            muc.attach(stream);
            yield messages.received_message_stanza_async(stream,
                build_error(stanza_id, ROOM,
                    ErrorStanza.CONDITION_FORBIDDEN, "late"));
            fail_if(failures != 0,
                "Detach must clear mediated-invite error correlation state");
        } catch (Error e) {
            fail_if_reached(@"Unexpected mediated invite detach error: $(e.message)");
        }
        cb();
    }

    private void test_room_leave_clears_pending_message_operations(
            Gee.TestFinishedCallback cb) {
        test_room_leave_clears_pending_message_operations_async.begin(cb);
    }

    private async void test_room_leave_clears_pending_message_operations_async(
            Gee.TestFinishedCallback cb) {
        try {
            VoiceRequestAuditStream stream = create_stream();
            MessageModule messages = (!) stream.get_module<MessageModule>(
                MessageModule.IDENTITY);
            Xep.Muc.Module muc = (!) stream.get_module<Xep.Muc.Module>(
                Xep.Muc.Module.IDENTITY);
            int request_failures = 0;
            int response_failures = 0;
            int invite_failures = 0;
            int settled = 0;
            string? settled_correlation = null;
            muc.voice_request_failed.connect(() => { request_failures++; });
            muc.voice_request_response_failed.connect(() => {
                response_failures++;
            });
            muc.invite_failed.connect(() => { invite_failures++; });
            muc.voice_request_response_settled.connect((event_stream,
                    event_room, correlation) => {
                settled++;
                settled_correlation = correlation;
            });

            StanzaNode request = yield request_and_wait_for_write(stream, muc);
            StanzaNode response = yield response_and_wait_for_write(stream, muc,
                "leave-correlation");
            StanzaNode invite = yield invite_and_wait_for_write(stream, muc);
            string request_id = (!) request.get_attribute("id");
            string response_id = (!) response.get_attribute("id");
            string invite_id = (!) invite.get_attribute("id");

            muc.exit(stream, new Jid(ROOM));
            fail_if(settled != 1,
                "Leaving a room must settle its pending moderator response once");
            fail_if_not_eq_str(settled_correlation, "leave-correlation",
                "Room-leave settlement must retain the response correlation ID");

            yield messages.received_message_stanza_async(stream,
                build_error(request_id, ROOM,
                    ErrorStanza.CONDITION_RESOURCE_CONSTRAINT, "late request"));
            yield messages.received_message_stanza_async(stream,
                build_error(response_id, ROOM,
                    ErrorStanza.CONDITION_FORBIDDEN, "late response"));
            yield messages.received_message_stanza_async(stream,
                build_error(invite_id, ROOM,
                    ErrorStanza.CONDITION_FORBIDDEN, "late invite"));
            fail_if(request_failures != 0 || response_failures != 0 ||
                    invite_failures != 0 || settled != 1,
                "Late errors from a left room lifecycle must not reach global UI signals");
        } catch (Error e) {
            fail_if_reached(@"Unexpected room-leave pending cleanup error: $(e.message)");
        }
        cb();
    }

    private VoiceRequestAuditStream create_stream(
            Xep.Muc.Module? shared_muc = null) throws Error {
        var stream = new VoiceRequestAuditStream(new Jid("example.test"));
        var bind_flag = new Bind.Flag();
        bind_flag.my_jid = new Jid(LOCAL_FULL);
        bind_flag.finished = true;
        stream.add_flag(bind_flag);

        var iq = new Iq.Module();
        stream.add_module(iq);
        iq.attach(stream);
        var messages = new MessageModule();
        stream.add_module(messages);
        messages.attach(stream);
        var presence = new Presence.Module();
        stream.add_module(presence);
        presence.attach(stream);
        var disco = new Xep.ServiceDiscovery.Module.with_identity(
            "client", "pc", "DinoX Voice Test");
        stream.add_module(disco);
        disco.attach(stream);
        Xep.Muc.Module muc = shared_muc ?? new Xep.Muc.Module();
        stream.add_module(muc);
        muc.attach(stream);
        ((!) stream.get_flag(Xep.Muc.Flag.IDENTITY)).set_muc_nick(
            new Jid(ROOM + "/Moderator"));
        return stream;
    }

    private async StanzaNode request_and_wait_for_write(
            VoiceRequestAuditStream stream, Xep.Muc.Module muc)
            throws Error {
        var written = new Promise<StanzaNode>();
        ulong handler_id = stream.message_written.connect((node) => {
            if (!written.future.ready) written.set_value(node);
        });
        muc.request_voice(stream, new Jid(ROOM));
        StanzaNode result = yield written.future.wait_async();
        GLib.SignalHandler.disconnect(stream, handler_id);
        return result;
    }

    private async StanzaNode response_and_wait_for_write(
            VoiceRequestAuditStream stream, Xep.Muc.Module muc,
            string correlation_id) throws Error {
        var written = new Promise<StanzaNode>();
        ulong handler_id = stream.message_written.connect((node) => {
            if (!written.future.ready) written.set_value(node);
        });
        yield muc.respond_to_voice_request(stream, new Jid(ROOM),
            new Jid(REQUESTER), "Visitor", true, correlation_id);
        StanzaNode result = yield written.future.wait_async();
        GLib.SignalHandler.disconnect(stream, handler_id);
        return result;
    }

    private async StanzaNode invite_and_wait_for_write(
            VoiceRequestAuditStream stream, Xep.Muc.Module muc)
            throws Error {
        var written = new Promise<StanzaNode>();
        ulong handler_id = stream.message_written.connect((node) => {
            if (!written.future.ready) written.set_value(node);
        });
        yield muc.invite(stream, new Jid(ROOM), new Jid(INVITEE),
            "Join the room");
        StanzaNode result = yield written.future.wait_async();
        GLib.SignalHandler.disconnect(stream, handler_id);
        return result;
    }

    private async void wait_milliseconds(uint milliseconds) throws Error {
        var completed = new Promise<bool>();
        Timeout.add(milliseconds, () => {
            completed.set_value(true);
            return Source.REMOVE;
        });
        yield completed.future.wait_async();
    }

    private static StanzaNode build_request_form(string from,
            string form_type, string role, bool include_form_type,
            string data_form_type) {
        StanzaNode form = new StanzaNode.build("x", Xep.DataForms.NS_URI)
            .add_self_xmlns().put_attribute("type", data_form_type);
        if (include_form_type) {
            StanzaNode form_type_field = build_field("FORM_TYPE", form_type);
            form_type_field.put_attribute("type", "hidden");
            form.put_node(form_type_field);
        }
        form.put_node(build_field("muc#role", role));
        form.put_node(build_field("muc#jid", REQUESTER));
        form.put_node(build_field("muc#roomnick", "Visitor"));
        form.put_node(build_field("muc#request_allow", "false"));
        return new StanzaNode.build("message")
            .put_attribute("id", "voice-request-1")
            .put_attribute("from", from)
            .put_attribute("type", MessageStanza.TYPE_NORMAL)
            .put_node(form);
    }

    private static StanzaNode build_field(string var_, string value) {
        return new StanzaNode.build("field", Xep.DataForms.NS_URI)
            .put_attribute("var", var_)
            .put_node(new StanzaNode.build("value", Xep.DataForms.NS_URI)
                .put_node(new StanzaNode.text(value)));
    }

    private static StanzaNode build_error(string id, string from,
            string condition, string? text) {
        var error = new ErrorStanza.build(ErrorStanza.TYPE_WAIT, condition,
            text, null);
        return new StanzaNode.build("message")
            .put_attribute("id", id)
            .put_attribute("from", from)
            .put_attribute("type", Stanza.TYPE_ERROR)
            .put_node(error.error_node);
    }

    private static string? get_form_value(StanzaNode message, string var_) {
        StanzaNode? form = message.get_subnode("x", Xep.DataForms.NS_URI);
        if (form == null) return null;
        foreach (StanzaNode field in ((!) form).get_subnodes("field",
                Xep.DataForms.NS_URI)) {
            if (field.get_attribute("var") != var_) continue;
            StanzaNode? value = field.get_subnode("value",
                Xep.DataForms.NS_URI);
            return value != null ? ((!) value).get_string_content() : null;
        }
        return null;
    }

    private static string? get_mediated_invitee(StanzaNode message) {
        StanzaNode? x_node = message.get_subnode("x",
            "http://jabber.org/protocol/muc#user");
        if (x_node == null) return null;
        StanzaNode? invite = ((!) x_node).get_subnode("invite",
            "http://jabber.org/protocol/muc#user");
        return invite != null ? ((!) invite).get_attribute("to") : null;
    }

    private static string? get_form_field_type(StanzaNode message,
            string var_) {
        StanzaNode? form = message.get_subnode("x", Xep.DataForms.NS_URI);
        if (form == null) return null;
        foreach (StanzaNode field in ((!) form).get_subnodes("field",
                Xep.DataForms.NS_URI)) {
            if (field.get_attribute("var") == var_) {
                return field.get_attribute("type");
            }
        }
        return null;
    }

    private static void set_form_value(StanzaNode message, string var_,
            string value) {
        StanzaNode? form = message.get_subnode("x", Xep.DataForms.NS_URI);
        if (form == null) return;
        foreach (StanzaNode field in ((!) form).get_subnodes("field",
                Xep.DataForms.NS_URI)) {
            if (field.get_attribute("var") != var_) continue;
            StanzaNode? value_node = field.get_subnode("value",
                Xep.DataForms.NS_URI);
            if (value_node == null) return;
            ((!) value_node).sub_nodes.clear();
            ((!) value_node).put_node(new StanzaNode.text(value));
            return;
        }
    }
}

private class VoiceRequestAuditStream : XmppStream {
    public signal void message_write_started(StanzaNode node);
    public signal void message_written(StanzaNode node);
    public bool fail_message_writes { get; set; default = false; }
    public bool hold_message_writes { get; set; default = false; }
    public StanzaNode? last_message_attempt { get; private set;
        default = null; }
    private Promise<bool> message_write_release = new Promise<bool>();

    public VoiceRequestAuditStream(Jid remote_name) {
        base(remote_name);
    }

    public override async void connect() throws IOError {}
    public override async void disconnect() throws IOError {}
    public override async StanzaNode read() throws IOError {
        throw new IOError.NOT_CONNECTED("test stream has no reader");
    }
    public override async void write_async(StanzaNode node,
            int io_priority = Priority.DEFAULT,
            Cancellable? cancellable = null) throws IOError {
        if (cancellable != null) cancellable.set_error_if_cancelled();
        if (node.name != "message") return;
        last_message_attempt = node;
        message_write_started(node);
        if (fail_message_writes) {
            throw new IOError.BROKEN_PIPE("simulated message write failure");
        }
        if (hold_message_writes) {
            try {
                yield message_write_release.future.wait_async();
            } catch (Gee.FutureError e) {
                throw new IOError.FAILED(
                    "Delayed test write could not be released: %s".printf(
                        e.message));
            }
        }
        message_written(node);
    }
    public void release_message_writes() {
        if (!message_write_release.future.ready) {
            message_write_release.set_value(true);
        }
    }
    public override async void setup() throws IOError {}
}

}

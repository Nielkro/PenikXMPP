using Gee;
using Xmpp;
using Xmpp.Xep;

namespace Dino.Test {

class RegistrationFormTest : Gee.TestCase {
    public RegistrationFormTest() {
        base("RegistrationForm");
        foreach (string condition in new string[] { "service-unavailable", "forbidden", "not-allowed", "feature-not-implemented" }) {
            string captured = condition;
            add_test(condition + "_offers_known_registration_website", () => { run_case(captured); });
        }
        add_test("malformed_error_is_not_empty_form", () => { run_case("malformed-error"); });
        add_test("missing_query_is_not_empty_form", () => { run_case("missing-query"); });
        add_test("foreign_reply_is_not_registration_refusal", () => { run_case("foreign-reply"); });
        add_test("rate_limit_is_not_registration_refusal", () => { run_case("resource-constraint"); });
        add_test("legacy_form_preserves_fields", () => { run_case("legacy"); });
        add_test("data_form_preserves_fields", () => { run_case("data-form"); });
        add_test("oob_preserves_server_website", () => { run_case("oob"); });
        add_test("instructions_only_remains_success", () => { run_case("instructions"); });
        add_test("empty_query_is_distinct_from_iq_error", () => { run_case("empty-query"); });
        add_test("senderless_server_result_remains_supported", () => { run_case("senderless"); });
        add_test("invite_preauth_unsupported_stops_form_request", () => { run_case("invite-unsupported"); });
        add_test("invite_preauth_rejection_stops_form_request", () => { run_case("invite-rejected"); });
        add_test("invite_preauth_precedes_form_request", () => { run_case("invite-success"); });
        add_test("tls_failure_never_offers_website", test_tls_failure);
    }

    private void run_case(string mode) {
        try {
            var stream = new RegistrationFormAuditStream(new Jid("example.test"), mode);
            string? token = mode.has_prefix("invite-") ? "test-invitation-token" : null;
            bool done = false;
            bool expired = false;
            Register.RegistrationFormReturn? result = null;
            var timeout = new TimeoutSource(2000);
            timeout.set_callback(() => { expired = true; return Source.REMOVE; });
            timeout.attach(null);
            Register.get_registration_form_on_stream.begin(stream, new Jid("example.test"), token, (obj, res) => {
                result = Register.get_registration_form_on_stream.end(res);
                done = true;
            });
            while (!done && !expired) MainContext.default().iteration(true);
            timeout.destroy();
            if (fail_if(expired || result == null, "Mock registration form request did not complete")) return;
            var response = (!) result;
            if (mode == "service-unavailable" || mode == "forbidden" || mode == "not-allowed" || mode == "feature-not-implemented") {
                fail_if(response.form != null, "A refused IQ must never become an empty successful form");
                fail_if_not_eq_str(mode, response.error);
                // This is the production AddAccountDialog decision gate. Its
                // provider additionally supplies the validated website URL.
                fail_if_not(response.registration_unavailable, "Registration refusal must allow the known website fallback");
            } else if (mode == "malformed-error" || mode == "missing-query" || mode == "foreign-reply") {
                fail_if(response.form != null, "An invalid response must not become a successful form");
                fail_if_not_eq_str(InBandRegistration.ERROR_INVALID_RESPONSE, response.error);
                fail_if(response.registration_unavailable, "Malformed or foreign responses do not establish a registration refusal");
            } else if (mode == "resource-constraint") {
                fail_if(response.form != null, "A temporary rejection must not become a successful form");
                fail_if_not_eq_str(mode, response.error);
                fail_if(response.registration_unavailable, "A temporary rate limit must not be described as outdated provider data");
            } else if (mode == "invite-unsupported") {
                fail_if(response.form != null, "Unsupported invitation registration must not request a form");
                fail_if_not_eq_str(Register.ERROR_INVITE_REGISTRATION_UNSUPPORTED, response.error);
                fail_if(stream.writes.size != 0, "Unsupported preauthorization must not transmit the invitation token");
            } else if (mode == "invite-rejected") {
                fail_if(response.form != null, "A rejected invitation must not request a form");
                fail_if_not_eq_str("Invitation invalid", response.error);
                fail_if(stream.writes.size != 1, "A rejected invitation must stop after preauthorization");
            } else {
                fail_if(response.error != null, "Successful forms must not gain an error");
                fail_if(response.registration_unavailable, "A valid response must not trigger the provider website fallback");
                if (fail_if(response.form == null, "Successful response must retain its form")) return;
                var form = (!) response.form;
                if (mode == "oob") {
                    fail_if_not_eq_str("https://example.test/register", form.oob);
                } else if (mode == "instructions") {
                    fail_if_not_eq_str("Contact the administrator to register.", form.instructions);
                    fail_if(form.fields.size != 0, "Instruction-only form must remain distinct from an editable form");
                } else if (mode == "empty-query") {
                    fail_if(form.fields.size != 0 || form.instructions != null || form.oob != null,
                            "Successful empty query must remain distinct from an IQ error");
                } else {
                    fail_if(form.fields.size != 2, "Valid registration form must preserve username and password fields");
                    fail_if(form.is_legacy_form != (mode != "data-form"), "Legacy and data forms must retain their submit format");
                }
                if (mode == "invite-success") {
                    fail_if(stream.writes.size != 2, "Invitation preauthorization must precede the form request");
                    var preauth = stream.writes[0].get_subnode("preauth", InBandRegistration.NS_URI_PARS);
                    fail_if(preauth == null || ((!) preauth).get_attribute("token") != token,
                            "Preauthorization must use the invitation supplied by this request");
                }
            }
            foreach (var request in stream.writes) {
                fail_if(request.get_attribute("to") != "example.test", "Registration request must stay on its initiating server");
            }
            var iq = stream.get_module<Iq.Module>(Iq.Module.IDENTITY);
            iq.detach(stream);
        } catch (Error e) {
            fail_if_reached("Registration form fixture setup failed");
        }
    }

    private void test_tls_failure() {
        var response = new Register.RegistrationFormReturn() {
            error = ErrorStanza.CONDITION_SERVICE_UNAVAILABLE,
            error_flags = TlsCertificateFlags.UNKNOWN_CA
        };
        fail_if(response.registration_unavailable, "TLS errors must retain their own security decision");
    }
}

internal class RegistrationFormAuditStream : XmppStream {
    public ArrayList<StanzaNode> writes = new ArrayList<StanzaNode>();
    private string mode;

    public RegistrationFormAuditStream(Jid remote_name, string mode) {
        base(remote_name);
        this.mode = mode;
        negotiation_complete = true;
        if (mode == "invite-success" || mode == "invite-rejected") {
            features.put_node(new StanzaNode.build("register", InBandRegistration.NS_URI_IBR_TOKEN));
        }
        var iq = new Iq.Module();
        add_module(iq);
        iq.attach(this);
        add_module(new InBandRegistration.Module());
    }

    public override async void connect() throws IOError { }
    public override async void disconnect() throws IOError { }
    public override async void setup() throws IOError { }
    public override async StanzaNode read() throws IOError {
        throw new IOError.NOT_CONNECTED("Fixture has no reader");
    }

    public override async void write_async(StanzaNode request,
            int io_priority = Priority.DEFAULT, Cancellable? cancellable = null) throws IOError {
        if (cancellable != null) ((!) cancellable).set_error_if_cancelled();
        request.to_xml();
        writes.add(request);
        Idle.add(() => {
            var response = new StanzaNode.build("iq", "jabber:client")
                    .put_attribute("type", "result")
                    .put_attribute("id", request.get_attribute("id"));
            if (mode != "senderless") response.put_attribute("from", mode == "foreign-reply" ? "foreign.example.test" : "example.test");
            if (request.get_subnode("preauth", InBandRegistration.NS_URI_PARS) != null) {
                if (mode == "invite-rejected") {
                    response.set_attribute("type", "error");
                    response.put_node(new ErrorStanza.build(ErrorStanza.TYPE_AUTH, ErrorStanza.CONDITION_FORBIDDEN,
                            "Invitation invalid", null).error_node);
                }
            } else if (mode == "service-unavailable" || mode == "forbidden" || mode == "not-allowed" ||
                    mode == "feature-not-implemented" || mode == "resource-constraint" || mode == "malformed-error") {
                response.set_attribute("type", "error");
                if (mode != "malformed-error") {
                    response.put_node(new ErrorStanza.build(ErrorStanza.TYPE_CANCEL, mode, "Server policy", null).error_node);
                }
            } else if (mode != "missing-query") {
                var query = new StanzaNode.build("query", InBandRegistration.NS_URI).add_self_xmlns();
                if (mode == "oob") {
                    query.put_node(new StanzaNode.build("x", "jabber:x:oob").add_self_xmlns()
                            .put_node(new StanzaNode.build("url", "jabber:x:oob")
                            .put_node(new StanzaNode.text("https://example.test/register"))));
                } else if (mode == "instructions") {
                    query.put_node(new StanzaNode.build("instructions", InBandRegistration.NS_URI)
                            .put_node(new StanzaNode.text("Contact the administrator to register.")));
                } else if (mode == "data-form") {
                    var form = new StanzaNode.build("x", DataForms.NS_URI).add_self_xmlns().put_attribute("type", "form");
                    foreach (string field in new string[] { "username", "password" }) {
                        form.put_node(new StanzaNode.build("field", DataForms.NS_URI)
                                .put_attribute("var", field).put_attribute("type", field == "password" ? "text-private" : "text-single"));
                    }
                    query.put_node(form);
                } else if (mode != "empty-query") {
                    query.put_node(new StanzaNode.build("username", InBandRegistration.NS_URI));
                    query.put_node(new StanzaNode.build("password", InBandRegistration.NS_URI));
                }
                response.put_node(query);
            }
            received_iq_stanza(this, response);
            return Source.REMOVE;
        });
    }
}

}

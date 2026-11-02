using Gee;

using Xmpp;
using Dino.Entities;

namespace Dino {

public class Register : StreamInteractionModule, Object{
    public static ModuleIdentity<Register> IDENTITY = new ModuleIdentity<Register>("registration");
    public const string ERROR_INVITE_REGISTRATION_UNSUPPORTED = "invite-registration-unsupported";
    public const string ERROR_CONNECTION_FAILED = "connection-failed";
    public const string ERROR_NO_RESPONSE = "no-response";
    public string id { get { return IDENTITY.id; } }

    private StreamInteractor stream_interactor;
    private Database db;

    public static void start(StreamInteractor stream_interactor, Database db) {
        Register m = new Register(stream_interactor, db);
        stream_interactor.add_module(m);
    }

    private Register(StreamInteractor stream_interactor, Database db) {
        this.stream_interactor = stream_interactor;
        this.db = db;
    }

    public class AccountCheckReturn {
        public ConnectionManager.ConnectionError.Source? error_source { get; set; }
        public string? error_identifier { get; set; }
        public TlsCertificateFlags? error_flags { get; set; }
        public TlsCertificate? tls_certificate { get; set; }
    }

    public async ConnectionManager.ConnectionError.Source? add_check_account(Account account) {
        return (yield check_account(account)).error_source;
    }

    public async AccountCheckReturn check_account(Account account) {
        AccountCheckReturn ret = new AccountCheckReturn();

        Gee.List<XmppStreamModule> list = new ArrayList<XmppStreamModule>();
        list.add(new Iq.Module());
        var sasl = new Sasl.Module(account.bare_jid.to_string(), account.password) {
            allow_plain = account.allow_plain,
            scram_seen = account.scram_seen,
            require_channel_binding = account.require_channel_binding
        };
        sasl.persist_scram = () => account.remember_scram();
        list.add(sasl);

        uint16 custom_port = (account.custom_port > 0 && account.custom_port <= 65535) ? (uint16) account.custom_port : 0;
        uint16 proxy_port = (account.proxy_port > 0 && account.proxy_port <= 65535) ? (uint16) account.proxy_port : 0;
        XmppStreamResult stream_result = yield Xmpp.establish_stream(account.bare_jid.domain_jid, list, Application.print_xmpp,
                (peer_cert, errors) => {
                    // Check pinned certificates in database
                    if (db != null) {
                        string cert_fp = CertificateManager.get_certificate_fingerprint(peer_cert);
                        string? pinned_fp = db.pinned_certificate.get_pinned_fingerprint(account.domainpart);
                        if (pinned_fp != null && pinned_fp == cert_fp) {
                            debug("Certificate for %s matches pinned fingerprint (check_account)", account.domainpart);
                            return true;
                        }
                    }
                    return ConnectionManager.on_invalid_certificate(account.domainpart, peer_cert, errors);
                },
                account.custom_host, custom_port,
                account.proxy_type, account.proxy_host, proxy_port,
                account.proxy_user, account.proxy_pass
        );

        if (stream_result.stream == null) {
            if (stream_result.tls_errors != null) {
                ret.error_source = ConnectionManager.ConnectionError.Source.TLS;
                ret.error_flags = stream_result.tls_errors;
                ret.tls_certificate = stream_result.tls_certificate;
            } else {
                ret.error_source = ConnectionManager.ConnectionError.Source.CONNECTION;
            }
            return ret;
        }
        XmppStream stream = stream_result.stream;

        SourceFunc callback = check_account.callback;
        stream.stream_negotiated.connect(() => {
            if (callback == null) return;
            Idle.add((owned)callback);
        });
        stream.get_module<Sasl.Module>(Sasl.Module.IDENTITY).received_auth_failure.connect((stream, node) => {
            if (callback == null) return;
            ret.error_source = ConnectionManager.ConnectionError.Source.SASL;
            ret.error_identifier = stream.get_flag(Sasl.Flag.IDENTITY)?.failure_reason;
            Idle.add((owned)callback);
        });
        stream.loop.begin((_, res) => {
            try {
                stream.loop.end(res);
            } catch (Error e) {
                debug("Error connecting to stream: %s", e.message);
            }
            if (callback != null) {
                ret.error_source = ConnectionManager.ConnectionError.Source.CONNECTION;
                Idle.add((owned)callback);
            }
        });

        yield;

        if (ret.error_source == null && !stream.negotiation_complete) {
            ret.error_source = ConnectionManager.ConnectionError.Source.CONNECTION;
        }

        stream.disconnect.begin((_, res) => {
            try {
                stream.disconnect.end(res);
            } catch (Error e) {
                debug("Registration: Failed to disconnect stream: %s", e.message);
            }
        });
        return ret;
    }

    public async string? change_password(Account account, string new_pw) {
        XmppStream? stream = stream_interactor.get_connected_stream_for_action(account);
        if (stream == null) return ERROR_CONNECTION_FAILED;
        var module = ((!) stream).get_module<Xep.InBandRegistration.Module>(
                Xep.InBandRegistration.Module.IDENTITY);
        if (module == null) return ErrorStanza.CONDITION_SERVICE_UNAVAILABLE;
        if (new_pw == "") return ErrorStanza.CONDITION_NOT_ACCEPTABLE;

        try {
            ErrorStanza? result = yield module.change_password((!) stream,
                    account.full_jid, new_pw);
            // A confirmed server change remains valid if this connection was
            // closed meanwhile. The caller must update the initiating account.
            return result != null ? ((!) result).condition : null;
        } catch (Error e) {
            // Do not expose error text: a server may echo credential data.
            return ERROR_NO_RESPONSE;
        }
    }

    public class ServerAvailabilityReturn {
        public bool available { get; set; }
        public TlsCertificateFlags? error_flags { get; set; }
        public TlsCertificate? tls_certificate { get; set; }
    }

    public async ServerAvailabilityReturn check_server_availability(Jid jid) {
        ServerAvailabilityReturn ret = new ServerAvailabilityReturn() { available=false };

        Gee.List<XmppStreamModule> list = new ArrayList<XmppStreamModule>();
        list.add(new Iq.Module());

        XmppStreamResult stream_result = yield Xmpp.establish_stream(jid.domain_jid, list, Application.print_xmpp,
                (peer_cert, errors) => {
                    // Check pinned certificates in database
                    if (db != null) {
                        string cert_fp = CertificateManager.get_certificate_fingerprint(peer_cert);
                        string? pinned_fp = db.pinned_certificate.get_pinned_fingerprint(jid.domainpart);
                        if (pinned_fp != null && pinned_fp == cert_fp) {
                            debug("Certificate for %s matches pinned fingerprint (check_server_availability)", jid.domainpart);
                            return true;
                        }
                    }
                    return ConnectionManager.on_invalid_certificate(jid.domainpart, peer_cert, errors);
                }
        );

        if (stream_result.stream == null) {
            if (stream_result.io_error != null) {
                debug("Error connecting to stream: %s", stream_result.io_error.message);
            }
            if (stream_result.tls_errors != null) {
                ret.error_flags = stream_result.tls_errors;
                ret.tls_certificate = stream_result.tls_certificate;
            }
            return ret;
        }
        XmppStream stream = stream_result.stream;

        SourceFunc callback = check_server_availability.callback;
        stream.stream_negotiated.connect(() => {
            if (callback != null) {
                ret.available = true;
                Idle.add((owned)callback);
            }
        });

        stream.loop.begin((_, res) => {
            try {
                stream.loop.end(res);
            } catch (Error e) {
                debug("Error connecting to stream: %s", e.message);
            }
            if (callback != null) {
                Idle.add((owned)callback);
            }
        });

        yield;

        stream.disconnect.begin((_, res) => {
            try {
                stream.disconnect.end(res);
            } catch (Error e) {
                debug("Registration: Failed to disconnect stream (check_server_availability): %s", e.message);
            }
        });
        return ret;
    }

    public class RegistrationFormReturn {
        public Xep.InBandRegistration.Form? form { get; set; }
        public TlsCertificateFlags? error_flags { get; set; }
        public string? error { get; set; }

        // A refused in-band request may use a known registration website.
        // Transport, TLS and malformed-response errors are not evidence that
        // the provider's advertised registration policy has changed.
        public bool registration_unavailable {
            get {
                if (form != null || error_flags != null) return false;
                return error == ErrorStanza.CONDITION_SERVICE_UNAVAILABLE ||
                        error == ErrorStanza.CONDITION_FEATURE_NOT_IMPLEMENTED ||
                        error == ErrorStanza.CONDITION_FORBIDDEN ||
                        error == ErrorStanza.CONDITION_NOT_ALLOWED;
            }
        }
    }

    internal static async RegistrationFormReturn get_registration_form_on_stream(
            XmppStream stream, Jid jid, string? preauth_token = null) {
        var ret = new RegistrationFormReturn();
        var registration_module = stream.get_module<Xep.InBandRegistration.Module>(Xep.InBandRegistration.Module.IDENTITY);
        if (registration_module == null) {
            ret.error = ErrorStanza.CONDITION_SERVICE_UNAVAILABLE;
            return ret;
        }
        if (preauth_token != null && preauth_token != "") {
            if (!registration_module.supports_preauth(stream)) {
                ret.error = ERROR_INVITE_REGISTRATION_UNSUPPORTED;
            } else {
                ret.error = yield registration_module.preauthorize_registration(stream, jid, (!) preauth_token);
            }
        }
        if (ret.error == null) {
            string? error;
            ret.form = yield registration_module.get_from_server_with_error(stream, jid, out error);
            ret.error = error;
        }
        return ret;
    }

    public static async RegistrationFormReturn get_registration_form(Jid jid, string? preauth_token = null) {
        RegistrationFormReturn ret = new RegistrationFormReturn();

        Gee.List<XmppStreamModule> list = new ArrayList<XmppStreamModule>();
        list.add(new Iq.Module());
        list.add(new Xep.InBandRegistration.Module());
        list.add(new Xep.BitsOfBinary.Module());

        XmppStreamResult stream_result = yield Xmpp.establish_stream(jid.domain_jid, list, Application.print_xmpp,
                (peer_cert, errors) => { return ConnectionManager.on_invalid_certificate(jid.domainpart, peer_cert, errors); }
        );

        if (stream_result.stream == null) {
            if (stream_result.io_error != null) {
                debug("Error connecting to stream: %s", stream_result.io_error.message);
            }
            if (stream_result.tls_errors != null) {
                ret.error_flags = stream_result.tls_errors;
            }
            return ret;
        }
        XmppStream stream = stream_result.stream;

        SourceFunc callback = get_registration_form.callback;

        stream.stream_negotiated.connect(() => {
            if (callback != null) {
                Idle.add((owned)callback);
            }
        });

        stream.loop.begin((_, res) => {
            try {
                stream.loop.end(res);
            } catch (Error e) {
                debug("Error connecting to stream: %s", e.message);
            }
            if (callback != null) {
                Idle.add((owned)callback);
            }
        });

        yield;

        if (stream.negotiation_complete) {
            ret = yield get_registration_form_on_stream(stream, jid, preauth_token);
        }
        try {
            yield stream.disconnect();
        } catch (Error e) {
            debug("Registration: Failed to disconnect stream (get_registration_form): %s", e.message);
        }

        return ret;
    }

    public static async string? submit_form(Jid jid, Xep.InBandRegistration.Form form, string? preauth_token = null) {
        Gee.List<XmppStreamModule> list = new ArrayList<XmppStreamModule>();
        list.add(new Iq.Module());
        list.add(new Xep.InBandRegistration.Module());

        XmppStreamResult stream_result = yield Xmpp.establish_stream(jid.domain_jid, list, Application.print_xmpp,
                (peer_cert, errors) => { return ConnectionManager.on_invalid_certificate(jid.domainpart, peer_cert, errors); }
        );

        if (stream_result.stream == null) {
            return ERROR_CONNECTION_FAILED;
        }
        XmppStream stream = stream_result.stream;

        SourceFunc callback = submit_form.callback;

        stream.stream_negotiated.connect(() => {
            if (callback != null) {
                Idle.add((owned)callback);
            }
        });

        stream.loop.begin((_, res) => {
            try {
                stream.loop.end(res);
            } catch (Error e) {
                debug("Error connecting to stream: %s", e.message);
            }
            if (callback != null) {
                Idle.add((owned)callback);
            }
        });

        yield;

        string? ret = null;
        if (stream.negotiation_complete) {
            var registration_module = stream.get_module<Xep.InBandRegistration.Module>(Xep.InBandRegistration.Module.IDENTITY);
            if (preauth_token != null && preauth_token != "") {
                if (!registration_module.supports_preauth(stream)) {
                    ret = ERROR_INVITE_REGISTRATION_UNSUPPORTED;
                } else {
                    ret = yield registration_module.preauthorize_registration(stream, jid, (!) preauth_token);
                }
            }
            if (ret == null) {
                ret = yield registration_module.submit_to_server(stream, jid, form);
            }
        } else {
            ret = ERROR_NO_RESPONSE;
        }
        try {
            yield stream.disconnect();
        } catch (Error e) {
            debug("Registration: Failed to disconnect stream (submit_form): %s", e.message);
        }
        return ret;
    }
}

}

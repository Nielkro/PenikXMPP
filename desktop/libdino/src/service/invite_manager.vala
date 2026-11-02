using Gee;

using Dino.Entities;
using Xmpp;

namespace Dino {

public class InviteResult : Object {
    public string uri { get; private set; }
    public string? landing_url { get; private set; }
    public string? expires_at { get; private set; }

    public InviteResult(string uri, string? landing_url = null, string? expires_at = null) {
        this.uri = uri;
        this.landing_url = landing_url;
        this.expires_at = expires_at;
    }

    public static InviteResult? from_command(Xep.AdHocCommands.Command command) {
        if (command.status != Xep.AdHocCommands.Command.Status.COMPLETED || command.form == null) {
            return null;
        }

        string uri = field_value(command.form, "uri");
        if (uri == "") return null;

        string landing_url = field_value(command.form, "landing-url");
        string expires_at = field_value(command.form, "expiry");
        if (expires_at == "") {
            expires_at = field_value(command.form, "expire");
        }

        return new InviteResult(
            uri,
            landing_url == "" ? null : landing_url,
            expires_at == "" ? null : expires_at
        );
    }

    private static string field_value(Xep.DataForms.DataForm? form, string var_name) {
        if (form == null) return "";
        foreach (Xep.DataForms.DataForm.Field field in form.fields) {
            if (field.var == var_name) {
                return field.get_value_string().strip();
            }
        }
        return "";
    }
}

public class InviteManager : StreamInteractionModule, Object {
    public static ModuleIdentity<InviteManager> IDENTITY = new ModuleIdentity<InviteManager>("invite_manager");
    public const string USER_INVITE_NODE = "urn:xmpp:invite#invite";
    public const string ACCOUNT_INVITE_NODE = "urn:xmpp:invite#create-account";

    public string id { get { return IDENTITY.id; } }

    private StreamInteractor stream_interactor;
    public string? last_error { get; private set; }

    public static void start(StreamInteractor stream_interactor) {
        stream_interactor.add_module(new InviteManager(stream_interactor));
    }

    private InviteManager(StreamInteractor stream_interactor) {
        this.stream_interactor = stream_interactor;
    }

    public async InviteResult? create_user_invite(Account account) {
        last_error = null;
        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream == null) {
            last_error = "account-not-connected";
            return null;
        }

        var module = stream.get_module<Xep.AdHocCommands.Module>(Xep.AdHocCommands.Module.IDENTITY);
        Xep.AdHocCommands.Command? command = yield module.execute(stream, account.bare_jid.domain_jid, USER_INVITE_NODE);
        if (command == null) {
            last_error = module.last_error ?? "command-failed";
            return null;
        }

        InviteResult? result = InviteResult.from_command(command);
        if (result == null) {
            last_error = "invite-result-invalid";
        }
        return result;
    }
}

}

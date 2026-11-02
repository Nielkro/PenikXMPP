using Gee;

using Dino.Entities;
using Xmpp;

namespace Dino {

public enum MucInviteSource {
    MEDIATED,
    DIRECT
}

public enum MucInviteState {
    PENDING,
    ACCEPTED,
    DECLINED,
    DISMISSED,
    ALREADY_JOINED
}

public class PendingMucInvite : Object {
    public int id { get; private set; }
    public Account account { get; private set; }
    public Jid room_jid { get; private set; }
    public Jid from_jid { get; private set; }
    public MucInviteSource source { get; private set; }
    public string? password { get; private set; }
    public string? reason { get; private set; }
    public bool continue_thread { get; private set; }
    public string? thread { get; private set; }
    public MucInviteState state { get; private set; }
    public DateTime received_at { get; private set; }
    public DateTime updated_at { get; private set; }

    internal PendingMucInvite(int id, Account account, Jid room_jid, Jid from_jid, MucInviteSource source,
            string? password, string? reason, bool continue_thread, string? thread) {
        this.id = id;
        this.account = account;
        this.room_jid = room_jid;
        this.from_jid = from_jid;
        this.source = source;
        this.password = password;
        this.reason = reason;
        this.continue_thread = continue_thread;
        this.thread = thread;
        this.state = MucInviteState.PENDING;
        this.received_at = new DateTime.now_utc();
        this.updated_at = received_at;
    }

    internal void refresh(Jid from_jid, MucInviteSource source, string? password, string? reason, bool continue_thread, string? thread) {
        if (source == MucInviteSource.MEDIATED || this.source != MucInviteSource.MEDIATED) {
            this.from_jid = from_jid;
            this.source = source;
        }
        if (password != null) {
            this.password = password;
        }
        if (reason != null) {
            this.reason = reason;
        }
        if (continue_thread) {
            this.continue_thread = true;
            this.thread = thread;
        }
        this.state = MucInviteState.PENDING;
        this.updated_at = new DateTime.now_utc();
    }

    internal void update_state(MucInviteState state) {
        this.state = state;
        this.updated_at = new DateTime.now_utc();
    }

    internal void clear_runtime_secret() {
        this.password = null;
    }
}

public class MucInviteManager : StreamInteractionModule, Object {
    public static ModuleIdentity<MucInviteManager> IDENTITY = new ModuleIdentity<MucInviteManager>("muc_invite_manager");

    public string id { get { return IDENTITY.id; } }

    public signal void invite_received(PendingMucInvite invite);
    public signal void invite_updated(PendingMucInvite invite);
    public signal void invite_removed(PendingMucInvite invite);

    private StreamInteractor stream_interactor;
    private HashMap<int, PendingMucInvite> invites_by_id = new HashMap<int, PendingMucInvite>();
    private HashMap<string, PendingMucInvite> pending_by_key = new HashMap<string, PendingMucInvite>();
    private HashSet<string> accept_in_progress = new HashSet<string>();
    private int next_id = 1;

    public static void start(StreamInteractor stream_interactor) {
        stream_interactor.add_module(new MucInviteManager(stream_interactor));
    }

    private MucInviteManager(StreamInteractor stream_interactor) {
        this.stream_interactor = stream_interactor;

        stream_interactor.get_module<MucManager>(MucManager.IDENTITY).joined.connect(on_room_joined);
        stream_interactor.get_module<MucManager>(MucManager.IDENTITY).invite_received_with_source.connect((account, room_jid, from_jid, password, reason, continue_thread, thread, source) => {
            add_or_update_invite(account, room_jid, from_jid, source, password, reason, continue_thread, thread);
        });
        stream_interactor.account_removed.connect(clear_account_invites);
    }

    public PendingMucInvite? get_invite(int id) {
        return invites_by_id[id];
    }

    public Gee.List<PendingMucInvite> get_pending_invites() {
        ArrayList<PendingMucInvite> pending = new ArrayList<PendingMucInvite>();
        foreach (PendingMucInvite invite in invites_by_id.values) {
            if (invite.state == MucInviteState.PENDING) {
                pending.add(invite);
            }
        }
        return pending;
    }

    public async Xep.Muc.JoinResult? accept(int id, string nick) {
        PendingMucInvite? invite = get_invite(id);
        if (invite == null || invite.state != MucInviteState.PENDING) return null;

        string key = invite_key(invite.account, invite.room_jid);
        if (accept_in_progress.contains(key)) return null;
        MucManager muc_manager = stream_interactor.get_module<MucManager>(MucManager.IDENTITY);
        accept_in_progress.add(key);
        Xep.Muc.JoinResult? result = yield muc_manager.join(
            invite.account, invite.room_jid, nick, invite.password, true, null, true, true
        );
        accept_in_progress.remove(key);

        if (result != null && result.nick != null) {
            invite.update_state(MucInviteState.ACCEPTED);
            remove_invite(invite);
        }
        return result;
    }

    public void decline(int id, string? reason = null) {
        PendingMucInvite? invite = get_invite(id);
        if (invite == null || invite.state != MucInviteState.PENDING) return;
        if (accept_in_progress.contains(invite_key(invite.account, invite.room_jid))) return;

        if (invite.source == MucInviteSource.MEDIATED) {
            XmppStream? stream = stream_interactor.get_stream(invite.account);
            if (stream != null) {
                var muc_module = stream.get_module<Xep.Muc.Module>(Xep.Muc.Module.IDENTITY);
                if (muc_module != null) {
                    muc_module.decline_invite(stream, invite.room_jid, invite.from_jid, reason);
                }
            }
        }

        invite.update_state(MucInviteState.DECLINED);
        remove_invite(invite);
    }

    public void dismiss(int id) {
        PendingMucInvite? invite = get_invite(id);
        if (invite == null || invite.state != MucInviteState.PENDING) return;
        if (accept_in_progress.contains(invite_key(invite.account, invite.room_jid))) return;

        invite.update_state(MucInviteState.DISMISSED);
        remove_invite(invite);
    }

    private void add_or_update_invite(Account account, Jid room_jid, Jid from_jid, MucInviteSource source,
            string? password, string? reason, bool continue_thread, string? thread) {
        if (stream_interactor.get_module<MucManager>(MucManager.IDENTITY).is_joined_or_joining(room_jid.bare_jid, account)) {
            return;
        }

        string key = invite_key(account, room_jid);
        PendingMucInvite? invite = pending_by_key[key];

        if (invite == null) {
            invite = new PendingMucInvite(next_id++, account, room_jid.bare_jid, from_jid, source, password, reason, continue_thread, thread);
            invites_by_id[invite.id] = invite;
            pending_by_key[key] = invite;
            invite_received(invite);
            return;
        }

        bool was_pending = invite.state == MucInviteState.PENDING;
        invite.refresh(from_jid, source, password, reason, continue_thread, thread);
        if (was_pending) {
            invite_updated(invite);
        } else {
            invite_received(invite);
        }
    }

    private void remove_invite(PendingMucInvite invite) {
        if (!invites_by_id.has_key(invite.id)) return;

        invite.clear_runtime_secret();
        invites_by_id.unset(invite.id);
        pending_by_key.unset(invite_key(invite.account, invite.room_jid));
        invite_removed(invite);
    }

    private void on_room_joined(Account account, Jid room_jid) {
        string key = invite_key(account, room_jid);
        if (accept_in_progress.contains(key)) return;

        PendingMucInvite? invite = pending_by_key[key];
        if (invite == null) return;

        invite.clear_runtime_secret();
        invite.update_state(MucInviteState.ALREADY_JOINED);
        invite_updated(invite);
    }

    private void clear_account_invites(Account account) {
        ArrayList<PendingMucInvite> account_invites = new ArrayList<PendingMucInvite>();
        foreach (PendingMucInvite invite in invites_by_id.values) {
            if (invite.account.id == account.id) {
                account_invites.add(invite);
            }
        }
        foreach (PendingMucInvite invite in account_invites) {
            invite.update_state(MucInviteState.DISMISSED);
            remove_invite(invite);
        }
    }

    private string invite_key(Account account, Jid room_jid) {
        return "%d|%s".printf(account.id, room_jid.bare_jid.to_string());
    }
}

}

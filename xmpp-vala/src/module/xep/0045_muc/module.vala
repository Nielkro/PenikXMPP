using Gee;

namespace Xmpp.Xep.Muc {

private const string NS_URI = "http://jabber.org/protocol/muc";
private const string NS_URI_ADMIN = NS_URI + "#admin";
private const string NS_URI_OWNER = NS_URI + "#owner";
private const string NS_URI_USER = NS_URI + "#user";
private const string NS_URI_REQUEST = NS_URI + "#request";
public const string NS_URI_HATS = "urn:xmpp:hats:0";
private const uint ENTER_TIMEOUT_SECONDS = 35;
private const uint VOICE_REQUEST_ERROR_WINDOW_SECONDS = 60;
private const uint MEDIATED_INVITE_ERROR_WINDOW_SECONDS = 60;

/**
 * Optional caller-owned lifecycle fence for affiliation-list results. It is
 * evaluated after the complete server payload was validated and immediately
 * before that payload is committed to the live MUC flag.
 */
public delegate bool AffiliationQueryCommitGuard();

public enum MucEnterError {
    PASSWORD_REQUIRED,
    BANNED,
    ROOM_DOESNT_EXIST,
    CREATION_RESTRICTED,
    USE_RESERVED_ROOMNICK,
    NOT_IN_MEMBER_LIST,
    NICK_CONFLICT,
    OCCUPANT_LIMIT_REACHED,
}

public enum Affiliation {
    NONE,
    ADMIN,
    MEMBER,
    OUTCAST,
    OWNER
}

public enum Role {
    NONE,
    MODERATOR,
    PARTICIPANT,
    VISITOR
}

public enum OccupantPresenceKind {
    AVAILABLE,
    UNAVAILABLE,
    ERROR,
    CONTROL
}

/** Parsed, immutable MUC presence data for main-context consumers. */
public class OccupantPresenceEvent : Object {
    public OccupantPresenceKind kind { get; private set; }
    public string occupant_full_jid { get; private set; }
    public string room_bare_jid { get; private set; }
    public string? nick { get; private set; }
    public string? real_bare_jid { get; private set; }
    public bool real_jid_known { get; private set; }
    public Affiliation affiliation { get; private set; }
    public bool affiliation_known { get; private set; }
    public Role role { get; private set; }
    public bool role_known { get; private set; }
    public string? avatar_hash { get; private set; }
    public bool is_self_presence { get; private set; }
    public int64 received_monotonic_us { get; private set; }

    private string[] hat_uris_value;
    private string[] hat_titles_value;
    private string[] hat_hues_value;
    private int[] status_codes_value;

    public OccupantPresenceEvent(OccupantPresenceKind kind,
            string occupant_full_jid, string room_bare_jid, string? nick,
            string? real_bare_jid, Affiliation affiliation,
            bool affiliation_known, Role role, bool role_known,
            string[]? hat_uris, string[]? hat_titles, string? avatar_hash,
            int[]? status_codes, bool is_self_presence,
            int64 received_monotonic_us, bool real_jid_known = false,
            string[]? hat_hues = null) {
        this.kind = kind;
        this.occupant_full_jid = occupant_full_jid;
        this.room_bare_jid = room_bare_jid;
        this.nick = nick;
        this.real_bare_jid = real_bare_jid;
        this.real_jid_known = real_jid_known;
        this.affiliation = affiliation;
        this.affiliation_known = affiliation_known;
        this.role = role;
        this.role_known = role_known;
        this.hat_uris_value = copy_strings(hat_uris);
        this.hat_titles_value = copy_strings(hat_titles);
        this.hat_hues_value = copy_hat_hues(hat_hues,
            this.hat_uris_value.length);
        this.avatar_hash = avatar_hash;
        this.status_codes_value = copy_integers(status_codes);
        this.is_self_presence = is_self_presence;
        this.received_monotonic_us = received_monotonic_us;
    }

    public string[] dup_hat_uris() {
        return copy_strings(hat_uris_value);
    }

    public string[] dup_hat_titles() {
        return copy_strings(hat_titles_value);
    }

    public string[] dup_hat_hues() {
        return copy_strings(hat_hues_value);
    }

    public int[] dup_status_codes() {
        return copy_integers(status_codes_value);
    }

    private static string[] copy_strings(string[]? source) {
        if (source == null) return new string[0];
        string[] copy = new string[((!) source).length];
        for (int i = 0; i < copy.length; i++) copy[i] = ((!) source)[i];
        return copy;
    }

    private static string[] copy_hat_hues(string[]? source, int count) {
        string[] copy = new string[count];
        for (int i = 0; i < count; i++) {
            copy[i] = source != null && i < ((!) source).length
                ? ((!) source)[i] : "";
        }
        return copy;
    }

    private static int[] copy_integers(int[]? source) {
        if (source == null) return new int[0];
        int[] copy = new int[((!) source).length];
        for (int i = 0; i < copy.length; i++) copy[i] = ((!) source)[i];
        return copy;
    }
}

public enum Feature {
    REGISTER,
    ROOMCONFIG,
    ROOMINFO,
    OCCUPANT_ID,
    HIDDEN,
    MEMBERS_ONLY,
    MODERATED,
    NON_ANONYMOUS,
    OPEN,
    PASSWORD_PROTECTED,
    PERSISTENT,
    PUBLIC,
    ROOMS,
    SEMI_ANONYMOUS,
    STABLE_ID,
    TEMPORARY,
    UNMODERATED,
    UNSECURED
}

public static void add_muc_pm_message_stanza_x_node(MessageStanza message_stanza) {
    StanzaNode x_node = new StanzaNode.build("x", "http://jabber.org/protocol/muc#user").add_self_xmlns();
    message_stanza.stanza.put_node(x_node);        
}

public class JoinResult {
    public MucEnterError? muc_error;
    public string? stanza_error;
    public string? nick;
    public bool newly_created = false;
}

private class PendingVoiceRequestSend : Object {
    public XmppStream stream { get; private set; }
    public Jid room_jid { get; private set; }
    public string stanza_id { get; private set; }
    public uint timeout_id { get; set; default = 0; }
    public bool local_write_completed { get; set; default = false; }

    public PendingVoiceRequestSend(XmppStream stream, Jid room_jid,
            string stanza_id) {
        this.stream = stream;
        this.room_jid = room_jid;
        this.stanza_id = stanza_id;
    }
}

private class PendingVoiceRequestResponse : Object {
    public XmppStream stream { get; private set; }
    public Jid room_jid { get; private set; }
    public string stanza_id { get; private set; }
    public string correlation_id { get; private set; }
    public uint timeout_id { get; set; default = 0; }

    public PendingVoiceRequestResponse(XmppStream stream, Jid room_jid,
            string stanza_id, string correlation_id) {
        this.stream = stream;
        this.room_jid = room_jid;
        this.stanza_id = stanza_id;
        this.correlation_id = correlation_id;
    }
}

private class PendingMediatedInvite : Object {
    public XmppStream stream { get; private set; }
    public Jid room_jid { get; private set; }
    public Jid invitee_jid { get; private set; }
    public string stanza_id { get; private set; }
    public uint timeout_id { get; set; default = 0; }

    public PendingMediatedInvite(XmppStream stream, Jid room_jid,
            Jid invitee_jid, string stanza_id) {
        this.stream = stream;
        this.room_jid = room_jid.bare_jid;
        this.invitee_jid = invitee_jid.bare_jid;
        this.stanza_id = stanza_id;
    }
}

public class Module : XmppStreamModule, Presence.ReceivedPresenceAdmission {
    public static ModuleIdentity<Module> IDENTITY = new ModuleIdentity<Module>(NS_URI, "0045_muc_module");

    public signal void received_occupant_affiliation(XmppStream stream, Jid jid, Affiliation? affiliation);
    // Confirmed persistent affiliation mutation. Unlike occupant presence,
    // this carries the room and the bare affiliation target separately so
    // offline member-list consumers cannot confuse the user's domain with the
    // MUC room.
    public signal void bare_affiliation_changed(XmppStream stream, Jid room_jid,
        Jid user_jid, Affiliation affiliation);
    public signal void received_occupant_jid(XmppStream stream, Jid jid, Jid? real_jid);
    public signal void received_occupant_role(XmppStream stream, Jid jid, Role? role);
    public signal void received_occupant_hats(XmppStream stream, Jid jid, Gee.List<Hat> hats);
    public signal void received_occupant_presence(XmppStream stream, OccupantPresenceEvent event);
    public signal void room_real_jid_visibility_revoked(XmppStream stream,
        Jid room_jid);
    public signal void room_real_jid_visibility_changed(XmppStream stream,
        Jid room_jid, RealJidVisibility visibility);
    public bool occupant_presence_events_enabled { get; set; default = false; }
    public signal void subject_set(XmppStream stream, string? subject, Jid jid);
    public signal void invite_received(XmppStream stream, Jid room_jid, Jid from_jid, string? password, string? reason);
    public signal void invite_received_with_context(XmppStream stream, Jid room_jid, Jid from_jid, string? password, string? reason, bool continue_thread, string? thread);
    public signal void invite_failed(XmppStream stream, Jid room_jid,
        Jid invitee_jid, string condition, string? text);
    public signal void voice_request_received(XmppStream stream, Jid room_jid,
        Jid from_jid, string nick, string? stanza_id);
    public signal void voice_request_sent(XmppStream stream, Jid room_jid,
        string correlation_id);
    public signal void voice_request_failed(XmppStream stream, Jid room_jid,
        string correlation_id, string condition, string? text);
    public signal void voice_request_response_failed(XmppStream stream,
        Jid room_jid, string correlation_id, string condition, string? text);
    public signal void voice_request_response_settled(XmppStream stream,
        Jid room_jid, string correlation_id);
    public signal void room_info_updated(XmppStream stream, Jid muc_jid);
    /** Complete XEP-0486 roominfo projection from the accepted generation. */
    public signal void room_avatar_info_received(XmppStream stream,
        Jid muc_jid, Xep.MucAvatars.RoomAvatarInfo info);
    /** Emitted once when the current room-info generation settles. */
    public signal void room_info_query_finished(XmppStream stream,
        Jid muc_jid, bool succeeded);
    public signal void room_info_query_started(XmppStream stream,
        Jid muc_jid);

    public signal void self_removed_from_room(XmppStream stream, Jid jid, StatusCode code, string? reason);
    public signal void room_destroyed(XmppStream stream, Jid room, string? reason);
    public signal void removed_from_room(XmppStream stream, Jid jid, StatusCode? code);

    private ReceivedPipelineListener received_pipeline_listener;
    private HashMap<string, PendingVoiceRequestSend> pending_voice_requests =
        new HashMap<string, PendingVoiceRequestSend>();
    private HashMap<string, PendingVoiceRequestResponse>
        pending_voice_responses =
            new HashMap<string, PendingVoiceRequestResponse>();
    private HashMap<string, PendingMediatedInvite> pending_mediated_invites =
        new HashMap<string, PendingMediatedInvite>();
    private uint voice_request_timeout_ms =
        VOICE_REQUEST_ERROR_WINDOW_SECONDS * 1000;
    public Module() {
        received_pipeline_listener = new ReceivedPipelineListener(this);
    }

    /** Test-only override for deterministic local-write timeout coverage. */
    public void set_voice_request_timeout_for_tests(uint timeout_ms) {
        voice_request_timeout_ms = timeout_ms > 0 ? timeout_ms : 1;
    }

    public async JoinResult? enter(XmppStream stream, Jid bare_jid, string nick, string? password, DateTime? history_since, bool receive_history, StanzaNode? additional_node) {
        try {
            Jid muc_jid = bare_jid.bare_jid;
            Flag flag = stream.get_flag(Flag.IDENTITY);
            if (flag.enter_futures.has_key(muc_jid)) {
                debug("MUC enter [%s]: already in progress, waiting for existing join", muc_jid.to_string());
                try {
                    return yield flag.enter_futures[muc_jid].future.wait_async();
                } catch (Gee.FutureError e) {
                    return null;
                }
            }

            Presence.Stanza presence = new Presence.Stanza();
            presence.to = muc_jid.with_resource(nick);

            var promise = new Promise<JoinResult?>();
            flag.enter_futures[muc_jid] = promise;

            StanzaNode x_node = new StanzaNode.build("x", NS_URI).add_self_xmlns();
            if (password != null) {
                x_node.put_node(new StanzaNode.build("password", NS_URI).put_node(new StanzaNode.text(password)));
            }
            if (history_since != null || !receive_history) {
                StanzaNode history_node = new StanzaNode.build("history", NS_URI);
                x_node.put_node(history_node);

                if (history_since != null) {
                    history_node.set_attribute("since", DateTimeProfiles.to_datetime(history_since));
                } else if (!receive_history) {
                    history_node.set_attribute("maxchars", "0");
                }
            }
            presence.stanza.put_node(x_node);

            if (additional_node != null) {
                presence.stanza.put_node(additional_node);
            }

            flag.start_muc_enter(muc_jid, presence.id, nick);

            query_room_info.begin(stream, muc_jid);
            stream.get_module<Presence.Module>(Presence.Module.IDENTITY).send_presence(stream, presence);

            uint timeout_id = 0;
            timeout_id = Timeout.add_seconds(ENTER_TIMEOUT_SECONDS, () => {
                if (flag.enter_futures.has_key(muc_jid) && flag.enter_futures[muc_jid] == promise) {
                    finish_enter_with_result(stream, flag, muc_jid,
                        new JoinResult() { stanza_error=ErrorStanza.CONDITION_REMOTE_SERVER_TIMEOUT });
                }
                timeout_id = 0;
                return false;
            });
            try {
                JoinResult? enter_result = yield promise.future.wait_async();
                if (timeout_id != 0) Source.remove(timeout_id);
                if (flag.enter_futures.has_key(muc_jid) && flag.enter_futures[muc_jid] == promise) {
                    flag.enter_futures.unset(muc_jid);
                }
                return enter_result;
            } catch (Gee.FutureError e) {
                if (timeout_id != 0) Source.remove(timeout_id);
                if (flag.enter_futures.has_key(muc_jid) && flag.enter_futures[muc_jid] == promise) {
                    flag.enter_futures.unset(muc_jid);
                    bool had_join = flag.get_muc_nick(muc_jid) != null;
                    if (!had_join) flag.mark_muc_enter_cancelled(muc_jid);
                    flag.finish_muc_enter(muc_jid);
                    if (!had_join) leave_room_state(stream, muc_jid, true);
                }
                return null;
            }
        } catch (InvalidJidError e) {
            return new JoinResult() { muc_error = MucEnterError.NICK_CONFLICT };
        }
    }

    /**
     * Ask an already joined service to replay its occupant presences as
     * described by XEP-0045 section 7.2.1. The reply is best-effort (SHOULD),
     * so existing state is never cleared and received presences are merged
     * through the normal parser and worker path.
     */
    public bool request_occupant_presence_resync(XmppStream stream,
            Jid room_jid) {
        Jid room = room_jid.bare_jid;
        Flag flag = stream.get_flag(Flag.IDENTITY);
        string? nick = flag.get_muc_nick(room);
        if (nick == null) return false;

        try {
            var presence = new Presence.Stanza();
            presence.to = room.with_resource((!) nick);
            var x_node = new StanzaNode.build("x", NS_URI).add_self_xmlns();
            var history_node = new StanzaNode.build("history", NS_URI);
            history_node.set_attribute("maxchars", "0");
            x_node.put_node(history_node);
            presence.stanza.put_node(x_node);
            stream.get_module<Presence.Module>(Presence.Module.IDENTITY)
                .send_presence(stream, presence);
            return true;
        } catch (InvalidJidError error) {
            return false;
        }
    }

    /**
     * Apply a whois value which was read back from the authoritative owner
     * form.  Disco normally performs the same transition first; in that case
     * this is a no-op.  The fallback closes the privacy/live-refresh gap when
     * the owner form succeeded but the following disco refresh failed.
     *
     * Returns true only when the transition expands JID visibility and an
     * occupant-presence replay is still needed.
     */
    public bool apply_confirmed_room_whois(XmppStream stream, Jid room_jid,
            string[] values) {
        if (values.length != 1) return false;

        RealJidVisibility visibility;
        switch (values[0].strip().down()) {
            case "anyone":
                visibility = RealJidVisibility.ANYONE;
                break;
            case "moderators":
                visibility = RealJidVisibility.MODERATORS;
                break;
            case "none":
                visibility = RealJidVisibility.NOBODY;
                break;
            default:
                // Do not invent privacy semantics for server extensions.
                return false;
        }

        Jid room = room_jid.bare_jid;
        Flag flag = stream.get_flag(Flag.IDENTITY);
        RealJidVisibility previous = flag.get_real_jid_visibility(room);
        if (previous == visibility) return false;
        set_room_real_jid_visibility(stream, room, visibility);

        switch (visibility) {
            case RealJidVisibility.NOBODY:
                clear_room_real_jids_after_privacy_change(stream, room,
                    StatusCode.FULLY_ANONYMOUS);
                return false;
            case RealJidVisibility.MODERATORS:
                if (!own_occupant_is_moderator(flag, room)) {
                    clear_room_real_jids_after_privacy_change(stream, room,
                        StatusCode.SEMI_ANONYMOUS);
                    return false;
                }
                return previous == RealJidVisibility.NOBODY ||
                    previous == RealJidVisibility.UNKNOWN;
            case RealJidVisibility.ANYONE:
                return true;
            case RealJidVisibility.UNKNOWN:
            default:
                return false;
        }
    }

    /**
     * Apply a successfully verified presence-broadcast restriction locally.
     * XEP-0045 changes the set of whole occupant presences a client may see;
     * services do not necessarily send unavailable stanzas for occupants which
     * became hidden. Remove only occupants whose already known role is now
     * excluded. Unknown roles and the client's own occupant stay untouched.
     */
    public int apply_confirmed_presence_broadcast_roles(XmppStream stream,
            Jid room_jid, string[] role_values) {
        Jid room = room_jid.bare_jid;
        Flag flag = stream.get_flag(Flag.IDENTITY);
        string? own_nick = flag.get_muc_nick(room);
        if (own_nick == null) return 0;

        var visible_roles = new HashSet<Role>();
        foreach (string role_value in role_values) {
            switch (role_value) {
                case "moderator":
                    visible_roles.add(Role.MODERATOR);
                    break;
                case "participant":
                    visible_roles.add(Role.PARTICIPANT);
                    break;
                case "visitor":
                    visible_roles.add(Role.VISITOR);
                    break;
            }
        }

        try {
            Jid own_occupant = room.with_resource((!) own_nick);
            Presence.Flag presence_flag = stream.get_flag(
                Presence.Flag.IDENTITY);
            Gee.List<Jid>? occupants = presence_flag.get_resources(room);
            if (occupants == null) return 0;

            int removed = 0;
            foreach (Jid occupant in (!) occupants) {
                if (occupant.equals(own_occupant) ||
                        !flag.has_occupant_role(occupant)) continue;
                Role? role = flag.get_occupant_role(occupant);
                if (role == null || visible_roles.contains((!) role)) continue;

                if (occupant_presence_events_enabled) {
                    received_occupant_presence(stream,
                        new OccupantPresenceEvent(
                            OccupantPresenceKind.UNAVAILABLE,
                            occupant.to_string(), room.to_string(),
                            occupant.resourcepart, null, Affiliation.NONE,
                            false, (!) role, true, new string[0],
                            new string[0], null, new int[0], false,
                            GLib.get_monotonic_time()));
                }
                presence_flag.remove_presence(occupant);
                flag.remove_occupant_info(occupant);
                removed++;
            }
            return removed;
        } catch (InvalidJidError error) {
            return 0;
        }
    }

    /** Clear assigned Hat projections after a verified enable_hats=false. */
    public int clear_confirmed_room_hats(XmppStream stream, Jid room_jid) {
        Jid room = room_jid.bare_jid;
        Flag flag = stream.get_flag(Flag.IDENTITY);
        Presence.Flag presence_flag = stream.get_flag(Presence.Flag.IDENTITY);
        Gee.List<Jid>? occupants = presence_flag.get_resources(room);
        if (occupants == null) return 0;

        int cleared = 0;
        foreach (Jid occupant in (!) occupants) {
            Gee.List<Hat> old_hats = flag.get_occupant_hats(occupant);
            if (old_hats.is_empty) continue;

            var no_hats = new ArrayList<Hat>();
            flag.set_occupant_hats(occupant, no_hats);
            received_occupant_hats(stream, occupant, no_hats);
            if (occupant_presence_events_enabled) {
                Jid? real_jid = flag.get_real_jid(occupant);
                bool affiliation_known = flag.has_affiliation(room, occupant);
                bool role_known = flag.has_occupant_role(occupant);
                Role? role = flag.get_occupant_role(occupant);
                received_occupant_presence(stream, new OccupantPresenceEvent(
                    OccupantPresenceKind.AVAILABLE, occupant.to_string(),
                    room.to_string(), occupant.resourcepart,
                    real_jid != null ? ((!) real_jid).bare_jid.to_string() : null,
                    flag.get_affiliation(room, occupant), affiliation_known,
                    role ?? Role.NONE, role_known, new string[0],
                    new string[0], null, new int[0], false,
                    GLib.get_monotonic_time(), real_jid != null));
            }
            cleared++;
        }
        return cleared;
    }

    public void exit(XmppStream stream, Jid jid, string? nick_override = null) {
        try {
            Flag flag = stream.get_flag(Flag.IDENTITY);
            string? nick = nick_override ?? flag.get_muc_nick(jid) ?? flag.get_enter_nick(jid);
            if (nick == null) {
                cancel_enter(stream, jid, false);
                return;
            }
            Presence.Stanza presence = new Presence.Stanza();
            presence.to = jid.with_resource(nick);
            presence.type_ = Presence.Stanza.TYPE_UNAVAILABLE;
            stream.get_module<Presence.Module>(Presence.Module.IDENTITY).send_presence(stream, presence);
            leave_room_state(stream, jid.bare_jid);
            cancel_enter(stream, jid, false);
        } catch (InvalidJidError e) {
            warning("Tried to leave room with invalid nick: %s", e.message);
        }
    }

    public void cancel_enter(XmppStream stream, Jid jid, bool send_unavailable = true) {
        try {
            Jid bare_jid = jid.bare_jid;
            Flag flag = stream.get_flag(Flag.IDENTITY);
            string? enter_nick = flag.get_enter_nick(bare_jid);
            flag.mark_muc_enter_cancelled(bare_jid);
            if (send_unavailable && enter_nick != null) {
                Presence.Stanza presence = new Presence.Stanza();
                presence.to = bare_jid.with_resource((!) enter_nick);
                presence.type_ = Presence.Stanza.TYPE_UNAVAILABLE;
                stream.get_module<Presence.Module>(Presence.Module.IDENTITY).send_presence(stream, presence);
            }
            finish_enter_with_result(stream, flag, bare_jid,
                new JoinResult() { stanza_error=ErrorStanza.CONDITION_REMOTE_SERVER_TIMEOUT });
        } catch (InvalidJidError e) {
            warning("Tried to cancel MUC enter with invalid nick: %s", e.message);
        }
    }

    public void change_subject(XmppStream stream, Jid jid, string subject) {
        MessageStanza message = new MessageStanza();
        message.to = jid;
        message.type_ = MessageStanza.TYPE_GROUPCHAT;
        message.stanza.put_node((new StanzaNode.build("subject")).put_node(new StanzaNode.text(subject)));
        stream.get_module<MessageModule>(MessageModule.IDENTITY).send_message.begin(stream, message);
    }

    public void change_nick(XmppStream stream, Jid jid, string new_nick) {
        // TODO: Return if successful
        try {
            Presence.Stanza presence = new Presence.Stanza();
            presence.to = jid.with_resource(new_nick);
            stream.get_module<Presence.Module>(Presence.Module.IDENTITY).send_presence(stream, presence);
        } catch (InvalidJidError e) {
            warning("Tried to change nick to invalid nick: %s", e.message);
        }
    }

    public async void invite(XmppStream stream, Jid to_muc, Jid jid, string? reason = null, bool continue_thread = false, string? thread = null) throws IOError {
        Jid room_jid = to_muc.bare_jid;
        Jid invitee_jid = jid.bare_jid;
        MessageStanza message = new MessageStanza() { to=room_jid };
        StanzaNode invite_payload = new StanzaNode.build("invite", NS_URI_USER).put_attribute("to", invitee_jid.to_string());
        if (reason != null && reason.strip() != "") {
            invite_payload.put_node(new StanzaNode.build("reason", NS_URI_USER).put_node(new StanzaNode.text(reason)));
        }
        if (continue_thread || (thread != null && thread.strip() != "")) {
            StanzaNode continue_node = new StanzaNode.build("continue", NS_URI_USER);
            if (thread != null && thread.strip() != "") {
                continue_node.put_attribute("thread", thread);
            }
            invite_payload.put_node(continue_node);
        }
        StanzaNode invite_node = new StanzaNode.build("x", NS_URI_USER).add_self_xmlns()
            .put_node(invite_payload);
        message.stanza.put_node(invite_node);

        string stanza_id = (!) message.id;
        var pending = new PendingMediatedInvite(stream, room_jid,
            invitee_jid, stanza_id);
        pending_mediated_invites[stanza_id] = pending;
        pending.timeout_id = Timeout.add_seconds(
            MEDIATED_INVITE_ERROR_WINDOW_SECONDS, () => {
                pending.timeout_id = 0;
                remove_pending_mediated_invite(pending);
                return Source.REMOVE;
            });
        try {
            yield stream.get_module<MessageModule>(MessageModule.IDENTITY)
                .send_message(stream, message);
        } catch (IOError e) {
            remove_pending_mediated_invite(pending);
            throw e;
        }
    }

    public void decline_invite(XmppStream stream, Jid room_jid, Jid inviter_jid, string? reason = null) {
        MessageStanza message = new MessageStanza();
        message.to = room_jid.bare_jid;
        StanzaNode decline_payload = new StanzaNode.build("decline", NS_URI_USER).put_attribute("to", inviter_jid.to_string());
        if (reason != null && reason.strip() != "") {
            decline_payload.put_node(new StanzaNode.build("reason", NS_URI_USER).put_node(new StanzaNode.text(reason)));
        }
        StanzaNode decline_node = new StanzaNode.build("x", NS_URI_USER).add_self_xmlns().put_node(decline_payload);
        message.stanza.put_node(decline_node);
        stream.get_module<MessageModule>(MessageModule.IDENTITY).send_message.begin(stream, message);
    }

    public string request_voice(XmppStream stream, Jid to_muc,
            string? correlation_id = null) {
        Jid room_jid = to_muc.bare_jid;
        MessageStanza message = new MessageStanza(correlation_id) {
            to=room_jid
        };

        DataForms.DataForm submit_node = new DataForms.DataForm();
        submit_node.get_submit_node();

        DataForms.DataForm.HiddenField field_node =
            new DataForms.DataForm.HiddenField() { var="FORM_TYPE" };
        field_node.set_value_string(NS_URI_REQUEST);

        DataForms.DataForm.Field role_field =
            new DataForms.DataForm.Field() { var="muc#role" };
        role_field.set_value_string("participant");

        submit_node.add_field(field_node);
        submit_node.add_field(role_field);

        message.stanza.put_node(submit_node.stanza_node);

        string stanza_id = (!) message.id;
        var pending = new PendingVoiceRequestSend(stream, room_jid,
            stanza_id);
        pending_voice_requests[stanza_id] = pending;
        arm_pending_voice_request_timeout(pending);

        MessageModule message_module = stream.get_module<MessageModule>(
            MessageModule.IDENTITY);
        message_module.send_message.begin(stream, message, (_, res) => {
            try {
                message_module.send_message.end(res);
                if (mark_pending_voice_request_write_completed(pending)) {
                    voice_request_sent(pending.stream, pending.room_jid,
                        pending.stanza_id);
                }
            } catch (IOError e) {
                fail_pending_voice_request(pending, "send-failed",
                    e.message);
            }
        });
        return stanza_id;
    }

    /** Submit the exact XEP-0045 voice-approval form selected by a moderator. */
    public async void respond_to_voice_request(XmppStream stream,
            Jid room_jid, Jid requester_jid, string nick, bool allow,
            string correlation_id) throws IOError {
        Jid room = room_jid.bare_jid;
        MessageStanza message = new MessageStanza() { to=room };
        var form = new StanzaNode.build("x", DataForms.NS_URI)
            .add_self_xmlns().put_attribute("type", "submit")
            .put_node(build_voice_form_field("FORM_TYPE", NS_URI_REQUEST,
                "hidden"))
            .put_node(build_voice_form_field("muc#role", "participant"))
            .put_node(build_voice_form_field("muc#jid",
                requester_jid.to_string()))
            .put_node(build_voice_form_field("muc#roomnick", nick))
            .put_node(build_voice_form_field("muc#request_allow",
                allow ? "true" : "false"));
        message.stanza.put_node(form);

        string stanza_id = (!) message.id;
        var pending = new PendingVoiceRequestResponse(stream, room,
            stanza_id, correlation_id);
        pending_voice_responses[stanza_id] = pending;
        pending.timeout_id = Timeout.add_seconds(
            VOICE_REQUEST_ERROR_WINDOW_SECONDS, () => {
                pending.timeout_id = 0;
                if (remove_pending_voice_response(pending)) {
                    voice_request_response_settled(pending.stream,
                        pending.room_jid, pending.correlation_id);
                }
                return false;
            });
        try {
            yield stream.get_module<MessageModule>(MessageModule.IDENTITY)
                .send_message(stream, message);
        } catch (IOError e) {
            remove_pending_voice_response(pending);
            throw e;
        }
    }

    private static StanzaNode build_voice_form_field(string var_,
            string value, string? type = null) {
        var field = new StanzaNode.build("field", DataForms.NS_URI)
            .put_attribute("var", var_)
            .put_node(new StanzaNode.build("value", DataForms.NS_URI)
                .put_node(new StanzaNode.text(value)));
        if (type != null) field.put_attribute("type", (!) type);
        return field;
    }

    public void kick(XmppStream stream, Jid jid, string nick, string? reason = null) {
        change_role.begin(stream, jid, nick, "none", reason, (_, res) => {
            try {
                change_role.end(res);
            } catch (GLib.Error e) {
                warning("Failed to kick occupant: %s", e.message);
            }
        });
    }

    /* XEP 0046: "A user cannot be kicked by a moderator with a lower affiliation." (XEP 0045 8.2) */
    public bool kick_possible(XmppStream stream, Jid occupant) {
        try {
            Jid muc_jid = occupant.bare_jid;
            Flag flag = stream.get_flag(Flag.IDENTITY);
            string own_nick = flag.get_muc_nick(muc_jid);
            Affiliation my_affiliation = flag.get_affiliation(muc_jid, muc_jid.with_resource(own_nick));
            Affiliation other_affiliation = flag.get_affiliation(muc_jid, occupant);
            switch (my_affiliation) {
                case Affiliation.MEMBER:
                    if (other_affiliation == Affiliation.ADMIN || other_affiliation == Affiliation.OWNER) return false;
                    break;
                case Affiliation.ADMIN:
                    if (other_affiliation == Affiliation.OWNER) return false;
                    break;
                case Affiliation.OWNER:
                    return true;
                default:
                    return false;
            }
            return true;
        } catch (InvalidJidError e) {
            warning("Tried to kick with invalid nick: %s", e.message);
            return false;
        }
    }

    public async void change_role(XmppStream stream, Jid jid, string nick, string new_role, string? reason = null) throws GLib.Error {
        StanzaNode query = new StanzaNode.build("query", NS_URI_ADMIN).add_self_xmlns();
        StanzaNode item = new StanzaNode.build("item", NS_URI_ADMIN).put_attribute("nick", nick, NS_URI_ADMIN).put_attribute("role", new_role, NS_URI_ADMIN);
        if (reason != null) {
            item.put_node(new StanzaNode.build("reason", NS_URI_ADMIN).put_node(new StanzaNode.text(reason)));
        }
        query.put_node(item);
        Iq.Stanza iq = new Iq.Stanza.set(query) { to=jid };
        Iq.Stanza result = yield stream.get_module<Iq.Module>(Iq.Module.IDENTITY).send_iq_async(stream, iq);
        throw_if_unexpected_iq_sender(result, jid, "change occupant role");
        throw_if_iq_error(result, "change occupant role");
    }

    public async void change_affiliation(XmppStream stream, Jid muc_jid, Jid? user_jid, string? nick, string new_affiliation, string? reason = null) throws GLib.Error {
        StanzaNode item_node = new StanzaNode.build("item", NS_URI_ADMIN)
                .put_attribute("affiliation", new_affiliation, NS_URI_ADMIN);
        if (user_jid != null) {
            // Some servers don't allow full JIDs and reply error:modify - jid-malformed - "Bare JID expected, got full JID". Make them bare JIDs.
            item_node.put_attribute("jid", user_jid.bare_jid.to_string(), NS_URI_ADMIN);
        }
        if (nick != null) item_node.put_attribute("nick", nick, NS_URI_ADMIN);
        if (reason != null) item_node.put_node(new StanzaNode.build("reason", NS_URI_ADMIN).put_node(new StanzaNode.text(reason)));

        StanzaNode query = new StanzaNode.build("query", NS_URI_ADMIN).add_self_xmlns().put_node(item_node);
        Iq.Stanza iq = new Iq.Stanza.set(query) { to=muc_jid };
        Iq.Stanza result = yield stream.get_module<Iq.Module>(Iq.Module.IDENTITY).send_iq_async(stream, iq);
        throw_if_unexpected_iq_sender(result, muc_jid,
            "change occupant affiliation");
        throw_if_iq_error(result, "change occupant affiliation");

        if (user_jid != null) {
            Flag flag = stream.get_flag(Flag.IDENTITY);
            Jid room = muc_jid.bare_jid;
            Jid target = ((!) user_jid).bare_jid;
            Affiliation affiliation = parse_affiliation(new_affiliation);
            flag.set_offline_member(room, target, affiliation);

            // Keep a currently present room/nick projection in sync as well.
            // The subsequent server presence remains authoritative, but the
            // successful IQ already authorizes this cache transition.
            Jid? live_occupant = flag.get_occupant_jid(target, room);
            if (live_occupant != null) {
                flag.set_affiliation(room, (!) live_occupant, affiliation);
            }
            bare_affiliation_changed(stream, room, target, affiliation);
        }
    }

    public async DataForms.DataForm? get_config_form(XmppStream stream, Jid jid) {
        Iq.Stanza get_iq = new Iq.Stanza.get(new StanzaNode.build("query", NS_URI_OWNER).add_self_xmlns()) { to=jid };
        try {
            Iq.Stanza result_iq = yield stream.get_module<Iq.Module>(Iq.Module.IDENTITY).send_iq_async(stream, get_iq);
            throw_if_unexpected_iq_sender(result_iq, jid,
                "load room configuration");
            throw_if_iq_error(result_iq, "load room configuration");

            StanzaNode? query_node = result_iq.stanza.get_subnode("query", NS_URI_OWNER);
            if (query_node != null) {
                StanzaNode? x_node = query_node.get_subnode("x", DataForms.NS_URI);
                if (x_node != null) {
                    DataForms.DataForm data_form = DataForms.DataForm.create_from_node(x_node);
                    return data_form;
                }
            }
        } catch (GLib.Error e) {
            warning("Failed to get config form: %s", e.message);
        }
        return null;
    }

    public async bool set_config_form(XmppStream stream, Jid jid, DataForms.DataForm data_form) {
        StanzaNode stanza_node = new StanzaNode.build("query", NS_URI_OWNER);
        // XEP-0004 incomplete submissions preserve omitted optional values.
        // Send only hidden/required/changed values so an unrelated edit cannot
        // overwrite concurrent room changes or retrigger expensive safeguards.
        stanza_node.add_self_xmlns().put_node(data_form.get_delta_submit_node());
        Iq.Stanza set_iq = new Iq.Stanza.set(stanza_node) { to=jid };
        try {
            Iq.Stanza result = yield stream.get_module<Iq.Module>(Iq.Module.IDENTITY).send_iq_async(stream, set_iq);
            throw_if_unexpected_iq_sender(result, jid,
                "save room configuration");
            throw_if_iq_error(result, "save room configuration");
            return true;
        } catch (GLib.Error e) {
            warning("Failed to set config form: %s", e.message);
            return false;
        }
    }

    public override void attach(XmppStream stream) {
        stream.add_flag(new Flag());
        stream.get_module<MessageModule>(MessageModule.IDENTITY).received_message.connect(on_received_message);
        stream.get_module<MessageModule>(MessageModule.IDENTITY).received_error.connect(on_received_message_error);
        stream.get_module<MessageModule>(MessageModule.IDENTITY).received_pipeline.connect(received_pipeline_listener);
        Presence.Module presence_module = stream.get_module<Presence.Module>(
            Presence.Module.IDENTITY);
        presence_module.add_received_presence_admission(this);
        presence_module.received_available.connect(on_received_available);
        presence_module.received_presence.connect(check_for_enter_error);
        presence_module.received_unavailable.connect(on_received_unavailable);
        stream.get_module<ServiceDiscovery.Module>(ServiceDiscovery.Module.IDENTITY).add_feature(stream, NS_URI);
    }

    public override void detach(XmppStream stream) {
        Flag? flag = stream.get_flag(Flag.IDENTITY);
        if (flag != null) {
            ((!) flag).cancel_all_pending_member_affiliation_snapshots();
            fail_outstanding_enters(stream, (!) flag,
                ErrorStanza.CONDITION_REMOTE_SERVER_TIMEOUT);
        }

        stream.get_module<MessageModule>(MessageModule.IDENTITY).received_message.disconnect(on_received_message);
        stream.get_module<MessageModule>(MessageModule.IDENTITY).received_error.disconnect(on_received_message_error);
        stream.get_module<MessageModule>(MessageModule.IDENTITY).received_pipeline.disconnect(received_pipeline_listener);
        Presence.Module presence_module = stream.get_module<Presence.Module>(
            Presence.Module.IDENTITY);
        presence_module.remove_received_presence_admission(this);
        presence_module.received_available.disconnect(on_received_available);
        presence_module.received_presence.disconnect(check_for_enter_error);
        presence_module.received_unavailable.disconnect(on_received_unavailable);
        stream.get_module<ServiceDiscovery.Module>(ServiceDiscovery.Module.IDENTITY).remove_feature(stream, NS_URI);

        clear_pending_message_operations(stream, null, false);
    }

    public override string get_ns() { return NS_URI; }
    public override string get_id() { return IDENTITY.id; }

    private void on_received_message(XmppStream stream, MessageStanza message) {
        if (message.type_ == MessageStanza.TYPE_GROUPCHAT) {
            StanzaNode? subject_node = message.stanza.get_subnode("subject");
            if (subject_node != null && message.body == null){ 
                string subject = subject_node.get_string_content();
                stream.get_flag(Flag.IDENTITY).set_muc_subject(message.from, subject);
                subject_set(stream, subject, message.from);
            }

            StanzaNode? x_node = message.stanza.get_subnode("x", NS_URI_USER);
            Flag flag = stream.get_flag(Flag.IDENTITY);
            // XEP-0045 room-configuration notifications originate from the
            // bare room JID. A full room/nick sender is an occupant message
            // and must not be allowed to spoof privacy transitions.
            if (x_node != null && message.from.is_bare() &&
                    flag.is_occupant(message.from) &&
                    !is_replayed_muc_status_message(message)) {
                Gee.List<int> status_codes = get_status_codes(x_node);
                if (!status_codes.is_empty) {
                    bool occupant_replay_requested = false;
                    if (status_codes.contains(StatusCode.FULLY_ANONYMOUS)) {
                        set_room_real_jid_visibility(stream, message.from,
                            RealJidVisibility.NOBODY);
                        clear_room_real_jids_after_privacy_change(stream,
                            message.from, StatusCode.FULLY_ANONYMOUS);
                    } else if (status_codes.contains(
                            StatusCode.SEMI_ANONYMOUS)) {
                        RealJidVisibility previous_visibility =
                            flag.get_real_jid_visibility(message.from);
                        set_room_real_jid_visibility(stream, message.from,
                            RealJidVisibility.MODERATORS);
                        if (!own_occupant_is_moderator(flag, message.from)) {
                            clear_room_real_jids_after_privacy_change(stream,
                                message.from, StatusCode.SEMI_ANONYMOUS);
                        } else if (previous_visibility ==
                                    RealJidVisibility.NOBODY ||
                                previous_visibility ==
                                    RealJidVisibility.UNKNOWN) {
                            occupant_replay_requested =
                                request_occupant_presence_resync(stream,
                                    message.from);
                        }
                    } else if (status_codes.contains(
                            StatusCode.NON_ANONYMOUS)) {
                        RealJidVisibility previous_visibility =
                            flag.get_real_jid_visibility(message.from);
                        set_room_real_jid_visibility(stream, message.from,
                            RealJidVisibility.ANYONE);
                        if (previous_visibility !=
                                RealJidVisibility.ANYONE) {
                            occupant_replay_requested =
                                request_occupant_presence_resync(stream,
                                    message.from);
                        }
                    } else if (status_codes.contains(
                            StatusCode.JID_VISIBLE) &&
                            flag.get_enter_id(message.from) != null) {
                        // XEP-0045 registers status 100 for message and
                        // presence, but the message form is an enter-time
                        // disclosure to the joining occupant. Historical or
                        // post-join messages must not change live privacy.
                        set_room_real_jid_visibility(stream, message.from,
                            RealJidVisibility.ANYONE);
                    }
                    if ((status_codes.contains(
                                StatusCode.CONFIG_CHANGE_NON_PRIVACY) ||
                            status_codes.contains(
                                StatusCode.SHOWS_UNAVIABLE_MEMBERS)) &&
                            !occupant_replay_requested) {
                        // Status 104 does not identify the changed field. A
                        // single merge-only replay is the only standard way
                        // for a non-owner client to pick up Hats and expanded
                        // occupant-presence projections. Status 102 is itself
                        // an expansion. Never infer removals from absence.
                        occupant_replay_requested =
                            request_occupant_presence_resync(stream,
                                message.from);
                    }
                    if (status_codes.contains(StatusCode.CONFIG_CHANGE_NON_PRIVACY) ||
                            status_codes.contains(StatusCode.LOGGING_ENABLED) ||
                            status_codes.contains(StatusCode.LOGGING_DISABLED) ||
                            status_codes.contains(StatusCode.NON_ANONYMOUS) ||
                            status_codes.contains(StatusCode.SEMI_ANONYMOUS) ||
                            status_codes.contains(StatusCode.FULLY_ANONYMOUS)) {
                        query_room_info.begin(stream, message.from.bare_jid);
                    }
                }
            }
        }
    }

    private bool is_replayed_muc_status_message(MessageStanza message) {
        if (MessageArchiveManagement.MessageFlag.get_flag(message) != null ||
                Xmpp.Xep.DelayedDelivery.MessageFlag.get_flag(message) !=
                    null) {
            return true;
        }
        // Keep this fail-safe independent of module attachment/order. A
        // direct XEP-0203 marker is enough to make a state-changing room
        // status historical rather than live authority.
        return message.stanza.get_subnode("delay",
            Xmpp.Xep.DelayedDelivery.NS_URI) != null;
    }

    private void on_received_message_error(XmppStream stream,
            MessageStanza message, ErrorStanza error) {
        string? stanza_id = message.id;
        Jid? sender = message.from;
        if (stanza_id == null || sender == null || !sender.is_bare()) return;

        PendingMediatedInvite? invite =
            pending_mediated_invites[(!) stanza_id];
        if (invite != null && ((!) invite).stream == stream &&
                sender.equals(((!) invite).room_jid)) {
            if (remove_pending_mediated_invite((!) invite)) {
                invite_failed(stream, ((!) invite).room_jid,
                    ((!) invite).invitee_jid, error.condition, error.text);
            }
            return;
        }

        PendingVoiceRequestSend? pending =
            pending_voice_requests[(!) stanza_id];
        if (pending != null && ((!) pending).stream == stream &&
                sender.equals(((!) pending).room_jid)) {
            fail_pending_voice_request((!) pending, error.condition,
                error.text);
            return;
        }

        PendingVoiceRequestResponse? response =
            pending_voice_responses[(!) stanza_id];
        if (response == null || ((!) response).stream != stream ||
                !sender.equals(((!) response).room_jid)) return;
        remove_pending_voice_response((!) response);
        voice_request_response_failed(stream, ((!) response).room_jid,
            ((!) response).correlation_id, error.condition, error.text);
    }

    private void fail_pending_voice_request(PendingVoiceRequestSend pending,
            string condition, string? text) {
        if (!remove_pending_voice_request(pending)) return;
        voice_request_failed(pending.stream, pending.room_jid,
            pending.stanza_id, condition, text);
    }

    private void on_pending_voice_request_timeout(
            PendingVoiceRequestSend pending) {
        if (pending.local_write_completed) {
            remove_pending_voice_request(pending);
            return;
        }
        fail_pending_voice_request(pending, "send-failed", null);
    }

    private bool mark_pending_voice_request_write_completed(
            PendingVoiceRequestSend pending) {
        PendingVoiceRequestSend? current =
            pending_voice_requests[pending.stanza_id];
        if (current == null || (!) current != pending) return false;
        pending.local_write_completed = true;
        // The first window bounds the local write. A successful write starts
        // a fresh, full window in which a correlated stanza error may arrive.
        arm_pending_voice_request_timeout(pending);
        return true;
    }

    private void arm_pending_voice_request_timeout(
            PendingVoiceRequestSend pending) {
        if (pending.timeout_id != 0) {
            Source.remove(pending.timeout_id);
            pending.timeout_id = 0;
        }
        pending.timeout_id = Timeout.add(voice_request_timeout_ms, () => {
            pending.timeout_id = 0;
            on_pending_voice_request_timeout(pending);
            return Source.REMOVE;
        });
    }

    private bool remove_pending_voice_request(
            PendingVoiceRequestSend pending) {
        PendingVoiceRequestSend? current =
            pending_voice_requests[pending.stanza_id];
        if (current == null || (!) current != pending) return false;
        pending_voice_requests.unset(pending.stanza_id);
        if (pending.timeout_id != 0) {
            Source.remove(pending.timeout_id);
            pending.timeout_id = 0;
        }
        return true;
    }

    private bool remove_pending_voice_response(
            PendingVoiceRequestResponse pending) {
        PendingVoiceRequestResponse? current =
            pending_voice_responses[pending.stanza_id];
        if (current == null || (!) current != pending) return false;
        pending_voice_responses.unset(pending.stanza_id);
        if (pending.timeout_id != 0) {
            Source.remove(pending.timeout_id);
            pending.timeout_id = 0;
        }
        return true;
    }

    private bool remove_pending_mediated_invite(
            PendingMediatedInvite pending) {
        PendingMediatedInvite? current =
            pending_mediated_invites[pending.stanza_id];
        if (current == null || (!) current != pending) return false;
        pending_mediated_invites.unset(pending.stanza_id);
        if (pending.timeout_id != 0) {
            Source.remove(pending.timeout_id);
            pending.timeout_id = 0;
        }
        return true;
    }

    private bool set_room_real_jid_visibility(XmppStream stream, Jid room,
            RealJidVisibility visibility) {
        Flag flag = stream.get_flag(Flag.IDENTITY);
        Jid bare = room.bare_jid;
        RealJidVisibility previous = flag.get_real_jid_visibility(bare);
        if (previous == visibility) return false;
        flag.set_real_jid_visibility(bare, visibility);
        room_real_jid_visibility_changed(stream, bare, visibility);
        return true;
    }

    private void clear_pending_message_operations(XmppStream stream,
            Jid? room, bool settle_responses) {
        Jid? bare = room != null ? ((!) room).bare_jid : null;
        var requests = new ArrayList<PendingVoiceRequestSend>();
        foreach (PendingVoiceRequestSend pending in
                pending_voice_requests.values) {
            if (pending.stream == stream && (bare == null ||
                    pending.room_jid.equals((!) bare))) {
                requests.add(pending);
            }
        }
        foreach (PendingVoiceRequestSend pending in requests) {
            remove_pending_voice_request(pending);
        }

        var responses = new ArrayList<PendingVoiceRequestResponse>();
        foreach (PendingVoiceRequestResponse pending in
                pending_voice_responses.values) {
            if (pending.stream == stream && (bare == null ||
                    pending.room_jid.equals((!) bare))) {
                responses.add(pending);
            }
        }
        foreach (PendingVoiceRequestResponse pending in responses) {
            if (remove_pending_voice_response(pending)) {
                if (settle_responses) {
                    voice_request_response_settled(pending.stream,
                        pending.room_jid, pending.correlation_id);
                }
            }
        }

        var invites = new ArrayList<PendingMediatedInvite>();
        foreach (PendingMediatedInvite pending in
                pending_mediated_invites.values) {
            if (pending.stream == stream && (bare == null ||
                    pending.room_jid.equals((!) bare))) {
                invites.add(pending);
            }
        }
        foreach (PendingMediatedInvite pending in invites) {
            remove_pending_mediated_invite(pending);
        }
    }

    private void leave_room_state(XmppStream stream, Jid room,
            bool preserve_cancelled_enter = false) {
        Flag flag = stream.get_flag(Flag.IDENTITY);
        Jid bare = room.bare_jid;
        RealJidVisibility previous = flag.get_real_jid_visibility(bare);
        clear_pending_message_operations(stream, bare, true);
        // A local room exit is authoritative even when the service does not
        // replay one unavailable stanza per remote occupant. Detach only this
        // room's raw presence projection; contacts and other rooms remain live.
        stream.get_flag<Presence.Flag>(Presence.Flag.IDENTITY)
            .remove_bare_presences_deferred(bare);
        flag.left_muc(stream, bare, preserve_cancelled_enter);
        if (previous != RealJidVisibility.UNKNOWN) {
            room_real_jid_visibility_changed(stream, bare,
                RealJidVisibility.UNKNOWN);
        }
    }

    /**
     * A restrictive room-privacy transition revokes disclosed real occupant
     * JIDs immediately. Do not wait for a later presence refresh: cached real
     * JIDs are privacy-sensitive state and must disappear at the configuration
     * boundary itself.
     */
    private void clear_room_real_jids_after_privacy_change(XmppStream stream,
            Jid room, StatusCode privacy_status,
            bool include_status_code = true) {
        Flag flag = stream.get_flag(Flag.IDENTITY);
        Gee.List<Jid> affected = flag.clear_room_real_jids(room);
        flag.clear_room_disclosed_bare_jids(room);
        room_real_jid_visibility_revoked(stream, room.bare_jid);
        foreach (Jid occupant in affected) {
            received_occupant_jid(stream, occupant, null);
            if (!occupant_presence_events_enabled) continue;

            int[] status_codes = include_status_code
                ? new int[] { (int) privacy_status }
                : new int[0];
            received_occupant_presence(stream, new OccupantPresenceEvent(
                OccupantPresenceKind.CONTROL, occupant.to_string(),
                room.bare_jid.to_string(), occupant.resourcepart, null,
                Affiliation.NONE, false, Role.NONE, false, null, null, null,
                status_codes, false, GLib.get_monotonic_time(), true));
        }
    }

    private bool own_occupant_is_moderator(Flag flag, Jid room) {
        string? own_nick = flag.get_muc_nick(room);
        if (own_nick == null) return false;
        try {
            Jid own_occupant = room.bare_jid.with_resource((!) own_nick);
            return flag.has_occupant_role(own_occupant) &&
                flag.get_occupant_role(own_occupant) == Role.MODERATOR;
        } catch (InvalidJidError e) {
            return false;
        }
    }

    /**
     * Presence item@jid is authoritative while room privacy is still unknown:
     * the service deliberately sent that value to this occupant. Once an
     * explicit NOBODY or semi-anonymous/non-moderator boundary is known,
     * however, a delayed or buggy presence must not repopulate revoked data.
     * An as-yet unknown own role is accepted provisionally and is reconciled by
     * the self-presence role boundary below.
     */
    private bool current_role_forbids_real_jids(Flag flag, Jid room) {
        RealJidVisibility visibility = flag.get_real_jid_visibility(room);
        if (visibility == RealJidVisibility.NOBODY) return true;
        if (visibility != RealJidVisibility.MODERATORS) return false;

        string? own_nick = flag.get_muc_nick(room);
        if (own_nick == null) return false;
        try {
            Jid own_occupant = room.bare_jid.with_resource((!) own_nick);
            return flag.has_occupant_role(own_occupant) &&
                flag.get_occupant_role(own_occupant) != Role.MODERATOR;
        } catch (InvalidJidError e) {
            return true;
        }
    }

    private void check_for_enter_error(XmppStream stream, Presence.Stanza presence) {
        Flag flag = stream.get_flag(Flag.IDENTITY);
        Jid? from = presence.from;
        if (presence.is_error() && from != null && flag.is_muc_enter_outstanding() && flag.is_occupant((!) from)) {
            Jid bare_jid = ((!) from).bare_jid;
            ErrorStanza? error_stanza = presence.get_error();
            if (error_stanza == null) return;

            if (flag.matches_muc_enter(bare_jid, presence.id, ((!) from).resourcepart, true)) {
                emit_occupant_presence(stream, presence, OccupantPresenceKind.ERROR,
                    new ArrayList<int>(), null, null, null, new ArrayList<Hat>(), false);
                if (!flag.enter_futures.has_key(bare_jid)) {
                    flag.finish_muc_enter(bare_jid);
                    return;
                }
                MucEnterError? error = null;
                switch (((!) error_stanza).condition) {
                    case ErrorStanza.CONDITION_NOT_AUTHORIZED:
                        if (ErrorStanza.TYPE_AUTH == ((!) error_stanza).type_) error = MucEnterError.PASSWORD_REQUIRED;
                        break;
                    case ErrorStanza.CONDITION_REGISTRATION_REQUIRED:
                        if (ErrorStanza.TYPE_AUTH == ((!) error_stanza).type_) error = MucEnterError.NOT_IN_MEMBER_LIST;
                        break;
                    case ErrorStanza.CONDITION_FORBIDDEN:
                        if (ErrorStanza.TYPE_AUTH == ((!) error_stanza).type_) error = MucEnterError.BANNED;
                        break;
                    case ErrorStanza.CONDITION_SERVICE_UNAVAILABLE:
                        if (ErrorStanza.TYPE_WAIT == ((!) error_stanza).type_) error = MucEnterError.OCCUPANT_LIMIT_REACHED;
                        break;
                    case ErrorStanza.CONDITION_ITEM_NOT_FOUND:
                        if (ErrorStanza.TYPE_CANCEL == ((!) error_stanza).type_) error = MucEnterError.ROOM_DOESNT_EXIST;
                        break;
                    case ErrorStanza.CONDITION_CONFLICT:
                        if (ErrorStanza.TYPE_CANCEL == ((!) error_stanza).type_) error = MucEnterError.NICK_CONFLICT;
                        break;
                    case ErrorStanza.CONDITION_NOT_ALLOWED:
                        if (ErrorStanza.TYPE_CANCEL == ((!) error_stanza).type_) error = MucEnterError.CREATION_RESTRICTED;
                        break;
                    case ErrorStanza.CONDITION_NOT_ACCEPTABLE:
                        if (ErrorStanza.TYPE_CANCEL == ((!) error_stanza).type_) error = MucEnterError.USE_RESERVED_ROOMNICK;
                        break;
                }
                if (error != null) {
                    finish_enter_with_result(stream, flag, bare_jid,
                        new JoinResult() {muc_error=error});
                } else {
                    finish_enter_with_result(stream, flag, bare_jid,
                        new JoinResult() {stanza_error=((!) error_stanza).condition});
                }
            }
        }
    }

    public bool admit_received_presence(XmppStream stream,
            Presence.Stanza presence) {
        if (presence.type_ != Presence.Stanza.TYPE_AVAILABLE) return true;

        StanzaNode? x_node = presence.stanza.get_subnode("x", NS_URI_USER);
        if (x_node == null) return true;

        Flag flag = stream.get_flag(Flag.IDENTITY);
        bool is_self_presence = has_status_code((!) x_node,
            StatusCode.SELF_PRESENCE);
        Jid bare_jid = presence.from.bare_jid;
        bool has_active_enter = flag.get_enter_id(bare_jid) != null;

        if (is_self_presence && flag.consume_cancelled_muc_enter(bare_jid,
                presence.id, presence.from.resourcepart,
                !has_active_enter)) {
            debug("Rejecting stale cancelled MUC self-presence from %s before dispatch",
                presence.from.to_string());
            return false;
        }
        if (!flag.is_occupant(presence.from)) {
            debug("Rejecting late MUC presence from inactive room %s before dispatch",
                presence.from.to_string());
            return false;
        }
        if (!is_self_presence) return true;

        string? presence_nick = presence.from.resourcepart;
        if (has_active_enter) {
            if (!flag.matches_muc_enter(bare_jid, presence.id,
                    presence_nick)) {
                debug("Rejecting stale MUC self-presence from %s that does not match the active enter before dispatch",
                    presence.from.to_string());
                return false;
            }
        } else {
            string? own_nick = flag.get_muc_nick(bare_jid);
            if (own_nick == null || presence_nick != own_nick) {
                debug("Rejecting stale MUC self-presence from %s that does not match the current room nick before dispatch",
                    presence.from.to_string());
                return false;
            }
        }
        return true;
    }

    private void on_received_available(XmppStream stream, Presence.Stanza presence) {
        Flag flag = stream.get_flag(Flag.IDENTITY);
        StanzaNode? cancelled_x_node = presence.stanza.get_subnode("x", NS_URI_USER);
        if (cancelled_x_node != null) {
            ArrayList<int> cancelled_status_codes = get_status_codes(cancelled_x_node);
            if (cancelled_status_codes.contains(StatusCode.SELF_PRESENCE) &&
                    flag.consume_cancelled_muc_enter(presence.from.bare_jid, presence.id, presence.from.resourcepart, true)) {
                debug("Ignoring stale cancelled MUC self-presence from %s", presence.from.to_string());
                return;
            }
        }
        if (flag.is_occupant(presence.from)) {
            StanzaNode? x_node = presence.stanza.get_subnode("x", NS_URI_USER);
            var status_codes = new ArrayList<int>();
            Affiliation? parsed_affiliation = null;
            Role? parsed_role = null;
            string? real_bare_jid = null;
            bool real_jid_known = false;
            bool is_self_presence = false;
            JoinResult? pending_join_result = null;
            if (x_node != null) {
                status_codes = get_status_codes(x_node);
                Jid bare_jid = presence.from.bare_jid;
                is_self_presence = status_codes.contains(StatusCode.SELF_PRESENCE);

                if (is_self_presence) {
                    bool has_active_enter = flag.get_enter_id(bare_jid) != null;
                    string? presence_nick = presence.from.resourcepart;
                    if (has_active_enter) {
                        if (!flag.matches_muc_enter(bare_jid, presence.id, presence_nick)) {
                            debug("Ignoring stale MUC self-presence from %s that does not match the active enter", presence.from.to_string());
                            return;
                        }
                    } else {
                        string? own_nick = flag.get_muc_nick(bare_jid);
                        if (own_nick == null || presence_nick != own_nick) {
                            debug("Ignoring stale MUC self-presence from %s that does not match the current room nick", presence.from.to_string());
                            return;
                        }
                    }

                    // Only an enter-correlated or current own self-presence
                    // may establish status-100 JID visibility. This follows
                    // the complete lifecycle authority check.
                    if (status_codes.contains(StatusCode.JID_VISIBLE)) {
                        set_room_real_jid_visibility(stream, bare_jid,
                            RealJidVisibility.ANYONE);
                    }

                    if (has_active_enter) {
                        if (!flag.enter_futures.has_key(bare_jid)) {
                            flag.finish_muc_enter(bare_jid);
                            flag.set_muc_nick(presence.from);
                        } else {
                            // Keep the three required lists parallel, but expose
                            // one awaitable operation so security-sensitive
                            // consumers do not launch a duplicate set of IQs.
                            query_member_affiliation_snapshot.begin(stream,
                                bare_jid);

                            pending_join_result = new JoinResult() { nick=presence.from.resourcepart, newly_created=status_codes.contains(StatusCode.NEW_ROOM_CREATED) };
                            flag.set_muc_nick(presence.from);
                        }
                    }
                }
                string? affiliation_str = x_node.get_deep_attribute("item", "affiliation");
                Affiliation? affiliation = null;
                if (affiliation_str != null) {
                    affiliation = parse_affiliation(affiliation_str);
                    parsed_affiliation = affiliation;
                    Affiliation old_affiliation = flag.get_affiliation(presence.from.bare_jid, presence.from);
                    flag.set_affiliation(presence.from.bare_jid, presence.from, affiliation);
                    if (affiliation != old_affiliation) {
                        received_occupant_affiliation(stream, presence.from, affiliation);
                    }
                }
                StanzaNode? item_node = x_node.get_subnode("item", NS_URI_USER);
                real_jid_known = item_node != null;
                string? jid_ = item_node != null
                    ? ((!) item_node).get_attribute("jid") : null;
                Jid? parsed_real_jid = null;
                if (jid_ != null && current_role_forbids_real_jids(flag,
                        presence.from.bare_jid)) {
                    // Preserve the authoritative "known absent" edge for the
                    // worker, but never retain or re-emit a forbidden JID.
                    flag.clear_occupant_real_jid(presence.from);
                    received_occupant_jid(stream, presence.from, null);
                    real_bare_jid = null;
                    real_jid_known = true;
                } else if (jid_ != null) {
                    try {
                        Jid jid = new Jid(jid_);
                        parsed_real_jid = jid.bare_jid;
                        real_bare_jid = jid.bare_jid.to_string();
                        flag.set_real_jid(presence.from, jid);
                        received_occupant_jid(stream, presence.from, jid);
                    } catch (InvalidJidError e) {
                        warning("Received invalid occupant jid: %s", e.message);
                        flag.clear_occupant_real_jid(presence.from);
                        received_occupant_jid(stream, presence.from, null);
                    }
                } else if (real_jid_known) {
                    flag.clear_occupant_real_jid(presence.from);
                    received_occupant_jid(stream, presence.from, null);
                }
                if (affiliation != null) {
                    Jid? affiliation_jid = parsed_real_jid ?? flag.get_real_jid(presence.from);
                    if (affiliation_jid != null) {
                        flag.set_offline_member(presence.from.bare_jid,
                            (!) affiliation_jid, (!) affiliation);
                    }
                }
                string? role_str = x_node.get_deep_attribute("item", "role");
                if (role_str != null) {
                    Role role = parse_role(role_str);
                    parsed_role = role;
                    bool old_role_known = flag.has_occupant_role(presence.from);
                    Role? old_role = flag.get_occupant_role(presence.from);
                    flag.set_occupant_role(presence.from, role);
                    string? own_nick = flag.get_muc_nick(
                        presence.from.bare_jid);
                    bool is_current_self = is_self_presence ||
                        (own_nick != null && presence.from.resourcepart ==
                            (!) own_nick);
                    if (is_current_self && role != Role.MODERATOR &&
                            flag.get_real_jid_visibility(
                                presence.from.bare_jid) ==
                                RealJidVisibility.MODERATORS &&
                            (!old_role_known || old_role == Role.MODERATOR)) {
                        clear_room_real_jids_after_privacy_change(stream,
                            presence.from.bare_jid,
                            StatusCode.SEMI_ANONYMOUS);
                        // This same self-presence was parsed before the role
                        // boundary. Do not let its formerly disclosed jid be
                        // reintroduced by the final atomic AVAILABLE event.
                        real_bare_jid = null;
                        real_jid_known = true;
                    }
                    if (is_current_self && role == Role.MODERATOR &&
                            old_role_known && old_role != Role.MODERATOR &&
                            flag.get_real_jid_visibility(
                                presence.from.bare_jid) ==
                                RealJidVisibility.MODERATORS) {
                        request_occupant_presence_resync(stream,
                            presence.from.bare_jid);
                    }
                    if (!old_role_known || role != old_role) {
                        received_occupant_role(stream, presence.from, role);
                    }
                }
            }

            Gee.List<Hat> hats = parse_hats(presence.stanza);
            Gee.List<Hat> old_hats = flag.get_occupant_hats(presence.from);
            if (!hat_lists_equal(old_hats, hats)) {
                flag.set_occupant_hats(presence.from, hats);
                received_occupant_hats(stream, presence.from, hats);
            }
            emit_occupant_presence(stream, presence, OccupantPresenceKind.AVAILABLE,
                status_codes, parsed_affiliation, parsed_role, real_bare_jid, hats,
                is_self_presence, null, real_jid_known);
            // Gee.Promise resumes enter() continuations synchronously. Finish
            // only after every state field and the atomic presence event from
            // this self-presence have been published. A reentrant cancellation
            // can then clear the room without this handler recreating it.
            if (pending_join_result != null) {
                finish_enter_with_result(stream, flag,
                    presence.from.bare_jid, (!) pending_join_result);
            }
        }
    }

    private Gee.List<Hat> parse_hats(StanzaNode stanza) {
        var hats = new ArrayList<Hat>();
        StanzaNode? hats_node = stanza.get_subnode("hats", NS_URI_HATS);
        if (hats_node == null) return hats;

        foreach (StanzaNode hat_node in hats_node.get_subnodes("hat", NS_URI_HATS)) {
            string? uri = hat_node.get_attribute("uri");
            string? title = hat_node.get_attribute("title");
            if (uri == null || title == null || uri == "" || title == "") continue;

            hats.add(new Hat() {
                uri = uri,
                title = title,
                hue = hat_node.get_attribute("hue")
            });
        }
        return hats;
    }

    private bool hat_lists_equal(Gee.List<Hat> a, Gee.List<Hat> b) {
        if (a.size != b.size) return false;
        for (int i = 0; i < a.size; i++) {
            if (!a[i].equals(b[i])) return false;
        }
        return true;
    }

    private void emit_occupant_presence(XmppStream stream, Presence.Stanza presence,
            OccupantPresenceKind kind, Gee.List<int> status_codes,
            Affiliation? affiliation, Role? role, string? real_bare_jid,
            Gee.List<Hat> hats, bool is_self_presence, string? nick = null,
            bool real_jid_known = false) {
        if (!occupant_presence_events_enabled) return;

        string[] hat_uris = new string[hats.size];
        string[] hat_titles = new string[hats.size];
        string[] hat_hues = new string[hats.size];
        for (int i = 0; i < hats.size; i++) {
            hat_uris[i] = hats[i].uri;
            hat_titles[i] = hats[i].title;
            hat_hues[i] = hats[i].hue ?? "";
        }
        int[] copied_status_codes = new int[status_codes.size];
        for (int i = 0; i < status_codes.size; i++) copied_status_codes[i] = status_codes[i];

        received_occupant_presence(stream, new OccupantPresenceEvent(
            kind, presence.from.to_string(), presence.from.bare_jid.to_string(),
            nick ?? presence.from.resourcepart, real_bare_jid,
            affiliation ?? Affiliation.NONE, affiliation != null,
            role ?? Role.NONE, role != null, hat_uris, hat_titles,
            get_presence_avatar_hash(presence), copied_status_codes,
            is_self_presence, GLib.get_monotonic_time(), real_jid_known,
            hat_hues));
    }

    private string? get_presence_avatar_hash(Presence.Stanza presence) {
        const string NS_URI_VCARD_UPDATE = "vcard-temp:x:update";
        StanzaNode? update_node = presence.stanza.get_subnode("x", NS_URI_VCARD_UPDATE);
        if (update_node == null) return null;
        StanzaNode? photo_node = ((!) update_node).get_subnode("photo", NS_URI_VCARD_UPDATE);
        if (photo_node == null) photo_node = ((!) update_node).get_subnode("photo");
        if (photo_node == null) return null;
        // XEP-0153 uses an empty <photo/> as an authoritative avatar reset.
        // Absence means "no avatar update" and must remain distinguishable.
        return ((!) photo_node).get_string_content() ?? "";
    }

    private void on_received_unavailable(XmppStream stream, Presence.Stanza presence) {
        debug("on_received_unavailable from %s", presence.from.to_string());
        Flag flag = stream.get_flag(Flag.IDENTITY);
        if (!flag.is_occupant(presence.from)) {
            debug("Not an occupant: %s", presence.from.to_string());
            return;
        }

        StanzaNode? x_node = presence.stanza.get_subnode("x", NS_URI_USER);
        ArrayList<int> status_codes = x_node != null
            ? get_status_codes((!) x_node)
            : new ArrayList<int>();
        if (status_codes.size > 0) {
            var sb = new StringBuilder();
            foreach (int c in status_codes) sb.append_printf("%d ", c);
            debug("Status codes: %s", sb.str.strip());
        }

        string? reason = null;
        StanzaNode? item_node = x_node != null
            ? ((!) x_node).get_subnode("item", NS_URI_USER)
            : null;
        string? replacement_nick = null;
        string? real_bare_jid = null;
        bool real_jid_known = item_node != null;
        Jid? parsed_real_jid = null;
        Affiliation? parsed_affiliation = null;
        Role? parsed_role = null;
        if (item_node != null) {
            replacement_nick = ((!) item_node).get_attribute("nick");
            string? real_jid = ((!) item_node).get_attribute("jid");
            if (real_jid != null) {
                try {
                    parsed_real_jid = new Jid((!) real_jid).bare_jid;
                    real_bare_jid = ((!) parsed_real_jid).to_string();
                } catch (InvalidJidError e) {
                    warning("Received invalid unavailable occupant jid: %s", e.message);
                }
            }
            if (parsed_real_jid == null) {
                flag.clear_occupant_real_jid(presence.from);
                received_occupant_jid(stream, presence.from, null);
            }
            string? affiliation_string = ((!) item_node).get_attribute("affiliation");
            if (affiliation_string != null) parsed_affiliation = parse_affiliation((!) affiliation_string);
            string? role_string = ((!) item_node).get_attribute("role");
            if (role_string != null) parsed_role = parse_role((!) role_string);

            StanzaNode? reason_node = item_node.get_subnode("reason", NS_URI_USER);
            if (reason_node != null) {
                reason = reason_node.get_string_content();
                debug("Found reason node with content: '%s'", reason);
            } else {
                debug("Item node found, but no reason node.");
                // Try without namespace just in case
                reason_node = item_node.get_subnode("reason");
                if (reason_node != null) {
                     reason = reason_node.get_string_content();
                     debug("Found reason node without explicit namespace: '%s'", reason);
                }
            }
        } else if (x_node != null) {
            debug("No item node found in x_node.");
        }

        bool is_self = StatusCode.SELF_PRESENCE in status_codes;
        if (!is_self) {
            string? own_nick = flag.get_muc_nick(presence.from.bare_jid);
            debug("Checking self-removal. Own nick: '%s', Presence resource: '%s'", own_nick != null ? own_nick : "null", presence.from.resourcepart);
            if (own_nick != null && presence.from.resourcepart == own_nick) {
                is_self = true;
                debug("Detected self-removal via nick match (missing 110)");
            }
        }

        if (parsed_affiliation != null) {
            Jid? affiliation_jid = parsed_real_jid ?? flag.get_real_jid(presence.from);
            if (affiliation_jid != null) {
                flag.set_offline_member(presence.from.bare_jid,
                    (!) affiliation_jid, (!) parsed_affiliation);
            }
        }

        emit_occupant_presence(stream, presence, OccupantPresenceKind.UNAVAILABLE,
            status_codes, parsed_affiliation, parsed_role, real_bare_jid,
            parse_hats(presence.stanza), is_self, replacement_nick,
            real_jid_known);

        if (x_node == null) {
            debug("No x_node found");
            flag.remove_occupant_info(presence.from);
            return;
        }

        // XEP-0045 section 10.9 uses <destroy/>, not a removal status code.
        // ejabberd also omits 110 here. Only our current room/nick can end
        // our visit; a payload attached to another occupant is insufficient.
        StanzaNode? destroy = ((!) x_node).get_subnode("destroy", NS_URI_USER);
        string? current_nick = flag.get_muc_nick(presence.from.bare_jid);
        if (destroy != null && current_nick != null &&
                presence.from.resourcepart == current_nick) {
            string? destroy_reason = ((!) destroy).get_deep_string_content(NS_URI_USER + ":reason");
            leave_room_state(stream, presence.from.bare_jid);
            room_destroyed(stream, presence.from.bare_jid, destroy_reason);
            return;
        }

        bool occupant_info_removed = false;
        if (StatusCode.SELF_PRESENCE in status_codes) {
            flag.remove_occupant_info(presence.from);
            occupant_info_removed = true;
        } else if (is_self) {
            flag.remove_occupant_info(presence.from);
            occupant_info_removed = true;
        }

        foreach (StatusCode code in USER_REMOVED_CODES) {
            if (code in status_codes) {
                if (is_self) {
                    debug("Self removed with code %s", code.to_string());
                    leave_room_state(stream, presence.from.bare_jid);
                    occupant_info_removed = true;
                    self_removed_from_room(stream, presence.from, code, reason);
                    Presence.Flag presence_flag = stream.get_flag(Presence.Flag.IDENTITY);
                    presence_flag.remove_presence(presence.from.bare_jid);
                } else {
                    removed_from_room(stream, presence.from, code);
                }
            }
        }
        if (!occupant_info_removed) {
            flag.remove_occupant_info(presence.from);
        }
    }

    public async bool query_room_info(XmppStream stream, Jid jid) {
        Flag flag = stream.get_flag(Flag.IDENTITY);
        uint64 query_generation = flag.begin_room_info_query(jid);
        room_info_query_started(stream, jid.bare_jid);
        bool result = yield query_room_info_for_generation(stream, jid,
            flag, query_generation);
        bool was_current = flag.is_current_room_info_query(jid,
            query_generation);
        flag.finish_room_info_query(jid, query_generation);
        if (was_current) {
            room_info_query_finished(stream, jid.bare_jid, result);
        }
        return result;
    }

    private async bool query_room_info_for_generation(XmppStream stream,
            Jid jid, Flag flag, uint64 query_generation) {
        // An explicit room-info refresh must not join an older generic disco
        // request that happened to be in flight. Configuration and permission
        // state need a response initiated for this exact refresh generation.
        ServiceDiscovery.InfoResult? info_result = yield stream.get_module<
            ServiceDiscovery.Module>(ServiceDiscovery.Module.IDENTITY)
                .request_info_fresh(stream, jid);
        if (info_result == null) {
            debug("query_room_info: No info result for %s", jid.to_string());
            return false;
        }

        string? result_from = info_result.iq.stanza.get_attribute("from");
        bool avatar_sender_authoritative = result_from != null;
        if (result_from != null) {
            try {
                Jid result_from_jid = new Jid((!) result_from);
                if (!result_from_jid.equals(jid.bare_jid)) {
                    warning("Ignoring room info result for %s from unexpected JID %s",
                        jid.bare_jid.to_string(),
                        result_from_jid.to_string());
                    return false;
                }
            } catch (InvalidJidError e) {
                warning("Ignoring room info result with invalid from JID: %s",
                    e.message);
                return false;
            }
        }

        Gee.List<Feature> features = new ArrayList<Feature>();
        string? room_name = null;
        bool? occupants_may_change_subject = null;
        bool? occupants_may_invite = null;

        foreach (ServiceDiscovery.Identity identity in info_result.identities) {
            if (identity.category == "conference" && identity.name != null) {
                debug("query_room_info: Setting room name for %s to '%s'", jid.to_string(), identity.name);
                room_name = identity.name;
            }
        }

        foreach (string feature in info_result.features) {
            Feature? parsed = null;
            switch (feature) {
                case "http://jabber.org/protocol/muc#register": parsed = Feature.REGISTER; break;
                case "http://jabber.org/protocol/muc#roomconfig": parsed = Feature.ROOMCONFIG; break;
                case "http://jabber.org/protocol/muc#roominfo": parsed = Feature.ROOMINFO; break;
                case Xmpp.Xep.OccupantIds.NS_URI: parsed = Feature.OCCUPANT_ID; break;
                case UniqueStableStanzaIDs.NS_URI:
                case "http://jabber.org/protocol/muc#stable_id":
                    parsed = Feature.STABLE_ID;
                    break;
                case "muc_hidden": parsed = Feature.HIDDEN; break;
                case "muc_membersonly": parsed = Feature.MEMBERS_ONLY; break;
                case "muc_moderated": parsed = Feature.MODERATED; break;
                case "muc_nonanonymous": parsed = Feature.NON_ANONYMOUS; break;
                case "muc_open": parsed = Feature.OPEN; break;
                case "muc_passwordprotected": parsed = Feature.PASSWORD_PROTECTED; break;
                case "muc_persistent": parsed = Feature.PERSISTENT; break;
                case "muc_public": parsed = Feature.PUBLIC; break;
                case "muc_rooms": parsed = Feature.ROOMS; break;
                case "muc_semianonymous": parsed = Feature.SEMI_ANONYMOUS; break;
                case "muc_temporary": parsed = Feature.TEMPORARY; break;
                case "muc_unmoderated": parsed = Feature.UNMODERATED; break;
                case "muc_unsecured": parsed = Feature.UNSECURED; break;
            }
            if (parsed != null) features.add(parsed);
        }

        StanzaNode? info_query = info_result.iq.stanza.get_subnode(
            "query", ServiceDiscovery.NS_URI_INFO);
        if (info_query != null) {
            foreach (StanzaNode form in ((!) info_query).get_subnodes("x",
                    DataForms.NS_URI)) {
                if (form.get_attribute("type") != "result") continue;

                bool is_room_info_form = false;
                foreach (StanzaNode field in form.get_subnodes("field",
                        DataForms.NS_URI)) {
                    if (field.get_attribute("var") != "FORM_TYPE") continue;
                    StanzaNode? value = field.get_subnode("value",
                        DataForms.NS_URI);
                    if (value != null && ((!) value).get_string_content() ==
                            "http://jabber.org/protocol/muc#roominfo") {
                        is_room_info_form = true;
                    }
                    break;
                }
                if (!is_room_info_form) continue;

                foreach (StanzaNode field in form.get_subnodes("field",
                        DataForms.NS_URI)) {
                    string? field_var = field.get_attribute("var");
                    if (field_var != "muc#roomconfig_changesubject" &&
                            field_var != "muc#roomconfig_allowinvites" &&
                            field_var != "muc#roominfo_allowinvites") continue;
                    StanzaNode? value = field.get_subnode("value",
                        DataForms.NS_URI);
                    if (value == null) continue;
                    bool? parsed_value = null;
                    switch (((!) value).get_string_content().down()) {
                        case "1":
                        case "true":
                            parsed_value = true;
                            break;
                        case "0":
                        case "false":
                            parsed_value = false;
                            break;
                    }
                    if (field_var == "muc#roomconfig_changesubject") {
                        occupants_may_change_subject = parsed_value;
                    } else {
                        occupants_may_invite = parsed_value;
                    }
                }
            }
        }

        if (!flag.is_current_room_info_query(jid, query_generation)) {
            debug("Discarding superseded room-info result for %s",
                jid.bare_jid.to_string());
            return false;
        }

        // Replace the live projection atomically only after a complete,
        // valid disco result. A timeout/error must preserve the last known
        // feature state and the independent affiliation snapshot.
        RealJidVisibility previous_visibility =
            flag.get_real_jid_visibility(jid);
        if (room_name != null) flag.set_room_name(jid, (!) room_name);
        flag.set_room_features(jid, features);
        flag.set_occupants_may_change_subject(jid,
            occupants_may_change_subject);
        flag.set_occupants_may_invite(jid, occupants_may_invite);
        flag.mark_room_info_query_complete(jid, query_generation);

        Xep.MucAvatars.RoomAvatarInfo room_avatar_info =
            Xep.MucAvatars.parse_info_result(info_result);

        RealJidVisibility current_visibility =
            flag.get_real_jid_visibility(jid);
        if (current_visibility != previous_visibility) {
            room_real_jid_visibility_changed(stream, jid.bare_jid,
                current_visibility);
            if (current_visibility == RealJidVisibility.MODERATORS) {
                if (!own_occupant_is_moderator(flag, jid)) {
                    clear_room_real_jids_after_privacy_change(stream, jid,
                        StatusCode.SEMI_ANONYMOUS);
                } else if (previous_visibility ==
                            RealJidVisibility.NOBODY ||
                        previous_visibility == RealJidVisibility.UNKNOWN) {
                    // A moderator gains access when a fully/unknown-
                    // anonymous room becomes semi-anonymous. Ask for the
                    // newly disclosed occupant JIDs just as for ANYONE.
                    request_occupant_presence_resync(stream, jid);
                }
            } else if (current_visibility == RealJidVisibility.NOBODY) {
                clear_room_real_jids_after_privacy_change(stream, jid,
                    StatusCode.FULLY_ANONYMOUS);
            } else if (current_visibility == RealJidVisibility.UNKNOWN &&
                    previous_visibility != RealJidVisibility.NOBODY) {
                // A complete disco response without either standardized
                // anonymity feature is not proof that cached identities may
                // remain visible. Clear them without fabricating a MUC status
                // code that the service did not send.
                clear_room_real_jids_after_privacy_change(stream, jid,
                    StatusCode.SEMI_ANONYMOUS, false);
            } else if (current_visibility == RealJidVisibility.ANYONE &&
                    previous_visibility != RealJidVisibility.ANYONE) {
                request_occupant_presence_resync(stream, jid);
            }
        }
        if (avatar_sender_authoritative) {
            room_avatar_info_received(stream, jid.bare_jid, room_avatar_info);
        }
        room_info_updated(stream, jid);
        return true;
    }

    public async Gee.List<Jid>? query_affiliation(XmppStream stream, Jid jid,
            string affiliation) {
        return yield query_affiliation_internal(stream, jid, affiliation,
            null);
    }

    public async Gee.List<Jid>? query_affiliation_guarded(XmppStream stream,
            Jid jid, string affiliation,
            owned AffiliationQueryCommitGuard commit_guard) {
        return yield query_affiliation_internal(stream, jid, affiliation,
            (owned) commit_guard);
    }

    /**
     * Query the complete member/admin/owner affiliation snapshot.
     *
     * Concurrent callers for the same room and stream share one three-IQ
     * operation. A forced refresh supersedes the previous operation before
     * starting all three new query generations, which gives configuration
     * readback a strict post-change snapshot.
     */
    public async bool query_member_affiliation_snapshot(XmppStream stream,
            Jid jid, bool force_refresh = false) {
        return yield query_member_affiliation_snapshot_internal(stream, jid,
            force_refresh, null);
    }

    public async bool query_member_affiliation_snapshot_guarded(
            XmppStream stream, Jid jid, bool force_refresh,
            owned AffiliationQueryCommitGuard commit_guard) {
        return yield query_member_affiliation_snapshot_internal(stream, jid,
            force_refresh, (owned) commit_guard);
    }

    private async bool query_member_affiliation_snapshot_internal(
            XmppStream stream, Jid jid, bool force_refresh,
            owned AffiliationQueryCommitGuard? commit_guard) {
        Flag flag = stream.get_flag(Flag.IDENTITY);
        Jid room = jid.bare_jid;
        PendingMemberAffiliationSnapshot? pending =
            flag.get_pending_member_affiliation_snapshot(room);

        if (!force_refresh &&
                flag.has_complete_member_affiliation_snapshot(room)) {
            return true;
        }
        if (!force_refresh && pending != null) {
            if (commit_guard != null) {
                ((!) pending).set_commit_guard((owned) commit_guard);
            }
            try {
                return yield ((!) pending).promise.future.wait_async();
            } catch (Gee.FutureError e) {
                return false;
            }
        }

        var operation = new PendingMemberAffiliationSnapshot();
        if (commit_guard != null) {
            operation.set_commit_guard((owned) commit_guard);
        }
        flag.set_pending_member_affiliation_snapshot(room, operation);
        run_member_affiliation_snapshot_query.begin(stream, room, "member",
            operation);
        run_member_affiliation_snapshot_query.begin(stream, room, "admin",
            operation);
        run_member_affiliation_snapshot_query.begin(stream, room, "owner",
            operation);

        try {
            return yield operation.promise.future.wait_async();
        } catch (Gee.FutureError e) {
            return false;
        }
    }

    private async void run_member_affiliation_snapshot_query(
            XmppStream stream, Jid room, string affiliation,
            PendingMemberAffiliationSnapshot operation) {
        Flag flag = stream.get_flag(Flag.IDENTITY);
        Gee.List<Jid>? result = yield query_affiliation_guarded(stream, room,
            affiliation, () => {
                return flag.is_pending_member_affiliation_snapshot(room,
                        operation) && operation.may_commit();
            });
        if (!flag.is_pending_member_affiliation_snapshot(room, operation)) {
            return;
        }
        if (operation.record_result(result != null)) {
            flag.finish_pending_member_affiliation_snapshot(room, operation,
                flag.has_complete_member_affiliation_snapshot(room));
        }
    }

    private async Gee.List<Jid>? query_affiliation_internal(
            XmppStream stream, Jid jid, string affiliation,
            owned AffiliationQueryCommitGuard? commit_guard) {
        Flag flag = stream.get_flag(Flag.IDENTITY);
        Jid room_jid = jid.bare_jid;
        Affiliation requested_affiliation;
        if (!try_parse_list_affiliation(affiliation,
                out requested_affiliation)) {
            warning("Refusing invalid affiliation-list query '%s' for %s",
                affiliation, room_jid.to_string());
            return null;
        }
        uint64 query_generation = flag.begin_affiliation_query(room_jid,
            requested_affiliation);

        Iq.Stanza iq = new Iq.Stanza.get(
            new StanzaNode.build("query", NS_URI_ADMIN)
                .add_self_xmlns()
                .put_node(new StanzaNode.build("item", NS_URI_ADMIN)
                    .put_attribute("affiliation", affiliation))
        ) { to=room_jid };

        Iq.Stanza iq_result;
        try {
            iq_result = yield stream.get_module<Iq.Module>(Iq.Module.IDENTITY).send_iq_async(stream, iq);
        } catch (IOError.CANCELLED e) {
            debug("Affiliation query cancelled: %s", e.message);
            return null;
        } catch (GLib.Error e) {
            warning("Failed to query affiliation: %s", e.message);
            return null;
        }
        if (iq_result.is_error()) return null;

        string? result_from = iq_result.stanza.get_attribute("from");
        if (result_from != null) {
            try {
                Jid result_from_jid = new Jid((!) result_from);
                if (!result_from_jid.equals(room_jid)) {
                    warning("Ignoring affiliation result for %s from unexpected JID %s", room_jid.to_string(), result_from_jid.to_string());
                    return null;
                }
            } catch (InvalidJidError e) {
                warning("Ignoring affiliation result with invalid from JID: %s", e.message);
                return null;
            }
        }

        StanzaNode? query_node = iq_result.stanza.get_subnode("query", NS_URI_ADMIN);
        if (query_node == null) return null;

        Gee.List<StanzaNode> item_nodes = query_node.get_subnodes("item", NS_URI_ADMIN);
        Gee.List<Jid> ret_jids = new ArrayList<Jid>(Jid.equals_bare_func);
        foreach (StanzaNode item in item_nodes) {
            string? returned_jid_text = item.get_attribute("jid");
            string? returned_affiliation_text =
                item.get_attribute("affiliation");
            Affiliation returned_affiliation = Affiliation.NONE;
            if (returned_jid_text == null ||
                    returned_affiliation_text == null ||
                    !try_parse_list_affiliation(
                        (!) returned_affiliation_text,
                        out returned_affiliation) ||
                    returned_affiliation != requested_affiliation) {
                warning("Rejecting malformed %s affiliation list for %s",
                    affiliation, room_jid.to_string());
                return null;
            }

            try {
                Jid returned_jid = new Jid((!) returned_jid_text);
                if (returned_jid.is_full() ||
                        ret_jids.contains(returned_jid.bare_jid)) {
                    warning("Rejecting non-bare or duplicate JID in %s affiliation list for %s",
                        affiliation, room_jid.to_string());
                    return null;
                }
                ret_jids.add(returned_jid.bare_jid);
            } catch (InvalidJidError e) {
                warning("Rejecting invalid JID in %s affiliation list for %s: %s",
                    affiliation, room_jid.to_string(), e.message);
                return null;
            }
        }

        if (!flag.is_current_affiliation_query(room_jid,
                requested_affiliation, query_generation)) {
            debug("Discarding superseded %s affiliation list for %s",
                affiliation, room_jid.to_string());
            return null;
        }
        if (commit_guard != null && !((!) commit_guard)()) {
            debug("Discarding stale %s affiliation list for %s",
                affiliation, room_jid.to_string());
            return null;
        }

        // Commit only after the complete payload was validated. A malformed
        // server response must never partially clear or replace a previously
        // valid administration/member snapshot.
        flag.clear_affiliation_query_result(room_jid,
            requested_affiliation);
        foreach (Jid returned_jid in ret_jids) {
            flag.set_offline_member(room_jid, returned_jid,
                requested_affiliation);
            // OUTCAST is an administration list, never a private-room
            // recipient list. Do not route banned JIDs into avatar/OMEMO
            // member discovery.
            if (requested_affiliation == Affiliation.MEMBER ||
                    requested_affiliation == Affiliation.ADMIN ||
                    requested_affiliation == Affiliation.OWNER) {
                received_occupant_jid(stream, room_jid, returned_jid);
            }
        }
        flag.set_affiliation_query_complete(room_jid, requested_affiliation,
            query_generation);
        return ret_jids;
    }

    private static bool try_parse_list_affiliation(string value,
            out Affiliation affiliation) {
        switch (value) {
            case "admin":
                affiliation = Affiliation.ADMIN;
                return true;
            case "member":
                affiliation = Affiliation.MEMBER;
                return true;
            case "outcast":
                affiliation = Affiliation.OUTCAST;
                return true;
            case "owner":
                affiliation = Affiliation.OWNER;
                return true;
            default:
                affiliation = Affiliation.NONE;
                return false;
        }
    }

    private static ArrayList<int> get_status_codes(StanzaNode x_node) {
        ArrayList<int> ret = new ArrayList<int>();
        foreach (StanzaNode status_node in x_node.get_subnodes("status", NS_URI_USER)) {
            string? code = status_node.get_attribute("code");
            int parsed_code = 0;
            if (code != null && int.try_parse((!) code, out parsed_code,
                    null, 10)) ret.add(parsed_code);
        }
        return ret;
    }

    private static bool has_status_code(StanzaNode x_node, int expected_code) {
        foreach (StanzaNode status_node in x_node.get_subnodes("status", NS_URI_USER)) {
            string? code = status_node.get_attribute("code");
            if (code == null) continue;
            int parsed_code = 0;
            if (int.try_parse((!) code,
                    out parsed_code, null, 10) &&
                    parsed_code == expected_code) return true;
        }
        return false;
    }

    private static Affiliation parse_affiliation(string affiliation_str) {
        Affiliation affiliation;
        switch (affiliation_str) {
            case "admin":
                affiliation = Affiliation.ADMIN; break;
            case "member":
                affiliation = Affiliation.MEMBER; break;
            case "outcast":
                affiliation = Affiliation.OUTCAST; break;
            case "owner":
                affiliation = Affiliation.OWNER; break;
            default:
                affiliation = Affiliation.NONE; break;
        }
        return affiliation;
    }

    private static Role parse_role(string role_str) {
        Role role;
        switch (role_str) {
            case "moderator":
                role = Role.MODERATOR; break;
            case "participant":
                role = Role.PARTICIPANT; break;
            case "visitor":
                role = Role.VISITOR; break;
            default:
                role = Role.NONE; break;
        }
        return role;
    }

    private static void throw_if_iq_error(Iq.Stanza result, string context) throws GLib.Error {
        if (!result.is_error()) return;

        ErrorStanza? stanza_error = result.get_error();
        string detail = "unknown stanza error";
        if (stanza_error != null) {
            detail = ((!) stanza_error).condition;
            if (((!) stanza_error).text != null && ((!) stanza_error).text != "") {
                detail += ": " + ((!) stanza_error).text;
            }
        }
        throw new GLib.IOError.FAILED("Server rejected %s: %s".printf(context, detail));
    }

    private static void throw_if_unexpected_iq_sender(Iq.Stanza result,
            Jid expected, string context) throws GLib.Error {
        string? from = result.stanza.get_attribute("from");
        // These IQs are addressed to a specific room service, not to the
        // account's own server. A sender-less result therefore cannot prove
        // that the room accepted the requested mutation.
        if (from == null) {
            throw new GLib.IOError.FAILED(
                "Ignoring %s response without room sender".printf(context));
        }
        try {
            Jid sender = new Jid((!) from);
            if (!sender.equals(expected.bare_jid)) {
                throw new GLib.IOError.FAILED(
                    "Ignoring %s response from unexpected JID %s".printf(
                        context, sender.to_string()));
            }
        } catch (InvalidJidError e) {
            throw new GLib.IOError.FAILED(
                "Ignoring %s response with invalid sender JID".printf(
                    context));
        }
    }

    public async void destroy_room(XmppStream stream, Jid jid, string? reason = null, Jid? alternate_venue = null) throws GLib.Error {
        StanzaNode destroy_node = new StanzaNode.build("destroy", NS_URI_OWNER);
        if (alternate_venue != null) {
            destroy_node.put_attribute("jid", alternate_venue.to_string());
        }
        if (reason != null) {
            destroy_node.put_node(new StanzaNode.build("reason", NS_URI_OWNER).put_node(new StanzaNode.text(reason)));
        }

        StanzaNode query_node = new StanzaNode.build("query", NS_URI_OWNER).add_self_xmlns().put_node(destroy_node);
        Iq.Stanza set_iq = new Iq.Stanza.set(query_node) { to=jid };
        
        Iq.Stanza result = yield stream.get_module<Iq.Module>(Iq.Module.IDENTITY).send_iq_async(stream, set_iq);
        throw_if_unexpected_iq_sender(result, jid, "destroy room");
        if (result.is_error()) {
            StanzaNode? error_node = result.stanza.get_subnode("error");
            string error_text = "Server rejected room destruction";
            if (error_node != null) {
                StanzaNode? text_node = error_node.get_subnode("text");
                if (text_node != null && text_node.get_string_content() != null) {
                    error_text = text_node.get_string_content();
                } else {
                    // Try to get the error condition name
                    foreach (StanzaNode child in error_node.get_all_subnodes()) {
                        if (child.ns_uri == "urn:ietf:params:xml:ns:xmpp-stanzas") {
                            error_text = child.name;
                            break;
                        }
                    }
                }
            }
            throw new GLib.IOError.FAILED(error_text);
        }
    }

    private void fail_outstanding_enters(XmppStream stream, Flag flag,
            string stanza_error) {
        var pending_jids = new ArrayList<Jid>(Jid.equals_bare_func);
        foreach (Jid jid in flag.enter_futures.keys) {
            pending_jids.add(jid);
        }

        foreach (Jid jid in pending_jids) {
            finish_enter_with_result(stream, flag, jid,
                new JoinResult() { stanza_error=stanza_error });
        }
    }

    private void finish_enter_with_result(XmppStream stream, Flag flag,
            Jid bare_jid, JoinResult result) {
        Promise<JoinResult?>? promise = flag.enter_futures[bare_jid];
        bool had_join = flag.get_muc_nick(bare_jid) != null;
        if (!had_join) flag.mark_muc_enter_cancelled(bare_jid);
        flag.finish_muc_enter(bare_jid);
        flag.enter_futures.unset(bare_jid);
        if (!had_join) leave_room_state(stream, bare_jid, true);

        if (promise != null && !((!) promise).future.ready) {
            ((!) promise).set_value(result);
        }
    }
}

public class ReceivedPipelineListener : StanzaListener<MessageStanza> {

    private string[] after_actions_const = new string[] { "EXTRACT_MESSAGE_2" };

    public override string action_group { get { return ""; } }
    public override string[] after_actions { get { return after_actions_const; } }

    Module outer;

    public ReceivedPipelineListener(Module outer) {
        this.outer = outer;
    }

    public override async bool run(XmppStream stream, MessageStanza message) {
        if (message.type_ == MessageStanza.TYPE_NORMAL) {
            StanzaNode? x_node = message.stanza.get_subnode("x", NS_URI_USER);
            if (x_node != null) {
                StanzaNode? invite_node = x_node.get_subnode("invite", NS_URI_USER);
                string? password = null;
                StanzaNode? password_node = x_node.get_subnode("password", NS_URI_USER);
                if (password_node != null) password = password_node.get_string_content();
                if (invite_node != null) {
                    Jid? from_jid = null;
                    try {
                        string from = invite_node.get_attribute("from");
                        if (from != null) from_jid = new Jid(from);
                    } catch (InvalidJidError e) {
                        warning("Received invite from invalid jid: %s", e.message);
                    }
                    if (from_jid != null) {
                        StanzaNode? reason_node = invite_node.get_subnode("reason", NS_URI_USER);
                        string? reason = null;
                        if (reason_node != null) reason = reason_node.get_string_content();
                        StanzaNode? continue_node = invite_node.get_subnode("continue", NS_URI_USER);
                        bool continue_thread = continue_node != null;
                        string? thread = continue_node != null ? continue_node.get_attribute("thread") : null;
                        bool is_mam_message = Xmpp.MessageArchiveManagement.MessageFlag.get_flag(message) != null; // TODO
                        if (!is_mam_message) {
                            outer.invite_received(stream, message.from, from_jid, password, reason);
                            outer.invite_received_with_context(stream, message.from, from_jid, password, reason, continue_thread, thread);
                        }
                        return true;
                    }
                }
            }

            Jid? room_jid = message.from;
            Flag? flag = stream.get_flag(Flag.IDENTITY);
            StanzaNode? form = message.stanza.get_subnode("x",
                DataForms.NS_URI);
            if (MessageArchiveManagement.MessageFlag.get_flag(message) !=
                    null || Xmpp.Xep.DelayedDelivery.MessageFlag.get_flag(
                        message) != null || message.stanza.get_subnode("delay",
                        Xmpp.Xep.DelayedDelivery.NS_URI) != null ||
                    room_jid == null || !((!) room_jid).is_bare() ||
                    flag == null || !((!) flag).is_muc((!) room_jid) ||
                    form == null || ((!) form).get_attribute("type") !=
                        "form") {
                return false;
            }

            Jid? requester_jid = null;
            string? nick = null;
            bool form_type_seen = false;
            bool requested_role_seen = false;
            bool requester_seen = false;
            bool nick_seen = false;
            bool request_allow_seen = false;
            foreach (StanzaNode field in ((!) form).get_subnodes("field",
                    DataForms.NS_URI)) {
                string? var_ = field.get_attribute("var");
                StanzaNode? value_node = field.get_subnode("value",
                    DataForms.NS_URI);
                string? value = value_node != null
                    ? ((!) value_node).get_string_content() : null;
                switch (var_) {
                    case "FORM_TYPE":
                        if (form_type_seen || value != NS_URI_REQUEST ||
                                field.get_attribute("type") != "hidden")
                            return false;
                        form_type_seen = true;
                        break;
                    case "muc#role":
                        if (requested_role_seen || value != "participant")
                            return false;
                        requested_role_seen = true;
                        break;
                    case "muc#jid":
                        if (requester_seen || value == null) return false;
                        requester_seen = true;
                        try {
                            requester_jid = new Jid((!) value);
                        } catch (InvalidJidError e) {
                            return false;
                        }
                        break;
                    case "muc#roomnick":
                        if (nick_seen || value == null ||
                                ((!) value).strip() == "") return false;
                        nick_seen = true;
                        nick = value;
                        break;
                    case "muc#request_allow":
                        if (request_allow_seen || value == null ||
                                (((!) value).down() != "false" &&
                                 (!) value != "0")) return false;
                        request_allow_seen = true;
                        break;
                    default:
                        break;
                }
            }
            if (!form_type_seen || !requested_role_seen ||
                    !request_allow_seen ||
                    requester_jid == null || nick == null) {
                return false;
            }

            outer.voice_request_received(stream, (!) room_jid,
                (!) requester_jid, (!) nick, message.id);
            return true;
        }
        return false;
    }
}

}

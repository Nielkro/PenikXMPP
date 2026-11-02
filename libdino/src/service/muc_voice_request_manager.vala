/*
 * Copyright (C) 2026 Ralf Peter <dinox@handwerker.jetzt>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

using Gee;
using Dino.Entities;
using Xmpp;

namespace Dino {

public enum MucVoiceRequestState {
    PENDING,
    RESPONDING
}

public enum OwnMucVoiceRequestState {
    SENDING,
    SENT,
    FAILED
}

/** One outgoing voice request scoped to one account and bare room JID. */
public class OwnMucVoiceRequest : Object {
    public string id { get; private set; }
    public Account account { get; private set; }
    public Jid room_jid { get; private set; }
    public OwnMucVoiceRequestState state { get; private set; }
    public string? condition { get; private set; }
    public string? text { get; private set; }

    internal OwnMucVoiceRequest(Account account, Jid room_jid, string id) {
        this.id = id;
        this.account = account;
        this.room_jid = room_jid.bare_jid;
        this.state = OwnMucVoiceRequestState.SENDING;
    }

    internal void mark_sent() {
        state = OwnMucVoiceRequestState.SENT;
        condition = null;
        text = null;
    }

    internal void mark_failed(string condition, string? text) {
        state = OwnMucVoiceRequestState.FAILED;
        this.condition = condition;
        this.text = text;
    }
}

/**
 * One transient request tied to an account, room, bare requester JID and nick.
 * request_jid retains the most specific form value for the protocol response.
 */
public class PendingMucVoiceRequest : Object {
    public string id { get; private set; }
    public Account account { get; private set; }
    public Jid room_jid { get; private set; }
    public Jid from_jid { get; private set; }
    public Jid request_jid { get; private set; }
    public string nick { get; private set; }
    public string? source_stanza_id { get; private set; }
    public MucVoiceRequestState state { get; private set; }
    public DateTime received_at { get; private set; }

    internal PendingMucVoiceRequest(Account account, Jid room_jid,
            Jid from_jid, string nick, string? source_stanza_id) {
        this.id = Uuid.string_random();
        this.account = account;
        this.room_jid = room_jid.bare_jid;
        this.from_jid = from_jid.bare_jid;
        this.request_jid = from_jid;
        this.nick = nick;
        this.source_stanza_id = source_stanza_id;
        this.state = MucVoiceRequestState.PENDING;
        this.received_at = new DateTime.now_utc();
    }

    internal void refresh(Jid exact_request_jid) {
        // Never replace a full form JID with a less specific bare duplicate,
        // but follow a newer full resource supplied by the authoritative room.
        if (exact_request_jid.is_full() || !request_jid.is_full()) {
            request_jid = exact_request_jid;
        }
    }

    internal void begin_response() {
        state = MucVoiceRequestState.RESPONDING;
    }

    internal void restore_pending() {
        state = MucVoiceRequestState.PENDING;
    }
}

/**
 * Owns pending voice requests independently of desktop notifications and UI
 * widgets. State is deliberately transient and is fenced by the current MUC
 * lifecycle so an old request can never mutate a rejoined room.
 */
public class MucVoiceRequestManager : StreamInteractionModule, Object {
    public static ModuleIdentity<MucVoiceRequestManager> IDENTITY =
        new ModuleIdentity<MucVoiceRequestManager>(
            "muc_voice_request_manager");

    public string id { get { return IDENTITY.id; } }

    public signal void request_received(PendingMucVoiceRequest request);
    public signal void request_removed(PendingMucVoiceRequest request);
    public signal void request_response_started(PendingMucVoiceRequest request);
    public signal void requests_changed(Account account, Jid room_jid);
    public signal void own_request_changed(Account account, Jid room_jid,
        OwnMucVoiceRequest? request);
    public signal void own_request_failed(Account account, Jid room_jid,
        string condition, string? text);
    public signal void request_action_failed(PendingMucVoiceRequest request,
        string condition, string? text);

    private MucManager? muc_manager;
    private HashMap<string, PendingMucVoiceRequest> requests_by_id =
        new HashMap<string, PendingMucVoiceRequest>();
    private HashMap<string, PendingMucVoiceRequest> pending_by_key =
        new HashMap<string, PendingMucVoiceRequest>();
    private HashMap<string, OwnMucVoiceRequest> own_requests_by_room =
        new HashMap<string, OwnMucVoiceRequest>();
    public static void start(StreamInteractor stream_interactor) {
        stream_interactor.add_module(
            new MucVoiceRequestManager(stream_interactor));
    }

    private MucVoiceRequestManager(StreamInteractor stream_interactor) {
        this.muc_manager = stream_interactor.get_module<MucManager>(
            MucManager.IDENTITY);
        MucManager manager = (!) this.muc_manager;

        manager.voice_request_received.connect(on_voice_request_received);
        manager.voice_request_sent.connect(on_own_voice_request_sent);
        manager.voice_request_failed.connect(on_own_voice_request_failed);
        manager.voice_request_response_failed.connect(
            on_voice_request_response_failed);
        manager.voice_request_response_settled.connect(
            on_voice_request_response_settled);
        manager.received_occupant_role.connect(on_occupant_role);
        manager.occupant_role_change_confirmed.connect(
            (account, occupant, role) => {
                on_occupant_role(account, occupant, role);
            });
        manager.occupant_removed.connect((account, room, occupant, code) => {
            on_occupant_removed(account, room, occupant);
        });
        manager.private_room_occupant_real_jid_ready.connect(
                (account, room, occupant, real_jid) => {
            if (!occupant.is_full()) return;
            clear_nick_identity_mismatches(account, room,
                occupant.resourcepart, real_jid.bare_jid.to_string());
        });
        manager.left_signal.connect((account, room) => {
            clear_room(account, room);
        });
        manager.joined.connect((account, room) => {
            clear_room(account, room);
        });
        stream_interactor.connection_manager.connection_state_changed.connect(
                (account, state) => {
            if (state == ConnectionManager.ConnectionState.DISCONNECTED) {
                clear_account(account);
            }
        });
        stream_interactor.account_removed.connect((account) => {
            clear_account(account);
        });
    }

    /** Test-only construction exercises the same store and cleanup paths. */
    internal MucVoiceRequestManager.for_tests() {
        this.muc_manager = null;
    }

    public PendingMucVoiceRequest? get_request(string id) {
        return requests_by_id[id];
    }

    public OwnMucVoiceRequest? get_own_request(Account account,
            Jid room_jid) {
        return own_requests_by_room[own_request_key(account, room_jid)];
    }

    /**
     * Request participant voice once. A second activation while the local
     * write is still in flight is ignored atomically; SENT and FAILED are
     * explicit previous attempts and may be retried with a fresh stanza ID.
     */
    public void request_voice(Account account, Jid room_jid) {
        Jid room = room_jid.bare_jid;
        string correlation_id = Xmpp.random_uuid();
        OwnMucVoiceRequest? request = begin_own_request(account, room,
            correlation_id);
        if (request == null) return;

        if (muc_manager == null) {
            fail_own_request(account, room, correlation_id,
                "send-failed", null);
            return;
        }

        string? dispatched_id = ((!) muc_manager).request_voice(account,
            room, correlation_id);
        if (dispatched_id == null) {
            fail_own_request(account, room, correlation_id,
                "send-failed", null);
        } else if (dispatched_id != correlation_id) {
            fail_own_request(account, room, correlation_id,
                "send-failed", null);
        }
    }

    public Gee.List<PendingMucVoiceRequest> get_pending_requests(
            Account account, Jid room_jid) {
        var result = new ArrayList<PendingMucVoiceRequest>();
        foreach (PendingMucVoiceRequest request in requests_by_id.values) {
            if (request.state == MucVoiceRequestState.PENDING &&
                    same_account(request.account, account) &&
                    request.room_jid.equals(room_jid.bare_jid)) {
                result.add(request);
            }
        }
        result.sort((left, right) =>
            left.received_at.compare(right.received_at));
        return result;
    }

    public async void accept(string id) throws GLib.Error {
        yield respond(id, true);
    }

    public async void deny(string id) throws GLib.Error {
        yield respond(id, false);
    }

    private async void respond(string id, bool allow) throws GLib.Error {
        PendingMucVoiceRequest? maybe_request = requests_by_id[id];
        if (maybe_request == null ||
                ((!) maybe_request).state != MucVoiceRequestState.PENDING) {
            throw new IOError.CANCELLED("The voice request is no longer pending");
        }
        if (muc_manager == null) {
            throw new IOError.NOT_CONNECTED("No MUC manager is available");
        }

        PendingMucVoiceRequest request = (!) maybe_request;
        MucManager manager = (!) muc_manager;
        MucManager.MucOwnerMutationContext? maybe_context =
            manager.capture_current_muc_context(request.account,
                request.room_jid);
        if (maybe_context == null) {
            remove_request(request);
            throw new IOError.NOT_CONNECTED(
                "The room is no longer joined on this account");
        }

        MucManager.MucOwnerMutationContext context = (!) maybe_context;
        if (!manager.has_role(context.own_jid, request.account) ||
                manager.get_role(context.own_jid, request.account) !=
                    Xep.Muc.Role.MODERATOR) {
            throw new IOError.PERMISSION_DENIED(
                "The current room role cannot grant this request");
        }

        // Visitor presence is allowed to be hidden by room configuration.
        // When it is visible, reject stale or nick-reuse state locally. When
        // it is hidden, the room-authored approval form remains authoritative.
        try {
            Jid occupant = request.room_jid.with_resource(request.nick);
            if (manager.is_current_occupant(request.account,
                    request.room_jid, occupant)) {
                if (manager.has_role(occupant, request.account) &&
                        manager.get_role(occupant, request.account) !=
                            Xep.Muc.Role.VISITOR) {
                    remove_request(request);
                    throw new IOError.CANCELLED(
                        "The requester is no longer a visitor in this room");
                }
                Jid? real_jid = manager.get_real_jid(occupant,
                    request.account);
                if (real_jid != null &&
                        !((!) real_jid).equals_bare(request.from_jid)) {
                    remove_request(request);
                    throw new IOError.PERMISSION_DENIED(
                        "The live occupant identity no longer matches the request");
                }
            }
        } catch (InvalidJidError e) {
            remove_request(request);
            throw new IOError.INVALID_ARGUMENT(
                "The requested room nickname is invalid");
        }

        begin_response(request);
        try {
            yield context.stream.get_module<Xep.Muc.Module>(
                Xep.Muc.Module.IDENTITY).respond_to_voice_request(
                    context.stream, request.room_jid, request.request_jid,
                    request.nick, allow, request.id);
        } catch (GLib.Error e) {
            if (requests_by_id[request.id] == request) {
                request.restore_pending();
                requests_changed(request.account, request.room_jid);
            }
            throw e;
        }
    }

    private void on_voice_request_received(Account account, Jid room_jid,
            Jid from_jid, string nick, string? stanza_id) {
        if (nick.strip() == "") return;
        Jid room = room_jid.bare_jid;
        Jid requester = from_jid.bare_jid;
        if (muc_manager != null) {
            MucManager manager = (!) muc_manager;
            if (!manager.is_joined(room, account)) return;
            try {
                Jid occupant = room.with_resource(nick);
                if (manager.has_role(occupant, account) &&
                        manager.get_role(occupant, account) !=
                            Xep.Muc.Role.VISITOR) return;
                Jid? real_jid = manager.get_real_jid(occupant, account);
                if (real_jid != null &&
                        !((!) real_jid).equals_bare(requester)) return;
            } catch (InvalidJidError e) {
                return;
            }
        }

        string key = request_key(account, room, requester, nick);
        PendingMucVoiceRequest? request = pending_by_key[key];
        if (request != null) {
            bool exact_retransmission = stanza_id != null &&
                ((!) request).source_stanza_id == stanza_id;
            if (exact_retransmission) {
                ((!) request).refresh(from_jid);
                return;
            }

            // Only the same stanza id proves a retransmission. A new stanza
            // from the same requester is a fresh request even if this client
            // never saw the intervening role presence (for example because
            // another moderator handled it while visitors were hidden by
            // presencebroadcast). Null ids are therefore never deduplicated.
            remove_request((!) request);
        }

        // Keep the exact JID supplied by the room for the approval form while
        // using its bare form only for stable request identity/deduplication.
        request = new PendingMucVoiceRequest(account, room, from_jid, nick,
            stanza_id);
        requests_by_id[((!) request).id] = (!) request;
        pending_by_key[key] = (!) request;
        request_received((!) request);
        requests_changed(account, room);
    }

    private void on_voice_request_response_failed(Account account, Jid room,
            string correlation_id, string condition, string? text) {
        PendingMucVoiceRequest? request = requests_by_id[correlation_id];
        if (request == null || !same_account(((!) request).account, account) ||
                !((!) request).room_jid.equals(room.bare_jid) ||
                !is_responding((!) request)) return;
        ((!) request).restore_pending();
        requests_changed(((!) request).account, ((!) request).room_jid);
        request_action_failed((!) request, condition, text);
    }

    private void on_voice_request_response_settled(Account account, Jid room,
            string correlation_id) {
        PendingMucVoiceRequest? request = requests_by_id[correlation_id];
        if (request == null || !same_account(((!) request).account, account) ||
                !((!) request).room_jid.equals(room.bare_jid) ||
                !is_responding((!) request)) return;
        remove_request((!) request);
    }

    private void on_own_voice_request_sent(Account account, Jid room,
            string correlation_id) {
        OwnMucVoiceRequest? request = get_own_request(account, room);
        if (request == null || ((!) request).id != correlation_id ||
                ((!) request).state != OwnMucVoiceRequestState.SENDING) {
            return;
        }
        ((!) request).mark_sent();
        own_request_changed(((!) request).account,
            ((!) request).room_jid, request);
    }

    private void on_own_voice_request_failed(Account account, Jid room,
            string correlation_id, string condition, string? text) {
        fail_own_request(account, room, correlation_id, condition, text);
    }

    private void on_occupant_role(Account account, Jid occupant,
            Xep.Muc.Role? role) {
        if (!occupant.is_full() ||
                (!has_requests_for_room(account, occupant.bare_jid) &&
                get_own_request(account, occupant.bare_jid) == null)) return;

        bool is_own = false;
        if (muc_manager != null) {
            Jid? own_jid = ((!) muc_manager).get_own_jid(
                occupant.bare_jid, account);
            is_own = own_jid != null && ((!) own_jid).equals(occupant);
        }
        reconcile_occupant_role(account, occupant, role, is_own);
    }

    private void reconcile_occupant_role(Account account, Jid occupant,
            Xep.Muc.Role? role, bool is_own) {
        if (is_own) {
            if (role == Xep.Muc.Role.PARTICIPANT ||
                    role == Xep.Muc.Role.MODERATOR) {
                clear_own_request(account, occupant.bare_jid);
            }
            if (role != Xep.Muc.Role.MODERATOR) {
                clear_pending_room(account, occupant.bare_jid);
            }
            return;
        }
        if (role == null) return;
        if (role != Xep.Muc.Role.VISITOR) {
            clear_nick(account, occupant.bare_jid, occupant.resourcepart);
            return;
        }

        if (muc_manager == null) return;
        Jid? real_jid = ((!) muc_manager).get_real_jid(occupant, account);
        if (real_jid != null) {
            clear_nick_identity_mismatches(account, occupant.bare_jid,
                occupant.resourcepart, ((!) real_jid).bare_jid.to_string());
        }
    }

    private void on_occupant_removed(Account account, Jid room,
            Jid occupant) {
        if (!has_requests_for_room(account, room) &&
                get_own_request(account, room) == null) return;
        if (muc_manager != null) {
            Jid? own_jid = ((!) muc_manager).get_own_jid(room, account);
            if (own_jid != null && ((!) own_jid).equals(occupant)) {
                clear_room(account, room);
                return;
            }
        }
        clear_occupant(account, room, occupant);
    }

    private void clear_nick_identity_mismatches(Account account, Jid room,
            string nick, string current_real_jid) {
        Jid real_jid;
        try {
            real_jid = new Jid(current_real_jid).bare_jid;
        } catch (InvalidJidError e) {
            clear_nick(account, room, nick);
            return;
        }
        var stale = matching_requests(account, room, nick);
        foreach (PendingMucVoiceRequest request in stale) {
            if (!request.from_jid.equals_bare(real_jid)) {
                remove_request(request);
            }
        }
    }

    private void clear_occupant(Account account, Jid room, Jid occupant) {
        if (!occupant.is_full() ||
                !occupant.bare_jid.equals(room.bare_jid)) return;
        clear_nick(account, room, occupant.resourcepart);
    }

    private void clear_nick(Account account, Jid room, string nick) {
        foreach (PendingMucVoiceRequest request in
                matching_requests(account, room, nick)) {
            remove_request(request);
        }
    }

    private ArrayList<PendingMucVoiceRequest> matching_requests(
            Account account, Jid room, string nick) {
        var matches = new ArrayList<PendingMucVoiceRequest>();
        foreach (PendingMucVoiceRequest request in requests_by_id.values) {
            if (same_account(request.account, account) &&
                    request.room_jid.equals(room.bare_jid) &&
                    request.nick == nick) {
                matches.add(request);
            }
        }
        return matches;
    }

    private bool has_requests_for_room(Account account, Jid room) {
        foreach (PendingMucVoiceRequest request in requests_by_id.values) {
            if (same_account(request.account, account) &&
                    request.room_jid.equals(room.bare_jid)) return true;
        }
        return false;
    }

    private void clear_room(Account account, Jid room) {
        clear_pending_room(account, room);
        clear_own_request(account, room);
    }

    private void clear_pending_room(Account account, Jid room) {
        var stale = new ArrayList<PendingMucVoiceRequest>();
        foreach (PendingMucVoiceRequest request in requests_by_id.values) {
            if (same_account(request.account, account) &&
                    request.room_jid.equals(room.bare_jid)) {
                stale.add(request);
            }
        }
        foreach (PendingMucVoiceRequest request in stale) {
            remove_request(request);
        }
    }

    private void clear_account(Account account) {
        var stale = new ArrayList<PendingMucVoiceRequest>();
        foreach (PendingMucVoiceRequest request in requests_by_id.values) {
            if (same_account(request.account, account)) stale.add(request);
        }
        foreach (PendingMucVoiceRequest request in stale) {
            remove_request(request);
        }

        var own_stale = new ArrayList<OwnMucVoiceRequest>();
        foreach (OwnMucVoiceRequest request in own_requests_by_room.values) {
            if (same_account(request.account, account)) {
                own_stale.add(request);
            }
        }
        foreach (OwnMucVoiceRequest request in own_stale) {
            clear_own_request(request.account, request.room_jid);
        }
    }

    private OwnMucVoiceRequest? begin_own_request(Account account, Jid room,
            string correlation_id) {
        OwnMucVoiceRequest? current = get_own_request(account, room);
        if (current != null && ((!) current).state ==
                OwnMucVoiceRequestState.SENDING) return null;

        var request = new OwnMucVoiceRequest(account, room,
            correlation_id);
        own_requests_by_room[own_request_key(account, room)] = request;
        own_request_changed(account, request.room_jid, request);
        return request;
    }

    private void fail_own_request(Account account, Jid room,
            string correlation_id, string condition, string? text) {
        OwnMucVoiceRequest? request = get_own_request(account, room);
        if (request == null || ((!) request).id != correlation_id) return;
        if (((!) request).state == OwnMucVoiceRequestState.FAILED) return;
        ((!) request).mark_failed(condition, text);
        own_request_changed(((!) request).account,
            ((!) request).room_jid, request);
        own_request_failed(((!) request).account,
            ((!) request).room_jid, condition, text);
    }

    private void clear_own_request(Account account, Jid room) {
        string key = own_request_key(account, room);
        OwnMucVoiceRequest? request = own_requests_by_room[key];
        if (request == null) return;
        own_requests_by_room.unset(key);
        own_request_changed(((!) request).account,
            ((!) request).room_jid, null);
    }

    private void remove_request(PendingMucVoiceRequest request) {
        if (requests_by_id[request.id] != request) return;
        requests_by_id.unset(request.id);
        string key = request_key(request.account, request.room_jid,
            request.from_jid, request.nick);
        if (pending_by_key[key] == request) pending_by_key.unset(key);
        request_removed(request);
        requests_changed(request.account, request.room_jid);
    }

    private void begin_response(PendingMucVoiceRequest request) {
        if (requests_by_id[request.id] != request ||
                request.state != MucVoiceRequestState.PENDING) return;
        request.begin_response();
        request_response_started(request);
        requests_changed(request.account, request.room_jid);
    }

    private static bool same_account(Account left, Account right) {
        return left.id == right.id && left.bare_jid.equals(right.bare_jid);
    }

    private static string request_key(Account account, Jid room, Jid from,
            string nick) {
        return "%d|%s|%s|%s".printf(account.id,
            room.bare_jid.to_string(), from.bare_jid.to_string(), nick);
    }

    private static string own_request_key(Account account, Jid room) {
        return "%d|%s|%s".printf(account.id,
            account.bare_jid.to_string(), room.bare_jid.to_string());
    }

    internal PendingMucVoiceRequest receive_for_tests(Account account,
            Jid room, Jid from, string nick, string? stanza_id = null) {
        on_voice_request_received(account, room, from, nick, stanza_id);
        return (!) pending_by_key[request_key(account, room, from, nick)];
    }

    internal void role_for_tests(Account account, Jid occupant,
            Xep.Muc.Role? role, bool is_own = false) {
        if (occupant.is_full()) {
            reconcile_occupant_role(account, occupant, role, is_own);
        }
    }

    internal void confirmed_role_for_tests(Account account, Jid occupant,
            Xep.Muc.Role role) {
        if (occupant.is_full()) {
            reconcile_occupant_role(account, occupant, role, false);
        }
    }

    internal void room_reset_for_tests(Account account, Jid room) {
        clear_room(account, room);
    }

    internal void response_failure_for_tests(Account account, Jid room,
            string correlation_id, string condition, string? text) {
        on_voice_request_response_failed(account, room, correlation_id,
            condition, text);
    }

    internal void responding_for_tests(PendingMucVoiceRequest request) {
        begin_response(request);
    }

    internal void response_settled_for_tests(Account account, Jid room,
            string correlation_id) {
        on_voice_request_response_settled(account, room, correlation_id);
    }

    internal bool own_request_start_for_tests(Account account, Jid room,
            string correlation_id) {
        return begin_own_request(account, room, correlation_id) != null;
    }

    internal void own_request_sent_for_tests(Account account, Jid room,
            string correlation_id) {
        on_own_voice_request_sent(account, room, correlation_id);
    }

    internal void own_request_failure_for_tests(Account account, Jid room,
            string correlation_id, string condition, string? text) {
        on_own_voice_request_failed(account, room, correlation_id,
            condition, text);
    }

    internal void left_for_tests(Account account, Jid room) {
        clear_room(account, room);
    }

    internal void joined_for_tests(Account account, Jid room) {
        clear_room(account, room);
    }

    internal void disconnected_for_tests(Account account) {
        clear_account(account);
    }

    internal void account_removed_for_tests(Account account) {
        clear_account(account);
    }

    private static bool is_responding(PendingMucVoiceRequest request) {
        return request.state == MucVoiceRequestState.RESPONDING;
    }
}

}

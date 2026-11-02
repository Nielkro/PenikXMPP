using Gee;
using Xmpp;
using Xmpp.Xep;

namespace Dino.Plugins.GoogleWebrtc {

/**
 * Development-only router for XEP-0353-gated libwebrtc sessions.
 *
 * It deliberately routes only sessions that were explicitly registered by
 * local full JID and SID. Unknown Jingle IQs must remain untouched so the
 * existing production Xep.Jingle.Module + GStreamer RTP path can keep owning
 * its sessions until the libwebrtc engine is intentionally selected.
 */
public class EngineJmiSessionRouter : Object {
    private HashMap<string, HashMap<string, EngineJmiSession>> sessions_by_local =
        new HashMap<string, HashMap<string, EngineJmiSession>>();
    private ArrayList<EngineMujiGroupSession> muji_groups =
        new ArrayList<EngineMujiGroupSession>();

    public void add(EngineJmiSession session) throws JmiError {
        string local_key = session.local_full_jid.to_string();
        HashMap<string, EngineJmiSession>? local_sessions = sessions_by_local[local_key];
        if (local_sessions == null) {
            local_sessions = new HashMap<string, EngineJmiSession>();
            sessions_by_local[local_key] = (!) local_sessions;
        }
        if (((!) local_sessions).has_key(session.sid)) {
            throw new JmiError.BAD_STATE("A Google/libwebrtc JMI session with this local JID and SID is already registered");
        }
        ((!) local_sessions)[session.sid] = session;
    }

    public bool contains(Jid local_full_jid, string sid) {
        return lookup(local_full_jid, sid) != null;
    }

    public EngineJmiSession? lookup(Jid local_full_jid, string sid) {
        HashMap<string, EngineJmiSession>? local_sessions = sessions_by_local[local_full_jid.to_string()];
        if (local_sessions == null) return null;
        return ((!) local_sessions)[sid];
    }

    public bool remove(EngineJmiSession session) {
        string local_key = session.local_full_jid.to_string();
        HashMap<string, EngineJmiSession>? local_sessions = sessions_by_local[local_key];
        if (local_sessions == null) return false;
        bool removed = ((!) local_sessions).unset(session.sid);
        if (((!) local_sessions).size == 0) {
            sessions_by_local.unset(local_key);
        }
        return removed;
    }

    public void add_muji_group(EngineMujiGroupSession group) throws JmiError {
        foreach (EngineMujiGroupSession existing in muji_groups) {
            if (existing.local_full_jid.equals(group.local_full_jid) &&
                    existing.room_jid.equals(group.room_jid)) {
                throw new JmiError.BAD_STATE(
                    "A Google/libwebrtc MUJI group for this local JID and room is already registered");
            }
        }
        muji_groups.add(group);
    }

    public bool remove_muji_group(EngineMujiGroupSession group) {
        return muji_groups.remove(group);
    }

    public bool route_proceed(
            Jid from,
            Jid to,
            string sid,
            out EngineJingleWireSession? wire_session) throws Error {
        wire_session = null;
        EngineJmiSession? session = lookup(to, sid);
        if (session == null) return false;
        wire_session = ((!) session).handle_proceed(from, to, sid);
        return true;
    }

    public bool route_jingle_iq_set(
            Jid local_full_jid,
            Iq.Stanza iq,
            out EngineJingleWireSession? wire_session) throws Error {
        wire_session = null;
        string? sid = get_jingle_sid(iq);
        if (sid == null) return false;

        EngineJmiSession? session = lookup(local_full_jid, (!) sid);
        EngineMujiGroupSession? claimed_group = null;
        if (session == null) {
            EngineMujiGroupSession? group = find_expected_muji_group(local_full_jid, iq);
            if (group == null) return false;
            session = ((!) group).claim_incoming(iq, (!) sid);
            claimed_group = group;
        }

        try {
            wire_session = ((!) session).handle_jingle_iq_set(iq);
        } catch (Error e) {
            if (claimed_group != null) {
                ((!) claimed_group).abort_incoming_claim(
                    (!) session, e.message);
            }
            throw e;
        }
        if (claimed_group != null) {
            ((!) claimed_group).complete_incoming_claim((!) session);
        }
        remove_if_ended((!) session);
        return true;
    }

    public bool owns_jingle_iq_set(Jid local_full_jid, Iq.Stanza iq) {
        string? sid = get_jingle_sid(iq);
        if (sid == null) return false;
        if (contains(local_full_jid, (!) sid)) return true;
        return find_expected_muji_group(local_full_jid, iq) != null;
    }

    internal bool reject_jingle_iq_set(Jid local_full_jid,
            Iq.Stanza iq, string message) {
        string? sid = get_jingle_sid(iq);
        if (sid == null || iq.from == null ||
                ((!) iq.from).resourcepart == null ||
                !EngineJmiIqInterceptor.recipient_matches_local(local_full_jid, iq.to)) return false;
        EngineJmiSession? session = lookup(local_full_jid, (!) sid);
        if (session != null) {
            // A foreign request must not retire another resource's registered
            // call merely by copying its SID onto an invalid fingerprint.
            if (!((!) session).peer_jid.equals((!) iq.from)) return false;
            remove((!) session);
            ((!) session).report_start_failure(message);
            ((!) session).close();
            return true;
        }
        EngineMujiGroupSession? group = find_expected_muji_group(local_full_jid, iq);
        return group != null && ((!) group).reject_expected_incoming(
            (!) iq.from, (!) sid, message);
    }

    public bool terminate(
            Jid local_full_jid,
            string sid,
            string? reason_name = null,
            string? reason_text = null) throws Error {
        EngineJmiSession? session = lookup(local_full_jid, sid);
        if (session == null) return false;
        ((!) session).terminate(reason_name, reason_text);
        remove_if_ended((!) session);
        return true;
    }

    private void remove_if_ended(EngineJmiSession session) {
        if (session.jmi_state == JmiState.ENDED ||
                session.jmi_state == JmiState.REJECTED ||
                session.jmi_state == JmiState.RETRACTED) {
            remove(session);
        }
    }

    private EngineMujiGroupSession? find_expected_muji_group(
            Jid local_full_jid, Iq.Stanza iq) {
        if (iq.type_ != Iq.Stanza.TYPE_SET || iq.from == null) return null;
        Jid peer_full_jid = (!) iq.from;
        if (peer_full_jid.resourcepart == null) return null;
        if (iq.to != null && !((!) iq.to).equals(local_full_jid)) return null;

        StanzaNode? jingle = iq.stanza.get_subnode("jingle", Jingle.NS_URI);
        if (jingle == null || ((!) jingle).get_attribute("action") != "session-initiate") {
            return null;
        }
        string? sid = ((!) jingle).get_attribute("sid");
        if (sid == null || ((!) sid).strip() == "") return null;

        Gee.List<StanzaNode> muji_nodes = ((!) jingle).get_subnodes("muji", Muji.NS_URI);
        if (muji_nodes.size != 1) return null;
        string? room_value = muji_nodes[0].get_attribute("room");
        if (room_value == null || ((!) room_value).strip() == "") return null;

        Jid room_jid;
        try {
            room_jid = new Jid((!) room_value);
        } catch (InvalidJidError e) {
            return null;
        }
        if (room_jid.resourcepart != null) return null;

        foreach (EngineMujiGroupSession group in muji_groups) {
            if (group.expects_incoming(
                    local_full_jid, peer_full_jid, room_jid, (!) sid)) {
                return group;
            }
        }
        return null;
    }

    private static string? get_jingle_sid(Iq.Stanza iq) {
        if (iq.type_ != Iq.Stanza.TYPE_SET) return null;
        StanzaNode? jingle = iq.stanza.get_subnode("jingle", Jingle.NS_URI);
        if (jingle == null) return null;
        return ((!) jingle).get_attribute("sid");
    }
}

}

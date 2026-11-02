using Xmpp;
using Xmpp.Xep;

namespace Dino.Plugins.GoogleWebrtc {

/**
 * Development-only IQ interceptor for the XEP-0353-gated libwebrtc route.
 *
 * The interceptor is intentionally conservative: it only consumes Jingle IQ set
 * stanzas whose local full JID and SID are already owned by
 * EngineJmiSessionRouter. All unknown SIDs return false so Xmpp.Iq.Module can
 * continue into the existing production Xep.Jingle.Module handler.
 */
public class EngineJmiIqInterceptor : Object, Iq.Interceptor {
    public EngineJmiSessionRouter router { get; private set; }

    public EngineJmiIqInterceptor(EngineJmiSessionRouter router) {
        this.router = router;
    }

    public bool owns_iq_set(Jid local_full_jid, Iq.Stanza iq) {
        if (!recipient_matches_local(local_full_jid, iq.to)) return false;
        return router.owns_jingle_iq_set(local_full_jid, iq);
    }

    public bool route_iq_set_for_local_jid(Jid local_full_jid, Iq.Stanza iq) throws Error {
        if (!owns_iq_set(local_full_jid, iq)) return false;

        EngineJingleWireSession? wire_session = null;
        return router.route_jingle_iq_set(local_full_jid, iq, out wire_session);
    }

    public void on_iq_request_rejected(XmppStream stream, Iq.Stanza iq) {
        Jid? local_full_jid = resolve_local_full_jid(stream, iq);
        if (local_full_jid == null) return;
        // Security filters run before an incoming engine leg is claimed. A
        // refused expected MUJI peer still needs its normal failure event so
        // the call owner can remove the waiting participant without media.
        router.reject_jingle_iq_set((!) local_full_jid, iq,
            GLib.dgettext("dino", "Could not establish a secure connection"));
    }

    public async bool try_handle_iq_set(XmppStream stream, Iq.Stanza iq) {
        Jid? local_full_jid = resolve_local_full_jid(stream, iq);
        if (local_full_jid == null) return false;

        bool owned = owns_iq_set((!) local_full_jid, iq);
        if (!owned) return false;

        try {
            return route_iq_set_for_local_jid((!) local_full_jid, iq);
        } catch (Error e) {
            StanzaNode? jingle = iq.stanza.get_subnode("jingle", Jingle.NS_URI);
            string sid = jingle != null
                ? ((!) jingle).get_attribute("sid") ?? "(missing)"
                : "(missing)";
            EngineJmiSession? session = router.lookup((!) local_full_jid, sid);
            warning(
                "Google/libwebrtc owned Jingle IQ failed: action=%s sid=%s from=%s local=%s jmi_state=%s signaling_state=%s: %s",
                jingle != null ? ((!) jingle).get_attribute("action") ?? "(missing)" : "(missing)",
                sid,
                iq.from != null ? ((!) iq.from).to_string() : "(missing)",
                ((!) local_full_jid).to_string(),
                session != null ? ((!) session).jmi_state.to_string() : "(missing)",
                session != null && ((!) session).wire_session != null
                    ? ((!) ((!) session).wire_session).state.to_string() : "(not-created)",
                e.message);
            return true;
        }
    }

    internal static Jid? resolve_local_full_jid(XmppStream stream, Iq.Stanza iq) {
        // The router is shared across accounts. Only the stream's bound JID
        // identifies the local account; an explicit IQ recipient cannot select
        // a session registered on another stream.
        Bind.Flag? bind = stream.get_flag(Bind.Flag.IDENTITY);
        if (bind == null) return null;

        Bind.Flag bind_flag = (!) bind;
        if (bind_flag.my_jid == null) return null;

        Jid my_jid = (!) bind_flag.my_jid;
        if (my_jid.resourcepart == null) return null;
        if (!recipient_matches_local(my_jid, iq.to)) return null;
        return my_jid;
    }

    internal static bool recipient_matches_local(Jid local_full_jid, Jid? to) {
        if (to == null) return true;
        if (((!) to).resourcepart == null) {
            return ((!) to).bare_jid.equals(local_full_jid.bare_jid);
        }
        return ((!) to).equals(local_full_jid);
    }

}

}

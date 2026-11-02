using Gee;
namespace Xmpp.Xep.Muji {

    public const string NS_URI = "urn:xmpp:jingle:muji:0";
    public const string LIVENESS_NS_URI = "urn:dinox:muji:liveness:0";

    /**
     * Backend-neutral source of RTP capabilities advertised in MUJI presence.
     *
     * The MUJI module owns room presence and intersection semantics, but it
     * must not select a concrete media engine.  The selected call engine
     * supplies the payloads it can actually negotiate on its peer sessions.
     */
    public interface CodecProvider : Object {
        public abstract async Gee.List<Xep.JingleRtp.PayloadType> get_supported_payloads(
            string media) throws Error;
        public abstract async bool is_payload_supported(
            string media, Xep.JingleRtp.PayloadType payload_type) throws Error;
    }

    /** Atomically prepares media ownership before the initial ready presence. */
    public delegate void ReadyPresenceCommit(GroupCall group_call) throws Error;

    /** Claims an explicit join intent immediately before our preparing presence. */
    public delegate void PreparingPresenceCommit(GroupCall group_call) throws Error;

    public enum CodecAvailability {
        AVAILABLE,
        OPTIONAL_UNAVAILABLE,
        REQUIRED_UNAVAILABLE
    }

    /**
     * Result of one backend-neutral MUJI media capability selection.
     *
     * Audio is mandatory for the current call implementation.  Video is
     * optional and may be dropped when no common codec exists.
     */
    public class CodecSelection : Object {
        public Gee.List<Xep.JingleRtp.PayloadType> payload_types { get; private set; }
        public CodecAvailability availability { get; private set; }

        internal CodecSelection(
                Gee.List<Xep.JingleRtp.PayloadType> payload_types,
                CodecAvailability availability) {
            this.payload_types = payload_types;
            this.availability = availability;
        }
    }

    /** One XEP-0272 conference content identity plus its codec result. */
    private class ConferenceContentSelection : Object {
        public string? content_name { get; private set; }
        public CodecSelection codec_selection { get; private set; }

        public ConferenceContentSelection(
                string? content_name,
                CodecSelection codec_selection) {
            this.content_name = content_name;
            this.codec_selection = codec_selection;
        }
    }

    /**
     * Applies the media-independent provider contract and the MUJI required
     * media policy. Provider failures deliberately propagate to the caller.
     */
    public class CodecNegotiation : Object {
        public static async CodecSelection select(
                CodecProvider codec_provider,
                string media,
                Gee.List<Xep.JingleRtp.PayloadType>? remote_payload_types = null)
                throws Error {
            Gee.List<Xep.JingleRtp.PayloadType> local_payload_types =
                yield codec_provider.get_supported_payloads(media);
            Gee.List<Xep.JingleRtp.PayloadType> supported =
                new ArrayList<Xep.JingleRtp.PayloadType>(
                    Xep.JingleRtp.PayloadType.equals_func);
            if (payload_map_is_well_formed(local_payload_types)) {
                if (remote_payload_types == null) {
                    foreach (Xep.JingleRtp.PayloadType payload_type in
                            local_payload_types) {
                        supported.add(payload_type.clone());
                    }
                } else if (payload_map_is_well_formed(
                        (!) remote_payload_types)) {
                    supported = yield select_remote_payload_map(
                        codec_provider, media, local_payload_types,
                        (!) remote_payload_types);
                }
            }

            CodecAvailability availability = CodecAvailability.AVAILABLE;
            if (supported.is_empty) {
                availability = media == "video"
                    ? CodecAvailability.OPTIONAL_UNAVAILABLE
                    : CodecAvailability.REQUIRED_UNAVAILABLE;
            }
            return new CodecSelection(supported, availability);
        }

        /** A conference PT map is atomic: dependencies and IDs cannot dangle. */
        public static bool payload_map_is_well_formed(
                Gee.List<Xep.JingleRtp.PayloadType> payload_types) {
            var by_id = new HashMap<int, Xep.JingleRtp.PayloadType>();
            foreach (Xep.JingleRtp.PayloadType payload_type in payload_types) {
                if (!payload_type.id_valid || payload_type.id > 127 ||
                        payload_type.name == null ||
                        ((!) payload_type.name).strip() == "" ||
                        by_id.has_key((int) payload_type.id)) {
                    return false;
                }
                by_id[(int) payload_type.id] = payload_type;
            }
            foreach (Xep.JingleRtp.PayloadType payload_type in payload_types) {
                string? apt = payload_type.parameters["apt"];
                if (!is_rtx_payload(payload_type)) {
                    if (apt != null) return false;
                    continue;
                }
                int apt_id = -1;
                if (apt == null ||
                        !int.try_parse((!) apt, out apt_id, null, 10) ||
                        apt_id == (int) payload_type.id ||
                        !by_id.has_key(apt_id) ||
                        is_rtx_payload(by_id[apt_id])) {
                    return false;
                }
            }
            return true;
        }

        /**
         * Checks a late participant against the already frozen conference
         * mapping. The frozen mapping was selected through CodecProvider
         * before our Ready presence, so repeating asynchronous provider work
         * here would only create a Presence/session-initiate race.
         */
        public static CodecSelection select_from_frozen_payload_map(
                string media,
                Gee.List<Xep.JingleRtp.PayloadType> frozen_payload_types,
                Gee.List<Xep.JingleRtp.PayloadType> remote_payload_types) {
            var supported = new ArrayList<Xep.JingleRtp.PayloadType>(
                Xep.JingleRtp.PayloadType.equals_func);
            if (payload_map_is_well_formed(frozen_payload_types) &&
                    payload_map_is_well_formed(remote_payload_types)) {
                foreach (Xep.JingleRtp.PayloadType payload_type in
                        frozen_payload_types) {
                    if (remote_payload_types.contains(payload_type)) {
                        supported.add(payload_type.clone());
                    }
                }
                if (!payload_map_is_well_formed(supported)) {
                    supported.clear();
                }
            }

            CodecAvailability availability = supported.is_empty
                ? media == "video"
                    ? CodecAvailability.OPTIONAL_UNAVAILABLE
                    : CodecAvailability.REQUIRED_UNAVAILABLE
                : CodecAvailability.AVAILABLE;
            return new CodecSelection(supported, availability);
        }

        private static async Gee.List<Xep.JingleRtp.PayloadType>
                select_remote_payload_map(
                    CodecProvider codec_provider,
                    string media,
                    Gee.List<Xep.JingleRtp.PayloadType> local_payload_types,
                    Gee.List<Xep.JingleRtp.PayloadType> remote_payload_types)
                    throws Error {
            var accepted_ids = new HashSet<int>();
            var local_by_remote_id =
                new HashMap<int, Xep.JingleRtp.PayloadType>();
            // Primaries are decided first, independently of stanza order.
            foreach (Xep.JingleRtp.PayloadType remote_payload in
                    remote_payload_types) {
                if (is_rtx_payload(remote_payload)) continue;
                Xep.JingleRtp.PayloadType? local_payload =
                    select_unique_local_payload(
                        remote_payload, local_payload_types, -1);
                if (local_payload == null ||
                        !(yield codec_provider.is_payload_supported(
                            media, remote_payload))) {
                    continue;
                }
                accepted_ids.add((int) remote_payload.id);
                local_by_remote_id[(int) remote_payload.id] =
                    (!) local_payload;
            }

            // RTX is accepted only as a pair with the already accepted
            // primary and the corresponding local RTX->primary relation.
            foreach (Xep.JingleRtp.PayloadType remote_payload in
                    remote_payload_types) {
                if (!is_rtx_payload(remote_payload)) continue;
                int remote_apt_id = -1;
                string? remote_apt = remote_payload.parameters["apt"];
                if (remote_apt == null ||
                        !int.try_parse((!) remote_apt, out remote_apt_id,
                            null, 10) ||
                        !accepted_ids.contains(remote_apt_id)) {
                    continue;
                }
                Xep.JingleRtp.PayloadType local_primary =
                    local_by_remote_id[remote_apt_id];
                Xep.JingleRtp.PayloadType? local_rtx =
                    select_unique_local_payload(
                        remote_payload, local_payload_types,
                        (int) local_primary.id);
                if (local_rtx == null ||
                        !(yield codec_provider.is_payload_supported(
                            media, remote_payload))) {
                    continue;
                }
                accepted_ids.add((int) remote_payload.id);
            }

            var selected = new ArrayList<Xep.JingleRtp.PayloadType>(
                Xep.JingleRtp.PayloadType.equals_func);
            foreach (Xep.JingleRtp.PayloadType remote_payload in
                    remote_payload_types) {
                if (accepted_ids.contains((int) remote_payload.id)) {
                    selected.add(remote_payload.clone());
                }
            }
            return selected;
        }

        private static Xep.JingleRtp.PayloadType? select_unique_local_payload(
                Xep.JingleRtp.PayloadType remote_payload,
                Gee.List<Xep.JingleRtp.PayloadType> local_payload_types,
                int expected_local_apt) {
            var candidates = new ArrayList<Xep.JingleRtp.PayloadType>();
            var exact_candidates = new ArrayList<Xep.JingleRtp.PayloadType>();
            foreach (Xep.JingleRtp.PayloadType local_payload in
                    local_payload_types) {
                if (!codec_identity_matches(remote_payload, local_payload)) {
                    continue;
                }
                string? local_apt = local_payload.parameters["apt"];
                if (expected_local_apt < 0) {
                    if (local_apt != null) continue;
                } else {
                    int local_apt_id = -1;
                    if (local_apt == null ||
                            !int.try_parse((!) local_apt, out local_apt_id,
                                null, 10) ||
                            local_apt_id != expected_local_apt) {
                        continue;
                    }
                }
                candidates.add(local_payload);
                if (parameter_maps_equal_except_apt(
                        remote_payload, local_payload)) {
                    exact_candidates.add(local_payload);
                }
            }
            if (exact_candidates.size == 1) return exact_candidates[0];
            if (exact_candidates.size > 1 || candidates.size != 1) return null;
            return candidates[0];
        }

        private static bool codec_identity_matches(
                Xep.JingleRtp.PayloadType left,
                Xep.JingleRtp.PayloadType right) {
            if (left.name == null || right.name == null) return false;
            return ((!) left.name).strip().ascii_down() ==
                    ((!) right.name).strip().ascii_down() &&
                left.clockrate == right.clockrate &&
                left.channels == right.channels;
        }

        private static bool parameter_maps_equal_except_apt(
                Xep.JingleRtp.PayloadType left,
                Xep.JingleRtp.PayloadType right) {
            int left_size = left.parameters.size -
                (left.parameters.has_key("apt") ? 1 : 0);
            int right_size = right.parameters.size -
                (right.parameters.has_key("apt") ? 1 : 0);
            if (left_size != right_size) return false;
            foreach (var entry in left.parameters.entries) {
                if (entry.key == "apt") continue;
                if (!right.parameters.has_key(entry.key) ||
                        right.parameters[entry.key] != entry.value) {
                    return false;
                }
            }
            return true;
        }

        public static bool is_rtx_payload(
                Xep.JingleRtp.PayloadType payload_type) {
            return payload_type.name != null &&
                ((!) payload_type.name).strip().ascii_down() == "rtx";
        }
    }

    public class Module : XmppStreamModule {
        public static ModuleIdentity<Module> IDENTITY = new ModuleIdentity<Module>(NS_URI, "0272_muji");
        private const uint SELF_PRESENCE_ECHO_TIMEOUT_SECONDS = 10;

        public async GroupCall? join_call(
                XmppStream stream,
                Jid muc_jid,
                bool video,
                CodecProvider? codec_provider = null,
                Gee.Map<string, string>? preferred_content_names = null,
                Gee.Map<string, Gee.List<Xep.JingleRtp.PayloadType>>?
                    preferred_payload_types = null,
                ReadyPresenceCommit? ready_presence_commit = null,
                Cancellable? join_cancellable = null,
                bool require_existing_call = false,
                bool require_joined_room = false,
                PreparingPresenceCommit? preparing_presence_commit = null,
                bool take_joined_occupancy = false) {
            CodecProvider? selected_codec_provider = codec_provider;
            if (selected_codec_provider == null) {
                selected_codec_provider = stream.get_flag(Flag.IDENTITY).codec_provider;
            }
            if (selected_codec_provider == null) {
                warning("Cannot join MUJI call without a media codec provider");
                return null;
            }
            if ((preferred_content_names == null) !=
                    (preferred_payload_types == null)) {
                warning("Cannot join MUJI with an incomplete preferred conference mapping");
                return null;
            }
            string preparing_generation = Uuid.string_random();
            StanzaNode initial_muji_node = new StanzaNode.build("muji", NS_URI)
                    .add_self_xmlns()
                    .put_node(new StanzaNode.build("preparing", NS_URI))
                    .put_node(new StanzaNode.build(
                            "generation", LIVENESS_NS_URI)
                        .add_self_xmlns()
                        .put_attribute("id", preparing_generation));

            var group_call = new GroupCall(
                muc_jid, (!) selected_codec_provider, video);
            Flag flag = stream.get_flag(Flag.IDENTITY);
            Muc.Flag muc_flag = stream.get_flag(Muc.Flag.IDENTITY);
            string? existing_nick = muc_flag.get_muc_nick(muc_jid);
            // An existing chat room may only lend its confirmed occupancy.
            // Losing that nick must never fall through to a new MUC enter.
            if ((require_joined_room && existing_nick == null) ||
                    (take_joined_occupancy && !require_joined_room)) return null;
            GroupCall? existing_group_call = flag.calls.get(muc_jid);
            if (existing_group_call != null &&
                    !((!) existing_group_call).left) {
                warning("[%s] Refusing to replace a live MUJI join for %s",
                    stream.get_flag(Bind.Flag.IDENTITY).my_jid.to_string(),
                    muc_jid.to_string());
                return null;
            }
            flag.calls[muc_jid] = group_call;
            group_call.bind_join_cancellation(stream, join_cancellable);
            if (group_call.left) return null;
            if (require_existing_call && existing_nick == null) {
                group_call.require_current_join_presences();
            }
            // The room may already contain cached MUJI presences. Register
            // them before MUC enter yields so facet-removal presences can
            // invalidate every join/preparing continuation immediately.
            group_call.capture_muji_membership_snapshot(
                get_other_presences(stream, muc_jid));

            if (existing_nick != null) {
                group_call.our_nick = (!) existing_nick;
                group_call.reuses_muc_occupancy = !take_joined_occupancy;
                debug("[%s] MUJI preparing in joined MUC as %s",
                    stream.get_flag(Bind.Flag.IDENTITY).my_jid.to_string(),
                    group_call.our_nick);
                if (!(yield announce_preparing_in_joined_room(stream,
                        group_call, initial_muji_node,
                        preparing_generation, preparing_presence_commit))) {
                    if (!group_call.left) {
                        warning("[%s] MUJI preparing presence was not echoed by joined MUC %s",
                            stream.get_flag(Bind.Flag.IDENTITY).my_jid.to_string(),
                            muc_jid.to_string());
                    }
                    group_call.leave(stream);
                    return null;
                }
            } else {
                // A dedicated MUJI room still needs a normal MUC join. Retry
                // only nick conflicts; every other failure is authoritative.
                Xep.Muc.JoinResult? result = null;
                for (int attempt = 0; attempt < 3; attempt++) {
                    group_call.our_nick = "%08x".printf(Random.next_int());
                    debug("[%s] MUJI joining as %s (attempt %d)", stream.get_flag(Bind.Flag.IDENTITY).my_jid.to_string(), group_call.our_nick, attempt + 1);
                    result = yield stream.get_module<Muc.Module>(Muc.Module.IDENTITY).enter(stream, muc_jid, group_call.our_nick, null, null, false, initial_muji_node);
                    if (!is_current_group_call(stream, group_call)) return null;
                    if (result != null && result.muc_error == Muc.MucEnterError.NICK_CONFLICT) {
                        debug("[%s] MUJI nick conflict for %s, retrying", stream.get_flag(Bind.Flag.IDENTITY).my_jid.to_string(), group_call.our_nick);
                        continue;
                    }
                    break;
                }
                if (!group_call.bind_confirmed_muc_occupancy(result)) {
                    string detail = "no join result";
                    if (result != null && ((!) result).muc_error != null) {
                        detail = "MUC error " + ((!) ((!) result).muc_error).to_string();
                    } else if (result != null && ((!) result).stanza_error != null) {
                        detail = "stanza error " + (!) ((!) result).stanza_error;
                    }
                    warning("[%s] MUJI join failed after retries for %s (%s)",
                        stream.get_flag(Bind.Flag.IDENTITY).my_jid.to_string(),
                        muc_jid.to_string(), detail);
                    group_call.leave(stream);
                    return null;
                }
                if (require_existing_call && ((!) result).newly_created) {
                    // A deleted call room must never become a new call during rejoin.
                    // The confirmed nick owns this accidental occupancy, so leave it.
                    group_call.leave(stream);
                    return null;
                }
            }
            debug("[%s] MUJI joining as %s done", stream.get_flag(Bind.Flag.IDENTITY).my_jid.to_string(), group_call.our_nick);

            // Nick ordering elects the initiator independently of arrival order.
            // Do not wait for other preparing peers: simultaneous joiners would
            // otherwise wait on one another before either can advertise READY.
            if (!is_current_group_call(stream, group_call)) return null;
            if (require_existing_call || require_joined_room) {
                // Entering a MUC invalidates earlier discovery. Recheck the
                // confirmed occupancy before selecting codecs or publishing READY.
                bool room_exists = yield stream.get_module<Muc.Module>(Muc.Module.IDENTITY)
                    .query_room_info(stream, muc_jid);
                if (!is_current_group_call(stream, group_call)) return null;
                Muc.Flag? current_muc = stream.get_flag(Muc.Flag.IDENTITY);
                if (!room_exists || current_muc == null ||
                        !((!) current_muc).has_current_room_features(muc_jid) ||
                        !((!) current_muc).has_room_feature(muc_jid, Muc.Feature.MEMBERS_ONLY) ||
                        !((!) current_muc).has_room_feature(muc_jid, Muc.Feature.NON_ANONYMOUS) ||
                        ((!) current_muc).get_real_jid_visibility(muc_jid) != Muc.RealJidVisibility.ANYONE) {
                    group_call.leave(stream);
                    return null;
                }
            }
            StanzaNode? muji_node = null;
            while (is_current_group_call(stream, group_call)) {
                Gee.List<Presence.Stanza> current_muji_presences =
                    get_other_presences(stream, muc_jid);
                Gee.List<Presence.Stanza> other_presences =
                    get_ready_presences(stream, muc_jid);
                uint membership_generation =
                    group_call.capture_muji_membership_snapshot(
                        current_muji_presences);
                var selections = new HashMap<string, CodecSelection>();
                var selected_content_names = new HashMap<string, string>();
                bool membership_changed = false;

                foreach (string media in video
                        ? new string[] { "audio", "video" }
                        : new string[] { "audio" }) {
                    ConferenceContentSelection content_selection;
                    try {
                        content_selection = yield select_conference_content(
                            group_call, media, other_presences,
                            preferred_content_names,
                            preferred_payload_types);
                    } catch (Error e) {
                        if (!is_current_group_call(stream, group_call)) {
                            return null;
                        }
                        if (!group_call.is_current_ready_membership_generation(
                                membership_generation)) {
                            membership_changed = true;
                            break;
                        }
                        warning("Could not determine MUJI %s codecs: %s",
                            media, e.message);
                        group_call.leave(stream);
                        return null;
                    }
                    if (!is_current_group_call(stream, group_call)) return null;
                    if (!group_call.is_current_ready_membership_generation(
                            membership_generation)) {
                        membership_changed = true;
                        break;
                    }
                    selections[media] = content_selection.codec_selection;
                    if (content_selection.content_name != null) {
                        selected_content_names[media] =
                            (!) content_selection.content_name;
                    }
                }
                if (membership_changed) continue;
                if (!group_call.is_current_ready_membership_generation(
                        membership_generation)) continue;

                foreach (Presence.Stanza presence in other_presences) {
                    Jid? real_jid = stream.get_flag(Muc.Flag.IDENTITY)
                        .get_real_jid(presence.from);
                    group_call.track_muji_participant(
                        presence.from, real_jid);
                    if (real_jid == null) {
                        warning("Don't know the real jid for %s",
                            presence.from.to_string());
                        continue;
                    }
                }

                var selected_muji_node = new StanzaNode.build(
                    "muji", NS_URI).add_self_xmlns();
                foreach (string media in video
                        ? new string[] { "audio", "video" }
                        : new string[] { "audio" }) {
                    CodecSelection codec_selection =
                        group_call.record_codec_selection(
                            media, selections[media]);
                    if (codec_selection.availability ==
                            CodecAvailability.REQUIRED_UNAVAILABLE) {
                        warning("Cannot join MUJI call without a common audio codec");
                        group_call.leave(stream);
                        return null;
                    }
                    if (codec_selection.availability ==
                            CodecAvailability.OPTIONAL_UNAVAILABLE) {
                        debug("No common MUJI video codec; publishing audio-only presence");
                        selected_content_names.unset(media);
                        continue;
                    }
                    string? content_name = selected_content_names[media];
                    if (content_name == null) {
                        warning("Cannot join MUJI call without a common %s content identity",
                            media);
                        group_call.leave(stream);
                        return null;
                    }
                    StanzaNode description_node = new StanzaNode.build(
                        "description", Xep.JingleRtp.NS_URI).add_self_xmlns()
                        .put_attribute("media", media);
                    foreach (Xep.JingleRtp.PayloadType payload_type in
                            codec_selection.payload_types) {
                        description_node.put_node(
                            payload_type.to_xml().add_self_xmlns());
                    }
                    selected_muji_node.put_node(new StanzaNode.build(
                        "content", NS_URI).add_self_xmlns()
                        .put_attribute("creator", "initiator")
                        .put_attribute("name", (!) content_name)
                        .put_node(description_node));
                }
                if (!group_call.commit_content_names(selected_content_names)) {
                    warning("Cannot change MUJI conference content identities after selection");
                    group_call.leave(stream);
                    return null;
                }
                group_call.peers_to_connect_to.clear();
                group_call.peers_to_wait_for.clear();
                foreach (Presence.Stanza presence in other_presences) {
                    Jid? real_jid = stream.get_flag(Muc.Flag.IDENTITY)
                        .get_real_jid(presence.from);
                    if (real_jid == null ||
                            !presence_supports_selected_payload(
                                presence, "audio",
                                selected_content_names["audio"],
                                selections["audio"].payload_types)) continue;

                    bool peer_video = false;
                    if (video && group_call.video_available &&
                            selected_content_names.has_key("video")) {
                        peer_video = presence_supports_selected_payload(
                            presence, "video",
                            selected_content_names["video"],
                            selections["video"].payload_types);
                    }
                    bool initiate_outgoing = should_initiate_peer_session(
                        group_call.our_nick, presence.from);
                    group_call.add_initial_peer(
                        (!) real_jid, peer_video, initiate_outgoing);
                }
                muji_node = selected_muji_node;
                break;
            }
            if (muji_node == null) return null;

            if (require_existing_call && !has_existing_call_peer(stream,
                    group_call)) {
                group_call.leave(stream);
                return null;
            }

            if (ready_presence_commit != null) {
                try {
                    ((!) ready_presence_commit)(group_call);
                } catch (Error e) {
                    warning("Cannot commit MUJI media before ready presence: %s",
                        e.message);
                    group_call.leave(stream);
                    return null;
                }
                if (!is_current_group_call(stream, group_call)) return null;
            }

            Presence.Stanza presence_stanza;
            try {
                presence_stanza = new Presence.Stanza() { to=muc_jid.with_resource(group_call.our_nick) };
            } catch (Xmpp.InvalidJidError e) {
                warning("Invalid JID for MUJI presence: %s", e.message);
                group_call.leave(stream);
                return null;
            }
            if (!is_current_group_call(stream, group_call)) return null;
            // Correlate the reflected READY with this call, even when the
            // room rewrites stanza ids. Keep incoming admission available;
            // only outgoing peer creation waits for this echo.
            ((!) muji_node).put_node(new StanzaNode.build(
                    "generation", LIVENESS_NS_URI).add_self_xmlns()
                .put_attribute("id", preparing_generation));
            presence_stanza.stanza.put_node((!) muji_node);
            group_call.expect_own_ready_presence(
                stream, presence_stanza.id, preparing_generation);
            stream.get_module<Presence.Module>(Presence.Module.IDENTITY).send_presence(stream, presence_stanza);

            return is_current_group_call(stream, group_call)
                ? group_call : null;
        }

        private async bool announce_preparing_in_joined_room(
                XmppStream stream, GroupCall group_call,
                StanzaNode initial_muji_node,
                string preparing_generation,
                PreparingPresenceCommit? preparing_presence_commit = null) {
            var echoed = new Promise<bool>();
            ulong echoed_handler = group_call.own_preparing_presence_echoed
                .connect(() => {
                    if (!echoed.future.ready) echoed.set_value(true);
                });
            ulong ended_handler = group_call.ended.connect(() => {
                if (!echoed.future.ready) echoed.set_value(false);
            });
            uint timeout_id = 0;
            timeout_id = Timeout.add_seconds(
                SELF_PRESENCE_ECHO_TIMEOUT_SECONDS, () => {
                    timeout_id = 0;
                    if (!echoed.future.ready) echoed.set_value(false);
                    return Source.REMOVE;
                });

            try {
                var presence = new Presence.Stanza() {
                    to = group_call.muc_jid.with_resource(group_call.our_nick)
                };
                group_call.expect_own_preparing_presence(
                    presence.id, preparing_generation);
                presence.stanza.put_node(initial_muji_node);
                if (preparing_presence_commit != null) {
                    ((!) preparing_presence_commit)(group_call);
                }
                stream.get_module<Presence.Module>(Presence.Module.IDENTITY)
                    .send_presence(stream, presence);
                return yield echoed.future.wait_async();
            } catch (Xmpp.InvalidJidError e) {
                warning("Invalid joined-MUC JID for MUJI presence: %s",
                    e.message);
                return false;
            } catch (Gee.FutureError e) {
                warning("MUJI self-presence wait failed: %s", e.message);
                return false;
            } catch (Error e) {
                debug("MUJI preparing intent cancelled: %s", e.message);
                return false;
            } finally {
                if (timeout_id != 0) Source.remove(timeout_id);
                if (SignalHandler.is_connected(group_call, echoed_handler)) {
                    SignalHandler.disconnect(group_call, echoed_handler);
                }
                if (SignalHandler.is_connected(group_call, ended_handler)) {
                    SignalHandler.disconnect(group_call, ended_handler);
                }
            }
        }

        private static bool presence_supports_selected_payload(
                Presence.Stanza presence,
                string media,
                string content_name,
                Gee.List<Xep.JingleRtp.PayloadType> selected_payloads) {
            if (!presence_has_content(media, content_name, presence)) return false;
            Gee.List<Xep.JingleRtp.PayloadType> peer_payloads =
                parse_payload_types(media, content_name, presence);
            if (!CodecNegotiation.payload_map_is_well_formed(peer_payloads)) {
                return false;
            }
            foreach (Xep.JingleRtp.PayloadType payload in selected_payloads) {
                if (!CodecNegotiation.is_rtx_payload(payload) &&
                        peer_payloads.contains(payload)) return true;
            }
            return false;
        }

        private bool is_current_group_call(
                XmppStream stream, GroupCall group_call) {
            GroupCall? current = stream.get_flag(Flag.IDENTITY).calls.get(
                group_call.muc_jid);
            return !group_call.left && current == group_call;
        }

        private async ConferenceContentSelection select_conference_content(
                GroupCall group_call,
                string media,
                Gee.List<Presence.Stanza> ready_presences,
                Gee.Map<string, string>? preferred_content_names = null,
                Gee.Map<string, Gee.List<Xep.JingleRtp.PayloadType>>?
                    preferred_payload_types = null) throws Error {
            string? preferred_name = preferred_content_names != null
                ? ((!) preferred_content_names)[media] : null;
            Gee.List<Xep.JingleRtp.PayloadType>? preferred_payloads =
                preferred_payload_types != null
                    ? ((!) preferred_payload_types)[media] : null;
            if (ready_presences.is_empty) {
                if (preferred_name != null && preferred_payloads != null) {
                    CodecSelection preferred_selection =
                        yield CodecNegotiation.select(
                            group_call.codec_provider, media,
                            (!) preferred_payloads);
                    if (preferred_selection.availability ==
                            CodecAvailability.AVAILABLE &&
                            payload_sets_equal(
                                preferred_selection.payload_types,
                                (!) preferred_payloads)) {
                        return new ConferenceContentSelection(
                            (!) preferred_name, preferred_selection);
                    }
                    return yield unavailable_conference_content(
                        group_call, media);
                }
                CodecSelection local_selection = yield CodecNegotiation.select(
                    group_call.codec_provider, media);
                return new ConferenceContentSelection(media, local_selection);
            }

            Gee.List<string> content_names =
                content_names_for_ready_presences(media, ready_presences);
            if (preferred_name != null) {
                if (!content_names.contains((!) preferred_name) ||
                        preferred_payloads == null) {
                    return yield unavailable_conference_content(
                        group_call, media);
                }
                Gee.List<Xep.JingleRtp.PayloadType> intersection =
                    payload_intersection_for_ready_presences(
                        media, ready_presences, (!) preferred_name);
                var exact_preferred_intersection =
                    new ArrayList<Xep.JingleRtp.PayloadType>(
                        Xep.JingleRtp.PayloadType.equals_func);
                foreach (Xep.JingleRtp.PayloadType payload_type in
                        intersection) {
                    if (((!) preferred_payloads).contains(payload_type)) {
                        exact_preferred_intersection.add(
                        payload_type.clone());
                    }
                }
                if (!payload_sets_equal(
                        exact_preferred_intersection,
                        (!) preferred_payloads)) {
                    return yield unavailable_conference_content(
                        group_call, media);
                }
                CodecSelection preferred_selection =
                    yield CodecNegotiation.select(
                        group_call.codec_provider, media,
                        exact_preferred_intersection);
                if (preferred_selection.availability ==
                        CodecAvailability.AVAILABLE &&
                        payload_sets_equal(
                            preferred_selection.payload_types,
                            (!) preferred_payloads)) {
                    return new ConferenceContentSelection(
                        (!) preferred_name, preferred_selection);
                }
                return yield unavailable_conference_content(
                    group_call, media);
            }

            foreach (string content_name in content_names) {
                Gee.List<Xep.JingleRtp.PayloadType> intersection =
                    payload_intersection_for_ready_presences(
                        media, ready_presences, content_name);
                CodecSelection selection = yield CodecNegotiation.select(
                    group_call.codec_provider, media, intersection);
                if (selection.availability == CodecAvailability.AVAILABLE) {
                    return new ConferenceContentSelection(
                        content_name, selection);
                }
            }

            return yield unavailable_conference_content(group_call, media);
        }

        private static bool payload_sets_equal(
                Gee.List<Xep.JingleRtp.PayloadType> left,
                Gee.List<Xep.JingleRtp.PayloadType> right) {
            if (left.size != right.size) return false;
            var unmatched = new ArrayList<Xep.JingleRtp.PayloadType>(
                Xep.JingleRtp.PayloadType.equals_func);
            unmatched.add_all(right);
            foreach (Xep.JingleRtp.PayloadType payload_type in left) {
                if (!unmatched.remove(payload_type)) return false;
            }
            return unmatched.is_empty;
        }

        private async ConferenceContentSelection unavailable_conference_content(
                GroupCall group_call, string media) throws Error {
            var unavailable_payloads =
                new ArrayList<Xep.JingleRtp.PayloadType>(
                    Xep.JingleRtp.PayloadType.equals_func);
            CodecSelection unavailable = yield CodecNegotiation.select(
                group_call.codec_provider, media, unavailable_payloads);
            return new ConferenceContentSelection(null, unavailable);
        }

        private static CodecSelection compute_peer_codec_selection(
                GroupCall group_call,
                string media,
                Presence.Stanza presence) {
            string? content_name = group_call.get_content_name(media);
            Gee.List<Xep.JingleRtp.PayloadType> peer_payloads =
                new ArrayList<Xep.JingleRtp.PayloadType>(
                Xep.JingleRtp.PayloadType.equals_func);
            if (content_name != null &&
                    presence_has_content(media, (!) content_name, presence)) {
                peer_payloads =
                    parse_payload_types(media, (!) content_name, presence);
            }
            Gee.List<Xep.JingleRtp.PayloadType>? frozen_payloads =
                group_call.current_payload_intersection[media];
            if (frozen_payloads == null) {
                frozen_payloads = new ArrayList<Xep.JingleRtp.PayloadType>(
                    Xep.JingleRtp.PayloadType.equals_func);
            }
            return CodecNegotiation.select_from_frozen_payload_map(
                media, (!) frozen_payloads, peer_payloads);
        }

        public static bool is_ready_muji_presence(Presence.Stanza presence) {
            StanzaNode? muji_node = presence.stanza.get_subnode("muji", NS_URI);
            return muji_node != null &&
                ((!) muji_node).get_subnode("preparing", NS_URI) == null;
        }

        /**
         * Computes an intersection from ready participants in one exact
         * conference content. Omission means non-participation in that
         * content; preparing and ambiguous presences are ignored.
         */
        public static Gee.List<Xep.JingleRtp.PayloadType>
                payload_intersection_for_ready_presences(
                    string media,
                    Gee.List<Presence.Stanza> presences,
                    string? selected_content_name = null) {
            string? content_name = selected_content_name ??
                common_content_name_for_ready_presences(media, presences);
            if (content_name == null) {
                return new ArrayList<Xep.JingleRtp.PayloadType>(
                    Xep.JingleRtp.PayloadType.equals_func);
            }
            Gee.List<Xep.JingleRtp.PayloadType>? intersection = null;
            foreach (Presence.Stanza presence in presences) {
                if (!is_ready_muji_presence(presence)) continue;
                if (!presence_has_content(media, (!) content_name, presence)) {
                    // XEP-0272 explicitly allows participants to omit a
                    // conference content. Only participants advertising this
                    // exact content contribute to its global PT map.
                    continue;
                }
                Gee.List<Xep.JingleRtp.PayloadType> peer_payload_types =
                    parse_payload_types(media, (!) content_name, presence);
                if (!CodecNegotiation.payload_map_is_well_formed(
                        peer_payload_types)) {
                    return new ArrayList<Xep.JingleRtp.PayloadType>(
                        Xep.JingleRtp.PayloadType.equals_func);
                }
                if (intersection == null) {
                    intersection = new ArrayList<Xep.JingleRtp.PayloadType>(
                        Xep.JingleRtp.PayloadType.equals_func);
                    foreach (Xep.JingleRtp.PayloadType payload_type in
                            peer_payload_types) {
                        ((!) intersection).add(payload_type.clone());
                    }
                    continue;
                }
                var remove_payloads = new ArrayList<Xep.JingleRtp.PayloadType>();
                foreach (Xep.JingleRtp.PayloadType payload_type in
                        (!) intersection) {
                    if (!peer_payload_types.contains(payload_type)) {
                        remove_payloads.add(payload_type);
                    }
                }
                ((!) intersection).remove_all(remove_payloads);
                if (!CodecNegotiation.payload_map_is_well_formed(
                        (!) intersection)) {
                    return new ArrayList<Xep.JingleRtp.PayloadType>(
                        Xep.JingleRtp.PayloadType.equals_func);
                }
            }
            return intersection ?? new ArrayList<Xep.JingleRtp.PayloadType>(
                Xep.JingleRtp.PayloadType.equals_func);
        }

        public static Gee.List<string> content_names_for_ready_presences(
                string media, Gee.List<Presence.Stanza> presences) {
            var names = new HashSet<string>();
            foreach (Presence.Stanza presence in presences) {
                if (!is_ready_muji_presence(presence)) continue;
                names.add_all(parse_content_names(media, presence));
            }
            var sorted_names = new ArrayList<string>();
            sorted_names.add_all(names);
            // Protocol selection must not depend on the process locale.
            sorted_names.sort((left, right) => strcmp(left, right));
            return sorted_names;
        }

        /**
         * Returns the first stable existing conference content for callers
         * which do not perform codec-aware selection themselves. Different
         * names remain different contents and their payload maps never mix.
         */
        public static string? common_content_name_for_ready_presences(
                string media, Gee.List<Presence.Stanza> presences) {
            Gee.List<string> names = content_names_for_ready_presences(
                media, presences);
            return names.is_empty ? null : names[0];
        }

        private static HashSet<string> parse_content_names(
                string media, Presence.Stanza presence) {
            var names = new HashSet<string>();
            HashSet<string> ambiguous_names =
                ambiguous_initiator_content_names(presence);
            foreach (StanzaNode content_node in presence.stanza.get_deep_subnodes(
                    NS_URI + ":muji", NS_URI + ":content")) {
                if (content_node.get_attribute("creator") != "initiator") {
                    continue;
                }
                string? content_name = content_node.get_attribute("name");
                if (!is_valid_content_name(content_name) ||
                        ambiguous_names.contains((!) content_name)) continue;
                StanzaNode? description_node = content_node.get_subnode(
                    "description", Xep.JingleRtp.NS_URI);
                if (description_node == null ||
                        ((!) description_node).get_attribute("media") != media) {
                    continue;
                }
                names.add((!) content_name);
            }
            return names;
        }

        private static Gee.List<Xep.JingleRtp.PayloadType> parse_payload_types(
                string media,
                string selected_content_name,
                Presence.Stanza presence) {
            Gee.List<Xep.JingleRtp.PayloadType> ret = new ArrayList<Xep.JingleRtp.PayloadType>(Xep.JingleRtp.PayloadType.equals_func);

            if (ambiguous_initiator_content_names(presence).contains(
                    selected_content_name)) return ret;

            foreach (StanzaNode content_node in presence.stanza.get_deep_subnodes(
                    NS_URI + ":muji", NS_URI + ":content")) {
                if (content_node.get_attribute("creator") != "initiator") {
                    continue;
                }
                if (content_node.get_attribute("name") != selected_content_name) {
                    continue;
                }
                StanzaNode? description_node = content_node.get_subnode("description", Xep.JingleRtp.NS_URI);
                if (description_node == null) continue;

                if (description_node.get_attribute("media") == media) {
                    Gee.List<StanzaNode> payload_nodes = description_node.get_subnodes("payload-type", Xep.JingleRtp.NS_URI);
                    foreach (StanzaNode payload_node in payload_nodes) {
                        Xep.JingleRtp.PayloadType payload_type = Xep.JingleRtp.PayloadType.parse(payload_node);
                        ret.add(payload_type);
                    }
                }
            }
            return ret;
        }

        public static bool presence_has_content(
                string media,
                string selected_content_name,
                Presence.Stanza presence) {
            if (ambiguous_initiator_content_names(presence).contains(
                    selected_content_name)) return false;
            foreach (StanzaNode content_node in presence.stanza.get_deep_subnodes(
                    NS_URI + ":muji", NS_URI + ":content")) {
                if (content_node.get_attribute("creator") != "initiator" ||
                        content_node.get_attribute("name") !=
                            selected_content_name) continue;
                StanzaNode? description_node = content_node.get_subnode(
                    "description", Xep.JingleRtp.NS_URI);
                if (description_node != null &&
                        ((!) description_node).get_attribute("media") == media) {
                    return true;
                }
            }
            return false;
        }

        /** Duplicate (creator,name) contents make that identity ambiguous. */
        private static HashSet<string> ambiguous_initiator_content_names(
                Presence.Stanza presence) {
            var seen_names = new HashSet<string>();
            var ambiguous_names = new HashSet<string>();
            foreach (StanzaNode content_node in presence.stanza.get_deep_subnodes(
                    NS_URI + ":muji", NS_URI + ":content")) {
                if (content_node.get_attribute("creator") != "initiator") {
                    continue;
                }
                string? content_name = content_node.get_attribute("name");
                if (!is_valid_content_name(content_name)) continue;
                if (!seen_names.add((!) content_name)) {
                    ambiguous_names.add((!) content_name);
                }
            }
            return ambiguous_names;
        }

        public static bool is_valid_content_name(string? value) {
            // XEP-0166 defines content@name as xs:string, not NMTOKEN.
            // Preserve it exactly; XML parsing/building owns escaping.
            return value != null && ((!) value).length > 0;
        }

        private void on_received_available(XmppStream stream, Presence.Stanza presence) {
            var flag = stream.get_flag(Flag.IDENTITY);
            GroupCall? group_call = flag.calls.get(presence.from.bare_jid);
            if (group_call == null) return;
            group_call.observe_current_join_presence(presence);

            string? call_debug = Environment.get_variable(
                "DINOX_GOOGLE_WEBRTC_CALL_DEBUG");
            if (call_debug == "1" || call_debug == "true" || call_debug == "yes") {
                StanzaNode? advertised = presence.stanza.get_subnode("muji", NS_URI);
                string phase = advertised == null ? "absent"
                    : ((!) advertised).get_subnode("preparing", NS_URI) != null
                        ? "preparing" : "ready";
                GLib.log("google-webrtc", LogLevelFlags.LEVEL_DEBUG,
                    "MUJI control: presence room=%s occupant=%s self=%s advertised-phase=%s",
                    group_call.muc_jid.to_string(), presence.from.to_string(),
                    (presence.from.resourcepart == group_call.our_nick).to_string(), phase);
            }

            if (presence.from.resourcepart == group_call.our_nick) {
                StanzaNode? own_muji = presence.stanza.get_subnode(
                    "muji", NS_URI);
                if (own_muji != null && ((!) own_muji).get_subnode(
                        "preparing", NS_URI) != null) {
                    StanzaNode? generation = ((!) own_muji).get_subnode(
                        "generation", LIVENESS_NS_URI);
                    if (generation != null &&
                            ((!) generation).get_attribute("id") == null) {
                        return;
                    }
                    group_call.confirm_own_preparing_presence(
                        presence.id,
                        generation != null
                            ? ((!) generation).get_attribute("id") : null);
                } else if (own_muji != null) {
                    StanzaNode? generation = ((!) own_muji).get_subnode(
                        "generation", LIVENESS_NS_URI);
                    if (generation != null &&
                            ((!) generation).get_attribute("id") == null) return;
                    group_call.confirm_own_ready_presence(presence.id,
                        generation != null
                            ? ((!) generation).get_attribute("id") : null);
                }
                return;
            }

            StanzaNode? muji_node = presence.stanza.get_subnode("muji", NS_URI);
            if (muji_node == null) {
                if (is_muji_leave_presence((!) group_call, presence)) {
                    remove_muji_participant(stream, presence.from,
                        (!) group_call, "available presence removed MUJI");
                }
                return;
            }

            uint presence_generation = group_call.mark_presence_update(presence.from);
            StanzaNode? prepare_node = muji_node.get_subnode("preparing", NS_URI);
            if (prepare_node == null) {
                process_ready_presence(
                    stream, presence, group_call, presence_generation);
            }
        }

        private void process_ready_presence(
                XmppStream stream,
                Presence.Stanza presence,
                GroupCall group_call,
                uint presence_generation) {
            // Before the initial ready presence is committed, join_call() owns
            // the complete cached-room snapshot.  Starting a second selection
            // here could publish a peer against a different content identity.
            if (!group_call.content_names_committed) {
                return;
            }
            if (!is_current_group_call(stream, group_call) ||
                    !group_call.is_current_presence_update(
                    presence.from, presence_generation)) return;

            Gee.List<Presence.Stanza> current_muji_presences =
                get_other_presences(stream, group_call.muc_jid);
            uint membership_generation =
                group_call.capture_muji_membership_snapshot(
                    current_muji_presences);
            var selections = new HashMap<string, CodecSelection>();
            // Deliberately synchronous: a standard late joiner may send its
            // session-initiate immediately after Ready presence. The
            // peer_joined signal must arm the exact engine expectation before
            // stanza dispatch can advance to that IQ.
            foreach (string media in group_call.video_requested &&
                    group_call.video_available
                        ? new string[] { "audio", "video" }
                        : new string[] { "audio" }) {
                selections[media] = compute_peer_codec_selection(
                    group_call, media, presence);
            }
            if (!is_current_group_call(stream, group_call) ||
                    !group_call.is_current_ready_snapshot(presence.from,
                        presence_generation, membership_generation)) {
                return;
            }

            Jid? real_jid = stream.get_flag(Muc.Flag.IDENTITY)
                .get_real_jid(presence.from);
            if (real_jid == null) {
                warning("Don't know the real jid for %s",
                    presence.from.to_string());
                return;
            }
            if (!is_current_group_call(stream, group_call) ||
                    !group_call.is_current_ready_snapshot(presence.from,
                        presence_generation, membership_generation)) return;

            bool initiate_outgoing = should_initiate_peer_session(
                group_call.our_nick, presence.from);
            if (!group_call.complete_ready_peer(
                    presence.from, (!) real_jid, selections,
                    initiate_outgoing)) {
                debug("MUJI ready peer %s does not share required audio content",
                    presence.from.to_string());
            }
        }

        /**
         * Monocles MUJI profile: the greater nick initiates each pair's leg.
         * Compare UTF-16 code units, exactly like Java String.compareTo().
         * UTF-8 byte order differs for supplementary-plane characters. Neither
         * real addresses nor locale/case folding take part in this election.
         */
        public static bool should_initiate_peer_session(
                string local_nick, Jid peer_occupant_jid) {
            string? peer_nick = peer_occupant_jid.resourcepart;
            if (local_nick == "" || peer_nick == null || peer_nick == "") {
                return false;
            }
            int local_pos = 0;
            int peer_pos = 0;
            while (true) {
                unichar local_char;
                unichar peer_char;
                bool have_local = local_nick.get_next_char(ref local_pos, out local_char);
                bool have_peer = ((!) peer_nick).get_next_char(ref peer_pos, out peer_char);
                if (!have_local || !have_peer) return have_local;
                if (local_char == peer_char) continue;
                // Compare the first UTF-16 unit; within the same surrogate
                // block, scalar order also orders the second unit correctly.
                uint local_unit = local_char > 0xffff
                    ? 0xd800 + ((local_char - 0x10000) >> 10) : local_char;
                uint peer_unit = peer_char > 0xffff
                    ? 0xd800 + ((peer_char - 0x10000) >> 10) : peer_char;
                return local_unit != peer_unit
                    ? local_unit > peer_unit : local_char > peer_char;
            }
        }

        private void on_received_unavailable(XmppStream stream, Presence.Stanza presence) {
            Flag flag = stream.get_flag(Flag.IDENTITY);
            GroupCall? group_call = flag.calls[presence.from.bare_jid];
            if (group_call == null) return;
            group_call.observe_current_join_presence(presence);

            if (presence.from.resourcepart == group_call.our_nick) {
                group_call.cancel_own_ready_wait();
            }
            remove_muji_participant(stream, presence.from,
                (!) group_call, "unavailable presence");
        }

        public static bool is_muji_leave_presence(
                GroupCall group_call, Presence.Stanza presence) {
            return presence.type_ == Presence.Stanza.TYPE_AVAILABLE &&
                presence.stanza.get_subnode("muji", NS_URI) == null &&
                group_call.has_muji_participant(presence.from);
        }

        private void remove_muji_participant(XmppStream stream,
                Jid occupant_jid, GroupCall group_call, string reason) {
            Jid? real_jid;
            if (!group_call.forget_muji_participant(
                    occupant_jid, out real_jid)) return;
            debug("Muji peer left %s / %s (%s)",
                real_jid != null ? ((!) real_jid).to_string()
                    : "Unknown real JID",
                occupant_jid.to_string(), reason);
        }

        private Gee.List<Presence.Stanza> get_other_presences(XmppStream stream, Jid muc_jid) {
            Gee.List<Presence.Stanza> presences = stream.get_flag(Presence.Flag.IDENTITY).get_presences(muc_jid);
            GroupCall? call = stream.get_flag(Flag.IDENTITY).calls[muc_jid];
            string? own_nick = call != null ? call.our_nick : null;

            var remove_presences = new ArrayList<Presence.Stanza>();
            foreach (Presence.Stanza presence in presences) {
                if (call != null && !((!) call).may_use_join_presence(presence.from)) {
                    remove_presences.add(presence);
                    continue;
                }
                if (presence.from.resourcepart == own_nick) {
                    remove_presences.add(presence);
                }
                StanzaNode? muji_node = presence.stanza.get_subnode("muji", NS_URI);
                if (muji_node == null) {
                    remove_presences.add(presence);
                }
            }
            presences.remove_all(remove_presences);
            return presences;
        }

        /** A room occupant alone is not evidence of an ongoing MUJI call. */
        public static bool is_existing_call_peer(Presence.Stanza presence,
                Jid room, string own_nick, Jid? real_jid) {
            if (presence.type_ != Presence.Stanza.TYPE_AVAILABLE ||
                    presence.from.resourcepart == null ||
                    !presence.from.bare_jid.equals(room.bare_jid) ||
                    presence.from.resourcepart == own_nick ||
                    real_jid == null || !((!) real_jid).is_full()) return false;
            return has_call_advertisement(presence);
        }

        /** An unvouched MUJI advertisement is not evidence of an empty room. */
        public static bool has_call_advertisement(Presence.Stanza presence) {
            if (presence.type_ != Presence.Stanza.TYPE_AVAILABLE) return false;
            StanzaNode? muji = presence.stanza.get_subnode("muji", NS_URI);
            if (muji == null) return false;
            if (((!) muji).get_subnode("preparing", NS_URI) != null) return true;
            foreach (StanzaNode content in ((!) muji).get_subnodes("content", NS_URI)) {
                StanzaNode? description = content.get_subnode("description", Xep.JingleRtp.NS_URI);
                if (description != null &&
                        ((!) description).get_attribute("media") == "audio" &&
                        ((!) description).get_subnode("payload-type", Xep.JingleRtp.NS_URI) != null) return true;
            }
            return false;
        }

        private bool has_existing_call_peer(XmppStream stream,
                GroupCall group_call) {
            Muc.Flag flag = stream.get_flag(Muc.Flag.IDENTITY);
            foreach (Presence.Stanza presence in get_other_presences(stream,
                    group_call.muc_jid)) {
                if (is_existing_call_peer(presence, group_call.muc_jid,
                        group_call.our_nick, flag.get_real_jid(presence.from))) return true;
            }
            return false;
        }

        private Gee.List<Presence.Stanza> get_ready_presences(
                XmppStream stream, Jid muc_jid) {
            Gee.List<Presence.Stanza> presences = get_other_presences(stream, muc_jid);
            var remove_presences = new ArrayList<Presence.Stanza>();
            foreach (Presence.Stanza presence in presences) {
                if (!is_ready_muji_presence(presence)) {
                    remove_presences.add(presence);
                }
            }
            presences.remove_all(remove_presences);
            return presences;
        }

        private void on_pre_send_presence_stanza(XmppStream stream,
                Presence.Stanza presence) {
            // XEP-0272 participation is part of our occupant presence. A
            // normal status/avatar update or XEP-0045 occupant replay must
            // not accidentally withdraw it while the call is still active.
            if (presence.type_ != Presence.Stanza.TYPE_AVAILABLE ||
                    presence.to == null) return;
            Jid target = (!) presence.to;
            if (target.resourcepart == null) return;
            GroupCall? group_call = stream.get_flag(Flag.IDENTITY)
                .calls.get(target.bare_jid);
            if (group_call == null || ((!) group_call).left ||
                    target.resourcepart != ((!) group_call).our_nick) return;
            ((!) group_call).preserve_own_muji_presence(presence);
        }

        public override void attach(XmppStream stream) {
            stream.add_flag(new Flag());
            stream.get_module<Presence.Module>(Presence.Module.IDENTITY)
                .pre_send_presence_stanza.connect(on_pre_send_presence_stanza);
            stream.get_module<Presence.Module>(Presence.Module.IDENTITY).received_available.connect(on_received_available);
            stream.get_module<Presence.Module>(Presence.Module.IDENTITY).received_unavailable.connect(on_received_unavailable);
        }

        public void register_codec_provider(XmppStream stream, CodecProvider codec_provider) {
            Flag flag = stream.get_flag(Flag.IDENTITY);
            flag.codec_provider = codec_provider;
            stream.get_module<ServiceDiscovery.Module>(ServiceDiscovery.Module.IDENTITY)
                .add_feature(stream, NS_URI);
        }

        public bool unregister_codec_provider(XmppStream stream, CodecProvider codec_provider) {
            Flag flag = stream.get_flag(Flag.IDENTITY);
            if (flag.codec_provider != codec_provider) return false;
            flag.codec_provider = null;
            stream.get_module<ServiceDiscovery.Module>(ServiceDiscovery.Module.IDENTITY)
                .remove_feature(stream, NS_URI);
            return true;
        }

        public override void detach(XmppStream stream) {
            foreach (GroupCall call in stream.get_flag(Flag.IDENTITY).calls.values.to_array()) {
                call.cancel_own_ready_wait();
            }
            stream.get_module<ServiceDiscovery.Module>(ServiceDiscovery.Module.IDENTITY).remove_feature(stream, NS_URI);
            stream.get_flag(Flag.IDENTITY).codec_provider = null;
            stream.get_module<Presence.Module>(Presence.Module.IDENTITY)
                .pre_send_presence_stanza.disconnect(on_pre_send_presence_stanza);
            stream.get_module<Presence.Module>(Presence.Module.IDENTITY).received_available.disconnect(on_received_available);
            stream.get_module<Presence.Module>(Presence.Module.IDENTITY).received_unavailable.disconnect(on_received_unavailable);
        }

        public override string get_ns() {
            return NS_URI;
        }

        public override string get_id() {
            return IDENTITY.id;
        }
    }

    public class GroupCall {
        public string our_nick;
        public Jid muc_jid;
        /** True when MUJI shares an already joined chat-room presence. */
        public bool reuses_muc_occupancy { get; internal set; default=false; }
        public CodecProvider codec_provider { get; private set; }
        public bool video_requested { get; private set; }
        public bool video_available { get; internal set; default = true; }
        public ArrayList<Jid> peers_to_connect_to = new ArrayList<Jid>(Jid.equals_func);
        public ArrayList<Jid> peers_to_wait_for = new ArrayList<Jid>(Jid.equals_func);
        public ArrayList<Jid> peers = new ArrayList<Jid>(Jid.equals_func);
        public HashMap<Jid, Jid> real_jids = new HashMap<Jid, Jid>(Jid.hash_func, Jid.equals_func);
        public HashMap<string, Gee.List<Xep.JingleRtp.PayloadType>> current_payload_intersection = new HashMap<string, Gee.List<Xep.JingleRtp.PayloadType>>();
        public HashMap<string, CodecAvailability> current_media_availability =
            new HashMap<string, CodecAvailability>();
        private HashMap<string, string> selected_content_names =
            new HashMap<string, string>();
        private HashMap<Jid, uint> presence_generations =
            new HashMap<Jid, uint>(Jid.hash_func, Jid.equals_func);
        private HashSet<Jid> muji_participants =
            new HashSet<Jid>(Jid.hash_func, Jid.equals_func);
        private HashMap<Jid, bool> peer_video_by_real_jid =
            new HashMap<Jid, bool>(Jid.hash_func, Jid.equals_func);
        private HashMap<Jid, bool> peer_outgoing_by_real_jid =
            new HashMap<Jid, bool>(Jid.hash_func, Jid.equals_func);
        private uint next_presence_generation = 0;
        private uint ready_membership_generation = 1;
        private bool needs_current_join_presences = false;
        private HashSet<Jid> current_join_occupants =
            new HashSet<Jid>(Jid.hash_func, Jid.equals_func);
        public bool left { get; private set; default = false; }
        public bool content_names_committed { get; private set; default = false; }
        public bool outgoing_connections_ready { get; private set; default = false; }

        public signal void peer_joined(Jid real_jid);
        public signal void peer_left(Jid real_jid);
        /** Legacy payload-only notification. Prefer media_availability_changed. */
        public signal void codecs_changed(Gee.List<Xep.JingleRtp.PayloadType> payload_types);
        public signal void media_availability_changed(
            string media,
            CodecAvailability availability,
            Gee.List<Xep.JingleRtp.PayloadType> payload_types);
        internal signal void own_preparing_presence_echoed();
        internal signal void ended();
        private bool own_preparing_echo_seen = false;
        private string? own_preparing_presence_id = null;
        private string? own_preparing_generation = null;
        private string? own_ready_presence_id = null;
        private string? own_ready_generation = null;
        private bool own_ready_pending = false;
        private uint own_ready_timeout_id = 0;
        private signal void own_ready_wait_finished(bool ready);
        private StanzaNode? own_muji_presence = null;
        private Cancellable? join_cancellable = null;
        private ulong join_cancelled_handler_id = 0;

        public GroupCall(
                Jid muc_jid,
                CodecProvider codec_provider,
                bool video_requested = false) {
            this.muc_jid = muc_jid;
            this.codec_provider = codec_provider;
            this.video_requested = video_requested;
            this.video_available = video_requested;
        }

        internal void require_current_join_presences() {
            needs_current_join_presences = true;
            current_join_occupants.clear();
        }

        internal void observe_current_join_presence(Presence.Stanza presence) {
            if (!needs_current_join_presences || left ||
                    !presence.from.bare_jid.equals(muc_jid) ||
                    presence.from.resourcepart == null) return;
            if (presence.type_ == Presence.Stanza.TYPE_AVAILABLE) {
                current_join_occupants.add(presence.from);
            } else {
                current_join_occupants.remove(presence.from);
            }
        }

        internal bool may_use_join_presence(Jid occupant) {
            return !needs_current_join_presences ||
                current_join_occupants.contains(occupant);
        }

        internal void preserve_own_muji_presence(Presence.Stanza presence) {
            StanzaNode? muji = presence.stanza.get_subnode("muji", NS_URI);
            if (muji != null) {
                // Keep the last actually announced phase and immutable codec
                // map, including extensions. Never synthesize Ready early.
                own_muji_presence = clone_presence_node((!) muji);
            } else if (own_muji_presence != null) {
                presence.stanza.put_node(clone_presence_node(
                    (!) own_muji_presence));
            }
        }

        private static StanzaNode clone_presence_node(StanzaNode source) {
            var copy = new StanzaNode();
            copy.name = source.name;
            copy.ns_uri = source.ns_uri;
            copy.val = source.val;
            copy.has_nodes = source.has_nodes;
            copy.pseudo = source.pseudo;
            foreach (StanzaAttribute attribute in source.attributes) {
                var copied_attribute = new StanzaAttribute();
                copied_attribute.name = attribute.name;
                copied_attribute.ns_uri = attribute.ns_uri;
                copied_attribute.val = attribute.val;
                copy.attributes.add(copied_attribute);
            }
            foreach (StanzaNode child in source.sub_nodes) {
                copy.sub_nodes.add(clone_presence_node(child));
            }
            return copy;
        }

        /**
         * Records the initial conference media result and emits an unambiguous
         * update. Once the ready presence is committed, both the content names
         * and the global payload mapping are immutable for this participant.
         */
        public CodecSelection record_codec_selection(
                string media, CodecSelection selection) {
            if (content_names_committed &&
                    current_media_availability.has_key(media) &&
                    current_payload_intersection.has_key(media)) {
                return new CodecSelection(
                    clone_payload_types(current_payload_intersection[media]),
                    current_media_availability[media]);
            }
            CodecSelection effective_selection = selection;
            if (media == "video" &&
                    (selection.availability == CodecAvailability.OPTIONAL_UNAVAILABLE ||
                     !video_available)) {
                video_available = false;
                if (selection.availability != CodecAvailability.OPTIONAL_UNAVAILABLE ||
                        !selection.payload_types.is_empty) {
                    effective_selection = new CodecSelection(
                        new ArrayList<Xep.JingleRtp.PayloadType>(
                            Xep.JingleRtp.PayloadType.equals_func),
                        CodecAvailability.OPTIONAL_UNAVAILABLE);
                }
            }

            Gee.List<Xep.JingleRtp.PayloadType> payload_types =
                clone_payload_types(effective_selection.payload_types);
            bool changed = !current_media_availability.has_key(media) ||
                current_media_availability[media] != effective_selection.availability ||
                !current_payload_intersection.has_key(media) ||
                !current_payload_intersection[media].contains_all(payload_types) ||
                !payload_types.contains_all(current_payload_intersection[media]);
            if (changed) {
                current_media_availability[media] = effective_selection.availability;
                current_payload_intersection[media] = payload_types;
                codecs_changed(payload_types);
                media_availability_changed(
                    media, effective_selection.availability, payload_types);
            }
            return new CodecSelection(
                clone_payload_types(payload_types),
                effective_selection.availability);
        }

        /** Atomically freezes the conference content identity for every leg. */
        public bool commit_content_names(Gee.Map<string, string> content_names) {
            if (!content_names.has_key("audio") ||
                    !Module.is_valid_content_name(content_names["audio"])) {
                return false;
            }
            if ((video_requested && video_available &&
                    !content_names.has_key("video")) ||
                    ((!video_requested || !video_available) &&
                    content_names.has_key("video"))) {
                return false;
            }
            var unique_names = new HashSet<string>();
            foreach (var entry in content_names.entries) {
                if ((entry.key != "audio" && entry.key != "video") ||
                        !Module.is_valid_content_name(entry.value) ||
                        unique_names.contains(entry.value)) {
                    return false;
                }
                unique_names.add(entry.value);
            }
            if (content_names_committed) {
                return selected_content_names.size == content_names.size &&
                    selected_content_names.has_key("audio") &&
                    selected_content_names["audio"] == content_names["audio"] &&
                    ((!content_names.has_key("video") &&
                        !selected_content_names.has_key("video")) ||
                     (content_names.has_key("video") &&
                        selected_content_names.has_key("video") &&
                        selected_content_names["video"] == content_names["video"]));
            }
            selected_content_names.clear();
            foreach (var entry in content_names.entries) {
                selected_content_names[entry.key] = entry.value;
            }
            content_names_committed = true;
            return true;
        }

        public string? get_content_name(string media) {
            return selected_content_names[media];
        }

        public Gee.Map<string, string> copy_content_names_by_media() {
            var copy = new HashMap<string, string>();
            foreach (var entry in selected_content_names.entries) {
                copy[entry.key] = entry.value;
            }
            return copy;
        }

        /** Deep copy of the frozen global XEP-0272 payload map. */
        public Gee.Map<string, Gee.List<Xep.JingleRtp.PayloadType>>
                copy_payload_types_by_media() {
            var copy = new HashMap<string,
                Gee.List<Xep.JingleRtp.PayloadType>>();
            foreach (string media in selected_content_names.keys) {
                Gee.List<Xep.JingleRtp.PayloadType>? payload_types =
                    current_payload_intersection[media];
                if (payload_types != null) {
                    copy[media] = clone_payload_types((!) payload_types);
                }
            }
            return copy;
        }

        /** Stores the per-leg media and initiator decision. */
        public void add_initial_peer(
                Jid real_jid,
                bool supports_video,
                bool initiate_outgoing) {
            peers_to_connect_to.remove(real_jid);
            peers_to_wait_for.remove(real_jid);
            peer_video_by_real_jid[real_jid] = supports_video;
            peer_outgoing_by_real_jid[real_jid] = initiate_outgoing;
            if (initiate_outgoing) {
                peers_to_connect_to.add(real_jid);
            } else {
                peers_to_wait_for.add(real_jid);
            }
        }

        public bool peer_supports_video(Jid real_jid) {
            return peer_video_by_real_jid.has_key(real_jid) &&
                peer_video_by_real_jid[real_jid];
        }

        public bool peer_should_initiate_outgoing(Jid real_jid) {
            return peer_outgoing_by_real_jid.has_key(real_jid) &&
                peer_outgoing_by_real_jid[real_jid];
        }

        public uint mark_presence_update(Jid occupant_jid) {
            next_presence_generation++;
            if (next_presence_generation == 0) {
                presence_generations.clear();
                next_presence_generation++;
            }
            presence_generations[occupant_jid] = next_presence_generation;
            track_muji_participant(occupant_jid);
            advance_ready_membership_generation();
            return next_presence_generation;
        }

        public void invalidate_presence_update(Jid occupant_jid) {
            presence_generations.unset(occupant_jid);
            advance_ready_membership_generation();
        }

        public bool is_current_presence_update(
                Jid occupant_jid, uint generation) {
            return !left && presence_generations.has_key(occupant_jid) &&
                presence_generations[occupant_jid] == generation;
        }

        internal void expect_own_preparing_presence(
                string? presence_id, string generation) {
            own_preparing_presence_id = presence_id;
            own_preparing_generation = generation;
            own_preparing_echo_seen = false;
        }

        internal void expect_own_ready_presence(XmppStream stream,
                string? presence_id, string generation) {
            if (left || own_ready_pending || outgoing_connections_ready) return;
            own_ready_presence_id = presence_id;
            own_ready_generation = generation;
            own_ready_pending = true;
            // The Monocles profile permits outgoing legs after five seconds
            // without an echo. A cancelled/replaced call never gets that fallback.
            own_ready_timeout_id = Timeout.add(5000, () => {
                own_ready_timeout_id = 0;
                Flag? flag = stream.get_flag(Flag.IDENTITY);
                Muc.Flag? muc = stream.get_flag(Muc.Flag.IDENTITY);
                finish_own_ready_wait(!left && flag != null &&
                    ((!) flag).calls.get(muc_jid) == this && muc != null &&
                    ((!) muc).get_muc_nick(muc_jid) == our_nick);
                return Source.REMOVE;
            });
        }

        internal void confirm_own_ready_presence(
                string? presence_id, string? generation) {
            if (left || !own_ready_pending) return;
            if (generation != null) {
                if (generation != own_ready_generation) return;
            } else if (presence_id == null ||
                    presence_id != own_ready_presence_id) return;
            finish_own_ready_wait(true);
        }

        internal void cancel_own_ready_wait() {
            outgoing_connections_ready = false;
            finish_own_ready_wait(false);
        }

        private void finish_own_ready_wait(bool ready) {
            if (!own_ready_pending) return;
            own_ready_pending = false;
            if (own_ready_timeout_id != 0) {
                Source.remove(own_ready_timeout_id);
                own_ready_timeout_id = 0;
            }
            own_ready_presence_id = null;
            own_ready_generation = null;
            outgoing_connections_ready = ready && !left;
            own_ready_wait_finished(outgoing_connections_ready);
        }

        /** Incoming peer admission does not wait on this outgoing-only gate. */
        public async bool wait_for_own_ready() {
            if (left || !own_ready_pending) return !left && outgoing_connections_ready;
            var ready = new Promise<bool>();
            ulong handler = own_ready_wait_finished.connect((allowed) => {
                if (!ready.future.ready) ready.set_value(allowed);
            });
            try {
                return yield ready.future.wait_async();
            } catch (Gee.FutureError e) {
                return false;
            } finally {
                if (SignalHandler.is_connected(this, handler)) {
                    SignalHandler.disconnect(this, handler);
                }
            }
        }

        public bool bind_confirmed_muc_occupancy(
                Muc.JoinResult? result) {
            if (result == null || ((!) result).nick == null) return false;
            // Status 210 may rewrite the requested nick. Keep the exact
            // confirmed occupancy so teardown can release this room.
            our_nick = (!) ((!) result).nick;
            return true;
        }

        internal void bind_join_cancellation(XmppStream stream,
                Cancellable? cancellable) {
            if (cancellable == null) return;
            join_cancellable = (!) cancellable;
            join_cancelled_handler_id = ((!) cancellable).cancelled.connect(
                () => leave(stream));
            if (((!) cancellable).is_cancelled()) leave(stream);
        }

        internal void confirm_own_preparing_presence(
                string? presence_id, string? generation) {
            if (left || own_preparing_echo_seen) return;
            if (generation != null) {
                if (own_preparing_generation == null ||
                        generation != own_preparing_generation) return;
            } else if (presence_id == null ||
                    own_preparing_presence_id == null ||
                    presence_id != own_preparing_presence_id) {
                return;
            }
            own_preparing_echo_seen = true;
            own_preparing_presence_echoed();
        }

        public void track_muji_participant(
                Jid occupant_jid, Jid? real_jid = null) {
            muji_participants.add(occupant_jid);
            if (real_jid != null) {
                real_jids[occupant_jid] = (!) real_jid;
            }
        }

        public bool has_muji_participant(Jid occupant_jid) {
            return muji_participants.contains(occupant_jid);
        }

        public bool forget_muji_participant(
                Jid occupant_jid, out Jid? real_jid) {
            real_jid = real_jids.get(occupant_jid);
            if (!muji_participants.remove(occupant_jid)) return false;
            presence_generations.unset(occupant_jid);
            peers.remove(occupant_jid);
            if (real_jid != null) {
                peers_to_connect_to.remove((!) real_jid);
                peers_to_wait_for.remove((!) real_jid);
                peer_video_by_real_jid.unset((!) real_jid);
                peer_outgoing_by_real_jid.unset((!) real_jid);
            }
            real_jids.unset(occupant_jid);
            advance_ready_membership_generation();
            if (real_jid != null) peer_left((!) real_jid);
            return true;
        }

        public uint capture_ready_membership_generation() {
            return ready_membership_generation;
        }

        public uint capture_muji_membership_snapshot(
                Gee.List<Presence.Stanza> muji_presences) {
            bool discovered_membership = false;
            foreach (Presence.Stanza presence in muji_presences) {
                // Store only the occupant identity at this preliminary stage.
                // The real JID is bound when the still-current snapshot is
                // committed, avoiding peer_left for a leg never exposed.
                if (!has_muji_participant(presence.from)) {
                    track_muji_participant(presence.from);
                    discovered_membership = true;
                }
            }
            if (discovered_membership) advance_ready_membership_generation();
            return capture_ready_membership_generation();
        }

        public bool is_current_ready_membership_generation(uint generation) {
            return !left && ready_membership_generation == generation;
        }

        public bool is_current_ready_snapshot(Jid occupant_jid,
                uint presence_generation, uint membership_generation) {
            return is_current_presence_update(occupant_jid,
                    presence_generation) &&
                is_current_ready_membership_generation(
                    membership_generation);
        }

        private void advance_ready_membership_generation() {
            ready_membership_generation++;
            if (ready_membership_generation == 0) {
                ready_membership_generation++;
            }
        }

        /** Records all media decisions before exposing a newly ready peer. */
        public bool complete_ready_peer(
                Jid occupant_jid,
                Jid real_jid,
                Gee.Map<string, CodecSelection> selections,
                bool initiate_outgoing = false) {
            if (!selections.has_key("audio") ||
                    selections["audio"].availability !=
                        CodecAvailability.AVAILABLE ||
                    selections["audio"].payload_types.is_empty) {
                return false;
            }
            if (peers.contains(occupant_jid)) return true;
            bool supports_video = video_available &&
                selections.has_key("video") &&
                selections["video"].availability ==
                    CodecAvailability.AVAILABLE &&
                !selections["video"].payload_types.is_empty;
            peer_video_by_real_jid[real_jid] = supports_video;
            peer_outgoing_by_real_jid[real_jid] = initiate_outgoing;
            debug("Muji peer joined %s / %s\n",
                real_jid.to_string(), occupant_jid.to_string());
            peers.add(occupant_jid);
            track_muji_participant(occupant_jid, real_jid);
            peer_joined(real_jid);
            return true;
        }

        public void leave(XmppStream stream, bool send_wire = true) {
            if (left) return;
            left = true;
            cancel_own_ready_wait();
            own_muji_presence = null;
            Cancellable? cancellable = join_cancellable;
            ulong cancelled_handler_id = join_cancelled_handler_id;
            join_cancellable = null;
            join_cancelled_handler_id = 0;
            if (cancellable != null && cancelled_handler_id != 0 &&
                    SignalHandler.is_connected((!) cancellable,
                        cancelled_handler_id)) {
                SignalHandler.disconnect((!) cancellable,
                    cancelled_handler_id);
            }
            own_preparing_presence_id = null;
            own_preparing_generation = null;
            presence_generations.clear();
            muji_participants.clear();
            current_join_occupants.clear();
            peers.clear();
            peers_to_connect_to.clear();
            peers_to_wait_for.clear();
            peer_video_by_real_jid.clear();
            peer_outgoing_by_real_jid.clear();
            real_jids.clear();
            Flag? flag = stream.get_flag(Flag.IDENTITY);
            bool owns_room_call = flag != null &&
                ((!) flag).calls.get(muc_jid) == this;
            if (owns_room_call) {
                Muc.Flag? muc_flag = stream.get_flag(Muc.Flag.IDENTITY);
                string? current_nick = muc_flag != null
                    ? ((!) muc_flag).get_muc_nick(muc_jid) : null;
                string? entering_nick = muc_flag != null
                    ? ((!) muc_flag).get_enter_nick(muc_jid) : null;
                bool owns_occupancy = current_nick == our_nick ||
                    entering_nick == our_nick;
                if (send_wire && reuses_muc_occupancy && owns_occupancy) {
                    try {
                        var presence = new Presence.Stanza() {
                            to = muc_jid.with_resource(our_nick)
                        };
                        stream.get_module<Presence.Module>(
                            Presence.Module.IDENTITY).send_presence(
                                stream, presence);
                    } catch (Xmpp.InvalidJidError e) {
                        warning("Invalid joined-MUC JID while leaving MUJI: %s",
                            e.message);
                    }
                } else if (send_wire && !reuses_muc_occupancy &&
                        owns_occupancy) {
                    stream.get_module<Xep.Muc.Module>(
                        Xep.Muc.Module.IDENTITY).exit(stream, muc_jid);
                }
                ((!) flag).calls.unset(muc_jid);
            }
            // Wake a suspended join only after this lifecycle has released
            // every map and presence resource it still owns.
            ended();
        }

        private static Gee.List<Xep.JingleRtp.PayloadType> clone_payload_types(
                Gee.List<Xep.JingleRtp.PayloadType> source) {
            var copy = new ArrayList<Xep.JingleRtp.PayloadType>(
                Xep.JingleRtp.PayloadType.equals_func);
            foreach (Xep.JingleRtp.PayloadType payload_type in source) {
                copy.add(payload_type.clone());
            }
            return copy;
        }
    }

    public class Flag : XmppStreamFlag {
        public static FlagIdentity<Flag> IDENTITY = new FlagIdentity<Flag>(NS_URI, "muji");

        public HashMap<Jid, GroupCall> calls = new HashMap<Jid, GroupCall>(Jid.hash_bare_func, Jid.equals_bare_func);
        public CodecProvider? codec_provider { get; set; default = null; }

        public override string get_ns() { return NS_URI; }
        public override string get_id() { return IDENTITY.id; }
    }
}

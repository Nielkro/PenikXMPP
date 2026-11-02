using Gee;
using Xmpp;
using Xmpp.Xep;
using Dino.Plugins.GoogleWebrtc;

namespace Dino.Plugins.GoogleWebrtc.Test {

private class OwnershipWireTransport : Object, EngineJingleWireTransport {
    public Jid local_full_jid { get; private set; }

    public OwnershipWireTransport(Jid local_full_jid) {
        this.local_full_jid = local_full_jid;
    }

    public void send_jingle_iq(Jid to, StanzaNode jingle) {}
    public void send_result_iq(Iq.Stanza request_iq) {}
    public void send_error_iq(Iq.Stanza request_iq, ErrorStanza error) {}
}

private class OwnershipJmiTransport : Object, EngineJmiTransport {
    public Jid local_full_jid { get; private set; }

    public OwnershipJmiTransport(Jid local_full_jid) {
        this.local_full_jid = local_full_jid;
    }

    public void send_propose(
            Jid to, string sid, Gee.List<StanzaNode> descriptions) {}
    public void send_accept_to_self(string sid) {}
    public void send_proceed(Jid to, string sid) {}
    public void send_reject(Jid to, string sid) {}
    public void send_reject_to_self(string sid) {}
    public void send_retract(Jid to, string sid) {}
}

private class OwnershipCodecProvider : Object, Muji.CodecProvider {
    public async Gee.List<JingleRtp.PayloadType> get_supported_payloads(
            string media) throws Error {
        return new ArrayList<JingleRtp.PayloadType>(
            JingleRtp.PayloadType.equals_func);
    }

    public async bool is_payload_supported(
            string media, JingleRtp.PayloadType payload_type) throws Error {
        return false;
    }
}

private void close_tracked_group_and_store_weak_refs(
        Plugin plugin, ref WeakRef group_ref, ref WeakRef peer_ref) throws Error {
    EngineMujiGroupSession? group = null;
    plugin.begin_call_context_registration_for_test();
    try {
        EngineContext context = plugin.context_for_retirement_test();
        var local = new Jid("alice-plugin-ownership@example.test/DinoX");
        var room = new Jid("plugin-ownership@conference.example.test");
        var router = new EngineJmiSessionRouter();
        group = new EngineMujiGroupSession(
            context,
            router,
            new OwnershipWireTransport(local),
            new OwnershipJmiTransport(local),
            local,
            room,
            8401,
            false,
            new OwnershipCodecProvider());
        var content_names = new HashMap<string, string>();
        content_names["audio"] = "voice";
        var payload_types = new HashMap<string,
            Gee.List<JingleRtp.PayloadType>>();
        var audio_payloads = new ArrayList<JingleRtp.PayloadType>(
            JingleRtp.PayloadType.equals_func);
        audio_payloads.add(new JingleRtp.PayloadType() {
            id = 111,
            name = "opus",
            clockrate = 48000,
            channels = 2
        });
        payload_types["audio"] = audio_payloads;
        ((!) group).configure_conference_media(
            content_names, payload_types);
        router.add_muji_group((!) group);
        plugin.track_muji_group_for_test((!) group);
    } finally {
        plugin.end_call_context_registration_for_test();
    }
    if (plugin.muji_group_count_for_test() != 1) {
        throw new IOError.FAILED(
            "plugin did not retain the ownership-test MUJI group");
    }
    EngineJmiSession? peer = ((!) group).start_peer_without_offer_for_test(
        new Jid("bob-plugin-ownership@example.test/Phone"),
        "plugin-ownership-peer");
    EngineJmiSession? second_peer =
        ((!) group).start_peer_without_offer_for_test(
            new Jid("carol-plugin-ownership@example.test/Tablet"),
            "plugin-ownership-second-peer");
    if (plugin.session_count_for_test() != 2) {
        throw new IOError.FAILED(
            "plugin did not track both MUJI peer sessions");
    }
    group_ref.set((!) group);
    peer_ref.set((!) peer);

    ((!) peer).discard();
    ((!) second_peer).discard();
    if (plugin.session_count_for_test() != 0) {
        throw new IOError.FAILED(
            "discarded MUJI peers remained in the plugin session set");
    }
    ((!) group).close();
    if (plugin.muji_group_count_for_test() != 0) {
        throw new IOError.FAILED(
            "group_closed did not remove the plugin MUJI group entry");
    }
    peer = null;
    second_peer = null;
    group = null;
}

private EngineJmiSession create_tracked_pending_call(
        Plugin plugin, EngineContext context, string sid,
        uint64 logical_call_id) throws Error {
    plugin.begin_call_context_registration_for_test();
    try {
        EngineContext registered_context =
            plugin.context_for_retirement_test();
        if (registered_context != context) {
            throw new IOError.FAILED(
                "call registration did not retain the expected shared context");
        }
        var local = new Jid("alice-plugin-pending@example.test/DinoX");
        var peer = new Jid("bob-plugin-pending@example.test");
        var session = new EngineJmiSession.outgoing(
            registered_context,
            new OwnershipWireTransport(local),
            new OwnershipJmiTransport(local),
            sid,
            logical_call_id,
            local,
            peer,
            true,
            false);
        plugin.track_session_for_test(session);
        session.propose();
        return session;
    } finally {
        plugin.end_call_context_registration_for_test();
    }
}

private void verify_direct_migration_uses_one_worker(
        Plugin plugin, EngineContext context,
        uint expected_creation_count) throws Error {
    var local = new Jid("alice-plugin-migration@example.test/DinoX");
    var peer_bare = new Jid("bob-plugin-migration@example.test");
    var peer_full = new Jid("bob-plugin-migration@example.test/Phone");
    EngineJmiSession? original = null;
    EngineJmiSession? replacement = null;

    plugin.begin_call_context_registration_for_test();
    try {
        EngineContext registered_context =
            plugin.context_for_retirement_test();
        if (registered_context != context) {
            throw new IOError.FAILED(
                "migration source did not retain the shared context");
        }
        original = new EngineJmiSession.outgoing(
            registered_context,
            new OwnershipWireTransport(local),
            new OwnershipJmiTransport(local),
            "plugin-migration-old",
            8406,
            local,
            peer_bare,
            true,
            false);
        plugin.track_session_for_test((!) original);
        ((!) original).propose();
    } finally {
        plugin.end_call_context_registration_for_test();
    }

    try {
        ((!) original).handle_proceed(
            peer_full, local, "plugin-migration-old");
        if (((!) original).wire_session == null) {
            throw new IOError.FAILED(
                "migration source did not own a native wire session");
        }

        var descriptions = new ArrayList<StanzaNode>();
        descriptions.add(new StanzaNode.build("description", JingleRtp.NS_URI)
            .put_attribute("media", "audio"));
        plugin.begin_call_context_registration_for_test();
        try {
            EngineContext registered_context =
                plugin.context_for_retirement_test();
            if (registered_context != context) {
                throw new IOError.FAILED(
                    "migration replacement created another context");
            }
            replacement = new EngineJmiSession.incoming(
                registered_context,
                new OwnershipWireTransport(local),
                new OwnershipJmiTransport(local),
                "plugin-migration-new",
                8406,
                local,
                peer_full,
                descriptions);
            plugin.track_session_for_test((!) replacement);
        } finally {
            plugin.end_call_context_registration_for_test();
        }

        if (plugin.session_count_for_test() != 2 ||
                plugin.context_for_retirement_test() != context ||
                plugin.context_creation_count_for_test() !=
                    expected_creation_count ||
                ((!) replacement).wire_session != null) {
            throw new IOError.FAILED(
                "staged migration did not keep one worker and one native leg");
        }

        ((!) original).end("expired", "Session migrated");
        if (plugin.session_count_for_test() != 1 ||
                ((!) original).wire_session != null ||
                ((!) replacement).wire_session != null ||
                plugin.context_for_retirement_test() != context ||
                plugin.context_creation_count_for_test() !=
                    expected_creation_count) {
            throw new IOError.FAILED(
                "migration source release overlapped or replaced the shared worker");
        }

        ((!) replacement).accept_proposal();
        if (((!) replacement).wire_session != null ||
                plugin.context_creation_count_for_test() !=
                    expected_creation_count) {
            throw new IOError.FAILED(
                "migration replacement started native media before session-initiate");
        }
    } finally {
        if (original != null) ((!) original).discard();
        if (replacement != null) ((!) replacement).discard();
    }

    if (plugin.session_count_for_test() != 0 ||
            plugin.context_for_retirement_test() != context ||
            plugin.context_creation_count_for_test() !=
                expected_creation_count) {
        throw new IOError.FAILED(
            "migration cleanup leaked a session or replaced its worker");
    }
}

private EngineMujiGroupSession create_tracked_video_group(
        Plugin plugin, EngineContext context) throws Error {
    plugin.begin_call_context_registration_for_test();
    try {
        EngineContext registered_context =
            plugin.context_for_retirement_test();
        if (registered_context != context) {
            throw new IOError.FAILED(
                "group registration did not retain the expected shared context");
        }
        var local = new Jid("alice-plugin-video@example.test/DinoX");
        var room = new Jid("plugin-video@conference.example.test");
        var router = new EngineJmiSessionRouter();
        var group = new EngineMujiGroupSession(
            registered_context,
            router,
            new OwnershipWireTransport(local),
            new OwnershipJmiTransport(local),
            local,
            room,
            8402,
            true,
            new OwnershipCodecProvider());
        var content_names = new HashMap<string, string>();
        content_names["audio"] = "voice";
        content_names["video"] = "camera";
        var payload_types = new HashMap<string,
            Gee.List<JingleRtp.PayloadType>>();
        var audio_payloads = new ArrayList<JingleRtp.PayloadType>(
            JingleRtp.PayloadType.equals_func);
        audio_payloads.add(new JingleRtp.PayloadType() {
            id = 111,
            name = "opus",
            clockrate = 48000,
            channels = 2
        });
        payload_types["audio"] = audio_payloads;
        var video_payloads = new ArrayList<JingleRtp.PayloadType>(
            JingleRtp.PayloadType.equals_func);
        video_payloads.add(new JingleRtp.PayloadType() {
            id = 96,
            name = "VP8",
            clockrate = 90000,
            channels = 1
        });
        payload_types["video"] = video_payloads;
        group.configure_conference_media(content_names, payload_types);
        router.add_muji_group(group);
        plugin.track_muji_group_for_test(group);
        return group;
    } finally {
        plugin.end_call_context_registration_for_test();
    }
}

private void verify_device_test_does_not_stop_message_playback() throws Error {
    var plugin = new Plugin();
    EngineContext shared = plugin.context_for_retirement_test();
    var provider = new GoogleWebrtcMediaMessagePlaybackProvider(() => { return shared; });
    Dino.Plugins.MediaMessagePlaybackSession? playback = null;
    EngineSessionOwner? call = null;
    try {
        var config = new EngineSessionConfig();
        config.video_enabled = false;
        call = shared.create_session(config);
        playback = provider.create_audio_playback_session();
        playback.start(48000, 1, 2);
        var pcm = new Bytes(new uint8[960 * 2]);
        playback.push_pcm(pcm);

        plugin.play_test_tone(null, '5', 120);
        plugin.stop_audio_test_playout();
        playback.push_pcm(pcm);
        plugin.play_audio_test_clip(null, pcm, 48000, 1, 2);
        plugin.stop_audio_test_playout();
        playback.push_pcm(pcm);

        if (shared.is_closed || shared.active_call_activity_count == 0) {
            throw new IOError.FAILED("device test disturbed the unrelated call context");
        }
        ((!) call).get_state();
        try {
            plugin.play_test_tone(null, 'z', 120);
            throw new IOError.FAILED("invalid device-test tone unexpectedly succeeded");
        } catch (EngineError e) {
            // A failed test also must leave message playout intact.
            playback.push_pcm(pcm);
        }
    } finally {
        try { plugin.stop_audio_test_playout(); } catch (Error e) {
            debug("device-test cleanup: %s", e.message);
        }
        if (playback != null) ((!) playback).stop();
        if (call != null) ((!) call).close();
        plugin.shutdown();
    }
}

private int run_smoke() {
    try {
        verify_device_test_does_not_stop_message_playback();
    } catch (Error e) {
        critical("device-test playback isolation failed: %s", e.message);
        return 1;
    }
    if (Plugin.should_advertise_muji_bundle_feature(false) ||
            !Plugin.should_advertise_muji_bundle_feature(true)) {
        critical("MUJI BUNDLE capability is not gated by MUJI module availability");
        return 1;
    }
    var plugin = new Plugin();
    JmiCallEnginePlugin direct_engine = plugin;
    MujiCallEnginePlugin group_engine = plugin;
    if (direct_engine.engine_id != "google-libwebrtc" ||
            group_engine.group_engine_id != direct_engine.engine_id) {
        critical(
            "JMI/MUJI engine facets do not expose the same engine id");
        return 1;
    }
    uint before = plugin.context_creation_count_for_test();
    bool first = plugin.can_start_group_video_without_account_for_test();
    for (int i = 0; i < 32; i++) {
        if (plugin.can_start_group_video_without_account_for_test() != first) {
            critical("group-video capability getter changed without runtime state change");
            return 1;
        }
    }
    uint after = plugin.context_creation_count_for_test();
    if (before != 0 || after != before) {
        critical(
            "group-video capability getter created a context/worker: before=%u after=%u",
            before, after);
        return 1;
    }
    try {
        EngineContext first_context =
            plugin.context_for_retirement_test();
        uint first_creation_count =
            plugin.context_creation_count_for_test();
        EngineContextActivityLease non_call_lease =
            first_context.acquire_activity(
                "plugin-retirement-non-call-test");
        verify_direct_migration_uses_one_worker(
            plugin, first_context, first_creation_count);
        WeakRef lifecycle_group_ref = WeakRef(null);
        WeakRef lifecycle_peer_ref = WeakRef(null);
        close_tracked_group_and_store_weak_refs(
            plugin, ref lifecycle_group_ref, ref lifecycle_peer_ref);
        if (plugin.context_for_retirement_test() != first_context ||
                plugin.context_creation_count_for_test() !=
                    first_creation_count) {
            critical(
                "two MUJI peer sessions created a second context/worker");
            return 1;
        }
        if (!plugin.has_context_for_test() || first_context.is_closed) {
            critical(
                "final MUJI group cleanup interrupted a live non-call activity");
            return 1;
        }
        EngineJmiSession pending_direct = create_tracked_pending_call(
            plugin,
            first_context,
            "plugin-pending-after-muji",
            8403);
        non_call_lease.release();
        if (!plugin.has_context_for_test() || first_context.is_closed ||
                plugin.context_for_retirement_test() != first_context ||
                plugin.context_creation_count_for_test() !=
                    first_creation_count) {
            critical(
                "deferred MUJI retirement closed a newly tracked 1:1 proposal");
            return 1;
        }
        pending_direct.discard();
        if (plugin.has_context_for_test() || !first_context.is_closed) {
            critical(
                "final 1:1 proposal release did not retire the idle call worker");
            return 1;
        }
        EngineContext second_context =
            plugin.context_for_retirement_test();
        if (second_context == first_context ||
                plugin.context_creation_count_for_test() !=
                    first_creation_count + 1) {
            critical(
                "next 1:1-capable use did not receive a fresh media worker");
            return 1;
        }

        EngineMujiGroupSession video_group = create_tracked_video_group(
            plugin, second_context);
        EngineVideoEffectPipelineOwner? video_pipeline =
            video_group.shared_video_pipeline_for_test();
        if (video_pipeline == null) {
            critical("plugin video group did not create its shared pipeline");
            return 1;
        }
        EngineJmiSession concurrent_direct = create_tracked_pending_call(
            plugin,
            second_context,
            "plugin-direct-while-muji-active",
            8405);
        if (plugin.context_for_retirement_test() != second_context ||
                plugin.context_creation_count_for_test() !=
                    first_creation_count + 1) {
            critical(
                "simultaneous MUJI and 1:1 calls did not share one media worker");
            return 1;
        }
        concurrent_direct.discard();
        if (!plugin.has_context_for_test() || second_context.is_closed ||
                plugin.context_for_retirement_test() != second_context) {
            critical(
                "ending a concurrent 1:1 proposal interrupted the live MUJI group");
            return 1;
        }
        bool blocker_done = false;
        ((!) video_pipeline).block_native_control_for_test.begin(
            500, (_, result) => {
                try {
                    ((!) video_pipeline).block_native_control_for_test.end(result);
                } catch (Error e) {
                    // Closing the group is expected to cancel the logical
                    // result while native cleanup remains ordered behind it.
                }
                blocker_done = true;
            });
        int64 blocker_deadline = get_monotonic_time() + 2 * 1000 * 1000;
        while (!((!) video_pipeline).control_in_flight_for_test() &&
                get_monotonic_time() < blocker_deadline) {
            Thread.usleep(1000);
        }
        if (!((!) video_pipeline).control_in_flight_for_test()) {
            critical("plugin video cleanup blocker did not enter native control");
            return 1;
        }

        video_group.close();
        EngineContext during_video_cleanup =
            plugin.context_for_retirement_test();
        if (during_video_cleanup != second_context || second_context.is_closed ||
                plugin.context_creation_count_for_test() !=
                    first_creation_count + 1) {
            critical(
                "MUJI video cleanup closed its worker or created an overlapping worker");
            return 1;
        }
        EngineJmiSession pending_during_video_cleanup =
            create_tracked_pending_call(
                plugin,
                second_context,
                "plugin-pending-during-video-cleanup",
                8404);
        int64 cleanup_deadline = get_monotonic_time() + 3 * 1000 * 1000;
        while ((!((!) video_pipeline).cleanup_finished_for_test() ||
                !blocker_done) && get_monotonic_time() < cleanup_deadline) {
            while (MainContext.default().pending()) {
                MainContext.default().iteration(false);
            }
            Thread.usleep(1000);
        }
        if (!((!) video_pipeline).cleanup_finished_for_test() ||
                !blocker_done || second_context.is_closed ||
                plugin.context_for_retirement_test() != second_context ||
                plugin.context_creation_count_for_test() !=
                    first_creation_count + 1) {
            critical(
                "a pending 1:1 call did not retain the single worker through MUJI video cleanup");
            return 1;
        }
        pending_during_video_cleanup.discard();
        if (plugin.has_context_for_test() || !second_context.is_closed) {
            critical(
                "finished video cleanup plus final 1:1 release did not retire the worker");
            return 1;
        }

        EngineContext third_context =
            plugin.context_for_retirement_test();
        if (third_context == second_context ||
                plugin.context_creation_count_for_test() !=
                    first_creation_count + 2) {
            critical("post-cleanup call use did not receive exactly one fresh worker");
            return 1;
        }
        plugin.request_context_retirement_for_test();
        if (plugin.has_context_for_test() || !third_context.is_closed) {
            critical("fresh retirement-test context remained alive");
            return 1;
        }
    } catch (Error e) {
        critical("plugin worker-retirement smoke failed: %s", e.message);
        return 1;
    }
    try {
        WeakRef group_ref = WeakRef(null);
        WeakRef peer_ref = WeakRef(null);
        close_tracked_group_and_store_weak_refs(
            plugin, ref group_ref, ref peer_ref);
        for (int i = 0; i < 8; i++) {
            while (MainContext.default().pending()) {
                MainContext.default().iteration(false);
            }
            Thread.usleep(1000);
        }
        if (group_ref.get() != null) {
            critical("closed MUJI group retained itself through plugin signals");
            return 1;
        }
        if (peer_ref.get() != null) {
            critical("discarded MUJI peer retained itself through plugin signals");
            return 1;
        }
    } catch (Error e) {
        critical("plugin MUJI ownership smoke failed: %s", e.message);
        return 1;
    }
    plugin.shutdown();
    return 0;
}

}

public int main(string[] args) {
    return Dino.Plugins.GoogleWebrtc.Test.run_smoke();
}

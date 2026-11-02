using Xmpp;

namespace Dino.Plugins.GoogleWebrtc.Test {

/**
 * Keeps the complete internal smoke-test API referenced in every standalone
 * Vala smoke binary. Each binary recompiles the engine sources independently,
 * so a hook exercised by another smoke would otherwise produce a misleading
 * "never used" warning in strict builds.
 *
 * This class is compiled only into non-installed test executables and is never
 * called at runtime.
 */
public class CompilerWarningAnchor : Object {
    public static async void retain_engine_smoke_api(
            EngineContext context,
            EngineSessionOwner owner,
            EngineJmiSession jmi_session,
            EngineMujiGroupSession group_session,
            owned EnginePeerBundleCapability bundle_capability,
            EnginePeerBundleCapabilityResolver bundle_capability_resolver,
            EngineVideoEffectPipelineOwner video_pipeline,
            Jid peer_full_jid) throws Error {
        context.try_retire_if_idle();

        var codec_probe = new EngineSessionMujiCodecProbe(owner);
        yield EngineMujiCodecProbeRunner.run(codec_probe, "audio", 1);

        jmi_session.inject_group_video_state_apply_failure_for_test();
        jmi_session.suppress_local_capture_start_for_test();
        jmi_session.start_muji_wire_without_offer_for_test();
        jmi_session.ensure_video_effect_pipeline_for_test();
        jmi_session.disconnect_wire_session_for_test();

        group_session.set_peer_bundle_capability((owned) bundle_capability);
        group_session.set_peer_bundle_capability_resolver(
            bundle_capability_resolver);
        group_session.start_peer_without_offer_for_test(
            peer_full_jid, "compiler-warning-anchor");
        group_session.video_attachment_count_for_test();
        group_session.preview_publisher_sid_for_test();
        group_session.capture_start_attempt_count_for_test();
        group_session.shared_video_pipeline_open_for_test();
        group_session.shared_video_pipeline_for_test();
        group_session.video_disabled_by_codec_for_test();
        group_session.local_video_enabled_for_test();
        group_session.suppress_capture_start_for_test();
        group_session.push_preview_synthetic_frame_for_test(1, 1);

        video_pipeline.has_queued_state(1);
        Native.VideoPipelineState callback_state = {};
        video_pipeline.inject_state_for_test(callback_state);
        yield video_pipeline.block_native_control_for_test(1);
        video_pipeline.control_in_flight_for_test();
        video_pipeline.control_pending_count_for_test();
        video_pipeline.cleanup_finished_for_test();
        video_pipeline.arm_background_precommit_for_test();
        video_pipeline.background_precommit_reached_for_test();
        video_pipeline.release_background_precommit_for_test();
        video_pipeline.attachment_count_for_test();
        video_pipeline.is_preview_session_for_test(owner);
    }
}

}

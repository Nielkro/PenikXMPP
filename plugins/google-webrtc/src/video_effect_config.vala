namespace Dino.Plugins.GoogleWebrtc {

/** One value mapping shared by direct and MUJI outgoing-camera sources. */
internal class VideoEffectConfigMapper : Object {
    internal static JmiVideoEffectCapabilities capabilities(Native.VideoEffectCapabilities native) {
        return new JmiVideoEffectCapabilities(true,
            (native.supported_effect_mask & (1UL << (int) Native.VideoEffectType.GRAYSCALE)) != 0,
            (native.supported_effect_mask & (1UL << (int) Native.VideoEffectType.WARM_TONE)) != 0,
            JmiVideoEffectUnavailableReason.NONE,
            (native.supported_effect_mask & (1UL << (int) Native.VideoEffectType.COLD_TONE)) != 0,
            (native.supported_effect_mask & (1UL << (int) Native.VideoEffectType.SEPIA)) != 0,
            native.supported_adjustment_mask & 15U,
            native.supported_background_mask & 15U,
            native.auto_framing_supported != 0,
            native.supported_effect_mask & 8160UL,
            native.supported_glasses_mask, native.supported_hat_mask, native.supported_beard_mask,
            native.supported_face_accessory_mask, native.supported_scene_effect_mask,
            native.touch_up_supported != 0, native.low_light_supported != 0);
    }

    internal static Native.VideoEffectConfig to_native(JmiVideoEffectSelection selection,
            JmiVideoEffectCapabilities capabilities) throws Error {
        if (!selection.is_valid()) {
            throw new IOError.INVALID_ARGUMENT("The video-effect settings are invalid");
        }
        if (!capabilities.supports_selection(selection)) {
            throw new IOError.NOT_SUPPORTED("The video-effect settings are unavailable for this source");
        }
        Native.VideoEffectConfig config = Native.video_effect_config_default();
        config.abi_version = Native.ABI_VERSION;
        switch (selection.kind) {
            case JmiVideoEffectKind.OFF: config.effect_type = Native.VideoEffectType.NONE; break;
            case JmiVideoEffectKind.GRAYSCALE: config.effect_type = Native.VideoEffectType.GRAYSCALE; break;
            case JmiVideoEffectKind.WARM_TONE: config.effect_type = Native.VideoEffectType.WARM_TONE; break;
            case JmiVideoEffectKind.COLD_TONE: config.effect_type = Native.VideoEffectType.COLD_TONE; break;
            case JmiVideoEffectKind.SEPIA: config.effect_type = Native.VideoEffectType.SEPIA; break;
            case JmiVideoEffectKind.LIGHT_LEAK: config.effect_type = Native.VideoEffectType.LIGHT_LEAK; break;
            case JmiVideoEffectKind.DREAMY: config.effect_type = Native.VideoEffectType.DREAMY; break;
            case JmiVideoEffectKind.PRISM_LIGHT: config.effect_type = Native.VideoEffectType.PRISM_LIGHT; break;
            case JmiVideoEffectKind.FISHEYE: config.effect_type = Native.VideoEffectType.FISHEYE; break;
            case JmiVideoEffectKind.VINTAGE_TV: config.effect_type = Native.VideoEffectType.VINTAGE_TV; break;
            case JmiVideoEffectKind.FROSTED_GLASS: config.effect_type = Native.VideoEffectType.FROSTED_GLASS; break;
            case JmiVideoEffectKind.DUO_TONE: config.effect_type = Native.VideoEffectType.DUO_TONE; break;
            case JmiVideoEffectKind.UNDERWATER: config.effect_type = Native.VideoEffectType.UNDERWATER; break;
            default: throw new IOError.INVALID_ARGUMENT("The video colour preset is invalid");
        }
        config.preset_id = selection.preset_id;
        config.asset_id = selection.asset_id;
        config.brightness = selection.brightness;
        config.contrast = selection.contrast;
        config.saturation = selection.saturation;
        config.sharpness = selection.sharpness;
        config.background_mode = (Native.VideoBackgroundMode) (int) selection.background_mode;
        config.background_strength = selection.background_strength;
        config.background_color_rgb = selection.background_color_rgb;
        config.framing_mode = (Native.VideoFramingMode) (int) selection.framing_mode;
        config.glasses_style = (uint32) selection.glasses_style;
        config.hat_style = (uint32) selection.hat_style;
        config.beard_style = (uint32) selection.beard_style;
        config.face_accessory = (uint32) selection.face_accessory;
        config.touch_up = selection.touch_up ? 1U : 0U;
        config.low_light = selection.low_light ? 1U : 0U;
        config.scene_effect = (uint32) selection.scene_effect;
        return config;
    }

    internal static JmiVideoEffectSelection from_native(Native.VideoPipelineState state) throws EngineError {
        JmiVideoEffectKind kind;
        switch (state.effect_type) {
            case Native.VideoEffectType.NONE: kind = JmiVideoEffectKind.OFF; break;
            case Native.VideoEffectType.GRAYSCALE: kind = JmiVideoEffectKind.GRAYSCALE; break;
            case Native.VideoEffectType.WARM_TONE: kind = JmiVideoEffectKind.WARM_TONE; break;
            case Native.VideoEffectType.COLD_TONE: kind = JmiVideoEffectKind.COLD_TONE; break;
            case Native.VideoEffectType.SEPIA: kind = JmiVideoEffectKind.SEPIA; break;
            case Native.VideoEffectType.LIGHT_LEAK: kind = JmiVideoEffectKind.LIGHT_LEAK; break;
            case Native.VideoEffectType.DREAMY: kind = JmiVideoEffectKind.DREAMY; break;
            case Native.VideoEffectType.PRISM_LIGHT: kind = JmiVideoEffectKind.PRISM_LIGHT; break;
            case Native.VideoEffectType.FISHEYE: kind = JmiVideoEffectKind.FISHEYE; break;
            case Native.VideoEffectType.VINTAGE_TV: kind = JmiVideoEffectKind.VINTAGE_TV; break;
            case Native.VideoEffectType.FROSTED_GLASS: kind = JmiVideoEffectKind.FROSTED_GLASS; break;
            case Native.VideoEffectType.DUO_TONE: kind = JmiVideoEffectKind.DUO_TONE; break;
            case Native.VideoEffectType.UNDERWATER: kind = JmiVideoEffectKind.UNDERWATER; break;
            default: throw new EngineError.NATIVE("The native video colour preset is invalid");
        }
        var selection = new JmiVideoEffectSelection(kind, JmiVideoEffectQuality.AUTO,
            state.preset_id, state.asset_id, state.brightness, state.contrast,
            state.saturation, state.sharpness,
            (JmiVideoBackgroundMode) (int) state.background_mode,
            state.background_strength, state.background_color_rgb,
            (JmiVideoFramingMode) (int) state.framing_mode,
            (JmiVideoGlassesStyle) state.glasses_style, (JmiVideoHatStyle) state.hat_style,
            (JmiVideoBeardStyle) state.beard_style, (JmiVideoFaceAccessory) state.face_accessory,
            state.touch_up != 0, state.low_light != 0, (JmiVideoSceneEffect) state.scene_effect);
        if (state.quality != Native.VideoEffectQuality.AUTO || state.touch_up > 1 ||
                state.low_light > 1 || !selection.is_valid()) {
            throw new EngineError.NATIVE("The native video-effect settings are invalid");
        }
        return selection;
    }
}

}

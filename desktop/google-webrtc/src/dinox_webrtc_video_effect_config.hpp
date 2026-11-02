#ifndef DINOX_WEBRTC_VIDEO_EFFECT_CONFIG_HPP
#define DINOX_WEBRTC_VIDEO_EFFECT_CONFIG_HPP

#include "dinox_webrtc.h"

namespace dinox::webrtc_effects {

constexpr uint64_t kSupportedEffectMask = UINT64_C(8191);
constexpr uint64_t kKnownEffectMask = UINT64_C(8191);
constexpr uint32_t kSupportedAdjustmentMask = UINT32_C(15);
constexpr uint32_t kSupportedBackgroundMask = UINT32_C(1);
constexpr uint32_t kKnownBackgroundMask = UINT32_C(15);
constexpr uint32_t kSupportedStyleMask = UINT32_C(1);
constexpr uint32_t kKnownThreeStyleMask = UINT32_C(15);
constexpr uint32_t kKnownFaceAccessoryMask = UINT32_C(7);
constexpr uint32_t kKnownSceneEffectMask = UINT32_C(31);

inline bool valid_config(const DinoXWebrtcVideoEffectConfig& config) {
    if (config.abi_version != DINOX_WEBRTC_ABI_VERSION ||
            static_cast<uint32_t>(config.effect_type) > DINOX_WEBRTC_VIDEO_EFFECT_UNDERWATER ||
            config.quality != DINOX_WEBRTC_VIDEO_EFFECT_QUALITY_AUTO ||
            config.preset_id != 0 || config.reserved != 0 ||
            config.brightness < -100 || config.brightness > 100 ||
            config.contrast < -100 || config.contrast > 100 ||
            config.saturation < -100 || config.saturation > 100 ||
            config.sharpness < 0 || config.sharpness > 100 ||
            static_cast<uint32_t>(config.background_mode) > DINOX_WEBRTC_VIDEO_BACKGROUND_IMAGE ||
            config.background_strength < 0 || config.background_strength > 100 ||
            config.background_color_rgb > UINT32_C(0xffffff) ||
            static_cast<uint32_t>(config.framing_mode) > DINOX_WEBRTC_VIDEO_FRAMING_AUTO ||
            config.glasses_style > 3 || config.hat_style > 3 || config.beard_style > 3 ||
            config.face_accessory > 2 || config.touch_up > 1 || config.low_light > 1 ||
            config.scene_effect > 4) {
        return false;
    }
    if (config.background_mode == DINOX_WEBRTC_VIDEO_BACKGROUND_IMAGE) {
        // The registry bounds live assets; opaque IDs can increase across
        // many image replacements and are never paths or pointers.
        return config.asset_id > 0 &&
            config.background_strength == 0 && config.background_color_rgb == 0;
    }
    if (config.asset_id != 0) return false;
    if (config.background_mode == DINOX_WEBRTC_VIDEO_BACKGROUND_NONE) {
        return config.background_strength == 0 && config.background_color_rgb == 0;
    }
    if (config.background_mode == DINOX_WEBRTC_VIDEO_BACKGROUND_SOLID) {
        return config.background_strength == 0;
    }
    return config.background_color_rgb == 0;
}

inline bool supported_config(const DinoXWebrtcVideoEffectConfig& config,
    bool segmentation_available = false, bool face_available = false) {
    const uint32_t effect = static_cast<uint32_t>(config.effect_type);
    return effect < 64 && (kSupportedEffectMask & (UINT64_C(1) << effect)) != 0 &&
        (config.background_mode == DINOX_WEBRTC_VIDEO_BACKGROUND_NONE ||
            segmentation_available) &&
        (config.framing_mode == DINOX_WEBRTC_VIDEO_FRAMING_NONE || segmentation_available) &&
        (face_available || (config.glasses_style == 0 && config.hat_style == 0 &&
            config.beard_style == 0 && config.face_accessory == 0 && config.touch_up == 0));
}

inline bool active_config(const DinoXWebrtcVideoEffectConfig& config) {
    return config.effect_type != DINOX_WEBRTC_VIDEO_EFFECT_NONE ||
        config.brightness != 0 || config.contrast != 0 ||
        config.saturation != 0 || config.sharpness != 0 ||
        config.background_mode != DINOX_WEBRTC_VIDEO_BACKGROUND_NONE ||
        config.framing_mode != DINOX_WEBRTC_VIDEO_FRAMING_NONE ||
        config.glasses_style != 0 || config.hat_style != 0 || config.beard_style != 0 ||
        config.face_accessory != 0 || config.touch_up != 0 || config.low_light != 0 ||
        config.scene_effect != 0;
}

inline bool same_config(
    const DinoXWebrtcVideoEffectConfig& first,
    const DinoXWebrtcVideoEffectConfig& second) {
    // Compare fields deliberately: ABI structs can contain padding.
    return first.abi_version == second.abi_version &&
        first.effect_type == second.effect_type && first.quality == second.quality &&
        first.preset_id == second.preset_id && first.asset_id == second.asset_id &&
        first.reserved == second.reserved && first.brightness == second.brightness &&
        first.contrast == second.contrast && first.saturation == second.saturation &&
        first.sharpness == second.sharpness &&
        first.background_mode == second.background_mode &&
        first.background_strength == second.background_strength &&
        first.background_color_rgb == second.background_color_rgb &&
        first.framing_mode == second.framing_mode &&
        first.glasses_style == second.glasses_style && first.hat_style == second.hat_style &&
        first.beard_style == second.beard_style && first.face_accessory == second.face_accessory &&
        first.touch_up == second.touch_up && first.low_light == second.low_light &&
        first.scene_effect == second.scene_effect;
}

}  // namespace dinox::webrtc_effects

#endif

#ifndef DINOX_WEBRTC_HARDWARE_RATE_CONTROL_HPP
#define DINOX_WEBRTC_HARDWARE_RATE_CONTROL_HPP

#include <cstdint>

namespace dinox::webrtc_runtime {

enum class HardwareRateUpdate { Keep, Reinitialize, SoftwareFallback };

// FFmpeg VA-API snapshots rate control at open; its NVENC reconfiguration can
// silently ignore unsupported changes or hide driver failures. Small target
// changes use a 10% downward / 20% upward hysteresis; at most one restart is
// allowed per second. A faster substantial reduction falls back to libwebrtc's
// dynamic software controller instead of holding an unsafe old target or
// producing repeated IDRs. Both providers reopen with verified parameters.
inline HardwareRateUpdate DecideFfmpegHardwareRateUpdate(
    uint32_t active_bps, int active_fps, uint32_t target_bps, int target_fps,
    int64_t milliseconds_since_restart) {
    const bool reduction = uint64_t(target_bps) * 10 <= uint64_t(active_bps) * 9 ||
        int64_t(target_fps) * 10 <= int64_t(active_fps) * 9;
    const bool increase = uint64_t(target_bps) * 10 >= uint64_t(active_bps) * 12 ||
        int64_t(target_fps) * 10 >= int64_t(active_fps) * 12;
    if (!reduction && !increase) return HardwareRateUpdate::Keep;
    if (milliseconds_since_restart >= 1000) return HardwareRateUpdate::Reinitialize;
    return reduction ? HardwareRateUpdate::SoftwareFallback : HardwareRateUpdate::Keep;
}

}  // namespace dinox::webrtc_runtime

#endif

#include "dinox_webrtc_hardware_rate_control.hpp"

#include <cstdio>

int main() {
    using namespace dinox::webrtc_runtime;
    if (DecideFfmpegHardwareRateUpdate(500000, 30, 490000, 29, 10) != HardwareRateUpdate::Keep ||
        DecideFfmpegHardwareRateUpdate(500000, 30, 550000, 30, 5000) != HardwareRateUpdate::Keep ||
        DecideFfmpegHardwareRateUpdate(500000, 30, 600000, 30, 999) != HardwareRateUpdate::Keep ||
        DecideFfmpegHardwareRateUpdate(500000, 30, 600000, 30, 1000) != HardwareRateUpdate::Reinitialize ||
        DecideFfmpegHardwareRateUpdate(500000, 30, 450000, 30, 1000) != HardwareRateUpdate::Reinitialize ||
        DecideFfmpegHardwareRateUpdate(500000, 30, 450000, 30, 999) != HardwareRateUpdate::SoftwareFallback ||
        DecideFfmpegHardwareRateUpdate(500000, 30, 500000, 15, 1) != HardwareRateUpdate::SoftwareFallback ||
        DecideFfmpegHardwareRateUpdate(UINT32_MAX, 30, UINT32_MAX, 30, 5000) != HardwareRateUpdate::Keep) {
        std::fputs("FAIL: hardware rate updates must bound restarts and fall back on rapid reductions\n", stderr);
        return 1;
    }
    for (int index = 0; index < 1000; ++index) {
        const uint32_t target = 500000 + (index % 2 ? 10000 : -10000);
        if (DecideFfmpegHardwareRateUpdate(500000, 30, target, 30, index * 20) != HardwareRateUpdate::Keep) return 1;
    }
    std::puts("OK: rate jitter does not restart hardware; substantial fast reductions use software");
    return 0;
}

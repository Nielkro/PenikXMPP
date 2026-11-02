#ifndef DINOX_WEBRTC_VP8_DECODE_QUALIFICATION_HPP
#define DINOX_WEBRTC_VP8_DECODE_QUALIFICATION_HPP

#include <algorithm>
#include <cmath>
#include <limits>
#include <vector>

namespace dinox::webrtc_runtime {

enum class Vp8DecodeQualificationReason {
    Qualified,
    InvalidFrames,
    InsufficientSamples,
    InvalidTiming,
    UnresolvedTiming,
    SlowerThanSoftware,
};

struct Vp8DecodeQualification {
    bool qualified = false;
    Vp8DecodeQualificationReason reason = Vp8DecodeQualificationReason::InvalidFrames;
    double software_p90_ms = 0.0;
    double hardware_p90_ms = 0.0;
    double limit_ms = 0.0;
};

inline const char* Vp8DecodeQualificationReasonName(Vp8DecodeQualificationReason reason) {
    switch (reason) {
        case Vp8DecodeQualificationReason::Qualified: return "qualified";
        case Vp8DecodeQualificationReason::InvalidFrames: return "invalid-frames";
        case Vp8DecodeQualificationReason::InsufficientSamples: return "insufficient-samples";
        case Vp8DecodeQualificationReason::InvalidTiming: return "invalid-timing";
        case Vp8DecodeQualificationReason::UnresolvedTiming: return "unresolved-timing";
        case Vp8DecodeQualificationReason::SlowerThanSoftware: return "slower-than-software";
    }
    return "unknown";
}

// Timings cover submission through usable I420 output and exclude warm-up
// frames. This relative latency check does not measure power consumption or
// certify driver stability outside the tested sequences and resolutions.
inline Vp8DecodeQualification EvaluateVp8DecodeQualification(
    bool valid_frames,
    const std::vector<double>& software_ms,
    const std::vector<double>& hardware_ms) {
    Vp8DecodeQualification result;
    if (!valid_frames) return result;
    if (software_ms.size() < 8 || hardware_ms.size() < 8) {
        result.reason = Vp8DecodeQualificationReason::InsufficientSamples;
        return result;
    }

    const auto valid_timing = [](const std::vector<double>& samples) {
        return std::all_of(samples.begin(), samples.end(), [](double value) {
            return std::isfinite(value) && value >= 0.0;
        });
    };
    if (!valid_timing(software_ms) || !valid_timing(hardware_ms)) {
        result.reason = Vp8DecodeQualificationReason::InvalidTiming;
        return result;
    }
    const auto resolved_timing = [](const std::vector<double>& samples) {
        return std::any_of(samples.begin(), samples.end(), [](double value) {
            return value > 0.0;
        });
    };
    if (!resolved_timing(software_ms) || !resolved_timing(hardware_ms)) {
        result.reason = Vp8DecodeQualificationReason::UnresolvedTiming;
        return result;
    }

    const auto p90 = [](std::vector<double> samples) {
        std::sort(samples.begin(), samples.end());
        // ceil(0.9 * n) - 1, without floating-point rank rounding or n * 9
        // overflow. Callers have already checked that n is at least eight.
        return samples[samples.size() - samples.size() / 10 - 1];
    };
    result.software_p90_ms = p90(software_ms);
    result.hardware_p90_ms = p90(hardware_ms);
    const double maximum = std::numeric_limits<double>::max();
    const double relative_limit = result.software_p90_ms > maximum / 1.25
        ? maximum : result.software_p90_ms * 1.25;
    const double absolute_limit = result.software_p90_ms > maximum - 0.75
        ? maximum : result.software_p90_ms + 0.75;
    result.limit_ms = std::max(relative_limit, absolute_limit);
    result.qualified = result.hardware_p90_ms <= result.limit_ms;
    result.reason = result.qualified ? Vp8DecodeQualificationReason::Qualified
                                    : Vp8DecodeQualificationReason::SlowerThanSoftware;
    return result;
}

}  // namespace dinox::webrtc_runtime

#endif

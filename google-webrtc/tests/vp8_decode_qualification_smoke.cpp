#include "dinox_webrtc_vp8_decode_qualification.hpp"

#include <cmath>
#include <cstdio>
#include <cstring>
#include <limits>
#include <vector>

namespace {

using dinox::webrtc_runtime::EvaluateVp8DecodeQualification;
using dinox::webrtc_runtime::Vp8DecodeQualification;
using dinox::webrtc_runtime::Vp8DecodeQualificationReason;
using dinox::webrtc_runtime::Vp8DecodeQualificationReasonName;
using Reason = Vp8DecodeQualificationReason;

bool expect(bool condition, const char* message) {
    if (!condition) std::fprintf(stderr, "FAIL: %s\n", message);
    return condition;
}

bool has_reason(const Vp8DecodeQualification& result, Reason reason) {
    return result.reason == reason && result.qualified == (reason == Reason::Qualified);
}

bool close_to(double actual, double expected) {
    return std::abs(actual - expected) < 1e-12;
}

std::vector<double> samples(double value) {
    return std::vector<double>(8, value);
}

bool faster_hardware() {
    const auto result = EvaluateVp8DecodeQualification(true, samples(4.0), samples(2.0));
    return expect(has_reason(result, Reason::Qualified) &&
        close_to(result.software_p90_ms, 4.0) && close_to(result.hardware_p90_ms, 2.0) &&
        close_to(result.limit_ms, 5.0), "faster hardware must qualify with reported measurements");
}

bool invalid_frames() {
    const auto result = EvaluateVp8DecodeQualification(false, samples(4.0), samples(2.0));
    return expect(has_reason(result, Reason::InvalidFrames),
        "incorrect output must disqualify otherwise fast hardware");
}

bool insufficient_samples() {
    return expect(has_reason(EvaluateVp8DecodeQualification(true, {}, samples(2.0)),
            Reason::InsufficientSamples) &&
        has_reason(EvaluateVp8DecodeQualification(true, samples(2.0), {}),
            Reason::InsufficientSamples) &&
        has_reason(EvaluateVp8DecodeQualification(true, std::vector<double>(7, 2.0), samples(2.0)),
            Reason::InsufficientSamples) &&
        has_reason(EvaluateVp8DecodeQualification(true, samples(2.0), std::vector<double>(7, 2.0)),
            Reason::InsufficientSamples), "each decoder needs at least eight post-warm-up samples");
}

bool invalid_timings() {
    for (double invalid : {-0.001, std::numeric_limits<double>::quiet_NaN(),
             std::numeric_limits<double>::infinity(),
             -std::numeric_limits<double>::infinity()}) {
        auto damaged = samples(2.0);
        damaged[0] = invalid;
        if (!expect(has_reason(EvaluateVp8DecodeQualification(true, damaged, samples(2.0)),
                Reason::InvalidTiming) &&
            has_reason(EvaluateVp8DecodeQualification(true, samples(2.0), damaged),
                Reason::InvalidTiming), "invalid timing anywhere in either decoder must be rejected")) {
            return false;
        }
    }
    return true;
}

bool unresolved_timings() {
    auto mixed = samples(1.0);
    mixed[0] = 0.0;
    return expect(has_reason(EvaluateVp8DecodeQualification(true, samples(0.0), samples(1.0)),
            Reason::UnresolvedTiming) &&
        has_reason(EvaluateVp8DecodeQualification(true, samples(1.0), samples(0.0)),
            Reason::UnresolvedTiming) &&
        has_reason(EvaluateVp8DecodeQualification(true, mixed, mixed), Reason::Qualified),
        "all-zero timing is unresolved, while individual finite zero samples are allowed");
}

bool absolute_boundary() {
    const auto equal = EvaluateVp8DecodeQualification(true, samples(1.0), samples(1.75));
    const auto below = EvaluateVp8DecodeQualification(true, samples(1.0),
        samples(std::nextafter(1.75, 0.0)));
    const auto above = EvaluateVp8DecodeQualification(true, samples(1.0),
        samples(std::nextafter(1.75, std::numeric_limits<double>::infinity())));
    return expect(close_to(equal.limit_ms, 1.75) && has_reason(equal, Reason::Qualified) &&
        has_reason(below, Reason::Qualified) && has_reason(above, Reason::SlowerThanSoftware),
        "the 0.75 ms boundary must include equality and exclude its next representable value");
}

bool relative_boundary() {
    const auto equal = EvaluateVp8DecodeQualification(true, samples(8.0), samples(10.0));
    const auto above = EvaluateVp8DecodeQualification(true, samples(8.0),
        samples(std::nextafter(10.0, std::numeric_limits<double>::infinity())));
    const auto crossover = EvaluateVp8DecodeQualification(true, samples(3.0), samples(3.75));
    return expect(close_to(equal.limit_ms, 10.0) && has_reason(equal, Reason::Qualified) &&
        has_reason(above, Reason::SlowerThanSoftware) &&
        close_to(crossover.limit_ms, 3.75) && has_reason(crossover, Reason::Qualified),
        "the 25 percent boundary and the two limits' crossover must retain equality");
}

bool nearest_rank() {
    // Fourteen samples have nearest-rank p90 at sorted index 12. The largest
    // outlier is therefore excluded, without interpolation between samples.
    const std::vector<double> software{100.0, 1.3, 0.2, 0.9, 0.1, 1.2, 0.4,
        1.1, 0.7, 0.3, 1.0, 0.6, 0.5, 0.8};
    const auto result = EvaluateVp8DecodeQualification(true, software,
        std::vector<double>(14, 1.0));
    const auto minimum = EvaluateVp8DecodeQualification(true,
        {1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 4.0}, samples(1.0));
    return expect(has_reason(result, Reason::Qualified) &&
        close_to(result.software_p90_ms, 1.3) && close_to(result.limit_ms, 2.05) &&
        close_to(minimum.software_p90_ms, 4.0),
        "nearest-rank p90 must use the correct rank for both fourteen and eight samples");
}

bool finite_limit() {
    const double maximum = std::numeric_limits<double>::max();
    const auto result = EvaluateVp8DecodeQualification(true, samples(maximum), samples(maximum));
    return expect(has_reason(result, Reason::Qualified) && std::isfinite(result.limit_ms) &&
        result.limit_ms == maximum, "finite inputs must not overflow the reported latency limit");
}

bool reason_names() {
    return expect(std::strcmp(Vp8DecodeQualificationReasonName(Reason::Qualified), "qualified") == 0 &&
        std::strcmp(Vp8DecodeQualificationReasonName(Reason::SlowerThanSoftware), "slower-than-software") == 0 &&
        std::strcmp(Vp8DecodeQualificationReasonName(Reason::InvalidFrames), "invalid-frames") == 0,
        "qualification results must expose stable diagnostic names");
}

}  // namespace

int main() {
    bool passed = true;
    for (const auto test : {faster_hardware, invalid_frames, insufficient_samples,
             invalid_timings, unresolved_timings, absolute_boundary, relative_boundary,
             nearest_rank, finite_limit, reason_names}) {
        if (!test()) passed = false;
    }
    if (!passed) return 1;
    std::puts("OK: VP8 decode qualification rejects invalid samples and applies nearest-rank latency limits");
    return 0;
}

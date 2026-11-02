#include "dinox_webrtc.h"

#include <atomic>
#include <array>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <initializer_list>
#include <limits>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#ifdef __linux__
#include <unistd.h>
#endif

namespace {

struct Options {
    DinoXWebrtcVideoEffectType effect = DINOX_WEBRTC_VIDEO_EFFECT_NONE;
    const char* effect_name = "off";
    bool attach_pipeline = true;
    int brightness = 0;
    int contrast = 0;
    int saturation = 0;
    int sharpness = 0;
    DinoXWebrtcVideoBackgroundMode background = DINOX_WEBRTC_VIDEO_BACKGROUND_NONE;
    int background_strength = 50;
    uint32_t background_color_rgb = UINT32_C(0x303030);
    DinoXWebrtcBackgroundBuiltin background_builtin = DINOX_WEBRTC_BACKGROUND_BUILTIN_OFFICE;
    bool background_strength_supplied = false;
    bool background_color_supplied = false;
    bool background_builtin_supplied = false;
    DinoXWebrtcVideoFramingMode framing = DINOX_WEBRTC_VIDEO_FRAMING_NONE;
    uint32_t glasses = 0;
    uint32_t hat = 0;
    uint32_t beard = 0;
    uint32_t face_accessory = 0;
    uint32_t touch_up = 0;
    uint32_t low_light = 0;
    uint32_t scene = 0;
    int sessions = 1;
    int width = 640;
    int height = 480;
    int fps = 30;
    int warmup_seconds = 30;
    int measure_seconds = 60;
};

struct State {
    std::mutex mutex;
    std::condition_variable changed;
    DinoXWebrtcVideoPipelineState pipeline = {};
    std::atomic<uint64_t> preview_frames{0};
    std::array<std::atomic<uint64_t>, 4> session_preview_frames{};
};

struct SessionObservation {
    State* state = nullptr;
    size_t index = 0;
};

struct NamedChoice {
    const char* name;
    uint32_t value;
};

constexpr NamedChoice kBackgrounds[] = {{"none", 0}, {"blur", 1}, {"solid", 2}, {"builtin", 3}};
constexpr NamedChoice kBuiltins[] = {
    {"living-room", 1}, {"office", 2}, {"cafe", 3}, {"stones", 4}, {"food", 5},
    {"abstract", 6}, {"beach", 7}, {"sunset", 8}, {"celebration", 9}, {"forest", 10}};
constexpr NamedChoice kFraming[] = {{"none", 0}, {"auto", 1}};
constexpr NamedChoice kGlasses[] = {{"none", 0}, {"sunglasses", 1}, {"round", 2}, {"rectangular", 3}};
constexpr NamedChoice kHats[] = {{"none", 0}, {"cap", 1}, {"cowboy", 2}, {"top-hat", 3}};
constexpr NamedChoice kBeards[] = {{"none", 0}, {"moustache", 1}, {"goatee", 2}, {"full-beard", 3}};
constexpr NamedChoice kAccessories[] = {{"none", 0}, {"puppy", 1}, {"karaoke-microphone", 2}};
constexpr NamedChoice kSwitch[] = {{"off", 0}, {"on", 1}, {"0", 0}, {"1", 1}};
constexpr NamedChoice kScenes[] = {{"none", 0}, {"fireworks", 1}, {"confetti", 2}, {"stars", 3}, {"football", 4}};

template <typename Value, size_t Count>
bool parse_choice(const char* text, const NamedChoice (&choices)[Count], Value* output) {
    if (text == nullptr || output == nullptr) return false;
    for (const auto& choice : choices) {
        if (std::strcmp(text, choice.name) == 0) {
            *output = static_cast<Value>(choice.value);
            return true;
        }
    }
    return false;
}

bool parse_color(const char* text, uint32_t* output) {
    if (text == nullptr || output == nullptr) return false;
    std::string value(text);
    if (value.compare(0, 2, "0x") == 0) value.erase(0, 2);
    else if (value.compare(0, 1, "#") == 0) value.erase(0, 1);
    if (value.size() != 6) return false;
    for (const char digit : value) {
        if (!((digit >= '0' && digit <= '9') || (digit >= 'a' && digit <= 'f') ||
                (digit >= 'A' && digit <= 'F'))) return false;
    }
    char* end = nullptr;
    const unsigned long color = std::strtoul(value.c_str(), &end, 16);
    if (end == value.c_str() || *end != '\0' || color > UINT32_C(0xffffff)) return false;
    *output = static_cast<uint32_t>(color);
    return true;
}

bool parse_integer(const char* value, int minimum, int maximum, int* output) {
    if (value == nullptr || output == nullptr || value[0] == '\0') return false;
    char* end = nullptr;
    const long parsed = std::strtol(value, &end, 10);
    if (end == value || *end != '\0' || parsed < minimum || parsed > maximum) {
        return false;
    }
    *output = static_cast<int>(parsed);
    return true;
}

bool parse_options(int argc, char** argv, Options* options) {
    if (options == nullptr) return false;
    for (int index = 1; index < argc; ++index) {
        if (std::strcmp(argv[index], "--effect") == 0 && index + 1 < argc) {
            const char* value = argv[++index];
            if (std::strcmp(value, "direct") == 0) {
                options->effect = DINOX_WEBRTC_VIDEO_EFFECT_NONE;
                options->effect_name = "direct";
                options->attach_pipeline = false;
            } else if (std::strcmp(value, "off") == 0) {
                options->effect = DINOX_WEBRTC_VIDEO_EFFECT_NONE;
                options->effect_name = "off";
                options->attach_pipeline = true;
            } else if (std::strcmp(value, "grayscale") == 0) {
                options->effect = DINOX_WEBRTC_VIDEO_EFFECT_GRAYSCALE;
                options->effect_name = "grayscale";
                options->attach_pipeline = true;
            } else if (std::strcmp(value, "warm-tone") == 0) {
                options->effect = DINOX_WEBRTC_VIDEO_EFFECT_WARM_TONE;
                options->effect_name = "warm-tone";
                options->attach_pipeline = true;
            } else if (std::strcmp(value, "cold-tone") == 0) {
                options->effect = DINOX_WEBRTC_VIDEO_EFFECT_COLD_TONE;
                options->effect_name = "cold-tone";
                options->attach_pipeline = true;
            } else if (std::strcmp(value, "sepia") == 0) {
                options->effect = DINOX_WEBRTC_VIDEO_EFFECT_SEPIA;
                options->effect_name = "sepia";
                options->attach_pipeline = true;
            } else if (std::strcmp(value, "light-leak") == 0) {
                options->effect = DINOX_WEBRTC_VIDEO_EFFECT_LIGHT_LEAK;
                options->effect_name = "light-leak";
                options->attach_pipeline = true;
            } else if (std::strcmp(value, "dreamy") == 0) {
                options->effect = DINOX_WEBRTC_VIDEO_EFFECT_DREAMY;
                options->effect_name = "dreamy";
                options->attach_pipeline = true;
            } else if (std::strcmp(value, "prism-light") == 0) {
                options->effect = DINOX_WEBRTC_VIDEO_EFFECT_PRISM_LIGHT;
                options->effect_name = "prism-light";
                options->attach_pipeline = true;
            } else if (std::strcmp(value, "fisheye") == 0) {
                options->effect = DINOX_WEBRTC_VIDEO_EFFECT_FISHEYE;
                options->effect_name = "fisheye";
                options->attach_pipeline = true;
            } else if (std::strcmp(value, "vintage-tv") == 0) {
                options->effect = DINOX_WEBRTC_VIDEO_EFFECT_VINTAGE_TV;
                options->effect_name = "vintage-tv";
                options->attach_pipeline = true;
            } else if (std::strcmp(value, "frosted-glass") == 0) {
                options->effect = DINOX_WEBRTC_VIDEO_EFFECT_FROSTED_GLASS;
                options->effect_name = "frosted-glass";
                options->attach_pipeline = true;
            } else if (std::strcmp(value, "duo-tone") == 0) {
                options->effect = DINOX_WEBRTC_VIDEO_EFFECT_DUO_TONE;
                options->effect_name = "duo-tone";
                options->attach_pipeline = true;
            } else if (std::strcmp(value, "underwater") == 0) {
                options->effect = DINOX_WEBRTC_VIDEO_EFFECT_UNDERWATER;
                options->effect_name = "underwater";
                options->attach_pipeline = true;
            } else if (std::strcmp(value, "adjustments") == 0) {
                options->effect = DINOX_WEBRTC_VIDEO_EFFECT_NONE;
                options->effect_name = "adjustments";
                options->attach_pipeline = true;
            } else {
                return false;
            }
        } else if (std::strcmp(argv[index], "--width") == 0 && index + 1 < argc) {
            if (!parse_integer(argv[++index], 16, 4096, &options->width)) return false;
        } else if (std::strcmp(argv[index], "--height") == 0 && index + 1 < argc) {
            if (!parse_integer(argv[++index], 16, 2160, &options->height)) return false;
        } else if (std::strcmp(argv[index], "--fps") == 0 && index + 1 < argc) {
            if (!parse_integer(argv[++index], 1, 120, &options->fps)) return false;
        } else if (std::strcmp(argv[index], "--warmup-seconds") == 0 &&
                index + 1 < argc) {
            if (!parse_integer(argv[++index], 1, 600, &options->warmup_seconds)) return false;
        } else if (std::strcmp(argv[index], "--measure-seconds") == 0 &&
                index + 1 < argc) {
            if (!parse_integer(argv[++index], 1, 3600, &options->measure_seconds)) return false;
        } else if (std::strcmp(argv[index], "--brightness") == 0 && index + 1 < argc) {
            if (!parse_integer(argv[++index], -100, 100, &options->brightness)) return false;
        } else if (std::strcmp(argv[index], "--contrast") == 0 && index + 1 < argc) {
            if (!parse_integer(argv[++index], -100, 100, &options->contrast)) return false;
        } else if (std::strcmp(argv[index], "--saturation") == 0 && index + 1 < argc) {
            if (!parse_integer(argv[++index], -100, 100, &options->saturation)) return false;
        } else if (std::strcmp(argv[index], "--sharpness") == 0 && index + 1 < argc) {
            if (!parse_integer(argv[++index], 0, 100, &options->sharpness)) return false;
        } else if (std::strcmp(argv[index], "--background") == 0 && index + 1 < argc) {
            if (!parse_choice(argv[++index], kBackgrounds, &options->background)) return false;
        } else if (std::strcmp(argv[index], "--background-strength") == 0 && index + 1 < argc) {
            if (!parse_integer(argv[++index], 0, 100, &options->background_strength)) return false;
            options->background_strength_supplied = true;
        } else if (std::strcmp(argv[index], "--background-color") == 0 && index + 1 < argc) {
            if (!parse_color(argv[++index], &options->background_color_rgb)) return false;
            options->background_color_supplied = true;
        } else if (std::strcmp(argv[index], "--background-builtin") == 0 && index + 1 < argc) {
            if (!parse_choice(argv[++index], kBuiltins, &options->background_builtin)) return false;
            options->background_builtin_supplied = true;
        } else if (std::strcmp(argv[index], "--framing") == 0 && index + 1 < argc) {
            if (!parse_choice(argv[++index], kFraming, &options->framing)) return false;
        } else if (std::strcmp(argv[index], "--glasses") == 0 && index + 1 < argc) {
            if (!parse_choice(argv[++index], kGlasses, &options->glasses)) return false;
        } else if (std::strcmp(argv[index], "--hat") == 0 && index + 1 < argc) {
            if (!parse_choice(argv[++index], kHats, &options->hat)) return false;
        } else if (std::strcmp(argv[index], "--beard") == 0 && index + 1 < argc) {
            if (!parse_choice(argv[++index], kBeards, &options->beard)) return false;
        } else if (std::strcmp(argv[index], "--face-accessory") == 0 && index + 1 < argc) {
            if (!parse_choice(argv[++index], kAccessories, &options->face_accessory)) return false;
        } else if (std::strcmp(argv[index], "--touch-up") == 0 && index + 1 < argc) {
            if (!parse_choice(argv[++index], kSwitch, &options->touch_up)) return false;
        } else if (std::strcmp(argv[index], "--low-light") == 0 && index + 1 < argc) {
            if (!parse_choice(argv[++index], kSwitch, &options->low_light)) return false;
        } else if ((std::strcmp(argv[index], "--scene") == 0 ||
                    std::strcmp(argv[index], "--scene-effect") == 0) && index + 1 < argc) {
            if (!parse_choice(argv[++index], kScenes, &options->scene)) return false;
        } else if (std::strcmp(argv[index], "--sessions") == 0 && index + 1 < argc) {
            if (!parse_integer(argv[++index], 1, 4, &options->sessions) ||
                    (options->sessions != 1 && options->sessions != 4)) return false;
        } else {
            return false;
        }
    }
    const bool adjustments = options->brightness != 0 || options->contrast != 0 ||
        options->saturation != 0 || options->sharpness != 0;
    if (adjustments && !options->attach_pipeline) return false;
    const bool advanced = options->background != DINOX_WEBRTC_VIDEO_BACKGROUND_NONE ||
        options->framing != DINOX_WEBRTC_VIDEO_FRAMING_NONE || options->glasses != 0 ||
        options->hat != 0 || options->beard != 0 || options->face_accessory != 0 ||
        options->touch_up != 0 || options->low_light != 0 || options->scene != 0;
    if (advanced && !options->attach_pipeline) return false;
    if (options->background_strength_supplied && options->background_strength != 0 &&
            options->background != DINOX_WEBRTC_VIDEO_BACKGROUND_BLUR) return false;
    if (options->background_color_supplied &&
            options->background != DINOX_WEBRTC_VIDEO_BACKGROUND_SOLID) return false;
    if (options->background_builtin_supplied &&
            options->background != DINOX_WEBRTC_VIDEO_BACKGROUND_IMAGE) return false;
    if (adjustments && options->effect == DINOX_WEBRTC_VIDEO_EFFECT_NONE) {
        options->effect_name = "adjustments";
    }
    return options->width % 2 == 0 && options->height % 2 == 0;
}

void print_usage(const char* program) {
    std::fprintf(
        stderr,
        "Usage: %s --effect direct|off|grayscale|warm-tone|cold-tone|sepia|light-leak|dreamy|"
        "prism-light|fisheye|vintage-tv|frosted-glass|duo-tone|underwater|adjustments "
        "[--brightness -100..100] [--contrast -100..100] [--saturation -100..100] "
        "[--sharpness 0..100] [--width 640] [--height 480] "
        "[--fps 30] [--warmup-seconds 30] [--measure-seconds 60] [--sessions 1|4] "
        "[--background none|blur|solid|builtin] [--background-strength 0..100] "
        "[--background-color RRGGBB] "
        "[--background-builtin living-room|office|cafe|stones|food|abstract|beach|sunset|celebration|forest] "
        "[--framing none|auto] [--glasses none|sunglasses|round|rectangular] "
        "[--hat none|cap|cowboy|top-hat] [--beard none|moustache|goatee|full-beard] "
        "[--face-accessory none|puppy|karaoke-microphone] [--touch-up off|on] "
        "[--low-light off|on] [--scene none|fireworks|confetti|stars|football]\n"
        "       %s --self-test (pure CLI contract checks, no context or worker)\n",
        program,
        program);
}

void on_pipeline_state(
    DinoXWebrtcVideoPipeline*,
    const DinoXWebrtcVideoPipelineState* pipeline,
    void* user_data) {
    if (pipeline == nullptr || user_data == nullptr) return;
    auto* state = static_cast<State*>(user_data);
    {
        std::lock_guard<std::mutex> lock(state->mutex);
        state->pipeline = *pipeline;
    }
    state->changed.notify_all();
}

void on_local_video_frame(
    DinoXWebrtcSession*,
    const uint8_t* bgra,
    int width,
    int height,
    int stride,
    uint64_t,
    void* user_data) {
    if (user_data == nullptr || bgra == nullptr || width <= 0 || height <= 0 ||
            stride < width * 4) {
        return;
    }
    auto* observation = static_cast<SessionObservation*>(user_data);
    if (observation->state == nullptr || observation->index >= 4) return;
    observation->state->preview_frames.fetch_add(1, std::memory_order_relaxed);
    observation->state->session_preview_frames[observation->index].fetch_add(1, std::memory_order_relaxed);
}

bool matches_config(const DinoXWebrtcVideoPipelineState& state,
                    const DinoXWebrtcVideoEffectConfig& config) {
    return state.abi_version == config.abi_version && state.effect_type == config.effect_type &&
        state.quality == config.quality && state.preset_id == config.preset_id &&
        state.asset_id == config.asset_id && state.reserved == config.reserved &&
        state.brightness == config.brightness && state.contrast == config.contrast &&
        state.saturation == config.saturation && state.sharpness == config.sharpness &&
        state.background_mode == config.background_mode &&
        state.background_strength == config.background_strength &&
        state.background_color_rgb == config.background_color_rgb &&
        state.framing_mode == config.framing_mode && state.glasses_style == config.glasses_style &&
        state.hat_style == config.hat_style && state.beard_style == config.beard_style &&
        state.face_accessory == config.face_accessory && state.touch_up == config.touch_up &&
        state.low_light == config.low_light && state.scene_effect == config.scene_effect;
}

bool wait_for_effect(State* state, uint64_t revision, const DinoXWebrtcVideoEffectConfig& config) {
    std::unique_lock<std::mutex> lock(state->mutex);
    return state->changed.wait_for(lock, std::chrono::seconds(5), [&] {
        return state->pipeline.application_state ==
                DINOX_WEBRTC_VIDEO_EFFECT_APPLICATION_APPLIED &&
            state->pipeline.accepted_revision == revision &&
            state->pipeline.applied_revision == revision &&
            matches_config(state->pipeline, config);
    });
}

DinoXWebrtcVideoEffectConfig requested_config(const Options& options) {
    DinoXWebrtcVideoEffectConfig config = dinox_webrtc_video_effect_config_default();
    config.effect_type = options.effect;
    config.brightness = options.brightness;
    config.contrast = options.contrast;
    config.saturation = options.saturation;
    config.sharpness = options.sharpness;
    config.background_mode = options.background;
    config.background_strength = options.background == DINOX_WEBRTC_VIDEO_BACKGROUND_BLUR ?
        options.background_strength : 0;
    config.background_color_rgb = options.background == DINOX_WEBRTC_VIDEO_BACKGROUND_SOLID ?
        options.background_color_rgb : 0;
    config.framing_mode = options.framing;
    config.glasses_style = options.glasses;
    config.hat_style = options.hat;
    config.beard_style = options.beard;
    config.face_accessory = options.face_accessory;
    config.touch_up = options.touch_up;
    config.low_light = options.low_light;
    config.scene_effect = options.scene;
    return config;
}

bool active_config(const DinoXWebrtcVideoEffectConfig& config) {
    return config.effect_type != DINOX_WEBRTC_VIDEO_EFFECT_NONE || config.brightness != 0 ||
        config.contrast != 0 || config.saturation != 0 || config.sharpness != 0 ||
        config.background_mode != DINOX_WEBRTC_VIDEO_BACKGROUND_NONE ||
        config.framing_mode != DINOX_WEBRTC_VIDEO_FRAMING_NONE || config.glasses_style != 0 ||
        config.hat_style != 0 || config.beard_style != 0 || config.face_accessory != 0 ||
        config.touch_up != 0 || config.low_light != 0 || config.scene_effect != 0;
}

void print_config(const DinoXWebrtcVideoPipelineState& state) {
    std::printf(
        "{\"abi_version\":%u,\"effect_type\":%u,\"quality\":%u,\"preset_id\":%u,"
        "\"asset_id\":%u,\"reserved\":%u,\"brightness\":%d,\"contrast\":%d,"
        "\"saturation\":%d,\"sharpness\":%d,\"background_mode\":%u,"
        "\"background_strength\":%d,\"background_color_rgb\":%u,\"framing_mode\":%u,"
        "\"glasses_style\":%u,\"hat_style\":%u,\"beard_style\":%u,\"face_accessory\":%u,"
        "\"touch_up\":%u,\"low_light\":%u,\"scene_effect\":%u}",
        state.abi_version, static_cast<unsigned>(state.effect_type), static_cast<unsigned>(state.quality),
        state.preset_id, state.asset_id, state.reserved, state.brightness, state.contrast,
        state.saturation, state.sharpness, static_cast<unsigned>(state.background_mode),
        state.background_strength, state.background_color_rgb, static_cast<unsigned>(state.framing_mode),
        state.glasses_style, state.hat_style, state.beard_style, state.face_accessory,
        state.touch_up, state.low_light, state.scene_effect);
}

int parser_self_test() {
    const auto check = [](std::initializer_list<const char*> values, bool expected) {
        std::vector<char*> arguments;
        for (const char* value : values) arguments.push_back(const_cast<char*>(value));
        Options options;
        return parse_options(static_cast<int>(arguments.size()), arguments.data(), &options) == expected;
    };
    const bool passed =
        check({"baseline", "--effect", "direct"}, true) &&
        check({"baseline", "--effect", "off", "--sessions", "4"}, true) &&
        check({"baseline", "--effect", "underwater", "--background", "builtin",
            "--background-builtin", "forest", "--framing", "auto", "--glasses", "round",
            "--hat", "cowboy", "--beard", "goatee", "--face-accessory", "puppy",
            "--touch-up", "on", "--low-light", "on", "--scene", "confetti", "--sessions", "4"}, true) &&
        check({"baseline", "--background", "blur", "--background-strength", "50"}, true) &&
        check({"baseline", "--background", "solid", "--background-color", "abcdef"}, true) &&
        check({"baseline", "--effect", "direct", "--background", "blur"}, false) &&
        check({"baseline", "--effect", "direct", "--scene", "stars"}, false) &&
        check({"baseline", "--background", "none", "--background-builtin", "office"}, false) &&
        check({"baseline", "--background", "solid", "--background-strength", "50"}, false) &&
        check({"baseline", "--background", "solid", "--background-color", "+00000"}, false) &&
        check({"baseline", "--sessions", "2"}, false) &&
        check({"baseline", "--framing", "unknown"}, false) &&
        check({"baseline", "--touch-up", "2"}, false) &&
        check({"baseline", "--width", "641"}, false) &&
        check({"baseline", "--hat"}, false);
    std::fprintf(passed ? stdout : stderr, "baseline CLI contract self-test: %s\n", passed ? "PASS" : "FAIL");
    return passed ? 0 : 1;
}

struct TimingWindowSummary {
    uint64_t rolling_p95_max_us = 0;
    uint64_t rolling_p99_max_us = 0;
    uint64_t processing_max_us = 0;
    uint64_t observations = 0;
    uint64_t rss_self_sampled_max_bytes = 0;
    uint64_t rss_tree_sampled_max_bytes = 0;
    uint64_t rss_observations = 0;
    uint32_t rss_tree_sampled_max_processes = 0;
    bool rss_tree_sample_incomplete = false;
};

struct MemorySample {
    uint64_t self_bytes = 0;
    uint64_t tree_sum_bytes = 0;
    uint32_t tree_processes = 0;
    bool measured = false;
    bool tree_complete = false;
};

MemorySample sample_memory() {
    MemorySample sample;
#ifdef __linux__
    const long page_size = sysconf(_SC_PAGESIZE);
    if (page_size <= 0) return sample;
    const auto rss = [page_size](int pid, uint64_t* output) {
        uint64_t virtual_pages = 0, resident_pages = 0;
        std::ifstream statm("/proc/" + std::to_string(pid) + "/statm");
        if (!(statm >> virtual_pages >> resident_pages) || resident_pages >
                std::numeric_limits<uint64_t>::max() / static_cast<uint64_t>(page_size)) return false;
        *output = resident_pages * static_cast<uint64_t>(page_size);
        return true;
    };
    const int self = static_cast<int>(getpid());
    sample.measured = rss(self, &sample.self_bytes);
    if (!sample.measured) return sample;
    struct Parent { int pid; int parent; };
    std::vector<Parent> parents;
    std::error_code error;
    const std::filesystem::directory_iterator end;
    for (std::filesystem::directory_iterator entry("/proc", error);
            !error && entry != end; entry.increment(error)) {
        int pid = 0;
        if (!parse_integer(entry->path().filename().string().c_str(), 1,
                std::numeric_limits<int>::max(), &pid)) continue;
        std::ifstream status(entry->path() / "status");
        std::string line;
        while (std::getline(status, line)) {
            int parent = 0;
            if (line.compare(0, 5, "PPid:") == 0 && parse_integer(line.c_str() + 5, 0,
                    std::numeric_limits<int>::max(), &parent)) {
                parents.push_back({pid, parent});
                break;
            }
        }
        if (parents.size() > 65536) return sample;
    }
    if (error) return sample;
    std::vector<int> tree{self};
    sample.tree_complete = true;
    for (size_t index = 0; index < tree.size(); ++index) {
        for (const auto& process : parents) {
            if (process.parent != tree[index]) continue;
            bool known = false;
            for (int pid : tree) known = known || pid == process.pid;
            if (!known) tree.push_back(process.pid);
        }
        if (tree.size() > 1024) { sample.tree_complete = false; break; }
    }
    for (int pid : tree) {
        uint64_t bytes = 0;
        if (!rss(pid, &bytes) || bytes > std::numeric_limits<uint64_t>::max() - sample.tree_sum_bytes) {
            sample.tree_complete = false;
            continue;
        }
        sample.tree_sum_bytes += bytes;
        ++sample.tree_processes;
    }
#endif
    return sample;
}

void record_memory(const MemorySample& memory, TimingWindowSummary* summary) {
    if (summary == nullptr || !memory.measured) return;
    ++summary->rss_observations;
    if (memory.self_bytes > summary->rss_self_sampled_max_bytes)
        summary->rss_self_sampled_max_bytes = memory.self_bytes;
    if (memory.tree_sum_bytes > summary->rss_tree_sampled_max_bytes)
        summary->rss_tree_sampled_max_bytes = memory.tree_sum_bytes;
    if (memory.tree_processes > summary->rss_tree_sampled_max_processes)
        summary->rss_tree_sampled_max_processes = memory.tree_processes;
    summary->rss_tree_sample_incomplete = summary->rss_tree_sample_incomplete || !memory.tree_complete;
}

void record_timing_window(
    const DinoXWebrtcVideoEffectDiagnostics& diagnostics,
    TimingWindowSummary* summary) {
    if (summary == nullptr) return;
    if (diagnostics.processing_time_p95_us > summary->rolling_p95_max_us) {
        summary->rolling_p95_max_us = diagnostics.processing_time_p95_us;
    }
    if (diagnostics.processing_time_p99_us > summary->rolling_p99_max_us) {
        summary->rolling_p99_max_us = diagnostics.processing_time_p99_us;
    }
    if (diagnostics.processing_time_max_us > summary->processing_max_us) {
        summary->processing_max_us = diagnostics.processing_time_max_us;
    }
    summary->observations++;
}

bool observe_timing_window(
    DinoXWebrtcVideoPipeline* pipeline,
    TimingWindowSummary* summary) {
    if (summary == nullptr) return true;
    record_memory(sample_memory(), summary);
    if (pipeline == nullptr) return true;
    DinoXWebrtcVideoEffectDiagnostics diagnostics = {};
    if (dinox_webrtc_video_pipeline_get_diagnostics(pipeline, &diagnostics) !=
            DINOX_WEBRTC_STATUS_OK) {
        return false;
    }
    record_timing_window(diagnostics, summary);
    return true;
}

bool send_frames(
    const std::array<DinoXWebrtcSession*, 4>& sessions,
    int source_count,
    int width,
    int height,
    int fps,
    int seconds,
    uint64_t* submitted,
    DinoXWebrtcVideoPipeline* observed_pipeline = nullptr,
    TimingWindowSummary* timing = nullptr) {
    if (source_count < 1 || source_count > 4 || submitted == nullptr) return false;
    const uint64_t frame_count =
        static_cast<uint64_t>(fps) * static_cast<uint64_t>(seconds);
    const auto interval = std::chrono::nanoseconds(1000000000LL / fps);
    auto deadline = std::chrono::steady_clock::now();
    for (uint64_t frame = 0; frame < frame_count; ++frame) {
        for (int index = 0; index < source_count; ++index) {
            DinoXWebrtcSession* session = sessions[static_cast<size_t>(index)];
            if (session == nullptr || dinox_webrtc_session_push_synthetic_video_frame(session, width, height) !=
                    DINOX_WEBRTC_STATUS_OK) return false;
            (*submitted)++;
        }
        if (timing != nullptr && (frame + 1) % static_cast<uint64_t>(fps) == 0 &&
                !observe_timing_window(observed_pipeline, timing)) {
            return false;
        }
        deadline += interval;
        std::this_thread::sleep_until(deadline);
    }
    return true;
}

uint64_t delta(uint64_t after, uint64_t before) {
    return after >= before ? after - before : 0;
}

}  // namespace

int main(int argc, char** argv) {
    if (argc == 2 && std::strcmp(argv[1], "--self-test") == 0) return parser_self_test();
    if (argc == 2 && std::strcmp(argv[1], "--help") == 0) { print_usage(argv[0]); return 0; }
    Options options;
    if (!parse_options(argc, argv, &options)) {
        print_usage(argv[0]);
        return 2;
    }

    State state;
    DinoXWebrtcContext* context = nullptr;
    std::array<DinoXWebrtcSession*, 4> sessions{};
    std::array<SessionObservation, 4> observations{};
    std::array<DinoXWebrtcSessionState, 4> sessions_before{};
    std::array<DinoXWebrtcSessionState, 4> sessions_after{};
    std::array<uint64_t, 4> previews_before{};
    DinoXWebrtcVideoPipeline* pipeline = nullptr;
    DinoXWebrtcVideoEffectDiagnostics before = {};
    DinoXWebrtcVideoEffectDiagnostics after = {};
    TimingWindowSummary timing;
    DinoXWebrtcVideoEffectConfig config = requested_config(options);
    DinoXWebrtcVideoPipelineState accepted_config = {};
    DinoXWebrtcVideoPipelineState final_config = {};
    MemorySample memory_before, memory_after;
    uint32_t staged_background = 0;
    uint64_t revision = 0;
    uint64_t config_apply_wait_us = 0;
    uint64_t background_staging_us = 0;
    const int source_count = options.attach_pipeline ? 1 : options.sessions;
    uint64_t preview_before = 0;
    uint64_t preview_after = 0;
    uint64_t submitted = 0;
    std::chrono::steady_clock::time_point measure_start;
    std::chrono::steady_clock::time_point measure_end;
    double elapsed_seconds = 0.0;
    int result = 1;

    if (dinox_webrtc_context_new(&context) != DINOX_WEBRTC_STATUS_OK) {
        std::fprintf(stderr, "baseline: failed to create libwebrtc context\n");
        goto cleanup;
    }

    for (int index = 0; index < options.sessions; ++index) {
        const size_t slot = static_cast<size_t>(index);
        observations[slot] = {&state, slot};
        DinoXWebrtcSessionConfig session_config = dinox_webrtc_session_config_default();
        DinoXWebrtcCallbacks callbacks = dinox_webrtc_callbacks_default();
        callbacks.on_local_video_frame = on_local_video_frame;
        if (dinox_webrtc_session_new(
                context, &session_config, &callbacks, &observations[slot], &sessions[slot]) != DINOX_WEBRTC_STATUS_OK) {
            std::fprintf(stderr, "baseline: failed to create video session\n");
            goto cleanup;
        }
    }

    if (options.attach_pipeline) {
        DinoXWebrtcVideoPipelineCallbacks callbacks =
            dinox_webrtc_video_pipeline_callbacks_default();
        callbacks.on_state_changed = on_pipeline_state;
        if (dinox_webrtc_video_pipeline_new(
                context, 88001, &callbacks, &state, &pipeline) != DINOX_WEBRTC_STATUS_OK) {
            std::fprintf(stderr, "baseline: failed to create or attach video pipeline\n");
            goto cleanup;
        }
        for (int index = 0; index < options.sessions; ++index) {
            if (dinox_webrtc_video_pipeline_attach_session(pipeline,
                    sessions[static_cast<size_t>(index)], index == 0 ? 1 : 0) != DINOX_WEBRTC_STATUS_OK) {
                std::fprintf(stderr, "baseline: failed to attach fanout session\n");
                goto cleanup;
            }
        }
    }

    if (config.background_mode == DINOX_WEBRTC_VIDEO_BACKGROUND_IMAGE) {
        const auto begin = std::chrono::steady_clock::now();
        if (dinox_webrtc_video_pipeline_background_builtin(pipeline, options.background_builtin,
                &staged_background) != DINOX_WEBRTC_STATUS_OK || staged_background == 0 ||
                dinox_webrtc_video_pipeline_background_prepare(pipeline, staged_background) != DINOX_WEBRTC_STATUS_OK) {
            std::fprintf(stderr, "baseline: actual builtin background staging failed\n");
            goto cleanup;
        }
        background_staging_us = static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(
            std::chrono::steady_clock::now() - begin).count());
        config.asset_id = staged_background;
    }
    if (active_config(config)) {
        const auto begin = std::chrono::steady_clock::now();
        if (dinox_webrtc_video_pipeline_set_config(pipeline, &config, &revision) !=
                DINOX_WEBRTC_STATUS_OK ||
            !wait_for_effect(&state, revision, config)) {
            std::fprintf(
                stderr, "baseline: %s did not become applied\n", options.effect_name);
            goto cleanup;
        }
        config_apply_wait_us = static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(
            std::chrono::steady_clock::now() - begin).count());
    }
    if (pipeline != nullptr && (dinox_webrtc_video_pipeline_get_state(pipeline, &accepted_config) !=
            DINOX_WEBRTC_STATUS_OK || !matches_config(accepted_config, config) ||
            accepted_config.subscriber_count != static_cast<uint32_t>(options.sessions))) {
        std::fprintf(stderr, "baseline: accepted configuration/fanout differs from the request\n");
        goto cleanup;
    }

    std::printf(
        "DINOX_VIDEO_EFFECT_BASELINE_READY effect=%s width=%d height=%d fps=%d sessions=%d\n",
        options.effect_name, options.width, options.height, options.fps, options.sessions);
    std::printf("DINOX_VIDEO_EFFECT_BASELINE_ACCEPTED_CONFIG ");
    if (pipeline != nullptr) print_config(accepted_config);
    else std::printf("null");
    std::printf("\n");
    std::fflush(stdout);

    {
        uint64_t warmup_submitted = 0;
        if (!send_frames(
                sessions, source_count, options.width, options.height, options.fps,
                options.warmup_seconds, &warmup_submitted)) {
            std::fprintf(stderr, "baseline: warm-up frame submission failed\n");
            goto cleanup;
        }
    }
    for (int index = 0; index < options.sessions; ++index) {
        const size_t slot = static_cast<size_t>(index);
        if (dinox_webrtc_session_get_state(sessions[slot], &sessions_before[slot]) != DINOX_WEBRTC_STATUS_OK) {
            std::fprintf(stderr, "baseline: failed to snapshot pre-measurement fanout\n");
            goto cleanup;
        }
        previews_before[slot] = state.session_preview_frames[slot].load(std::memory_order_relaxed);
    }
    memory_before = sample_memory();
    record_memory(memory_before, &timing);

    if (pipeline != nullptr) {
        if (dinox_webrtc_video_pipeline_get_diagnostics(pipeline, &before) !=
                DINOX_WEBRTC_STATUS_OK) {
            std::fprintf(stderr, "baseline: failed to read pre-measurement diagnostics\n");
            goto cleanup;
        }
        record_timing_window(before, &timing);
    }
    preview_before = state.preview_frames.load(std::memory_order_relaxed);
    std::printf("DINOX_VIDEO_EFFECT_BASELINE_MEASURE effect=%s\n", options.effect_name);
    std::fflush(stdout);

    measure_start = std::chrono::steady_clock::now();
    if (!send_frames(
            sessions, source_count, options.width, options.height, options.fps,
            options.measure_seconds, &submitted, pipeline, &timing)) {
        std::fprintf(stderr, "baseline: measurement frame submission failed\n");
        goto cleanup;
    }
    measure_end = std::chrono::steady_clock::now();
    std::this_thread::sleep_for(std::chrono::milliseconds(250));
    for (int index = 0; index < options.sessions; ++index) {
        const size_t slot = static_cast<size_t>(index);
        if (dinox_webrtc_session_get_state(sessions[slot], &sessions_after[slot]) != DINOX_WEBRTC_STATUS_OK) {
            std::fprintf(stderr, "baseline: failed to snapshot post-measurement fanout\n");
            goto cleanup;
        }
    }
    memory_after = sample_memory();
    record_memory(memory_after, &timing);

    if (pipeline != nullptr) {
        if (dinox_webrtc_video_pipeline_get_diagnostics(pipeline, &after) !=
                DINOX_WEBRTC_STATUS_OK) {
            std::fprintf(stderr, "baseline: failed to read post-measurement diagnostics\n");
            goto cleanup;
        }
        record_timing_window(after, &timing);
        if (dinox_webrtc_video_pipeline_get_state(pipeline, &final_config) != DINOX_WEBRTC_STATUS_OK) {
            std::fprintf(stderr, "baseline: failed to read final pipeline state\n");
            goto cleanup;
        }
    }
    preview_after = state.preview_frames.load(std::memory_order_relaxed);
    elapsed_seconds =
        std::chrono::duration<double>(measure_end - measure_start).count();

    std::printf(
        "DINOX_VIDEO_EFFECT_BASELINE_RESULT "
        "{\"effect\":\"%s\",\"width\":%d,\"height\":%d,\"fps\":%d,"
        "\"brightness\":%d,\"contrast\":%d,\"saturation\":%d,\"sharpness\":%d,"
        "\"warmup_seconds\":%d,\"measure_seconds\":%.6f,"
        "\"submitted\":%llu,\"preview_frames\":%llu,"
        "\"captured\":%llu,\"enqueued\":%llu,\"processed\":%llu,"
        "\"bypassed\":%llu,\"queue_replaced\":%llu,\"failed\":%llu,"
        "\"watchdog_bypass\":%llu,\"frame_copy_count\":%llu,"
        "\"processing_time_rolling_p95_max_us\":%llu,"
        "\"processing_time_rolling_p99_max_us\":%llu,"
        "\"processing_time_max_us\":%llu,"
        "\"diagnostic_observation_count\":%llu,"
        "\"effect_owned_allocated_bytes\":%llu,"
        "\"effect_thread_count\":%u,\"effect_handle_count\":%u,",
        options.effect_name,
        options.width,
        options.height,
        options.fps,
        options.brightness,
        options.contrast,
        options.saturation,
        options.sharpness,
        options.warmup_seconds,
        elapsed_seconds,
        static_cast<unsigned long long>(submitted),
        static_cast<unsigned long long>(preview_after - preview_before),
        static_cast<unsigned long long>(delta(after.captured, before.captured)),
        static_cast<unsigned long long>(delta(after.enqueued, before.enqueued)),
        static_cast<unsigned long long>(delta(after.processed, before.processed)),
        static_cast<unsigned long long>(delta(after.bypassed, before.bypassed)),
        static_cast<unsigned long long>(delta(after.queue_replaced, before.queue_replaced)),
        static_cast<unsigned long long>(delta(after.failed, before.failed)),
        static_cast<unsigned long long>(delta(after.watchdog_bypass, before.watchdog_bypass)),
        static_cast<unsigned long long>(delta(after.frame_copy_count, before.frame_copy_count)),
        static_cast<unsigned long long>(timing.rolling_p95_max_us),
        static_cast<unsigned long long>(timing.rolling_p99_max_us),
        static_cast<unsigned long long>(timing.processing_max_us),
        static_cast<unsigned long long>(timing.observations),
        static_cast<unsigned long long>(after.effect_owned_allocated_bytes),
        after.effect_thread_count,
        after.effect_handle_count);
    std::printf("\"accepted_config\":");
    if (pipeline != nullptr) print_config(accepted_config);
    else std::printf("null");
    std::printf(
        ",\"config_origin\":\"%s\",\"config_apply_wait_us\":%llu,"
        "\"background_builtin\":%u,\"background_staging_us\":%llu,"
        "\"accepted_revision\":%llu,\"final_accepted_revision\":%llu,\"final_applied_revision\":%llu,"
        "\"final_application_state\":%u,\"final_config\":",
        !options.attach_pipeline ? "direct_no_pipeline" : (active_config(config) ? "set_config_applied" : "default_pipeline_state"),
        static_cast<unsigned long long>(config_apply_wait_us),
        staged_background != 0 ? static_cast<unsigned>(options.background_builtin) : 0,
        static_cast<unsigned long long>(background_staging_us),
        static_cast<unsigned long long>(accepted_config.accepted_revision),
        static_cast<unsigned long long>(final_config.accepted_revision),
        static_cast<unsigned long long>(final_config.applied_revision), static_cast<unsigned>(final_config.application_state));
    if (pipeline != nullptr) print_config(final_config);
    else std::printf("null");
    std::printf(
        ",\"input_fixture\":\"black_synthetic_frame\",\"sessions\":%d,\"source_inputs_per_tick\":%d,"
        "\"fanout_mode\":\"%s\",\"fanout_scope\":\"local_video_source_publication_no_peer_negotiation\","
        "\"logical_pipeline_count\":%u,\"pipeline_subscriber_count\":%u,\"fanout_sessions\":[",
        options.sessions, source_count, options.attach_pipeline ? "shared_pipeline" : "independent_direct_sources",
        after.logical_pipeline_count, after.subscriber_count);
    for (int index = 0; index < options.sessions; ++index) {
        const size_t slot = static_cast<size_t>(index);
        const uint64_t published = delta(sessions_after[slot].local_video_source_frame_count,
                                        sessions_before[slot].local_video_source_frame_count);
        const uint64_t expected = submitted / static_cast<uint64_t>(source_count);
        std::printf("%s{\"session\":%d,\"local_source_frames\":%llu,\"preview_frames\":%llu,"
                    "\"unpublished_input_frames\":%llu,\"outbound_frames_encoded\":%llu,\"outbound_frames_sent\":%llu}",
            index == 0 ? "" : ",", index,
            static_cast<unsigned long long>(published),
            static_cast<unsigned long long>(delta(state.session_preview_frames[slot].load(std::memory_order_relaxed), previews_before[slot])),
            static_cast<unsigned long long>(delta(expected, published)),
            static_cast<unsigned long long>(delta(sessions_after[slot].outbound_video_frames_encoded, sessions_before[slot].outbound_video_frames_encoded)),
            static_cast<unsigned long long>(delta(sessions_after[slot].outbound_video_frames_sent, sessions_before[slot].outbound_video_frames_sent)));
    }
    std::printf("],\"processing_time_total_us\":%llu,\"processing_time_mean_us\":",
        static_cast<unsigned long long>(delta(after.processing_time_total_us, before.processing_time_total_us)));
    if (delta(after.processed, before.processed) != 0) std::printf("%.3f",
        static_cast<double>(delta(after.processing_time_total_us, before.processing_time_total_us)) /
        static_cast<double>(delta(after.processed, before.processed)));
    else std::printf("null");
    std::printf(
        ",\"mask_wait_time_us\":null,\"mask_wait_time_measured\":false,"
        "\"mask_wait_reason\":\"not_exposed_by_public_C_API\","
        "\"face_detection_measured\":false,"
        "\"processing_scope\":\"pipeline_executor_excludes_async_model_inference\","
        "\"processing_time_max_scope\":\"pipeline_lifetime_including_warmup\","
        "\"processing_percentiles_scope\":\"rolling_native_windows_may_include_warmup\","
        "\"rss_scope\":\"%s\",\"rss_measured\":%s,"
        "\"rss_observation_count\":%llu,\"rss_tree_sampled_max_processes\":%u,"
        "\"rss_tree_samples_have_missing_reads\":%s,\"rss_self_before_bytes\":",
        timing.rss_observations != 0 ? "linux_visible_process_tree_sum_best_effort_shared_pages_counted_per_process" : "not_measured",
        timing.rss_observations != 0 ? "true" : "false",
        static_cast<unsigned long long>(timing.rss_observations), timing.rss_tree_sampled_max_processes,
        timing.rss_tree_sample_incomplete ? "true" : "false");
    if (memory_before.measured) std::printf("%llu", static_cast<unsigned long long>(memory_before.self_bytes));
    else std::printf("null");
    std::printf(",\"rss_self_after_bytes\":");
    if (memory_after.measured) std::printf("%llu", static_cast<unsigned long long>(memory_after.self_bytes));
    else std::printf("null");
    std::printf(",\"rss_self_sampled_max_bytes\":");
    if (timing.rss_observations != 0) std::printf("%llu", static_cast<unsigned long long>(timing.rss_self_sampled_max_bytes));
    else std::printf("null");
    std::printf(",\"rss_tree_sampled_max_bytes\":");
    if (timing.rss_tree_sampled_max_processes != 0) std::printf("%llu", static_cast<unsigned long long>(timing.rss_tree_sampled_max_bytes));
    else std::printf("null");
    std::printf("}\n");
    std::fflush(stdout);
    result = 0;

cleanup:
    if (pipeline != nullptr) {
        if (staged_background != 0) dinox_webrtc_video_pipeline_background_release(pipeline, staged_background);
        dinox_webrtc_video_pipeline_free(pipeline);
    }
    for (DinoXWebrtcSession* session : sessions) {
        if (session == nullptr) continue;
        dinox_webrtc_session_close(session);
        dinox_webrtc_session_free(session);
    }
    if (context != nullptr) dinox_webrtc_context_free(context);
    return result;
}

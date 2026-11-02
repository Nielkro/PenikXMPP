#include "media_foundation_writer.h"

#ifdef _WIN32

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#define DINOX_CHECK(expression) do { \
    if (!(expression)) { \
        std::fprintf(stderr, "CHECK failed at %s:%d: %s\n", __FILE__, __LINE__, #expression); \
        std::exit(1); \
    } \
} while (0)

static std::string temp_path(const char* filename) {
    char directory[MAX_PATH + 1] = {};
    const DWORD length = GetTempPathA(MAX_PATH, directory);
    DINOX_CHECK(length > 0 && length < MAX_PATH);
    return std::string(directory) + filename;
}

static uint64_t file_size(const std::string& path) {
    WIN32_FILE_ATTRIBUTE_DATA data = {};
    if (!GetFileAttributesExA(path.c_str(), GetFileExInfoStandard, &data)) return 0;
    return (static_cast<uint64_t>(data.nFileSizeHigh) << 32) | data.nFileSizeLow;
}

static std::vector<uint8_t> make_pcm(unsigned int first_sample, unsigned int sample_count) {
    std::vector<uint8_t> bytes(sample_count * 2u);
    for (unsigned int index = 0; index < sample_count; ++index) {
        const double phase = static_cast<double>(first_sample + index) * 440.0 * 6.283185307179586 / 48000.0;
        const int16_t sample = static_cast<int16_t>(std::sin(phase) * 4000.0);
        bytes[index * 2] = static_cast<uint8_t>(sample & 0xff);
        bytes[index * 2 + 1] = static_cast<uint8_t>((static_cast<uint16_t>(sample) >> 8) & 0xff);
    }
    return bytes;
}

int main() {
    const std::string audio_path = temp_path("dinox-mf-audio-smoke.m4a");
    const std::string video_path = temp_path("dinox-mf-video-smoke.mp4");
    DeleteFileA(audio_path.c_str());
    DeleteFileA(video_path.c_str());

    DinoXMediaFoundationWriter* audio = dinox_mf_writer_new_audio(
        audio_path.c_str(), 48000, 1, 2, 64000);
    DINOX_CHECK(audio != nullptr);
    if (!dinox_mf_writer_is_ready(audio)) {
        std::fprintf(stderr, "Audio writer: %s\n", dinox_mf_writer_last_error(audio));
        return 2;
    }
    for (unsigned int frame = 0; frame < 100; ++frame) {
        const std::vector<uint8_t> pcm = make_pcm(frame * 480u, 480u);
        DINOX_CHECK(dinox_mf_writer_write_audio(audio, pcm.data(), pcm.size(), 48000, 1, 2));
    }
    DINOX_CHECK(dinox_mf_writer_finish(audio));
    dinox_mf_writer_free(audio);
    DINOX_CHECK(file_size(audio_path) > 512);

    constexpr int width = 320;
    constexpr int height = 240;
    std::vector<uint8_t> bgra(static_cast<size_t>(width) * height * 4u);
    DinoXMediaFoundationWriter* video = dinox_mf_writer_new_video(
        video_path.c_str(), width, height, 15, 350000, 1, 48000, 1, 2, 64000);
    DINOX_CHECK(video != nullptr);
    if (!dinox_mf_writer_is_ready(video)) {
        std::fprintf(stderr, "Video writer: %s\n", dinox_mf_writer_last_error(video));
        return 3;
    }
    unsigned int audio_frame = 0;
    for (int frame = 0; frame < 30; ++frame) {
        for (int y = 0; y < height; ++y) {
            for (int x = 0; x < width; ++x) {
                const size_t offset = (static_cast<size_t>(y) * width + x) * 4u;
                bgra[offset] = static_cast<uint8_t>((x + frame * 3) & 0xff);
                bgra[offset + 1] = static_cast<uint8_t>((y + frame * 2) & 0xff);
                bgra[offset + 2] = static_cast<uint8_t>((x + y + frame) & 0xff);
                bgra[offset + 3] = 255;
            }
        }
        DINOX_CHECK(dinox_mf_writer_write_bgra(
            video, bgra.data(), bgra.size(), width, height, width * 4));
        for (int audio_block = 0; audio_block < 7; ++audio_block) {
            const std::vector<uint8_t> pcm = make_pcm(audio_frame * 480u, 480u);
            DINOX_CHECK(dinox_mf_writer_write_audio(video, pcm.data(), pcm.size(), 48000, 1, 2));
            audio_frame++;
        }
    }
    DINOX_CHECK(dinox_mf_writer_finish(video));
    dinox_mf_writer_free(video);
    DINOX_CHECK(file_size(video_path) > 4096);

    const char* keep_output = std::getenv("DINOX_KEEP_MF_SMOKE_OUTPUT");
    if (keep_output != nullptr && std::strcmp(keep_output, "1") == 0) {
        std::printf("Audio output: %s\nVideo output: %s\n", audio_path.c_str(), video_path.c_str());
    } else {
        DeleteFileA(audio_path.c_str());
        DeleteFileA(video_path.c_str());
    }
    std::puts("Media Foundation AAC/H.264 writer smoke OK");
    return 0;
}

#else
int main() { return 0; }
#endif

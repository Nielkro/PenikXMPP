#include "media_foundation_writer.h"

#ifdef _WIN32

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <combaseapi.h>
#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mfreadwrite.h>

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <new>
#include <string>
#include <vector>

namespace {

template <typename T>
void release_com(T*& value) {
    if (value != nullptr) {
        value->Release();
        value = nullptr;
    }
}

std::string hresult_text(const char* operation, HRESULT result) {
    char buffer[160] = {};
    std::snprintf(
        buffer,
        sizeof(buffer),
        "%s failed (HRESULT 0x%08lx)",
        operation,
        static_cast<unsigned long>(result));
    return buffer;
}

std::wstring utf8_to_wide(const char* value) {
    if (value == nullptr || value[0] == '\0') return {};
    const int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value, -1, nullptr, 0);
    if (count <= 1) return {};
    std::wstring output(static_cast<size_t>(count), L'\0');
    if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value, -1, output.data(), count) <= 0) {
        return {};
    }
    output.resize(static_cast<size_t>(count - 1));
    return output;
}

uint8_t clamp_byte(int value) {
    return static_cast<uint8_t>(std::clamp(value, 0, 255));
}

void bgra_to_nv12(
        const uint8_t* bgra,
        int width,
        int height,
        int stride,
        std::vector<uint8_t>* output) {
    output->resize(static_cast<size_t>(width) * static_cast<size_t>(height) * 3u / 2u);
    uint8_t* y_plane = output->data();
    uint8_t* uv_plane = y_plane + static_cast<size_t>(width) * static_cast<size_t>(height);

    for (int y = 0; y < height; ++y) {
        const uint8_t* row = bgra + static_cast<size_t>(y) * static_cast<size_t>(stride);
        uint8_t* y_row = y_plane + static_cast<size_t>(y) * static_cast<size_t>(width);
        for (int x = 0; x < width; ++x) {
            const int b = row[x * 4];
            const int g = row[x * 4 + 1];
            const int r = row[x * 4 + 2];
            y_row[x] = clamp_byte(((66 * r + 129 * g + 25 * b + 128) >> 8) + 16);
        }
    }

    for (int y = 0; y < height; y += 2) {
        uint8_t* uv_row = uv_plane + static_cast<size_t>(y / 2) * static_cast<size_t>(width);
        for (int x = 0; x < width; x += 2) {
            int sum_u = 0;
            int sum_v = 0;
            for (int dy = 0; dy < 2; ++dy) {
                const uint8_t* row = bgra + static_cast<size_t>(y + dy) * static_cast<size_t>(stride);
                for (int dx = 0; dx < 2; ++dx) {
                    const int b = row[(x + dx) * 4];
                    const int g = row[(x + dx) * 4 + 1];
                    const int r = row[(x + dx) * 4 + 2];
                    sum_u += ((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128;
                    sum_v += ((112 * r - 94 * g - 18 * b + 128) >> 8) + 128;
                }
            }
            uv_row[x] = clamp_byte((sum_u + 2) / 4);
            uv_row[x + 1] = clamp_byte((sum_v + 2) / 4);
        }
    }
}

HRESULT create_sample(
        const uint8_t* data,
        size_t byte_count,
        LONGLONG timestamp,
        LONGLONG duration,
        IMFSample** out_sample) {
    if (data == nullptr || byte_count == 0 || byte_count > MAXDWORD || out_sample == nullptr) {
        return E_INVALIDARG;
    }
    *out_sample = nullptr;
    IMFMediaBuffer* buffer = nullptr;
    IMFSample* sample = nullptr;
    HRESULT result = MFCreateMemoryBuffer(static_cast<DWORD>(byte_count), &buffer);
    if (SUCCEEDED(result)) {
        BYTE* destination = nullptr;
        result = buffer->Lock(&destination, nullptr, nullptr);
        if (SUCCEEDED(result)) {
            std::memcpy(destination, data, byte_count);
            buffer->Unlock();
            result = buffer->SetCurrentLength(static_cast<DWORD>(byte_count));
        }
    }
    if (SUCCEEDED(result)) result = MFCreateSample(&sample);
    if (SUCCEEDED(result)) result = sample->AddBuffer(buffer);
    if (SUCCEEDED(result)) result = sample->SetSampleTime(timestamp);
    if (SUCCEEDED(result)) result = sample->SetSampleDuration(duration);
    release_com(buffer);
    if (FAILED(result)) {
        release_com(sample);
        return result;
    }
    *out_sample = sample;
    return S_OK;
}

}  // namespace

struct _DinoXMediaFoundationWriter {
    IMFSinkWriter* sink = nullptr;
    DWORD audio_stream = 0;
    DWORD video_stream = 0;
    std::wstring output_path;
    std::string last_error;
    int sample_rate = 0;
    int channels = 0;
    int bytes_per_sample = 0;
    int width = 0;
    int height = 0;
    int fps = 0;
    uint64_t audio_sample_frames = 0;
    uint64_t video_frames = 0;
    bool has_audio = false;
    bool has_video = false;
    bool ready = false;
    bool finished = false;
    bool mf_started = false;
    bool co_uninitialize = false;

    void fail(const char* operation, HRESULT result) {
        last_error = hresult_text(operation, result);
    }

    bool initialize(const char* path) {
        output_path = utf8_to_wide(path);
        if (output_path.empty()) {
            last_error = "Output path is empty or is not valid UTF-8";
            return false;
        }

        const HRESULT com_result = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
        if (com_result == S_OK || com_result == S_FALSE) {
            co_uninitialize = true;
        } else if (com_result != RPC_E_CHANGED_MODE) {
            fail("CoInitializeEx", com_result);
            return false;
        }

        HRESULT result = MFStartup(MF_VERSION, MFSTARTUP_FULL);
        if (FAILED(result)) {
            fail("MFStartup", result);
            return false;
        }
        mf_started = true;

        IMFAttributes* attributes = nullptr;
        result = MFCreateAttributes(&attributes, 2);
        if (SUCCEEDED(result)) {
            result = attributes->SetUINT32(MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, TRUE);
        }
        if (SUCCEEDED(result)) {
            result = attributes->SetUINT32(MF_SINK_WRITER_DISABLE_THROTTLING, TRUE);
        }
        if (SUCCEEDED(result)) {
            result = MFCreateSinkWriterFromURL(output_path.c_str(), nullptr, attributes, &sink);
        }
        release_com(attributes);
        if (FAILED(result)) {
            fail("MFCreateSinkWriterFromURL", result);
            return false;
        }
        return true;
    }

    bool add_audio(int rate, int channel_count, int sample_bytes, int bitrate_bps) {
        if (rate <= 0 || channel_count <= 0 || sample_bytes != 2 || bitrate_bps <= 0) {
            last_error = "Unsupported PCM/AAC configuration";
            return false;
        }
        IMFMediaType* output_type = nullptr;
        IMFMediaType* input_type = nullptr;
        HRESULT result = MFCreateMediaType(&output_type);
        if (SUCCEEDED(result)) result = output_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
        if (SUCCEEDED(result)) result = output_type->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_AAC);
        if (SUCCEEDED(result)) result = output_type->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, channel_count);
        if (SUCCEEDED(result)) result = output_type->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, rate);
        if (SUCCEEDED(result)) result = output_type->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, sample_bytes * 8);
        if (SUCCEEDED(result)) result = output_type->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, bitrate_bps / 8);
        if (SUCCEEDED(result)) result = output_type->SetUINT32(MF_MT_AAC_PAYLOAD_TYPE, 0);
        if (SUCCEEDED(result)) result = output_type->SetUINT32(MF_MT_AAC_AUDIO_PROFILE_LEVEL_INDICATION, 0x29);
        if (SUCCEEDED(result)) result = sink->AddStream(output_type, &audio_stream);

        if (SUCCEEDED(result)) result = MFCreateMediaType(&input_type);
        if (SUCCEEDED(result)) result = input_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
        if (SUCCEEDED(result)) result = input_type->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM);
        if (SUCCEEDED(result)) result = input_type->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, channel_count);
        if (SUCCEEDED(result)) result = input_type->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, rate);
        if (SUCCEEDED(result)) result = input_type->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, sample_bytes * 8);
        if (SUCCEEDED(result)) result = input_type->SetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT, channel_count * sample_bytes);
        if (SUCCEEDED(result)) {
            result = input_type->SetUINT32(
                MF_MT_AUDIO_AVG_BYTES_PER_SECOND,
                rate * channel_count * sample_bytes);
        }
        if (SUCCEEDED(result)) result = sink->SetInputMediaType(audio_stream, input_type, nullptr);
        release_com(input_type);
        release_com(output_type);
        if (FAILED(result)) {
            fail("Configuring Media Foundation AAC stream", result);
            return false;
        }
        sample_rate = rate;
        channels = channel_count;
        bytes_per_sample = sample_bytes;
        has_audio = true;
        return true;
    }

    bool add_video(int frame_width, int frame_height, int frame_rate, int bitrate_bps) {
        if (frame_width <= 0 || frame_height <= 0 || (frame_width & 1) != 0 ||
                (frame_height & 1) != 0 || frame_rate <= 0 || bitrate_bps <= 0) {
            last_error = "Media Foundation H.264 requires positive even geometry";
            return false;
        }
        IMFMediaType* output_type = nullptr;
        IMFMediaType* input_type = nullptr;
        HRESULT result = MFCreateMediaType(&output_type);
        if (SUCCEEDED(result)) result = output_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
        if (SUCCEEDED(result)) result = output_type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264);
        if (SUCCEEDED(result)) result = output_type->SetUINT32(MF_MT_AVG_BITRATE, bitrate_bps);
        if (SUCCEEDED(result)) result = output_type->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
        if (SUCCEEDED(result)) result = output_type->SetUINT32(MF_MT_MPEG2_PROFILE, 66);
        if (SUCCEEDED(result)) result = MFSetAttributeSize(output_type, MF_MT_FRAME_SIZE, frame_width, frame_height);
        if (SUCCEEDED(result)) result = MFSetAttributeRatio(output_type, MF_MT_FRAME_RATE, frame_rate, 1);
        if (SUCCEEDED(result)) result = MFSetAttributeRatio(output_type, MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
        if (SUCCEEDED(result)) result = sink->AddStream(output_type, &video_stream);

        if (SUCCEEDED(result)) result = MFCreateMediaType(&input_type);
        if (SUCCEEDED(result)) result = input_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
        if (SUCCEEDED(result)) result = input_type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12);
        if (SUCCEEDED(result)) result = input_type->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
        if (SUCCEEDED(result)) result = MFSetAttributeSize(input_type, MF_MT_FRAME_SIZE, frame_width, frame_height);
        if (SUCCEEDED(result)) result = MFSetAttributeRatio(input_type, MF_MT_FRAME_RATE, frame_rate, 1);
        if (SUCCEEDED(result)) result = MFSetAttributeRatio(input_type, MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
        if (SUCCEEDED(result)) result = sink->SetInputMediaType(video_stream, input_type, nullptr);
        release_com(input_type);
        release_com(output_type);
        if (FAILED(result)) {
            fail("Configuring Media Foundation H.264 stream", result);
            return false;
        }
        width = frame_width;
        height = frame_height;
        fps = frame_rate;
        has_video = true;
        return true;
    }

    bool begin() {
        const HRESULT result = sink != nullptr ? sink->BeginWriting() : E_UNEXPECTED;
        if (FAILED(result)) {
            fail("IMFSinkWriter::BeginWriting", result);
            return false;
        }
        ready = true;
        return true;
    }

    void shutdown() {
        release_com(sink);
        if (mf_started) {
            MFShutdown();
            mf_started = false;
        }
        if (co_uninitialize) {
            CoUninitialize();
            co_uninitialize = false;
        }
        ready = false;
    }
};

extern "C" DinoXMediaFoundationWriter* dinox_mf_writer_new_audio(
        const char* output_path,
        int sample_rate,
        int channels,
        int bytes_per_sample,
        int bitrate_bps) {
    auto* writer = new (std::nothrow) DinoXMediaFoundationWriter();
    if (writer == nullptr) return nullptr;
    if (!writer->initialize(output_path) ||
            !writer->add_audio(sample_rate, channels, bytes_per_sample, bitrate_bps) ||
            !writer->begin()) {
        writer->shutdown();
    }
    return writer;
}

extern "C" DinoXMediaFoundationWriter* dinox_mf_writer_new_video(
        const char* output_path,
        int width,
        int height,
        int max_fps,
        int video_bitrate_bps,
        int include_audio,
        int audio_sample_rate,
        int audio_channels,
        int audio_bytes_per_sample,
        int audio_bitrate_bps) {
    auto* writer = new (std::nothrow) DinoXMediaFoundationWriter();
    if (writer == nullptr) return nullptr;
    bool success = writer->initialize(output_path) &&
        writer->add_video(width, height, max_fps, video_bitrate_bps);
    if (success && include_audio != 0) {
        success = writer->add_audio(
            audio_sample_rate,
            audio_channels,
            audio_bytes_per_sample,
            audio_bitrate_bps);
    }
    if (success) success = writer->begin();
    if (!success) writer->shutdown();
    return writer;
}

extern "C" int dinox_mf_writer_is_ready(const DinoXMediaFoundationWriter* writer) {
    return writer != nullptr && writer->ready ? 1 : 0;
}

extern "C" const char* dinox_mf_writer_last_error(const DinoXMediaFoundationWriter* writer) {
    if (writer == nullptr) return "Media Foundation writer allocation failed";
    return writer->last_error.empty() ? "Media Foundation writer error" : writer->last_error.c_str();
}

extern "C" int dinox_mf_writer_write_audio(
        DinoXMediaFoundationWriter* writer,
        const uint8_t* data,
        size_t byte_count,
        int sample_rate,
        int channels,
        int bytes_per_sample) {
    if (writer == nullptr || !writer->ready || !writer->has_audio || data == nullptr ||
            sample_rate != writer->sample_rate || channels != writer->channels ||
            bytes_per_sample != writer->bytes_per_sample) {
        if (writer != nullptr) writer->last_error = "Unexpected Media Foundation PCM frame format or state";
        return 0;
    }
    const size_t block = static_cast<size_t>(channels) * static_cast<size_t>(bytes_per_sample);
    if (block == 0 || byte_count == 0 || byte_count % block != 0) {
        writer->last_error = "Invalid Media Foundation PCM frame size";
        return 0;
    }
    const uint64_t frame_count = byte_count / block;
    const LONGLONG timestamp = static_cast<LONGLONG>(writer->audio_sample_frames * 10000000ull / sample_rate);
    const LONGLONG end = static_cast<LONGLONG>((writer->audio_sample_frames + frame_count) * 10000000ull / sample_rate);
    IMFSample* sample = nullptr;
    HRESULT result = create_sample(data, byte_count, timestamp, end - timestamp, &sample);
    if (SUCCEEDED(result)) result = writer->sink->WriteSample(writer->audio_stream, sample);
    release_com(sample);
    if (FAILED(result)) {
        writer->fail("Writing Media Foundation audio sample", result);
        return 0;
    }
    writer->audio_sample_frames += frame_count;
    return 1;
}

extern "C" int dinox_mf_writer_write_bgra(
        DinoXMediaFoundationWriter* writer,
        const uint8_t* data,
        size_t byte_count,
        int width,
        int height,
        int stride) {
    if (writer == nullptr || !writer->ready || !writer->has_video || data == nullptr ||
            width != writer->width || height != writer->height || stride < width * 4 ||
            byte_count < static_cast<size_t>(stride) * static_cast<size_t>(height)) {
        if (writer != nullptr) writer->last_error = "Unexpected Media Foundation BGRA frame format or state";
        return 0;
    }
    try {
        std::vector<uint8_t> nv12;
        bgra_to_nv12(data, width, height, stride, &nv12);
        const LONGLONG timestamp = static_cast<LONGLONG>(writer->video_frames * 10000000ull / writer->fps);
        const LONGLONG end = static_cast<LONGLONG>((writer->video_frames + 1) * 10000000ull / writer->fps);
        IMFSample* sample = nullptr;
        HRESULT result = create_sample(nv12.data(), nv12.size(), timestamp, end - timestamp, &sample);
        if (SUCCEEDED(result)) result = writer->sink->WriteSample(writer->video_stream, sample);
        release_com(sample);
        if (FAILED(result)) {
            writer->fail("Writing Media Foundation video sample", result);
            return 0;
        }
    } catch (...) {
        writer->last_error = "Allocating Media Foundation NV12 frame failed";
        return 0;
    }
    writer->video_frames++;
    return 1;
}

extern "C" int dinox_mf_writer_finish(DinoXMediaFoundationWriter* writer) {
    if (writer == nullptr || !writer->ready || writer->sink == nullptr || writer->finished) {
        if (writer != nullptr) writer->last_error = "Media Foundation writer is not active";
        return 0;
    }
    const HRESULT result = writer->sink->Finalize();
    if (FAILED(result)) {
        writer->fail("IMFSinkWriter::Finalize", result);
        writer->shutdown();
        return 0;
    }
    writer->finished = true;
    writer->shutdown();
    return 1;
}

extern "C" void dinox_mf_writer_cancel(DinoXMediaFoundationWriter* writer) {
    if (writer == nullptr) return;
    writer->shutdown();
    if (!writer->finished && !writer->output_path.empty()) {
        _wremove(writer->output_path.c_str());
    }
}

extern "C" void dinox_mf_writer_free(DinoXMediaFoundationWriter* writer) {
    if (writer == nullptr) return;
    if (!writer->finished) dinox_mf_writer_cancel(writer);
    delete writer;
}

#else

struct _DinoXMediaFoundationWriter {};

#endif

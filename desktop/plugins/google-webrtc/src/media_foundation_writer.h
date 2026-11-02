#ifndef DINOX_MEDIA_FOUNDATION_WRITER_H
#define DINOX_MEDIA_FOUNDATION_WRITER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct _DinoXMediaFoundationWriter DinoXMediaFoundationWriter;

DinoXMediaFoundationWriter* dinox_mf_writer_new_audio(
    const char* output_path,
    int sample_rate,
    int channels,
    int bytes_per_sample,
    int bitrate_bps);

DinoXMediaFoundationWriter* dinox_mf_writer_new_video(
    const char* output_path,
    int width,
    int height,
    int max_fps,
    int video_bitrate_bps,
    int include_audio,
    int audio_sample_rate,
    int audio_channels,
    int audio_bytes_per_sample,
    int audio_bitrate_bps);

int dinox_mf_writer_is_ready(const DinoXMediaFoundationWriter* writer);
const char* dinox_mf_writer_last_error(const DinoXMediaFoundationWriter* writer);

int dinox_mf_writer_write_audio(
    DinoXMediaFoundationWriter* writer,
    const uint8_t* data,
    size_t byte_count,
    int sample_rate,
    int channels,
    int bytes_per_sample);

int dinox_mf_writer_write_bgra(
    DinoXMediaFoundationWriter* writer,
    const uint8_t* data,
    size_t byte_count,
    int width,
    int height,
    int stride);

int dinox_mf_writer_finish(DinoXMediaFoundationWriter* writer);
void dinox_mf_writer_cancel(DinoXMediaFoundationWriter* writer);
void dinox_mf_writer_free(DinoXMediaFoundationWriter* writer);

#ifdef __cplusplus
}
#endif

#endif

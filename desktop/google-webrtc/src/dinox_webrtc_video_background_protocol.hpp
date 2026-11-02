#ifndef DINOX_WEBRTC_VIDEO_BACKGROUND_PROTOCOL_HPP
#define DINOX_WEBRTC_VIDEO_BACKGROUND_PROTOCOL_HPP
#include "dinox_webrtc.h"
#include <cstddef>
#include <cstdint>
namespace dinox::video_background_protocol {
constexpr size_t kMaxBytes=8*1024*1024;
constexpr size_t kChunkBytes=64*1024;
// Shared validation before ANY allocation, source retirement or IPC mutation.
inline bool valid_upload(uint32_t width,uint32_t height,uint32_t stride,
                         uint32_t format,size_t bytes) {
    if(!width||!height||width>1920||height>1920||uint64_t(width)*height>2073600||
            format>1||!bytes||bytes>kMaxBytes||stride>kMaxBytes)return false;
    const size_t row=size_t(width)*(format==0?3:4),rows=height-1;
    return stride>=row&&(!rows||stride<=(kMaxBytes-row)/rows)&&
        bytes>=rows*stride+row;
}
}
#endif

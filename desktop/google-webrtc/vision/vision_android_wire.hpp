// Copyright 2026 DinoX contributors.
// SPDX-License-Identifier: Apache-2.0
#ifndef DINOX_VISION_ANDROID_WIRE_HPP
#define DINOX_VISION_ANDROID_WIRE_HPP

// SDK-free equivalent of VideoVisionWire v1. No JNI, Binder or model runtime.
// Packets own no pointers on the wire; Request payload spans borrow their input.
#include <algorithm>
#include <array>
#include <bit>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <limits>
#include <optional>
#include <span>
#include <vector>

#include "face_decoder.hpp"

namespace dinox::vision::android_wire {
static_assert(sizeof(float)==4&&sizeof(double)==8&&std::numeric_limits<float>::is_iec559&&
    std::numeric_limits<double>::is_iec559,"Android vision packets require IEEE-754 binary32/binary64");
constexpr uint32_t kVersion=1;
constexpr size_t kHeaderBytes=256;
constexpr uint32_t kRequestMagic=UINT32_C(0x51565744);
constexpr uint32_t kResultMagic=UINT32_C(0x52565744);
constexpr uint32_t kSegmentDemand=1,kFaceDemand=2;
constexpr size_t kSegmentRgbBytes=110592,kFaceRgbBytes=49152;
constexpr size_t kMaskBytes=36864,kFaceBytes=68;
constexpr size_t kMaxRequestBytes=kHeaderBytes+kSegmentRgbBytes+kFaceRgbBytes;
constexpr size_t kMaxResultBytes=kHeaderBytes+kMaskBytes+kFaceBytes;
constexpr uint64_t kMaxAgeNs=UINT64_C(500000000);
using Header=std::array<uint8_t,kHeaderBytes>;

inline uint32_t read32(std::span<const uint8_t> bytes,size_t offset) {
    if (bytes.size()<4||offset>bytes.size()-4) std::abort();
    const auto field=bytes.subspan(offset,4);
    return uint32_t(field[0])|(uint32_t(field[1])<<8)|(uint32_t(field[2])<<16)|(uint32_t(field[3])<<24);
}
inline uint64_t read64(std::span<const uint8_t> bytes,size_t offset) {
    if (bytes.size()<8||offset>bytes.size()-8) std::abort();
    return uint64_t(read32(bytes,offset))|(uint64_t(read32(bytes,offset+4))<<32);
}
inline double read_double(std::span<const uint8_t> bytes,size_t offset) {
    return std::bit_cast<double>(read64(bytes,offset));
}
inline void write32(std::span<uint8_t> bytes,size_t offset,uint32_t value) {
    if (bytes.size()<4||offset>bytes.size()-4) std::abort();
    const auto field=bytes.subspan(offset,4);
    for (size_t i=0;i<4;++i) field[i]=uint8_t(value>>(i*8));
}
inline void write64(std::span<uint8_t> bytes,size_t offset,uint64_t value) {
    if (bytes.size()<8||offset>bytes.size()-8) std::abort();
    write32(bytes,offset,uint32_t(value));write32(bytes,offset+4,uint32_t(value>>32));
}
inline void write_double(std::span<uint8_t> bytes,size_t offset,double value) {
    write64(bytes,offset,std::bit_cast<uint64_t>(value));
}
inline void write_float(std::span<uint8_t> bytes,size_t offset,float value) {
    write32(bytes,offset,std::bit_cast<uint32_t>(value));
}

struct Identity {
    uint64_t call=0,source=0,revision=0,transform=0,frame=0,media_ns=0,capture_ns=0;
};
struct ContentRect {
    uint32_t left=0,top=0,width=0,height=0;
    bool operator==(const ContentRect&) const=default;
};
inline ContentRect letterbox(uint32_t width,uint32_t height,uint32_t canvas_width,uint32_t canvas_height) {
    if (!width||!height||!canvas_width||!canvas_height) return {};
    ContentRect box;
    if (uint64_t(width)*canvas_height>=uint64_t(height)*canvas_width) {
        box.width=canvas_width;
        box.height=uint32_t(std::max(UINT64_C(1),(uint64_t(height)*box.width+width/2)/width));
    } else {
        box.height=canvas_height;
        box.width=uint32_t(std::max(UINT64_C(1),(uint64_t(width)*box.height+height/2)/height));
    }
    box.left=(canvas_width-box.width)/2;box.top=(canvas_height-box.height)/2;
    return box;
}
struct Request {
    Header header{};
    Identity identity;
    uint32_t demand=0;
    std::span<const uint8_t> segment_rgb;
    std::span<const uint8_t> face_rgb;
};
// Only owned bytes/scalars may be retained after the request packet is released.
struct History {
    Header header{};
    Identity identity;
    uint32_t demand=0;
};
inline bool positive_java_long(uint64_t value) {
    return value&&value<=uint64_t(std::numeric_limits<int64_t>::max());
}
inline bool dimensions(uint32_t width,uint32_t height) {
    return width&&height&&width<=4096&&height<=4096&&uint64_t(width)*height<=UINT64_C(8847360);
}
inline bool box_matches(std::span<const uint8_t> bytes,size_t offset,ContentRect box) {
    return read32(bytes,offset)==box.left&&read32(bytes,offset+4)==box.top&&
        read32(bytes,offset+8)==box.width&&read32(bytes,offset+12)==box.height;
}
inline std::optional<Request> parse_request(std::span<const uint8_t> packet) {
    if (packet.size()<kHeaderBytes||packet.size()>kMaxRequestBytes) return std::nullopt;
    const auto bytes=packet.first(kHeaderBytes);
    if (read32(bytes,0)!=kRequestMagic||read32(bytes,4)!=kVersion||read32(bytes,8)!=kHeaderBytes||
            read32(bytes,12)!=packet.size()||read32(bytes,100)) return std::nullopt;
    for (size_t i=224;i<kHeaderBytes;++i) if (bytes[i]) return std::nullopt;
    Request result;
    result.identity={read64(bytes,16),read64(bytes,24),read64(bytes,32),read64(bytes,40),
        read64(bytes,48),read64(bytes,56),read64(bytes,64)};
    const auto& id=result.identity;
    if (!positive_java_long(id.call)||!positive_java_long(id.source)||!positive_java_long(id.revision)||
            !positive_java_long(id.transform)||!positive_java_long(id.frame)||!positive_java_long(id.capture_ns)||
            id.media_ns>uint64_t(std::numeric_limits<int64_t>::max())) return std::nullopt;
    result.demand=read32(bytes,72);
    const auto sw=read32(bytes,76),sh=read32(bytes,80),aw=read32(bytes,84),ah=read32(bytes,88);
    const auto rotation=read32(bytes,92),mirror=read32(bytes,96);
    if (result.demand<1||result.demand>3||!dimensions(sw,sh)||!dimensions(aw,ah)||mirror>1||
            (rotation!=0&&rotation!=90&&rotation!=180&&rotation!=270)) return std::nullopt;
    std::array<double,4> crop;
    for (size_t i=0;i<crop.size();++i) {
        crop[i]=read_double(bytes,104+i*8);
        if (!std::isfinite(crop[i])) return std::nullopt;
    }
    if (crop[0]<0||crop[1]<0||crop[2]<=0||crop[3]<=0||crop[0]+crop[2]>1||crop[1]+crop[3]>1) return std::nullopt;
    std::array<double,6> affine;
    for (size_t i=0;i<affine.size();++i) {
        affine[i]=read_double(bytes,136+i*8);
        if (!std::isfinite(affine[i])) return std::nullopt;
    }
    const double determinant=affine[0]*affine[4]-affine[1]*affine[3];
    if (!std::isfinite(determinant)||std::abs(determinant)<1e-12||
            !box_matches(bytes,184,letterbox(aw,ah,256,144))||
            !box_matches(bytes,200,letterbox(aw,ah,128,128))) return std::nullopt;
    const size_t segment_size=(result.demand&kSegmentDemand)?kSegmentRgbBytes:0;
    const size_t face_size=(result.demand&kFaceDemand)?kFaceRgbBytes:0;
    if (read32(bytes,216)!=segment_size||read32(bytes,220)!=face_size||
            packet.size()!=kHeaderBytes+segment_size+face_size) return std::nullopt;
    std::ranges::copy(bytes,result.header.begin());
    result.segment_rgb=packet.subspan(kHeaderBytes,segment_size);
    result.face_rgb=packet.subspan(kHeaderBytes+segment_size,face_size);
    return result;
}
inline History history(const Request& request) {
    return {request.header,request.identity,request.demand};
}
inline bool fresh(const Request& request,uint64_t now_ns) {
    return positive_java_long(request.identity.capture_ns)&&now_ns>=request.identity.capture_ns&&
        now_ns-request.identity.capture_ns<=kMaxAgeNs;
}
inline bool follows(const History& previous,const Request& next) {
    const auto& a=previous.identity;const auto& b=next.identity;
    if (b.call!=a.call||b.source<a.source||b.revision<a.revision||b.transform<a.transform||
            (b.revision==a.revision&&next.demand!=previous.demand)) return false;
    if (b.transform==a.transform) {
        // source/analyzed dimensions, rotation, mirror, crop, affine and both
        // exact model letterboxes are all part of one immutable transform ID.
        for (size_t i=76;i<216;++i) if (previous.header[i]!=next.header[i]) return false;
    }
    return b.source!=a.source||(b.frame>a.frame&&b.capture_ns>=a.capture_ns);
}
inline bool valid_face(const Face& face) {
    if (!std::isfinite(face.score)||face.score<0.5f||face.score>1||
            !face_detail::usable_box(face)||!face_detail::usable_points(face)||!face_detail::intersects_canvas(face)) return false;
    // The Android body stores float width/height, whereas Face stores edges.
    // Validate the exact double reconstruction performed by Java FaceBounds so
    // rounding cannot emit an invalid box. Unrepresentable edge slivers fail;
    // coordinates are never clamped or replaced with a synthetic detection.
    const float width=face.right-face.left,height=face.bottom-face.top;
    const double right=double(face.left)+double(width),bottom=double(face.top)+double(height);
    return std::isfinite(right)&&std::isfinite(bottom)&&std::abs(right)<=4&&std::abs(bottom)<=4&&
        face.left<1&&face.top<1&&right>0&&bottom>0;
}
inline std::optional<std::vector<uint8_t>> encode_result(const Request& request,
        std::span<const uint8_t> mask,const Face* face) {
    const size_t expected_mask=(request.demand&kSegmentDemand)?kMaskBytes:0;
    if (mask.size()!=expected_mask||(face&&(!(request.demand&kFaceDemand)||!valid_face(*face)))) return std::nullopt;
    const size_t face_bytes=face?kFaceBytes:0;
    std::vector<uint8_t> output(kHeaderBytes+mask.size()+face_bytes);
    std::ranges::copy(request.header,std::span(output).first(kHeaderBytes).begin());
    write32(output,0,kResultMagic);write32(output,12,uint32_t(output.size()));
    write32(output,216,uint32_t(mask.size()));write32(output,220,uint32_t(face_bytes));
    std::ranges::copy(mask,std::span(output).subspan(kHeaderBytes,mask.size()).begin());
    if (face) {
        const auto bytes=std::span(output).subspan(kHeaderBytes+mask.size(),kFaceBytes);
        write_float(bytes,0,face->score);write_float(bytes,4,face->left);write_float(bytes,8,face->top);
        write_float(bytes,12,face->right-face->left);write_float(bytes,16,face->bottom-face->top);
        for (size_t i=0;i<face->points.size();++i) {
            write_float(bytes,20+i*8,face->points[i].x);write_float(bytes,24+i*8,face->points[i].y);
        }
    }
    return output;
}
} // namespace dinox::vision::android_wire
#endif

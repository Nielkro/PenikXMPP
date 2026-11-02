// Copyright 2026 DinoX contributors.
// SPDX-License-Identifier: Apache-2.0
// Handwritten byte goldens for the actual SDK-free Android parser/serializer.
// These checks remain active in release builds; no JNI or model is substituted.
#include "vision_android_wire.hpp"

#include <array>
#include <bit>
#include <cstdio>
#include <limits>
#include <span>
#include <vector>

#define CHECK(condition) do { if (!(condition)) { \
    std::fprintf(stderr,"ANDROID_VISION_WIRE_FAIL line %d: %s\n",__LINE__,#condition); \
    return false; } } while(false)
namespace wire=dinox::vision::android_wire;
namespace {
// Independent construction. Expected fields/letterbox values are explicit,
// rather than asking the production parser to generate its own golden input.
void put32(std::span<uint8_t> bytes,size_t offset,uint32_t value) {
    for (size_t i=0;i<4;++i) bytes[offset+i]=uint8_t((value>>(8*i))&255);
}
void put64(std::span<uint8_t> bytes,size_t offset,uint64_t value) {
    for (size_t i=0;i<8;++i) bytes[offset+i]=uint8_t((value>>(8*i))&255);
}
void put_double(std::span<uint8_t> bytes,size_t offset,double value) {
    put64(bytes,offset,std::bit_cast<uint64_t>(value));
}
std::vector<uint8_t> packet(uint32_t demand=3,uint64_t frame=9) {
    const size_t segment=(demand&1)?110592:0,face=(demand&2)?49152:0;
    std::vector<uint8_t> bytes(256+segment+face);
    put32(bytes,0,UINT32_C(0x51565744));put32(bytes,4,1);put32(bytes,8,256);put32(bytes,12,uint32_t(bytes.size()));
    put64(bytes,16,11);put64(bytes,24,22);put64(bytes,32,33);put64(bytes,40,44);
    put64(bytes,48,frame);put64(bytes,56,uint64_t(std::numeric_limits<int64_t>::max()));put64(bytes,64,1000000000+frame);
    put32(bytes,72,demand);put32(bytes,76,640);put32(bytes,80,480);put32(bytes,84,360);put32(bytes,88,320);
    put32(bytes,92,90);put32(bytes,96,1);
    const std::array<double,4> crop{.25,.125,.5,.75};
    const std::array<double,6> affine{0,4.0/3,-1.0/6,2,0,-.5};
    for(size_t i=0;i<crop.size();++i)put_double(bytes,104+i*8,crop[i]);
    for(size_t i=0;i<affine.size();++i)put_double(bytes,136+i*8,affine[i]);
    put32(bytes,184,47);put32(bytes,188,0);put32(bytes,192,162);put32(bytes,196,144);
    put32(bytes,200,0);put32(bytes,204,7);put32(bytes,208,128);put32(bytes,212,114);
    put32(bytes,216,uint32_t(segment));put32(bytes,220,uint32_t(face));
    for(size_t i=0;i<segment;++i)bytes[256+i]=uint8_t(i*17);
    for(size_t i=0;i<face;++i)bytes[256+segment+i]=uint8_t(i*17+1);
    return bytes;
}
bool known_packet_and_sizes() {
    static_assert(wire::kHeaderBytes==256&&wire::kMaxRequestBytes==160000&&wire::kMaxResultBytes==37188);
    auto good=packet();const auto r=wire::parse_request(good);
    CHECK(r&&r->demand==3&&r->identity.call==11&&r->identity.source==22&&r->identity.revision==33);
    CHECK(r->identity.transform==44&&r->identity.frame==9&&r->identity.media_ns==uint64_t(INT64_MAX));
    CHECK(r->identity.capture_ns==1000000009);
    CHECK(r->segment_rgb.size()==110592&&r->face_rgb.size()==49152);
    CHECK(r->segment_rgb[1]==17&&r->face_rgb[1]==18);
    CHECK((wire::letterbox(360,320,256,144)==wire::ContentRect{47,0,162,144}));
    CHECK((wire::letterbox(360,320,128,128)==wire::ContentRect{0,7,128,114}));
    CHECK((wire::letterbox(4096,1,128,128)==wire::ContentRect{0,63,128,1}));
    for(const uint32_t demand:{1u,2u,3u}) {
        auto one=packet(demand);const auto request=wire::parse_request(one);
        CHECK(request&&request->demand==demand);
        CHECK(request->segment_rgb.size()==((demand&1)?110592u:0u));
        CHECK(request->face_rgb.size()==((demand&2)?49152u:0u));
    }
    return true;
}
bool malformed_packets() {
    const auto good=packet();
    for(const size_t offset:{size_t(0),size_t(4),size_t(8),size_t(12),size_t(72),size_t(76),size_t(80),
            size_t(84),size_t(88),size_t(92),size_t(96),size_t(100),size_t(184),size_t(188),size_t(192),
            size_t(196),size_t(200),size_t(204),size_t(208),size_t(212),size_t(216),size_t(220),size_t(224),size_t(252)}) {
        auto bad=good;put32(bad,offset,UINT32_MAX);CHECK(!wire::parse_request(bad));
    }
    for(const size_t offset:{size_t(16),size_t(24),size_t(32),size_t(40),size_t(48),size_t(64)}) {
        auto bad=good;put64(bad,offset,0);CHECK(!wire::parse_request(bad));
        put64(bad,offset,uint64_t(INT64_MAX)+1);CHECK(!wire::parse_request(bad));
    }
    auto bad=good;put64(bad,56,UINT64_MAX);CHECK(!wire::parse_request(bad));
    for(const size_t offset:{size_t(104),size_t(112),size_t(120),size_t(128),size_t(136),size_t(144),
            size_t(152),size_t(160),size_t(168),size_t(176)}) {
        bad=good;put_double(bad,offset,std::numeric_limits<double>::quiet_NaN());CHECK(!wire::parse_request(bad));
        bad=good;put_double(bad,offset,std::numeric_limits<double>::infinity());CHECK(!wire::parse_request(bad));
    }
    bad=good;put_double(bad,120,0);CHECK(!wire::parse_request(bad));
    bad=good;put_double(bad,104,.75);CHECK(!wire::parse_request(bad));
    bad=good;put_double(bad,144,0);CHECK(!wire::parse_request(bad)); // singular transform
    bad=good;put_double(bad,136,1e308);put_double(bad,168,1e308);CHECK(!wire::parse_request(bad)); // determinant overflow
    bad=good;put32(bad,76,4096);put32(bad,80,2161);CHECK(!wire::parse_request(bad));
    for(const size_t size:{size_t(0),size_t(255),size_t(256),good.size()-1,good.size()+1}) {
        bad=good;bad.resize(size);CHECK(!wire::parse_request(bad));
    }
    return true;
}
bool sequence_and_age() {
    auto first=packet();const auto a=wire::parse_request(first);CHECK(a);
    const auto previous=wire::history(*a);
    CHECK(!wire::follows(previous,*a));
    auto following=packet(3,10);auto b=wire::parse_request(following);CHECK(b&&wire::follows(previous,*b));
    CHECK(wire::fresh(*a,a->identity.capture_ns+wire::kMaxAgeNs));
    CHECK(!wire::fresh(*a,a->identity.capture_ns+wire::kMaxAgeNs+1));
    CHECK(!wire::fresh(*a,a->identity.capture_ns-1));
    for(const size_t offset:{size_t(16),size_t(24),size_t(32),size_t(40)}) {
        auto bad=following;put64(bad,offset,wire::read64(bad,offset)-1);
        const auto parsed=wire::parse_request(bad);CHECK(parsed&&!wire::follows(previous,*parsed));
    }
    auto newer=following;put64(newer,56,0);b=wire::parse_request(newer);CHECK(b&&wire::follows(previous,*b)); // independent media clock
    newer=following;put64(newer,64,a->identity.capture_ns-1);b=wire::parse_request(newer);
    CHECK(b&&!wire::follows(previous,*b));
    newer=following;put_double(newer,104,.125);b=wire::parse_request(newer);CHECK(b&&!wire::follows(previous,*b));
    put64(newer,40,45);b=wire::parse_request(newer);CHECK(b&&wire::follows(previous,*b));
    newer=packet(3,1);put64(newer,24,23);b=wire::parse_request(newer);CHECK(b&&wire::follows(previous,*b)); // camera counter resets
    newer=packet(1,10);b=wire::parse_request(newer);CHECK(b&&!wire::follows(previous,*b));
    put64(newer,32,34);b=wire::parse_request(newer);CHECK(b&&wire::follows(previous,*b));
    // Retained History has no dangling payload span after the first packet dies.
    first.clear();CHECK(previous.identity.call==11&&previous.header[0]==0x44);
    return true;
}
bool response_identity_and_partial_face() {
    auto bytes=packet();const auto request=wire::parse_request(bytes);CHECK(request);
    std::array<uint8_t,36864> mask;mask.fill(127);
    dinox::vision::Face face;
    face.score=.75f;face.left=-.25f;face.top=.125f;face.right=.5f;face.bottom=1.25f;
    face.points.fill({-.25f,1.125f});
    const auto encoded=wire::encode_result(*request,mask,&face);CHECK(encoded&&encoded->size()==37188);
    CHECK(wire::read32(*encoded,0)==UINT32_C(0x52565744));
    CHECK(wire::read32(*encoded,12)==37188&&wire::read32(*encoded,216)==36864&&wire::read32(*encoded,220)==68);
    for(size_t i=16;i<216;++i)CHECK((*encoded)[i]==request->header[i]);
    for(size_t i=224;i<256;++i)CHECK((*encoded)[i]==0);
    CHECK((*encoded)[256]==127&&(*encoded)[256+36863]==127);
    const auto payload=std::span(*encoded).subspan(256+36864);
    CHECK(std::bit_cast<float>(wire::read32(payload,0))==.75f);
    CHECK(std::bit_cast<float>(wire::read32(payload,4))==-.25f);
    CHECK(std::bit_cast<float>(wire::read32(payload,12))==.75f); // width, not right
    CHECK(std::bit_cast<float>(wire::read32(payload,16))==1.125f); // height, not bottom
    for(size_t i=0;i<6;++i) {
        CHECK(std::bit_cast<float>(wire::read32(payload,20+i*8))==-.25f);
        CHECK(std::bit_cast<float>(wire::read32(payload,24+i*8))==1.125f);
    }
    CHECK(!wire::encode_result(*request,{},&face)); // SEG failure cannot become missing mask
    face.points[0].x=5;CHECK(!wire::encode_result(*request,mask,&face));
    face.points[0].x=-.25f;face.left=1.1f;face.right=1.5f;CHECK(!wire::encode_result(*request,mask,&face));
    face.left=-.25f;face.right=std::numeric_limits<float>::denorm_min();
    CHECK(!wire::encode_result(*request,mask,&face)); // float width would reconstruct wholly outside
    const auto no_face=wire::encode_result(*request,mask,nullptr);CHECK(no_face&&no_face->size()==37120);
    auto only_face_bytes=packet(2);const auto only_face=wire::parse_request(only_face_bytes);CHECK(only_face);
    const auto empty_detection=wire::encode_result(*only_face,{},nullptr);CHECK(empty_detection&&empty_detection->size()==256);
    CHECK(!wire::encode_result(*only_face,mask,nullptr));
    auto segment_bytes=packet(1);const auto segment=wire::parse_request(segment_bytes);CHECK(segment);
    face.left=-.25f;face.right=.5f;CHECK(!wire::encode_result(*segment,mask,&face));
    return true;
}
} // namespace
int main() {
    if (!known_packet_and_sizes()||!malformed_packets()||!sequence_and_age()||!response_identity_and_partial_face()) return 1;
    std::puts("ANDROID_VISION_WIRE_PASS: manual packets/bounds/identity/replay/partial face/failure mask");
    return 0;
}

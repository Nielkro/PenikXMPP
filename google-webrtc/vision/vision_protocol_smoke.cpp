#include "vision_protocol.hpp"
#include <cstdlib>
#define CHECK(condition) do { if (!(condition)) { \
    std::fprintf(stderr, "VISION_PROTOCOL_FAIL at line %d: %s\n", __LINE__, #condition); \
    std::exit(1); } } while (false)
#include <cstdio>
using namespace dinox::vision;
int main() {
    Header h{};
    write32(h,0,kRequestMagic);write32(h,4,kProtocolVersion);write32(h,8,kHeaderBytes);
    write32(h,12,kHeaderBytes+kMaxPayloadBytes);
    for(size_t offset=16;offset<=56;offset+=8)write64(h,offset,offset);
    write32(h,64,3);write32(h,68,2160);write32(h,72,4096);
    write32(h,76,270);write32(h,80,1);
    auto r=parse_request(h);CHECK(r&&r->payload_bytes==159744&&r->mirrored);
    auto bad=h;write32(bad,12,UINT32_MAX);CHECK(!parse_request(bad));
    bad=h;write32(bad,64,4);CHECK(!parse_request(bad));
    bad=h;write32(bad,68,4096);CHECK(!parse_request(bad));
    bad=h;write32(bad,76,45);CHECK(!parse_request(bad));
    bad=h;write32(bad,80,2);CHECK(!parse_request(bad));
    bad=h;write64(bad,16,0);CHECK(!parse_request(bad));
    bad=h;write32(bad,84,1);CHECK(!parse_request(bad));
    bad=h;write64(bad,88,1);CHECK(!parse_request(bad));
    for(auto demand:{kSegmentDemand,kFaceDemand}) {
        auto one=h;write32(one,64,demand);
        write32(one,12,uint32_t(kHeaderBytes+payload_size(demand)));
        CHECK(parse_request(one));
    }
    FrameToken desired{1,2,3,11,1000000000,6};
    FrameToken result{1,2,3,10,900000000,6};
    CHECK(result_is_fresh(result,desired,1400000000));
    CHECK(!result_is_fresh(result,desired,1400000001));
    CHECK(!result_is_fresh(result,desired,800000000));
    result.transform=7;CHECK(!result_is_fresh(result,desired,1100000000));result.transform=6;
    result.call=2;CHECK(!result_is_fresh(result,desired,1100000000));result.call=1;
    result.frame=12;CHECK(!result_is_fresh(result,desired,1100000000));result.frame=10;
    result.capture_ns=1000000001;CHECK(!result_is_fresh(result,desired,1100000000));
    result.frame=desired.frame;result.capture_ns=900000000;
    CHECK(!result_is_fresh(result,desired,1100000000));
    result.capture_ns=desired.capture_ns;
    CHECK(result_is_fresh(result,desired,1100000000));
    CHECK(!result_is_fresh({}, {}, 1));
    auto response=response_header(*r,true);
    CHECK(read32(response,0)==kResponseMagic);
    CHECK(read32(response,12)==kHeaderBytes+kMaskBytes+kFaceBytes);
    CHECK(read32(response,80)==1&&read32(response,88)==68);
    CHECK(read64(response,40)==r->token.frame);
    CHECK(parse_response(response,*r));
    bad=response;write32(bad,80,2);CHECK(!parse_response(bad,*r));
    bad=response;write32(bad,88,UINT32_MAX);CHECK(!parse_response(bad,*r));
    bad=response;write64(bad,24,999);CHECK(!parse_response(bad,*r));
    bad=response;write32(bad,92,1);CHECK(!parse_response(bad,*r));
    bad=response;write32(bad,12,UINT32_MAX);CHECK(!parse_response(bad,*r));
    std::puts("PASS bounded vision protocol and stale-result fences");
}

// Copyright 2026 DinoX contributors.
// SPDX-License-Identifier: Apache-2.0
// Actual immutable registry/lease/pixel tests. No decoder, model or call mock.
#include "dinox_webrtc_video_background_images.hpp"
#include <algorithm>
#include <array>
#include <cstdio>
#include <limits>
#include <vector>

#define CHECK(condition) do { if (!(condition)) { \
    std::fprintf(stderr,"BACKGROUND_IMAGE_FAIL line %d: %s\n",__LINE__,#condition); \
    return false; } } while(false)
namespace bg=dinox::video_background_images;
namespace vc=dinox::video_compositor;
namespace {
bg::Input input(std::span<const uint8_t> bytes,int width=1,int height=1,size_t stride=3,
        bg::PixelFormat format=bg::PixelFormat::Rgb888) {return {width,height,stride,format,bytes};}
uint64_t hash(std::span<const uint8_t> bytes) {
    uint64_t h=UINT64_C(1469598103934665603);
    for(const auto value:bytes){h^=value;h*=UINT64_C(1099511628211);}return h;
}
bool bounds_copy_alpha_and_alias() {
    bg::BackgroundImageRegistry r;
    CHECK(r.retained_sources()==0&&r.retained_variants()==0&&!r.acquire(1,vc::Range::Full,vc::Matrix::Bt601));
    std::array<uint8_t,12> rgb{255,0,0,0,255,0,0,0,255,91,92,93};
    auto result=r.upload(input(rgb,3,1,12));CHECK(result.status==bg::Status::Ok&&result.id);
    auto p=r.prepare(result.id,vc::Range::Full,vc::Matrix::Bt601);CHECK(p.status==bg::Status::Ok&&p.lease);
    CHECK(p.lease->rgb().size()==9&&p.lease->rgb()[0]==255&&p.lease->rgb()[8]==255);
    rgb.fill(7);CHECK(p.lease->rgb()[0]==255&&p.lease->rgb()[1]==0);
    CHECK(r.upload(input(p.lease->rgb(),3,1,9)).status==bg::Status::InvalidInput);
    CHECK(r.upload(input(p.lease->view().pixels.y.bytes)).status==bg::Status::InvalidInput); // valid3-byte input, owned I420
    CHECK(r.upload(input(rgb,1921)).status==bg::Status::InvalidInput);
    CHECK(r.upload(input(rgb,1920,1081,5760)).status==bg::Status::InvalidInput);
    CHECK(r.upload(input(rgb,1,1,2)).status==bg::Status::InvalidInput);
    CHECK(r.upload(input(rgb,1,2,std::numeric_limits<size_t>::max())).status==bg::Status::InvalidInput);
    CHECK(r.upload(input(rgb,3,2,12)).status==bg::Status::InvalidInput);
    CHECK(r.upload(input({},1,1,3)).status==bg::Status::InvalidInput);
    CHECK(r.upload(input(rgb,1,1,3,static_cast<bg::PixelFormat>(99))).status==bg::Status::InvalidInput);
    CHECK(r.prepare(result.id,static_cast<vc::Range>(99),vc::Matrix::Bt601).status==bg::Status::InvalidInput);
    CHECK(r.prepare(0,vc::Range::Full,vc::Matrix::Bt601).status==bg::Status::Unavailable);
    CHECK(r.create_builtin(bg::Builtin::None).status==bg::Status::InvalidInput);
    CHECK(r.create_builtin(static_cast<bg::Builtin>(11)).status==bg::Status::InvalidInput);
    CHECK(r.reset()==bg::Status::Ok);
    CHECK(p.lease->rgb()[0]==255&&!r.acquire(result.id,vc::Range::Full,vc::Matrix::Bt601));
    p.lease.reset();CHECK(r.retained_sources()==0&&r.retained_variants()==0);
    const std::array<uint8_t,8> rgba{255,0,0,128,0,255,255,0};
    result=r.upload(input(rgba,2,1,8,bg::PixelFormat::Rgba8888));CHECK(result.status==bg::Status::Ok);
    p=r.prepare(result.id,vc::Range::Full,vc::Matrix::Bt601);CHECK(p.lease);
    const std::array<uint8_t,6> expected{152,24,24,48,48,48};
    CHECK(std::ranges::equal(p.lease->rgb(),expected));
    std::vector<uint8_t> too_big(bg::kMaxInputBytes+1);
    CHECK(r.upload(input(too_big)).status==bg::Status::InvalidInput);
    return true;
}
bool exact_color_and_odd_chroma() {
    bg::BackgroundImageRegistry r;
    const std::array<uint8_t,9> rgb{255,0,0,0,255,0,0,0,255};
    const auto id=r.upload(input(rgb,3,1,9));CHECK(id.status==bg::Status::Ok);
    struct Golden {vc::Range range;vc::Matrix matrix;std::array<uint8_t,3> y;std::array<uint8_t,2> u,v;};
    const std::array<Golden,4> goldens{{
        {vc::Range::Full,vc::Matrix::Bt601,{76,150,29},{64,255},{138,107}},
        {vc::Range::Full,vc::Matrix::Bt709,{54,182,18},{64,255},{134,116}},
        {vc::Range::Limited,vc::Matrix::Bt601,{81,145,41},{72,240},{137,110}},
        {vc::Range::Limited,vc::Matrix::Bt709,{63,173,32},{72,240},{133,118}}}};
    for(const auto& golden:goldens) {
        auto p=r.prepare(id.id,golden.range,golden.matrix);CHECK(p.status==bg::Status::Ok&&p.lease);
        const auto view=p.lease->view();CHECK(vc::valid_image(view));
        CHECK(view.pixels.width==3&&view.pixels.height==1&&view.pixels.y.stride==3&&view.pixels.u.stride==2);
        CHECK(std::ranges::equal(view.pixels.y.bytes,golden.y));
        CHECK(std::ranges::equal(view.pixels.u.bytes,golden.u)&&std::ranges::equal(view.pixels.v.bytes,golden.v));
        CHECK(r.acquire(id.id,golden.range,golden.matrix)==p.lease);
        CHECK(r.prepare(id.id,golden.range,golden.matrix).lease==p.lease); // convert once while cached
    }
    CHECK(r.reset()==bg::Status::Ok);
    const std::array<uint8_t,20> padded{255,0,0,0,255,0,0,0,255,222,223,0,0,255,0,0,0,255,0,0};
    const auto rows=r.upload(input(padded,3,2,11));CHECK(rows.status==bg::Status::Ok);
    auto p=r.prepare(rows.id,vc::Range::Full,vc::Matrix::Bt601);CHECK(p.lease);
    const std::array<uint8_t,18> packed{255,0,0,0,255,0,0,0,255,0,0,255,0,0,0,255,0,0};
    CHECK(std::ranges::equal(p.lease->rgb(),packed));
    // First block red/green/blue/black is neutral chroma; right odd block blue/red.
    CHECK(p.lease->view().pixels.u.bytes[0]==128&&p.lease->view().pixels.v.bytes[0]==128);
    CHECK(p.lease->view().pixels.u.bytes[1]==170&&p.lease->view().pixels.v.bytes[1]==181);
    return true;
}
bool source_and_variant_leases() {
    bg::IdAllocator ids(100);bg::BackgroundImageRegistry r(ids);
    const std::array<uint8_t,3> red{255,0,0},blue{0,0,255},green{0,255,0};
    const auto a=r.upload(input(red));CHECK(a.status==bg::Status::Ok&&a.id==100);
    auto old=r.prepare(a.id,vc::Range::Full,vc::Matrix::Bt601);CHECK(old.lease);
    const auto old_view=old.lease->view();
    const auto b=r.upload(input(blue));CHECK(b.status==bg::Status::Ok&&b.id==101);
    CHECK(r.acquire(a.id,vc::Range::Full,vc::Matrix::Bt601)==old.lease); // upload keeps old until prepare commits
    auto current=r.prepare(b.id,vc::Range::Full,vc::Matrix::Bt601);CHECK(current.lease);
    CHECK(old_view.pixels.y.bytes[0]==76&&current.lease->view().pixels.y.bytes[0]==29);
    CHECK(r.retained_sources()==2&&r.retained_variants()==2);
    CHECK(r.upload(input(green)).status==bg::Status::NoMemory);
    CHECK(r.discard(a.id)==bg::Status::Ok&&!r.acquire(a.id,vc::Range::Full,vc::Matrix::Bt601));
    CHECK(old_view.pixels.y.bytes[0]==76&&r.upload(input(green)).status==bg::Status::NoMemory);
    old.lease.reset();CHECK(r.retained_sources()==1&&r.retained_variants()==1);
    const auto c=r.upload(input(green));CHECK(c.status==bg::Status::Ok&&c.id==102);
    CHECK(r.discard(c.id)==bg::Status::Ok); // cancelled upload does not clear unrelated active image
    CHECK(r.acquire(b.id,vc::Range::Full,vc::Matrix::Bt601)==current.lease);
    CHECK(r.reset()==bg::Status::Ok);current.lease.reset();
    CHECK(r.retained_sources()==0&&r.retained_variants()==0);
    const auto source=r.upload(input(red));CHECK(source.status==bg::Status::Ok);
    auto format_a=r.prepare(source.id,vc::Range::Full,vc::Matrix::Bt601);
    auto format_b=r.prepare(source.id,vc::Range::Full,vc::Matrix::Bt709);CHECK(format_a.lease&&format_b.lease);
    CHECK(r.retained_sources()==1&&r.retained_variants()==2);
    CHECK(r.prepare(source.id,vc::Range::Limited,vc::Matrix::Bt601).status==bg::Status::NoMemory);
    format_a.lease.reset();auto format_c=r.prepare(source.id,vc::Range::Limited,vc::Matrix::Bt601);CHECK(format_c.lease);
    CHECK(format_b.lease->view().pixels.y.bytes[0]==54&&format_c.lease->view().pixels.y.bytes[0]==81);
    CHECK(r.discard(source.id)==bg::Status::Ok);
    CHECK(!r.acquire(source.id,vc::Range::Full,vc::Matrix::Bt709));
    CHECK(format_b.lease->view().pixels.y.bytes[0]==54); // retained reader, never a mutable replace
    format_b.lease.reset();format_c.lease.reset();CHECK(r.retained_sources()==0&&r.retained_variants()==0);
    return true;
}
bool active_format_recovery_with_staged_image() {
    bg::BackgroundImageRegistry r;
    const std::array<uint8_t,3> red{255,0,0},blue{0,0,255};
    const auto a=r.upload(input(red));CHECK(a.status==bg::Status::Ok);
    const auto active_source=r.retain_source(a.id);CHECK(active_source);
    auto active=r.prepare(a.id,vc::Range::Limited,vc::Matrix::Bt601);CHECK(active.lease);
    auto reader=active.lease;const auto old_view=reader->view();
    const auto b=r.upload(input(blue));CHECK(b.status==bg::Status::Ok);
    auto staged=r.prepare(b.id,vc::Range::Limited,vc::Matrix::Bt601);CHECK(staged.lease);
    const uint64_t generation=r.generation();
    CHECK(r.retained_sources()==2&&r.retained_variants()==2&&r.owned_pixel_bytes()==12);
    // The registry current owner belongs to B. A's transition must leave B,
    // the source ID and the retained reader untouched, never allocate a third.
    active.lease.reset();r.retire_other_format(a.id,vc::Range::Full,vc::Matrix::Bt709);
    CHECK(r.prepare(a.id,vc::Range::Full,vc::Matrix::Bt709).status==bg::Status::NoMemory);
    CHECK(r.retained_variants()==2&&r.owned_pixel_bytes()==12);
    CHECK(old_view.pixels.y.bytes[0]==81&&old_view.pixels.u.bytes[0]==90&&old_view.pixels.v.bytes[0]==240);
    CHECK(r.acquire(b.id,vc::Range::Limited,vc::Matrix::Bt601)==staged.lease);
    reader.reset();CHECK(r.retained_variants()==1&&r.owned_pixel_bytes()==9);
    auto full=r.prepare(a.id,vc::Range::Full,vc::Matrix::Bt709);CHECK(full.lease);
    const auto full_view=full.lease->view();
    CHECK(full_view.pixels.y.bytes[0]==54&&full_view.pixels.u.bytes[0]==99&&full_view.pixels.v.bytes[0]==255);
    CHECK(full.lease->range()==vc::Range::Full&&full.lease->matrix()==vc::Matrix::Bt709);
    CHECK(r.retained_sources()==2&&r.retained_variants()==2&&r.owned_pixel_bytes()==12);
    // Now current_asset belongs to A. Retire that registry owner too, without
    // deleting A's source or prematurely freeing a reader-held allocation.
    r.retire_other_format(a.id,static_cast<vc::Range>(99),vc::Matrix::Bt709);
    CHECK(r.acquire(a.id,vc::Range::Full,vc::Matrix::Bt709)==full.lease);
    r.retire_other_format(a.id,vc::Range::Limited,vc::Matrix::Bt709);
    CHECK(r.contains(a.id)&&r.contains(b.id)&&r.generation()==generation);
    CHECK(r.prepare(a.id,vc::Range::Limited,vc::Matrix::Bt709).status==bg::Status::NoMemory);
    CHECK(full_view.pixels.y.bytes[0]==54&&r.retained_variants()==2&&r.owned_pixel_bytes()==12);
    full.lease.reset();CHECK(r.retained_variants()==1&&r.owned_pixel_bytes()==9);
    auto limited=r.prepare(a.id,vc::Range::Limited,vc::Matrix::Bt709);CHECK(limited.lease);
    const auto limited_view=limited.lease->view();
    CHECK(limited_view.pixels.y.bytes[0]==63&&limited_view.pixels.u.bytes[0]==102&&limited_view.pixels.v.bytes[0]==240);
    CHECK(r.acquire(b.id,vc::Range::Limited,vc::Matrix::Bt601)==staged.lease&&
        staged.lease->view().pixels.y.bytes[0]==41);
    CHECK(r.retained_sources()==2&&r.retained_variants()==2&&r.owned_pixel_bytes()==12);
    return true;
}
bool ids_reset_and_registry_destruction() {
    const std::array<uint8_t,3> red{255,0,0};bg::IdAllocator ids(UINT32_MAX);
    bg::BackgroundImageRegistry r(ids);
    const auto last=r.upload(input(red));CHECK(last.status==bg::Status::Ok&&last.id==UINT32_MAX);
    const uint64_t generation=r.generation();auto lease=r.prepare(last.id,vc::Range::Limited,vc::Matrix::Bt709).lease;CHECK(lease);
    CHECK(r.reset()==bg::Status::Ok&&r.generation()==generation+1);
    CHECK(!r.acquire(last.id,vc::Range::Limited,vc::Matrix::Bt709));
    CHECK(r.upload(input(red)).status==bg::Status::IdExhausted);
    CHECK(lease->view().pixels.y.bytes[0]==63);lease.reset();
    CHECK(r.upload(input(red)).status==bg::Status::IdExhausted);
    bg::BackgroundImageRegistry first,second;
    const auto a=first.upload(input(red)),b=second.upload(input(red));
    CHECK(a.status==bg::Status::Ok&&b.status==bg::Status::Ok&&b.id>a.id);
    CHECK(first.prepare(b.id,vc::Range::Full,vc::Matrix::Bt601).status==bg::Status::Unavailable);
    CHECK(first.reset()==bg::Status::Ok);const auto c=first.upload(input(red));CHECK(c.id>b.id);
    bg::Lease survived;
    {bg::BackgroundImageRegistry transient;const auto id=transient.upload(input(red));survived=transient.prepare(id.id,vc::Range::Full,vc::Matrix::Bt601).lease;}
    CHECK(survived&&survived->rgb()[0]==255&&survived->view().pixels.y.bytes[0]==76);
    return true;
}
bool original_builtins_and_maximum() {
    bg::BackgroundImageRegistry r;std::array<uint64_t,10> hashes{};
    for(uint32_t choice=1;choice<=10;++choice) {
        const auto id=r.create_builtin(static_cast<bg::Builtin>(choice));CHECK(id.status==bg::Status::Ok);
        CHECK(r.create_builtin(static_cast<bg::Builtin>(choice)).id==id.id);
        auto p=r.prepare(id.id,vc::Range::Limited,vc::Matrix::Bt709);CHECK(p.lease&&p.lease->width()==320&&p.lease->height()==180);
        hashes[choice-1]=hash(p.lease->rgb());CHECK(vc::valid_image(p.lease->view()));
        CHECK(r.retained_sources()==1&&r.retained_variants()==1);
        CHECK(r.reset()==bg::Status::Ok&&hash(p.lease->rgb())==hashes[choice-1]);
        p.lease.reset();CHECK(r.retained_sources()==0&&r.retained_variants()==0);
    }
    for(size_t i=0;i<hashes.size();++i)for(size_t j=0;j<i;++j)CHECK(hashes[i]!=hashes[j]);
    std::vector<uint8_t> maximum(bg::kMaxRgbBytes,128);
    const auto id=r.upload(input(maximum,1920,1080,5760));CHECK(id.status==bg::Status::Ok);
    auto p=r.prepare(id.id,vc::Range::Full,vc::Matrix::Bt601);CHECK(p.lease);
    const auto view=p.lease->view();
    CHECK(p.lease->rgb().size()==bg::kMaxRgbBytes);
    CHECK(view.pixels.y.bytes.size()+view.pixels.u.bytes.size()+view.pixels.v.bytes.size()==3110400);
    CHECK(view.pixels.y.bytes.front()==128&&view.pixels.v.bytes.back()==128);
    CHECK(r.reset()==bg::Status::Ok);p.lease.reset();
    // Near the pixel limit, odd chroma dimensions legitimately exceed the
    // even full-HD byte count. They still fit the proven4MiB decoded bound.
    maximum.resize(1125*1843*3);
    const auto odd=r.upload(input(maximum,1125,1843,3375));CHECK(odd.status==bg::Status::Ok);
    p=r.prepare(odd.id,vc::Range::Full,vc::Matrix::Bt601);CHECK(p.lease&&vc::valid_image(p.lease->view()));
    const auto odd_view=p.lease->view();
    const size_t odd_bytes=odd_view.pixels.y.bytes.size()+odd_view.pixels.u.bytes.size()+odd_view.pixels.v.bytes.size();
    CHECK(odd_bytes==3111547&&odd_bytes<=bg::kMaxI420Bytes);
    return true;
}
} // namespace
int main() {
    if(!bounds_copy_alpha_and_alias()||!exact_color_and_odd_chroma()||!source_and_variant_leases()||
            !active_format_recovery_with_staged_image()||!ids_reset_and_registry_destruction()||
            !original_builtins_and_maximum())return 1;
    std::puts("BACKGROUND_IMAGE_PASS: bounded immutable leases/IDs/copy/color/odd stride/builtins");
    return 0;
}

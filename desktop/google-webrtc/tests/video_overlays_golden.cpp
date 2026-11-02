// Copyright 2026 DinoX contributors.
// SPDX-License-Identifier: Apache-2.0
// Synthetic geometry/pixel goldens; no inference/device/call quality claim.
#include "dinox_webrtc_video_overlays.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <limits>

#define CHECK(condition) do { if (!(condition)) { \
    std::fprintf(stderr,"VIDEO_OVERLAY_GOLDEN_FAIL line %d: %s\n",__LINE__,#condition); \
    return false; } } while (false)

namespace vo=dinox::video_overlays;
namespace {
constexpr uint64_t kCapture=UINT64_C(1000000000);
vo::Frame frame() { return {200,240,1,kCapture,kCapture+100000000}; }
vo::Face face() {
    vo::Face f;
    f.score=0.9;f.bounds={50.5/200,65.5/240,150.5/200,190.5/240};
    f.points={vo::Point{80.5/200,100.5/240},vo::Point{120.5/200,100.5/240},
        vo::Point{100.5/200,120.5/240},vo::Point{100.5/200,136.5/240},
        vo::Point{60.5/200,112.5/240},vo::Point{140.5/200,112.5/240}};
    f.captured_ns=kCapture;f.valid=true;
    return f;
}
bool near(double a,double b) { return std::abs(a-b)<1e-8; }
uint64_t pixel_hash(const vo::Prepared& prepared) {
    uint64_t hash=UINT64_C(1469598103934665603);
    for (int y=0;y<prepared.height;++y) for (int x=0;x<prepared.width;++x) {
        const auto p=vo::rgba_pixel(prepared,x,y);
        for (const uint8_t channel:{p.r,p.g,p.b,p.a}) { hash^=channel;hash*=UINT64_C(1099511628211); }
    }
    return hash;
}
bool neutral_and_validation() {
    CHECK(vo::is_neutral({})&&vo::valid_options({}));
    vo::Face bad;
    bad.score=std::numeric_limits<double>::quiet_NaN();
    const auto neutral=vo::prepare({}, {}, &bad);
    CHECK(neutral.valid&&!neutral.active&&!neutral.face_usable&&neutral.particle_count==0);
    CHECK(vo::rgba_pixel(neutral,0,0)==vo::Rgba{});
    CHECK(vo::touch_up_weight(neutral,0,0)==0);
    for (int y=0;y<256;++y) CHECK(vo::low_light_luma(neutral,uint8_t(y),vo::LumaRange::Limited)==y);
    vo::Options o;o.glasses=vo::Glasses::Sunglasses;
    CHECK(!vo::prepare(o,{}).valid);
    auto bad_frame=frame();bad_frame.width=4097;
    CHECK(!vo::prepare(o,bad_frame).valid);
    bad_frame={4096,2161,1,kCapture,kCapture};
    CHECK(!vo::prepare(o,bad_frame).valid);
    for (const int rotation:{-90,45,360}) {
        bad_frame=frame();bad_frame.rotation=rotation;
        CHECK(!vo::prepare(o,bad_frame).valid);
        CHECK(vo::prepare({},bad_frame).valid); // neutral performs no work
    }
    for (const int field:{0,1,2,3,4}) {
        auto invalid=o;
        if (field==0) invalid.glasses=static_cast<vo::Glasses>(4);
        if (field==1) invalid.hat=static_cast<vo::Hat>(4);
        if (field==2) invalid.beard=static_cast<vo::Beard>(4);
        if (field==3) invalid.accessory=static_cast<vo::Accessory>(3);
        if (field==4) invalid.scene=static_cast<vo::Scene>(5);
        CHECK(!vo::valid_options(invalid)&&!vo::prepare(invalid,frame()).valid);
    }
    const auto f=face();const auto p=vo::prepare(o,frame(),&f);
    CHECK(vo::rgba_pixel(p,-1,100)==vo::Rgba{});
    CHECK(vo::rgba_pixel(p,200,100)==vo::Rgba{});
    CHECK(vo::rgba_pixel(p,100,240)==vo::Rgba{});
    return true;
}
bool geometry_and_freshness() {
    vo::Options o;o.glasses=vo::Glasses::Sunglasses;
    auto f=face();auto fr=frame();
    const auto p=vo::prepare(o,fr,&f);
    CHECK(p.active&&p.face_usable&&near(p.eye_center.x,100.5)&&near(p.eye_center.y,100.5));
    CHECK(near(p.eye_distance,40)&&near(p.eye_axis.x,1)&&near(p.eye_axis.y,0));
    CHECK(near(p.nose_local.x,0)&&near(p.nose_local.y,0.5));
    CHECK(near(p.mouth_local.y,0.9));
    CHECK(vo::rgba_pixel(p,80,100).a==235);
    CHECK(vo::rgba_pixel(p,100,100).a==245); // bridge
    CHECK(vo::rgba_pixel(p,20,20).a==0);
    fr.now_ns=kCapture+vo::kMaxFaceAgeNs;
    CHECK(vo::prepare(o,fr,&f).face_usable);
    ++fr.now_ns;CHECK(!vo::prepare(o,fr,&f).active);
    fr=frame();f.captured_ns=kCapture+1;CHECK(!vo::prepare(o,fr,&f).face_usable);
    f=face();f.valid=false;CHECK(!vo::prepare(o,fr,&f).face_usable);
    f=face();f.points[2].x=std::numeric_limits<double>::quiet_NaN();CHECK(!vo::prepare(o,fr,&f).face_usable);
    f=face();f.points[5].x=5;CHECK(!vo::prepare(o,fr,&f).face_usable);
    f=face();f.points[2].x=160.5/200;CHECK(!vo::prepare(o,fr,&f).face_usable); // strong profile
    f=face();f.points[3]=f.points[2];CHECK(!vo::prepare(o,fr,&f).face_usable);
    f=face();f.points[1]=f.points[0];CHECK(!vo::prepare(o,fr,&f).face_usable);
    f=face();f.bounds.right=f.bounds.left;CHECK(!vo::prepare(o,fr,&f).face_usable);
    f=face();f.score=1.01;CHECK(!vo::prepare(o,fr,&f).face_usable);
    f=face();f.bounds.left=-0.1;CHECK(vo::prepare(o,fr,&f).face_usable); // no clamping
    f=face();f.bounds={1.1,0.1,1.4,0.4};CHECK(!vo::prepare(o,fr,&f).face_usable);
    // Native source coordinates may be rotated 90 degrees while metadata rotates
    // the displayed frame back. The overlay must follow the source, not disappear.
    f=face();
    for (auto& point:f.points) {
        const double px=point.x*200,py=point.y*240;
        point={(100.5-(py-100.5))/200,(100.5+(px-100.5))/240};
    }
    f.bounds={10.5/200,50.5/240,135.5/200,150.5/240};
    const auto rotated=vo::prepare(o,fr,&f);
    CHECK(rotated.face_usable&&near(rotated.eye_axis.x,0)&&near(rotated.eye_axis.y,1));
    CHECK(near(rotated.nose_local.y,0.5)&&vo::rgba_pixel(rotated,100,80).a==235);
    // Mirroring swaps the visual eye direction, but the perpendicular must still
    // point toward the nose so hats remain above the face.
    f=face();for (auto& point:f.points) point.x=(201-point.x*200)/200;
    CHECK(vo::prepare(o,fr,&f).face_usable);
    CHECK(near(vo::prepare(o,fr,&f).eye_axis.x,1));
    return true;
}
bool distinct_styles_and_blend() {
    const auto f=face();const auto fr=frame();vo::Options o;
    std::array<uint64_t,3> glasses{},hats{},beards{};
    for (uint32_t style=1;style<=3;++style) {
        o={};o.glasses=static_cast<vo::Glasses>(style);const auto p=vo::prepare(o,fr,&f);
        CHECK(p.face_usable);glasses[style-1]=pixel_hash(p);
        if (style==1) CHECK(vo::rgba_pixel(p,80,100).a==235);
        if (style==2) CHECK(vo::rgba_pixel(p,80,100).a==35);
        if (style==3) CHECK(vo::rgba_pixel(p,80,100).a==30);
        o={};o.hat=static_cast<vo::Hat>(style);hats[style-1]=pixel_hash(vo::prepare(o,fr,&f));
        o={};o.beard=static_cast<vo::Beard>(style);beards[style-1]=pixel_hash(vo::prepare(o,fr,&f));
    }
    CHECK(glasses[0]!=glasses[1]&&glasses[1]!=glasses[2]&&glasses[0]!=glasses[2]);
    CHECK(hats[0]!=hats[1]&&hats[1]!=hats[2]&&hats[0]!=hats[2]);
    CHECK(beards[0]!=beards[1]&&beards[1]!=beards[2]&&beards[0]!=beards[2]);
    o={};o.beard=vo::Beard::Moustache;CHECK(vo::rgba_pixel(vo::prepare(o,fr,&f),109,132).a==230);
    o.beard=vo::Beard::Goatee;CHECK(vo::rgba_pixel(vo::prepare(o,fr,&f),100,148).a==230);
    o.beard=vo::Beard::Full;CHECK(vo::rgba_pixel(vo::prepare(o,fr,&f),124,145).a==230);
    o={};o.accessory=vo::Accessory::Puppy;const auto puppy=vo::prepare(o,fr,&f);
    CHECK(vo::rgba_pixel(puppy,100,120).a==245);
    o.accessory=vo::Accessory::KaraokeMic;const auto mic=vo::prepare(o,fr,&f);
    CHECK(vo::rgba_pixel(mic,136,144).a==250&&pixel_hash(mic)!=pixel_hash(puppy));
    o.glasses=vo::Glasses::Round;o.hat=vo::Hat::Cowboy;o.beard=vo::Beard::Full;o.scene=vo::Scene::Confetti;
    const auto combined=vo::prepare(o,fr,&f);
    for (int y=0;y<fr.height;++y) for (int x=0;x<fr.width;++x) {
        const auto color=vo::rgba_pixel(combined,x,y);
        CHECK(color.r<=color.a&&color.g<=color.a&&color.b<=color.a);
    }
    return true;
}
bool scene_clock_and_geometry() {
    vo::Options o;auto fr=frame();
    for (uint32_t style=1;style<=4;++style) {
        o.scene=static_cast<vo::Scene>(style);const auto p=vo::prepare(o,fr);
        CHECK(p.valid&&p.active&&!p.face_usable&&p.particle_count<=vo::kMaxParticles);
        CHECK(p.particle_count==(style==1?32u:style==2?24u:style==3?16u:8u));
        CHECK(pixel_hash(p)==pixel_hash(vo::prepare(o,fr)));
        auto next=fr;next.captured_ns+=500000000;
        CHECK(pixel_hash(p)!=pixel_hash(vo::prepare(o,next)));
        next=fr;next.captured_ns+=6000000000;
        CHECK(pixel_hash(p)==pixel_hash(vo::prepare(o,next)));
        next=fr;next.frame_id+=1234567;
        CHECK(pixel_hash(p)==pixel_hash(vo::prepare(o,next))); // no per-frame random flicker
    }
    o={};o.scene=vo::Scene::Confetti;fr.captured_ns=0;fr.frame_id=1;
    const auto a=vo::prepare(o,fr);fr.frame_id+=180;
    CHECK(pixel_hash(a)==pixel_hash(vo::prepare(o,fr)));
    // Prepared particle shape checks, independently of pseudo-random placements.
    auto p=vo::prepare(o,frame());p.particle_count=1;
    auto& part=p.particles[0];part.shape=vo::ParticleShape::Rectangle;
    part.center={100.5,100.5};part.axis={std::sqrt(0.5),std::sqrt(0.5)};
    part.half_width=10;part.half_height=2;part.left=90;part.right=111;part.top=90;part.bottom=111;
    part.rgb=0xff0000;part.alpha=128;
    CHECK((vo::rgba_pixel(p,100,100)==vo::Rgba{128,0,0,128}));
    CHECK(vo::rgba_pixel(p,106,94)==vo::Rgba{}); // inside AABB, outside rotated rectangle
    part.shape=vo::ParticleShape::Football;part.axis={1,0};part.half_width=part.half_height=10;
    CHECK(vo::rgba_pixel(p,100,100).r==17); // central black patch: round(34*128/255)
    part.shape=vo::ParticleShape::Star;
    CHECK(vo::rgba_pixel(p,100,100).a==128);
    CHECK(vo::rgba_pixel(p,109,109).a==0);
    return true;
}
bool scene_orientation() {
    // Independent raw-to-display pixel mapping on a non-square canvas. Every
    // RGBA result must match the upright generator after receiver presentation.
    vo::Frame raw{80,48,17,UINT64_C(2000000000),UINT64_C(2100000000)};
    for (uint32_t style=1;style<=4;++style) for (const int rotation:{0,90,180,270}) {
        vo::Options o;o.scene=static_cast<vo::Scene>(style);
        raw.rotation=rotation;
        auto display=raw;display.rotation=0;
        if (rotation==90 || rotation==270) std::swap(display.width,display.height);
        const auto reference=vo::prepare(o,display),actual=vo::prepare(o,raw);
        CHECK(actual.valid&&actual.active&&!actual.face_usable);
        CHECK(actual.width==raw.width&&actual.height==raw.height);
        CHECK(actual.particle_count==reference.particle_count);
        for (size_t i=0;i<actual.particle_count;++i) {
            const auto& p=actual.particles[i];const auto& up=reference.particles[i];
            vo::Point center=up.center,axis=up.axis;
            if (rotation==90) { center={up.center.y,raw.height-up.center.x};axis={up.axis.y,-up.axis.x}; }
            if (rotation==180) { center={raw.width-up.center.x,raw.height-up.center.y};axis={-up.axis.x,-up.axis.y}; }
            if (rotation==270) { center={raw.width-up.center.y,up.center.x};axis={-up.axis.y,up.axis.x}; }
            CHECK(near(p.center.x,center.x)&&near(p.center.y,center.y));
            CHECK(near(p.axis.x,axis.x)&&near(p.axis.y,axis.y));
            CHECK(p.shape==up.shape&&p.rgb==up.rgb&&p.alpha==up.alpha);
            CHECK(p.half_width==up.half_width&&p.half_height==up.half_height);
            const double ex=std::abs(axis.x)*p.half_width+std::abs(axis.y)*p.half_height;
            const double ey=std::abs(axis.y)*p.half_width+std::abs(axis.x)*p.half_height;
            CHECK(near(p.left,center.x-ex)&&near(p.right,center.x+ex));
            CHECK(near(p.top,center.y-ey)&&near(p.bottom,center.y+ey));
        }
        for (int y=0;y<raw.height;++y) for (int x=0;x<raw.width;++x) {
            int ux=x,uy=y;
            if (rotation==90) { ux=raw.height-1-y;uy=x; }
            if (rotation==180) { ux=raw.width-1-x;uy=raw.height-1-y; }
            if (rotation==270) { ux=y;uy=raw.width-1-x; }
            CHECK(vo::rgba_pixel(actual,x,y)==vo::rgba_pixel(reference,ux,uy));
        }
    }
    // Face landmarks have already been inverse-projected by the adapter. The
    // scene rotation field must not rotate face artwork or touch-up again.
    auto fr=frame();const auto f=face();vo::Options face_options;
    face_options.glasses=vo::Glasses::Round;face_options.hat=vo::Hat::Cowboy;
    face_options.beard=vo::Beard::Goatee;face_options.accessory=vo::Accessory::Puppy;
    face_options.touch_up=true;
    const auto reference=vo::prepare(face_options,fr,&f);
    for (const int rotation:{90,180,270}) {
        fr.rotation=rotation;const auto actual=vo::prepare(face_options,fr,&f);
        CHECK(actual.face_usable&&pixel_hash(actual)==pixel_hash(reference));
        for (int y=0;y<fr.height;++y) for (int x=0;x<fr.width;++x)
            CHECK(vo::touch_up_weight(actual,x,y)==vo::touch_up_weight(reference,x,y));
    }
    return true;
}
bool conservative_pixel_adjustments() {
    auto f=face();auto fr=frame();vo::Options o;o.touch_up=true;
    const auto touched=vo::prepare(o,fr,&f);
    CHECK(touched.face_usable&&vo::touch_up_weight(touched,118,123)==32);
    CHECK(vo::touch_up_weight(touched,80,100)==0&&vo::touch_up_weight(touched,100,120)==0);
    CHECK(vo::touch_up_weight(touched,100,136)==0&&vo::touch_up_weight(touched,0,0)==0);
    for (int y=0;y<240;++y) for (int x=0;x<200;++x) CHECK(vo::touch_up_weight(touched,x,y)<=32);
    fr.now_ns=kCapture+vo::kMaxFaceAgeNs+1;CHECK(!vo::prepare(o,fr,&f).active);
    o={};o.low_light=true;const auto dark=vo::prepare(o,frame(),nullptr,{32,32});
    CHECK(dark.active&&dark.low_light_gain_q8==384&&!dark.face_usable);
    CHECK(vo::low_light_luma(dark,64,vo::LumaRange::Full)==96);
    CHECK(vo::low_light_luma(dark,80,vo::LumaRange::Limited)==112);
    CHECK(vo::low_light_luma(dark,255,vo::LumaRange::Limited)==235);
    CHECK(vo::low_light_luma(dark,255,vo::LumaRange::Full)==255);
    CHECK(vo::low_light_luma(dark,0,vo::LumaRange::Limited)==16);
    CHECK(!vo::prepare(o,frame(),nullptr,{0,32}).active);
    CHECK(!vo::prepare(o,frame(),nullptr,{4097,32}).active);
    CHECK(!vo::prepare(o,frame(),nullptr,{32,256}).active);
    const auto bright=vo::prepare(o,frame(),nullptr,{32,96});CHECK(!bright.active);
    for (int value=0;value<256;++value) CHECK(vo::low_light_luma(bright,uint8_t(value),vo::LumaRange::Limited)==value);
    return true;
}
} // namespace

int main() {
    if (!neutral_and_validation()||!geometry_and_freshness()||!distinct_styles_and_blend()||
            !scene_clock_and_geometry()||!scene_orientation()||!conservative_pixel_adjustments()) return 1;
    std::puts("VIDEO_OVERLAY_GOLDEN_PASS: geometry/styles/upright scenes/freshness/neutral/pixel bounds");
    return 0;
}

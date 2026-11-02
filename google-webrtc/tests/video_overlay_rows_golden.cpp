// Copyright 2026 DinoX contributors.
// SPDX-License-Identifier: Apache-2.0
// The sparse row path must reproduce the original full pixel query exactly.
#include "dinox_webrtc_video_overlays.hpp"
#include <algorithm>
#include <cmath>
#include <cstdio>
namespace vo=dinox::video_overlays;
namespace {
constexpr uint64_t kCapture=UINT64_C(6000000001);
#define CHECK(x) do { if (!(x)) { std::fprintf(stderr,"VIDEO_OVERLAY_ROWS_FAIL %d: %s\n",__LINE__,#x);return false; } } while(false)
vo::Face face(int width,int height,int roll,double shift) {
    vo::Face f;f.score=0.9;f.captured_ns=kCapture;f.valid=true;
    const double angle=roll*1.57079632679489661923,co=std::cos(angle),si=std::sin(angle);
    const auto point=[&](vo::Point p) {
        const double dx=p.x-100.5,dy=p.y-120.5;
        return vo::Point{(100.5+shift+dx*co-dy*si)/width,(120.5+dx*si+dy*co)/height};
    };
    constexpr vo::Point points[]={{80.5,100.5},{120.5,100.5},{100.5,120.5},
        {100.5,136.5},{60.5,112.5},{140.5,112.5}};
    for(size_t i=0;i<f.points.size();++i)f.points[i]=point(points[i]);
    bool first=true;
    for(double x:{50.5,150.5})for(double y:{65.5,190.5}) {
        const auto p=point({x,y});
        if(first){f.bounds={p.x,p.y,p.x,p.y};first=false;}
        else {f.bounds.left=std::min(f.bounds.left,p.x);f.bounds.right=std::max(f.bounds.right,p.x);
            f.bounds.top=std::min(f.bounds.top,p.y);f.bounds.bottom=std::max(f.bounds.bottom,p.y);}
    }
    return f;
}
bool equality() {
    for(int test=0;test<160;++test) {
        vo::Options o;o.scene=vo::Scene(test%5);
        const bool with_face=(test/5)%2;
        if(with_face){o.glasses=vo::Glasses(1+(test/10)%3);o.hat=vo::Hat(1+(test/30)%3);
            o.beard=vo::Beard(1+(test/13)%3);o.accessory=vo::Accessory((test/17)%3);o.touch_up=true;}
        o.low_light=test&1;
        const int width=200+(test%2),height=240+((test/2)%2);
        auto f=face(width,height,(test/20)%4,test%7==0?-50.25:test%7==1?59.5:0.0);
        const uint64_t capture=kCapture+uint64_t(test)*37000000;f.captured_ns=capture;
        const auto c=vo::prepare(o,{width,height,uint64_t(test+1),capture,capture+100,(test/10)%4*90},&f,{1000,32});
        CHECK(c.valid);if(with_face)CHECK(c.face_usable);
        for(int y=0;y<height;++y) {
            const auto row=vo::prepare_row(c,y);
            CHECK(row.particle_count<=vo::kMaxParticles);
            CHECK(row.begin>=0&&row.end<=width);
            for(int x=0;x<width;++x) {
                const auto expected=vo::rgba_pixel(c,x,y);
                const auto actual=vo::rgba_row_pixel(c,row,x);
                CHECK(actual==expected);
                if(x<row.begin||x>=row.end)CHECK(expected==vo::Rgba{});
            }
        }
        CHECK(!vo::prepare_row(c,-1).valid&&!vo::prepare_row(c,height).valid);
    }
    return true;
}
bool candidate_bounds() {
    vo::Options o;o.scene=vo::Scene::Confetti;
    const auto c=vo::prepare(o,{4096,2160,1,kCapture,kCapture,270});
    CHECK(c.valid&&c.active);
    for(int y:{0,1,1079,2159}) {
        const auto row=vo::prepare_row(c,y);
        CHECK(row.particle_count<=vo::kMaxParticles&&row.begin>=0&&row.end<=4096);
        CHECK(vo::rgba_row_pixel(c,row,-1)==vo::Rgba{});
        CHECK(vo::rgba_row_pixel(c,row,4096)==vo::Rgba{});
    }
    auto bad=c;bad.particle_count=vo::kMaxParticles+1;
    CHECK(!vo::prepare_row(bad,0).valid);
    auto row=vo::prepare_row(c,1079);row.valid=true;row.begin=0;row.end=4096;
    row.particle_count=1;row.particles[0]=255;
    CHECK(vo::rgba_row_pixel(c,row,2048)==vo::Rgba{});
    row.particle_count=vo::kMaxParticles+1;
    CHECK(vo::rgba_row_pixel(c,row,2048)==vo::Rgba{});
    return true;
}
}
int main(){if(!equality()||!candidate_bounds())return 1;std::puts("VIDEO_OVERLAY_ROWS_PASS: byte-equivalent row candidates, face rolls, upright scenes, clipped edges and scalar bounds");}

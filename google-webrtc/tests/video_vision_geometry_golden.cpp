#include "dinox_webrtc_video_vision_geometry.hpp"
#include <array>
#include <iostream>
#include <vector>
#define CHECK(x) do{if(!(x)){std::cerr<<"vision geometry check "<<__LINE__<<": "<<#x<<'\n';return 1;}}while(false)
namespace vg=dinox::video_vision_geometry;
namespace vc=dinox::video_compositor;
int main(){
    constexpr std::array<int,4> rotations{0,90,180,270};
    constexpr std::array<std::array<uint8_t,6>,4> expected{{{0,51,98,144,191,255},
        {144,0,191,51,255,98},{255,191,144,98,51,0},{98,255,51,191,0,144}}};
    const std::array<uint8_t,10> limited{16,60,100,0xa5,0xa5,140,180,235,0xa5,0xa5};
    const std::array<uint8_t,10> full{0,51,98,0xa5,0xa5,144,191,255,0xa5,0xa5};
    const std::array<uint8_t,4> u{128,128,0xa5,0xa5};
    const std::array<uint8_t,3> v{128,128,0xa5};
    for(bool full_range:{false,true})for(auto matrix:{vc::Matrix::Bt601,vc::Matrix::Bt709}){
        vc::I420View source{3,2,full_range?vc::Range::Full:vc::Range::Limited,matrix,
            {full_range?std::span(full):std::span(limited),5},{u,4},{v,3}};
        for(size_t i=0;i<rotations.size();++i){
            const int r=rotations[i],dw=(r==90||r==270)?2:3,dh=(r==90||r==270)?3:2;
            std::array<uint8_t,18> rgb{};
            CHECK(vg::preprocess_rgb(source,r,dw,dh,{0,0,dw,dh},rgb));
            for(size_t p=0;p<6;++p)for(size_t c=0;c<3;++c)CHECK(rgb[p*3+c]==expected[i][p]);
            const auto rect=vg::letterbox(dw,dh,8,8);
            CHECK(rect.x==(dw==2?1:0)&&rect.y==(dw==2?0:1)&&
                rect.width==(dw==2?5:8)&&rect.height==(dw==2?8:5));
            std::array<uint8_t,8*8*3> padded{};
            CHECK(vg::preprocess_rgb(source,r,8,8,rect,padded));
            for(int y=0;y<8;++y)for(int x=0;x<8;++x){
                if(x>=rect.x&&x<rect.x+rect.width&&y>=rect.y&&y<rect.y+rect.height)continue;
                for(int c=0;c<3;++c)CHECK(padded[(y*8+x)*3+c]==0);
            }
            CHECK(source.y.bytes[3]==0xa5&&source.y.bytes[4]==0xa5&&source.y.bytes[8]==0xa5&&
                source.u.bytes[2]==0xa5&&source.v.bytes[2]==0xa5);
        }
        std::array<uint8_t,18> sentinel;sentinel.fill(0xa5);
        CHECK(!vg::preprocess_rgb(source,45,3,2,{0,0,3,2},sentinel));
        CHECK(!vg::preprocess_rgb(source,0,3,2,{0,0,4,2},sentinel));
        for(auto byte:sentinel)CHECK(byte==0xa5);
    }
    constexpr std::array<vg::Point,4> partial{{{-.25,1.5},{1.5,1.25},{1.25,-.5},{-.5,-.25}}};
    for(size_t i=0;i<rotations.size();++i){
        const auto point=vg::detector_to_raw({-.25,1.5},{0,0,128,128},rotations[i]);
        CHECK(std::abs(point.x-partial[i].x)<1e-12&&std::abs(point.y-partial[i].y)<1e-12);
    }
    const auto roi=vg::detector_to_raw({.1,-.25},{32,0,64,128},90,{.5,.5,2.0/3});
    CHECK(std::abs(roi.x+.625)<1e-12&&std::abs(roi.y-1.7)<1e-12);
    // Four-corner bounds retain positive raw box extents at quarter turns;
    // no source-coordinate clamp is allowed for a partial detector rectangle.
    for(int rotation:rotations){
        double left=10,top=10,right=-10,bottom=-10;
        for(const auto p:std::array<vg::Point,4>{{{-.2,.1},{.8,.1},{-.2,.9},{.8,.9}}}){
            const auto raw=vg::detector_to_raw(p,{0,0,128,128},rotation);
            left=std::min(left,raw.x);top=std::min(top,raw.y);right=std::max(right,raw.x);bottom=std::max(bottom,raw.y);
        }
        CHECK(right>left&&bottom>top);
        if(rotation==90||rotation==270)CHECK(std::abs(right-left-.8)<1e-12&&std::abs(bottom-top-1)<1e-12);
        else CHECK(std::abs(right-left-1)<1e-12&&std::abs(bottom-top-.8)<1e-12);
    }
    return 0;
}

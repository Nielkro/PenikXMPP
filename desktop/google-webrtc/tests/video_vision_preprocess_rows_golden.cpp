// Copyright 2026 DinoX contributors.
// SPDX-License-Identifier: Apache-2.0
// Independent legacy formula checks for bounded RGB sampling and half ties.
#include "dinox_webrtc_video_vision_geometry.hpp"
#include <array>
#include <cmath>
#include <cstdio>
#include <limits>
#include <vector>
namespace vg=dinox::video_vision_geometry;
namespace vc=dinox::video_compositor;
namespace {
#define CHECK(x) do{if(!(x)){std::fprintf(stderr,"VISION_PREPROCESS_ROWS_FAIL %d: %s\n",__LINE__,#x);return false;}}while(false)
uint8_t original_byte(double value){return uint8_t(std::clamp(int(std::lround(value)),0,255));}
std::array<uint8_t,3> original_rgb(uint8_t yy,uint8_t uu,uint8_t vv,vc::Range range,vc::Matrix matrix){
    const double kr=matrix==vc::Matrix::Bt709?0.2126:0.299;
    const double kb=matrix==vc::Matrix::Bt709?0.0722:0.114,kg=1-kr-kb;
    double luma=yy,u=int(uu)-128,v=int(vv)-128;
    if(range==vc::Range::Limited){luma=(luma-16)*255/219;u*=255.0/224;v*=255.0/224;}
    const double r=luma+2*(1-kr)*v,b=luma+2*(1-kb)*u,g=(luma-kr*r-kb*b)/kg;
    return {original_byte(r),original_byte(g),original_byte(b)};
}
bool ties(){
    for(int whole=0;whole<256;++whole){
        const double half=whole+0.5;
        for(double value:{half,std::nextafter(half,-std::numeric_limits<double>::infinity()),
                         std::nextafter(half,std::numeric_limits<double>::infinity())}){
            CHECK(vg::detail::rgb_byte(value)==original_byte(value));
            CHECK(vg::detail::rgb_byte(-value)==original_byte(-value));
        }
    }
    for(double value:{-1000.,-1.,-0.,0.,0.49999999999999994,254.49999999999997,255.,255.5,1000.})
        CHECK(vg::detail::rgb_byte(value)==original_byte(value));
    return true;
}
bool pixels(){
    for(auto size:{std::array{1,1},std::array{2,3},std::array{3,2},std::array{17,11},std::array{32,19}})
    for(auto range:{vc::Range::Limited,vc::Range::Full})for(auto matrix:{vc::Matrix::Bt601,vc::Matrix::Bt709}){
        const int w=size[0],h=size[1],cw=(w+1)/2,ch=(h+1)/2,ys=w+7,us=cw+3,vs=cw+5;
        std::vector<uint8_t> yy(ys*h,0xa7),uu(us*ch,0xb9),vv(vs*ch,0xce);
        for(int y=0;y<h;++y)for(int x=0;x<w;++x)yy[y*ys+x]=uint8_t(y*137+x*71);
        for(int y=0;y<ch;++y)for(int x=0;x<cw;++x){uu[y*us+x]=uint8_t(y*37+x*83);vv[y*vs+x]=uint8_t(y*59+x*97);}
        const auto old_y=yy,old_u=uu,old_v=vv;
        vc::I420View source{w,h,range,matrix,{yy,ys},{uu,us},{vv,vs}};
        for(int rotation:{0,90,180,270}){
            const int dw=rotation==90||rotation==270?h:w,dh=rotation==90||rotation==270?w:h;
            const int target_width=23,target_height=27;
            const auto rect=vg::letterbox(dw,dh,target_width,target_height);
            std::vector<uint8_t> rgb(target_width*target_height*3+2,0xa5);
            std::span<uint8_t> destination(rgb.data()+1,rgb.size()-2);
            CHECK(vg::preprocess_rgb(source,rotation,target_width,target_height,rect,destination));
            CHECK(rgb.front()==0xa5&&rgb.back()==0xa5);
            for(int y=0;y<target_height;++y)for(int x=0;x<target_width;++x){
                const size_t p=(y*target_width+x)*3;
                if(x<rect.x||x>=rect.x+rect.width||y<rect.y||y>=rect.y+rect.height){
                    CHECK(destination[p]==0&&destination[p+1]==0&&destination[p+2]==0);continue;
                }
                const int ux=std::min(dw-1,int(int64_t(2*(x-rect.x)+1)*dw/(2*rect.width)));
                const int uy=std::min(dh-1,int(int64_t(2*(y-rect.y)+1)*dh/(2*rect.height)));
                int sx=ux,sy=uy;
                if(rotation==90){sx=uy;sy=h-1-ux;}
                else if(rotation==180){sx=w-1-ux;sy=h-1-uy;}
                else if(rotation==270){sx=w-1-uy;sy=ux;}
                const auto expected=original_rgb(yy[sy*ys+sx],uu[(sy/2)*us+sx/2],vv[(sy/2)*vs+sx/2],range,matrix);
                CHECK(destination[p]==expected[0]&&destination[p+1]==expected[1]&&destination[p+2]==expected[2]);
            }
            const auto before=rgb;
            CHECK(!vg::preprocess_rgb(source,45,target_width,target_height,rect,destination));CHECK(rgb==before);
            auto bad=source;bad.u.bytes=bad.u.bytes.first(1);
            if(cw*ch>1){CHECK(!vg::preprocess_rgb(bad,rotation,target_width,target_height,rect,destination));CHECK(rgb==before);}
            CHECK(!vg::preprocess_rgb(source,rotation,target_width,target_height,{0,0,256,256},destination));CHECK(rgb==before);
        }
        CHECK(yy==old_y&&uu==old_u&&vv==old_v);
    }
    return true;
}
}
int main(){if(!ties()||!pixels())return 1;std::puts("VISION_PREPROCESS_ROWS_PASS: legacy RGB bytes, half ties, rotated padded/odd sources, letterbox and invalid no-write bounds");}

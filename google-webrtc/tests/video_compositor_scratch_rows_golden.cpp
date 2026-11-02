// Copyright 2026 DinoX contributors.
// SPDX-License-Identifier: Apache-2.0
// Exact independent box means and minimal scratch for fused/even and odd rows.
#include "dinox_webrtc_video_compositor.hpp"
#include <algorithm>
#include <array>
#include <cstdio>
#include <vector>
namespace vc=dinox::video_compositor;
namespace {
#define CHECK(x) do { if(!(x)){std::fprintf(stderr,"COMPOSITOR_SCRATCH_ROWS_FAIL %d: %s\n",__LINE__,#x);return false;} }while(false)
int reference(vc::Plane p,int w,int h,int x,int y,int radius){
    int sum=0;for(int dy=-radius;dy<=radius;++dy)for(int dx=-radius;dx<=radius;++dx)
        sum+=p.bytes[std::clamp(y+dy,0,h-1)*p.stride+std::clamp(x+dx,0,w-1)];
    const int area=(2*radius+1)*(2*radius+1);return (sum+area/2)/area;
}
bool padding(const std::vector<uint8_t>& p,int stride,int w,int h){
    for(int y=0;y<h;++y)for(int x=w;x<stride;++x)if(p[y*stride+x]!=0xa7)return false;
    return true;
}
bool rows(){
    constexpr std::array<uint8_t,1> confidence{0};
    for(int w:{1,2,3,4,15,16,31,32})for(int h:{1,2,3,9})for(int radius=1;radius<=12;++radius){
        int strength=0;while(strength<100 && 1+(11*strength+50)/100<radius)++strength;
        CHECK(1+(11*strength+50)/100==radius);
        const int cw=(w+1)/2,ch=(h+1)/2,ys=w+7,us=cw+3,vs=cw+5;
        std::vector<uint8_t> sy(w*h),su(cw*ch),sv(cw*ch),oy(ys*h,0xa7),ou(us*ch,0xa7),ov(vs*ch,0xa7);
        for(size_t i=0;i<sy.size();++i)sy[i]=uint8_t(i*131+i/7);
        for(size_t i=0;i<su.size();++i){su[i]=uint8_t(i*47+31);sv[i]=uint8_t(i*73+89);}
        const auto before_y=sy,before_u=su,before_v=sv;
        vc::I420View source{w,h,vc::Range::Limited,vc::Matrix::Bt601,{sy,w},{su,cw},{sv,cw}};
        vc::I420Output output{w,h,source.range,source.matrix,{oy,ys},{ou,us},{ov,vs}};
        vc::Options options;options.background=vc::BackgroundMode::Blur;options.blur_strength=strength;
        vc::MaskView mask{{confidence,1},1,1,w,h,{0,0,1,1},true};
        const auto required=vc::blur_scratch_requirements(w,strength);
        std::vector<uint16_t> rr(required.row_samples+2,0xfefd);
        std::vector<uint32_t> cc(required.column_samples+2,0xdeadbeef);
        const vc::Scratch scratch{{rr.data()+1,required.row_samples},{cc.data()+1,required.column_samples}};
        CHECK(vc::compose(source,options,&mask,nullptr,scratch,output)==vc::Status::Applied);
        for(int y=0;y<h;++y)for(int x=0;x<w;++x)CHECK(oy[y*ys+x]==reference(source.y,w,h,x,y,radius));
        for(int y=0;y<ch;++y)for(int x=0;x<cw;++x){
            CHECK(ou[y*us+x]==reference(source.u,cw,ch,x,y,(radius+1)/2));
            CHECK(ov[y*vs+x]==reference(source.v,cw,ch,x,y,(radius+1)/2));
        }
        CHECK(sy==before_y&&su==before_u&&sv==before_v);
        CHECK(padding(oy,ys,w,h)&&padding(ou,us,cw,ch)&&padding(ov,vs,cw,ch));
        CHECK(rr.front()==0xfefd&&rr.back()==0xfefd&&cc.front()==0xdeadbeef&&cc.back()==0xdeadbeef);
        auto short_rows=scratch;short_rows.rows=short_rows.rows.first(required.row_samples-1);
        auto short_columns=scratch;short_columns.columns=short_columns.columns.first(required.column_samples-1);
        for(const auto invalid:{short_rows,short_columns}){
            CHECK(vc::compose(source,options,&mask,nullptr,invalid,output)==vc::Status::Concealed);
            for(int y=0;y<h;++y)for(int x=0;x<w;++x)CHECK(oy[y*ys+x]==57);
            for(int y=0;y<ch;++y)for(int x=0;x<cw;++x)CHECK(ou[y*us+x]==128&&ov[y*vs+x]==128);
            CHECK(padding(oy,ys,w,h)&&padding(ou,us,cw,ch)&&padding(ov,vs,cw,ch));
        }
    }
    return true;
}
}
int main(){if(!rows())return 1;std::puts("COMPOSITOR_SCRATCH_ROWS_PASS: all radii, even/odd/singleton shapes, exact minimal rings, independent means, short-scratch concealment");}

#ifndef DINOX_WEBRTC_VIDEO_VISION_GEOMETRY_HPP
#define DINOX_WEBRTC_VIDEO_VISION_GEOMETRY_HPP
#include "dinox_webrtc_video_compositor.hpp"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <span>
namespace dinox::video_vision_geometry {
struct Point{double x=0,y=0;};
inline bool valid_rotation(int value){return value==0||value==90||value==180||value==270;}
inline Point upright_to_raw(Point p,int rotation){
    switch(rotation){case 90:return {p.y,1-p.x};case 180:return {1-p.x,1-p.y};
        case 270:return {1-p.y,p.x};default:return p;}
}
inline video_compositor::ContentRect letterbox(int w,int h,int tw,int th){
    if(w<1||h<1||tw<1||th<1)return {};
    int width=tw,height=th;
    if(int64_t(w)*th>=int64_t(h)*tw)height=std::max(1,int((int64_t(h)*tw+w/2)/w));
    else width=std::max(1,int((int64_t(w)*th+h/2)/h));
    return {(tw-width)/2,(th-height)/2,width,height};
}
inline Point detector_to_raw(Point model,video_compositor::ContentRect content,
                             int rotation,video_compositor::Roi roi={}){
    const Point upright{(model.x*128-content.x)/content.width,(model.y*128-content.y)/content.height};
    const auto raw=upright_to_raw(upright,rotation);
    return {(raw.x-(roi.center_x-roi.scale/2))/roi.scale,
        (raw.y-(roi.center_y-roi.scale/2))/roi.scale};
}
inline bool valid_plane(video_compositor::Plane p,int w,int h){
    return w>0&&h>0&&p.stride>=w&&size_t(h-1)<=SIZE_MAX/size_t(p.stride)&&
        size_t(h-1)*p.stride<=p.bytes.size()&&size_t(w)<=p.bytes.size()-size_t(h-1)*p.stride;
}
namespace detail {
// The converter produces finite doubles. Saturate before rounding; for the
// remaining positive [0,255) range, subtraction of the integer part is exact.
// This retains lround's half-away-from-zero byte result without value+0.5,
// whose floating addition can change a value immediately below a half tie.
inline uint8_t rgb_byte(double value){
    if(value<=0)return 0;
    if(value>=255)return 255;
    const int whole=static_cast<int>(value);
    return static_cast<uint8_t>(whole+(value-whole>=0.5));
}
struct RgbOffsets{size_t y=0,u=0,v=0;};
}
// Caller supplies a separately owned RGB target. No allocation, output metadata
// mutation or raw-camera rotation; this only turns the small ML probe upright.
inline bool preprocess_rgb(const video_compositor::I420View& source,int rotation,
    int width,int height,video_compositor::ContentRect rect,std::span<uint8_t> rgb){
    namespace vc=video_compositor;
    if(!valid_rotation(rotation)||source.width<1||source.height<1||source.width>4096||source.height>4096||
        uint64_t(source.width)*source.height>vc::kMaxFramePixels||width<1||height<1||width>256||height>256||
        rgb.size()!=size_t(width)*height*3||rect.x<0||rect.y<0||rect.width<1||rect.height<1||
        rect.x>width-rect.width||rect.y>height-rect.height||
        !valid_plane(source.y,source.width,source.height)||
        !valid_plane(source.u,(source.width+1)/2,(source.height+1)/2)||
        !valid_plane(source.v,(source.width+1)/2,(source.height+1)/2))return false;
    std::fill(rgb.begin(),rgb.end(),0);
    const int dw=(rotation==90||rotation==270)?source.height:source.width;
    const int dh=(rotation==90||rotation==270)?source.width:source.height;
    const double kr=source.matrix==vc::Matrix::Bt709?0.2126:0.299;
    const double kb=source.matrix==vc::Matrix::Bt709?0.0722:0.114,kg=1-kr-kb;
    // Per-invocation scalar offsets only: no pixel/model data is retained.
    // The old 64-bit pixel-centre divisions are performed once per axis.
    std::array<detail::RgbOffsets,256> columns,rows;
    const auto offsets=[&](int sx,int sy){return detail::RgbOffsets{
        size_t(sy)*source.y.stride+sx,
        size_t(sy/2)*source.u.stride+sx/2,
        size_t(sy/2)*source.v.stride+sx/2};};
    for(int x=0;x<rect.width;++x){
        const int ux=std::min(dw-1,int(int64_t(2*x+1)*dw/(2*rect.width)));
        int sx=0,sy=0;
        if(rotation==0)sx=ux;
        else if(rotation==180)sx=source.width-1-ux;
        else if(rotation==90)sy=source.height-1-ux;
        else sy=ux;
        columns[x]=offsets(sx,sy);
    }
    for(int y=0;y<rect.height;++y){
        const int uy=std::min(dh-1,int(int64_t(2*y+1)*dh/(2*rect.height)));
        int sx=0,sy=0;
        if(rotation==0)sy=uy;
        else if(rotation==180)sy=source.height-1-uy;
        else if(rotation==90)sx=uy;
        else sx=source.width-1-uy;
        rows[y]=offsets(sx,sy);
    }
    const auto* source_y=source.y.bytes.data();
    const auto* source_u=source.u.bytes.data();
    const auto* source_v=source.v.bytes.data();
    auto* target=rgb.data();
    for(int y=0;y<rect.height;++y){
      const auto row=rows[y];
      for(int x=0;x<rect.width;++x){
        const auto column=columns[x];
        // Checked boundary: valid_plane proves each complete source row and
        // its stride; rotated axis sums address sx<width, sy<height and their
        // exact chroma halves. RGB size is exactly width*height*3 and rect is
        // wholly inside it, so p,p+1,p+2 are valid. No alias policy is changed.
#if defined(__clang__)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunsafe-buffer-usage"
#endif
        double luma=source_y[row.y+column.y];
        double u=source_u[row.u+column.u]-128;
        double v=source_v[row.v+column.v]-128;
        if(source.range==vc::Range::Limited){luma=(luma-16)*255/219;u*=255.0/224;v*=255.0/224;}
        const double r=luma+2*(1-kr)*v,b=luma+2*(1-kb)*u,g=(luma-kr*r-kb*b)/kg;
        const size_t p=(size_t(rect.y+y)*width+rect.x+x)*3;
        target[p]=detail::rgb_byte(r);
        target[p+1]=detail::rgb_byte(g);
        target[p+2]=detail::rgb_byte(b);
#if defined(__clang__)
#pragma clang diagnostic pop
#endif
      }
    }
    return true;
}
}
#endif

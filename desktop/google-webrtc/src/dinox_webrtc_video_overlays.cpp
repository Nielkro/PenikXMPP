// Copyright 2026 DinoX contributors.
// SPDX-License-Identifier: Apache-2.0
#include "dinox_webrtc_video_overlays.hpp"

#include <algorithm>
#include <cmath>

namespace dinox::video_overlays {
namespace {
constexpr double kPi = 3.14159265358979323846;
constexpr uint64_t kPeriodNs = UINT64_C(6000000000);
constexpr std::array<uint32_t, 6> kColors{
    0xff677d, 0xffd166, 0x6be3bf, 0x6fa8ff, 0xca91ff, 0xffa96b};

bool bounded(double value) { return std::isfinite(value) && std::abs(value) <= 4; }
bool finite_point(Point value) { return bounded(value.x) && bounded(value.y); }
bool valid_frame(Frame f) {
    return f.width > 0 && f.height > 0 && f.width <= 4096 && f.height <= 4096 &&
        uint64_t(f.width) * uint64_t(f.height) <= UINT64_C(8847360) && f.frame_id &&
        (f.rotation==0 || f.rotation==90 || f.rotation==180 || f.rotation==270);
}
double sq(double value) { return value * value; }
bool ellipse(Point p, double cx, double cy, double rx, double ry) {
    return sq((p.x-cx)/rx) + sq((p.y-cy)/ry) <= 1;
}
bool rectangle(Point p, double cx, double cy, double rx, double ry) {
    return std::abs(p.x-cx) <= rx && std::abs(p.y-cy) <= ry;
}
bool segment(Point p, Point a, Point b, double radius) {
    const double dx = b.x-a.x, dy = b.y-a.y;
    const double length = dx*dx+dy*dy;
    const double t = length > 0 ? std::clamp(((p.x-a.x)*dx+(p.y-a.y)*dy)/length,0.0,1.0) : 0;
    return sq(p.x-a.x-t*dx)+sq(p.y-a.y-t*dy) <= radius*radius;
}
void over(Rgba& dst, uint32_t rgb, uint8_t alpha) {
    const uint32_t inverse = 255-alpha;
    const uint32_t out_alpha = alpha+(uint32_t(dst.a)*inverse+127)/255;
    const auto component = [&](uint32_t source, uint8_t old) {
        return uint8_t(std::min(out_alpha,(source*alpha+127)/255+(uint32_t(old)*inverse+127)/255));
    };
    dst.r = component((rgb>>16)&255,dst.r);
    dst.g = component((rgb>>8)&255,dst.g);
    dst.b = component(rgb&255,dst.b);
    dst.a = uint8_t(out_alpha);
}
Point local_point(const Prepared& c, double x, double y) {
    const double dx=x-c.eye_center.x, dy=y-c.eye_center.y;
    return {(dx*c.eye_axis.x+dy*c.eye_axis.y)/c.eye_distance,
        (-dx*c.eye_axis.y+dy*c.eye_axis.x)/c.eye_distance};
}
bool prepare_face(Prepared& out, Frame frame, const Face* face) {
    if (!face || !face->valid || !face->captured_ns || !frame.captured_ns ||
            frame.now_ns < frame.captured_ns || face->captured_ns > frame.captured_ns ||
            frame.now_ns-face->captured_ns > kMaxFaceAgeNs || !std::isfinite(face->score) ||
            face->score < 0.5 || face->score > 1) return false;
    const auto& b=face->bounds;
    const double bw=b.right-b.left,bh=b.bottom-b.top;
    if (!bounded(b.left) || !bounded(b.top) || !bounded(b.right) || !bounded(b.bottom) ||
            bw<=0 || bh<=0 || bw>4 || bh>4 || b.right<=0 || b.bottom<=0 || b.left>=1 || b.top>=1) return false;
    for (const auto& point : face->points) if (!finite_point(point)) return false;
    std::array<Point,6> pixels;
    for (size_t i=0;i<pixels.size();++i) pixels[i]={face->points[i].x*frame.width,face->points[i].y*frame.height};
    double dx=pixels[1].x-pixels[0].x,dy=pixels[1].y-pixels[0].y;
    const double distance=std::hypot(dx,dy);
    if (!std::isfinite(distance) || distance<6 || distance>0.7*std::max(frame.width,frame.height)) return false;
    out.eye_center={(pixels[0].x+pixels[1].x)/2,(pixels[0].y+pixels[1].y)/2};
    out.eye_distance=distance;
    out.eye_axis={dx/distance,dy/distance};
    if (local_point(out,pixels[2].x,pixels[2].y).y<0) {
        out.eye_axis.x=-out.eye_axis.x;
        out.eye_axis.y=-out.eye_axis.y;
    }
    out.nose_local=local_point(out,pixels[2].x,pixels[2].y);
    out.mouth_local=local_point(out,pixels[3].x,pixels[3].y);
    const Point ear0=local_point(out,pixels[4].x,pixels[4].y);
    const Point ear1=local_point(out,pixels[5].x,pixels[5].y);
    const double left=std::min(ear0.x,ear1.x),right=std::max(ear0.x,ear1.x);
    // Reject strong profile/collapsed or inconsistent geometry. Source roll is
    // deliberately unrestricted: camera rotation may make the eye axis vertical.
    if (std::abs(out.nose_local.x)>0.65 || out.nose_local.y<0.05 || out.nose_local.y>1.25 ||
            std::abs(out.mouth_local.x)>0.8 || out.mouth_local.y<out.nose_local.y+0.05 ||
            out.mouth_local.y>2.25 || left>-0.65 || right<0.65 || left<-2.5 || right>2.5 ||
            std::abs(ear0.y)>1.4 || std::abs(ear1.y)>1.4 ||
            std::min(-left,right)/std::max(-left,right)<0.3) return false;
    const double box_size=std::hypot(bw*frame.width,bh*frame.height)/distance;
    if (box_size<1.4 || box_size>7) return false;
    bool first_corner = true;
    for (const double x : {-3.0, 3.0}) for (const double y : {-2.0, 4.0}) {
        const Point pixel{out.eye_center.x + distance * (x * out.eye_axis.x - y * out.eye_axis.y),
            out.eye_center.y + distance * (x * out.eye_axis.y + y * out.eye_axis.x)};
        auto& bounds = out.face_artwork_bounds;
        if (first_corner) { bounds={pixel.x,pixel.y,pixel.x,pixel.y}; first_corner=false; }
        else {
            bounds.left=std::min(bounds.left,pixel.x);bounds.right=std::max(bounds.right,pixel.x);
            bounds.top=std::min(bounds.top,pixel.y);bounds.bottom=std::max(bounds.bottom,pixel.y);
        }
    }
    return true;
}
uint32_t hash(uint32_t value) {
    value^=value>>16;value*=UINT32_C(0x7feb352d);value^=value>>15;
    value*=UINT32_C(0x846ca68b);return value^(value>>16);
}
double unit(uint32_t value) { return double(hash(value)&65535)/65536; }
double fractional(double value) { return value-std::floor(value); }
void particle_bounds(Particle& p) {
    const double extent_x=std::abs(p.axis.x)*p.half_width+std::abs(p.axis.y)*p.half_height;
    const double extent_y=std::abs(p.axis.y)*p.half_width+std::abs(p.axis.x)*p.half_height;
    p.left=p.center.x-extent_x;p.right=p.center.x+extent_x;
    p.top=p.center.y-extent_y;p.bottom=p.center.y+extent_y;
}
void particle(Prepared& c, ParticleShape shape, Point center, double width, double height,
        double angle, uint32_t rgb, uint8_t alpha) {
    if (c.particle_count>=c.particles.size() || !alpha) return;
    auto& p=c.particles[c.particle_count++];
    p.shape=shape;p.center=center;p.axis={std::cos(angle),std::sin(angle)};
    p.half_width=width;p.half_height=height;p.rgb=rgb;p.alpha=alpha;
    particle_bounds(p);
}
void prepare_scene(Prepared& c, Frame frame) {
    const double phase=frame.captured_ns ? double(frame.captured_ns%kPeriodNs)/kPeriodNs : double(frame.frame_id%180)/180;
    const double size=std::min(frame.width,frame.height);
    if (c.options.scene==Scene::Fireworks) {
        const double radius=std::clamp(size*0.009,1.5,12.0);
        for (uint32_t burst=0;burst<4;++burst) {
            const double t=fractional(phase+burst*0.25);
            const Point origin{(0.15+unit(31+burst)*0.7)*frame.width,(0.12+unit(71+burst)*0.5)*frame.height};
            for (uint32_t ray=0;ray<8;++ray) {
                const double angle=2*kPi*ray/8;
                const double travel=t*size*0.35;
                const Point center{origin.x+std::cos(angle)*travel,origin.y+std::sin(angle)*travel+t*t*size*0.12};
                particle(c,ParticleShape::Spark,center,radius,radius,0,kColors[burst%kColors.size()],uint8_t((1-t)*220));
            }
        }
    } else if (c.options.scene==Scene::Confetti || c.options.scene==Scene::Stars) {
        const uint32_t count=c.options.scene==Scene::Confetti?24:16;
        for (uint32_t i=0;i<count;++i) {
            const double base=unit(101+i),x=fractional(base+phase*(0.06+unit(501+i)*0.08));
            const double y=fractional(unit(201+i)+phase)*(frame.height+size*0.12)-size*0.06;
            const double radius=std::clamp(size*(c.options.scene==Scene::Confetti?0.01:0.017),2.0,20.0);
            const bool star=c.options.scene==Scene::Stars;
            const double pulse=star?0.7+0.3*std::abs(2*fractional(phase+base)-1):1;
            particle(c,star?ParticleShape::Star:ParticleShape::Rectangle,{x*frame.width,y},radius*pulse,
                star?radius*pulse:radius*0.4,phase*2*kPi+unit(301+i)*kPi,kColors[i%kColors.size()],220);
        }
    } else if (c.options.scene==Scene::Football) {
        const double radius=std::clamp(size*0.027,3.0,20.0);
        for (uint32_t i=0;i<8;++i) {
            const double x=fractional(unit(901+i)+phase*0.1)*frame.width;
            const double y=fractional(unit(1001+i)+phase)*(frame.height+2*radius)-radius;
            particle(c,ParticleShape::Football,{x,y},radius,radius,phase*2*kPi,0xf4f4ed,235);
        }
    }
}
void prepare_upright_scene(Prepared& c, Frame raw) {
    Frame upright=raw;
    if (raw.rotation==90 || raw.rotation==270) std::swap(upright.width,upright.height);
    prepare_scene(c,upright);
    // Keep the zero-rotation generator/arithmetic unchanged. Pixel centers and
    // axes are inverse-projected together, then raw conservative bounds follow.
    if (!raw.rotation) return;
    for (size_t i=0;i<c.particle_count;++i) {
        auto& p=c.particles[i];
        const auto center=p.center,axis=p.axis;
        if (raw.rotation==90) {
            p.center={center.y,raw.height-center.x};p.axis={axis.y,-axis.x};
        } else if (raw.rotation==180) {
            p.center={raw.width-center.x,raw.height-center.y};p.axis={-axis.x,-axis.y};
        } else {
            p.center={raw.width-center.y,center.x};p.axis={-axis.y,axis.x};
        }
        particle_bounds(p);
    }
}
bool star_inside(Point p) {
    // Original regular five-point polygon, outer radius1 and inner radius0.45.
    // Crossing parity uses ten fixed vertices; no trig occurs per pixel.
    constexpr std::array<Point,10> vertices{{{0,-1},{0.264503,-0.364058},{0.951057,-0.309017},
        {0.427975,0.139058},{0.587785,0.809017},{0,0.45},{-0.587785,0.809017},
        {-0.427975,0.139058},{-0.951057,-0.309017},{-0.264503,-0.364058}}};
    bool inside=false;
    for (size_t i=0,j=vertices.size()-1;i<vertices.size();j=i++) {
        const auto a=vertices[i],b=vertices[j];
        if ((a.y>p.y)!=(b.y>p.y) && p.x<(b.x-a.x)*(p.y-a.y)/(b.y-a.y)+a.x) inside=!inside;
    }
    return inside;
}
void scene_particle_pixel(Rgba& result, const Particle& part, Point pixel) {
        if (pixel.x<part.left || pixel.x>part.right || pixel.y<part.top || pixel.y>part.bottom) return;
        const double dx=pixel.x-part.center.x,dy=pixel.y-part.center.y;
        const Point p{(dx*part.axis.x+dy*part.axis.y)/part.half_width,
            (-dx*part.axis.y+dy*part.axis.x)/part.half_height};
        if (part.shape==ParticleShape::Rectangle) {
            if (std::abs(p.x)<=1&&std::abs(p.y)<=1) over(result,part.rgb,part.alpha);
            return;
        }
        if (part.shape==ParticleShape::Star) { if (star_inside(p)) over(result,part.rgb,part.alpha);return; }
        if (p.x*p.x+p.y*p.y>1) return;
        uint32_t rgb=part.rgb;
        if (part.shape==ParticleShape::Football) {
            constexpr std::array<Point,5> patches{{{0,-0.72},{0.68476,-0.22249},{0.42321,0.58249},
                {-0.42321,0.58249},{-0.68476,-0.22249}}};
            bool black=std::abs(p.x)+std::abs(p.y)<0.36;
            for (const auto patch:patches) black=black||ellipse(p,patch.x,patch.y,0.17,0.17);
            rgb=black?0x22252a:part.rgb;
        }
        over(result,rgb,part.alpha);
}
void scene_pixel(Rgba& result, const Prepared& c, Point pixel) {
    for (size_t i=0;i<c.particle_count;++i) scene_particle_pixel(result,c.particles[i],pixel);
}
void glasses_pixel(Rgba& result, Glasses style, Point p) {
    if (style==Glasses::None) return;
    const bool bridge=segment(p,{-0.16,0},{0.16,0},0.045);
    const bool temples=segment(p,{-1.05,-0.03},{-0.8,0},0.04)||segment(p,{0.8,0},{1.05,-0.03},0.04);
    if (bridge||temples) over(result,style==Glasses::Rectangular?0x253b65:0x29252a,245);
    for (const double center:{-0.5,0.5}) {
        if (style==Glasses::Sunglasses) {
            if (ellipse(p,center,0.025,0.39,0.25)) {
                over(result,0x20232b,235);
                if (segment(p,{center-0.18,-0.1},{center+0.07,-0.15},0.025)) over(result,0x86b6c2,120);
            }
        } else if (style==Glasses::Round) {
            const double r=sq(p.x-center)+sq(p.y);
            if (r<=sq(0.36)) over(result,r>=sq(0.30)?0x8c704f:0x99d7e3,r>=sq(0.30)?245:35);
        } else if (rectangle(p,center,0,0.38,0.25)) {
            const bool rim=!rectangle(p,center,0,0.31,0.18);
            over(result,rim?0x253b65:0x96cee4,rim?245:30);
        }
    }
}
void hat_pixel(Rgba& result, Hat style, Point p) {
    if (style==Hat::Cap) {
        if (ellipse(p,0,-0.66,1.0,0.75)&&p.y<=-0.62) over(result,0xb92f43,245);
        if (ellipse(p,0.46,-0.64,0.98,0.12)) over(result,0x7d1b2b,250);
        if (ellipse(p,-0.12,-0.99,0.13,0.13)) over(result,0xf0d8b0,245);
    } else if (style==Hat::Cowboy) {
        if (ellipse(p,0,-0.67,1.5,0.19)) over(result,0xad7845,245);
        if (rectangle(p,0,-1.07,0.76,0.43)&&!ellipse(p,0,-1.52,0.29,0.2)) over(result,0xc79962,245);
        if (rectangle(p,0,-0.76,0.77,0.075)) over(result,0x60432f,250);
    } else if (style==Hat::Top) {
        if (rectangle(p,0,-1.28,0.62,0.66)) over(result,0x24232b,250);
        if (rectangle(p,0,-0.65,1.15,0.1)) over(result,0x181821,250);
        if (rectangle(p,0,-0.85,0.62,0.1)) over(result,0x8a4ea9,250);
    }
}
void beard_pixel(Rgba& result, Beard style, Point p, Point mouth) {
    const Point q{p.x-mouth.x,p.y-mouth.y};
    if (style==Beard::Moustache) {
        if (ellipse(q,-0.23,-0.1,0.35,0.13)||ellipse(q,0.23,-0.1,0.35,0.13)) over(result,0x392d29,230);
    } else if (style==Beard::Goatee) {
        if ((ellipse(q,0,0.33,0.34,0.45)&&q.y>=0.03)||ellipse(q,0,0.04,0.12,0.08)) over(result,0x4a342b,230);
    } else if (style==Beard::Full) {
        if (ellipse(q,0,0.33,0.95,0.85)&&q.y>=-0.17&&!ellipse(q,0,0,0.32,0.14)) {
            const bool stripe=(int(std::floor((q.x+4)*18+q.y*3))&3)==0;
            over(result,stripe?0x5e4639:0x3a2e28,230);
        }
    }
}
void puppy_ears(Rgba& result, Point p) {
    for (const double center:{-1.02,1.02}) {
        if (ellipse(p,center,0.08,0.3,0.78)) {
            over(result,0x80513a,235);
            if (ellipse(p,center,0.18,0.14,0.48)) over(result,0xc38b7e,220);
        }
    }
}
void accessory_pixel(Rgba& result, Accessory style, Point p, Point nose, Point mouth) {
    if (style==Accessory::Puppy) {
        if (ellipse(p,nose.x,nose.y+0.02,0.22,0.14)) over(result,0x28232a,245);
        if (ellipse(p,mouth.x,mouth.y+0.29,0.16,0.34)&&p.y>=mouth.y+0.05) {
            over(result,0xe98093,235);
            if (segment(p,{mouth.x,mouth.y+0.15},{mouth.x,mouth.y+0.48},0.015)) over(result,0xb74c66,190);
        }
    } else if (style==Accessory::KaraokeMic) {
        const Point center{mouth.x+0.9,mouth.y+0.2};
        if (segment(p,{center.x+0.1,center.y+0.26},{center.x+0.48,center.y+1.15},0.14)) over(result,0x3b4c6c,250);
        if (ellipse(p,center.x,center.y,0.3,0.38)) {
            const bool grid=((int(std::floor((p.x-center.x+0.4)*25))+
                int(std::floor((p.y-center.y+0.5)*25)))&1)==0;
            over(result,grid?0xb7bdc6:0x697283,250);
        }
        const Point note{mouth.x+1.43,mouth.y-0.68};
        if (ellipse(p,note.x,note.y+0.22,0.12,0.08)||
                segment(p,{note.x+0.1,note.y+0.2},{note.x+0.1,note.y-0.15},0.025)||
                segment(p,{note.x+0.1,note.y-0.15},{note.x+0.29,note.y-0.08},0.035)) over(result,0xec81ba,240);
    }
}
bool inside(const Prepared& c,int x,int y) {
    return c.valid&&c.active&&x>=0&&y>=0&&x<c.width&&y<c.height;
}
void face_pixel(Rgba& result, const Prepared& c, Point pixel) {
    if (!c.face_usable) return;
    const Point local=local_point(c,pixel.x,pixel.y);
    // Every face artwork is within this conservative local box.
    if (local.x<-3 || local.x>3 || local.y<-2 || local.y>4) return;
    if (c.options.accessory==Accessory::Puppy) puppy_ears(result,local);
    beard_pixel(result,c.options.beard,local,c.mouth_local);
    glasses_pixel(result,c.options.glasses,local);
    hat_pixel(result,c.options.hat,local);
    accessory_pixel(result,c.options.accessory,local,c.nose_local,c.mouth_local);
}
} // namespace

bool valid_options(const Options& o) {
    return uint32_t(o.glasses)<=3&&uint32_t(o.hat)<=3&&uint32_t(o.beard)<=3&&
        uint32_t(o.accessory)<=2&&uint32_t(o.scene)<=4;
}
bool is_neutral(const Options& o) {
    return o.glasses==Glasses::None&&o.hat==Hat::None&&o.beard==Beard::None&&
        o.accessory==Accessory::None&&o.scene==Scene::None&&!o.touch_up&&!o.low_light;
}
Prepared prepare(const Options& o,Frame f,const Face* face,LumaStats luma) {
    Prepared c;
    if (!valid_options(o)) return c;
    c.options=o;
    if (is_neutral(o)) { c.valid=true;return c; }
    if (!valid_frame(f)) return c;
    c.width=f.width;c.height=f.height;c.valid=true;
    const bool needs_face=o.glasses!=Glasses::None||o.hat!=Hat::None||o.beard!=Beard::None||
        o.accessory!=Accessory::None||o.touch_up;
    c.face_usable=needs_face&&prepare_face(c,f,face);
    if (o.scene!=Scene::None) prepare_upright_scene(c,f);
    if (o.low_light&&luma.sample_count&&luma.sample_count<=4096&&luma.mean_full_range<=255) {
        const int delta=std::max(0,96-int(luma.mean_full_range));
        c.low_light_gain_q8=uint16_t(256+std::min(128,delta*2));
    }
    c.active=c.face_usable||c.particle_count||c.low_light_gain_q8!=256;
    return c;
}
Rgba rgba_pixel(const Prepared& c,int x,int y) {
    Rgba result;
    if (!inside(c,x,y)) return result;
    const Point pixel{double(x)+0.5,double(y)+0.5};
    scene_pixel(result,c,pixel);
    face_pixel(result,c,pixel);
    return result;
}
Row prepare_row(const Prepared& c,int y) {
    Row row;
    row.y=y;row.begin=c.width;
    if (!inside(c,0,y) || c.particle_count>kMaxParticles) return row;
    row.valid=true;
    const double pixel_y=double(y)+0.5;
    const auto include = [&](double left,double right) {
        // One extra pixel makes floating boundary projection conservative.
        const int begin=std::clamp(int(std::floor(left-0.5))-1,0,c.width);
        const int end=std::clamp(int(std::ceil(right-0.5))+2,0,c.width);
        row.begin=std::min(row.begin,begin);row.end=std::max(row.end,end);
    };
    for (size_t i=0;i<c.particle_count;++i) {
        const auto& p=c.particles[i];
        if (pixel_y<p.top || pixel_y>p.bottom) continue;
        row.particles[row.particle_count++]=static_cast<uint8_t>(i);
        include(p.left,p.right);
    }
    const bool face_art=c.options.glasses!=Glasses::None || c.options.hat!=Hat::None ||
        c.options.beard!=Beard::None || c.options.accessory!=Accessory::None;
    const auto& b=c.face_artwork_bounds;
    row.face_possible=c.face_usable&&face_art&&pixel_y>=b.top-1&&pixel_y<=b.bottom+1;
    if (row.face_possible) include(b.left,b.right);
    if (row.end<=row.begin) row.begin=row.end=0;
    return row;
}
Rgba rgba_row_pixel(const Prepared& c,const Row& row,int x) {
    Rgba result;
    if (!row.valid || !inside(c,x,row.y) || x<row.begin || x>=row.end ||
            row.particle_count>kMaxParticles || c.particle_count>kMaxParticles) return result;
    const Point pixel{double(x)+0.5,double(row.y)+0.5};
    for (size_t i=0;i<row.particle_count;++i) {
        const size_t index=row.particles[i];
        if (index>=c.particle_count) return {};
        scene_particle_pixel(result,c.particles[index],pixel);
    }
    if (row.face_possible) face_pixel(result,c,pixel);
    return result;
}
uint8_t touch_up_weight(const Prepared& c,int x,int y) {
    if (!inside(c,x,y)||!c.options.touch_up||!c.face_usable) return 0;
    const Point p=local_point(c,double(x)+0.5,double(y)+0.5);
    const double distance=sq(p.x/0.83)+sq((p.y-0.48)/1.02);
    if (distance>=1||ellipse(p,-0.5,0,0.22,0.16)||ellipse(p,0.5,0,0.22,0.16)||
            ellipse(p,c.nose_local.x,c.nose_local.y,0.18,0.2)||
            ellipse(p,c.mouth_local.x,c.mouth_local.y,0.3,0.18)) return 0;
    return uint8_t(std::clamp(std::lround(std::min(1.0,(1-distance)*4)*32),0L,32L));
}
uint8_t low_light_luma(const Prepared& c,uint8_t luma,LumaRange range) {
    if (!c.valid||!c.options.low_light||c.low_light_gain_q8==256) return luma;
    const int black=range==LumaRange::Limited?16:0,white=range==LumaRange::Limited?235:255;
    return uint8_t(std::clamp(black+(std::max(0,int(luma)-black)*c.low_light_gain_q8+128)/256,black,white));
}
} // namespace dinox::video_overlays

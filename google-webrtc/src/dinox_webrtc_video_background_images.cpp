// Copyright 2026 DinoX contributors.
// SPDX-License-Identifier: Apache-2.0
#include "dinox_webrtc_video_background_images.hpp"
#include <algorithm>
#include <cstdlib>
#include <limits>
#include <new>
#include <utility>

namespace dinox::video_background_images {
namespace vc=video_compositor;
struct ImageSource {
    uint32_t id=0;
    uint64_t generation=0;
    int width=0,height=0;
    Builtin builtin=Builtin::None;
    std::vector<uint8_t> rgb;
};
namespace {
constexpr uint64_t kIdEnd=uint64_t(UINT32_MAX)+1;
bool valid_builtin(Builtin choice) { return uint32_t(choice)>=1&&uint32_t(choice)<=10; }
int format_index(vc::Range range,vc::Matrix matrix) {
    if ((range!=vc::Range::Limited&&range!=vc::Range::Full)||
            (matrix!=vc::Matrix::Bt601&&matrix!=vc::Matrix::Bt709)) return -1;
    return (range==vc::Range::Full?2:0)+(matrix==vc::Matrix::Bt709?1:0);
}
bool valid_input(Input input) {
    if (input.width<=0||input.height<=0||input.width>kMaxSide||input.height>kMaxSide||
            uint64_t(input.width)*uint64_t(input.height)>kMaxPixels||
            (input.format!=PixelFormat::Rgb888&&input.format!=PixelFormat::Rgba8888)||
            input.bytes.empty()||!input.bytes.data()||input.bytes.size()>kMaxInputBytes) return false;
    const size_t bpp=input.format==PixelFormat::Rgb888?3:4;
    const size_t row=size_t(input.width)*bpp;
    if (input.stride<row||input.stride>kMaxInputBytes) return false;
    const size_t rows=size_t(input.height-1);
    if (rows&&(input.stride>(kMaxInputBytes-row)/rows)) return false;
    return input.bytes.size()>=rows*input.stride+row;
}
bool overlaps(std::span<const uint8_t> a,std::span<const uint8_t> b) {
    if (a.empty()||b.empty()) return false;
    const uintptr_t first=reinterpret_cast<uintptr_t>(a.data()),second=reinterpret_cast<uintptr_t>(b.data());
    if (!first||!second||a.size()>std::numeric_limits<uintptr_t>::max()-first||
            b.size()>std::numeric_limits<uintptr_t>::max()-second) return true;
    return first<second+b.size()&&second<first+a.size();
}
int rounded(int64_t numerator,int64_t denominator) {
    return int(numerator>=0?(numerator+denominator/2)/denominator:-((-numerator+denominator/2)/denominator));
}
uint8_t byte(int value) { return uint8_t(std::clamp(value,0,255)); }
std::vector<uint8_t> copy_rgb(Input input) {
    std::vector<uint8_t> pixels(size_t(input.width)*size_t(input.height)*3);
    const size_t bpp=input.format==PixelFormat::Rgb888?3:4;
    for(int y=0;y<input.height;++y) {
        const auto row=input.bytes.subspan(size_t(y)*input.stride,size_t(input.width)*bpp);
        const auto output=std::span(pixels).subspan(size_t(y)*size_t(input.width)*3,size_t(input.width)*3);
        for(int x=0;x<input.width;++x) {
            const auto pixel=row.subspan(size_t(x)*bpp,bpp);
            const int alpha=bpp==4?pixel[3]:255;
            for(size_t c=0;c<3;++c)output[size_t(x)*3+c]=uint8_t((int(pixel[c])*alpha+48*(255-alpha)+127)/255);
        }
    }
    return pixels;
}
std::vector<uint8_t> convert(const ImageSource& source,vc::Range range,vc::Matrix matrix) {
    const size_t ysize=size_t(source.width)*size_t(source.height);
    const int cw=(source.width+1)/2,ch=(source.height+1)/2;
    const size_t csize=size_t(cw)*size_t(ch);
    std::vector<uint8_t> output(ysize+2*csize);
    const auto yplane=std::span(output).first(ysize);
    const auto uplane=std::span(output).subspan(ysize,csize);
    const auto vplane=std::span(output).subspan(ysize+csize,csize);
    const int kr=matrix==vc::Matrix::Bt709?2126:2990,kb=matrix==vc::Matrix::Bt709?722:1140;
    const int kg=10000-kr-kb,excursion=range==vc::Range::Full?255:224;
    const auto rgb=std::span(source.rgb);
    for(int cy=0;cy<ch;++cy)for(int cx=0;cx<cw;++cx) {
        int64_t sum_y=0,sum_r=0,sum_b=0;int count=0;
        for(int dy=0;dy<2&&2*cy+dy<source.height;++dy)for(int dx=0;dx<2&&2*cx+dx<source.width;++dx) {
            const int x=2*cx+dx,y=2*cy+dy;
            const auto pixel=rgb.subspan((size_t(y)*size_t(source.width)+size_t(x))*3,3);
            const int64_t weighted=int64_t(kr)*pixel[0]+int64_t(kg)*pixel[1]+int64_t(kb)*pixel[2];
            yplane[size_t(y)*size_t(source.width)+size_t(x)]=byte(range==vc::Range::Full?
                rounded(weighted,10000):16+rounded(weighted*219,INT64_C(255)*10000));
            sum_y+=weighted;sum_r+=pixel[0];sum_b+=pixel[2];++count;
        }
        const size_t index=size_t(cy)*size_t(cw)+size_t(cx);
        uplane[index]=byte(128+rounded((10000*sum_b-sum_y)*excursion,INT64_C(2)*255*(10000-kb)*count));
        vplane[index]=byte(128+rounded((10000*sum_r-sum_y)*excursion,INT64_C(2)*255*(10000-kr)*count));
    }
    return output;
}
uint32_t mix(uint32_t a,uint32_t b,int amount) {
    uint32_t rgb=0;
    for(const int shift:{16,8,0})rgb|=uint32_t((((a>>shift)&255)*(255-amount)+((b>>shift)&255)*amount+127)/255)<<shift;
    return rgb;
}
bool rect(int x,int y,int left,int top,int width,int height) {
    return x>=left&&y>=top&&x<left+width&&y<top+height;
}
bool ellipse(int x,int y,int cx,int cy,int rx,int ry) {
    const int64_t dx=x-cx,dy=y-cy;
    return dx*dx*ry*ry+dy*dy*rx*rx<=int64_t(rx)*rx*ry*ry;
}
uint32_t builtin_pixel(Builtin kind,int x,int y) {
    // Original small geometric scenes. These are artwork, not stock photographs.
    constexpr std::array<uint32_t,10> top{0xe6d6bc,0xc9dfec,0xdec2a4,0xadafaa,0xf8e2b0,
        0x272559,0x8dd6ee,0x73396e,0x49315d,0x789c7a};
    constexpr std::array<uint32_t,10> bottom{0x967054,0x6e8ba0,0x936142,0x5b625c,0xeaa26d,
        0x936bc9,0xf2d5a1,0xf6ac67,0x917091,0x254a3e};
    const size_t index=size_t(uint32_t(kind)-1);
    uint32_t color=mix(top[index],bottom[index],y*255/179);
    switch(kind) {
        case Builtin::LivingRoom:
            if(y>=123)color=0xa37c5b;
            if(rect(x,y,28,22,68,82))color=0x81b3c6;
            if(rect(x,y,59,22,6,82)||rect(x,y,28,60,68,5))color=0xf3e4ca;
            if(rect(x,y,137,101,145,51)||rect(x,y,129,115,14,32)||rect(x,y,276,115,14,32))color=0x4f7770;
            if(rect(x,y,150,105,54,25)||rect(x,y,212,105,54,25))color=0x83a698;
            if(rect(x,y,43,133,25,29))color=0x805341;
            if(ellipse(x,y,56,111,19,28))color=0x466c43;
            break;
        case Builtin::Office:
            if(rect(x,y,67,108,215,13)||rect(x,y,81,120,10,51)||rect(x,y,259,120,10,51))color=0x665e58;
            if(rect(x,y,103,37,140,70))color=0x35485b;
            if(rect(x,y,109,43,128,58))color=0x6694ab;
            if(rect(x,y,160,102,23,9))color=0x35485b;
            if(rect(x,y,18,44,44,72))color=0xe4edf3;
            if(rect(x,y,25,56,30,5)||rect(x,y,25,71,30,5)||rect(x,y,25,86,30,5))color=0x91a6b4;
            break;
        case Builtin::Cafe:
            if(y<105&&(y%18<2||((x+(y/18%2)*25)%50)<2))color=0xbb987b;
            if(ellipse(x,y,169,127,67,12)||rect(x,y,162,128,13,45))color=0x5c4031;
            if(rect(x,y,141,102,19,22))color=0xf5ead5;
            if(ellipse(x,y,164,111,7,7)&&!ellipse(x,y,164,111,4,4))color=0xf5ead5;
            if(rect(x,y,30,52,55,64))color=0x404c40;
            if(rect(x,y,35,58,45,52))color=0x79977d;
            break;
        case Builtin::Stones:
            for(int row=0;row<4;++row)for(int column=0;column<7;++column) {
                const int cx=column*50+(row%2)*20,cy=35+row*43;
                if(ellipse(x,y,cx,cy,24,17))color=((row+column)%3)==0?0x6f7775:((row+column)%3)==1?0x96938b:0xc6beb0;
            }
            break;
        case Builtin::Food:
            if(y>=88)color=((x/24)%2)?0xf0c38c:0xe8b47e;
            if(ellipse(x,y,172,125,90,34))color=0xf8f0da;
            if(ellipse(x,y,138,124,22,20))color=0xca5346;
            if(ellipse(x,y,181,132,28,17))color=0xedb752;
            if(ellipse(x,y,219,116,17,17))color=0x86a653;
            if(ellipse(x,y,145,102,10,4))color=0x53734a;
            if(rect(x,y,63,103,4,57)||rect(x,y,59,95,3,20)||rect(x,y,66,95,3,20))color=0x747c86;
            break;
        case Builtin::Abstract:
            if(x+y>185&&x-y<150)color=0x4389a0;
            if(ellipse(x,y,243,47,55,55))color=0xe4b462;
            if(ellipse(x,y,88,122,61,61)&&!ellipse(x,y,88,122,36,36))color=0xb985c8;
            if(x>=150&&x<=170&&y<=125)color=0xe59280;
            break;
        case Builtin::Beach:
            if(y>=96)color=0x499fbc;
            if(y>=127)color=0xf2d5a1;
            if(y>=107&&y<=111&&(x/35)%2==0)color=0xa4e2e4;
            if(rect(x,y,71,104,4,54))color=0x83624a;
            if(y>=65&&y<=106&&std::abs(x-73)<(y-65)*2)color=x<73?0xe17c64:0xeadfba;
            if(ellipse(x,y,230,146,14,5))color=0xc3a080;
            break;
        case Builtin::Sunset:
            if(ellipse(x,y,230,78,26,26))color=0xfbd887;
            if(y>=110)color=0x564565;
            if(y>=111&&y<151&&std::abs(x-230)<28-(y-111)/2)color=0xc9977a;
            if((x<105&&y>112-x/6)||(x>270&&y>116-(319-x)/4))color=0x39334e;
            break;
        case Builtin::Celebration:
            for(int i=0;i<8;++i) {
                const int cx=21+i*40,cy=43+(i%3)*12;
                if(ellipse(x,y,cx,cy,12,17))color=i%3==0?0xeaa15a:i%3==1?0xc876b7:0x7fbdba;
                if(x==cx&&y>cy+16&&y<cy+74)color=0xded0d8;
            }
            if(y<13+(x%32)/2)color=(x/32)%2?0xdeb36d:0xa697d6;
            break;
        case Builtin::Forest:
            for(int i=0;i<7;++i) {
                const int cx=i*53,peak=21+(i%3)*12;
                if(y>peak&&y<145&&std::abs(x-cx)<(y-peak)/3)color=i%2?0x315a42:0x446c47;
                if(rect(x,y,cx-3,110,7,57))color=0x6a5845;
            }
            if(y>113&&std::abs(x-175)<(y-113)*3/4)color=0xb9ae8b;
            break;
        case Builtin::None:break;
    }
    return color;
}
std::vector<uint8_t> render_builtin(Builtin choice) {
    std::vector<uint8_t> rgb(320*180*3);
    for(int y=0;y<180;++y)for(int x=0;x<320;++x) {
        const uint32_t color=builtin_pixel(choice,x,y);
        const size_t offset=(size_t(y)*320+size_t(x))*3;
        rgb[offset]=uint8_t(color>>16);rgb[offset+1]=uint8_t(color>>8);rgb[offset+2]=uint8_t(color);
    }
    return rgb;
}
} // namespace

IdAllocator::IdAllocator(uint64_t first) noexcept:next_(first>=1&&first<=kIdEnd?first:kIdEnd) {}
std::optional<uint32_t> IdAllocator::reserve() noexcept {
    uint64_t value=next_.load(std::memory_order_relaxed);
    while(value<kIdEnd) {
        if(next_.compare_exchange_weak(value,value+1,std::memory_order_relaxed))return uint32_t(value);
    }
    return std::nullopt;
}
IdAllocator& process_id_allocator() noexcept { static IdAllocator ids;return ids; }
Asset::Asset(std::shared_ptr<const ImageSource> source,vc::Range range,vc::Matrix matrix,std::vector<uint8_t> pixels)
    :source_(std::move(source)),range_(range),matrix_(matrix),pixels_(std::move(pixels)) {}
uint32_t Asset::id() const noexcept { return source_->id; }
uint64_t Asset::generation() const noexcept { return source_->generation; }
int Asset::width() const noexcept { return source_->width; }
int Asset::height() const noexcept { return source_->height; }
vc::Range Asset::range() const noexcept { return range_; }
vc::Matrix Asset::matrix() const noexcept { return matrix_; }
std::span<const uint8_t> Asset::rgb() const noexcept { return source_->rgb; }
vc::StagedImageView Asset::view() const noexcept {
    const size_t ys=size_t(width())*size_t(height()),cs=size_t((width()+1)/2)*size_t((height()+1)/2);
    const auto pixels=std::span(pixels_);
    return {{width(),height(),range_,matrix_,{pixels.first(ys),width()},
        {pixels.subspan(ys,cs),(width()+1)/2},{pixels.subspan(ys+cs,cs),(width()+1)/2}}};
}
BackgroundImageRegistry::BackgroundImageRegistry(IdAllocator& ids) noexcept:ids_(ids) {}
std::optional<BackgroundImageRegistry::Reservation> BackgroundImageRegistry::reserve_source_locked(Status& status) {
    if(exhausted_){status=Status::GenerationExhausted;return std::nullopt;}
    for(size_t i=0;i<sources_.size();++i) {
        auto& slot=sources_[i];
        if(slot.reserved_id||!slot.source.expired())continue;
        const auto id=ids_.reserve();
        if(!id){status=Status::IdExhausted;return std::nullopt;}
        slot.reserved_id=*id;return Reservation{i,*id,generation_};
    }
    status=Status::NoMemory;return std::nullopt;
}
bool BackgroundImageRegistry::aliases_locked(std::span<const uint8_t> bytes) const {
    for(const auto& slot:sources_)if(const auto source=slot.source.lock();source&&overlaps(bytes,source->rgb))return true;
    for(const auto& slot:variants_)if(const auto asset=slot.asset.lock();asset&&overlaps(bytes,asset->pixels_))return true;
    return false;
}
std::shared_ptr<const ImageSource> BackgroundImageRegistry::source_locked(uint32_t id) const {
    if(!id||exhausted_)return {};
    for(const auto& slot:sources_)if(const auto source=slot.source.lock();slot.registered&&source&&source->id==id&&source->generation==generation_)return source;
    return {};
}
Lease BackgroundImageRegistry::lease_locked(uint32_t id,vc::Range range,vc::Matrix matrix) const {
    if(!source_locked(id))return {};
    for(const auto& slot:variants_)if(const auto asset=slot.asset.lock();asset&&asset->id()==id&&
            asset->generation()==generation_&&asset->range_==range&&asset->matrix_==matrix)return asset;
    return {};
}
UploadResult BackgroundImageRegistry::upload(Input input) {
    if(!valid_input(input))return {Status::InvalidInput,0};
    return stage(input,Builtin::None);
}
UploadResult BackgroundImageRegistry::create_builtin(Builtin choice) {
    if(!valid_builtin(choice))return {Status::InvalidInput,0};
    return stage({},choice);
}
UploadResult BackgroundImageRegistry::stage(Input input,Builtin choice) {
    Status status=Status::Ok;std::optional<Reservation> reserved;
    {
        std::lock_guard lock(mutex_);
        if(exhausted_)return {Status::GenerationExhausted,0};
        if(choice!=Builtin::None) {
            for(const auto& slot:sources_)if(const auto source=slot.source.lock();slot.registered&&source&&source->generation==generation_&&source->builtin==choice) {
                current_source_=source;
                return {Status::Ok,source->id};
            }
        } else if(aliases_locked(input.bytes))return {Status::InvalidInput,0};
        reserved=reserve_source_locked(status);
        if(!reserved)return {status,0};
    }
    std::shared_ptr<const ImageSource> source;
#if defined(__cpp_exceptions) || defined(__EXCEPTIONS) || defined(_CPPUNWIND)
    try {
#else
    {
#endif
        auto owned=std::make_shared<ImageSource>();
        owned->id=reserved->id;owned->generation=reserved->generation;owned->builtin=choice;
        owned->width=choice==Builtin::None?input.width:320;owned->height=choice==Builtin::None?input.height:180;
        owned->rgb=choice==Builtin::None?copy_rgb(input):render_builtin(choice);
        source=std::move(owned);
    }
#if defined(__cpp_exceptions) || defined(__EXCEPTIONS) || defined(_CPPUNWIND)
    catch(const std::bad_alloc&) { status=Status::NoMemory; }
#endif
    {
        std::lock_guard lock(mutex_);
        auto& slot=sources_[reserved->slot];
        if(status!=Status::Ok){source.reset();slot.reserved_id=0;return {status,0};}
        if(exhausted_||generation_!=reserved->generation){
            // Free unpublished pixels before freeing their reservation. Another
            // staging lane cannot temporarily allocate a third source buffer.
            source.reset();slot.reserved_id=0;return {Status::Unavailable,0};
        }
        slot.source=source;slot.registered=true;current_source_=std::move(source);slot.reserved_id=0;
        // Keep the previously prepared asset until the new format commits. A
        // failed/cancelled preparation must not make the old active lookup vanish.
    }
    return {Status::Ok,reserved->id};
}
PrepareResult BackgroundImageRegistry::prepare(uint32_t id,vc::Range range,vc::Matrix matrix) {
    const int format=format_index(range,matrix);
    if(format<0)return {Status::InvalidInput,{}};
    std::shared_ptr<const ImageSource> source;size_t reserved_slot=variants_.size();uint64_t reserved_generation=0;
    {
        std::lock_guard lock(mutex_);
        source=source_locked(id);
        if(!source)return {Status::Unavailable,{}};
        if(auto asset=lease_locked(id,range,matrix)) {current_source_=source;current_asset_=asset;return {Status::Ok,std::move(asset)};}
        for(size_t i=0;i<variants_.size();++i) {
            const auto& slot=variants_[i];
            if(slot.reserved_id==id&&slot.reserved_generation==generation_&&slot.reserved_format==format)return {Status::Unavailable,{}};
            if(reserved_slot==variants_.size()&&!slot.reserved_id&&slot.asset.expired())reserved_slot=i;
        }
        if(reserved_slot==variants_.size())return {Status::NoMemory,{}};
        auto& slot=variants_[reserved_slot];
        slot.reserved_id=id;slot.reserved_generation=generation_;slot.reserved_format=format;reserved_generation=generation_;
    }
    Lease asset;Status status=Status::Ok;
#if defined(__cpp_exceptions) || defined(__EXCEPTIONS) || defined(_CPPUNWIND)
    try {asset=Lease(new Asset(source,range,matrix,convert(*source,range,matrix)));}
    catch(const std::bad_alloc&) {status=Status::NoMemory;}
#else
    asset=Lease(new Asset(source,range,matrix,convert(*source,range,matrix)));
#endif
    {
        std::lock_guard lock(mutex_);
        auto& slot=variants_[reserved_slot];
        const bool invalidated=exhausted_||generation_!=reserved_generation||!source_locked(id);
        if(status!=Status::Ok||invalidated){
            asset.reset();source.reset();slot.reserved_id=0;slot.reserved_generation=0;slot.reserved_format=-1;
            return {status!=Status::Ok?status:Status::Unavailable,{}};
        }
        slot.asset=asset;current_source_=source;current_asset_=asset;
        slot.reserved_id=0;slot.reserved_generation=0;slot.reserved_format=-1;
    }
    return {Status::Ok,std::move(asset)};
}
Lease BackgroundImageRegistry::acquire(uint32_t id,vc::Range range,vc::Matrix matrix) const {
    if(format_index(range,matrix)<0)return {};
    std::lock_guard lock(mutex_);return lease_locked(id,range,matrix);
}
bool BackgroundImageRegistry::contains(uint32_t id) const {
    std::lock_guard lock(mutex_); return bool(source_locked(id));
}
std::shared_ptr<const ImageSource> BackgroundImageRegistry::retain_source(uint32_t id) const {
    std::lock_guard lock(mutex_); return source_locked(id);
}
size_t BackgroundImageRegistry::owned_pixel_bytes() const {
    std::lock_guard lock(mutex_); size_t bytes=0;
    for(const auto& slot:sources_) if(const auto source=slot.source.lock()) bytes+=source->rgb.capacity();
    for(const auto& slot:variants_) if(const auto asset=slot.asset.lock()) bytes+=asset->pixels_.capacity();
    return bytes;
}
void BackgroundImageRegistry::retire_other_format(uint32_t id,vc::Range range,vc::Matrix matrix) {
    if(!id||format_index(range,matrix)<0)return;
    Lease retired;
    {
        std::lock_guard lock(mutex_);
        if(current_asset_&&current_asset_->id()==id&&
                (current_asset_->range_!=range||current_asset_->matrix_!=matrix))
            retired=std::move(current_asset_);
    }
    // No slot is declared free early: its weak lease tracks this temporary and
    // every existing reader until actual release. Destruction is outside lock.
}
Status BackgroundImageRegistry::discard(uint32_t id) {
    std::lock_guard lock(mutex_);
    if(!source_locked(id))return Status::Unavailable;
    for(auto& slot:sources_)if(const auto source=slot.source.lock();source&&source->id==id)slot.registered=false;
    if(current_source_&&current_source_->id==id)current_source_.reset();
    if(current_asset_&&current_asset_->id()==id)current_asset_.reset();
    return Status::Ok;
}
Status BackgroundImageRegistry::reset() {
    std::lock_guard lock(mutex_);current_asset_.reset();current_source_.reset();
    if(generation_==UINT64_MAX){exhausted_=true;return Status::GenerationExhausted;}
    ++generation_;return Status::Ok;
}
uint64_t BackgroundImageRegistry::generation() const {std::lock_guard lock(mutex_);return generation_;}
size_t BackgroundImageRegistry::retained_sources() const {
    std::lock_guard lock(mutex_);size_t count=0;
    for(const auto& slot:sources_)count+=bool(slot.reserved_id)||!slot.source.expired();
    return count;
}
size_t BackgroundImageRegistry::retained_variants() const {
    std::lock_guard lock(mutex_);size_t count=0;
    for(const auto& slot:variants_)count+=bool(slot.reserved_id)||!slot.asset.expired();
    return count;
}
} // namespace dinox::video_background_images

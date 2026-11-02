// Copyright 2026 DinoX contributors.
// SPDX-License-Identifier: Apache-2.0
// This library is loaded exclusively by NativeVisionBridge in :video_vision.
// Never call inference synchronously from capture, audio or signalling.
#include "vision_android_wire.hpp"
#include "vision_inference.hpp"

#include <android/asset_manager.h>
#include <android/asset_manager_jni.h>
#include <jni.h>

#include <array>
#include <cstdlib>
#include <limits>
#include <memory>
#include <mutex>
#include <new>
#include <optional>
#include <stdexcept>
#include <string_view>
#include <time.h>
#include <unordered_map>
#include <utility>
#include <vector>

namespace {
namespace wire=dinox::vision::android_wire;
using dinox::vision::Face;
using dinox::vision::ModelRuntime;
using dinox::vision::ModelTask;
constexpr std::string_view kSegmentAsset="video-vision/selfie_segmenter_landscape-v1.tflite";
constexpr std::string_view kFaceAsset="video-vision/blaze-face-short-range-v1.tflite";
constexpr std::string_view kSegmentSha="490e9ea734313e0de10fa0cd9e3c6133e36ea4db2b7a49bde9ef019f72796b8e";
constexpr std::string_view kFaceSha="b4578f35940bf5a1a655214a1cce5cab13eba73c1297cd78e1a04c2380b0152f";

struct State {
    jobject assets_ref=nullptr;
    AAssetManager* assets=nullptr; // kept alive by assets_ref, never independently deleted
    uint32_t demand=0;
    std::unique_ptr<ModelRuntime> segment;
    std::unique_ptr<ModelRuntime> face;
    std::optional<Face> previous_face;
    std::optional<wire::History> previous_request;
};
// Registry IDs are positive monotone Java longs, never native pointers. The
// private service admits one backend; enforce that bound again at JNI. Holding
// this independent lock over Invoke prevents nativeClose/read UAF even if a
// caller violates the Java service's serialization. This is never a call lock.
std::mutex registry_mutex;
std::unordered_map<jlong,std::unique_ptr<State>> states;
jlong next_handle=1;

[[noreturn]] void fail() { throw std::runtime_error("Isolated vision backend failed"); }
void java_failure(JNIEnv* env) {
    if (env->ExceptionCheck()) return; // preserve a JNI allocation/type error
    const jclass exception=env->FindClass("java/lang/IllegalStateException");
    if (exception) {
        env->ThrowNew(exception,"Isolated vision backend failed");
        env->DeleteLocalRef(exception);
    }
}
struct UtfChars {
    JNIEnv* env;
    jstring string;
    const char* chars;
    ~UtfChars() { if (chars) env->ReleaseStringUTFChars(string,chars); }
};
bool exact_string(JNIEnv* env,jstring value,std::string_view expected) {
    if (!value||env->ExceptionCheck()) return false;
    const jsize size=env->GetStringUTFLength(value);
    if (size<0||size_t(size)!=expected.size()||env->ExceptionCheck()) return false;
    UtfChars chars{env,value,env->GetStringUTFChars(value,nullptr)};
    if (!chars.chars||env->ExceptionCheck()) return false;
    // JNI guarantees exactly GetStringUTFLength readable bytes plus a terminator.
    // The bounded view is the single pointer/extent boundary, not a string scan.
#if defined(__clang__)
#pragma clang unsafe_buffer_usage begin
#endif
    const std::string_view actual(chars.chars,size_t(size));
#if defined(__clang__)
#pragma clang unsafe_buffer_usage end
#endif
    return actual==expected;
}
struct GlobalRef {
    JNIEnv* env;
    jobject value;
    ~GlobalRef() { if (value) env->DeleteGlobalRef(value); }
    jobject release() { return std::exchange(value,nullptr); }
};
State& state(jlong handle) {
    const auto found=states.find(handle);
    if (handle<=0||found==states.end()||!found->second) fail();
    return *found->second;
}
uint64_t monotonic_ns() {
    timespec time{};
    // Android elapsedRealtimeNanos uses the suspend-inclusive BOOTTIME clock.
    if (clock_gettime(CLOCK_BOOTTIME,&time)||time.tv_sec<0||time.tv_nsec<0||time.tv_nsec>=1000000000) fail();
    const uint64_t seconds=uint64_t(time.tv_sec);
    if (seconds>(std::numeric_limits<uint64_t>::max()-uint64_t(time.tv_nsec))/UINT64_C(1000000000)) fail();
    return seconds*UINT64_C(1000000000)+uint64_t(time.tv_nsec);
}
std::vector<uint8_t> read_asset(State& owner,ModelTask task) {
    const size_t expected=task==ModelTask::Segmentation?250177:229746;
    const auto name=task==ModelTask::Segmentation?kSegmentAsset:kFaceAsset;
    // Both names are fixed, NUL-terminated string literals; callers cannot supply
    // paths. APK asset access happens only in the child inference lane.
    std::unique_ptr<AAsset,decltype(&AAsset_close)> asset(
        AAssetManager_open(owner.assets,name.data(),AASSET_MODE_STREAMING),&AAsset_close);
    if (!asset||AAsset_getLength64(asset.get())!=off64_t(expected)) fail();
    std::vector<uint8_t> bytes(expected);
    size_t used=0;
    while (used<bytes.size()) {
        const auto remaining=std::span(bytes).subspan(used);
        const int count=AAsset_read(asset.get(),remaining.data(),remaining.size());
        if (count<=0||size_t(count)>remaining.size()) fail();
        used+=size_t(count);
    }
    std::array<uint8_t,1> extra{};
    if (AAsset_read(asset.get(),extra.data(),extra.size())!=0) fail();
    return bytes;
}
void demand(State& owner,uint32_t mask) {
    if (mask>3) fail();
    if (!(mask&wire::kSegmentDemand)) owner.segment.reset();
    if (!(mask&wire::kFaceDemand)) { owner.face.reset();owner.previous_face.reset(); }
    owner.demand=mask;
    // Adding demand is inert. It does not construct/read either model.
}
std::vector<uint8_t> infer(State& owner,std::span<const uint8_t> packet) {
    const auto request=wire::parse_request(packet);
    if (!request||request->demand!=owner.demand||!wire::fresh(*request,monotonic_ns())||
            (owner.previous_request&&!wire::follows(*owner.previous_request,*request))) fail();
    if (owner.previous_request&&(request->identity.source!=owner.previous_request->identity.source||
            request->identity.transform!=owner.previous_request->identity.transform)) owner.previous_face.reset();
    std::vector<uint8_t> mask;
    if (request->demand&wire::kSegmentDemand) {
        if (!owner.segment) owner.segment=ModelRuntime::create_from_bytes(ModelTask::Segmentation,
            read_asset(owner,ModelTask::Segmentation));
        mask.resize(wire::kMaskBytes);
        if (!owner.segment||!owner.segment->segment(request->segment_rgb,mask)) fail();
    }
    std::optional<Face> detected;
    if (request->demand&wire::kFaceDemand) {
        if (!owner.face) owner.face=ModelRuntime::create_from_bytes(ModelTask::Face,read_asset(owner,ModelTask::Face));
        if (!owner.face||!owner.face->face(request->face_rgb,
                owner.previous_face?&*owner.previous_face:nullptr,&detected)) fail();
        owner.previous_face=detected;
    }
    auto result=wire::encode_result(*request,mask,detected?&*detected:nullptr);
    if (!result) fail(); // never replace a model error with a missing/empty mask
    owner.previous_request=wire::history(*request);
    return std::move(*result);
}
} // namespace

extern "C" JNIEXPORT jlong JNICALL
Java_eu_siacs_conversations_xmpp_jingle_NativeVisionBridge_nativeCreate(JNIEnv* env,jclass,
        jobject assets,jstring segment_asset,jstring segment_sha,jstring face_asset,jstring face_sha,jint version) {
    try {
        if (!env||env->ExceptionCheck()||!assets||version!=jint(wire::kVersion)||
                !exact_string(env,segment_asset,kSegmentAsset)||!exact_string(env,segment_sha,kSegmentSha)||
                !exact_string(env,face_asset,kFaceAsset)||!exact_string(env,face_sha,kFaceSha)) fail();
        std::lock_guard guard(registry_mutex);
        if (!states.empty()||next_handle<=0||next_handle==std::numeric_limits<jlong>::max()) fail();
        auto owner=std::make_unique<State>();
        GlobalRef reference{env,env->NewGlobalRef(assets)};
        if (!reference.value||env->ExceptionCheck()) fail();
        owner->assets=AAssetManager_fromJava(env,reference.value);
        if (!owner->assets||env->ExceptionCheck()) fail();
        const jlong handle=next_handle++;
        owner->assets_ref=reference.release();
        states.emplace(handle,std::move(owner));
        // No asset bytes, interpreter, delegate or inference were created here.
        return handle;
    } catch (const std::bad_alloc&) { std::abort(); }
    catch (...) { if (env) java_failure(env);return 0; }
}

extern "C" JNIEXPORT void JNICALL
Java_eu_siacs_conversations_xmpp_jingle_NativeVisionBridge_nativeApplyDemand(JNIEnv* env,jclass,jlong handle,jint mask) {
    try {
        if (!env||env->ExceptionCheck()||mask<0||mask>3) fail();
        std::lock_guard guard(registry_mutex);
        demand(state(handle),uint32_t(mask));
    } catch (const std::bad_alloc&) { std::abort(); }
    catch (...) { if (env) java_failure(env); }
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_eu_siacs_conversations_xmpp_jingle_NativeVisionBridge_nativeInfer(JNIEnv* env,jclass,jlong handle,jbyteArray input) {
    try {
        if (!env||env->ExceptionCheck()||!input) fail();
        const jsize size=env->GetArrayLength(input);
        if (env->ExceptionCheck()||size<jsize(wire::kHeaderBytes)||size>jsize(wire::kMaxRequestBytes)) fail();
        std::vector<uint8_t> packet(size_t(size),uint8_t(0));
        env->GetByteArrayRegion(input,0,size,reinterpret_cast<jbyte*>(packet.data()));
        if (env->ExceptionCheck()) fail();
        std::lock_guard guard(registry_mutex);
        const auto result=infer(state(handle),packet);
        if (result.size()>wire::kMaxResultBytes) fail();
        jbyteArray output=env->NewByteArray(jsize(result.size()));
        if (!output||env->ExceptionCheck()) fail();
        env->SetByteArrayRegion(output,0,jsize(result.size()),reinterpret_cast<const jbyte*>(result.data()));
        if (env->ExceptionCheck()) { env->DeleteLocalRef(output);fail(); }
        return output;
    } catch (const std::bad_alloc&) { std::abort(); }
    catch (...) { if (env) java_failure(env);return nullptr; }
}

extern "C" JNIEXPORT void JNICALL
Java_eu_siacs_conversations_xmpp_jingle_NativeVisionBridge_nativeClose(JNIEnv* env,jclass,jlong handle) {
    try {
        if (!env||env->ExceptionCheck()) fail();
        std::lock_guard guard(registry_mutex);
        auto& owner=state(handle);
        // Lock ownership proves no Invoke/read is active. Model destructors free
        // interpreters, delegates and their owned bytes before Java can ack close.
        owner.previous_face.reset();owner.previous_request.reset();
        owner.face.reset();owner.segment.reset();
        env->DeleteGlobalRef(owner.assets_ref);
        owner.assets_ref=nullptr;owner.assets=nullptr;
        states.erase(handle);
    } catch (const std::bad_alloc&) { std::abort(); }
    catch (...) { if (env) java_failure(env); }
}

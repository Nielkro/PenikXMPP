#include "vision_inference.hpp"
#include "vision_protocol.hpp"
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <filesystem>
#include <initializer_list>
#include <vector>
#include <string_view>
#include "openssl/sha.h"
#include "flatbuffers/verifier.h"
#include "tensorflow/lite/c/builtin_op_data.h"
#if defined(DINOX_VISION_ANDROID_ARMV7_TFLITE_CPU_ONLY)
// The pinned Chromium XNNPACK wrapper has no standalone ARM32 target. Only
// this Android ARMv7 build uses the same TFLite models with builtin CPU ops.
// Never turn a missing delegate on another target into a silent fallback.
#if DINOX_VISION_ANDROID_ARMV7_TFLITE_CPU_ONLY != 1 || !defined(__ANDROID__) || \
    !defined(__arm__) || defined(__aarch64__) || defined(TFLITE_BUILD_WITH_XNNPACK)
#error "DinoX TFLite CPU-only profile is restricted to Android ARMv7 without XNNPACK"
#endif
#else
#include "tensorflow/lite/delegates/xnnpack/xnnpack_delegate.h"
#endif
#include "tensorflow/lite/interpreter.h"
#include "tensorflow/lite/interpreter_builder.h"
#include "tensorflow/lite/kernels/register.h"
#include "tensorflow/lite/model_builder.h"
#include "tensorflow/lite/schema/schema_generated.h"
#include "mediapipe/util/tflite/operations/transpose_conv_bias.h"

namespace dinox::vision {
namespace {
constexpr char kSegmentSha[] = "490e9ea734313e0de10fa0cd9e3c6133e36ea4db2b7a49bde9ef019f72796b8e";
constexpr char kFaceSha[] = "b4578f35940bf5a1a655214a1cce5cab13eba73c1297cd78e1a04c2380b0152f";
constexpr char kCustomOp[] = "Convolution2DTransposeBias";
// The TFLite C++ API returns raw tensor pointers. Every caller first validates
// exact type, shape and byte size with valid_tensors(); only that checked
// boundary converts the pointer into a bounded span.
template<class T> std::span<T> checked_tensor_view(T* data, size_t count) {
    if (!data || !count || count > kSegmentRgbBytes) return {};
#if defined(__clang__)
#pragma clang unsafe_buffer_usage begin
#endif
    return {data,count};
#if defined(__clang__)
#pragma clang unsafe_buffer_usage end
#endif
}
bool shape(const TfLiteTensor* tensor, std::initializer_list<int> wanted) {
    if (!tensor || tensor->type != kTfLiteFloat32 || !tensor->dims ||
            tensor->dims->size != int(wanted.size())) return false;
    size_t elements = 1;
    size_t i = 0;
    // TFLite owns its flexible dimension array; its declared length was just
    // checked against the fixed expected shape before this bounded view.
    const auto dimensions = checked_tensor_view<const int>(tensor->dims->data, wanted.size());
    if (dimensions.size() != wanted.size()) return false;
    for (const int dim : wanted) {
        if (dimensions[i++] != dim) return false;
        elements *= size_t(dim);
    }
    return tensor->bytes == elements * sizeof(float);
}
bool validate_pinned_model(ModelTask task, const std::vector<uint8_t>& storage) {
    const size_t expected_size = task == ModelTask::Segmentation ? 250177 : 229746;
    const std::string_view expected_sha = task == ModelTask::Segmentation ? kSegmentSha : kFaceSha;
    if (storage.size() != expected_size) return false;
    const auto* bytes = &storage;
    std::array<unsigned char,SHA256_DIGEST_LENGTH> digest{};
    if (!SHA256(bytes->data(), bytes->size(), digest.data())) return false;
    static constexpr std::string_view hex = "0123456789abcdef";
    for (size_t i = 0; i < digest.size(); ++i) {
        if (hex[digest[i] >> 4] != expected_sha[2*i] ||
                hex[digest[i] & 15] != expected_sha[2*i+1]) return false;
    }
    flatbuffers::Verifier verifier(bytes->data(), bytes->size());
    if (!tflite::VerifyModelBuffer(verifier)) return false;
    const auto* model = tflite::GetModel(bytes->data());
    if (model->version() != 3 || !model->subgraphs() || model->subgraphs()->size() != 1 ||
            !model->operator_codes()) return false;
    const auto* graph = model->subgraphs()->Get(0);
    if (!graph->operators()) return false;
    size_t custom_nodes = 0;
    for (const auto* op : *graph->operators()) {
        if (op->opcode_index() >= model->operator_codes()->size()) return false;
        const auto* code = model->operator_codes()->Get(op->opcode_index());
        if (code->builtin_code() != tflite::BuiltinOperator_CUSTOM) continue;
        if (task != ModelTask::Segmentation || !code->custom_code() ||
                code->custom_code()->str() != kCustomOp || code->version() != 1) return false;
        const auto* options = op->custom_options();
        constexpr size_t length = offsetof(TfLiteTransposeConvParams, stride_height) + sizeof(int);
        if (!options || options->size() < length || options->size() > 64) return false;
        TfLiteTransposeConvParams params{};
        std::memcpy(&params, options->data(), length);
        if ((params.padding != kTfLitePaddingSame && params.padding != kTfLitePaddingValid) ||
                params.stride_width <= 0 || params.stride_width > 16 ||
                params.stride_height <= 0 || params.stride_height > 16) return false;
        ++custom_nodes;
    }
    return task == ModelTask::Face ? custom_nodes == 0 : custom_nodes > 0;
}
bool read_pinned_model(ModelTask task, const std::string& path, std::vector<uint8_t>* bytes) {
    const size_t expected_size = task == ModelTask::Segmentation ? 250177 : 229746;
    // Paths cross the private launch API as UTF-8. A filesystem path preserves
    // them as UTF-16 on Windows instead of using the system ANSI code page.
    std::ifstream file(std::filesystem::path(std::u8string(path.begin(), path.end())),
                       std::ios::binary | std::ios::ate);
    if (!file || file.tellg() != std::streamoff(expected_size)) return false;
    bytes->resize(expected_size);
    file.seekg(0);
    file.read(reinterpret_cast<char*>(bytes->data()), std::streamsize(expected_size));
    return file && file.gcount() == std::streamsize(expected_size) && validate_pinned_model(task, *bytes);
}
} // namespace

struct ModelRuntime::Impl {
    explicit Impl(ModelTask wanted) : task(wanted) {}
    bool initialize(const std::string& path) {
        if (!read_pinned_model(task, path, &bytes)) return false;
        return initialize_model();
    }
    bool initialize_bytes(std::vector<uint8_t> owned_bytes) {
        if (!validate_pinned_model(task, owned_bytes)) return false;
        bytes = std::move(owned_bytes);
        return initialize_model();
    }
    bool initialize_model() {
        model = tflite::FlatBufferModel::BuildFromBuffer(
            reinterpret_cast<const char*>(bytes.data()), bytes.size());
        if (!model) return false;
        if (task == ModelTask::Segmentation) {
            auto* op = mediapipe::tflite_operations::RegisterConvolution2DTransposeBias();
            if (!op || !op->prepare || !op->invoke) return false;
            resolver.AddCustom(kCustomOp, op, 1, 1);
        }
#if !defined(DINOX_VISION_ANDROID_ARMV7_TFLITE_CPU_ONLY)
        auto options = TfLiteXNNPackDelegateOptionsDefault();
        options.num_threads = 1;
        delegate.reset(TfLiteXNNPackDelegateCreate(&options));
        if (!delegate) return false;
#endif
        tflite::InterpreterBuilder builder(*model, resolver);
        if (builder.SetNumThreads(1) != kTfLiteOk) return false;
#if !defined(DINOX_VISION_ANDROID_ARMV7_TFLITE_CPU_ONLY)
        builder.AddDelegate(delegate.get());
#endif
        if (builder(&interpreter) != kTfLiteOk || !interpreter ||
                interpreter->AllocateTensors() != kTfLiteOk || !valid_tensors()) return false;
#if defined(DINOX_VISION_ANDROID_ARMV7_TFLITE_CPU_ONLY)
        // WithoutDefaultDelegates and no AddDelegate above mean genuine
        // builtin/custom CPU execution, still strictly one interpreter thread.
        return true;
#else
        for (int index : interpreter->execution_plan()) {
            const auto* node = interpreter->node_and_registration(index);
            if (node && node->first.delegate == delegate.get()) return true;
        }
        return false;
#endif
    }
    bool valid_tensors() const {
        if (interpreter->inputs().size() != 1) return false;
        if (task == ModelTask::Segmentation) {
            return interpreter->outputs().size() == 1 &&
                shape(interpreter->input_tensor(0), {1,144,256,3}) &&
                shape(interpreter->output_tensor(0), {1,144,256,1});
        }
        return interpreter->outputs().size() == 2 &&
            shape(interpreter->input_tensor(0), {1,128,128,3}) &&
            shape(interpreter->output_tensor(0), {1,896,16}) &&
            shape(interpreter->output_tensor(1), {1,896,1});
    }
    bool invoke(std::span<const uint8_t> rgb) {
        const auto expected = task == ModelTask::Segmentation ? kSegmentRgbBytes : kFaceRgbBytes;
        if (rgb.size() != expected || !valid_tensors()) return false;
        const auto input = checked_tensor_view(interpreter->typed_input_tensor<float>(0), expected);
        if (input.size() != expected) return false;
        for (size_t i = 0; i < rgb.size(); ++i) {
            input[i] = task == ModelTask::Segmentation ? rgb[i] / 255.0f :
                rgb[i] / 127.5f - 1.0f;
        }
        return interpreter->Invoke() == kTfLiteOk && valid_tensors();
    }
    ModelTask task;
    // Reverse destruction: interpreter, optional delegate, resolver, model, bytes.
    std::vector<uint8_t> bytes;
    std::unique_ptr<tflite::FlatBufferModel> model;
    tflite::ops::builtin::BuiltinOpResolverWithoutDefaultDelegates resolver;
#if !defined(DINOX_VISION_ANDROID_ARMV7_TFLITE_CPU_ONLY)
    std::unique_ptr<TfLiteDelegate, decltype(&TfLiteXNNPackDelegateDelete)> delegate{
        nullptr, &TfLiteXNNPackDelegateDelete};
#endif
    std::unique_ptr<tflite::Interpreter> interpreter;
};
ModelRuntime::ModelRuntime(std::unique_ptr<Impl> impl) : impl_(std::move(impl)) {}
ModelRuntime::~ModelRuntime() = default;
std::unique_ptr<ModelRuntime> ModelRuntime::create(ModelTask task, const std::string& path) {
    auto impl = std::make_unique<Impl>(task);
    if (!impl->initialize(path)) return nullptr;
    return std::unique_ptr<ModelRuntime>(new ModelRuntime(std::move(impl)));
}
std::unique_ptr<ModelRuntime> ModelRuntime::create_from_bytes(ModelTask task,
        std::vector<uint8_t> model_bytes) {
    auto impl = std::make_unique<Impl>(task);
    if (!impl->initialize_bytes(std::move(model_bytes))) return nullptr;
    return std::unique_ptr<ModelRuntime>(new ModelRuntime(std::move(impl)));
}
bool ModelRuntime::segment(std::span<const uint8_t> rgb, std::span<uint8_t> mask) {
    if (impl_->task != ModelTask::Segmentation || mask.size() != kMaskBytes ||
            !impl_->invoke(rgb)) return false;
    const auto output = checked_tensor_view<const float>(
        impl_->interpreter->typed_output_tensor<float>(0), kMaskBytes);
    if (output.size() != kMaskBytes) return false;
    // Validate the whole result before exposing any partial mask.
    for (size_t i = 0; i < mask.size(); ++i) {
        if (!std::isfinite(output[i]) || output[i] < 0 || output[i] > 1) return false;
    }
    for (size_t i = 0; i < mask.size(); ++i) mask[i] = uint8_t(output[i] * 255.0f + 0.5f);
    return true;
}
bool ModelRuntime::face(std::span<const uint8_t> rgb, const Face* previous,
        std::optional<Face>* output) {
    if (output) output->reset();
    if (!output || impl_->task != ModelTask::Face || !impl_->invoke(rgb)) return false;
    const auto boxes = checked_tensor_view<const float>(
        impl_->interpreter->typed_output_tensor<float>(0), 896*16);
    const auto logits = checked_tensor_view<const float>(
        impl_->interpreter->typed_output_tensor<float>(1), 896);
    if (boxes.size() != 896*16 || logits.size() != 896) return false;
    for (size_t i = 0; i < 896*16; ++i) if (!std::isfinite(boxes[i])) return false;
    for (size_t i = 0; i < 896; ++i) if (!std::isfinite(logits[i])) return false;
    *output = decode_primary_face(boxes, logits, previous);
    return true;
}
} // namespace dinox::vision

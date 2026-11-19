// TensorFlow Lite backend (built-in kernels + optional XNNPACK delegate).
#include <cstring>
#include <stdexcept>

#include "common.h"
#include "tensorflow/lite/interpreter.h"
#include "tensorflow/lite/kernels/register.h"
#include "tensorflow/lite/model.h"
#if __has_include("tensorflow/lite/delegates/xnnpack/xnnpack_delegate.h")
#include "tensorflow/lite/delegates/xnnpack/xnnpack_delegate.h"
#define EDGESIGHT_HAVE_XNNPACK 1
#endif

namespace {

class TfliteEngine : public Engine {
public:
    TfliteEngine(const std::string& path, int threads, bool xnnpack) {
        model_ = tflite::FlatBufferModel::BuildFromFile(path.c_str());
        if (!model_) throw std::runtime_error("cannot load tflite model " + path);
        tflite::ops::builtin::BuiltinOpResolverWithoutDefaultDelegates resolver;
        tflite::InterpreterBuilder(*model_, resolver)(&interp_);
        if (!interp_) throw std::runtime_error("cannot build tflite interpreter");
        interp_->SetNumThreads(threads);
#ifdef EDGESIGHT_HAVE_XNNPACK
        if (xnnpack) {
            TfLiteXNNPackDelegateOptions o = TfLiteXNNPackDelegateOptionsDefault();
            o.num_threads = threads;
#ifdef TFLITE_XNNPACK_DELEGATE_FLAG_QU8
            o.flags |= TFLITE_XNNPACK_DELEGATE_FLAG_QU8;
#endif
#ifdef TFLITE_XNNPACK_DELEGATE_FLAG_QS8
            o.flags |= TFLITE_XNNPACK_DELEGATE_FLAG_QS8;
#endif
            xnn_ = TfLiteXNNPackDelegateCreate(&o);
            if (interp_->ModifyGraphWithDelegate(xnn_) == kTfLiteOk) {
                delegate_ = "+xnnpack";
            } else {
                logf("tflite: XNNPACK delegate rejected the graph, using reference kernels");
            }
        }
#else
        (void)xnnpack;
#endif
        if (interp_->AllocateTensors() != kTfLiteOk) throw std::runtime_error("AllocateTensors failed");
        const TfLiteTensor* in = interp_->input_tensor(0);
        if (in->dims->size != 4 || in->dims->data[3] != 3) throw std::runtime_error("expected NHWC input");
        h_ = in->dims->data[1];
        w_ = in->dims->data[2];
        inType_ = in->type;
        if (interp_->outputs().size() < 4) throw std::runtime_error("expected TFLite_Detection_PostProcess outputs");
    }

    ~TfliteEngine() override {
        interp_.reset();
#ifdef EDGESIGHT_HAVE_XNNPACK
        if (xnn_) TfLiteXNNPackDelegateDelete(xnn_);
#endif
    }

    std::string name() const override { return std::string("tflite") + delegate_; }
    int inputW() const override { return w_; }
    int inputH() const override { return h_; }

    std::vector<Detection> infer(const uint8_t* rgb, float minScore) override {
        size_t n = (size_t)w_ * h_ * 3;
        if (inType_ == kTfLiteUInt8) {
            std::memcpy(interp_->typed_input_tensor<uint8_t>(0), rgb, n);
        } else {
            float* dst = interp_->typed_input_tensor<float>(0);
            for (size_t i = 0; i < n; ++i) dst[i] = (rgb[i] - 127.5f) / 127.5f;
        }
        if (interp_->Invoke() != kTfLiteOk) throw std::runtime_error("tflite Invoke failed");
        const float* boxes = interp_->typed_output_tensor<float>(0);
        const float* classes = interp_->typed_output_tensor<float>(1);
        const float* scores = interp_->typed_output_tensor<float>(2);
        int num = (int)interp_->typed_output_tensor<float>(3)[0];
        std::vector<Detection> dets;
        for (int i = 0; i < num; ++i) {
            if (scores[i] < minScore) continue;
            // PostProcess op emits 0-based class index -> COCO id = index + 1
            dets.push_back({boxes[i * 4 + 1], boxes[i * 4 + 0], boxes[i * 4 + 3], boxes[i * 4 + 2],
                            (int)classes[i] + 1, scores[i]});
        }
        return dets;
    }

private:
    std::unique_ptr<tflite::FlatBufferModel> model_;
    std::unique_ptr<tflite::Interpreter> interp_;
    TfLiteDelegate* xnn_ = nullptr;
    std::string delegate_;
    TfLiteType inType_ = kTfLiteUInt8;
    int w_ = 300, h_ = 300;
};

}  // namespace

std::unique_ptr<Engine> makeTfliteEngine(const std::string& model, int threads, bool xnnpack) {
    return std::make_unique<TfliteEngine>(model, threads, xnnpack);
}

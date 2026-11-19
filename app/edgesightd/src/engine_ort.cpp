// ONNX Runtime backend (CPU execution provider, MLAS kernels).
#include <onnxruntime_cxx_api.h>

#include <cstdlib>
#include <stdexcept>

#include "common.h"

namespace {

class OrtEngine : public Engine {
public:
    OrtEngine(const std::string& path, int threads)
        : env_(ORT_LOGGING_LEVEL_ERROR, "edgesight") {
        // The official release binary ships Microsoft 1DS telemetry: an appliance must not phone home.
        env_.DisableTelemetryEvents();
        Ort::SessionOptions so;
        so.SetIntraOpNumThreads(threads);
        so.SetInterOpNumThreads(1);
        so.SetExecutionMode(ExecutionMode::ORT_SEQUENTIAL);
        so.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_ALL);
        // Busy-wait between ops lowers latency but burns idle CPU; tunable for the ablation study.
        const char* spin = std::getenv("EDGESIGHT_ORT_SPIN");
        so.AddConfigEntry("session.intra_op.allow_spinning", (spin && spin[0] == '0') ? "0" : "1");
        session_ = Ort::Session(env_, path.c_str(), so);

        Ort::AllocatorWithDefaultOptions alloc;
        for (size_t i = 0; i < session_.GetInputCount(); ++i)
            inNames_.push_back(session_.GetInputNameAllocated(i, alloc).get());
        for (size_t i = 0; i < session_.GetOutputCount(); ++i)
            outNames_.push_back(session_.GetOutputNameAllocated(i, alloc).get());
        for (auto& s : inNames_) inPtrs_.push_back(s.c_str());
        for (auto& s : outNames_) outPtrs_.push_back(s.c_str());

        // keep the TypeInfo alive: GetTensorTypeAndShapeInfo() returns a view into it
        Ort::TypeInfo tinfo = session_.GetInputTypeInfo(0);
        auto ti = tinfo.GetTensorTypeAndShapeInfo();
        inType_ = ti.GetElementType();
        auto shape = ti.GetShape();
        std::string dims;
        for (auto d : shape) dims += std::to_string(d) + ",";
        if (shape.size() != 4 || !(shape[3] == 3 || shape[3] < 0))
            throw std::runtime_error("expected NHWC [N,H,W,3] detector input, got [" + dims + "]");
        h_ = shape[1] > 0 ? (int)shape[1] : 300;  // dynamic H/W: SSD resizes internally,
        w_ = shape[2] > 0 ? (int)shape[2] : 300;  // feed its native 300x300

        for (size_t i = 0; i < outNames_.size(); ++i) {
            const std::string& n = outNames_[i];
            if (n.find("boxes") != std::string::npos) iBoxes_ = (int)i;
            else if (n.find("classes") != std::string::npos) iClasses_ = (int)i;
            else if (n.find("scores") != std::string::npos) iScores_ = (int)i;
            else if (n.find("num") != std::string::npos) iNum_ = (int)i;
        }
        if (iBoxes_ < 0 || iClasses_ < 0 || iScores_ < 0 || iNum_ < 0)
            throw std::runtime_error("model outputs are not TF-OD style (boxes/classes/scores/num)");
        mem_ = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
        if (inType_ != ONNX_TENSOR_ELEMENT_DATA_TYPE_UINT8) fbuf_.resize((size_t)w_ * h_ * 3);
    }

    std::string name() const override { return "onnxruntime-" + std::string(Ort::GetVersionString()); }
    int inputW() const override { return w_; }
    int inputH() const override { return h_; }

    std::vector<Detection> infer(const uint8_t* rgb, float minScore) override {
        int64_t shape[4] = {1, h_, w_, 3};
        size_t n = (size_t)w_ * h_ * 3;
        Ort::Value in{nullptr};
        if (inType_ == ONNX_TENSOR_ELEMENT_DATA_TYPE_UINT8) {
            in = Ort::Value::CreateTensor<uint8_t>(mem_, const_cast<uint8_t*>(rgb), n, shape, 4);
        } else {
            for (size_t i = 0; i < n; ++i) fbuf_[i] = (rgb[i] - 127.5f) / 127.5f;
            in = Ort::Value::CreateTensor<float>(mem_, fbuf_.data(), n, shape, 4);
        }
        auto outs = session_.Run(Ort::RunOptions{nullptr}, inPtrs_.data(), &in, 1,
                                 outPtrs_.data(), outPtrs_.size());
        const float* boxes = outs[iBoxes_].GetTensorData<float>();
        const float* classes = outs[iClasses_].GetTensorData<float>();
        const float* scores = outs[iScores_].GetTensorData<float>();
        int num = (int)outs[iNum_].GetTensorData<float>()[0];
        std::vector<Detection> dets;
        for (int i = 0; i < num; ++i) {
            if (scores[i] < minScore) continue;
            // TF-OD box order: ymin, xmin, ymax, xmax
            dets.push_back({boxes[i * 4 + 1], boxes[i * 4 + 0], boxes[i * 4 + 3], boxes[i * 4 + 2],
                            (int)classes[i], scores[i]});
        }
        return dets;
    }

private:
    Ort::Env env_;
    Ort::Session session_{nullptr};
    Ort::MemoryInfo mem_{nullptr};
    std::vector<std::string> inNames_, outNames_;
    std::vector<const char*> inPtrs_, outPtrs_;
    ONNXTensorElementDataType inType_ = ONNX_TENSOR_ELEMENT_DATA_TYPE_UINT8;
    std::vector<float> fbuf_;
    int w_ = 300, h_ = 300;
    int iBoxes_ = -1, iClasses_ = -1, iScores_ = -1, iNum_ = -1;
};

}  // namespace

std::unique_ptr<Engine> makeOrtEngine(const std::string& model, int threads) {
    return std::make_unique<OrtEngine>(model, threads);
}

// Build-time offline optimisation: apply the hardware-independent graph rewrites
// (constant folding, node fusions = ORT "extended" level) once and serialise the result.
// At run time ORT then only performs the cheap, CPU-specific layout pass (NCHWc), which
// roughly halves model load time without changing inference speed. Output is deterministic.
void optimizeOrtModel(const std::string& in, const std::string& out) {
    Ort::Env env(ORT_LOGGING_LEVEL_ERROR, "edgesight-opt");
    env.DisableTelemetryEvents();
    Ort::SessionOptions so;
    so.SetIntraOpNumThreads(1);
    so.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_EXTENDED);
    so.SetOptimizedModelFilePath(out.c_str());
    Ort::Session s(env, in.c_str(), so);
}

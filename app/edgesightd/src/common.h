#pragma once
#include <chrono>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

struct Detection {
    float x0, y0, x1, y1;  // normalised [0,1] box corners
    int cls;               // COCO category id (1..90, TF/ONNX zoo convention)
    float score;
};

// Common interface implemented by the ONNX Runtime and TFLite backends.
class Engine {
public:
    virtual ~Engine() = default;
    virtual std::string name() const = 0;
    virtual int inputW() const = 0;
    virtual int inputH() const = 0;
    // rgb: inputW*inputH*3 interleaved uint8
    virtual std::vector<Detection> infer(const uint8_t* rgb, float minScore) = 0;
};

std::unique_ptr<Engine> makeOrtEngine(const std::string& model, int threads);
void optimizeOrtModel(const std::string& in, const std::string& out);
std::unique_ptr<Engine> makeTfliteEngine(const std::string& model, int threads, bool xnnpack);

const char* cocoLabel(int id);
double nowMs();          // monotonic, milliseconds
double uptimeSec();      // /proc/uptime (time since kernel start)
void logf(const char* fmt, ...) __attribute__((format(printf, 1, 2)));
std::string jsonEscape(const std::string& s);

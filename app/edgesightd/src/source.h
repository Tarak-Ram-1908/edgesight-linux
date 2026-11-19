#pragma once
#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

struct Frame {
    std::vector<uint8_t> jpeg;
    std::string origin;  // "camera" | "samples"
    uint64_t seq = 0;
};

// Frame source with automatic fail-over:
//  * a camera connected to the MJPEG-over-TCP ingest port wins
//    (e.g. `ffmpeg -f dshow -i video=... -f mjpeg tcp://edge:5000`);
//  * otherwise frames come from a directory of JPEGs, paced to `fps`.
class FrameSource {
public:
    static constexpr size_t kMaxFrameBytes = 4u << 20;   // larger "frames" are garbage
    static constexpr double kCameraStaleMs = 1500.0;    // silent camera -> back to samples

    // holdSec: keep each sample picture for this long (0 = next picture every frame)
    FrameSource(const std::string& dir, int cameraPort, double fps, double holdSec = 0);
    ~FrameSource();
    void start();                 // spawns the ingest thread (call before seccomp)
    bool next(Frame& f);          // blocks until a frame is available or stop()
    void stop();
    bool cameraConnected() const { return cameraLive(); }
    size_t sampleCount() const { return files_.size(); }
    uint64_t cameraFrames() const { return camFrames_.load(); }
    uint64_t droppedFrames() const { return droppedFrames_.load(); }

private:
    void ingestLoop();
    bool cameraLive() const;
    std::vector<std::vector<uint8_t>> files_;
    size_t idx_ = 0;
    int port_;
    double fps_;
    double holdMs_;
    double sampleSince_ = 0;
    double nextDue_ = 0;
    int listenFd_ = -1;
    std::thread th_;
    std::atomic<bool> stop_{false}, camConnected_{false};
    std::atomic<uint64_t> camFrames_{0}, droppedFrames_{0};
    std::atomic<double> lastCamFrameMs_{-1e18};
    std::mutex mu_;
    std::condition_variable cv_;
    std::vector<uint8_t> latest_;
    uint64_t latestSeq_ = 0, consumedSeq_ = 0, seq_ = 0;
};

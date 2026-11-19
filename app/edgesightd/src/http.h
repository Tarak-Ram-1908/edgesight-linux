#pragma once
#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

// Tiny dependency-free HTTP/1.0 server:
//   /             dashboard (HTML)
//   /stream.mjpg  annotated video (multipart/x-mixed-replace)
//   /metrics      JSON metrics
//   /detections   latest detections JSON
//   /healthz      200 when the pipeline is healthy, 503 otherwise
class HttpServer {
public:
    std::function<std::string()> metricsJson, detectionsJson;
    std::function<bool()> healthy;

    explicit HttpServer(int port) : port_(port) {}
    ~HttpServer();
    bool start();
    void stop();
    void publishFrame(std::vector<uint8_t> jpeg);
    int streamClients() const { return streamClients_.load(); }

private:
    void acceptLoop();
    void handle(int fd);
    int port_;
    int fd_ = -1;
    std::thread th_;
    std::atomic<bool> stop_{false};
    std::atomic<int> conns_{0}, streamClients_{0};
    std::mutex mu_;
    std::condition_variable cv_;
    std::vector<uint8_t> frame_;
    uint64_t frameSeq_ = 0;
};

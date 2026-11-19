#pragma once
#include <cstdint>
#include <deque>
#include <mutex>
#include <string>
#include <vector>

struct Summary {
    uint64_t count = 0;
    double mean = 0, p50 = 0, p90 = 0, p99 = 0, min = 0, max = 0, stdev = 0;
    std::string json() const;
};

// Sliding window (last N samples) latency statistics, thread-safe.
class LatencyStats {
public:
    explicit LatencyStats(size_t window = 2000) : window_(window) {}
    void add(double ms);
    Summary summary() const;
    void reset();

private:
    size_t window_;
    mutable std::mutex mu_;
    std::deque<double> v_;
    uint64_t total_ = 0;
};

// Frames-per-second over a sliding time window.
class RateMeter {
public:
    void tick(double nowMs);
    double rate(double nowMs) const;

private:
    mutable std::mutex mu_;
    std::deque<double> t_;
};

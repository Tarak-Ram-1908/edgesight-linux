#include "stats.h"

#include <algorithm>
#include <cmath>
#include <cstdio>

std::string Summary::json() const {
    char b[256];
    std::snprintf(b, sizeof b,
                  "{\"n\":%llu,\"mean\":%.3f,\"p50\":%.3f,\"p90\":%.3f,\"p99\":%.3f,\"min\":%.3f,\"max\":%.3f,\"stdev\":%.3f}",
                  (unsigned long long)count, mean, p50, p90, p99, min, max, stdev);
    return b;
}

void LatencyStats::add(double ms) {
    std::lock_guard<std::mutex> lk(mu_);
    v_.push_back(ms);
    if (v_.size() > window_) v_.pop_front();
    ++total_;
}

void LatencyStats::reset() {
    std::lock_guard<std::mutex> lk(mu_);
    v_.clear();
    total_ = 0;
}

Summary LatencyStats::summary() const {
    std::vector<double> s;
    Summary r;
    {
        std::lock_guard<std::mutex> lk(mu_);
        s.assign(v_.begin(), v_.end());
        r.count = total_;
    }
    if (s.empty()) return r;
    std::sort(s.begin(), s.end());
    auto pct = [&](double p) {
        double idx = p * (s.size() - 1);
        size_t lo = (size_t)idx, hi = std::min(lo + 1, s.size() - 1);
        return s[lo] + (s[hi] - s[lo]) * (idx - lo);
    };
    double sum = 0;
    for (double x : s) sum += x;
    r.mean = sum / s.size();
    double var = 0;
    for (double x : s) var += (x - r.mean) * (x - r.mean);
    r.stdev = std::sqrt(var / s.size());
    r.p50 = pct(0.50);
    r.p90 = pct(0.90);
    r.p99 = pct(0.99);
    r.min = s.front();
    r.max = s.back();
    return r;
}

void RateMeter::tick(double now) {
    std::lock_guard<std::mutex> lk(mu_);
    t_.push_back(now);
    while (!t_.empty() && now - t_.front() > 2000.0) t_.pop_front();
}

double RateMeter::rate(double now) const {
    std::lock_guard<std::mutex> lk(mu_);
    size_t n = 0;
    for (double t : t_)
        if (now - t <= 2000.0) ++n;
    return n / 2.0;
}

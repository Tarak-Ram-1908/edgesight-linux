#include "source.h"

#include <arpa/inet.h>
#include <dirent.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <iterator>

#include "common.h"

FrameSource::FrameSource(const std::string& dir, int cameraPort, double fps, double holdSec)
    : port_(cameraPort), fps_(fps), holdMs_(holdSec * 1000.0) {
    std::vector<std::string> names;
    if (!dir.empty()) {
        if (DIR* d = opendir(dir.c_str())) {
            while (dirent* e = readdir(d)) {
                std::string n = e->d_name;
                if (n.size() > 4 && (n.substr(n.size() - 4) == ".jpg" || n.substr(n.size() - 5) == ".jpeg"))
                    names.push_back(dir + "/" + n);
            }
            closedir(d);
        } else {
            logf("source: cannot open %s", dir.c_str());
        }
    }
    std::sort(names.begin(), names.end());
    for (auto& n : names) {
        std::ifstream f(n, std::ios::binary);
        files_.emplace_back(std::istreambuf_iterator<char>(f), std::istreambuf_iterator<char>());
    }
}

FrameSource::~FrameSource() {
    stop();
    if (th_.joinable()) th_.join();
    if (listenFd_ >= 0) close(listenFd_);
}

void FrameSource::start() {
    if (port_ <= 0) return;
    listenFd_ = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
    int one = 1;
    setsockopt(listenFd_, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    sockaddr_in a{};
    a.sin_family = AF_INET;
    a.sin_port = htons(port_);
    a.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(listenFd_, (sockaddr*)&a, sizeof a) < 0 || listen(listenFd_, 1) < 0) {
        logf("source: camera ingest port %d unavailable: %s", port_, strerror(errno));
        close(listenFd_);
        listenFd_ = -1;
        return;
    }
    logf("source: camera ingest listening on tcp/%d (MJPEG)", port_);
    th_ = std::thread([this] { ingestLoop(); });
}

void FrameSource::stop() {
    stop_ = true;
    cv_.notify_all();
}

// Reads a raw concatenated-JPEG byte stream and splits it on SOI (FFD8) / EOI (FFD9).
// Inside entropy-coded data 0xFF is always stuffed (FF00), so FFD9 only marks a frame end.
void FrameSource::ingestLoop() {
    std::vector<uint8_t> buf;
    buf.reserve(1 << 20);
    while (!stop_) {
        pollfd p{listenFd_, POLLIN, 0};
        if (poll(&p, 1, 500) <= 0) continue;
        int fd = accept4(listenFd_, nullptr, nullptr, SOCK_CLOEXEC);
        if (fd < 0) continue;
        timeval tv{3, 0};
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
        camConnected_ = true;
        logf("source: camera connected");
        buf.clear();
        // Incremental parser state: once SOI is found at buf[0], `scan` remembers how far we
        // already searched for EOI, so every byte is examined once (no quadratic rescans).
        bool inFrame = false;
        size_t scan = 0;
        uint8_t chunk[65536];
        while (!stop_) {
            ssize_t n = recv(fd, chunk, sizeof chunk, 0);
            if (n <= 0) break;
            buf.insert(buf.end(), chunk, chunk + n);
            for (;;) {
                if (!inFrame) {
                    size_t soi = std::string::npos;
                    for (size_t i = 0; i + 1 < buf.size(); ++i)
                        if (buf[i] == 0xFF && buf[i + 1] == 0xD8) { soi = i; break; }
                    if (soi == std::string::npos) {  // keep a trailing 0xFF that may start an SOI
                        if (buf.size() > 1) buf.erase(buf.begin(), buf.end() - 1);
                        break;
                    }
                    buf.erase(buf.begin(), buf.begin() + soi);
                    inFrame = true;
                    scan = 2;
                }
                size_t eoi = std::string::npos;
                for (; scan + 1 < buf.size(); ++scan)
                    if (buf[scan] == 0xFF && buf[scan + 1] == 0xD9) { eoi = scan + 2; break; }
                if (eoi == std::string::npos) {
                    if (buf.size() > kMaxFrameBytes) {  // runaway / garbage frame: drop it
                        buf.clear();
                        inFrame = false;
                        droppedFrames_++;
                    }
                    break;
                }
                {
                    std::lock_guard<std::mutex> lk(mu_);
                    latest_.assign(buf.begin(), buf.begin() + eoi);
                    ++latestSeq_;
                    lastCamFrameMs_ = nowMs();
                }
                camFrames_++;
                cv_.notify_one();
                buf.erase(buf.begin(), buf.begin() + eoi);
                inFrame = false;
            }
        }
        close(fd);
        camConnected_ = false;
        cv_.notify_all();
        logf("source: camera disconnected, falling back to samples");
    }
}

// The camera wins only while it is actually delivering frames. A client that connects and
// then stays silent (or trickles bytes) must not starve the pipeline: after kCameraStaleMs
// without a complete frame we fall back to the sample loop until frames flow again.
bool FrameSource::cameraLive() const {
    return camConnected_.load() && nowMs() - lastCamFrameMs_.load() < kCameraStaleMs;
}

bool FrameSource::next(Frame& f) {
    while (!stop_) {
        if (cameraLive()) {
            std::unique_lock<std::mutex> lk(mu_);
            cv_.wait_for(lk, std::chrono::milliseconds(250),
                         [&] { return stop_ || latestSeq_ != consumedSeq_ || !camConnected_; });
            if (latestSeq_ != consumedSeq_) {
                consumedSeq_ = latestSeq_;  // always process the newest frame, drop backlog
                f.jpeg = latest_;
                f.origin = "camera";
                f.seq = ++seq_;
                return true;
            }
            continue;
        }
        if (files_.empty()) {
            std::unique_lock<std::mutex> lk(mu_);
            cv_.wait_for(lk, std::chrono::milliseconds(250));
            continue;
        }
        if (fps_ > 0) {
            double now = nowMs();
            if (nextDue_ > now) {
                std::unique_lock<std::mutex> lk(mu_);
                cv_.wait_for(lk, std::chrono::microseconds((long)((nextDue_ - now) * 1000)),
                             [&] { return stop_ || latestSeq_ != consumedSeq_; });
                if (stop_ || cameraLive()) continue;
                if (nowMs() < nextDue_) continue;  // woken by a frame of a not-yet-live camera
            }
            nextDue_ = std::max(nextDue_, nowMs()) + 1000.0 / fps_;
        }
        // Sample "hold": show each picture for holdMs so a human can read the dashboard
        // (processing still runs at the full rate on the held picture).
        double now = nowMs();
        if (holdMs_ <= 0 || sampleSince_ == 0 || now - sampleSince_ >= holdMs_) {
            if (sampleSince_ != 0) idx_++;
            sampleSince_ = now;
        }
        f.jpeg = files_[idx_ % files_.size()];
        f.origin = "samples";
        f.seq = ++seq_;
        return true;
    }
    return false;
}

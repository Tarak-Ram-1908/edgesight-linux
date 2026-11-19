#pragma once
#include <atomic>
#include <string>

struct mosquitto;

// Thin wrapper around libmosquitto: async connect, background network thread,
// automatic reconnect with back-off. publish() never blocks the inference loop.
class Mqtt {
public:
    Mqtt(const std::string& host, int port, const std::string& clientId);
    ~Mqtt();
    bool start();  // spawns the libmosquitto network thread (call before seccomp)
    bool publish(const std::string& topic, const std::string& payload, bool retain = false);
    bool connected() const { return connected_.load(); }
    unsigned long published() const { return published_.load(); }

    std::atomic<bool> connected_{false};

private:
    mosquitto* m_ = nullptr;
    std::string host_;
    int port_;
    std::atomic<unsigned long> published_{0};
};

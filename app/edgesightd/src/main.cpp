// edgesightd - EdgeSight real-time object detection service.
//
//   frames (camera MJPEG/TCP or sample folder)
//     -> libjpeg-turbo decode (DCT-scaled) -> bilinear resize -> ONNX Runtime | TFLite
//     -> detections -> MQTT (edgesight/detections) + HTTP dashboard / metrics / healthz
//
// Also a benchmark tool: `edgesightd --bench 300 --model ... --runtime ...` prints JSON.
#include <signal.h>
#include <sys/resource.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iterator>
#include <memory>
#include <mutex>
#include <sstream>
#include <string>

#include "common.h"
#include "http.h"
#include "image.h"
#include "mqtt.h"
#include "sandbox.h"
#include "source.h"
#include "stats.h"

namespace {

std::atomic<bool> gStop{false};
void onSignal(int) { gStop = true; }

struct Options {
    std::string runtime = "ort";
    std::string model = "/usr/share/edgesight/models/ssd_mobilenet_v1_fp32.onnx";
    int threads = 2;
    float score = 0.5f;
    std::string sourceDir = "/usr/share/edgesight/samples";
    int cameraPort = 0;
    double fps = 0;
    int httpPort = 0;
    std::string mqttHost;
    int mqttPort = 1883;
    std::string topic = "edgesight";
    std::string selftest;
    std::string user = "edgesight";
    std::string sandbox = "off";
    bool sandboxTest = false;
    bool xnnpack = true;
    int bench = 0;
    int warmup = 20;
    double sampleHold = 0;
    std::string optimizeOut;
};

void usage() {
    std::fprintf(stderr,
                 "usage: edgesightd [options]\n"
                 "  --runtime ort|tflite     inference engine (default ort)\n"
                 "  --model PATH             .onnx or .tflite detector\n"
                 "  --threads N              intra-op threads (default 2)\n"
                 "  --score F                score threshold (default 0.5)\n"
                 "  --source dir:PATH        offline frame folder\n"
                 "  --camera-port N          MJPEG-over-TCP ingest port (0=off)\n"
                 "  --fps F                  pacing of the folder loop (0=max)\n"
                 "  --http-port N            dashboard/metrics port (0=off)\n"
                 "  --mqtt HOST:PORT         MQTT broker (empty=off)\n"
                 "  --topic T                MQTT topic prefix\n"
                 "  --selftest FILE.jpg      startup inference self-test (gates /healthz)\n"
                 "  --user NAME              drop root to this user\n"
                 "  --sandbox off|strict|trap\n"
                 "  --sandbox-test           run containment probes and exit\n"
                 "  --no-xnnpack             TFLite: reference kernels only\n"
                 "  --sample-hold SEC        show each sample picture for SEC seconds (0 = every frame)\n"
                 "  --bench N [--warmup W]   benchmark N frames, print JSON, exit\n"
                 "  --optimize-model OUT     (build time) save --model graph-optimised to OUT, exit\n");
}

bool parse(int argc, char** argv, Options& o) {
    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        auto val = [&]() -> std::string {
            if (i + 1 >= argc) { std::fprintf(stderr, "missing value for %s\n", a.c_str()); std::exit(2); }
            return argv[++i];
        };
        if (a == "--runtime") o.runtime = val();
        else if (a == "--model") o.model = val();
        else if (a == "--threads") o.threads = std::atoi(val().c_str());
        else if (a == "--score") o.score = (float)std::atof(val().c_str());
        else if (a == "--source") { o.sourceDir = val(); if (o.sourceDir.rfind("dir:", 0) == 0) o.sourceDir = o.sourceDir.substr(4); }
        else if (a == "--camera-port") o.cameraPort = std::atoi(val().c_str());
        else if (a == "--fps") o.fps = std::atof(val().c_str());
        else if (a == "--http-port") o.httpPort = std::atoi(val().c_str());
        else if (a == "--mqtt") {
            std::string v = val();
            auto c = v.rfind(':');
            o.mqttHost = v.substr(0, c);
            if (c != std::string::npos) o.mqttPort = std::atoi(v.c_str() + c + 1);
            if (o.mqttHost == ":" ) o.mqttHost.clear();
        }
        else if (a == "--topic") o.topic = val();
        else if (a == "--selftest") o.selftest = val();
        else if (a == "--user") o.user = val();
        else if (a == "--sandbox") o.sandbox = val();
        else if (a == "--sandbox-test") o.sandboxTest = true;
        else if (a == "--no-xnnpack") o.xnnpack = false;
        else if (a == "--bench") o.bench = std::atoi(val().c_str());
        else if (a == "--warmup") o.warmup = std::atoi(val().c_str());
        else if (a == "--sample-hold") o.sampleHold = std::atof(val().c_str());
        else if (a == "--optimize-model") o.optimizeOut = val();
        else if (a == "-h" || a == "--help") { usage(); std::exit(0); }
        else { std::fprintf(stderr, "unknown option %s\n", a.c_str()); usage(); return false; }
    }
    return true;
}

std::string readSmall(const char* path) {
    std::ifstream f(path);
    std::string s;
    std::getline(f, s);
    return s;
}

std::string bootSlot() {
    std::ifstream f("/proc/cmdline");
    std::string c((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
    auto p = c.find("rauc.slot=");
    return p == std::string::npos ? "-" : c.substr(p + 10, 1);
}

double rssMiB() {
    long pages = 0, resident = 0;
    if (FILE* f = std::fopen("/proc/self/statm", "r")) {
        if (std::fscanf(f, "%ld %ld", &pages, &resident) != 2) resident = 0;
        std::fclose(f);
    }
    return resident * (double)sysconf(_SC_PAGESIZE) / (1024.0 * 1024.0);
}

// System-wide memory in use (MemTotal - MemAvailable), MiB: lets the headless prod
// image report its footprint without a shell.
void sysMem(double& totalMiB, double& usedMiB) {
    long total = 0, avail = 0;
    if (FILE* f = std::fopen("/proc/meminfo", "r")) {
        char k[64];
        long v;
        while (std::fscanf(f, "%63s %ld kB\n", k, &v) == 2) {
            if (!std::strcmp(k, "MemTotal:")) total = v;
            else if (!std::strcmp(k, "MemAvailable:")) avail = v;
        }
        std::fclose(f);
    }
    totalMiB = total / 1024.0;
    usedMiB = (total - avail) / 1024.0;
}

double cpuSeconds() {
    rusage ru{};
    getrusage(RUSAGE_SELF, &ru);
    return ru.ru_utime.tv_sec + ru.ru_stime.tv_sec + (ru.ru_utime.tv_usec + ru.ru_stime.tv_usec) / 1e6;
}

double peakRssMiB() {
    rusage ru{};
    getrusage(RUSAGE_SELF, &ru);
    return ru.ru_maxrss / 1024.0;
}

std::string detectionsJson(const std::vector<Detection>& dets, uint64_t seq, const std::string& origin, double inferMs) {
    std::ostringstream o;
    o.setf(std::ios::fixed);
    o.precision(3);
    o << "{\"seq\":" << seq << ",\"source\":\"" << origin << "\",\"infer_ms\":" << inferMs << ",\"detections\":[";
    for (size_t i = 0; i < dets.size(); ++i) {
        const auto& d = dets[i];
        if (i) o << ',';
        o << "{\"label\":\"" << cocoLabel(d.cls) << "\",\"class\":" << d.cls << ",\"score\":" << d.score
          << ",\"box\":[" << d.x0 << ',' << d.y0 << ',' << d.x1 << ',' << d.y1 << "]}";
    }
    o << "]}";
    return o.str();
}

const uint8_t kPalette[6][3] = {{63, 185, 80}, {88, 166, 255}, {210, 153, 34}, {248, 81, 73}, {188, 140, 255}, {57, 197, 207}};

void annotate(Image& img, const std::vector<Detection>& dets, double fps, double inferMs, const std::string& engine) {
    int t = std::max(2, img.w / 320);
    int s = std::max(1, img.w / 400);
    for (const auto& d : dets) {
        const uint8_t* c = kPalette[d.cls % 6];
        int x0 = (int)(d.x0 * img.w), y0 = (int)(d.y0 * img.h), x1 = (int)(d.x1 * img.w), y1 = (int)(d.y1 * img.h);
        drawBox(img, x0, y0, x1, y1, c, t);
        char lbl[64];
        std::snprintf(lbl, sizeof lbl, "%s %d%%", cocoLabel(d.cls), (int)std::lround(d.score * 100));
        int ty = std::max(0, y0 - 9 * s - 2);
        fillRect(img, x0, ty, x0 + (int)std::strlen(lbl) * 6 * s + 3, ty + 9 * s, c);
        static const uint8_t black[3] = {0, 0, 0};
        drawText(img, x0 + 2, ty + s, lbl, black, s);
    }
    char hud[96];
    std::snprintf(hud, sizeof hud, "EDGESIGHT  %.1f FPS  %.1f MS  %s", fps, inferMs, engine.c_str());
    static const uint8_t bg[3] = {14, 17, 22}, fg[3] = {230, 237, 243};
    fillRect(img, 0, 0, (int)std::strlen(hud) * 6 * s + 8, 9 * s + 6, bg);
    drawText(img, 4, 3, hud, fg, s);
}

}  // namespace

int main(int argc, char** argv) {
    Options o;
    if (!parse(argc, argv, o)) return 2;
    signal(SIGPIPE, SIG_IGN);
    struct sigaction sa{};
    sa.sa_handler = onSignal;
    sigaction(SIGTERM, &sa, nullptr);
    sigaction(SIGINT, &sa, nullptr);

    const std::string version = readSmall("/etc/edgesight-version").empty() ? "dev" : readSmall("/etc/edgesight-version");
    const std::string slot = bootSlot();
    const sandbox::Mode mode = sandbox::parseMode(o.sandbox);
    logf("EdgeSight %s starting (slot %s, runtime %s, %d threads, sandbox %s)", version.c_str(), slot.c_str(),
         o.runtime.c_str(), o.threads, sandbox::modeName(mode));

    // ---- build-time helper: offline graph optimisation (runs on the build host) ----
    if (!o.optimizeOut.empty()) {
#ifdef HAVE_ORT
        try {
            optimizeOrtModel(o.model, o.optimizeOut);
            logf("optimised %s -> %s", o.model.c_str(), o.optimizeOut.c_str());
            return 0;
        } catch (const std::exception& e) {
            logf("FATAL: optimisation failed: %s", e.what());
            return 3;
        }
#else
        logf("FATAL: --optimize-model needs the ONNX Runtime backend");
        return 3;
#endif
    }

    // ---- sandbox stages 1-3: before any thread exists (Landlock is per-thread) ----
    if (mode != sandbox::Mode::Off) {
        if (!sandbox::dropPrivileges(o.user)) return 1;
        if (!sandbox::noNewPrivs()) { logf("no_new_privs failed"); return 1; }
        std::vector<std::string> ro = {"/usr", "/lib", "/etc", "/proc", "/sys"};
        if (!o.sourceDir.empty()) ro.push_back(o.sourceDir);
        sandbox::landlock(ro);
    }

    // ---- model ----
    if (access(o.model.c_str(), R_OK) != 0) {
        logf("FATAL: model %s not readable: %s", o.model.c_str(), strerror(errno));
        return 3;
    }
    std::unique_ptr<Engine> eng;
    double tl0 = nowMs();
    try {
        if (o.runtime == "ort") {
#ifdef HAVE_ORT
            eng = makeOrtEngine(o.model, o.threads);
#endif
        } else if (o.runtime == "tflite") {
#ifdef HAVE_TFLITE
            eng = makeTfliteEngine(o.model, o.threads, o.xnnpack);
#endif
        }
    } catch (const std::exception& e) {
        logf("FATAL: cannot load model: %s", e.what());
        return 3;
    }
    if (!eng) {
        logf("FATAL: runtime '%s' not compiled in", o.runtime.c_str());
        return 3;
    }
    const double loadMs = nowMs() - tl0;
    const int W = eng->inputW(), H = eng->inputH();
    logf("engine %s loaded %s in %.0f ms (input %dx%d)", eng->name().c_str(), o.model.c_str(), loadMs, W, H);

    // ---- self-test inference gates /healthz ----
    bool selftestOk = o.selftest.empty();
    if (!o.selftest.empty()) {
        std::ifstream f(o.selftest, std::ios::binary);
        std::vector<uint8_t> j((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
        Image im;
        std::vector<uint8_t> rs;
        if (!j.empty() && decodeJpeg(j.data(), j.size(), im, W, H)) {
            resizeBilinear(im, W, H, rs);
            auto d = eng->infer(rs.data(), o.score);
            selftestOk = !d.empty();
            logf("self-test on %s: %zu objects (%s%s)", o.selftest.c_str(), d.size(),
                 d.empty() ? "none" : cocoLabel(d[0].cls), d.size() > 1 ? ", ..." : "");
        }
        if (!selftestOk) {
            logf("FATAL: self-test inference failed");
            return 4;
        }
    }

    // ---- I/O threads ----
    FrameSource src(o.sourceDir, o.bench ? 0 : o.cameraPort, o.bench ? 0 : o.fps, o.bench ? 0 : o.sampleHold);
    src.start();
    std::unique_ptr<HttpServer> http;
    std::unique_ptr<Mqtt> mqtt;
    if (!o.bench && o.httpPort > 0) {
        http = std::make_unique<HttpServer>(o.httpPort);
        if (!http->start()) http.reset();
    }
    if (!o.bench && !o.mqttHost.empty()) {
        mqtt = std::make_unique<Mqtt>(o.mqttHost, o.mqttPort, "edgesightd");
        if (!mqtt->start()) mqtt.reset();
    }

    // ---- sandbox stage 4: seccomp on every thread (TSYNC) ----
    if (mode != sandbox::Mode::Off && !sandbox::seccomp(mode)) return 1;
    if (o.sandboxTest) return sandbox::selfTest();

    LatencyStats sDecode, sPre, sInfer, sPost, sTotal, sRender;
    // Corrupt input frames are counted and skipped (never fatal: they come from the network);
    // only an engine that keeps failing on valid input stops the process (init respawns it).
    std::atomic<uint64_t> errors{0};
    int inferFailStreak = 0;
    RateMeter rate;
    std::atomic<uint64_t> frames{0};
    std::atomic<double> lastTick{nowMs()};
    std::mutex detMu;
    std::string lastDets = "{\"detections\":[]}";
    const double readyUptime = uptimeSec();
    const std::string engineName = eng->name();

    auto healthy = [&] { return selftestOk && (nowMs() - lastTick.load() < 5000.0 || src.sampleCount() == 0); };
    auto metrics = [&]() {
        std::ostringstream m;
        m.setf(std::ios::fixed);
        m.precision(3);
        double now = nowMs();
        double memTotal = 0, memUsed = 0;
        sysMem(memTotal, memUsed);
        m << "{\"sys_mem_total_mib\":" << memTotal << ",\"sys_mem_used_mib\":" << memUsed << ",\"version\":\"" << jsonEscape(version) << "\",\"slot\":\"" << slot << "\",\"engine\":\"" << engineName
          << "\",\"model\":\"" << jsonEscape(o.model) << "\",\"threads\":" << o.threads
          << ",\"healthy\":" << (healthy() ? "true" : "false") << ",\"frames\":" << frames.load()
          << ",\"fps\":" << rate.rate(now) << ",\"camera_connected\":" << (src.cameraConnected() ? "true" : "false")
          << ",\"camera_frames\":" << src.cameraFrames() << ",\"camera_dropped\":" << src.droppedFrames()
          << ",\"decode_errors\":" << errors << ",\"latency_ms\":{\"decode\":" << sDecode.summary().json()
          << ",\"preprocess\":" << sPre.summary().json() << ",\"infer\":" << sInfer.summary().json()
          << ",\"postprocess\":" << sPost.summary().json() << ",\"total\":" << sTotal.summary().json()
          << ",\"render\":" << sRender.summary().json() << "},\"rss_mib\":" << rssMiB() << ",\"cpu_s\":" << cpuSeconds()
          << ",\"model_load_ms\":" << loadMs << ",\"mqtt_connected\":" << (mqtt && mqtt->connected() ? "true" : "false")
          << ",\"mqtt_published\":" << (mqtt ? mqtt->published() : 0) << ",\"sandbox\":\"" << sandbox::modeName(mode)
          << "\",\"uptime_s\":" << uptimeSec() << ",\"ready_uptime_s\":" << readyUptime << "}";
        return m.str();
    };
    if (http) {
        http->healthy = healthy;
        http->metricsJson = metrics;
        http->detectionsJson = [&] { std::lock_guard<std::mutex> lk(detMu); return lastDets; };
    }

    // Boot-time marker parsed by tests/bench (kernel uptime when the service became ready)
    std::fprintf(stderr, "EDGESIGHT_READY uptime=%.3f engine=%s load_ms=%.0f\n", readyUptime, engineName.c_str(), loadMs);
    fflush(stderr);

    Frame f;
    Image dec;
    std::vector<uint8_t> rs;
    double lastMetricsPub = 0;
    uint64_t totalDets = 0;
    const int target = o.bench > 0 ? o.bench + o.warmup : -1;
    double benchStart = 0, cpuStart = 0;
    int processed = 0;

    while (!gStop && src.next(f)) {
        if (o.bench && processed == o.warmup) {
            sDecode.reset(); sPre.reset(); sInfer.reset(); sPost.reset(); sTotal.reset();
            totalDets = 0;
            benchStart = nowMs();
            cpuStart = cpuSeconds();
        }
        double t0 = nowMs();
        if (!decodeJpeg(f.jpeg.data(), f.jpeg.size(), dec, W, H)) {
            if (errors++ % 100 == 0) logf("dropping undecodable %s frame (%llu so far)", f.origin.c_str(),
                                          (unsigned long long)errors.load());
            continue;
        }
        double t1 = nowMs();
        resizeBilinear(dec, W, H, rs);
        double t2 = nowMs();
        std::vector<Detection> dets;
        try {
            dets = eng->infer(rs.data(), o.score);
            inferFailStreak = 0;
        } catch (const std::exception& e) {
            logf("inference error: %s", e.what());
            if (++inferFailStreak > 50) return 5;
            continue;
        }
        double t3 = nowMs();
        std::string dj = detectionsJson(dets, f.seq, f.origin, t3 - t2);
        {
            std::lock_guard<std::mutex> lk(detMu);
            lastDets = dj;
        }
        double t4 = nowMs();
        sDecode.add(t1 - t0); sPre.add(t2 - t1); sInfer.add(t3 - t2); sPost.add(t4 - t3); sTotal.add(t4 - t0);
        rate.tick(t4);
        lastTick = t4;
        frames++;
        totalDets += dets.size();
        ++processed;

        if (mqtt) {
            mqtt->publish(o.topic + "/detections", dj);
            if (t4 - lastMetricsPub > 5000) {
                mqtt->publish(o.topic + "/metrics", metrics(), true);
                lastMetricsPub = t4;
            }
        }
        if (http && http->streamClients() > 0) {
            double r0 = nowMs();
            annotate(dec, dets, rate.rate(r0), t3 - t2, engineName);
            std::vector<uint8_t> out;
            if (encodeJpeg(dec, 75, out)) http->publishFrame(std::move(out));
            sRender.add(nowMs() - r0);
        }
        if (target > 0 && processed >= target) break;
    }

    if (o.bench) {
        double wall = (nowMs() - benchStart) / 1000.0;
        double cpu = cpuSeconds() - cpuStart;
        int n = processed - o.warmup;
        std::printf("{\"engine\":\"%s\",\"runtime\":\"%s\",\"model\":\"%s\",\"threads\":%d,\"frames\":%d,"
                    "\"wall_s\":%.3f,\"fps\":%.2f,\"cpu_s\":%.3f,\"cpu_ms_per_frame\":%.2f,\"model_load_ms\":%.1f,"
                    "\"peak_rss_mib\":%.1f,\"dets_per_frame\":%.2f,\"latency_ms\":{\"decode\":%s,\"preprocess\":%s,"
                    "\"infer\":%s,\"postprocess\":%s,\"total\":%s}}\n",
                    engineName.c_str(), o.runtime.c_str(), o.model.c_str(), o.threads, n, wall, n / wall, cpu,
                    1000.0 * cpu / n, loadMs, peakRssMiB(), (double)totalDets / n, sDecode.summary().json().c_str(),
                    sPre.summary().json().c_str(), sInfer.summary().json().c_str(), sPost.summary().json().c_str(),
                    sTotal.summary().json().c_str());
        std::fflush(stdout);
    }
    src.stop();
    if (http) http->stop();
    logf("shutting down after %llu frames", (unsigned long long)frames.load());
    return 0;
}

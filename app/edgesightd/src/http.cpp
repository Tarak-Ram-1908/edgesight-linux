#include "http.h"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>

#include <chrono>
#include <cstring>

#include "common.h"

namespace {

const char* kDashboard = R"HTML(<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>EdgeSight</title>
<style>
:root{--bg:#0e1116;--card:#161b22;--fg:#e6edf3;--mut:#8b949e;--acc:#3fb950;--warn:#d29922;--bad:#f85149;--line:#30363d}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.45 system-ui,-apple-system,Segoe UI,Roboto,sans-serif}
header{display:flex;align-items:center;gap:12px;padding:14px 20px;border-bottom:1px solid var(--line)}
header b{font-size:17px}.pill{padding:2px 10px;border-radius:99px;font-size:12px;border:1px solid var(--line);color:var(--mut)}
.ok{color:var(--acc);border-color:var(--acc)}.bad{color:var(--bad);border-color:var(--bad)}
main{display:grid;grid-template-columns:minmax(0,1fr) 340px;gap:16px;padding:16px 20px;max-width:1280px;margin:auto}
@media(max-width:860px){main{grid-template-columns:1fr}}
.card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:14px}
img{width:100%;border-radius:8px;background:#000;display:block}
.kpis{display:grid;grid-template-columns:repeat(2,1fr);gap:10px}.kpi .v{font-size:24px;font-weight:600;font-variant-numeric:tabular-nums}
.kpi .l{color:var(--mut);font-size:12px}h3{margin:14px 0 8px;font-size:13px;color:var(--mut);font-weight:600;text-transform:uppercase;letter-spacing:.04em}
table{width:100%;border-collapse:collapse;font-variant-numeric:tabular-nums}td{padding:3px 0;border-bottom:1px solid var(--line)}td:last-child{text-align:right}
.bar{height:6px;background:var(--line);border-radius:3px;overflow:hidden}.bar i{display:block;height:100%;background:var(--acc)}
small{color:var(--mut)}
</style></head><body>
<header><b>EdgeSight</b><span class="pill" id="health">...</span><span class="pill" id="src">...</span><span class="pill" id="rt">...</span><span style="flex:1"></span><small id="ver"></small></header>
<main>
<div class="card"><img src="/stream.mjpg" alt="annotated stream"><h3>Detections (latest frame)</h3><table id="dets"></table></div>
<div>
<div class="card"><div class="kpis">
<div class="kpi"><div class="v" id="fps">-</div><div class="l">frames / s</div></div>
<div class="kpi"><div class="v" id="p50">-</div><div class="l">inference p50 (ms)</div></div>
<div class="kpi"><div class="v" id="p99">-</div><div class="l">inference p99 (ms)</div></div>
<div class="kpi"><div class="v" id="e2e">-</div><div class="l">end-to-end p50 (ms)</div></div>
<div class="kpi"><div class="v" id="rss">-</div><div class="l">resident memory (MiB)</div></div>
<div class="kpi"><div class="v" id="frames">-</div><div class="l">frames processed</div></div>
</div>
<h3>Pipeline breakdown (mean ms)</h3><table id="stages"></table>
<h3>System</h3><table id="sys"></table></div></div>
</main>
<script>
const $=id=>document.getElementById(id);
async function tick(){
 try{
  const m=await (await fetch('/metrics',{cache:'no-store'})).json();
  $('health').textContent=m.healthy?'healthy':'unhealthy';$('health').className='pill '+(m.healthy?'ok':'bad');
  $('src').textContent=m.camera_connected?'camera':'sample loop';$('rt').textContent=m.engine;
  $('ver').textContent='v'+m.version+' · slot '+m.slot;
  $('fps').textContent=m.fps.toFixed(1);$('p50').textContent=m.latency_ms.infer.p50.toFixed(1);
  $('p99').textContent=m.latency_ms.infer.p99.toFixed(1);$('e2e').textContent=m.latency_ms.total.p50.toFixed(1);
  $('rss').textContent=m.rss_mib.toFixed(0);$('frames').textContent=m.frames;
  const st=['decode','preprocess','infer','postprocess'];const tot=st.reduce((a,k)=>a+m.latency_ms[k].mean,0)||1;
  $('stages').innerHTML=st.map(k=>`<tr><td>${k}<div class="bar"><i style="width:${(100*m.latency_ms[k].mean/tot).toFixed(1)}%"></i></div></td><td>${m.latency_ms[k].mean.toFixed(2)}</td></tr>`).join('');
  $('sys').innerHTML=[['model',m.model.split('/').pop()],['threads',m.threads],['sandbox',m.sandbox],['MQTT',m.mqtt_connected?'connected':'down'],['uptime (s)',m.uptime_s.toFixed(0)],['ready after boot (s)',m.ready_uptime_s.toFixed(2)]].map(r=>`<tr><td>${r[0]}</td><td>${r[1]}</td></tr>`).join('');
  const d=await (await fetch('/detections',{cache:'no-store'})).json();
  $('dets').innerHTML=d.detections.length?d.detections.map(x=>`<tr><td>${x.label}</td><td>${(100*x.score).toFixed(0)}%</td></tr>`).join(''):'<tr><td><small>nothing above threshold</small></td><td></td></tr>';
 }catch(e){$('health').textContent='offline';$('health').className='pill bad'}
}
setInterval(tick,1000);tick();
</script></body></html>
)HTML";

bool sendAll(int fd, const void* p, size_t n) {
    const char* c = static_cast<const char*>(p);
    while (n) {
        ssize_t w = send(fd, c, n, MSG_NOSIGNAL);
        if (w <= 0) return false;
        c += w;
        n -= (size_t)w;
    }
    return true;
}

bool sendResp(int fd, int code, const char* type, const std::string& body) {
    char h[256];
    const char* msg = code == 200 ? "OK" : code == 400 ? "Bad Request" : code == 404 ? "Not Found"
                    : code == 405 ? "Method Not Allowed" : code == 503 ? "Service Unavailable" : "Error";
    int n = std::snprintf(h, sizeof h,
                          "HTTP/1.0 %d %s\r\nContent-Type: %s\r\nContent-Length: %zu\r\nCache-Control: no-store\r\n"
                          "X-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n",
                          code, msg, type, body.size());
    return sendAll(fd, h, n) && sendAll(fd, body.data(), body.size());
}

}  // namespace

HttpServer::~HttpServer() {
    stop();
    if (th_.joinable()) th_.join();
    if (fd_ >= 0) close(fd_);
}

bool HttpServer::start() {
    fd_ = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
    int one = 1;
    setsockopt(fd_, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    sockaddr_in a{};
    a.sin_family = AF_INET;
    a.sin_port = htons(port_);
    a.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(fd_, (sockaddr*)&a, sizeof a) < 0 || listen(fd_, 16) < 0) {
        logf("http: cannot listen on %d: %s", port_, strerror(errno));
        return false;
    }
    th_ = std::thread([this] { acceptLoop(); });
    logf("http: dashboard on :%d", port_);
    return true;
}

void HttpServer::stop() {
    stop_ = true;
    cv_.notify_all();
}

void HttpServer::publishFrame(std::vector<uint8_t> jpeg) {
    {
        std::lock_guard<std::mutex> lk(mu_);
        frame_ = std::move(jpeg);
        ++frameSeq_;
    }
    cv_.notify_all();
}

void HttpServer::acceptLoop() {
    while (!stop_) {
        pollfd p{fd_, POLLIN, 0};
        if (poll(&p, 1, 500) <= 0) continue;
        int c = accept4(fd_, nullptr, nullptr, SOCK_CLOEXEC);
        if (c < 0) continue;
        if (conns_.load() >= 12) {  // bounded concurrency: cheap DoS resistance (+ cgroup pids.max)
            sendResp(c, 503, "text/plain", "busy\n");
            close(c);
            continue;
        }
        timeval tv{5, 0};
        setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
        setsockopt(c, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
        conns_++;
        std::thread([this, c] {
            handle(c);
            close(c);
            conns_--;
        }).detach();
    }
}

// A request must start "METHOD /path": uppercase token, one space, then '/' or a letter.
// Anything else is rejected after the first bytes instead of holding a worker thread
// until the receive timeout (cheap protection against junk / slow-drip connections).
static bool plausibleRequest(const char* r, size_t n) {
    size_t i = 0;
    while (i < n && i < 8 && r[i] >= 'A' && r[i] <= 'Z') ++i;
    if (i == n) return true;                 // still reading the method token
    if (i == 0 || i > 7 || r[i] != ' ') return false;
    return i + 1 >= n || r[i + 1] == '/' || (r[i + 1] >= 'a' && r[i + 1] <= 'z');
}

void HttpServer::handle(int fd) {
    timeval tv{2, 0};  // whole header must arrive within 2 s
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    char req[2048];
    size_t got = 0;
    while (got < sizeof req - 1) {
        ssize_t n = recv(fd, req + got, sizeof req - 1 - got, 0);
        if (n <= 0) return;
        got += (size_t)n;
        req[got] = 0;
        if (!plausibleRequest(req, got)) {
            sendResp(fd, 400, "text/plain", "bad request\n");
            return;
        }
        if (std::strstr(req, "\r\n\r\n") || std::strstr(req, "\n\n")) break;
    }
    char method[8] = {0}, path[256] = {0};
    if (std::sscanf(req, "%7s %255s", method, path) != 2) {
        sendResp(fd, 400, "text/plain", "bad request\n");
        return;
    }
    if (std::strcmp(method, "GET") != 0) {
        sendResp(fd, 405, "text/plain", "method not allowed\n");
        return;
    }
    std::string p(path);
    if (auto q = p.find('?'); q != std::string::npos) p.resize(q);

    if (p == "/" || p == "/index.html") {
        sendResp(fd, 200, "text/html; charset=utf-8", kDashboard);
    } else if (p == "/metrics") {
        sendResp(fd, 200, "application/json", metricsJson ? metricsJson() : "{}");
    } else if (p == "/detections") {
        sendResp(fd, 200, "application/json", detectionsJson ? detectionsJson() : "{}");
    } else if (p == "/healthz") {
        bool ok = healthy && healthy();
        sendResp(fd, ok ? 200 : 503, "text/plain", ok ? "ok\n" : "unhealthy\n");
    } else if (p == "/stream.mjpg") {
        const char* h =
            "HTTP/1.0 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=edgesightframe\r\n"
            "Cache-Control: no-store\r\nConnection: close\r\n\r\n";
        if (!sendAll(fd, h, std::strlen(h))) return;
        streamClients_++;
        uint64_t seen = 0;
        while (!stop_) {
            std::vector<uint8_t> f;
            {
                std::unique_lock<std::mutex> lk(mu_);
                cv_.wait_for(lk, std::chrono::seconds(2), [&] { return stop_ || frameSeq_ != seen; });
                if (frameSeq_ == seen) continue;
                seen = frameSeq_;
                f = frame_;
            }
            char ph[128];
            int n = std::snprintf(ph, sizeof ph, "--edgesightframe\r\nContent-Type: image/jpeg\r\nContent-Length: %zu\r\n\r\n", f.size());
            if (!sendAll(fd, ph, n) || !sendAll(fd, f.data(), f.size()) || !sendAll(fd, "\r\n", 2)) break;
        }
        streamClients_--;
    } else {
        sendResp(fd, 404, "text/plain", "not found\n");
    }
}

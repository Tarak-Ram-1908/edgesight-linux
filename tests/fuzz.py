#!/usr/bin/env python3
"""Hostile-input robustness test for edgesightd's two network-facing parsers.

  camera ingest (MJPEG over TCP) : garbage, bit-flipped / truncated JPEGs, absurd dimensions,
                                   runaway frames without EOI, silent and trickling clients
  HTTP server                    : garbage, oversized requests, bad methods, connection floods,
                                   slowloris, many concurrent MJPEG viewers

After every phase the service must answer /healthz and keep processing frames.
Usage: fuzz.py <sample-dir-with-jpgs> [http_port] [camera_port]
Exit status = number of failed phases.
"""
import glob
import io
import json
import os
import random
import socket
import struct
import sys
import threading
import time
import urllib.request

SAMPLES = sys.argv[1]
HTTP = int(sys.argv[2]) if len(sys.argv) > 2 else 8080
CAM = int(sys.argv[3]) if len(sys.argv) > 3 else 5000
rnd = random.Random(1234)  # deterministic fuzzing
jpegs = [open(p, "rb").read() for p in sorted(glob.glob(os.path.join(SAMPLES, "*.jpg")))]
failures = 0


def metrics():
    with urllib.request.urlopen(f"http://127.0.0.1:{HTTP}/metrics", timeout=5) as r:
        return json.load(r)


def healthy():
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{HTTP}/healthz", timeout=5) as r:
            return r.status == 200
    except Exception:
        return False


def cam_send(chunks, delay=0.0, linger=0.3):
    s = socket.create_connection(("127.0.0.1", CAM), timeout=10)
    try:
        for c in chunks:
            s.sendall(c)
            if delay:
                time.sleep(delay)
        time.sleep(linger)
    except OSError:
        pass  # the device may legitimately drop us
    finally:
        s.close()


def flip(b, n):
    b = bytearray(b)
    for _ in range(n):
        i = rnd.randrange(2, len(b))
        b[i] ^= 1 << rnd.randrange(8)
    return bytes(b)


def huge_dims(b, w, h):
    """Patch the SOF0/SOF2 frame header of a JPEG to claim w x h pixels."""
    b = bytearray(b)
    i = 2
    while i < len(b) - 9:
        if b[i] == 0xFF and b[i + 1] in (0xC0, 0xC1, 0xC2):
            struct.pack_into(">HH", b, i + 5, h, w)
            return bytes(b)
        i += 1
    return bytes(b)


def phase(name, fn, expect_progress=True):
    global failures
    before = metrics()["frames"]
    t0 = time.time()
    try:
        fn()
        err = None
    except Exception as e:  # harness errors count as failures too
        err = e
    time.sleep(2.5)
    ok = healthy()
    m = metrics()
    progressed = m["frames"] > before
    good = ok and (progressed or not expect_progress) and err is None
    if not good:
        failures += 1
    print(f"  {'PASS' if good else 'FAIL'}  {name:<46} {time.time() - t0:5.1f}s  healthy={ok} "
          f"frames+{m['frames'] - before} dropped={m.get('camera_dropped')} decode_err={m.get('decode_errors')}"
          + (f"  error={err}" if err else ""))


# ---------------------------------------------------------------- camera ingest
print("== camera ingest ==")
phase("valid MJPEG stream (baseline)", lambda: cam_send([jpegs[i % len(jpegs)] for i in range(60)], delay=0.03))
phase("1 MiB of random bytes", lambda: cam_send([bytes(rnd.randrange(256) for _ in range(1 << 20))]))
phase("200 bit-flipped JPEGs", lambda: cam_send([flip(jpegs[i % len(jpegs)], 1 + i % 40) for i in range(200)], delay=0.005))
phase("200 truncated JPEGs (+EOI)", lambda: cam_send([j[: rnd.randrange(4, len(j))] + b"\xff\xd9" for j in (jpegs * 25)], delay=0.005))
phase("JPEG claiming 60000x60000 px", lambda: cam_send([huge_dims(jpegs[0], 60000, 60000)] * 20, delay=0.05))
phase("JPEG claiming 4096x4096 px (allowed size)", lambda: cam_send([huge_dims(jpegs[0], 4096, 4096)] * 5, delay=0.2))
phase("8 MiB frame without EOI (runaway)", lambda: cam_send([b"\xff\xd8" + bytes(rnd.randrange(256) for _ in range(1 << 20)).replace(b"\xff\xd9", b"\x00\x00")] * 8))
phase("empty frames (SOI EOI) x1000", lambda: cam_send([b"\xff\xd8\xff\xd9" * 1000]))
phase("silent client for 6 s (must not starve)", lambda: cam_send([], linger=6.0))
phase("trickle 1 byte / 0.5 s for 6 s", lambda: cam_send([b"\xff"] * 12, delay=0.5))
phase("valid stream again (recovery)", lambda: cam_send([jpegs[i % len(jpegs)] for i in range(60)], delay=0.03))


# ---------------------------------------------------------------- HTTP
def raw_http(payload, read=True):
    s = socket.create_connection(("127.0.0.1", HTTP), timeout=5)
    try:
        s.sendall(payload)
        if read:
            s.recv(65536)
    except OSError:
        pass
    finally:
        s.close()


def flood(n, payload):
    ts = [threading.Thread(target=raw_http, args=(payload,)) for _ in range(n)]
    [t.start() for t in ts]
    [t.join() for t in ts]


def slowloris(n, secs):
    socks = []
    for _ in range(n):
        try:
            s = socket.create_connection(("127.0.0.1", HTTP), timeout=5)
            s.sendall(b"GET / HTTP/1.1\r\nHost: x\r\n")
            socks.append(s)
        except OSError:
            pass
    time.sleep(secs)
    for s in socks:
        s.close()


def viewers(n, secs):
    def view():
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{HTTP}/stream.mjpg", timeout=10) as r:
                end = time.time() + secs
                while time.time() < end:
                    r.read(65536)
        except Exception:
            pass
    ts = [threading.Thread(target=view) for _ in range(n)]
    [t.start() for t in ts]
    [t.join() for t in ts]


print("== HTTP server ==")
phase("random garbage x200", lambda: [raw_http(bytes(rnd.randrange(256) for _ in range(rnd.randrange(1, 4096)))) for _ in range(200)])
phase("16 KiB request line", lambda: raw_http(b"GET /" + b"A" * 16384 + b" HTTP/1.0\r\n\r\n"))
phase("non-GET methods / path tricks", lambda: [raw_http(p) for p in (b"POST / HTTP/1.0\r\n\r\n", b"DELETE /healthz HTTP/1.0\r\n\r\n",
                                                                     b"GET ../../etc/passwd HTTP/1.0\r\n\r\n", b"GET %s%s%n HTTP/1.0\r\n\r\n",
                                                                     b"\r\n\r\n", b"GET\r\n\r\n")])
phase("flood: 300 concurrent /metrics", lambda: flood(300, b"GET /metrics HTTP/1.0\r\n\r\n"))
phase("slowloris: 40 half-open requests, 8 s", lambda: slowloris(40, 8))
phase("10 MJPEG viewers for 6 s", lambda: viewers(10, 6))

print(f"fuzz: {failures} phase(s) failed")
sys.exit(failures)

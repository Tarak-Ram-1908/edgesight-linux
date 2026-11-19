#!/usr/bin/env python3
"""The "stock distro" way to deploy the same detector: Python + pip onnxruntime + Pillow + NumPy.

Same models, same frames, same pre/post-processing steps and the same JSON schema as
`edgesightd --bench`, so the numbers are directly comparable.
"""
import argparse
import glob
import io
import json
import os
import resource
import statistics
import time

import numpy as np
import onnxruntime as ort
from PIL import Image


def summary(xs):
    s = sorted(xs)

    def pct(p):
        i = p * (len(s) - 1)
        lo = int(i)
        hi = min(lo + 1, len(s) - 1)
        return s[lo] + (s[hi] - s[lo]) * (i - lo)

    return {"n": len(s), "mean": statistics.fmean(s), "p50": pct(0.5), "p90": pct(0.9), "p99": pct(0.99),
            "min": s[0], "max": s[-1], "stdev": statistics.pstdev(s)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--samples", required=True)
    ap.add_argument("--threads", type=int, default=2)
    ap.add_argument("--bench", type=int, default=300)
    ap.add_argument("--warmup", type=int, default=30)
    ap.add_argument("--score", type=float, default=0.5)
    a = ap.parse_args()

    t0 = time.perf_counter()
    so = ort.SessionOptions()
    so.intra_op_num_threads = a.threads
    so.inter_op_num_threads = 1
    so.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
    sess = ort.InferenceSession(a.model, so, providers=["CPUExecutionProvider"])
    load_ms = (time.perf_counter() - t0) * 1000
    inp = sess.get_inputs()[0].name
    outs = [o.name for o in sess.get_outputs()]
    ib = next(i for i, n in enumerate(outs) if "boxes" in n)
    isc = next(i for i, n in enumerate(outs) if "scores" in n)
    inum = next(i for i, n in enumerate(outs) if "num" in n)

    frames = [open(f, "rb").read() for f in sorted(glob.glob(os.path.join(a.samples, "*.jpg")))]
    dec, pre, inf, post, tot = [], [], [], [], []
    dets_total = 0
    cpu0 = wall0 = None
    for k in range(a.warmup + a.bench):
        if k == a.warmup:
            dec, pre, inf, post, tot, dets_total = [], [], [], [], [], 0
            wall0 = time.perf_counter()
            r = resource.getrusage(resource.RUSAGE_SELF)
            cpu0 = r.ru_utime + r.ru_stime
        b = frames[k % len(frames)]
        t0 = time.perf_counter()
        im = Image.open(io.BytesIO(b)).convert("RGB")
        im.load()
        t1 = time.perf_counter()
        x = np.asarray(im.resize((300, 300), Image.BILINEAR), dtype=np.uint8)[None, ...]
        t2 = time.perf_counter()
        o = sess.run(None, {inp: x})
        t3 = time.perf_counter()
        n = int(o[inum][0])
        scores = o[isc][0][:n]
        dets = [{"box": o[ib][0][i].tolist(), "score": float(scores[i])} for i in range(n) if scores[i] >= a.score]
        json.dumps(dets)
        t4 = time.perf_counter()
        dets_total += len(dets)
        dec.append((t1 - t0) * 1e3); pre.append((t2 - t1) * 1e3); inf.append((t3 - t2) * 1e3)
        post.append((t4 - t3) * 1e3); tot.append((t4 - t0) * 1e3)
    wall = time.perf_counter() - wall0
    r = resource.getrusage(resource.RUSAGE_SELF)
    cpu = r.ru_utime + r.ru_stime - cpu0
    print(json.dumps({
        "engine": "python-onnxruntime-" + ort.__version__, "runtime": "python-ort", "model": a.model,
        "threads": a.threads, "frames": a.bench, "wall_s": wall, "fps": a.bench / wall, "cpu_s": cpu,
        "cpu_ms_per_frame": 1000 * cpu / a.bench, "model_load_ms": load_ms,
        "peak_rss_mib": r.ru_maxrss / 1024, "dets_per_frame": dets_total / a.bench,
        "latency_ms": {"decode": summary(dec), "preprocess": summary(pre), "infer": summary(inf),
                       "postprocess": summary(post), "total": summary(tot)}}))


if __name__ == "__main__":
    main()

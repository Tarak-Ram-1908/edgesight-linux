# EdgeSight Linux

An application-specific Linux distribution for **real-time object detection at the edge**
(Track A, ML inference). One command builds a bootable, verified, self-updating x86-64
image that starts a sandboxed ONNX Runtime / TensorFlow Lite detection service, streams
annotated video to a browser dashboard and publishes detections over MQTT.

```
   camera (MJPEG/TCP) ─┐                      ┌─► MQTT  edgesight/detections, /metrics
   sample frames ──────┴► edgesightd ─────────┼─► HTTP  dashboard · /stream.mjpg · /metrics · /healthz
        libjpeg-turbo → resize → ORT|TFLite   └─► RAUC health gate (A/B slot confirmation)
   ───────────────────────────────────────────────────────────────────────────────
   BusyBox init · cgroup v2 · Landlock · seccomp · nftables      (read-only, dm-verity root)
   Linux 6.12 LTS, tinyconfig + 7 fragments, no modules, no initramfs
   GRUB2 EFI (A/B boot counting) · OVMF / any UEFI x86-64-v3 machine
```

| | |
|---|---|
| Build system | Buildroot 2026.02.3 LTS + `BR2_EXTERNAL` tree (`br2-external/`) |
| Kernel | 6.12.47 LTS, `tinyconfig` base + per-concern fragments (`br2-external/board/edgesight/linux/`) |
| Toolchain | Bootlin x86-64-v3 glibc stable (GCC 14) |
| ML runtimes | ONNX Runtime 1.32.0 (CPU/MLAS), TensorFlow Lite 2.11 (+XNNPACK) |
| Models | SSD-MobileNet-v1 COCO: ONNX FP32, ONNX INT8, TFLite uint8 (all Apache-2.0) |
| Security | dm-verity root, signed RAUC A/B updates + rollback, Landlock, seccomp-bpf, no modules, lockdown, nftables |

## Quick start (Windows 11 + WSL2 Ubuntu 24.04, or any Linux x86-64 host)

```bash
sudo apt-get install -y build-essential cpio unzip rsync bc file wget cmake ninja-build pkg-config \
    libncurses-dev libssl-dev python3-venv qemu-system-x86 qemu-utils ovmf squashfs-tools \
    cryptsetup-bin dosfstools mtools mosquitto-clients ffmpeg jq
sudo usermod -aG kvm $USER          # then restart the WSL session
```

```bash
./build.sh prod          # ~1 h first time (downloads + compiles), minutes afterwards
```

```bash
./run-qemu.sh prod       # serial console in the terminal, Ctrl-A X to quit
```

From **Windows PowerShell / cmd**, use the wrappers, which run the same scripts inside WSL
(typing `./run-qemu.sh` in PowerShell does nothing useful):

```bash
.\build.cmd prod
```

```bash
.\run-qemu.cmd prod
```

Open <http://localhost:8080> for the live dashboard. To feed the laptop webcam into the device
(from Windows PowerShell, needs `winget install Gyan.FFmpeg`):

```bash
powershell -ExecutionPolicy Bypass -File host-tools/webcam-stream.ps1
```

Watch detections arriving over MQTT:

```bash
host-tools/mqtt-watch.sh
```

## Repository layout

```
build.sh  run-qemu.sh  VERSION
br2-external/                 Buildroot external tree
  configs/                    edgesight_prod_defconfig, edgesight_dev.fragment
  package/                    onnxruntime-bin, edgesight-models, edgesightd
  board/edgesight/
    linux/                    tinyconfig-6.12.config + base/virtio/fs/net/security/ml/boot/dev.cfg
    grub.cfg genimage.cfg     A/B boot selection, GPT layout
    post-build.sh post-image.sh   rootfs finishing, dm-verity, disk image, signed bundle
    rootfs-overlay/           inittab, rcS, service wrappers, sysctl, nftables, RAUC, app config
app/edgesightd/               the C++ inference service (MIT)
scripts/                      gen-keys, make-ota-bundles, check-kernel-config, helpers
tests/                        test-boot, test-security, test-tamper, test-ota
bench/                        run-bench.sh, stock_pipeline.py, report.py, results/
baseline/ubuntu/              stock Ubuntu 24.04 measurement harness + results
host-tools/                   OTA server, MQTT viewer, webcam/video streamers
docs/                         report, demo script, licence list
out/                          build deliverables (kernel .config, manifests, size reports)
```

## Tests

| Script | What it proves |
|---|---|
| `tests/test-boot.sh prod 5` | boot → service ready, dashboard, MJPEG, MQTT, slot confirmation, no shell/SSH; boot timing ×5 |
| `tests/test-security.sh` | ELF hardening, no setuid, kernel-hardening score, process confinement, sandbox escape probes |
| `tests/test-robustness.sh` | fuzzes the camera ingest and HTTP server of the prod image; no crash, no restart, stays healthy |
| `tests/test-sanitizers.sh` | ASan + LSan + UBSan build of `edgesightd` driven through the same fuzz campaign and all backends |
| `tests/test-tamper.sh` | offline modification of the root fs → dm-verity panic → automatic fallback to slot B |
| `scripts/make-ota-bundles.sh && tests/test-ota.sh` | signed update, tampered + rogue bundles rejected, broken update rolled back |
| `bench/run-bench.sh` / `bench/run-bench.sh isolation` | runtime × precision × threads matrix (interleaved rounds); CPU-isolation jitter ablation |
| `baseline/ubuntu/run-baseline.sh` | the same measurements on stock Ubuntu Server 24.04 |
| `bench/ab-compare.sh` | interleaved EdgeSight vs Ubuntu (same binary) vs Ubuntu Python/pip inference |
| `bench/ab-boot.sh` | interleaved boot-time and RAM comparison, EdgeSight vs Ubuntu |
| `scripts/check-reproducible.sh` | from-scratch rebuild, byte-for-byte comparison of every image |
| `scripts/run-all-tests.sh` | rebuild both variants and run every suite (summary in `bench/results/summary.txt`) |
| `bench/report.py` | regenerate `docs/results.md` and the charts from the raw results |

Headline results (see the report): root fs **58.7 MiB vs 2.2 GiB** (−97 %), **196 vs 400 MiB** RAM,
**5.1 vs 18.7 s** power-on to detecting, **44 vs 35 FPS** against the stock Python deployment,
bit-identical rebuilds.

## Variants

* **prod** – no shell, no login, no SSH; the only way in is a signed update.
* **dev** – `./build.sh dev`: adds a root console, Dropbear SSH (key-only), strace, htop, Python 3,
  and a kernel with kallsyms/perf. Used for benchmarks and runtime inspection.

See [docs/report.md](docs/report.md) for the full design, evaluation and licence list.

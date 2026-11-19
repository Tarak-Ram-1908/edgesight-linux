# Assignment requirements → evidence

Every requirement of the assignment brief, mapped to where it is satisfied and how it was verified.
Status ✅ = done and verified by a script or test in this repository.

## Problem statement

| Requirement | Status | Evidence |
|---|---|---|
| Customised Linux distribution for one track, driven by the application's HW/SW stack | ✅ | Track A (ML inference at the edge, x86 board). Every config choice traces back to the detector: [report §1](report.md#1-requirements-analysis) |

## Tasks

| Task | Requirement | Status | Evidence |
|---|---|---|---|
| 1. Requirements analysis | HW (CPU/GPU/FPGA/sensors), performance, latency, power, footprint | ✅ | [report §1.1](report.md#11-target-platform): requirement table, each marked met with its measured value |
| | Explain why a stock distro is unsuitable | ✅ | [report §1.2](report.md#12-why-a-stock-distribution-is-unsuitable), quantified in §7 |
| 2. Build system | Choose one and compare ≥ 2 options | ✅ | [report §2](report.md#2-build-system-selection): Buildroot vs Yocto vs Debian live-build vs vendor SDK. Buildroot numbers measured (64 min first build, ~1 min incremental, 28 min clean rebuild) |
| 3. Kernel | Custom kernel with only required drivers | ✅ | `tinyconfig` + 7 fragments (`br2-external/board/edgesight/linux/`), 0 modules, 916 built-in options; `scripts/check-kernel-config.sh` → 168/168 options effective |
| | Track A: GPU drivers, kernel modules, DMA/memory settings for accelerators | ✅ | No GPU on the target (justified): CPU-SIMD inference; THP, CMA reserve for a future NPU, cgroup limits, CPU isolation measured ([report §3.2](report.md#32-accelerator-memory-settings), §7.4) |
| | Report kernel size and boot time before and after | ✅ | [report §3.3](report.md#33-kernel-size-and-boot-time-before-and-after): Ubuntu generic vs EdgeSight; boot-log analysis removed 0.36 s (§3.1) |
| 4. Userland | Minimal package set, integrate the stack | ✅ | 35 target packages (`out/prod/manifest.csv`); ONNX Runtime + TFLite/XNNPACK + MQTT + our C++ service |
| | Justify each major inclusion and exclusion | ✅ | [report §4.1–4.2](report.md#41-what-is-in-the-image-prod-35-target-packages), byte budget §4.5 |
| 5. System config & security | Init system + auto-start of the application | ✅ | BusyBox init, `rootfs-overlay/etc/inittab`, `run-edgesightd` (respawn), health check, OTA agent |
| | Read-only root + overlay | ✅ | squashfs root under dm-verity; `/etc` overlay on `/data`; `tests/test-security.sh` "cannot be remounted rw" |
| | ≥ 3 hardening measures | ✅ | 14 measures, each with a passing test: [report §5.3](report.md#53-hardening-measures-the-assignment-asks-for-3-14-are-implemented-and-tested) |
| | Secure boot **or** signed updates | ✅ | RAUC CMS-signed A/B bundles + bundle dm-verity + rollback; `tests/test-ota.sh` 15/15 (Secure Boot itself listed as future work) |
| 6. Build, test, deploy | Bootable image | ✅ | `~/edgesight-work/output-prod/images/disk.img` (GPT, UEFI) from `./build.sh prod` |
| | Run on real HW or QEMU | ✅ | QEMU q35 + KVM + OVMF: `run-qemu.sh` / `run-qemu.cmd` |
| | End-to-end demonstration | ✅ | frames → SSD-MobileNet → MQTT + live dashboard; webcam ingest; `tests/test-boot.sh` checks dashboard, MJPEG and MQTT |
| 7. Evaluation | vs stock distro: image size, RAM, boot time, package count | ✅ | [report §7.1–7.2](report.md#71-footprint-target--40--smaller-achieved-9597-), interleaved runs vs Ubuntu Server 24.04 on the identical VM |
| | Application metrics (latency/FPS, throughput, power) | ✅ | §7.3 (interleaved A/B incl. stock Python/pip), §7.4 ablations; power via CPU-ms/frame |
| 8. Documentation & demo | Report | ✅ | [docs/report.md](report.md), [docs/results.md](results.md) (generated) |
| | Git repository | ✅ | this repository (`git init`, all sources, configs, scripts, results) |
| | Short demo (live and video) | ✅ script / ⏺ to record | [docs/demo-script.md](demo-script.md); the video must be recorded by the team |

## Deliverables

| Deliverable | Status | Where |
|---|---|---|
| Bootable image or reproducible build recipe | ✅ both | `./build.sh prod`; from-scratch rebuild is bit-identical (`bench/results/reproducibility.txt`) |
| Kernel `.config` | ✅ | `out/prod/kernel.config`, `out/dev/kernel.config` |
| Device tree files | ✅ (n/a on x86, explained) | x86 uses ACPI, not device trees: [report §3.1](report.md#31-method) |
| Package manifest | ✅ | `out/prod/manifest.csv` (Buildroot legal-info), `out/prod/packages.txt` |
| Git repository with scripts and configurations | ✅ | `build.sh`, `br2-external/`, `scripts/`, `tests/`, `bench/`, `baseline/` |
| Report with benchmarks and licence list | ✅ | [report.md](report.md), [results.md](results.md), [licenses.md](licenses.md) |
| Demo (live and video) | script ✅ / video ⏺ | [demo-script.md](demo-script.md) |

## Constraints

| Constraint | Status | Evidence |
|---|---|---|
| Build reproducible from scripts | ✅ | one command; pinned Buildroot tag; every download sha256-pinned; 7/7 artefacts bit-identical after a clean rebuild |
| Proprietary components only if listed and justified; everything else open source | ✅ | **none used**: ONNX Runtime is MIT (Microsoft binary release, telemetry disabled and firewalled) ([licenses.md](licenses.md), report §8) |
| Image ≥ 40 % smaller than the stock distro | ✅ | root fs −97.4 %, kernel −95.1 %, distributable image −79 % (report §7.1) |

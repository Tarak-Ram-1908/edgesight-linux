# EdgeSight demo script (≈ 6 minutes, live or recorded)

Three terminals in WSL (`T1` device console, `T2` host tools, `T3` OTA server) plus a browser.
Before the session: `./build.sh prod`, `scripts/make-ota-bundles.sh` (bundles in `~/edgesight-work/bundles`).

| t | Who | Action | Say |
|---|---|---|---|
| 0:00 | T2 | `./build.sh prod` (show it is a no-op rebuild, then `cat out/prod/size-report.txt`) | "One script, pinned Buildroot LTS, hash-checked sources. Root fs 58.7 MiB, kernel 3.6 MiB, and a rebuild from scratch is bit-identical." |
| 0:30 | T1 | `./run-qemu.sh prod --fresh` (Windows: `run-qemu.cmd prod --fresh`) | "UEFI → GRUB picks slot A → kernel builds the dm-verity root itself, no initramfs." Point at `EDGESIGHT_READY uptime=…` |
| 1:00 | Browser | <http://localhost:8080> | Live boxes, FPS, p50/p99 latency, RSS, sandbox=strict, slot A |
| 1:30 | PowerShell | `host-tools\webcam-stream.ps1` | Dashboard flips from "sample loop" to "camera" – detect yourself / a cup / a phone |
| 2:15 | T2 | `host-tools/mqtt-watch.sh` | Same detections as JSON over MQTT – a dashboard or SCADA could subscribe |
| 2:45 | T1 | try to type in the console | "No getty, no shell, no SSH. The only way to change this device is a signed update." |
| 3:00 | T3 | `host-tools/ota-server.sh serve` ; T2 `host-tools/ota-server.sh publish ~/edgesight-work/bundles/edgesight-1.1.0.raucb 1.1.0` | Console: `update available` → `installed 1.1.0` → reboot → `booting slot B` → `update 1.1.0 confirmed`. Dashboard: INT8 model, FPS up |
| 4:00 | T2 | publish `edgesight-1.1.1-tampered.raucb` then `edgesight-6.6.6-rogue.raucb` | Console: `REJECTED …` twice – verity hash mismatch / signer not in keyring |
| 4:40 | T2 | publish `edgesight-1.2.0.raucb` (broken build) | Installs into A, boots, health check fails after 45 s, `mark-bad`, reboot → slot B. "Self-healing, no technician." |
| 5:30 | T2 | `tests/test-tamper.sh` (or show its recorded output) | Byte flipped in the root partition → `verity … corrupted` → panic → fallback slot |
| 6:00 | Browser | `docs/report.md` evaluation charts | Root fs −97 % (58.7 MiB vs 2.2 GiB), RAM −51 %, power-on→detecting 5.1 s vs 18.7 s, 44 vs 35 FPS against stock Python; bit-identical rebuild |

Fallbacks: if the webcam fails use `host-tools/video-stream.sh` (test pattern) or stay on the sample loop;
keep a recording of the OTA sequence (`tests/test-ota.sh` output) in case the live network misbehaves.

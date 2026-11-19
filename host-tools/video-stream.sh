#!/usr/bin/env bash
# Stream a video file (or a generated test pattern) into the VM camera ingest, from WSL/Linux.
#   host-tools/video-stream.sh [file.mp4] [fps]
set -euo pipefail
SRC="${1:-}"; FPS="${2:-15}"; PORT="${CAM_FWD:-5000}"
if [ -n "$SRC" ]; then
    exec ffmpeg -hide_banner -loglevel warning -re -stream_loop -1 -i "$SRC" -vf "fps=$FPS,scale=640:-2" -q:v 5 -f mjpeg "tcp://127.0.0.1:$PORT"
else
    exec ffmpeg -hide_banner -loglevel warning -re -f lavfi -i "testsrc2=size=640x480:rate=$FPS" -q:v 5 -f mjpeg "tcp://127.0.0.1:$PORT"
fi

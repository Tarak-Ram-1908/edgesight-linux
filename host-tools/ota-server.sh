#!/usr/bin/env bash
# Serve OTA bundles to EdgeSight devices (QEMU guests reach the host at 10.0.2.2).
#
#   host-tools/ota-server.sh publish <bundle.raucb> <version>   # make it the "latest"
#   host-tools/ota-server.sh serve [port]                         # default 8000
#
# The device polls GET /latest -> "<version> <file>" and downloads <file>.
set -euo pipefail
WORK="${EDGESIGHT_WORK:-$HOME/edgesight-work}"
DIR="$WORK/ota-www"
mkdir -p "$DIR"
case "${1:-serve}" in
    publish)
        cp "$2" "$DIR/$(basename "$2")"
        echo "$3 $(basename "$2")" > "$DIR/latest"
        echo "published $(basename "$2") as version $3"
        ;;
    withdraw)
        rm -f "$DIR/latest"; echo "no update advertised" ;;
    serve)
        PORT="${2:-8000}"
        echo "OTA server on :$PORT serving $DIR"
        cd "$DIR" && exec python3 -m http.server "$PORT" --bind 0.0.0.0
        ;;
    *) echo "usage: $0 publish <bundle> <version> | withdraw | serve [port]" >&2; exit 2 ;;
esac

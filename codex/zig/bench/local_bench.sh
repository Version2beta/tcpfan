#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_PORT="${SRC_PORT:-5000}"
SINK_PORT="${SINK_PORT:-5001}"
SINKS="${SINKS:-4}"
BYTES="${BYTES:-16777216}"  # 16 MiB

cd "$ROOT"
zig build -Doptimize=ReleaseFast >/dev/null

"$ROOT/zig-out/bin/tcpfan-zig" --source-port "$SRC_PORT" --sink-port "$SINK_PORT" --log-level warn &
RELAY_PID=$!
cleanup() {
  kill "$RELAY_PID" >/dev/null 2>&1 || true
}
trap cleanup EXIT

sleep 0.2

for _ in $(seq 1 "$SINKS"); do
  nc 127.0.0.1 "$SINK_PORT" >/dev/null &
done
sleep 0.2

start_ns=$(date +%s%N)
dd if=/dev/zero bs=1m count=$((BYTES / 1048576)) status=none | nc 127.0.0.1 "$SRC_PORT"
end_ns=$(date +%s%N)

elapsed_ns=$((end_ns - start_ns))
mbps=$(awk -v b="$BYTES" -v ns="$elapsed_ns" 'BEGIN { printf "%.2f", (b / (1024*1024)) / (ns / 1e9) }')

echo "Sent $BYTES bytes to source with $SINKS sinks in $((elapsed_ns / 1000000)) ms (${mbps} MiB/s source feed)"

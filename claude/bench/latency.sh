#!/usr/bin/env bash
# Latency suite: sends COUNT timestamped messages of MSG_SIZE bytes each,
# spaced INTERVAL_US apart, to the relay; measures per-sink p50/p99/max.
#
# Usage: bench/latency.sh <c|zig> [COUNT] [INTERVAL_US] [MSG_SIZE] [SINKS]
set -euo pipefail
WHICH="${1:-c}"
COUNT="${2:-10000}"
INTERVAL_US="${3:-100}"
MSG_SIZE="${4:-64}"
SINKS="${5:-4}"
SRC_PORT="${SRC_PORT:-19200}"
SNK_PORT="${SNK_PORT:-19201}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
make -C bench >/dev/null

case "$WHICH" in
  c)   BIN="$ROOT/c/tcpfan" ;;
  zig) BIN="$ROOT/zig/zig-out/bin/tcpfan" ;;
  *)   echo "unknown impl: $WHICH" >&2; exit 2 ;;
esac
[ -x "$BIN" ] || { echo "missing binary: $BIN" >&2; exit 2; }

LOG="$ROOT/results/${WHICH}_latency.log"
mkdir -p "$ROOT/results"
: > "$LOG"

"$BIN" --source-port "$SRC_PORT" --sink-port "$SNK_PORT" \
       --max-sinks 64 --stats-interval-ms 0 --log-level normal \
       >"$LOG" 2>&1 &
RPID=$!
trap 'kill $RPID 2>/dev/null || true; wait 2>/dev/null || true' EXIT

# Wait for listeners.
for _ in $(seq 1 50); do
  if nc -z 127.0.0.1 "$SRC_PORT" 2>/dev/null && nc -z 127.0.0.1 "$SNK_PORT" 2>/dev/null; then
    break
  fi
  sleep 0.05
done

# Spawn sinks.
SINK_PIDS=()
SINK_LOGS=()
for i in $(seq 1 "$SINKS"); do
  L="$ROOT/results/${WHICH}_lat_sink_${i}.log"
  SINK_LOGS+=("$L")
  "$ROOT/bench/latency_sink" 127.0.0.1 "$SNK_PORT" "$COUNT" "$MSG_SIZE" 2>"$L" &
  SINK_PIDS+=($!)
done

sleep 0.2

SRC_LOG="$ROOT/results/${WHICH}_lat_source.log"
"$ROOT/bench/latency_source" 127.0.0.1 "$SRC_PORT" "$COUNT" "$INTERVAL_US" "$MSG_SIZE" 2>"$SRC_LOG"

RC=0
for pid in "${SINK_PIDS[@]}"; do
  if ! wait "$pid"; then RC=1; fi
done

kill -INT "$RPID" 2>/dev/null || true
wait "$RPID" 2>/dev/null || true
trap - EXIT

echo "=== $WHICH: latency source ==="; cat "$SRC_LOG"
for L in "${SINK_LOGS[@]}"; do echo "=== $(basename "$L") ==="; cat "$L"; done
exit $RC

#!/usr/bin/env bash
# Usage: bench/run.sh <c|zig> [BYTES] [SINKS]
#
# Boots the chosen relay binary, attaches SINKS sinks, pushes BYTES from one
# source, prints throughput, and exits non-zero if any sink reports a
# mismatch or short count.
set -euo pipefail

WHICH="${1:-c}"
BYTES="${2:-$((1024*1024*1024))}"   # 1 GiB default
SINKS="${3:-4}"
SRC_PORT="${SRC_PORT:-19000}"
SNK_PORT="${SNK_PORT:-19001}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
make -C bench >/dev/null

case "$WHICH" in
  c)   BIN="$ROOT/c/tcpfan" ;;
  zig) BIN="$ROOT/zig/zig-out/bin/tcpfan" ;;
  *)   echo "unknown impl: $WHICH" >&2; exit 2 ;;
esac
[ -x "$BIN" ] || { echo "missing binary: $BIN" >&2; exit 2; }

LOG="$ROOT/results/${WHICH}.log"
mkdir -p "$ROOT/results"
: > "$LOG"

# Boot relay.
"$BIN" --source-port "$SRC_PORT" --sink-port "$SNK_PORT" \
       --max-sinks 64 --stats-interval-ms 0 --log-level normal \
       >"$LOG" 2>&1 &
RELAY_PID=$!
trap 'kill $RELAY_PID 2>/dev/null || true; wait 2>/dev/null || true' EXIT

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
  L="$ROOT/results/${WHICH}_sink_${i}.log"
  SINK_LOGS+=("$L")
  "$ROOT/bench/sink_reader" 127.0.0.1 "$SNK_PORT" "$BYTES" 2>"$L" &
  SINK_PIDS+=($!)
done

# Tiny grace so all sinks register before source starts.
sleep 0.2

# Push source.
SRC_LOG="$ROOT/results/${WHICH}_source.log"
"$ROOT/bench/source_writer" 127.0.0.1 "$SRC_PORT" "$BYTES" 2>"$SRC_LOG"

# Wait for sinks.
RC=0
for pid in "${SINK_PIDS[@]}"; do
  if ! wait "$pid"; then RC=1; fi
done

# Stop relay.
kill -INT "$RELAY_PID" 2>/dev/null || true
wait "$RELAY_PID" 2>/dev/null || true
trap - EXIT

echo "=== $WHICH: source ==="; cat "$SRC_LOG"
for L in "${SINK_LOGS[@]}"; do echo "=== $WHICH: $(basename "$L") ==="; cat "$L"; done
echo "=== $WHICH: relay ==="; tail -n 20 "$LOG" || true

exit $RC

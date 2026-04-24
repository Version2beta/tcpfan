#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 6 ]; then
  echo "usage: $0 <c|zig> <bytes> <sinks> <src_port> <sink_port> <round_tag>" >&2
  exit 2
fi

IMPL="$1"
BYTES="$2"
SINKS="$3"
SRC_PORT="$4"
SNK_PORT="$5"
ROUND_TAG="$6"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RESULTS="$ROOT/results"
mkdir -p "$RESULTS"

make -C "$ROOT/bench" >/dev/null

case "$IMPL" in
  c)
    make -C "$ROOT/c" >/dev/null
    BIN="$ROOT/c/relay"
    ARGS=(--source-bind 127.0.0.1 --source-port "$SRC_PORT" --sink-bind 127.0.0.1 --sink-port "$SNK_PORT" --max-sinks 4096 --sink-pending-bytes 67108864 --stats-interval-ms 0 --poll-timeout-ms 50 --log-level normal)
    ;;
  zig)
    (cd "$ROOT/zig" && zig build -Doptimize=ReleaseFast >/dev/null)
    BIN="$ROOT/zig/zig-out/bin/tcpfan-zig"
    ARGS=(--source-bind 127.0.0.1 --source-port "$SRC_PORT" --sink-bind 127.0.0.1 --sink-port "$SNK_PORT" --max-sinks 4096 --sink-pending-max 67108864 --stats-interval-ms 0 --poll-timeout-ms 50 --log-level normal)
    ;;
  *)
    echo "unknown impl: $IMPL" >&2
    exit 2
    ;;
esac

LOG_RELAY="$RESULTS/${ROUND_TAG}_${IMPL}_relay.log"
LOG_SRC="$RESULTS/${ROUND_TAG}_${IMPL}_source.log"
: > "$LOG_RELAY"
: > "$LOG_SRC"

"$BIN" "${ARGS[@]}" >"$LOG_RELAY" 2>&1 &
RELAY_PID=$!

stop_relay() {
  if ! kill -0 "$RELAY_PID" >/dev/null 2>&1; then
    wait "$RELAY_PID" >/dev/null 2>&1 || true
    return
  fi
  kill -INT "$RELAY_PID" >/dev/null 2>&1 || true
  for _ in $(seq 1 50); do
    if ! kill -0 "$RELAY_PID" >/dev/null 2>&1; then
      wait "$RELAY_PID" >/dev/null 2>&1 || true
      return
    fi
    sleep 0.02
  done
  kill -TERM "$RELAY_PID" >/dev/null 2>&1 || true
  for _ in $(seq 1 50); do
    if ! kill -0 "$RELAY_PID" >/dev/null 2>&1; then
      wait "$RELAY_PID" >/dev/null 2>&1 || true
      return
    fi
    sleep 0.02
  done
  kill -KILL "$RELAY_PID" >/dev/null 2>&1 || true
  wait "$RELAY_PID" >/dev/null 2>&1 || true
}

cleanup() {
  stop_relay
}
trap cleanup EXIT

for _ in $(seq 1 100); do
  if [ -s "$LOG_RELAY" ] && grep -q "listening" "$LOG_RELAY"; then
    break
  fi
  sleep 0.02
done

SINK_PIDS=()
SINK_LOGS=()
for i in $(seq 1 "$SINKS"); do
  L="$RESULTS/${ROUND_TAG}_${IMPL}_sink_${i}.log"
  SINK_LOGS+=("$L")
  "$ROOT/bench/sink_reader" 127.0.0.1 "$SNK_PORT" "$BYTES" 2>"$L" &
  SINK_PIDS+=("$!")
done

sleep 1.0
"$ROOT/bench/source_writer" 127.0.0.1 "$SRC_PORT" "$BYTES" 2>"$LOG_SRC"

RC=0
for pid in "${SINK_PIDS[@]}"; do
  if ! wait "$pid"; then
    RC=1
  fi
done

stop_relay
trap - EXIT

if [ "$RC" -ne 0 ]; then
  echo "round failed impl=$IMPL round=$ROUND_TAG" >&2
  exit 1
fi

python3 - "$LOG_SRC" "${SINK_LOGS[@]}" <<'PY'
import re, sys, statistics
src_log = sys.argv[1]
sink_logs = sys.argv[2:]

src_txt = open(src_log, 'r', encoding='utf-8').read()
m = re.search(r"in\s+([0-9.]+)s\s+=>\s+([0-9.]+)\s+MiB/s", src_txt)
if not m:
    raise SystemExit("cannot parse source throughput")
source_sec = float(m.group(1))
throughput = float(m.group(2))

latencies = []
for p in sink_logs:
    txt = open(p, 'r', encoding='utf-8').read()
    mm = re.search(r"in\s+([0-9.]+)s\s+=>\s+([0-9.]+)\s+MiB/s", txt)
    if not mm:
        raise SystemExit(f"cannot parse sink log: {p}")
    latencies.append(float(mm.group(1)))

latencies.sort()
count = len(latencies)
def pct(arr, q):
    if not arr:
        return 0.0
    idx = max(0, min(len(arr)-1, int(round((len(arr)-1)*q))))
    return arr[idx]

print(f"throughput_mib_s={throughput:.2f}")
print(f"source_completion_s={source_sec:.3f}")
print(f"sink_latency_p50_s={pct(latencies,0.50):.3f}")
print(f"sink_latency_p95_s={pct(latencies,0.95):.3f}")
print(f"sink_latency_max_s={max(latencies):.3f}")
print(f"sink_latency_min_s={min(latencies):.3f}")
print(f"sink_count={count}")
PY

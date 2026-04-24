#!/usr/bin/env bash
set -uo pipefail

if [ "$#" -ne 7 ]; then
  echo "usage: $0 <impl> <bytes> <sinks> <src_port> <sink_port> <scenario_id> <rep>" >&2
  exit 2
fi

IMPL="$1"
BYTES="$2"
SINKS="$3"
SRC_PORT="$4"
SNK_PORT="$5"
SCENARIO_ID="$6"
REP="$7"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BENCH="$ROOT/benchmark"
RESULTS="$BENCH/results"
RAW="$RESULTS/raw"
mkdir -p "$RAW"

make -C "$BENCH" >/dev/null

case "$IMPL" in
  claude-c)
    BIN="$ROOT/bin/tcpfan-claude-c"
    ARGS=(--source-port "$SRC_PORT" --sink-port "$SNK_PORT" --max-sinks 4096 --sink-buf 67108864 --stats-interval-ms 0 --log-level normal)
    ;;
  claude-zig)
    BIN="$ROOT/bin/tcpfan-claude-zig"
    ARGS=(--source-port "$SRC_PORT" --sink-port "$SNK_PORT" --max-sinks 4096 --sink-buf 67108864 --stats-interval-ms 0 --log-level normal)
    ;;
  codex-c)
    BIN="$ROOT/bin/tcpfan-codex-c"
    ARGS=(--source-bind 127.0.0.1 --source-port "$SRC_PORT" --sink-bind 127.0.0.1 --sink-port "$SNK_PORT" --max-sinks 4096 --sink-pending-bytes 67108864 --stats-interval-ms 0 --poll-timeout-ms 50 --log-level normal)
    ;;
  codex-zig)
    BIN="$ROOT/bin/tcpfan-codex-zig"
    ARGS=(--source-bind 127.0.0.1 --source-port "$SRC_PORT" --sink-bind 127.0.0.1 --sink-port "$SNK_PORT" --max-sinks 4096 --sink-pending-max 67108864 --stats-interval-ms 0 --poll-timeout-ms 50 --close-sinks-on-session-end true --log-level normal)
    ;;
  *)
    echo "unknown impl: $IMPL" >&2
    exit 2
    ;;
esac

if [ ! -x "$BIN" ]; then
  echo "binary not executable: $BIN" >&2
  exit 2
fi

TAG="s${SCENARIO_ID}_r${REP}_${IMPL}"
LOG_RELAY="$RAW/${TAG}_relay.log"
LOG_SRC="$RAW/${TAG}_source.log"
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
  for _ in $(seq 1 60); do
    if ! kill -0 "$RELAY_PID" >/dev/null 2>&1; then
      wait "$RELAY_PID" >/dev/null 2>&1 || true
      return
    fi
    sleep 0.02
  done

  kill -TERM "$RELAY_PID" >/dev/null 2>&1 || true
  for _ in $(seq 1 60); do
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

sleep 0.8

SINK_PIDS=()
SINK_LOGS=()
for i in $(seq 1 "$SINKS"); do
  L="$RAW/${TAG}_sink_${i}.log"
  SINK_LOGS+=("$L")
  "$BENCH/sink_reader" 127.0.0.1 "$SNK_PORT" "$BYTES" 2>"$L" &
  SINK_PIDS+=("$!")
done

sleep 0.25
RC=0
if ! "$BENCH/source_writer" 127.0.0.1 "$SRC_PORT" "$BYTES" 2>"$LOG_SRC"; then
  RC=1
fi

for pid in "${SINK_PIDS[@]}"; do
  if ! wait "$pid"; then
    RC=1
  fi
done

stop_relay
trap - EXIT

python3 - "$IMPL" "$BYTES" "$SINKS" "$LOG_SRC" "$RC" "${SINK_LOGS[@]}" <<'PY'
import re, statistics, sys
impl = sys.argv[1]
bytes_n = int(sys.argv[2])
sinks = int(sys.argv[3])
src_log = sys.argv[4]
rc = int(sys.argv[5])
sink_logs = sys.argv[6:]

source_sent = 0
source_sec = 0.0
source_mib = 0.0
parse_error = ""

src_txt = open(src_log, 'r', encoding='utf-8').read() if src_log else ""
ms = re.search(r"source:\s+sent=(\d+)\s+bytes\s+in\s+([0-9.]+)s\s+=>\s+([0-9.]+)\s+MiB/s", src_txt)
if ms:
    source_sent = int(ms.group(1))
    source_sec = float(ms.group(2))
    source_mib = float(ms.group(3))
else:
    parse_error = "source"

latencies = []
sink_mibs = []
sink_got = []
sink_mismatch = []
for p in sink_logs:
    txt = open(p, 'r', encoding='utf-8').read()
    m = re.search(r"sink:\s+got=(\d+)\s+expected=(\d+)\s+mismatches=(\d+)\s+in\s+([0-9.]+)s\s+=>\s+([0-9.]+)\s+MiB/s", txt)
    if not m:
        parse_error = parse_error or "sink"
        continue
    sink_got.append(int(m.group(1)))
    expected = int(m.group(2))
    sink_mismatch.append(int(m.group(3)))
    latencies.append(float(m.group(4)))
    sink_mibs.append(float(m.group(5)))
    if expected != bytes_n:
        parse_error = parse_error or "expected_mismatch"

if not latencies:
    latencies = [0.0]
if not sink_mibs:
    sink_mibs = [0.0]

latencies.sort()
def pct(arr, q):
    if not arr:
        return 0.0
    idx = max(0, min(len(arr)-1, int(round((len(arr)-1)*q))))
    return arr[idx]

all_ok = (
    rc == 0 and
    parse_error == "" and
    source_sent == bytes_n and
    len(sink_got) == sinks and
    all(g == bytes_n for g in sink_got) and
    all(m == 0 for m in sink_mismatch)
)
if not all_ok and parse_error == "":
    parse_error = "runtime_fail"

print(f"success={1 if all_ok else 0}")
print(f"parse_error={parse_error}")
print(f"impl={impl}")
print(f"bytes={bytes_n}")
print(f"sinks={sinks}")
print(f"source_mib_s={source_mib:.2f}")
print(f"source_sec={source_sec:.3f}")
print(f"sink_latency_p50_s={pct(latencies,0.50):.3f}")
print(f"sink_latency_p95_s={pct(latencies,0.95):.3f}")
print(f"sink_latency_max_s={max(latencies):.3f}")
print(f"sink_latency_min_s={min(latencies):.3f}")
print(f"sink_latency_mean_s={statistics.fmean(latencies):.3f}")
print(f"sink_latency_stddev_s={(statistics.pstdev(latencies) if len(latencies)>1 else 0.0):.3f}")
print(f"sink_mib_mean={statistics.fmean(sink_mibs):.2f}")
print(f"sink_mib_min={min(sink_mibs):.2f}")
print(f"sink_mib_max={max(sink_mibs):.2f}")
PY

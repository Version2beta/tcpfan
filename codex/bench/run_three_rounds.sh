#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RESULTS="$ROOT/results"
mkdir -p "$RESULTS"

OUT_CSV="$RESULTS/rounds.csv"
OUT_MD="$RESULTS/rounds.md"

cat > "$OUT_CSV" <<CSV
round,impl,bytes,sinks,throughput_mib_s,source_completion_s,sink_latency_p50_s,sink_latency_p95_s,sink_latency_max_s,sink_latency_min_s
CSV

run_round() {
  local round="$1" impl="$2" bytes="$3" sinks="$4" src_port="$5" snk_port="$6"
  local tag="r${round}"
  local metrics
  metrics=$("$ROOT/bench/run_once.sh" "$impl" "$bytes" "$sinks" "$src_port" "$snk_port" "$tag")
  local throughput source_sec p50 p95 pmax pmin
  throughput=$(printf '%s\n' "$metrics" | awk -F= '/^throughput_mib_s=/{print $2}')
  source_sec=$(printf '%s\n' "$metrics" | awk -F= '/^source_completion_s=/{print $2}')
  p50=$(printf '%s\n' "$metrics" | awk -F= '/^sink_latency_p50_s=/{print $2}')
  p95=$(printf '%s\n' "$metrics" | awk -F= '/^sink_latency_p95_s=/{print $2}')
  pmax=$(printf '%s\n' "$metrics" | awk -F= '/^sink_latency_max_s=/{print $2}')
  pmin=$(printf '%s\n' "$metrics" | awk -F= '/^sink_latency_min_s=/{print $2}')

  printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n" \
    "$round" "$impl" "$bytes" "$sinks" "$throughput" "$source_sec" "$p50" "$p95" "$pmax" "$pmin" \
    >> "$OUT_CSV"
}

# round, bytes, sinks
ROUNDS=(
  "1 67108864 4"
  "2 134217728 8"
  "3 134217728 12"
)

for spec in "${ROUNDS[@]}"; do
  set -- $spec
  round="$1"; bytes="$2"; sinks="$3"
  run_round "$round" c   "$bytes" "$sinks" "$((20000 + round * 100 + 0))" "$((20000 + round * 100 + 1))"
  run_round "$round" zig "$bytes" "$sinks" "$((20000 + round * 100 + 10))" "$((20000 + round * 100 + 11))"
done

python3 - "$OUT_CSV" "$OUT_MD" <<'PY'
import csv, sys
csv_path, md_path = sys.argv[1], sys.argv[2]
rows = list(csv.DictReader(open(csv_path, newline='')))

by_round = {}
for r in rows:
    by_round.setdefault(r['round'], []).append(r)

lines = []
lines.append("# Three-Round Benchmark Summary")
lines.append("")
for rnd in sorted(by_round, key=lambda x:int(x)):
    lines.append(f"## Round {rnd}")
    lines.append("")
    lines.append("| impl | bytes | sinks | throughput MiB/s | source completion s | sink p50 s | sink p95 s | sink max s |")
    lines.append("|---|---:|---:|---:|---:|---:|---:|---:|")
    for r in sorted(by_round[rnd], key=lambda x:x['impl']):
        lines.append(f"| {r['impl']} | {r['bytes']} | {r['sinks']} | {r['throughput_mib_s']} | {r['source_completion_s']} | {r['sink_latency_p50_s']} | {r['sink_latency_p95_s']} | {r['sink_latency_max_s']} |")
    lines.append("")

# averages per impl
impls = sorted(set(r['impl'] for r in rows))
lines.append("## Averages")
lines.append("")
lines.append("| impl | avg throughput MiB/s | avg source completion s | avg sink p95 s |")
lines.append("|---|---:|---:|---:|")
for impl in impls:
    rs = [r for r in rows if r['impl']==impl]
    avg_tp = sum(float(r['throughput_mib_s']) for r in rs)/len(rs)
    avg_src = sum(float(r['source_completion_s']) for r in rs)/len(rs)
    avg_p95 = sum(float(r['sink_latency_p95_s']) for r in rs)/len(rs)
    lines.append(f"| {impl} | {avg_tp:.2f} | {avg_src:.3f} | {avg_p95:.3f} |")

open(md_path, 'w', encoding='utf-8').write('\n'.join(lines) + '\n')
print(md_path)
PY

echo "Wrote: $OUT_CSV"
echo "Wrote: $OUT_MD"

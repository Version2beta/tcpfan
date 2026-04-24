#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BENCH="$ROOT/benchmark"
RESULTS="$BENCH/results"
mkdir -p "$RESULTS/raw"

REPEATS="${REPEATS:-3}"

CSV="$RESULTS/benchmark.csv"
MD="$RESULTS/benchmark.md"
JSON="$RESULTS/benchmark_summary.json"

cat > "$CSV" <<CSV
scenario,repeat,impl,bytes,sinks,success,parse_error,source_mib_s,source_sec,sink_latency_p50_s,sink_latency_p95_s,sink_latency_max_s,sink_latency_min_s,sink_latency_mean_s,sink_latency_stddev_s,sink_mib_mean,sink_mib_min,sink_mib_max
CSV

# scenario_id bytes sinks
SCENARIOS=(
  "1 67108864 4"
  "2 134217728 8"
  "3 134217728 12"
)

IMPLS=(
  "claude-c"
  "claude-zig"
  "codex-c"
  "codex-zig"
)

base_port=25000
port_stride=200
impl_stride=20

for spec in "${SCENARIOS[@]}"; do
  set -- $spec
  scenario="$1"; bytes="$2"; sinks="$3"

  rep=1
  while [ "$rep" -le "$REPEATS" ]; do
    idx=0
    for impl in "${IMPLS[@]}"; do
      src_port=$((base_port + scenario * port_stride + rep * 4 + idx * impl_stride + 0))
      snk_port=$((base_port + scenario * port_stride + rep * 4 + idx * impl_stride + 1))

      metrics="$($BENCH/run_impl_once.sh "$impl" "$bytes" "$sinks" "$src_port" "$snk_port" "$scenario" "$rep")"

      success=$(printf '%s\n' "$metrics" | awk -F= '/^success=/{print $2}')
      parse_error=$(printf '%s\n' "$metrics" | awk -F= '/^parse_error=/{print $2}')
      source_mib=$(printf '%s\n' "$metrics" | awk -F= '/^source_mib_s=/{print $2}')
      source_sec=$(printf '%s\n' "$metrics" | awk -F= '/^source_sec=/{print $2}')
      p50=$(printf '%s\n' "$metrics" | awk -F= '/^sink_latency_p50_s=/{print $2}')
      p95=$(printf '%s\n' "$metrics" | awk -F= '/^sink_latency_p95_s=/{print $2}')
      pmax=$(printf '%s\n' "$metrics" | awk -F= '/^sink_latency_max_s=/{print $2}')
      pmin=$(printf '%s\n' "$metrics" | awk -F= '/^sink_latency_min_s=/{print $2}')
      pmean=$(printf '%s\n' "$metrics" | awk -F= '/^sink_latency_mean_s=/{print $2}')
      pstd=$(printf '%s\n' "$metrics" | awk -F= '/^sink_latency_stddev_s=/{print $2}')
      sink_mib_mean=$(printf '%s\n' "$metrics" | awk -F= '/^sink_mib_mean=/{print $2}')
      sink_mib_min=$(printf '%s\n' "$metrics" | awk -F= '/^sink_mib_min=/{print $2}')
      sink_mib_max=$(printf '%s\n' "$metrics" | awk -F= '/^sink_mib_max=/{print $2}')

      success=${success:-0}
      parse_error=${parse_error:-none}
      source_mib=${source_mib:-0}
      source_sec=${source_sec:-0}
      p50=${p50:-0}
      p95=${p95:-0}
      pmax=${pmax:-0}
      pmin=${pmin:-0}
      pmean=${pmean:-0}
      pstd=${pstd:-0}
      sink_mib_mean=${sink_mib_mean:-0}
      sink_mib_min=${sink_mib_min:-0}
      sink_mib_max=${sink_mib_max:-0}

      printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n" \
        "$scenario" "$rep" "$impl" "$bytes" "$sinks" "$success" "$parse_error" "$source_mib" "$source_sec" "$p50" "$p95" "$pmax" "$pmin" "$pmean" "$pstd" "$sink_mib_mean" "$sink_mib_min" "$sink_mib_max" \
        >> "$CSV"

      echo "scenario=$scenario rep=$rep impl=$impl success=$success parse_error=$parse_error source_mib_s=$source_mib p95_s=$p95"
      idx=$((idx + 1))
    done

    rep=$((rep + 1))
  done
done

python3 - "$CSV" "$MD" "$JSON" "$REPEATS" <<'PY'
import csv, json, statistics, sys
csv_path, md_path, json_path, repeats = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
rows = list(csv.DictReader(open(csv_path, newline='')))

for r in rows:
    for k in [
        'scenario','repeat','bytes','sinks','success',
        'source_mib_s','source_sec','sink_latency_p50_s','sink_latency_p95_s',
        'sink_latency_max_s','sink_latency_min_s','sink_latency_mean_s',
        'sink_latency_stddev_s','sink_mib_mean','sink_mib_min','sink_mib_max'
    ]:
        if k in ['scenario','repeat','bytes','sinks','success']:
            r[k] = int(float(r[k]))
        else:
            r[k] = float(r[k])

impls = sorted({r['impl'] for r in rows})
scenarios = sorted({r['scenario'] for r in rows})

def avg(vals):
    return statistics.fmean(vals) if vals else 0.0

def stdev(vals):
    return statistics.pstdev(vals) if len(vals) > 1 else 0.0

scenario_tables = {}
overall = {}

for impl in impls:
    ir = [r for r in rows if r['impl'] == impl]
    ok = [r for r in ir if r['success'] == 1]
    errors = {}
    for r in ir:
        if r['success'] == 1:
            continue
        pe = (r.get('parse_error') or '').strip()
        if pe == '' or pe == 'none':
            pe = 'runtime_fail'
        errors[pe] = errors.get(pe, 0) + 1
    overall[impl] = {
        'runs': len(ir),
        'passes': len(ok),
        'failures': len(ir) - len(ok),
        'error_breakdown': errors,
        'avg_source_mib_s': avg([r['source_mib_s'] for r in ok]),
        'stdev_source_mib_s': stdev([r['source_mib_s'] for r in ok]),
        'avg_source_sec': avg([r['source_sec'] for r in ok]),
        'avg_sink_p95_s': avg([r['sink_latency_p95_s'] for r in ok]),
        'avg_sink_p50_s': avg([r['sink_latency_p50_s'] for r in ok]),
    }

for s in scenarios:
    sr = [r for r in rows if r['scenario'] == s]
    by_impl = {}
    for impl in impls:
        ir = [r for r in sr if r['impl'] == impl]
        ok = [r for r in ir if r['success'] == 1]
        by_impl[impl] = {
            'runs': len(ir),
            'passes': len(ok),
            'avg_source_mib_s': avg([r['source_mib_s'] for r in ok]),
            'stdev_source_mib_s': stdev([r['source_mib_s'] for r in ok]),
            'avg_p95_s': avg([r['sink_latency_p95_s'] for r in ok]),
            'avg_p50_s': avg([r['sink_latency_p50_s'] for r in ok]),
            'bytes': (ir[0]['bytes'] if ir else 0),
            'sinks': (ir[0]['sinks'] if ir else 0),
        }
    scenario_tables[s] = by_impl

ranked = sorted(
    impls,
    key=lambda i: (-overall[i]['avg_source_mib_s'], overall[i]['avg_sink_p95_s'], overall[i]['failures'])
)

summary = {
    'repeats': repeats,
    'rows': rows,
    'overall': overall,
    'scenario_tables': scenario_tables,
    'ranking': ranked,
}
with open(json_path, 'w', encoding='utf-8') as f:
    json.dump(summary, f, indent=2)

lines = []
lines.append('# TCPFan 4-Implementation Benchmark')
lines.append('')
lines.append(f'- Repeats per scenario: `{repeats}`')
lines.append(f'- Total runs: `{len(rows)}`')
lines.append('')

winner = ranked[0] if ranked else 'n/a'
lines.append('## Overall Leader')
lines.append('')
lines.append(f'`{winner}` (ranked by avg source throughput across passing runs; ties by sink p95 and failures)')
lines.append('')

lines.append('## Overall Summary')
lines.append('')
lines.append('| impl | runs | pass | fail | avg source MiB/s | source stdev | avg source s | avg sink p50 s | avg sink p95 s |')
lines.append('|---|---:|---:|---:|---:|---:|---:|---:|---:|')
for impl in ranked:
    o = overall[impl]
    lines.append(
        f"| {impl} | {o['runs']} | {o['passes']} | {o['failures']} | {o['avg_source_mib_s']:.2f} | {o['stdev_source_mib_s']:.2f} | {o['avg_source_sec']:.3f} | {o['avg_sink_p50_s']:.3f} | {o['avg_sink_p95_s']:.3f} |"
    )
lines.append('')

lines.append('## Failure Notes')
lines.append('')
for impl in ranked:
    o = overall[impl]
    if o['failures'] == 0:
        lines.append(f'- `{impl}`: none')
    else:
        bits = ', '.join(f"{k}={v}" for k, v in sorted(o['error_breakdown'].items())) or 'unclassified'
        lines.append(f'- `{impl}`: {o["failures"]} failures ({bits})')
lines.append('')

for s in scenarios:
    by = scenario_tables[s]
    any_impl = next(iter(by.values()))
    lines.append(f"## Scenario {s} ({any_impl['bytes']} bytes, {any_impl['sinks']} sinks)")
    lines.append('')
    lines.append('| impl | pass/runs | avg source MiB/s | source stdev | avg sink p50 s | avg sink p95 s |')
    lines.append('|---|---:|---:|---:|---:|---:|')
    ordered = sorted(impls, key=lambda i: (-by[i]['avg_source_mib_s'], by[i]['avg_p95_s']))
    for impl in ordered:
        d = by[impl]
        lines.append(
            f"| {impl} | {d['passes']}/{d['runs']} | {d['avg_source_mib_s']:.2f} | {d['stdev_source_mib_s']:.2f} | {d['avg_p50_s']:.3f} | {d['avg_p95_s']:.3f} |"
        )
    lines.append('')

lines.append('## Artifacts')
lines.append('')
lines.append(f'- Raw run data: `{csv_path}`')
lines.append(f'- Machine-readable summary: `{json_path}`')
lines.append('- Per-run logs: `benchmark/results/raw/`')
lines.append('')

with open(md_path, 'w', encoding='utf-8') as f:
    f.write('\n'.join(lines) + '\n')

print(md_path)
PY

echo "Wrote: $CSV"
echo "Wrote: $MD"
echo "Wrote: $JSON"

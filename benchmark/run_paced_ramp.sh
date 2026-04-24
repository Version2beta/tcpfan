#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BENCH="$ROOT/benchmark"
RESULTS="$BENCH/results"
mkdir -p "$RESULTS/raw"

REPEATS="${REPEATS:-3}"
RATE_BPS="${RATE_BPS:-10000000}"
BYTES="${BYTES:-16777216}"
UNDER_RUN_LAG_S="${UNDER_RUN_LAG_S:-1.000}"
SINKS_SERIES="${SINKS_SERIES:-16 32 48 64 96 128 160 192 224 256 320 384 512}"
RUN_TIMEOUT_SEC="${RUN_TIMEOUT_SEC:-45}"
RAMP_MODE="${RAMP_MODE:-binary}"

CSV="$RESULTS/paced_ramp.csv"
MD="$RESULTS/paced_ramp.md"
JSON="$RESULTS/paced_ramp_summary.json"

if [ "$RAMP_MODE" != "binary" ] && [ "$RAMP_MODE" != "linear" ]; then
  echo "invalid RAMP_MODE: $RAMP_MODE (expected binary or linear)" >&2
  exit 2
fi

read -r -a SINK_LEVELS <<< "$SINKS_SERIES"
if [ "${#SINK_LEVELS[@]}" -eq 0 ]; then
  echo "SINKS_SERIES must not be empty" >&2
  exit 2
fi

cat > "$CSV" <<CSV
impl,sinks,repeat,bytes,rate_bps,run_timeout_sec,ramp_mode,success,parse_error,source_mib_s,source_sec,sink_latency_p50_s,sink_latency_p95_s,lag_p95_s,under_run
CSV

IMPLS=(
  "claude-c"
  "claude-zig"
  "codex-c"
  "codex-zig"
)

under_run_trigger=$((REPEATS / 2 + 1))
base_port=33000
run_seq=0

impl_idx=0
for impl in "${IMPLS[@]}"; do
  impl_idx=$((impl_idx + 1))

  tested_sinks=()
  tested_under=()

  run_level() {
    local impl_name="$1"
    local sinks="$2"
    local idx

    for idx in "${!tested_sinks[@]}"; do
      if [ "${tested_sinks[$idx]}" -eq "$sinks" ]; then
        echo "${tested_under[$idx]}"
        return
      fi
    done

    local under_count=0
    local rep=1
    while [ "$rep" -le "$REPEATS" ]; do
      run_seq=$((run_seq + 1))
      local src_port=$((base_port + impl_idx * 4000 + run_seq * 2))
      local snk_port=$((src_port + 1))
      local scenario_id=$((9000 + impl_idx * 1000 + run_seq))

      local metrics
      metrics="$(RUN_TIMEOUT_SEC="$RUN_TIMEOUT_SEC" SOURCE_RATE_BPS="$RATE_BPS" "$BENCH/run_impl_once.sh" "$impl_name" "$BYTES" "$sinks" "$src_port" "$snk_port" "$scenario_id" "$rep" 2>/dev/null)"

      local success parse_error source_mib source_sec p50 p95
      success=$(printf '%s\n' "$metrics" | awk -F= '/^success=/{print $2}')
      parse_error=$(printf '%s\n' "$metrics" | awk -F= '/^parse_error=/{print $2}')
      source_mib=$(printf '%s\n' "$metrics" | awk -F= '/^source_mib_s=/{print $2}')
      source_sec=$(printf '%s\n' "$metrics" | awk -F= '/^source_sec=/{print $2}')
      p50=$(printf '%s\n' "$metrics" | awk -F= '/^sink_latency_p50_s=/{print $2}')
      p95=$(printf '%s\n' "$metrics" | awk -F= '/^sink_latency_p95_s=/{print $2}')

      success=${success:-0}
      parse_error=${parse_error:-none}
      source_mib=${source_mib:-0}
      source_sec=${source_sec:-0}
      p50=${p50:-0}
      p95=${p95:-0}

      local lag_p95 under_run
      lag_p95=$(awk -v p95="$p95" -v src="$source_sec" 'BEGIN { printf "%.3f", (p95 - src) }')
      under_run=$(awk -v ok="$success" -v lag="$lag_p95" -v thr="$UNDER_RUN_LAG_S" 'BEGIN { if (ok != 1 || lag > thr) print 1; else print 0 }')

      if [ "$under_run" -eq 1 ]; then
        under_count=$((under_count + 1))
      fi

      printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n" \
        "$impl_name" "$sinks" "$rep" "$BYTES" "$RATE_BPS" "$RUN_TIMEOUT_SEC" "$RAMP_MODE" "$success" "$parse_error" "$source_mib" "$source_sec" "$p50" "$p95" "$lag_p95" "$under_run" \
        >> "$CSV"
      echo "mode=$RAMP_MODE impl=$impl_name sinks=$sinks rep=$rep success=$success source_mib_s=$source_mib source_s=$source_sec p95_s=$p95 lag_p95_s=$lag_p95 under_run=$under_run parse_error=$parse_error" >&2

      rep=$((rep + 1))
    done

    tested_sinks+=("$sinks")
    tested_under+=("$under_count")
    echo "$under_count"
  }

  first_under_sinks=""

  if [ "$RAMP_MODE" = "linear" ]; then
    for sinks in "${SINK_LEVELS[@]}"; do
      under_count="$(run_level "$impl" "$sinks")"
      if [ "$under_count" -ge "$under_run_trigger" ]; then
        first_under_sinks="$sinks"
        break
      fi
    done
  else
    lo=0
    hi=$((${#SINK_LEVELS[@]} - 1))
    first_under_idx=-1

    while [ "$lo" -le "$hi" ]; do
      mid=$(((lo + hi) / 2))
      sinks="${SINK_LEVELS[$mid]}"
      under_count="$(run_level "$impl" "$sinks")"

      if [ "$under_count" -ge "$under_run_trigger" ]; then
        first_under_idx=$mid
        hi=$((mid - 1))
      else
        lo=$((mid + 1))
      fi
    done

    if [ "$first_under_idx" -ge 0 ]; then
      first_under_sinks="${SINK_LEVELS[$first_under_idx]}"
    fi
  fi

  if [ -n "$first_under_sinks" ]; then
    echo "impl=$impl first_under_run_sinks=$first_under_sinks trigger>=${under_run_trigger}/${REPEATS} mode=$RAMP_MODE"
  else
    echo "impl=$impl under_run_not_reached_within_series mode=$RAMP_MODE"
  fi
done

python3 - "$CSV" "$MD" "$JSON" "$REPEATS" "$UNDER_RUN_LAG_S" "$RATE_BPS" "$BYTES" "$SINKS_SERIES" "$RUN_TIMEOUT_SEC" "$RAMP_MODE" <<'PY'
import csv, json, statistics, sys
csv_path, md_path, json_path = sys.argv[1], sys.argv[2], sys.argv[3]
repeats = int(sys.argv[4])
under_run_lag_s = float(sys.argv[5])
rate_bps = int(sys.argv[6])
bytes_n = int(sys.argv[7])
sinks_series = [int(x) for x in sys.argv[8].split()]
run_timeout_sec = int(sys.argv[9])
ramp_mode = sys.argv[10]

rows = list(csv.DictReader(open(csv_path, newline='')))
for r in rows:
    r['sinks'] = int(r['sinks'])
    r['repeat'] = int(r['repeat'])
    r['bytes'] = int(r['bytes'])
    r['rate_bps'] = int(r['rate_bps'])
    r['run_timeout_sec'] = int(r['run_timeout_sec'])
    r['success'] = int(r['success'])
    r['source_mib_s'] = float(r['source_mib_s'])
    r['source_sec'] = float(r['source_sec'])
    r['sink_latency_p50_s'] = float(r['sink_latency_p50_s'])
    r['sink_latency_p95_s'] = float(r['sink_latency_p95_s'])
    r['lag_p95_s'] = float(r['lag_p95_s'])
    r['under_run'] = int(r['under_run'])

impls = sorted({r['impl'] for r in rows})
trigger = repeats // 2 + 1

def avg(vals):
    return statistics.fmean(vals) if vals else 0.0

def stdev(vals):
    return statistics.pstdev(vals) if len(vals) > 1 else 0.0

by_impl = {}
for impl in impls:
    ir = [r for r in rows if r['impl'] == impl]
    sink_levels = sorted({r['sinks'] for r in ir})
    levels = []
    first_under = None
    for s in sink_levels:
        sr = [r for r in ir if r['sinks'] == s]
        under_n = sum(r['under_run'] for r in sr)
        pass_n = sum(1 for r in sr if r['success'] == 1)
        level = {
            'sinks': s,
            'runs': len(sr),
            'passes': pass_n,
            'under_runs': under_n,
            'under_run_rate': under_n / len(sr),
            'avg_source_mib_s': avg([r['source_mib_s'] for r in sr]),
            'stdev_source_mib_s': stdev([r['source_mib_s'] for r in sr]),
            'avg_source_sec': avg([r['source_sec'] for r in sr]),
            'avg_sink_p95_s': avg([r['sink_latency_p95_s'] for r in sr]),
            'avg_lag_p95_s': avg([r['lag_p95_s'] for r in sr]),
        }
        levels.append(level)
        if first_under is None and under_n >= trigger:
            first_under = s

    sustainable = None
    for lvl in levels:
        if first_under is not None and lvl['sinks'] >= first_under:
            break
        sustainable = lvl['sinks']
    if first_under is None and levels:
        sustainable = levels[-1]['sinks']

    by_impl[impl] = {
        'levels': levels,
        'first_under_run_sinks': first_under,
        'sustainable_sinks': sustainable,
        'tested_sink_levels': sink_levels,
        'total_runs': len(ir),
        'total_failures': sum(1 for r in ir if r['success'] != 1),
    }

ranking = sorted(
    impls,
    key=lambda i: (
        -(by_impl[i]['sustainable_sinks'] or 0),
        (by_impl[i]['first_under_run_sinks'] or 10**9),
        by_impl[i]['total_failures'],
        -avg([l['avg_source_mib_s'] for l in by_impl[i]['levels']])
    )
)

summary = {
    'config': {
        'repeats': repeats,
        'rate_bps': rate_bps,
        'bytes': bytes_n,
        'run_timeout_sec': run_timeout_sec,
        'ramp_mode': ramp_mode,
        'under_run_lag_s': under_run_lag_s,
        'under_run_trigger_runs': trigger,
        'sinks_series': sinks_series,
        'definition': f'under_run = (success == 0) OR (sink_p95 - source_sec > {under_run_lag_s:.3f}s)',
    },
    'ranking': ranking,
    'by_impl': by_impl,
    'rows': rows,
}
with open(json_path, 'w', encoding='utf-8') as f:
    json.dump(summary, f, indent=2)

lines = []
lines.append('# Paced Ramp Benchmark')
lines.append('')
lines.append('## Configuration')
lines.append('')
lines.append(f'- Ramp mode: `{ramp_mode}`')
lines.append(f'- Input pacing: `{rate_bps}` bps ({rate_bps/1_000_000:.2f} Mbit/s)')
lines.append(f'- Source payload per run: `{bytes_n}` bytes')
lines.append(f'- Repeats per sink level: `{repeats}`')
lines.append(f'- Per-run timeout: `{run_timeout_sec}` s')
lines.append(f'- Under-run lag threshold: `{under_run_lag_s:.3f}` s')
lines.append(f'- Under-run trigger: `>= {trigger}/{repeats}` runs at a sink level')
lines.append(f'- Sink ramp series: `{ " ".join(str(x) for x in sinks_series) }`')
lines.append('')
lines.append('Under-run definition: `success == 0` OR `(sink_latency_p95_s - source_sec) > threshold`.')
lines.append('')

lines.append('## Ranking (Higher Sustainable Sink Count Is Better)')
lines.append('')
lines.append('| rank | impl | sustainable sinks | first under-run sinks | total failures | tested levels |')
lines.append('|---:|---|---:|---:|---:|---:|')
for idx, impl in enumerate(ranking, start=1):
    d = by_impl[impl]
    su = d['sustainable_sinks'] if d['sustainable_sinks'] is not None else 'n/a'
    fu = d['first_under_run_sinks'] if d['first_under_run_sinks'] is not None else 'not reached'
    lines.append(f'| {idx} | {impl} | {su} | {fu} | {d["total_failures"]} | {len(d["tested_sink_levels"])} |')
lines.append('')

for impl in ranking:
    d = by_impl[impl]
    lines.append(f'## {impl}')
    lines.append('')
    lines.append('| sinks | pass/runs | under/runs | under-run rate | avg source MiB/s | source stdev | avg source s | avg sink p95 s | avg p95 lag s |')
    lines.append('|---:|---:|---:|---:|---:|---:|---:|---:|---:|')
    for lvl in d['levels']:
        lines.append(
            f"| {lvl['sinks']} | {lvl['passes']}/{lvl['runs']} | {lvl['under_runs']}/{lvl['runs']} | {lvl['under_run_rate']:.2f} | {lvl['avg_source_mib_s']:.2f} | {lvl['stdev_source_mib_s']:.2f} | {lvl['avg_source_sec']:.3f} | {lvl['avg_sink_p95_s']:.3f} | {lvl['avg_lag_p95_s']:.3f} |"
        )
    lines.append('')

lines.append('## Artifacts')
lines.append('')
lines.append(f'- CSV: `{csv_path}`')
lines.append(f'- JSON: `{json_path}`')
lines.append('- Raw per-run logs: `benchmark/results/raw/`')
lines.append('')

with open(md_path, 'w', encoding='utf-8') as f:
    f.write('\n'.join(lines) + '\n')

print(md_path)
PY

echo "Wrote: $CSV"
echo "Wrote: $MD"
echo "Wrote: $JSON"

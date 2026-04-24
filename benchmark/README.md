# Benchmark Suite (4 Implementations)

Benchmarks all four binaries in `../bin/`:

- `tcpfan-claude-c`
- `tcpfan-claude-zig`
- `tcpfan-codex-c`
- `tcpfan-codex-zig`

## What It Measures

Per run:

- Source throughput (`MiB/s`)
- Source completion time (`s`)
- Sink completion latency distribution (`p50`, `p95`, `min`, `max`, mean, stddev)
- Sink throughput distribution (mean/min/max)
- Pass/fail correctness (all sinks receive exact expected bytes with zero mismatches)

Aggregated report:

- Overall ranking (throughput-first, latency/failures as tie-breakers)
- Per-scenario averages and variability
- Failure counts per implementation

## Throughput-Max Run

```bash
cd /Users/rob/Development/tcpfan
REPEATS=3 ./benchmark/run_all.sh
```

Outputs:

- `benchmark/results/benchmark.csv`
- `benchmark/results/benchmark.md`
- `benchmark/results/benchmark_summary.json`
- `benchmark/results/raw/*.log`

## Paced Ramp Run (10 Mbit/s Under-Run Detection)

```bash
cd /Users/rob/Development/tcpfan
REPEATS=3 RATE_BPS=10000000 BYTES=16777216 RUN_TIMEOUT_SEC=45 UNDER_RUN_LAG_S=1.000 \
  RAMP_MODE=binary \
  SINKS_SERIES="16 32 48 64 96 128 160 192 224 256 320 384 512" \
  ./benchmark/run_paced_ramp.sh
```

Outputs:

- `benchmark/results/paced_ramp.csv`
- `benchmark/results/paced_ramp.md`
- `benchmark/results/paced_ramp_summary.json`

Spec for cross-agent reproducibility:

- `benchmark/PACED_RAMP_SPEC.md`

## Notes

- Throughput scenarios are defined in `benchmark/run_all.sh`.
- Paced ramp logic is defined in `benchmark/run_paced_ramp.sh`.
- Binary search mode assumes sink under-run is monotonic with sink count.
- Port allocation is automatic and isolated per run.

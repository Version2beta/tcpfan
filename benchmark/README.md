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

## Run

```bash
cd /Users/rob/Development/tcpfan
REPEATS=3 ./benchmark/run_all.sh
```

Outputs:

- `benchmark/results/benchmark.csv`
- `benchmark/results/benchmark.md`
- `benchmark/results/benchmark_summary.json`
- `benchmark/results/raw/*.log`

## Notes

- Scenarios are defined in `benchmark/run_all.sh`.
- Default scenarios:
  - 64 MiB, 4 sinks
  - 128 MiB, 8 sinks
  - 128 MiB, 12 sinks
- Port allocation is automatic and isolated by scenario/repeat/implementation.

# tcpfan

One-to-many TCP relay implementations and a unified benchmark harness.

This repository contains four relay variants exposed through `bin/`:

- `tcpfan-claude-c`
- `tcpfan-claude-zig`
- `tcpfan-codex-c`
- `tcpfan-codex-zig`

## Repository Layout

- `claude/`: Claude-produced implementations and historical benchmark artifacts
- `codex/`: Codex-produced implementations and historical benchmark artifacts
- `bin/`: symlinks to the four active executables
- `benchmark/`: shared benchmark tools and reporting pipeline

## Benchmarking All Four Implementations

From repo root:

```bash
REPEATS=3 ./benchmark/run_all.sh
```

What this does:

- runs all 4 implementations across 3 scenarios
- validates correctness per sink (expected bytes + mismatch checks)
- captures throughput and latency stats
- writes machine-readable and human-readable summaries

Outputs:

- `benchmark/results/benchmark.csv`
- `benchmark/results/benchmark_summary.json`
- `benchmark/results/benchmark.md`
- per-run logs under `benchmark/results/raw/`

## Scenarios

Current default scenarios are defined in `benchmark/run_all.sh`:

1. `64 MiB`, `4 sinks`
2. `128 MiB`, `8 sinks`
3. `128 MiB`, `12 sinks`

## Notes

- `bin/` entries are symlinks by design.
- Benchmark helper binaries are built from `benchmark/Makefile`.
- This repository tracks source code and benchmark tooling; generated caches, local build outputs, and result logs are ignored.

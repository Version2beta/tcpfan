# BENCHMARKS

## Run Metadata

- Run timestamp (UTC): `2026-04-24 01:07:12 UTC`
- Run timestamp (local): `2026-04-23 21:07:12 EDT`
- Host: `Darwin 25.4.0 (arm64)`
- OS: `macOS 26.4.1 (25E253)`
- CPU: `Apple M5` (`10` cores)
- Memory: `17179869184` bytes (`16 GiB`)
- Repo revision: `24226a3` (working tree had local modifications during this run)

## Methodology

- Command: `REPEATS=5 ./benchmark/run_all.sh`
- Implementations:
  - `claude-c`
  - `claude-zig`
  - `codex-c`
  - `codex-zig`
- Scenarios:
  - Scenario 1: `67,108,864` bytes to `4` sinks
  - Scenario 2: `134,217,728` bytes to `8` sinks
  - Scenario 3: `134,217,728` bytes to `12` sinks
- Total runs: `60`
- Success criteria: source delivered full bytes, each sink received full bytes, and no mismatches.
- Harness note: `benchmark/run_impl_once.sh` uses dynamic `--max-sinks` unless `BENCH_MAX_SINKS` is set.

## Executive Summary

- Reliability: all implementations passed all runs (`60/60` successful).
- Throughput leader (overall average): `claude-zig` at `1074.31 MiB/s`.
- Latency leader (overall average sink p95): `claude-c` at `0.374 s`.
- Practical takeaway: `claude-zig` leads aggregate throughput, while `claude-c` is consistently better on sink-tail latency.

## Overall Results

| Rank | impl | pass/fail | avg source MiB/s | source stdev | CV | avg sink p50 s | avg sink p95 s |
|---|---|---:|---:|---:|---:|---:|---:|
| 1 | claude-zig | 15/0 | 1074.31 | 203.82 | 18.97% | 0.377 | 0.379 |
| 2 | claude-c | 15/0 | 1042.16 | 155.65 | 14.94% | 0.372 | 0.374 |
| 3 | codex-c | 15/0 | 1024.16 | 172.42 | 16.84% | 0.410 | 0.413 |
| 4 | codex-zig | 15/0 | 955.02 | 178.01 | 18.64% | 0.386 | 0.387 |

## Per-Scenario Results

### Scenario 1 (`67,108,864` bytes, `4` sinks)

| impl | pass/runs | avg source MiB/s | source stdev | avg sink p50 s | avg sink p95 s |
|---|---:|---:|---:|---:|---:|
| claude-zig | 5/5 | 1267.57 | 22.11 | 0.320 | 0.321 |
| codex-c | 5/5 | 1202.71 | 84.99 | 0.331 | 0.332 |
| claude-c | 5/5 | 1179.33 | 45.15 | 0.319 | 0.320 |
| codex-zig | 5/5 | 1139.13 | 14.03 | 0.320 | 0.320 |

Winner by throughput: `claude-zig`.
Winner by p95 latency: `claude-c` and `codex-zig` (tie at `0.320 s`).

### Scenario 2 (`134,217,728` bytes, `8` sinks)

| impl | pass/runs | avg source MiB/s | source stdev | avg sink p50 s | avg sink p95 s |
|---|---:|---:|---:|---:|---:|
| claude-zig | 5/5 | 1151.36 | 30.18 | 0.381 | 0.384 |
| claude-c | 5/5 | 1113.12 | 46.89 | 0.376 | 0.380 |
| codex-c | 5/5 | 1064.38 | 21.71 | 0.420 | 0.424 |
| codex-zig | 5/5 | 1001.54 | 22.99 | 0.393 | 0.394 |

Winner by throughput: `claude-zig`.
Winner by p95 latency: `claude-c`.

### Scenario 3 (`134,217,728` bytes, `12` sinks)

| impl | pass/runs | avg source MiB/s | source stdev | avg sink p50 s | avg sink p95 s |
|---|---:|---:|---:|---:|---:|
| claude-c | 5/5 | 834.04 | 35.81 | 0.420 | 0.422 |
| codex-c | 5/5 | 805.38 | 11.28 | 0.480 | 0.483 |
| claude-zig | 5/5 | 804.01 | 82.97 | 0.429 | 0.432 |
| codex-zig | 5/5 | 724.39 | 71.28 | 0.445 | 0.448 |

Winner by throughput: `claude-c`.
Winner by p95 latency: `claude-c`.

## Interpretation

- `claude-zig` wins global throughput by a small margin over `claude-c` (`+3.08%`).
- `claude-c` is the latency-strongest implementation overall (best p95 and p50).
- At higher fan-out (`12` sinks), `claude-c` overtakes `claude-zig` on both throughput and tail latency.
- `codex-c` is competitive on throughput but has materially higher sink-tail latency in 8- and 12-sink scenarios.

## Artifacts

- Generated summary doc: `benchmark/results/benchmark.md`
- CSV data: `benchmark/results/benchmark.csv`
- JSON summary: `benchmark/results/benchmark_summary.json`
- Per-run logs: `benchmark/results/raw/`

# Paced Ramp Benchmark Spec (Cross-Agent Reproducible)

This spec defines a deterministic benchmark variant that sends a paced source stream at 10 Mbit/s and uses binary search over sink fan-out levels to find where sink under-run begins.

## Purpose

Measure each `tcpfan` implementation's stability margin under a fixed low-rate input stream by finding the first sink-count where sinks consistently fall behind.

## Implementations Under Test

- `claude-c` (`bin/tcpfan-claude-c`)
- `claude-zig` (`bin/tcpfan-claude-zig`)
- `codex-c` (`bin/tcpfan-codex-c`)
- `codex-zig` (`bin/tcpfan-codex-zig`)

## Harness Files

- `benchmark/source_writer.c` (supports `--rate-bps` pacing)
- `benchmark/sink_reader.c`
- `benchmark/run_impl_once.sh` (single run; supports `SOURCE_RATE_BPS` and `RUN_TIMEOUT_SEC` env)
- `benchmark/run_paced_ramp.sh` (orchestrator; supports `RAMP_MODE=binary|linear`)

## Fixed Definitions

- Ramp mode: `binary`
- Input rate: `10,000,000` bits/s (`10 Mbit/s`, decimal units)
- Source payload per run: `16,777,216` bytes (`16 MiB`)
- Repeats per tested sink level: `3`
- Per-run timeout: `45` s
- Sink levels search space:
  - `16 32 48 64 96 128 160 192 224 256 320 384 512`
- Under-run lag threshold: `1.000` s
- Under-run for a single run is defined as:
  - `success == 0`, OR
  - `(sink_latency_p95_s - source_sec) > 1.000`
- First under-run sink count for an implementation:
  - Smallest tested sink level where under-run occurs in at least `2/3` repeats
- Sustainable sink count:
  - Highest tested sink level below first under-run sink count
  - If no under-run level is reached in the tested search space, sustainable count is the highest tested sink level

## Binary Search Assumption

The binary search assumes under-run behavior is monotonic over sink count (once under-run appears, higher sink counts are not better). This is appropriate for this fan-out stress model.

## Required Command

Run from repo root:

```bash
cd /Users/rob/Development/tcpfan
REPEATS=3 RATE_BPS=10000000 BYTES=16777216 RUN_TIMEOUT_SEC=45 UNDER_RUN_LAG_S=1.000 \
  RAMP_MODE=binary \
  SINKS_SERIES="16 32 48 64 96 128 160 192 224 256 320 384 512" \
  ./benchmark/run_paced_ramp.sh
```

## Output Artifacts

- `benchmark/results/paced_ramp.csv`
- `benchmark/results/paced_ramp.md`
- `benchmark/results/paced_ramp_summary.json`
- Raw logs in `benchmark/results/raw/`

## Reporting Requirements

When comparing results across agents/runs, report at minimum:

- Per implementation:
  - `first_under_run_sinks`
  - `sustainable_sinks`
  - `total_failures`
  - number of tested sink levels
- Per tested sink level:
  - pass/runs
  - under-run/runs
  - avg source MiB/s
  - avg sink p95 latency
  - avg p95 lag (`sink_p95 - source_sec`)

## Determinism Notes

- Use the same host machine and no background workload changes when possible.
- Do not change sink levels, rate, bytes, timeout, threshold, repeats, or ramp mode when aiming for strict comparability.
- Keep binary paths as symlinks under `./bin`.

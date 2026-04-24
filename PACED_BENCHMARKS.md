# Paced Benchmark Results

## Scope

This is the paced-input fan-out benchmark:

- Source rate: `10,000,000 bps` (`10 Mbit/s`)
- Payload per run: `16 MiB`
- Repeats per tested sink level: `3`
- Search method: `binary`
- Under-run threshold: `sink_p95 - source_sec > 1.000s` or any run failure
- Per-run timeout: `45s`

Command used:

```bash
REPEATS=3 RATE_BPS=10000000 BYTES=16777216 RUN_TIMEOUT_SEC=45 UNDER_RUN_LAG_S=1.000 \
  RAMP_MODE=binary \
  SINKS_SERIES="16 32 48 64 96 128 160 192 224 256 320 384 512" \
  ./benchmark/run_paced_ramp.sh
```

## Result Summary

All four implementations converged to the same boundary in this test configuration.

| impl | first under-run sinks | sustainable sinks | tested levels | total failures |
|---|---:|---:|---|---:|
| claude-c | 256 | 224 | 160, 192, 224, 256 | 3 |
| claude-zig | 256 | 224 | 160, 192, 224, 256 | 3 |
| codex-c | 256 | 224 | 160, 192, 224, 256 | 3 |
| codex-zig | 256 | 224 | 160, 192, 224, 256 | 3 |

## Notes

- At `224` sinks, all implementations passed all repeats.
- At `256` sinks, all implementations under-ran all repeats (`3/3`).
- In this paced regime, there is no winner among the four implementations on sustainable sink count.

## Artifacts

- Human summary: `benchmark/results/paced_ramp.md`
- Raw CSV: `benchmark/results/paced_ramp.csv`
- Machine summary: `benchmark/results/paced_ramp_summary.json`
- Repro spec: `benchmark/PACED_RAMP_SPEC.md`

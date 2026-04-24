#!/usr/bin/env bash
# Correctness suite: byte-exact small + medium streams, several sink counts.
set -euo pipefail
WHICH="${1:-c}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

run_one() {
  local bytes="$1" sinks="$2"
  echo "--- correctness: $WHICH bytes=$bytes sinks=$sinks ---"
  if "$ROOT/bench/run.sh" "$WHICH" "$bytes" "$sinks" >/tmp/tcpfan_correct.log 2>&1; then
    echo "OK ($bytes B / $sinks sinks)"
  else
    echo "FAIL ($bytes B / $sinks sinks)"
    tail -n 60 /tmp/tcpfan_correct.log
    exit 1
  fi
}

run_one 65536 1
run_one 1048576 2
run_one $((64*1024*1024)) 4
run_one $((256*1024*1024)) 8

echo "all correctness checks passed for $WHICH"

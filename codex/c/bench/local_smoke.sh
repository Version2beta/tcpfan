#!/usr/bin/env sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
RELAY="$ROOT_DIR/relay"
SRC_PORT="19001"
SNK_PORT="19002"

if [ ! -x "$RELAY" ]; then
  echo "building relay"
  make -C "$ROOT_DIR" >/dev/null
fi

TMP_DIR=$(mktemp -d)
cleanup() {
  if [ -n "${RELAY_PID:-}" ]; then
    kill "$RELAY_PID" >/dev/null 2>&1 || true
    wait "$RELAY_PID" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

"$RELAY" \
  --source-bind 127.0.0.1 --source-port "$SRC_PORT" \
  --sink-bind 127.0.0.1 --sink-port "$SNK_PORT" \
  --stats-interval-ms 0 --log-level error \
  >"$TMP_DIR/relay.log" 2>&1 &
RELAY_PID=$!

python3 - "$SNK_PORT" "$SRC_PORT" "$TMP_DIR" <<'PY'
import os
import socket
import sys
import threading
import time

sink_port = int(sys.argv[1])
source_port = int(sys.argv[2])
out_dir = sys.argv[3]

payload = (b"relay-check-" * 32768) + b"END"
nsinks = 3
results = [b"" for _ in range(nsinks)]
errors = []
ready = threading.Event()
connected = 0
lock = threading.Lock()


def sink_reader(idx: int):
    try:
        deadline = time.time() + 5.0
        while True:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.settimeout(1.0)
            try:
                s.connect(("127.0.0.1", sink_port))
                break
            except OSError:
                s.close()
                if time.time() >= deadline:
                    raise
                time.sleep(0.05)
        global connected
        with lock:
            connected += 1
            if connected == nsinks:
                ready.set()
        chunks = []
        need = len(payload)
        got = 0
        while got < need:
            b = s.recv(min(65536, need - got))
            if not b:
                break
            chunks.append(b)
            got += len(b)
        results[idx] = b"".join(chunks)
        s.close()
    except Exception as e:
        errors.append(f"sink {idx}: {e}")

threads = [threading.Thread(target=sink_reader, args=(i,)) for i in range(nsinks)]
for t in threads:
    t.start()

if not ready.wait(timeout=5):
    raise SystemExit("sinks did not become ready")

time.sleep(0.2)
src = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
src.settimeout(5)
src.connect(("127.0.0.1", source_port))
src.sendall(payload)
src.close()

for t in threads:
    t.join(timeout=5)

if errors:
    raise SystemExit("; ".join(errors))

for i, got in enumerate(results):
    with open(os.path.join(out_dir, f"sink{i}.bin"), "wb") as f:
        f.write(got)
    if got != payload:
        raise SystemExit(f"sink {i} mismatch: expected {len(payload)} got {len(got)}")

print(f"ok: {nsinks} sinks received {len(payload)} bytes")
PY

echo "smoke test passed"

# Competition Rules — tcpfan

Two implementations of the spec at `spec/SPEC.md` compete head-to-head:

- `c/`   — C or C++ implementation (single binary `c/tcpfan`)
- `zig/` — Zig implementation (single binary `zig/zig-out/bin/tcpfan` or `zig/tcpfan`)

## Judging criteria (in order)

1. **Correctness.** Must pass `bench/correctness.sh` (byte-exact fan-out, no
   reverse forwarding, slow-sink isolation, clean shutdown).
2. **Throughput.** Highest sustained source→sinks bytes/sec under
   `bench/throughput.sh` with the standard parameters (4 sinks, 8 GiB stream,
   loopback, default tuning).
3. **Simplicity.** Smaller, more obviously correct code wins ties. Measured
   by SLOC of non-comment, non-blank source.

## Hard rules

- POSIX sockets, single-threaded, nonblocking, `poll()` baseline as per spec.
- No third-party dependencies (libc / libstd only).
- No platform-specific tricks that break the other two target OSes
  (Linux, FreeBSD, macOS) without a portable fallback. `splice`, `kqueue`,
  `epoll` are allowed *as optional fast paths* only.
- The binary must accept the CLI flags below (extras allowed):
  - `--source-port N`        (required)
  - `--sink-port N`          (required)
  - `--max-sinks N`          (default 64)
  - `--read-min N`           (default 4096)
  - `--read-default N`       (default 65536)
  - `--read-max N`           (default 1048576)
  - `--sink-buf N`           (per-sink pending bytes cap, default 8 MiB)
  - `--stats-interval-ms N`  (default 1000, 0 = off)
  - `--log-level quiet|normal|verbose` (default normal)
- Must handle SIGPIPE without dying (ignore or `MSG_NOSIGNAL`/`SO_NOSIGPIPE`).
- Clean shutdown on SIGINT / SIGTERM.
- No data inspection, no buffering for late sinks, no reverse forwarding.

## What "tight" means

- No allocations on the hot path beyond the bounded read buffer and per-sink
  ring buffers sized at startup.
- No threads, no `select()`, no busy loops.
- One file is preferred. Header-only helpers fine. No build systems beyond
  `make` (C) and `zig build` (Zig).

## Benchmark harness

`bench/run.sh <c|zig>` will:

1. Start the binary on chosen ports.
2. Spawn N sink readers (`bench/sink_reader`) that drain bytes and count.
3. Spawn one source writer (`bench/source_writer`) that pushes a fixed
   number of bytes from `/dev/urandom`-seeded data.
4. Wait, then report bytes/sec and verify each sink received the exact
   stream (sha256 prefix match).

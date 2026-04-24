# Reviewer C (adversarial) checklist derived from spec

1. **Session model**
   - Single source listener accepting one connection at a time; rejects others when active. (SPEC §§4.1, 5.1)
   - Sinks stay session-scoped; close when source disconnects unless config overrides. (SPEC §§4.5, 12)
   - No reverse path: sink-originated bytes discarded and never forwarded. (SPEC §§4.3, 5.3)

2. **Forwarding correctness**
   - Each source read is forwarded exactly and in order to every active sink with no modification. (SPEC §§2, 5.2)
   - Partial writes handled properly; sink buffers track pending data and resume writes when ready. (SPEC §§5.2, 6)
   - No buffering of past data for late sinks; sinks see data only from join time onward. (SPEC §§3, 4.2)

3. **Backpressure policy / resource bounds**
   - Bounded per-sink pending bytes; drop sink immediately on overflow and log drop reason. (SPEC §§4.4, 6)
   - No allocations on forwarding hot path beyond read buffer and per-sink ring buffers sized at startup. (SPEC §“tight” section)
   - Memory usage bounded by read buffer and max_sinks; no unbounded data structures. (SPEC §§7.1, 11)
   - Adaptive read logic stays within read-min/default/max and responds to backlog/writes; ensure transitions are monotonic/simple. (SPEC §8)

4. **Event loop / I/O requirements**
   - `poll()` or portable variant drives single-threaded loop; no `select()` or busy loops. (RULES + SPEC §§4.6, 7.7)
   - All sockets nonblocking; reads/writes handle `EAGAIN`. (SPEC §“Safety”)
   - Listener readiness handles new connections; enforces max sinks. (SPEC §§5.1, 13)
   - Proper handling of sink-readable events to discard data (kernel discard where available). (SPEC §§5.3, 13)
   - Source readable/writable events handle EOF/errors, log bytes read/written, signal session state transitions. (SPEC §§12, 13)

5. **Signal and shutdown handling**
   - SIGPIPE ignored or suppressed; writing to closed sink must not crash. (RULES + SPEC §§6, 11)
   - SIGINT/SIGTERM trigger clean shutdown: close listeners, session sockets, exit gracefully. (RULES + SPEC §11)

6. **Logging / observability**
   - Log startup config, source connect/disconnect, sink connect/disconnect/drops, reverse bytes discarded, adaptation changes, periodic stats. (SPEC §§9.1, 9.3)
   - Support `--log-level quiet|normal|verbose`; stats interval respects `--stats-interval-ms`. (RULES + SPEC §§9, 14)

7. **CLI / configuration compliance**
   - Binary accepts required CLI flags (source/sink ports, max sinks, read sizes, sink buf, stats interval, log level). (RULES)
   - Read/write size defaults, sink buf limit, and others named/documented and overrideable from CLI. (SPEC §§7.2, 14)

8. **Portability concerns**
   - Uses only POSIX sockets/APIs; optional fast path for epoll/kqueue/splice guarded by compile-time config. (RULES)
   - Handles platform socket options gracefully; falls back if unsupported. (SPEC §10)
   - Avoids platform-specific blocking behavior; uses `MSG_NOSIGNAL`/`SO_NOSIGPIPE` conditionally. (RULES)

9. **Correctness/throughput threats**
   - Slow sink drop does not stall session or source; drop logic not causing double closes or leaks. (SPEC §§4.4, 6)
   - Reverse traffic never forwarded; discard counters incremented. (SPEC §5.3)
   - Adaptive read size adjustments logged; stats reflect current read length and backlog. (SPEC §§8, 9)

10. **Testing harness expectations**
   - Implementation passes `bench/correctness.sh` by obeying byte-exact fan-out and slow-sink isolation. (RULES)
   - No reliance on features absent from harness (e.g., TLS, non-TCP). (SPEC §3)


# tcpfan-zig

Single-threaded nonblocking TCP one-to-many relay in Zig using a `poll()` event loop.

Behavior highlights:
- One active source connection at a time.
- Multiple sink connections, including pre-session sinks.
- Source bytes are forwarded in-order to all sinks.
- Reverse sink->source traffic is discarded and counted.
- Per-sink pending queue is bounded; sink is dropped on overflow.
- Source session end optionally closes all sinks.
- Adaptive source read size (`read-min/default/max/step`).
- CLI options for bind addresses, ports, poll timeout, and limits.

## Build

```bash
cd /Users/rob/Development/tcpfan2/zig
zig build
```

## Run

```bash
cd /Users/rob/Development/tcpfan2/zig
zig build run -- \
  --source-bind 0.0.0.0 --source-port 5000 \
  --sink-bind 0.0.0.0 --sink-port 5001
```

## Options

```text
--source-bind <IPv4>                 default: 0.0.0.0
--source-port <u16>                  default: 5000
--sink-bind <IPv4>                   default: 0.0.0.0
--sink-port <u16>                    default: 5001
--poll-timeout-ms <i32>              default: 50

--max-sinks <usize>                  default: 1024
--sink-pending-max <usize>           default: 1048576

--read-min <usize>                   default: 1024
--read-default <usize>               default: 16384
--read-max <usize>                   default: 65536
--read-step <usize>                  default: 1024

--stats-interval-ms <u64>            default: 5000 (0 disables)
--close-sinks-on-session-end <bool>  default: true
--log-level <error|warn|info|debug|trace>  default: info
--help
```

## Notes

- `total_out` in stats counts bytes actually written to sink sockets, not bytes merely queued.
- Bind options currently accept IPv4 literals.

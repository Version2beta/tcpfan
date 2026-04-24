# C TCP Relay

Single-threaded, nonblocking one-to-many TCP relay using `poll()`.

## Build

```sh
cd /Users/rob/Development/tcpfan2/c
make
```

## Run

```sh
./relay --source-port 9001 --sink-port 9002
```

The relay accepts:
- one active source connection on `--source-bind/--source-port`
- many sink connections on `--sink-bind/--sink-port`

Source bytes are forwarded unchanged to all connected sinks in-order.

## CLI options

Required:
- `--source-port PORT`
- `--sink-port PORT`

Network/listener:
- `--source-bind ADDR` (default `0.0.0.0`)
- `--sink-bind ADDR` (default `0.0.0.0`)
- `--backlog N` (default `256`)
- `--max-sinks N` (default `4096`)

Buffering/throughput:
- `--sink-pending-bytes N` per-sink bounded pending bytes (default `1048576`)
- `--read-min N` adaptive source read minimum (default `4096`)
- `--read-default N` adaptive source read start size (default `65536`)
- `--read-max N` adaptive source read maximum (default `262144`)
- `--read-step-up N` bounded increase step (default `4096`)
- `--read-step-down N` bounded decrease step (default `4096`)

Loop/observability:
- `--poll-timeout-ms N` event loop poll timeout (default `250`)
- `--stats-interval-ms N` periodic stats logging, `0` disables (default `5000`)
- `--log-level error|warn|info|debug` (default `info`)

Session/sink behavior:
- `--discard-mode auto|kernel|read` (default `auto`)
- `--keep-sinks-on-source-close` (default behavior is to close all sinks when source session ends)

## Behavior summary

- One source at a time; extra source attempts are rejected immediately.
- Sinks can connect before any source and will only receive future data.
- Per-sink pending buffer is bounded; overflow drops that sink immediately.
- Sink->relay data is discarded (`kernel` discard attempted first in `auto` mode).
- `bytes_to_sinks` in stats counts actual bytes successfully written with `send()`.
- `SIGPIPE` is ignored and `MSG_NOSIGNAL`/`SO_NOSIGPIPE` protections are used.
- `SIGINT`/`SIGTERM` trigger clean shutdown.

## Quick local smoke/bench

```sh
cd /Users/rob/Development/tcpfan2/c
./bench/local_smoke.sh
```

The script launches relay + local source/sinks and validates identical payload delivery to all sinks.

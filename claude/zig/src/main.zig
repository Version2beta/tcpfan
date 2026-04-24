// tcpfan - single-source, multi-sink one-way TCP relay (Zig).
//
// Architecture:
//   * Single-threaded poll() event loop.
//   * Two listeners (source, sink). At most one source connection at a time;
//     extra source attempts are accepted then closed.
//   * Each sink owns a fixed-size byte ring buffer (allocated once per slot,
//     reused across rebinds). On source read, we try send() directly first
//     when the ring is empty, then enqueue any leftover and immediately
//     attempt one drain — kernel SNDBUF can free up in microseconds and
//     waiting for the next poll() round-trip is wasted opportunity.
//   * Adaptive read size grows on full reads with empty backlogs and shrinks
//     when any sink shows backlog or drops.
//
// Main is `Init.Minimal` — we skip Zig's heavyweight default `Init` (arena +
// Threaded Io + env_map + preopens) since none of it is used. Allocator is
// libc malloc directly. Argv comes from `init.args.vector` walked manually.
//
// SIGINT/SIGTERM trigger clean shutdown via a flag checked each loop
// iteration; SIGPIPE is ignored (and we additionally pass MSG_NOSIGNAL or
// SO_NOSIGPIPE where supported).

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const c = std.c;

// ----- Defaults -----------------------------------------------------------

const DEFAULT_MAX_SINKS: u32 = 64;
const DEFAULT_READ_MIN: u32 = 4096;
const DEFAULT_READ_DEFAULT: u32 = 65536;
const DEFAULT_READ_MAX: u32 = 1048576;
const DEFAULT_SINK_BUF: u32 = 8 * 1024 * 1024;
const DEFAULT_STATS_INTERVAL_MS: u32 = 1000;
const POLL_TIMEOUT_MS: i32 = 1000;
const ACCEPT_BACKLOG: u32 = 64;

// MSG_NOSIGNAL exists on Linux + BSDs + Darwin (>= 10.13). Use the symbol if
// the std exposes it for this OS, else 0 and rely on SO_NOSIGPIPE / SIGPIPE
// ignore.
const SEND_FLAGS: u32 = if (@hasDecl(c.MSG, "NOSIGNAL")) c.MSG.NOSIGNAL else 0;
const HAS_SO_NOSIGPIPE: bool = @hasDecl(c.SO, "NOSIGPIPE");

// O_NONBLOCK varies wildly by OS (Linux 0o4000, Darwin/BSD 0x4). Hardcode
// per-OS at comptime instead of round-tripping through `c.O` packed-struct
// which transitively pulls every flag table.
const O_NONBLOCK: c_int = switch (builtin.os.tag) {
    .linux => 0o4000,
    .macos, .ios, .tvos, .watchos, .visionos, .driverkit, .freebsd, .netbsd, .openbsd, .dragonfly => 0x4,
    else => @compileError("unsupported OS for O_NONBLOCK"),
};

// ----- Globals (signal handler) ------------------------------------------

// Single-threaded program: a plain `volatile` byte set from the signal
// handler is sufficient. Skips std.atomic intrinsics import.
var g_shutdown: u8 = 0;

fn handleSignal(_: c_int) callconv(.c) void {
    @as(*volatile u8, &g_shutdown).* = 1;
}

// ----- Logging -----------------------------------------------------------

const LogLevel = enum(u8) { quiet = 0, normal = 1, verbose = 2 };
var g_log_level: LogLevel = .normal;

fn logf(level: LogLevel, comptime fmt: []const u8, args: anytype) void {
    if (@intFromEnum(level) > @intFromEnum(g_log_level)) return;
    var buf: [768]u8 = undefined;
    const slice = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = c.write(2, slice.ptr, slice.len);
}

// ----- Config (parsed from CLI) ------------------------------------------

const Config = struct {
    source_port: u16,
    sink_port: u16,
    bind_addr: u32 = 0, // INADDR_ANY
    max_sinks: u32 = DEFAULT_MAX_SINKS,
    read_min: u32 = DEFAULT_READ_MIN,
    read_default: u32 = DEFAULT_READ_DEFAULT,
    read_max: u32 = DEFAULT_READ_MAX,
    sink_buf: u32 = DEFAULT_SINK_BUF,
    stats_interval_ms: u32 = DEFAULT_STATS_INTERVAL_MS,
    log_level: LogLevel = .normal,
};

fn dieUsage() noreturn {
    const msg =
        "usage: tcpfan --source-port N --sink-port N [options]\n" ++
        "  --max-sinks N           (default 64)\n" ++
        "  --read-min N            (default 4096)\n" ++
        "  --read-default N        (default 65536)\n" ++
        "  --read-max N            (default 1048576)\n" ++
        "  --sink-buf N            (default 8388608)\n" ++
        "  --stats-interval-ms N   (default 1000, 0 = off)\n" ++
        "  --log-level LEVEL       (quiet|normal|verbose)\n";
    _ = c.write(2, msg.ptr, msg.len);
    c.exit(2);
}

fn parseU32(s: []const u8) u32 {
    return std.fmt.parseInt(u32, s, 10) catch dieUsage();
}

fn parseConfig(args: []const [:0]const u8) Config {
    var cfg: Config = .{ .source_port = 0, .sink_port = 0 };
    // Table of (flag, target) pairs. Source/sink ports double as required-flag
    // sentinels (port==0 means missing).
    const targets = .{
        .{ "--source-port", &cfg.source_port },        .{ "--sink-port", &cfg.sink_port },
        .{ "--max-sinks", &cfg.max_sinks },            .{ "--read-min", &cfg.read_min },
        .{ "--read-default", &cfg.read_default },      .{ "--read-max", &cfg.read_max },
        .{ "--sink-buf", &cfg.sink_buf },              .{ "--stats-interval-ms", &cfg.stats_interval_ms },
    };
    var i: usize = 1;
    while (i < args.len) : (i += 2) {
        if (i + 1 >= args.len) dieUsage();
        const a = args[i];
        const v = args[i + 1];
        if (std.mem.eql(u8, a, "--log-level")) {
            cfg.log_level = if (std.mem.eql(u8, v, "quiet")) .quiet
                else if (std.mem.eql(u8, v, "normal")) .normal
                else if (std.mem.eql(u8, v, "verbose")) .verbose
                else dieUsage();
            continue;
        }
        var matched = false;
        inline for (targets) |t| {
            if (std.mem.eql(u8, a, t[0])) {
                matched = true;
                t[1].* = @intCast(parseU32(v));
            }
        }
        if (!matched) dieUsage();
    }
    // Ports default to 0 (missing). Other numeric defaults are non-zero, and
    // the parser rejects non-numeric input, so cfg.read_min/sink_buf/max_sinks
    // can't be zero unless the user explicitly passes 0 — caught here.
    if (cfg.source_port == 0 or cfg.sink_port == 0 or
        cfg.read_min == 0 or cfg.read_default < cfg.read_min or
        cfg.read_max < cfg.read_default) dieUsage();
    return cfg;
}

// ----- Sink ring buffer --------------------------------------------------

const Sink = struct {
    fd: c_int = -1,
    buf: []u8 = &.{},
    head: usize = 0,
    len: usize = 0, // bytes pending; capacity = buf.len
    bytes_out: u64 = 0,

    /// Append to the ring. Returns false if it won't fit; caller drops.
    fn enqueue(self: *Sink, data: []const u8) bool {
        if (data.len > self.buf.len - self.len) return false;
        const cap = self.buf.len;
        const tail = (self.head + self.len) % cap;
        const first = @min(data.len, cap - tail);
        @memcpy(self.buf[tail..][0..first], data[0..first]);
        if (first < data.len) {
            @memcpy(self.buf[0 .. data.len - first], data[first..]);
        }
        self.len += data.len;
        return true;
    }

    /// Drain pending bytes to the socket. Returns true on fatal write error
    /// (caller should drop the sink), false otherwise (whether or not bytes
    /// remain in the ring).
    fn drain(self: *Sink) bool {
        while (self.len > 0) {
            const cap = self.buf.len;
            const first = @min(self.len, cap - self.head);
            var sent: isize = undefined;
            if (first == self.len) {
                sent = c.send(self.fd, self.buf.ptr + self.head, first, SEND_FLAGS);
            } else {
                var iov: [2]posix.iovec_const = .{
                    .{ .base = self.buf.ptr + self.head, .len = first },
                    .{ .base = self.buf.ptr, .len = self.len - first },
                };
                // sendmsg honors MSG_NOSIGNAL; writev does not. Use sendmsg
                // for symmetry with the contiguous send() above.
                var mh = std.mem.zeroes(c.msghdr_const);
                mh.iov = &iov;
                mh.iovlen = 2;
                sent = c.sendmsg(self.fd, &mh, SEND_FLAGS);
            }
            if (sent > 0) {
                const n: usize = @intCast(sent);
                self.head = (self.head + n) % cap;
                self.len -= n;
                self.bytes_out += n;
                continue;
            }
            const e = c.errno(sent);
            if (e == .AGAIN or e == .INTR) return false;
            return true;
        }
        return false;
    }
};

// ----- Socket helpers ---------------------------------------------------

fn setNonblock(fd: c_int, on: bool) bool {
    const fl = c.fcntl(fd, c.F.GETFL, @as(c_int, 0));
    if (fl < 0) return false;
    const new: c_int = if (on) (fl | O_NONBLOCK) else (fl & ~O_NONBLOCK);
    return c.fcntl(fd, c.F.SETFL, new) >= 0;
}

/// Set common socket options. Listeners get REUSEADDR; everyone gets
/// NODELAY and NOSIGPIPE-where-supported.
fn setSockOpts(fd: c_int, is_listener: bool) void {
    const one: c_int = 1;
    if (is_listener) {
        _ = c.setsockopt(fd, c.SOL.SOCKET, c.SO.REUSEADDR, &one, @sizeOf(c_int));
        if (@hasDecl(c.SO, "REUSEPORT"))
            _ = c.setsockopt(fd, c.SOL.SOCKET, c.SO.REUSEPORT, &one, @sizeOf(c_int));
    }
    _ = c.setsockopt(fd, c.IPPROTO.TCP, c.TCP.NODELAY, &one, @sizeOf(c_int));
    if (HAS_SO_NOSIGPIPE)
        _ = c.setsockopt(fd, c.SOL.SOCKET, c.SO.NOSIGPIPE, &one, @sizeOf(c_int));
}

fn setSockBuf(fd: c_int, opt: u32, size: c_int) void {
    _ = c.setsockopt(fd, c.SOL.SOCKET, opt, &size, @sizeOf(c_int));
}

fn openListener(port: u16, addr: u32) !c_int {
    const fd = c.socket(c.AF.INET, c.SOCK.STREAM, 0);
    if (fd < 0) return error.Socket;
    errdefer _ = c.close(fd);
    setSockOpts(fd, true);
    if (!setNonblock(fd, true)) return error.Fcntl;
    var sin = std.mem.zeroes(c.sockaddr.in);
    sin.family = c.AF.INET;
    sin.port = std.mem.nativeToBig(u16, port);
    sin.addr = std.mem.nativeToBig(u32, addr);
    if (c.bind(fd, @ptrCast(&sin), @sizeOf(c.sockaddr.in)) < 0) return error.Bind;
    if (c.listen(fd, ACCEPT_BACKLOG) < 0) return error.Listen;
    return fd;
}

fn acceptOne(listener: c_int) ?c_int {
    var addr: c.sockaddr.in = undefined;
    var alen: c.socklen_t = @sizeOf(c.sockaddr.in);
    const fd = c.accept(listener, @ptrCast(&addr), &alen);
    if (fd < 0) return null;
    if (!setNonblock(fd, true)) {
        _ = c.close(fd);
        return null;
    }
    setSockOpts(fd, false);
    return fd;
}

// ----- Time -------------------------------------------------------------

fn nowMs() u64 {
    var ts: posix.timespec = undefined;
    if (c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
}

// ----- Drop reason ------------------------------------------------------

const DropReason = enum(u8) { peer_closed, overflow, write_error };

// ----- Relay state ------------------------------------------------------

const Relay = struct {
    cfg: Config,

    src_listener: c_int,
    snk_listener: c_int,
    src_fd: c_int = -1,

    sinks: []Sink,
    pollfds: []posix.pollfd,
    read_buf: []u8,
    cur_read: u32,
    src_rcvbuf: c_int,

    total_in: u64 = 0,
    total_out: u64 = 0,
    rev_dropped: u64 = 0,
    drops_overflow: u64 = 0,
    drops_error: u64 = 0,
    drops_peer: u64 = 0,
    sinks_accepted: u64 = 0,
    sources_seen: u64 = 0,
    last_stats_ms: u64 = 0,

    fn init(cfg: Config) !Relay {
        // pollfds layout: [0]=src listener, [1]=snk listener, [2]=src conn, [3..]=sinks.
        const sinks = cAlloc(Sink, cfg.max_sinks) orelse return error.OutOfMemory;
        for (sinks) |*s| s.* = .{};
        const pollfds = cAlloc(posix.pollfd, 3 + cfg.max_sinks) orelse return error.OutOfMemory;
        for (pollfds) |*p| p.* = .{ .fd = -1, .events = 0, .revents = 0 };
        const read_buf = cAlloc(u8, cfg.read_max) orelse return error.OutOfMemory;
        const src_listener = try openListener(cfg.source_port, cfg.bind_addr);
        const snk_listener = try openListener(cfg.sink_port, cfg.bind_addr);
        // Source RCVBUF: 4 * read_max, clamped to [4 MiB, 16 MiB]. At line
        // rate a 1 MiB buffer fills in ~150 us so source `read()` returns
        // short more often. C uses the same formula.
        var rcv: c_int = @intCast(@as(u64, cfg.read_max) * 4);
        if (rcv < (1 << 22)) rcv = 1 << 22;
        if (rcv > (1 << 24)) rcv = 1 << 24;
        // Initialize listener slots once; preparePollSet only touches [2..].
        pollfds[0] = .{ .fd = src_listener, .events = c.POLL.IN, .revents = 0 };
        pollfds[1] = .{ .fd = snk_listener, .events = c.POLL.IN, .revents = 0 };
        return .{
            .cfg = cfg,
            .src_listener = src_listener,
            .snk_listener = snk_listener,
            .sinks = sinks,
            .pollfds = pollfds,
            .read_buf = read_buf,
            .cur_read = cfg.read_default,
            .src_rcvbuf = rcv,
            .last_stats_ms = nowMs(),
        };
    }

    fn deinit(self: *Relay) void {
        if (self.src_fd >= 0) _ = c.close(self.src_fd);
        for (self.sinks) |*s| {
            if (s.fd >= 0) _ = c.close(s.fd);
            if (s.buf.len > 0) c.free(s.buf.ptr);
        }
        _ = c.close(self.src_listener); _ = c.close(self.snk_listener);
        c.free(self.sinks.ptr); c.free(self.pollfds.ptr); c.free(self.read_buf.ptr);
    }

    // ---- Sink lifecycle ----

    fn allocSinkSlot(self: *Relay) ?usize {
        for (self.sinks, 0..) |*s, i| if (s.fd < 0) return i;
        return null;
    }

    fn addSink(self: *Relay, fd: c_int) void {
        const slot = self.allocSinkSlot() orelse {
            _ = c.close(fd);
            logf(.normal, "sink rejected (max {})", .{self.cfg.max_sinks});
            return;
        };
        // Allocate ring lazily; reuse on rebind. Stale bytes are safe because
        // enqueue always writes-before-drain reads (len=0 short-circuits drain).
        const buf = if (self.sinks[slot].buf.len > 0) self.sinks[slot].buf
            else (cAlloc(u8, self.cfg.sink_buf) orelse {
                _ = c.close(fd); logf(.normal, "sink alloc failed", .{}); return;
            });
        // Tiny RCVBUF on sinks: we read-and-drop reverse traffic. Large
        // SNDBUF absorbs bursts.
        setSockBuf(fd, c.SO.SNDBUF, @intCast(self.cfg.sink_buf));
        setSockBuf(fd, c.SO.RCVBUF, 4096);
        self.sinks[slot] = .{ .fd = fd, .buf = buf };
        self.sinks_accepted += 1;
        logf(.normal, "sink connect slot={}", .{slot});
    }

    fn dropSink(self: *Relay, slot: usize, reason: DropReason) void {
        const s = &self.sinks[slot];
        if (s.fd < 0) return;
        _ = c.close(s.fd);
        s.fd = -1; s.head = 0; s.len = 0;
        const counter = switch (reason) {
            .peer_closed => &self.drops_peer,
            .overflow    => &self.drops_overflow,
            .write_error => &self.drops_error,
        };
        counter.* += 1;
        const name = switch (reason) { .peer_closed => "peer_closed", .overflow => "overflow", .write_error => "write_error" };
        logf(.normal, "sink drop slot={} reason={s} bytes_out={}", .{ slot, name, s.bytes_out });
    }

    // ---- Source lifecycle ----

    fn setSource(self: *Relay, fd: c_int) void {
        // Source RCVBUF: large buffer so a single read pulls a full burst.
        setSockBuf(fd, c.SO.RCVBUF, self.src_rcvbuf);
        self.src_fd = fd;
        self.sources_seen += 1;
        self.cur_read = self.cfg.read_default;
        logf(.normal, "source connect", .{});
    }

    fn endSession(self: *Relay) void {
        if (self.src_fd >= 0) {
            _ = c.close(self.src_fd);
            self.src_fd = -1;
        }
        // Default: close all sinks at session end. Best-effort blocking flush
        // first so committed bytes reach the receiver before our FIN.
        for (self.sinks, 0..) |*s, i| {
            if (s.fd < 0) continue;
            self.flushSinkBlocking(s);
            self.dropSink(i, .peer_closed);
        }
        logf(.normal, "session end in={} out={}", .{ self.total_in, self.total_out });
    }

    /// Block until the ring is fully flushed or a hard error occurs. Called
    /// only at session end, where the source is gone and short blocking
    /// per-sink is acceptable. We loop on EAGAIN/EINTR; we do NOT bail on
    /// the first short send (would silently drop trailing bytes).
    fn flushSinkBlocking(_: *Relay, s: *Sink) void {
        if (s.len == 0) return;
        if (!setNonblock(s.fd, false)) return;
        defer _ = setNonblock(s.fd, true);
        while (s.len > 0) {
            const cap = s.buf.len;
            const first = @min(s.len, cap - s.head);
            const sent = c.send(s.fd, s.buf.ptr + s.head, first, SEND_FLAGS);
            if (sent > 0) {
                const n: usize = @intCast(sent);
                s.head = (s.head + n) % cap;
                s.len -= n;
                s.bytes_out += n;
                continue;
            }
            const e = c.errno(sent);
            if (e == .AGAIN or e == .INTR) continue;
            logf(.normal, "flush hard error errno={}", .{@intFromEnum(e)});
            return;
        }
    }

    // ---- Adaptation ----

    fn adapt(self: *Relay, last_read: usize, any_backlog: bool, any_drop: bool) void {
        const next: u32 = if (any_drop or any_backlog)
            @max(self.cfg.read_min, self.cur_read / 2)
        else if (last_read == self.cur_read and self.cur_read < self.cfg.read_max)
            @min(self.cfg.read_max, self.cur_read * 2)
        else
            self.cur_read;
        if (next != self.cur_read) {
            logf(.verbose, "read size {} -> {}", .{ self.cur_read, next });
            self.cur_read = next;
        }
    }

    // ---- Main loop ----

    fn run(self: *Relay) void {
        logf(.normal, "tcpfan up: src=:{} sink=:{} max_sinks={} sink_buf={} read[{},{},{}] msg_nosignal={} so_nosigpipe={}", .{
            self.cfg.source_port, self.cfg.sink_port, self.cfg.max_sinks, self.cfg.sink_buf,
            self.cfg.read_min, self.cfg.read_default, self.cfg.read_max,
            SEND_FLAGS != 0, HAS_SO_NOSIGPIPE,
        });

        while (@as(*volatile u8, &g_shutdown).* == 0) {
            self.preparePollSet();

            const timeout: i32 = if (self.cfg.stats_interval_ms > 0)
                @min(POLL_TIMEOUT_MS, @as(i32, @intCast(self.cfg.stats_interval_ms)))
            else
                POLL_TIMEOUT_MS;

            const pr = c.poll(self.pollfds.ptr, @intCast(self.pollfds.len), timeout);
            if (pr < 0) {
                if (c.errno(pr) == .INTR) continue;
                break;
            }

            if ((self.pollfds[0].revents & (c.POLL.IN | c.POLL.ERR)) != 0)
                self.handleSourceListener();
            if ((self.pollfds[1].revents & (c.POLL.IN | c.POLL.ERR)) != 0)
                self.handleSinkListener();

            // Drain sink writes / reverse reads first so the ring has space
            // for fanout below.
            self.serviceSinks();

            if (self.src_fd >= 0) {
                const r = self.pollfds[2].revents;
                if ((r & c.POLL.IN) != 0) self.handleSourceRead();
                if (self.src_fd >= 0 and (r & (c.POLL.HUP | c.POLL.ERR | c.POLL.NVAL)) != 0) {
                    if ((r & c.POLL.IN) == 0) self.endSession();
                }
            }

            self.maybeStats();
        }

        logf(.normal, "shutdown", .{});
        if (self.src_fd >= 0) self.endSession();
    }

    /// Refresh pollfds for source + sink slots only. Listener slots are
    /// initialized once in `init` and only their `revents` is reset here.
    fn preparePollSet(self: *Relay) void {
        self.pollfds[0].revents = 0;
        self.pollfds[1].revents = 0;
        // Source: never throttled (spec 4.4: drop slow sinks, not source).
        const src_up = self.src_fd >= 0;
        self.pollfds[2] = .{ .fd = if (src_up) self.src_fd else -1, .events = if (src_up) c.POLL.IN else 0, .revents = 0 };
        for (self.sinks, 0..) |*s, i| {
            const ev: i16 = if (s.fd < 0) 0 else c.POLL.IN | (if (s.len > 0) @as(i16, c.POLL.OUT) else 0);
            self.pollfds[3 + i] = .{ .fd = s.fd, .events = ev, .revents = 0 };
        }
    }

    fn handleSourceListener(self: *Relay) void {
        while (true) {
            const fd = acceptOne(self.src_listener) orelse return;
            if (self.src_fd >= 0) {
                _ = c.close(fd);
                logf(.normal, "extra source rejected", .{});
                continue;
            }
            self.setSource(fd);
        }
    }

    fn handleSinkListener(self: *Relay) void {
        while (true) {
            const fd = acceptOne(self.snk_listener) orelse return;
            self.addSink(fd);
        }
    }

    fn serviceSinks(self: *Relay) void {
        for (self.sinks, 0..) |*s, i| {
            if (s.fd < 0) continue;
            const r = self.pollfds[3 + i].revents;

            // Reverse traffic: read & discard. Cap at one read per tick — a
            // long loop here lets a chatty sink (e.g., `nc -z` probe) starve
            // the rest of the loop.
            if ((r & c.POLL.IN) != 0) {
                var trash: [4096]u8 = undefined;
                const n = c.read(s.fd, &trash, trash.len);
                if (n > 0) {
                    self.rev_dropped += @intCast(n);
                } else if (n == 0) {
                    self.dropSink(i, .peer_closed);
                    continue;
                } else {
                    const e = c.errno(n);
                    if (e != .AGAIN and e != .INTR) {
                        self.dropSink(i, .write_error);
                        continue;
                    }
                }
            }

            // Write side.
            if ((r & c.POLL.OUT) != 0 or s.len > 0) {
                if (s.drain()) {
                    self.dropSink(i, .write_error);
                    continue;
                }
            }

            // Close on HUP after the final drain attempt, regardless of
            // whether the ring is empty: the peer is gone, more sends will
            // fail, and pending bytes won't be delivered anyway.
            if ((r & (c.POLL.HUP | c.POLL.ERR | c.POLL.NVAL)) != 0)
                self.dropSink(i, .peer_closed);
        }
    }

    fn handleSourceRead(self: *Relay) void {
        const want = self.cur_read;
        var last_read: usize = 0;
        var any_drop = false;

        const n = c.read(self.src_fd, self.read_buf.ptr, want);
        if (n > 0) {
            const nbytes: usize = @intCast(n);
            self.total_in += nbytes;
            last_read = nbytes;
            const data = self.read_buf[0..nbytes];

            for (self.sinks, 0..) |*s, i| {
                if (s.fd < 0) continue;
                var off: usize = 0;
                // Empty-ring fast path: try to push directly to the kernel
                // with no memcpy. On loopback with healthy receivers the
                // kernel typically swallows the whole chunk, saving one
                // copy per byte per sink. Falls back to enqueue on partial.
                if (s.len == 0) {
                    const sent = c.send(s.fd, data.ptr, data.len, SEND_FLAGS);
                    if (sent > 0) {
                        off = @intCast(sent);
                        s.bytes_out += off;
                        self.total_out += off;
                    } else if (sent == 0) {
                        any_drop = true;
                        self.dropSink(i, .peer_closed);
                        continue;
                    } else {
                        const e = c.errno(sent);
                        if (e != .AGAIN and e != .INTR) {
                            any_drop = true;
                            self.dropSink(i, .write_error);
                            continue;
                        }
                    }
                }
                if (off < data.len) {
                    // Either ring was non-empty (so a fresh send would
                    // bypass earlier bytes), or kernel partial-sent (so the
                    // socket is full). Enqueue the leftover; POLLOUT drains.
                    if (!s.enqueue(data[off..])) {
                        any_drop = true;
                        self.dropSink(i, .overflow);
                        continue;
                    }
                    self.total_out += data.len - off;
                    // Immediate drain after enqueue: kernel SNDBUF can free
                    // up in microseconds. Without this, once any partial
                    // write happens, the ring stays non-empty until the next
                    // POLLOUT round-trip — every subsequent read enqueues
                    // (and copies) instead of taking the fast path. Mirrors
                    // C's sink_flush after ring_push.
                    if (s.drain()) {
                        any_drop = true;
                        self.dropSink(i, .write_error);
                    }
                }
            }
        } else if (n == 0) {
            self.endSession();
            return;
        } else {
            const e = c.errno(n);
            if (e != .AGAIN and e != .INTR) {
                logf(.normal, "source read error errno={}", .{@intFromEnum(e)});
                self.endSession();
                return;
            }
        }

        // Heavy backlog = any sink past half its ring. A few-KB partial-write
        // tail that drains on the next poll round-trip is normal at line rate
        // and isn't worth shrinking for (causes oscillation).
        var heavy_backlog = false;
        for (self.sinks) |*s| {
            if (s.fd >= 0 and s.len > s.buf.len / 2) { heavy_backlog = true; break; }
        }
        self.adapt(last_read, heavy_backlog, any_drop);
    }

    fn maybeStats(self: *Relay) void {
        if (self.cfg.stats_interval_ms == 0) return;
        const now = nowMs();
        if (now - self.last_stats_ms < self.cfg.stats_interval_ms) return;
        self.last_stats_ms = now;

        var sink_count: u32 = 0;
        var pending_total: u64 = 0;
        for (self.sinks) |*s| {
            if (s.fd >= 0) {
                sink_count += 1;
                pending_total += s.len;
            }
        }
        logf(.normal, "stats active={} sinks={} in={} out={} pending={} drops_overflow={} drops_error={} drops_peer={} rev_dropped={} read_size={}", .{
            self.src_fd >= 0, sink_count,
            self.total_in, self.total_out, pending_total,
            self.drops_overflow, self.drops_error, self.drops_peer,
            self.rev_dropped, self.cur_read,
        });
    }
};

// ----- main --------------------------------------------------------------

/// libc malloc cast to `?[]T`. Single allocation per buffer at startup; no
/// alloc on hot path. Returns null on OOM (which we map to error.OutOfMemory).
fn cAlloc(comptime T: type, n: usize) ?[]T {
    const p = c.malloc(n * @sizeOf(T)) orelse return null;
    return @as([*]T, @ptrCast(@alignCast(p)))[0..n];
}


pub fn main(init: std.process.Init.Minimal) !void {
    // Walk argv directly. `init.args.vector` is `[]const [*:0]const u8` on
    // Posix; sliceTo gives us the per-arg length. Avoids std.process.Args
    // .Iterator (which on Wasi/Windows pulls heavyweight machinery).
    var arg_buf: [64][:0]const u8 = undefined;
    const vec = init.args.vector;
    if (vec.len > arg_buf.len) dieUsage();
    for (vec, 0..) |a, i| arg_buf[i] = std.mem.sliceTo(a, 0);
    const cfg = parseConfig(arg_buf[0..vec.len]);
    g_log_level = cfg.log_level;

    // Signal setup. We use posix.Sigaction directly; the wrappers cost zero.
    const empty: posix.sigset_t = std.mem.zeroes(posix.sigset_t);
    const sa_int: posix.Sigaction = .{ .handler = .{ .handler = @ptrCast(&handleSignal) }, .mask = empty, .flags = 0 };
    const sa_ign: posix.Sigaction = .{ .handler = .{ .handler = posix.SIG.IGN }, .mask = empty, .flags = 0 };
    posix.sigaction(.INT, &sa_int, null);
    posix.sigaction(.TERM, &sa_int, null);
    posix.sigaction(.PIPE, &sa_ign, null); // belt-and-braces for MSG_NOSIGNAL/SO_NOSIGPIPE

    var relay = try Relay.init(cfg);
    defer relay.deinit();
    relay.run();
}

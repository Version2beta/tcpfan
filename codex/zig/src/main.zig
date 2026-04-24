const std = @import("std");

const Allocator = std.mem.Allocator;

const CliError = error{
    HelpRequested,
    MissingValue,
    InvalidOption,
    InvalidValue,
};

const LogLevel = enum(u8) {
    err = 0,
    warn = 1,
    info = 2,
    debug = 3,
    trace = 4,
};

const Config = struct {
    source_bind: []const u8 = "0.0.0.0",
    source_port: u16 = 5000,
    sink_bind: []const u8 = "0.0.0.0",
    sink_port: u16 = 5001,
    poll_timeout_ms: i32 = 50,

    max_sinks: usize = 1024,
    sink_pending_max: usize = 1 * 1024 * 1024,

    read_min: usize = 1024,
    read_default: usize = 16 * 1024,
    read_max: usize = 64 * 1024,
    read_step: usize = 1024,

    stats_interval_ms: u64 = 5000,
    close_sinks_on_session_end: bool = true,
    log_level: LogLevel = .info,
};

const Stats = struct {
    sources_accepted: u64 = 0,
    sources_rejected: u64 = 0,
    source_sessions_ended: u64 = 0,

    sinks_accepted: u64 = 0,
    sinks_rejected_capacity: u64 = 0,
    sinks_dropped_overflow: u64 = 0,
    sinks_dropped_io: u64 = 0,

    source_in: u64 = 0,
    total_out: u64 = 0,
    sink_reverse_discarded: u64 = 0,
};

const Sink = struct {
    fd: std.posix.fd_t,
    pending: std.ArrayList(u8) = .empty,
    head: usize = 0,

    fn queued(self: *const Sink) usize {
        return self.pending.items.len - self.head;
    }

    fn deinit(self: *Sink, gpa: Allocator) void {
        self.pending.deinit(gpa);
    }
};

const DropReason = enum {
    io,
    overflow,
    session_end,
};

const Relay = struct {
    gpa: Allocator,
    cfg: Config,

    source_listener_fd: std.posix.fd_t,
    sink_listener_fd: std.posix.fd_t,
    source_fd: ?std.posix.fd_t = null,

    sinks: std.ArrayList(Sink) = .empty,
    pollfds: std.ArrayList(std.posix.pollfd) = .empty,

    read_buf: []u8,
    current_read_size: usize,
    send_flags: u32,

    stats: Stats = .{},
    last_stats_ms: u64,

    fn init(gpa: Allocator, cfg: Config) !Relay {
        const source_listener_fd = try createListener(cfg.source_bind, cfg.source_port);
        errdefer closeFd(source_listener_fd);

        const sink_listener_fd = try createListener(cfg.sink_bind, cfg.sink_port);
        errdefer closeFd(sink_listener_fd);

        const read_buf = try gpa.alloc(u8, cfg.read_max);
        errdefer gpa.free(read_buf);

        const send_flags: u32 = if (@hasDecl(std.posix.MSG, "NOSIGNAL"))
            @as(u32, @intCast(std.posix.MSG.NOSIGNAL))
        else
            0;

        return .{
            .gpa = gpa,
            .cfg = cfg,
            .source_listener_fd = source_listener_fd,
            .sink_listener_fd = sink_listener_fd,
            .read_buf = read_buf,
            .current_read_size = cfg.read_default,
            .send_flags = send_flags,
            .last_stats_ms = nowMs(),
        };
    }

    fn deinit(self: *Relay) void {
        self.endSession();
        self.dropAllSinks(.session_end);
        closeFd(self.source_listener_fd);
        closeFd(self.sink_listener_fd);
        self.pollfds.deinit(self.gpa);
        self.sinks.deinit(self.gpa);
        self.gpa.free(self.read_buf);
    }

    fn run(self: *Relay) !void {
        while (true) {
            const source_present = self.source_fd != null;
            const sink_count_snapshot = self.sinks.items.len;

            try self.buildPollfds(source_present, sink_count_snapshot);
            _ = try std.posix.poll(self.pollfds.items, self.cfg.poll_timeout_ms);

            const in_mask: i32 = @intCast(std.posix.POLL.IN);
            const out_mask: i32 = @intCast(std.posix.POLL.OUT);
            const err_mask: i32 = @intCast(std.posix.POLL.ERR);
            const hup_mask: i32 = @intCast(std.posix.POLL.HUP);
            const nval_mask: i32 = @intCast(std.posix.POLL.NVAL);

            var accepted_any = false;
            if (hasPollEvent(self.pollfds.items[0].revents, std.posix.POLL.IN)) {
                self.acceptSources();
                accepted_any = true;
            }
            if (hasPollEvent(self.pollfds.items[1].revents, std.posix.POLL.IN)) {
                self.acceptSinks();
                accepted_any = true;
            }
            if (accepted_any) {
                self.maybeLogStats();
                continue;
            }

            if (source_present and self.source_fd != null) {
                const source_poll_idx: usize = 2;
                const source_revents: i32 = self.pollfds.items[source_poll_idx].revents;

                if ((source_revents & in_mask) != 0) {
                    self.readFromSource();
                } else if ((source_revents & (err_mask | hup_mask | nval_mask)) != 0) {
                    self.log(.info, "source ended (poll err/hup)", .{});
                    self.endSession();
                    if (self.cfg.close_sinks_on_session_end) {
                        self.flushSinksOnSessionEnd(2000);
                        self.dropAllSinks(.session_end);
                    }
                }
            }

            if (sink_count_snapshot > 0) {
                const sink_poll_base: usize = if (source_present) 3 else 2;
                var idx: usize = sink_count_snapshot;
                while (idx > 0) {
                    idx -= 1;

                    if (idx >= self.sinks.items.len) {
                        continue;
                    }

                    const poll_idx = sink_poll_base + idx;
                    if (poll_idx >= self.pollfds.items.len) {
                        continue;
                    }

                    const sink_fd_snapshot = self.pollfds.items[poll_idx].fd;
                    const revents: i32 = self.pollfds.items[poll_idx].revents;
                    if (revents == 0) {
                        continue;
                    }

                    if (self.sinks.items[idx].fd != sink_fd_snapshot) {
                        continue;
                    }

                    if ((revents & (err_mask | hup_mask | nval_mask)) != 0) {
                        self.dropSinkAt(idx, .io);
                        continue;
                    }

                    if ((revents & in_mask) != 0) {
                        if (!self.discardSinkInput(idx)) {
                            continue;
                        }
                    }

                    if ((revents & out_mask) != 0) {
                        _ = self.flushSink(idx);
                    }
                }
            }

            self.maybeLogStats();
        }
    }

    fn buildPollfds(self: *Relay, source_present: bool, sink_count_snapshot: usize) !void {
        self.pollfds.clearRetainingCapacity();

        const in_mask: i16 = @intCast(std.posix.POLL.IN);
        const out_mask: i16 = @intCast(std.posix.POLL.OUT);

        try self.pollfds.append(self.gpa, .{
            .fd = self.source_listener_fd,
            .events = in_mask,
            .revents = 0,
        });
        try self.pollfds.append(self.gpa, .{
            .fd = self.sink_listener_fd,
            .events = in_mask,
            .revents = 0,
        });

        if (source_present) {
            try self.pollfds.append(self.gpa, .{
                .fd = self.source_fd.?,
                .events = in_mask,
                .revents = 0,
            });
        }

        var i: usize = 0;
        while (i < sink_count_snapshot) : (i += 1) {
            const sink = self.sinks.items[i];
            var events: i16 = in_mask;
            if (sink.queued() > 0) {
                events |= out_mask;
            }
            try self.pollfds.append(self.gpa, .{
                .fd = sink.fd,
                .events = events,
                .revents = 0,
            });
        }
    }

    fn readFromSource(self: *Relay) void {
        const source_fd = self.source_fd orelse return;
        const req = self.currentReadSizeClamped();
        const rc = std.c.recv(source_fd, self.read_buf.ptr, req, 0);
        if (rc > 0) {
            const n: usize = @intCast(rc);
            self.stats.source_in += n;
            self.broadcast(self.read_buf[0..n]);
            self.adaptReadSize(req, n);
            return;
        }

        if (rc == 0) {
            self.log(.info, "source disconnected", .{});
            self.endSession();
            if (self.cfg.close_sinks_on_session_end) {
                self.flushSinksOnSessionEnd(2000);
                self.dropAllSinks(.session_end);
            }
            return;
        }

        const err = std.posix.errno(rc);
        if (err == .INTR or isWouldBlock(err)) {
            return;
        }

        self.log(.warn, "source recv error: {s}", .{@tagName(err)});
        self.endSession();
        if (self.cfg.close_sinks_on_session_end) {
            self.flushSinksOnSessionEnd(2000);
            self.dropAllSinks(.session_end);
        }
    }

    fn adaptReadSize(self: *Relay, requested: usize, actual: usize) void {
        if (actual == requested and self.current_read_size < self.cfg.read_max) {
            const grown = self.current_read_size + self.cfg.read_step;
            self.current_read_size = @min(grown, self.cfg.read_max);
            return;
        }

        if (actual * 2 < requested and self.current_read_size > self.cfg.read_min) {
            const shrunk = if (self.current_read_size > self.cfg.read_step)
                self.current_read_size - self.cfg.read_step
            else
                self.cfg.read_min;
            self.current_read_size = @max(shrunk, self.cfg.read_min);
        }
    }

    fn currentReadSizeClamped(self: *Relay) usize {
        const upper = @min(self.current_read_size, self.cfg.read_max);
        return @max(upper, self.cfg.read_min);
    }

    fn broadcast(self: *Relay, data: []const u8) void {
        var idx: usize = self.sinks.items.len;
        while (idx > 0) {
            idx -= 1;

            if (idx >= self.sinks.items.len) {
                continue;
            }

            var sink = &self.sinks.items[idx];
            const queued = sink.queued();
            if (queued + data.len > self.cfg.sink_pending_max) {
                self.dropSinkAt(idx, .overflow);
                continue;
            }

            self.compactPendingIfUseful(sink, data.len);

            sink.pending.appendSlice(self.gpa, data) catch {
                self.dropSinkAt(idx, .io);
                continue;
            };
        }
    }

    fn compactPendingIfUseful(self: *Relay, sink: *Sink, incoming: usize) void {
        if (sink.head == 0) return;

        const remain = sink.queued();
        if (!(sink.head >= sink.pending.items.len / 2 or sink.pending.items.len + incoming > self.cfg.sink_pending_max)) {
            return;
        }

        if (remain > 0) {
            std.mem.copyForwards(u8, sink.pending.items[0..remain], sink.pending.items[sink.head..]);
        }
        sink.pending.shrinkRetainingCapacity(remain);
        sink.head = 0;
    }

    fn flushSink(self: *Relay, sink_idx: usize) bool {
        if (sink_idx >= self.sinks.items.len) return false;

        var sink = &self.sinks.items[sink_idx];
        while (sink.head < sink.pending.items.len) {
            const chunk = sink.pending.items[sink.head..];
            const rc = std.c.send(sink.fd, chunk.ptr, chunk.len, self.send_flags);
            if (rc > 0) {
                const n: usize = @intCast(rc);
                sink.head += n;
                self.stats.total_out += n;

                if (sink.head == sink.pending.items.len) {
                    sink.pending.clearRetainingCapacity();
                    sink.head = 0;
                }
                continue;
            }

            const err = std.posix.errno(rc);
            if (err == .INTR) {
                continue;
            }
            if (isWouldBlock(err)) {
                return true;
            }

            self.dropSinkAt(sink_idx, .io);
            return false;
        }

        return true;
    }

    fn discardSinkInput(self: *Relay, sink_idx: usize) bool {
        if (sink_idx >= self.sinks.items.len) return false;
        var scratch: [4096]u8 = undefined;

        while (true) {
            const sink_fd = self.sinks.items[sink_idx].fd;
            const rc = std.c.recv(sink_fd, scratch[0..].ptr, scratch.len, 0);

            if (rc > 0) {
                self.stats.sink_reverse_discarded += @intCast(rc);
                continue;
            }

            if (rc == 0) {
                self.dropSinkAt(sink_idx, .io);
                return false;
            }

            const err = std.posix.errno(rc);
            if (err == .INTR) {
                continue;
            }
            if (isWouldBlock(err)) {
                return true;
            }

            self.dropSinkAt(sink_idx, .io);
            return false;
        }
    }

    fn acceptSources(self: *Relay) void {
        while (true) {
            const fd = std.c.accept(self.source_listener_fd, null, null);
            if (fd >= 0) {
                if (self.source_fd != null) {
                    self.stats.sources_rejected += 1;
                    closeFd(fd);
                    continue;
                }

                if (setSocketNonBlocking(fd)) {
                    self.source_fd = fd;
                    self.current_read_size = self.cfg.read_default;
                    self.stats.sources_accepted += 1;
                    self.log(.info, "source connected", .{});
                } else |err| {
                    self.log(.warn, "failed to configure source socket: {s}", .{@errorName(err)});
                    closeFd(fd);
                }
                continue;
            }

            const err = std.posix.errno(fd);
            if (err == .INTR) continue;
            if (isWouldBlock(err)) return;

            self.log(.warn, "accept(source) error: {s}", .{@tagName(err)});
            return;
        }
    }

    fn acceptSinks(self: *Relay) void {
        while (true) {
            const fd = std.c.accept(self.sink_listener_fd, null, null);
            if (fd >= 0) {
                if (self.sinks.items.len >= self.cfg.max_sinks) {
                    self.stats.sinks_rejected_capacity += 1;
                    closeFd(fd);
                    continue;
                }

                if (setSocketNonBlocking(fd)) {
                    if (@hasDecl(std.posix.SO, "NOSIGPIPE")) {
                        setSockOptInt(fd, std.posix.SOL.SOCKET, std.posix.SO.NOSIGPIPE, 1) catch {};
                    }

                    self.sinks.append(self.gpa, .{ .fd = fd }) catch {
                        closeFd(fd);
                        continue;
                    };
                    self.stats.sinks_accepted += 1;
                    self.log(.info, "sink connected count={}", .{self.sinks.items.len});
                } else |err| {
                    self.log(.warn, "failed to configure sink socket: {s}", .{@errorName(err)});
                    closeFd(fd);
                }
                continue;
            }

            const err = std.posix.errno(fd);
            if (err == .INTR) continue;
            if (isWouldBlock(err)) return;

            self.log(.warn, "accept(sink) error: {s}", .{@tagName(err)});
            return;
        }
    }

    fn dropSinkAt(self: *Relay, sink_idx: usize, reason: DropReason) void {
        if (sink_idx >= self.sinks.items.len) return;

        var sink = self.sinks.swapRemove(sink_idx);
        closeFd(sink.fd);
        sink.deinit(self.gpa);

        switch (reason) {
            .io => self.stats.sinks_dropped_io += 1,
            .overflow => self.stats.sinks_dropped_overflow += 1,
            .session_end => {},
        }
    }

    fn dropAllSinks(self: *Relay, reason: DropReason) void {
        while (self.sinks.items.len > 0) {
            self.dropSinkAt(self.sinks.items.len - 1, reason);
        }
    }

    fn flushSinksOnSessionEnd(self: *Relay, max_wait_ms: u64) void {
        const start = nowMs();
        while (nowMs() - start < max_wait_ms) {
            var pending_any = false;
            var idx: usize = 0;
            while (idx < self.sinks.items.len) : (idx += 1) {
                if (idx >= self.sinks.items.len) break;
                if (self.sinks.items[idx].queued() == 0) continue;
                pending_any = true;
                _ = self.flushSink(idx);
            }
            if (!pending_any) return;
            const req = std.c.timespec{
                .sec = 0,
                .nsec = 1_000_000,
            };
            _ = std.c.nanosleep(&req, null);
        }
    }

    fn endSession(self: *Relay) void {
        const fd = self.source_fd orelse return;
        closeFd(fd);
        self.source_fd = null;
        self.current_read_size = self.cfg.read_default;
        self.stats.source_sessions_ended += 1;
    }

    fn maybeLogStats(self: *Relay) void {
        if (self.cfg.stats_interval_ms == 0) return;

        const now = nowMs();
        if (now - self.last_stats_ms < self.cfg.stats_interval_ms) return;
        self.last_stats_ms = now;

        var queued_total: u64 = 0;
        for (self.sinks.items) |sink| {
            queued_total += sink.queued();
        }

        self.log(
            .info,
            "stats src_active={} sinks={} src_in={} total_out={} reverse_drop={} queued={} src_acc={} src_rej={} sink_acc={} sink_rej={} sink_drop_io={} sink_drop_overflow={}",
            .{
                self.source_fd != null,
                self.sinks.items.len,
                self.stats.source_in,
                self.stats.total_out,
                self.stats.sink_reverse_discarded,
                queued_total,
                self.stats.sources_accepted,
                self.stats.sources_rejected,
                self.stats.sinks_accepted,
                self.stats.sinks_rejected_capacity,
                self.stats.sinks_dropped_io,
                self.stats.sinks_dropped_overflow,
            },
        );
    }

    fn log(self: *const Relay, level: LogLevel, comptime fmt: []const u8, args: anytype) void {
        if (@intFromEnum(level) > @intFromEnum(self.cfg.log_level)) {
            return;
        }
        std.debug.print("[{s}] ", .{@tagName(level)});
        std.debug.print(fmt ++ "\n", args);
    }
};

pub fn main(init: std.process.Init) !void {
    var arena_allocator = init.arena;
    const arena = arena_allocator.allocator();

    const args = try init.minimal.args.toSlice(arena);
    const cfg = parseArgs(args) catch |err| switch (err) {
        error.HelpRequested => {
            printUsage(args[0]);
            return;
        },
        else => {
            std.debug.print("argument error: {s}\n\n", .{@errorName(err)});
            printUsage(args[0]);
            return err;
        },
    };

    ignoreSigpipe();

    var relay = try Relay.init(arena, cfg);
    defer relay.deinit();

    relay.log(
        .info,
        "listening source={s}:{} sink={s}:{} poll_timeout_ms={} max_sinks={} pending_max={} read_min/default/max={}/{}/{} step={} close_sinks_on_session_end={} log_level={s}",
        .{
            cfg.source_bind,
            cfg.source_port,
            cfg.sink_bind,
            cfg.sink_port,
            cfg.poll_timeout_ms,
            cfg.max_sinks,
            cfg.sink_pending_max,
            cfg.read_min,
            cfg.read_default,
            cfg.read_max,
            cfg.read_step,
            cfg.close_sinks_on_session_end,
            @tagName(cfg.log_level),
        },
    );

    try relay.run();
}

fn parseArgs(args: []const []const u8) CliError!Config {
    var cfg = Config{};

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return error.HelpRequested;
        }

        if (!std.mem.startsWith(u8, arg, "--")) {
            return error.InvalidOption;
        }

        var key: []const u8 = undefined;
        var val: []const u8 = undefined;

        if (std.mem.indexOfScalar(u8, arg, '=')) |eq_idx| {
            key = arg[2..eq_idx];
            val = arg[eq_idx + 1 ..];
        } else {
            key = arg[2..];
            if (i + 1 >= args.len) return error.MissingValue;
            i += 1;
            val = args[i];
        }

        if (std.mem.eql(u8, key, "source-bind")) {
            cfg.source_bind = val;
        } else if (std.mem.eql(u8, key, "source-port")) {
            cfg.source_port = parseU16(val) catch return error.InvalidValue;
        } else if (std.mem.eql(u8, key, "sink-bind")) {
            cfg.sink_bind = val;
        } else if (std.mem.eql(u8, key, "sink-port")) {
            cfg.sink_port = parseU16(val) catch return error.InvalidValue;
        } else if (std.mem.eql(u8, key, "poll-timeout-ms")) {
            cfg.poll_timeout_ms = parseI32(val) catch return error.InvalidValue;
        } else if (std.mem.eql(u8, key, "max-sinks")) {
            cfg.max_sinks = parseUsize(val) catch return error.InvalidValue;
        } else if (std.mem.eql(u8, key, "sink-pending-max")) {
            cfg.sink_pending_max = parseUsize(val) catch return error.InvalidValue;
        } else if (std.mem.eql(u8, key, "read-min")) {
            cfg.read_min = parseUsize(val) catch return error.InvalidValue;
        } else if (std.mem.eql(u8, key, "read-default")) {
            cfg.read_default = parseUsize(val) catch return error.InvalidValue;
        } else if (std.mem.eql(u8, key, "read-max")) {
            cfg.read_max = parseUsize(val) catch return error.InvalidValue;
        } else if (std.mem.eql(u8, key, "read-step")) {
            cfg.read_step = parseUsize(val) catch return error.InvalidValue;
        } else if (std.mem.eql(u8, key, "stats-interval-ms")) {
            cfg.stats_interval_ms = parseU64(val) catch return error.InvalidValue;
        } else if (std.mem.eql(u8, key, "close-sinks-on-session-end")) {
            cfg.close_sinks_on_session_end = parseBool(val) catch return error.InvalidValue;
        } else if (std.mem.eql(u8, key, "log-level")) {
            cfg.log_level = parseLogLevel(val) catch return error.InvalidValue;
        } else {
            return error.InvalidOption;
        }
    }

    if (cfg.poll_timeout_ms < 0) return error.InvalidValue;
    if (cfg.max_sinks == 0) return error.InvalidValue;
    if (cfg.sink_pending_max == 0) return error.InvalidValue;
    if (cfg.read_min == 0 or cfg.read_step == 0) return error.InvalidValue;
    if (!(cfg.read_min <= cfg.read_default and cfg.read_default <= cfg.read_max)) return error.InvalidValue;

    _ = parseIPv4(cfg.source_bind) catch return error.InvalidValue;
    _ = parseIPv4(cfg.sink_bind) catch return error.InvalidValue;

    return cfg;
}

fn parseU16(s: []const u8) !u16 {
    return std.fmt.parseInt(u16, s, 10);
}

fn parseU64(s: []const u8) !u64 {
    return std.fmt.parseInt(u64, s, 10);
}

fn parseUsize(s: []const u8) !usize {
    return std.fmt.parseInt(usize, s, 10);
}

fn parseI32(s: []const u8) !i32 {
    return std.fmt.parseInt(i32, s, 10);
}

fn parseBool(s: []const u8) !bool {
    if (std.ascii.eqlIgnoreCase(s, "1") or std.ascii.eqlIgnoreCase(s, "true") or std.ascii.eqlIgnoreCase(s, "yes") or std.ascii.eqlIgnoreCase(s, "on")) {
        return true;
    }
    if (std.ascii.eqlIgnoreCase(s, "0") or std.ascii.eqlIgnoreCase(s, "false") or std.ascii.eqlIgnoreCase(s, "no") or std.ascii.eqlIgnoreCase(s, "off")) {
        return false;
    }
    return error.InvalidValue;
}

fn parseLogLevel(s: []const u8) !LogLevel {
    if (std.ascii.eqlIgnoreCase(s, "quiet")) return .err;
    if (std.ascii.eqlIgnoreCase(s, "normal")) return .info;
    if (std.ascii.eqlIgnoreCase(s, "verbose")) return .debug;
    if (std.ascii.eqlIgnoreCase(s, "error") or std.ascii.eqlIgnoreCase(s, "err")) return .err;
    if (std.ascii.eqlIgnoreCase(s, "warn") or std.ascii.eqlIgnoreCase(s, "warning")) return .warn;
    if (std.ascii.eqlIgnoreCase(s, "info")) return .info;
    if (std.ascii.eqlIgnoreCase(s, "debug")) return .debug;
    if (std.ascii.eqlIgnoreCase(s, "trace")) return .trace;
    return error.InvalidValue;
}

fn parseIPv4(s: []const u8) !u32 {
    var octets: [4]u8 = undefined;
    var octet_idx: usize = 0;
    var it = std.mem.splitScalar(u8, s, '.');

    while (it.next()) |part| {
        if (octet_idx >= 4 or part.len == 0) return error.InvalidValue;
        octets[octet_idx] = try std.fmt.parseInt(u8, part, 10);
        octet_idx += 1;
    }

    if (octet_idx != 4) return error.InvalidValue;

    const host: u32 = (@as(u32, octets[0]) << 24) |
        (@as(u32, octets[1]) << 16) |
        (@as(u32, octets[2]) << 8) |
        @as(u32, octets[3]);

    return std.mem.nativeToBig(u32, host);
}

fn createListener(bind_ip: []const u8, port: u16) !std.posix.fd_t {
    const fd = std.c.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
    if (fd < 0) {
        return error.SocketCreateFailed;
    }
    errdefer closeFd(fd);

    try setSocketNonBlocking(fd);
    try setSockOptInt(fd, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, 1);

    if (@hasDecl(std.posix.SO, "NOSIGPIPE")) {
        setSockOptInt(fd, std.posix.SOL.SOCKET, std.posix.SO.NOSIGPIPE, 1) catch {};
    }

    var addr = std.posix.sockaddr.in{
        .port = std.mem.nativeToBig(u16, port),
        .addr = try parseIPv4(bind_ip),
    };

    const sa: *const std.posix.sockaddr = @ptrCast(&addr);
    const bind_rc = std.c.bind(fd, sa, @intCast(@sizeOf(@TypeOf(addr))));
    if (bind_rc != 0) {
        return error.BindFailed;
    }

    if (std.c.listen(fd, 256) != 0) {
        return error.ListenFailed;
    }

    return fd;
}

fn setSockOptInt(fd: std.posix.fd_t, level: i32, optname: u32, value: c_int) !void {
    const rc = std.c.setsockopt(fd, level, optname, &value, @intCast(@sizeOf(c_int)));
    if (rc != 0) {
        return error.SetSockOptFailed;
    }
}

fn setSocketNonBlocking(fd: std.posix.fd_t) !void {
    const current_flags = std.c.fcntl(fd, std.posix.F.GETFL, @as(c_int, 0));
    if (current_flags < 0) {
        return error.FcntlGetFailed;
    }

    var flags: std.c.O = @bitCast(@as(u32, @truncate(@as(c_uint, @bitCast(current_flags)))));
    flags.NONBLOCK = true;
    const updated_flags: c_int = @bitCast(@as(u32, @bitCast(flags)));
    if (std.c.fcntl(fd, std.posix.F.SETFL, updated_flags) < 0) {
        return error.FcntlSetFailed;
    }
}

fn ignoreSigpipe() void {
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.PIPE, &action, null);
}

fn closeFd(fd: std.posix.fd_t) void {
    _ = std.c.close(fd);
}

fn isWouldBlock(err: std.posix.E) bool {
    if (err == .AGAIN) return true;
    if (comptime @hasField(std.posix.E, "WOULDBLOCK")) {
        if (err == .WOULDBLOCK) return true;
    }
    return false;
}

fn hasPollEvent(revents: i16, event_mask: anytype) bool {
    const rev: i32 = revents;
    const mask: i32 = @intCast(event_mask);
    return (rev & mask) != 0;
}

fn nowMs() u64 {
    var tv: std.c.timeval = undefined;
    _ = std.c.gettimeofday(&tv, null);

    const sec: u64 = @intCast(tv.sec);
    const usec: u64 = @intCast(tv.usec);
    return (sec * 1000) + (usec / 1000);
}

fn printUsage(argv0: []const u8) void {
    std.debug.print(
        \\Usage:
        \\  {s} [options]
        \\
        \\Options:
        \\  --source-bind <IPv4>                 Source listener bind address (default: 0.0.0.0)
        \\  --source-port <u16>                  Source listener port (default: 5000)
        \\  --sink-bind <IPv4>                   Sink listener bind address (default: 0.0.0.0)
        \\  --sink-port <u16>                    Sink listener port (default: 5001)
        \\  --poll-timeout-ms <i32>              poll() timeout in ms (default: 50)
        \\
        \\  --max-sinks <usize>                  Maximum connected sinks (default: 1024)
        \\  --sink-pending-max <usize>           Per-sink queued byte limit (default: 1048576)
        \\
        \\  --read-min <usize>                   Adaptive source read min bytes (default: 1024)
        \\  --read-default <usize>               Adaptive source read default bytes (default: 16384)
        \\  --read-max <usize>                   Adaptive source read max bytes (default: 65536)
        \\  --read-step <usize>                  Adaptive step bytes (default: 1024)
        \\
        \\  --stats-interval-ms <u64>            Stats log period; 0 disables (default: 5000)
        \\  --close-sinks-on-session-end <bool>  true|false (default: true)
        \\  --log-level <quiet|normal|verbose|error|warn|info|debug|trace> (default: info)
        \\  --help, -h                           Show this help
        \\ 
    , .{argv0});
}

test "parse IPv4 works" {
    const nbo = try parseIPv4("127.0.0.1");
    try std.testing.expectEqual(@as(u32, std.mem.nativeToBig(u32, 0x7f000001)), nbo);
}

test "parse bool supports common forms" {
    try std.testing.expect(try parseBool("true"));
    try std.testing.expect(!(try parseBool("0")));
}

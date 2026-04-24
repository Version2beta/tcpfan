// Build script for tcpfan (Zig).
//
// Defaults to ReleaseFast (throughput is the primary metric).
// `zig build -Doptimize=ReleaseSmall` for the smallest binary (~145 KB vs
// 172 KB) at a small throughput cost.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Default to ReleaseFast: throughput is the primary metric and the
    // ~25 KB extra over ReleaseSmall (171 vs 145 KB) is rounding error vs
    // the ~750 KB Round-2 baseline. `-Doptimize=ReleaseSmall` is supported
    // for the rare case where you want the absolute smallest binary.
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or binary size",
    ) orelse .ReleaseFast;

    const t = target.result;
    // PIC: on Darwin/Mach-O, executables must be PIE; ld64 rejects -no_pie on
    // arm64. Only disable PIC on Linux/BSD where it shaves indirection.
    const pic_off: ?bool = switch (t.os.tag) {
        .linux, .freebsd, .openbsd, .netbsd => false,
        else => null,
    };
    // LTO: requires LLD, which on macOS doesn't support Mach-O. Enable only
    // where LLD is the default linker.
    const want_lto = switch (t.os.tag) {
        .linux, .freebsd, .openbsd, .netbsd => true,
        else => false,
    };

    const exe = b.addExecutable(.{
        .name = "tcpfan",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            // Binary-size knobs: single-threaded by design, never panics on
            // the hot path, no stack unwinding needed. Stripping on top of
            // that gets us a fraction of the default ReleaseSmall binary.
            .single_threaded = true,
            .strip = true,
            .unwind_tables = .none,
            .omit_frame_pointer = true,
            .pic = pic_off,
        }),
    });
    if (want_lto) exe.lto = .full;

    b.installArtifact(exe);
}

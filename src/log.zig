const std = @import("std");
const timefmt = @import("timefmt.zig");

/// Tiny access logger. Serialized so lines from different threads
/// do not interleave. Suppressed entirely with --quiet.
pub const Logger = struct {
    io: std.Io,
    quiet: bool,
    mutex: std.Io.Mutex = .init,

    pub fn init(io: std.Io, quiet: bool) Logger {
        return .{ .io = io, .quiet = quiet };
    }

    pub fn access(
        self: *Logger,
        method: []const u8,
        path: []const u8,
        status: u16,
        bytes: u64,
        duration_ns: i96,
    ) void {
        if (self.quiet) return;

        const now_seconds: i64 = @intCast(@divTrunc(std.Io.Clock.real.now(self.io).nanoseconds, std.time.ns_per_s));
        var ts: [19]u8 = undefined;
        const stamp = timefmt.logTimestamp(now_seconds, &ts);

        var size_buf: [32]u8 = undefined;
        const size_text = formatSize(bytes, &size_buf);
        const duration_ms: u64 = @intCast(@divTrunc(duration_ns, std.time.ns_per_ms));

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var buf: [1024]u8 = undefined;
        var fw = std.Io.File.stdout().writer(self.io, &buf);
        const out = &fw.interface;
        out.print("{s} {s} {s} {d} {s} {d}ms\n", .{ stamp, method, path, status, size_text, duration_ms }) catch {};
        out.flush() catch {};
    }
};

fn formatSize(size: u64, out: []u8) []const u8 {
    if (size < 1024) return std.fmt.bufPrint(out, "{d} B", .{size}) catch out[0..0];
    if (size < 1024 * 1024) return std.fmt.bufPrint(out, "{d} KB", .{size / 1024}) catch out[0..0];
    return std.fmt.bufPrint(out, "{d} MB", .{size / (1024 * 1024)}) catch out[0..0];
}

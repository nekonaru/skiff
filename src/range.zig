const std = @import("std");

/// Result of parsing the `Range` header for a single byte range.
pub const Range = union(enum) {
    /// No usable Range header. Serve the full body with 200.
    none,
    /// Syntactically valid but unsatisfiable for this file size. Respond 416.
    unsatisfiable,
    /// One satisfiable range, inclusive on both ends. Respond 206.
    single: Single,

    pub const Single = struct {
        start: u64,
        end: u64,

        pub fn len(self: Single) u64 {
            return self.end - self.start + 1;
        }
    };
};

/// Parse a `Range: bytes=...` header value against the file size.
///
/// Rules:
/// - `bytes=start-end` (end clamped to file_size - 1)
/// - `bytes=start-`    (start must be < file_size)
/// - `bytes=-suffix`   (last N bytes; suffix of 0 is unsatisfiable)
/// - A comma-separated list is answered with `.none` (RFC 7233 allows
///   ignoring the header; we do not build multipart responses).
/// - Syntactically invalid input is `.none`, not an error.
/// - A syntactically valid range that cannot be satisfied is `.unsatisfiable`.
pub fn parse(header: []const u8, file_size: u64) Range {
    const trimmed = std.mem.trim(u8, header, " \t");
    if (!std.mem.startsWith(u8, trimmed, "bytes=")) return .none;
    const spec = trimmed["bytes=".len..];

    // Only single ranges are supported.
    if (std.mem.indexOfScalar(u8, spec, ',') != null) return .none;

    const dash = std.mem.indexOfScalar(u8, spec, '-') orelse return .none;
    if (std.mem.indexOfAny(u8, spec, " \t") != null) return .none;
    const start_text = spec[0..dash];
    const end_text = spec[dash + 1 ..];

    if (start_text.len == 0) {
        // Suffix range: bytes=-N -> last N bytes.
        const suffix = std.fmt.parseInt(u64, end_text, 10) catch return .none;
        if (suffix == 0) return .unsatisfiable;
        if (file_size == 0) return .unsatisfiable;
        const n = @min(suffix, file_size);
        return .{ .single = .{ .start = file_size - n, .end = file_size - 1 } };
    }

    const start = std.fmt.parseInt(u64, start_text, 10) catch return .none;
    if (start >= file_size) return .unsatisfiable;

    if (end_text.len == 0) {
        return .{ .single = .{ .start = start, .end = file_size - 1 } };
    }

    var end = std.fmt.parseInt(u64, end_text, 10) catch return .none;
    if (end < start) return .unsatisfiable;
    end = @min(end, file_size - 1);
    return .{ .single = .{ .start = start, .end = end } };
}

test "full-ish ranges" {
    const size: u64 = 1000;
    const a = parse("bytes=0-99", size);
    try std.testing.expectEqual(@as(u64, 0), a.single.start);
    try std.testing.expectEqual(@as(u64, 99), a.single.end);
    try std.testing.expectEqual(@as(u64, 100), a.single.len());

    const b = parse("bytes=100-", size);
    try std.testing.expectEqual(@as(u64, 100), b.single.start);
    try std.testing.expectEqual(@as(u64, 999), b.single.end);

    const c = parse("bytes=-200", size);
    try std.testing.expectEqual(@as(u64, 800), c.single.start);
    try std.testing.expectEqual(@as(u64, 999), c.single.end);

    const d = parse("bytes=900-5000", size);
    try std.testing.expectEqual(@as(u64, 900), d.single.start);
    try std.testing.expectEqual(@as(u64, 999), d.single.end);
}

test "unsatisfiable" {
    try std.testing.expect(parse("bytes=1000-", 1000) == .unsatisfiable);
    try std.testing.expect(parse("bytes=500-100", 1000) == .unsatisfiable);
    try std.testing.expect(parse("bytes=-0", 1000) == .unsatisfiable);
    try std.testing.expect(parse("bytes=0-0", 0) == .unsatisfiable);
}

test "ignored" {
    try std.testing.expect(parse("items=0-1", 1000) == .none);
    try std.testing.expect(parse("bytes=0-100,200-300", 1000) == .none);
    try std.testing.expect(parse("bytes=abc-def", 1000) == .none);
    try std.testing.expect(parse("bytes=", 1000) == .none);
    try std.testing.expect(parse("", 1000) == .none);
}

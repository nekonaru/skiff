const std = @import("std");
const builtin = @import("builtin");

/// Percent-decode and normalize a request path into a safe relative path
/// under the served root. Returns the decoded relative path ("a/b/c"),
/// or an empty slice for the root itself.
///
/// Rejects anything that could escape the root or confuse the filesystem:
/// bad percent sequences, NUL/control bytes, backslashes, drive letters,
/// UNC prefixes, `..` segments, and Windows device names.
pub const NormalizeError = error{
    Forbidden,
    PathTooLong,
};

pub fn normalize(request_path: []const u8, out: []u8) NormalizeError![]const u8 {
    if (request_path.len == 0 or request_path[0] != '/') return NormalizeError.Forbidden;

    // Percent-decode into `decoded`.
    var decoded_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const decoded = decodePercent(request_path, &decoded_buf) catch |err| switch (err) {
        error.PathTooLong => return NormalizeError.PathTooLong,
        error.BadEncoding => return NormalizeError.Forbidden,
    };

    // Reject backslashes (raw or decoded) and control bytes anywhere.
    for (decoded) |b| {
        if (b == '\\') return NormalizeError.Forbidden;
        if (b < 0x20) return NormalizeError.Forbidden;
    }

    // Build the relative path segment by segment.
    var result_len: usize = 0;
    var segments = std.mem.tokenizeScalar(u8, decoded, '/');
    while (segments.next()) |segment| {
        if (std.mem.eql(u8, segment, ".")) continue;
        if (std.mem.eql(u8, segment, "..")) return NormalizeError.Forbidden;
        if (isWindowsDeviceName(segment)) return NormalizeError.Forbidden;

        if (result_len != 0) {
            if (result_len >= out.len) return NormalizeError.PathTooLong;
            out[result_len] = '/';
            result_len += 1;
        }
        if (result_len + segment.len > out.len) return NormalizeError.PathTooLong;
        @memcpy(out[result_len .. result_len + segment.len], segment);
        result_len += segment.len;
    }
    return out[0..result_len];
}

fn decodePercent(in: []const u8, out: []u8) error{ PathTooLong, BadEncoding }![]const u8 {
    var i: usize = 0;
    var o: usize = 0;
    while (i < in.len) {
        const c = in[i];
        if (c == '%') {
            if (in.len - i < 3) return error.BadEncoding;
            const hi = hexValue(in[i + 1]) orelse return error.BadEncoding;
            const lo = hexValue(in[i + 2]) orelse return error.BadEncoding;
            const byte = (hi << 4) | lo;
            if (byte == 0) return error.BadEncoding;
            if (o >= out.len) return error.PathTooLong;
            out[o] = byte;
            o += 1;
            i += 3;
        } else {
            if (c < 0x20) return error.BadEncoding;
            if (o >= out.len) return error.PathTooLong;
            out[o] = c;
            o += 1;
            i += 1;
        }
    }
    return out[0..o];
}

fn hexValue(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// Windows device names are reserved with or without an extension.
fn isWindowsDeviceName(segment: []const u8) bool {
    const base = std.mem.sliceTo(segment, '.');
    if (base.len > 4) return false;
    const device_names = [_][]const u8{
        "con", "prn", "aux", "nul",
        "com1", "com2", "com3", "com4", "com5", "com6", "com7", "com8", "com9",
        "lpt1", "lpt2", "lpt3", "lpt4", "lpt5", "lpt6", "lpt7", "lpt8", "lpt9",
    };
    for (device_names) |name| {
        if (std.ascii.eqlIgnoreCase(base, name)) return true;
    }
    return false;
}

/// Case-insensitive-on-Windows, case-sensitive elsewhere path containment test.
/// Both paths must already be absolute. `child` must equal `root` or live inside it.
pub fn isPathInside(root: []const u8, child: []const u8) bool {
    const r = trimVerbatimPrefix(root);
    const c = trimVerbatimPrefix(child);
    const a = r;
    const b = c;
    const eqci = builtin.os.tag == .windows;

    if (a.len > b.len) return false;
    const prefix_ok = if (eqci) blk: {
        for (a, 0..) |ch, i| {
            if (std.ascii.toLower(ch) != std.ascii.toLower(b[i])) break :blk false;
        }
        break :blk true;
    } else std.mem.eql(u8, b[0..a.len], a);
    if (!prefix_ok) return false;
    if (a.len == b.len) return true;
    const next = b[a.len];
    return next == '/' or next == '\\';
}

fn trimVerbatimPrefix(p: []const u8) []const u8 {
    if (std.mem.eql(u8, p[0..@min(4, p.len)], "\\\\?\\")) {
        return p[4..];
    }
    return p;
}

test "normalize ok" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("", try normalize("/", &buf));
    try std.testing.expectEqualStrings("index.html", try normalize("/index.html", &buf));
    try std.testing.expectEqualStrings("a/b/c", try normalize("/a/b/c", &buf));
    try std.testing.expectEqualStrings("a/b", try normalize("/a//b/", &buf));
    try std.testing.expectEqualStrings("a/b", try normalize("/a/./b", &buf));
    try std.testing.expectEqualStrings("hello world", try normalize("/hello%20world", &buf));
    try std.testing.expectEqualStrings("dir/file.png", try normalize("/dir/%66ile.png", &buf));
}

test "normalize traversal" {
    var buf: [256]u8 = undefined;
    try std.testing.expectError(NormalizeError.Forbidden, normalize("/../etc/passwd", &buf));
    try std.testing.expectError(NormalizeError.Forbidden, normalize("/a/../../b", &buf));
    try std.testing.expectError(NormalizeError.Forbidden, normalize("/%2e%2e/secret", &buf));
    try std.testing.expectError(NormalizeError.Forbidden, normalize("/a/%2E%2E/b", &buf));
    try std.testing.expectError(NormalizeError.Forbidden, normalize("/..%2f..%2f", &buf));
    try std.testing.expectError(NormalizeError.Forbidden, normalize("/%2e%2e%2fetc", &buf));
    try std.testing.expectError(NormalizeError.Forbidden, normalize("/dir\\sub", &buf));
    try std.testing.expectError(NormalizeError.Forbidden, normalize("/%5cwindows", &buf));
    try std.testing.expectError(NormalizeError.Forbidden, normalize("/%00", &buf));
    try std.testing.expectError(NormalizeError.Forbidden, normalize("/CON", &buf));
    try std.testing.expectError(NormalizeError.Forbidden, normalize("/con.txt", &buf));
    try std.testing.expectError(NormalizeError.Forbidden, normalize("/a/PRN/b", &buf));
    try std.testing.expectError(NormalizeError.Forbidden, normalize("/com1", &buf));
    try std.testing.expectError(NormalizeError.Forbidden, normalize("/LPT9.md", &buf));
    try std.testing.expectError(NormalizeError.Forbidden, normalize("/%zz", &buf));
    try std.testing.expectError(NormalizeError.Forbidden, normalize("/%1f", &buf));
    try std.testing.expectError(NormalizeError.Forbidden, normalize("not-a-path", &buf));
}

test "path inside" {
    try std.testing.expect(isPathInside("/srv/root", "/srv/root"));
    try std.testing.expect(isPathInside("/srv/root", "/srv/root/a/b"));
    try std.testing.expect(isPathInside("/srv/root", "/srv/rootother") == false);
    try std.testing.expect(isPathInside("/srv/root", "/srv/rootx/file") == false);
    try std.testing.expect(isPathInside("C:\\\\root", "c:\\root\\a"));
    try std.testing.expect(isPathInside("\\\\?\\C:\\root", "\\\\?\\C:\\root\\file.txt"));
    try std.testing.expect(isPathInside("\\\\?\\C:\\root", "\\\\?\\C:\\rootother\\file.txt") == false);
}

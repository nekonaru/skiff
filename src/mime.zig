const std = @import("std");

/// Built-in MIME types. Keys are lowercase, without the leading dot.
/// Fallback for unknown extensions is application/octet-stream.
const table = [_]struct { ext: []const u8, mime: []const u8 }{
    .{ .ext = "css", .mime = "text/css; charset=utf-8" },
    .{ .ext = "gif", .mime = "image/gif" },
    .{ .ext = "htm", .mime = "text/html; charset=utf-8" },
    .{ .ext = "html", .mime = "text/html; charset=utf-8" },
    .{ .ext = "ico", .mime = "image/x-icon" },
    .{ .ext = "jpg", .mime = "image/jpeg" },
    .{ .ext = "jpeg", .mime = "image/jpeg" },
    .{ .ext = "js", .mime = "text/javascript; charset=utf-8" },
    .{ .ext = "json", .mime = "application/json; charset=utf-8" },
    .{ .ext = "md", .mime = "text/markdown; charset=utf-8" },
    .{ .ext = "mjs", .mime = "text/javascript; charset=utf-8" },
    .{ .ext = "mov", .mime = "video/quicktime" },
    .{ .ext = "mp3", .mime = "audio/mpeg" },
    .{ .ext = "mp4", .mime = "video/mp4" },
    .{ .ext = "ogg", .mime = "audio/ogg" },
    .{ .ext = "otf", .mime = "font/otf" },
    .{ .ext = "pdf", .mime = "application/pdf" },
    .{ .ext = "png", .mime = "image/png" },
    .{ .ext = "svg", .mime = "image/svg+xml" },
    .{ .ext = "tex", .mime = "text/x-tex; charset=utf-8" },
    .{ .ext = "tif", .mime = "image/tiff" },
    .{ .ext = "tiff", .mime = "image/tiff" },
    .{ .ext = "ttf", .mime = "font/ttf" },
    .{ .ext = "txt", .mime = "text/plain; charset=utf-8" },
    .{ .ext = "wav", .mime = "audio/wav" },
    .{ .ext = "webm", .mime = "video/webm" },
    .{ .ext = "webp", .mime = "image/webp" },
    .{ .ext = "wasm", .mime = "application/wasm" },
    .{ .ext = "woff", .mime = "font/woff" },
    .{ .ext = "woff2", .mime = "font/woff2" },
    .{ .ext = "xml", .mime = "application/xml; charset=utf-8" },
    .{ .ext = "zip", .mime = "application/zip" },
};

pub const default_mime = "application/octet-stream";

/// Look up the MIME type for a lowercase extension (no leading dot).
pub fn fromExtension(ext: []const u8) []const u8 {
    for (table) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.ext, ext)) return entry.mime;
    }
    return default_mime;
}

/// Extract the lowercase extension from a file name, or null if none.
pub fn extension(name: []const u8) ?[]const u8 {
    const base = std.fs.path.basename(name);
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return null;
    if (dot == 0 or dot == base.len - 1) return null;
    return base[dot + 1 ..];
}

/// MIME type for a whole file name or path.
pub fn forPath(path: []const u8) []const u8 {
    const ext = extension(path) orelse return default_mime;
    return fromExtension(ext);
}

test "mime lookup" {
    try std.testing.expectEqualStrings("text/html; charset=utf-8", fromExtension("html"));
    try std.testing.expectEqualStrings("text/html; charset=utf-8", fromExtension("HTM"));
    try std.testing.expectEqualStrings("video/mp4", fromExtension("mp4"));
    try std.testing.expectEqualStrings(default_mime, fromExtension("definitely-not-an-ext"));
}

test "extension extraction" {
    try std.testing.expectEqualStrings("html", extension("index.html").?);
    try std.testing.expectEqualStrings("js", extension("app.min.js").?);
    try std.testing.expectEqualStrings("wasm", extension("mod.wasm").?);
    try std.testing.expect(extension("noext") == null);
    try std.testing.expect(extension(".hidden") == null);
    try std.testing.expect(extension("trailing.") == null);
    try std.testing.expectEqualStrings("png", extension("a/b/c.png").?);
}

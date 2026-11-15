const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn escapeHtml(name: []const u8, out: []u8) []const u8 {
    var o: usize = 0;
    for (name) |c| {
        const replacement: []const u8 = switch (c) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            '\'' => "&#x27;",
            else => &.{c},
        };
        if (o + replacement.len > out.len) break;
        @memcpy(out[o .. o + replacement.len], replacement);
        o += replacement.len;
    }
    return out[0..o];
}

/// Percent-encode a file name for use as a single path segment in an href.
pub fn encodeUrlSegment(name: []const u8, out: []u8) []const u8 {
    var o: usize = 0;
    for (name) |b| {
        const is_unreserved = (b >= 'A' and b <= 'Z') or (b >= 'a' and b <= 'z') or
            (b >= '0' and b <= '9') or b == '-' or b == '.' or b == '_' or b == '~';
        if (is_unreserved) {
            if (o >= out.len) break;
            out[o] = b;
            o += 1;
        } else {
            if (o + 3 > out.len) break;
            const hex = "0123456789ABCDEF";
            out[o] = '%';
            out[o + 1] = hex[b >> 4];
            out[o + 2] = hex[b & 0xf];
            o += 3;
        }
    }
    return out[0..o];
}

pub fn formatSize(size: u64, out: []u8) []const u8 {
    if (size < 1024) {
        return std.fmt.bufPrint(out, "{d} B", .{size}) catch out[0..0];
    } else if (size < 1024 * 1024) {
        return std.fmt.bufPrint(out, "{d} KB", .{size / 1024}) catch out[0..0];
    } else if (size < 1024 * 1024 * 1024) {
        return std.fmt.bufPrint(out, "{d} MB", .{size / (1024 * 1024)}) catch out[0..0];
    } else {
        return std.fmt.bufPrint(out, "{d} GB", .{size / (1024 * 1024 * 1024)}) catch out[0..0];
    }
}

pub const Entry = struct {
    name: []const u8,
    is_dir: bool,
    size: u64,
};

/// Append the HTML listing page for `dir_display_path` into `list`.
/// `entries` must already be sorted (directories first, then by name).
pub fn render(
    alloc: Allocator,
    list: *std.ArrayList(u8),
    dir_display_path: []const u8,
    entries: []const Entry,
) !void {
    var esc: [1024]u8 = undefined;

    try list.appendSlice(alloc,
        "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n<title>Index of ");
    try list.appendSlice(alloc, escapeHtml(dir_display_path, &esc));
    try list.appendSlice(alloc,
        "</title>\n<style>body{font-family:ui-monospace,Menlo,Consolas,monospace;background:#0f0f12;color:#e8e6df;max-width:64rem;margin:2rem auto;padding:0 1rem}h1{font-size:1.2rem;color:#e86e1c;border-bottom:1px solid #2a2a30;padding-bottom:.5rem}table{width:100%;border-collapse:collapse}td,th{text-align:left;padding:.25rem .5rem;font-size:.9rem}th{color:#8e8d85;font-weight:600}tr:hover td{background:#1a1a1f}a{color:#e8e6df;text-decoration:none}a:hover{color:#e86e1c;text-decoration:underline}td.size{text-align:right;color:#8e8d85}</style>\n</head>\n<body>\n<h1>Index of ");
    try list.appendSlice(alloc, escapeHtml(dir_display_path, &esc));
    try list.appendSlice(alloc,
        "</h1>\n<table>\n<thead><tr><th>Name</th><th class=\"size\">Size</th></tr></thead>\n<tbody>\n");

    if (!std.mem.eql(u8, dir_display_path, "/")) {
        try list.appendSlice(alloc, "<tr><td><a href=\"../\">../</a></td><td class=\"size\">-</td></tr>\n");
    }

    for (entries) |entry| {
        var href_buf: [2048]u8 = undefined;
        const href = encodeUrlSegment(entry.name, &href_buf);
        var esc2: [2048]u8 = undefined;
        const name_text = escapeHtml(entry.name, &esc2);

        try list.appendSlice(alloc, "<tr><td><a href=\"");
        try list.appendSlice(alloc, href);
        if (entry.is_dir) try list.appendSlice(alloc, "/");
        try list.appendSlice(alloc, "\">");
        try list.appendSlice(alloc, name_text);
        if (entry.is_dir) try list.appendSlice(alloc, "/");
        try list.appendSlice(alloc, "</a></td><td class=\"size\">");
        if (entry.is_dir) {
            try list.appendSlice(alloc, "-");
        } else {
            var size_buf: [32]u8 = undefined;
            try list.appendSlice(alloc, formatSize(entry.size, &size_buf));
        }
        try list.appendSlice(alloc, "</td></tr>\n");
    }

    try list.appendSlice(alloc,
        "</tbody>\n</table>\n<hr>\n<p>Served by <a href=\"https://github.com/nekonaru/skiff\">Skiff</a></p>\n</body>\n</html>\n");
}

test "escape html" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("&lt;script&gt;&amp;", escapeHtml("<script>&", &buf));
    try std.testing.expectEqualStrings("plain", escapeHtml("plain", &buf));
}

test "encode url segment" {
    var buf: [512]u8 = undefined;
    try std.testing.expectEqualStrings("plain", encodeUrlSegment("plain", &buf));
    try std.testing.expectEqualStrings("a%20b%26c", encodeUrlSegment("a b&c", &buf));
    try std.testing.expectEqualStrings("%3Cscript%3E", encodeUrlSegment("<script>", &buf));
    try std.testing.expectEqualStrings("file%25name", encodeUrlSegment("file%name", &buf));
}

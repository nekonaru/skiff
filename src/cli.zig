const std = @import("std");

pub const version = "0.1.0";

pub const help_text =
    \\Skiff - tiny static file server
    \\
    \\Usage: skiff [options]
    \\
    \\Options:
    \\  -p, --port <port>    Port to listen on (default: 8080)
    \\  -d, --dir <path>     Root directory to serve (default: current directory)
    \\      --host <addr>    Address to bind, use 0.0.0.0 for LAN (default: 127.0.0.1)
    \\      --no-listing     Disable directory listing when no index.html exists
    \\      --spa            Fall back to index.html for unknown paths (SPA mode)
    \\      --cors           Add Access-Control-Allow-Origin: * to responses
    \\      --quiet          Suppress access logs
    \\  -h, --help           Show this help and exit
    \\  -v, --version        Show version and exit
    \\
    \\Examples:
    \\  skiff                 Serve the current directory on port 8080
    \\  skiff -p 3000 -d dist Serve ./dist on port 3000
    \\  skiff --host 0.0.0.0  Open the server to the local network
    \\  skiff --spa           Serve a single-page app
    \\
;

pub const Config = struct {
    port: u16 = 8080,
    host: []const u8 = "127.0.0.1",
    dir: []const u8 = ".",
    no_listing: bool = false,
    spa: bool = false,
    cors: bool = false,
    quiet: bool = false,
};

pub const ParseResult = union(enum) {
    help,
    version,
    config: Config,
};

pub const ParseError = error{
    UnknownOption,
    MissingValue,
    InvalidPort,
};

/// Parse command line arguments. `argv0` must already be consumed.
/// Returned strings borrow from the argument iterator, valid until deinit.
pub fn parse(argv: []const [:0]const u8) ParseError!ParseResult {
    var cfg: Config = .{};
    var args = argv;
    while (args.len > 0) {
        const arg = args[0];
        args = args[1..];

        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            return .help;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
            return .version;
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--port")) {
            const value = takeValue(&args) orelse return ParseError.MissingValue;
            cfg.port = parsePort(value) orelse return ParseError.InvalidPort;
        } else if (std.mem.startsWith(u8, arg, "--port=")) {
            const value = arg["--port=".len..];
            cfg.port = parsePort(value) orelse return ParseError.InvalidPort;
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--dir")) {
            cfg.dir = takeValue(&args) orelse return ParseError.MissingValue;
        } else if (std.mem.startsWith(u8, arg, "--dir=")) {
            cfg.dir = arg["--dir=".len..];
        } else if (std.mem.eql(u8, arg, "--host")) {
            cfg.host = takeValue(&args) orelse return ParseError.MissingValue;
        } else if (std.mem.startsWith(u8, arg, "--host=")) {
            cfg.host = arg["--host=".len..];
        } else if (std.mem.eql(u8, arg, "--no-listing")) {
            cfg.no_listing = true;
        } else if (std.mem.eql(u8, arg, "--spa")) {
            cfg.spa = true;
        } else if (std.mem.eql(u8, arg, "--cors")) {
            cfg.cors = true;
        } else if (std.mem.eql(u8, arg, "--quiet")) {
            cfg.quiet = true;
        } else {
            return ParseError.UnknownOption;
        }
    }
    return .{ .config = cfg };
}

fn takeValue(args: *[]const [:0]const u8) ?[:0]const u8 {
    if (args.*.len == 0) return null;
    const value = args.*[0];
    args.* = args.*[1..];
    return value;
}

fn parsePort(text: []const u8) ?u16 {
    const port = std.fmt.parseInt(u16, text, 10) catch return null;
    if (port == 0) return null;
    return port;
}

test "parse defaults" {
    const result = try parse(&.{});
    try std.testing.expectEqualStrings("127.0.0.1", result.config.host);
    try std.testing.expectEqual(@as(u16, 8080), result.config.port);
    try std.testing.expectEqualStrings(".", result.config.dir);
    try std.testing.expect(!result.config.spa);
}

test "parse port forms" {
    const a = try parse(&.{ "-p", "3000" });
    try std.testing.expectEqual(@as(u16, 3000), a.config.port);
    const b = try parse(&.{ "--port", "3001" });
    try std.testing.expectEqual(@as(u16, 3001), b.config.port);
    const c = try parse(&.{"--port=3002"});
    try std.testing.expectEqual(@as(u16, 3002), c.config.port);
    try std.testing.expectError(ParseError.InvalidPort, parse(&.{ "--port", "0" }));
    try std.testing.expectError(ParseError.InvalidPort, parse(&.{ "--port", "abc" }));
    try std.testing.expectError(ParseError.InvalidPort, parse(&.{"--port=99999"}));
    try std.testing.expectError(ParseError.MissingValue, parse(&.{"--port"}));
}

test "parse dir forms" {
    const a = try parse(&.{ "-d", "dist" });
    try std.testing.expectEqualStrings("dist", a.config.dir);
    const b = try parse(&.{ "--dir", "out" });
    try std.testing.expectEqualStrings("out", b.config.dir);
    const c = try parse(&.{"--dir=public"});
    try std.testing.expectEqualStrings("public", c.config.dir);
}

test "parse flags" {
    const result = try parse(&.{ "--spa", "--cors", "--quiet", "--no-listing", "--host", "0.0.0.0" });
    try std.testing.expect(result.config.spa);
    try std.testing.expect(result.config.cors);
    try std.testing.expect(result.config.quiet);
    try std.testing.expect(result.config.no_listing);
    try std.testing.expectEqualStrings("0.0.0.0", result.config.host);
}

test "help and version" {
    try std.testing.expect(std.meta.activeTag(try parse(&.{"--help"})) == .help);
    try std.testing.expect(std.meta.activeTag(try parse(&.{"-h"})) == .help);
    try std.testing.expect(std.meta.activeTag(try parse(&.{"--version"})) == .version);
    try std.testing.expect(std.meta.activeTag(try parse(&.{"-v"})) == .version);
}

test "unknown option" {
    try std.testing.expectError(ParseError.UnknownOption, parse(&.{"--bogus"}));
}

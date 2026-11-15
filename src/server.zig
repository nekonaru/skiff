const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const http = std.http;

const cli = @import("cli.zig");
const fs_guard = @import("fs_guard.zig");
const listing = @import("listing.zig");
const log = @import("log.zig");
const mime = @import("mime.zig");
const range = @import("range.zig");
const timefmt = @import("timefmt.zig");

const max_connections = 64;
const max_head_bytes = 16 * 1024;
const idle_timeout_seconds = 30;
const file_chunk = 16 * 1024;
const max_listing_entries = 1000;
const server_version = "Skiff/" ++ cli.version;

var shutdown_requested = std.atomic.Value(bool).init(false);

pub const RunError = error{
    InvalidHost,
    CannotOpenRoot,
    ServeFailed,
};

pub fn run(
    alloc: Allocator,
    io: std.Io,
    cfg: cli.Config,
    out: *std.Io.Writer,
) RunError!void {
    var root_dir = std.Io.Dir.cwd().openDir(io, cfg.dir, .{}) catch return RunError.CannotOpenRoot;
    defer root_dir.close(io);

    var root_real_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_real_len = root_dir.realPath(io, &root_real_buf) catch return RunError.CannotOpenRoot;
    const root_real = alloc.dupe(u8, root_real_buf[0..root_real_len]) catch return RunError.CannotOpenRoot;
    defer alloc.free(root_real);

    const address = std.Io.net.IpAddress.parse(cfg.host, cfg.port) catch return RunError.InvalidHost;
    var server = std.Io.net.IpAddress.listen(&address, io, .{ .kernel_backlog = 128 }) catch return RunError.CannotOpenRoot;
    defer server.deinit(io);

    var logger = log.Logger.init(io, cfg.quiet);

    installSignalHandlers();
    printStartup(out, cfg) catch {};

    var sem: std.Io.Semaphore = .{ .permits = max_connections };

    while (!shutdown_requested.load(.acquire)) {
        const stream = server.accept(io) catch |err| switch (err) {
            error.WouldBlock, error.ConnectionAborted => continue,
            else => return RunError.ServeFailed,
        };

        sem.waitUncancelable(io);
        const ctx = ConnectionContext{
            .io = io,
            .stream = stream,
            .root_dir = root_dir,
            .root_real = root_real,
            .cfg = cfg,
            .logger = &logger,
            .sem = &sem,
        };
        const thread = std.Thread.spawn(.{ .stack_size = 1024 * 1024 }, connectionThread, .{ctx}) catch {
            sem.post(io);
            stream.close(io);
            continue;
        };
        thread.detach();
    }
}

fn printStartup(out: *std.Io.Writer, cfg: cli.Config) !void {
    try out.print("Skiff {s}, serving {s}\n", .{ cli.version, cfg.dir });
    if (std.mem.eql(u8, cfg.host, "0.0.0.0") or std.mem.eql(u8, cfg.host, "::")) {
        try out.print("Listening on all interfaces at port {d}\n", .{cfg.port});
        try out.print("Open http://<this machine's LAN IP>:{d} from another device\n", .{cfg.port});
    } else {
        try out.print("Listening at http://{s}:{d}\n", .{ cfg.host, cfg.port });
    }
    try out.flush();
}

const ConnectionContext = struct {
    io: std.Io,
    stream: std.Io.net.Stream,
    root_dir: std.Io.Dir,
    root_real: []const u8,
    cfg: cli.Config,
    logger: *log.Logger,
    sem: *std.Io.Semaphore,
};

const RequestState = struct {
    status: u16 = 200,
    bytes: u64 = 0,
};

fn connectionThread(ctx: ConnectionContext) void {
    defer ctx.sem.post(ctx.io);
    defer ctx.stream.close(ctx.io);

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    setReadTimeout(ctx.stream, idle_timeout_seconds);

    var read_buffer: [max_head_bytes]u8 = undefined;
    var write_buffer: [16 * 1024]u8 = undefined;
    var net_reader = ctx.stream.reader(ctx.io, &read_buffer);
    var net_writer = ctx.stream.writer(ctx.io, &write_buffer);
    var http_server = http.Server.init(&net_reader.interface, &net_writer.interface);

    while (true) {
        const start = std.Io.Clock.awake.now(ctx.io);

        var req = http_server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing, error.ReadFailed => return,
            error.HttpHeadersInvalid, error.HttpHeadersOversize => {
                net_writer.interface.writeAll("HTTP/1.1 400 Bad Request\r\ncontent-type: text/plain\r\ncontent-length: 12\r\nconnection: close\r\n\r\nBad Request\n") catch {};
                net_writer.interface.flush() catch {};
                return;
            },
            error.HttpRequestTruncated => return,
        };

        const keep_alive = req.head.keep_alive;
        const method = req.head.method;
        const target = req.head.target;

        const state = handleRequest(ctx, alloc, &req);
        const now = std.Io.Clock.awake.now(ctx.io);
        const duration = start.durationTo(now);
        ctx.logger.access(@tagName(method), target, state.status, state.bytes, duration.nanoseconds);

        if (!keep_alive) return;
    }
}

fn handleRequest(
    ctx: ConnectionContext,
    alloc: Allocator,
    req: *http.Server.Request,
) RequestState {
    var state: RequestState = .{};
    const version = req.head.version;
    const keep_alive = req.head.keep_alive;

    const method = req.head.method;
    if (method != .GET and method != .HEAD) {
        state.status = 405;
        state.bytes = sendSimple(req, version, .method_not_allowed, "Method Not Allowed\n", keep_alive, &.{}) catch 0;
        return state;
    }

    const target = req.head.target;
    const query_start = std.mem.indexOfScalar(u8, target, '?');
    const path_part = if (query_start) |i| target[0..i] else target;
    const query_part: ?[]const u8 = if (query_start) |i| target[i..] else null;

    if (path_part.len == 0 or path_part[0] != '/') {
        state.status = 400;
        state.bytes = sendSimple(req, version, .bad_request, "Bad Request\n", keep_alive, &.{}) catch 0;
        return state;
    }

    var rel_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const rel = fs_guard.normalize(path_part, &rel_buf) catch {
        state.status = 400;
        state.bytes = sendSimple(req, version, .bad_request, "Bad Request\n", keep_alive, &.{}) catch 0;
        return state;
    };

    servePath(ctx, alloc, req, &state, rel, query_part) catch {
        state.status = 500;
        if (state.bytes == 0) {
            state.bytes = sendSimple(req, version, .internal_server_error, "Internal Server Error\n", keep_alive, &.{}) catch 0;
        }
    };
    return state;
}

fn servePath(
    ctx: ConnectionContext,
    alloc: Allocator,
    req: *http.Server.Request,
    state: *RequestState,
    rel: []const u8,
    query_part: ?[]const u8,
) !void {
    const version = req.head.version;
    const keep_alive = req.head.keep_alive;

    var abs_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;

    // Directories: index.html, then listing; else redirect to trailing slash.
    if (resolveAbs(ctx, rel, &abs_buf)) |abs_len| {
        const abs = abs_buf[0..abs_len];
        if (isDirectoryAbs(ctx, abs)) {
            const path_no_query = req.head.target[0 .. std.mem.indexOfScalar(u8, req.head.target, '?') orelse req.head.target.len];
            if (!std.mem.endsWith(u8, path_no_query, "/")) {
                const location = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ path_no_query, if (query_part) |q| q else "" });
                defer alloc.free(location);
                const headers = [_]http.Header{.{ .name = "location", .value = location }};
                state.status = 301;
                state.bytes = try sendSimple(req, version, .moved_permanently, "Moved Permanently\n", keep_alive, &headers);
                return;
            }
            const index_rel = if (rel.len == 0) @constCast("index.html") else try std.fmt.allocPrint(alloc, "{s}/index.html", .{rel});
            defer if (rel.len != 0) alloc.free(index_rel);
            if (tryServeFile(ctx, req, state, index_rel)) return;
            if (ctx.cfg.no_listing) {
                state.status = 403;
                state.bytes = try sendSimple(req, version, .forbidden, "Forbidden\n", keep_alive, &.{});
                return;
            }
            return serveListing(ctx, alloc, req, state, rel, abs);
        }
    } else |err| switch (err) {
        error.Contains => {
            state.status = 403;
            state.bytes = try sendSimple(req, version, .forbidden, "Forbidden\n", keep_alive, &.{});
            return;
        },
        error.NotFound => {},
        error.Internal => return error.Internal,
    }

    // Plain file.
    if (tryServeFile(ctx, req, state, rel)) return;

    if (ctx.cfg.spa) {
        if (tryServeFile(ctx, req, state, "index.html")) return;
    }

    state.status = 404;
    state.bytes = try sendSimple(req, version, .not_found, "Not Found\n", keep_alive, &.{});
}

/// Resolve `rel` (already normalized) to an absolute canonical path inside
/// the root. `out` receives the path; returns its length.
fn resolveAbs(ctx: ConnectionContext, rel: []const u8, out: []u8) error{ Contains, NotFound, Internal }!usize {
    if (rel.len == 0) {
        const n = ctx.root_dir.realPath(ctx.io, out) catch return error.Internal;
        return n;
    }
    const n = ctx.root_dir.realPathFile(ctx.io, rel, out) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.AccessDenied => return error.NotFound,
        else => return error.Internal,
    };
    if (!fs_guard.isPathInside(ctx.root_real, out[0..n])) return error.Contains;
    return n;
}

fn isDirectoryAbs(ctx: ConnectionContext, abs: []const u8) bool {
    var dir = std.Io.Dir.openDirAbsolute(ctx.io, abs, .{}) catch return false;
    dir.close(ctx.io);
    return true;
}

/// Try to stream `rel` as a regular file. Returns true once a response was sent.
fn tryServeFile(
    ctx: ConnectionContext,
    req: *http.Server.Request,
    state: *RequestState,
    rel: []const u8,
) bool {
    const version = req.head.version;
    const keep_alive = req.head.keep_alive;

    var abs_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const abs_len = resolveAbs(ctx, rel, &abs_buf) catch |err| switch (err) {
        error.NotFound => return false,
        error.Contains => {
            state.status = 403;
            state.bytes = sendSimple(req, version, .forbidden, "Forbidden\n", keep_alive, &.{}) catch 0;
            return true;
        },
        error.Internal => {
            state.status = 500;
            state.bytes = sendSimple(req, version, .internal_server_error, "Internal Server Error\n", keep_alive, &.{}) catch 0;
            return true;
        },
    };
    const abs = abs_buf[0..abs_len];

    var file = std.Io.Dir.openFileAbsolute(ctx.io, abs, .{}) catch return false;
    defer file.close(ctx.io);
    const stat = file.stat(ctx.io) catch return false;
    if (stat.kind != .file) return false;

    streamFile(ctx, req, state, rel, file, stat) catch {
        state.status = 500;
        if (state.bytes == 0) {
            state.bytes = sendSimple(req, version, .internal_server_error, "Internal Server Error\n", keep_alive, &.{}) catch 0;
        }
    };
    return true;
}

fn streamFile(
    ctx: ConnectionContext,
    req: *http.Server.Request,
    state: *RequestState,
    rel: []const u8,
    file: std.Io.File,
    stat: std.Io.File.Stat,
) !void {
    const version = req.head.version;
    const keep_alive = req.head.keep_alive;
    const size: u64 = stat.size;
    const mtime_sec: i64 = @intCast(@divTrunc(stat.mtime.nanoseconds, std.time.ns_per_s));

    var etag_buf: [48]u8 = undefined;
    const etag = std.fmt.bufPrint(&etag_buf, "W/\"{x}-{x}\"", .{ size, @as(u64, @bitCast(mtime_sec)) }) catch "W/\"0-0\"";
    var lm_buf: [29]u8 = undefined;
    const last_modified = timefmt.httpDate(mtime_sec, &lm_buf);
    const content_type = mime.forPath(rel);

    const base_headers = [_]http.Header{
        .{ .name = "content-type", .value = content_type },
        .{ .name = "accept-ranges", .value = "bytes" },
        .{ .name = "etag", .value = etag },
        .{ .name = "last-modified", .value = last_modified },
        .{ .name = "cache-control", .value = "no-cache" },
        .{ .name = "x-content-type-options", .value = "nosniff" },
        .{ .name = "server", .value = server_version },
        .{ .name = "access-control-allow-origin", .value = "*" },
    };
    const base: []const http.Header = if (ctx.cfg.cors) base_headers[0..] else base_headers[0 .. base_headers.len - 1];

    const headers = if (ctx.cfg.cors) base_headers[0..base_headers.len] else base_headers[0 .. base_headers.len - 1];
    _ = base;

    // Conditional GET: If-None-Match wins over If-Modified-Since.
    const inm = findHeader(req, "if-none-match");
    const ims = findHeader(req, "if-modified-since");
    const not_modified = if (inm) |v| ifNoneMatchMatches(v, etag) else if (ims) |v| ifModifiedSinceMatches(v, mtime_sec) else false;

    if (not_modified) {
        state.status = 304;
        const headers_304 = headers[1..]; // drop content-type
        state.bytes = try sendSimpleTransferNone(req, version, .not_modified, headers_304, keep_alive);
        return;
    }

    // Range (only honored when If-Range, if present, matches).
    var body_start: u64 = 0;
    var body_len: u64 = size;
    var is_range = false;
    var range_status: http.Status = .ok;
    if (findHeader(req, "range")) |rh| {
        const allowed = blk: {
            const if_range = findHeader(req, "if-range") orelse break :blk true;
            break :blk ifRangeMatches(if_range, etag, mtime_sec);
        };
        const parsed = if (allowed) range.parse(rh, size) else range.Range.none;
        switch (parsed) {
            .none => {},
            .unsatisfiable => {
                var cr_buf: [64]u8 = undefined;
                const cr = std.fmt.bufPrint(&cr_buf, "bytes */{d}", .{size}) catch "bytes */*";
                const h = [_]http.Header{
                    .{ .name = "content-type", .value = "text/plain; charset=utf-8" },
                    .{ .name = "content-range", .value = cr },
                    .{ .name = "x-content-type-options", .value = "nosniff" },
                    .{ .name = "server", .value = server_version },
                };
                state.status = 416;
                state.bytes = try sendSimple(req, version, .range_not_satisfiable, "Range Not Satisfiable\n", keep_alive, &h);
                return;
            },
            .single => |s| {
                body_start = s.start;
                body_len = s.len();
                is_range = true;
                range_status = .partial_content;
            },
        }
    }

    if (is_range) {
        state.status = 206;
        state.bytes = try sendPartial(req, rel, file, range_status, headers, body_start, body_len, size, version, keep_alive, ctx.io);
        return;
    }

    state.status = 200;
    state.bytes = try sendFileStreaming(ctx.io, req, file, .ok, headers, 0, size, version, keep_alive);
}

fn sendPartial(
    req: *http.Server.Request,
    rel: []const u8,
    file: std.Io.File,
    status: http.Status,
    base_headers: []const http.Header,
    body_start: u64,
    body_len: u64,
    total_size: u64,
    version: http.Version,
    keep_alive: bool,
    io: std.Io,
) !u64 {
    _ = rel;
    var cr_buf: [64]u8 = undefined;
    const content_range = std.fmt.bufPrint(&cr_buf, "bytes {d}-{d}/{d}", .{ body_start, body_start + body_len - 1, total_size }) catch "bytes */*";
    var merged: [10]http.Header = undefined;
    @memcpy(merged[0..base_headers.len], base_headers);
    merged[base_headers.len] = .{ .name = "content-range", .value = content_range };
    return sendFileStreaming(io, req, file, status, merged[0 .. base_headers.len + 1], body_start, body_len, version, keep_alive);
}

fn sendFileStreaming(
    io: std.Io,
    req: *http.Server.Request,
    file: std.Io.File,
    status: http.Status,
    extra_headers: []const http.Header,
    offset: u64,
    len: u64,
    version: http.Version,
    keep_alive: bool,
) !u64 {
    var buffer: [file_chunk]u8 = undefined;
    var bw = try req.respondStreaming(&buffer, .{
        .content_length = len,
        .respond_options = .{
            .status = status,
            .version = version,
            .keep_alive = keep_alive,
            .extra_headers = extra_headers,
        },
    });

    if (bw.isEliding()) {
        // HEAD: feed the counting writer without touching the file.
        const zeros: [8192]u8 = @splat(0);
        var remaining = len;
        while (remaining > 0) {
            const n: usize = @intCast(@min(remaining, zeros.len));
            try bw.writer.writeAll(zeros[0..n]);
            remaining -= n;
        }
    } else {
        var read_buf: [file_chunk]u8 = undefined;
        var sent: u64 = 0;
        while (sent < len) {
            const want: usize = @intCast(@min(len - sent, read_buf.len));
            const n = try file.readPositional(io, &.{read_buf[0..want]}, offset + sent);
            if (n == 0) break;
            try bw.writer.writeAll(read_buf[0..n]);
            sent += n;
        }
    }
    try bw.end();
    return len;
}

/// Find a request header by case-insensitive name.
fn findHeader(req: *const http.Server.Request, name: []const u8) ?[]const u8 {
    var it = req.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    }
    return null;
}

fn weakEtag(etag: []const u8) []const u8 {
    if (std.mem.startsWith(u8, etag, "W/")) return etag[2..];
    return etag;
}

/// Weak comparison of an If-None-Match value against our ETag.
fn ifNoneMatchMatches(value: []const u8, etag: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, value, ',');
    const tag = weakEtag(etag);
    while (it.next()) |tok| {
        const t = std.mem.trim(u8, tok, " \t");
        if (std.mem.eql(u8, t, "*")) return true;
        if (std.mem.eql(u8, weakEtag(t), tag)) return true;
    }
    return false;
}

/// If-Range: either our ETag (weak comparison) or an HTTP date that is not
/// earlier than the file mtime.
fn ifRangeMatches(value: []const u8, etag: []const u8, mtime_sec: i64) bool {
    const trimmed = std.mem.trim(u8, value, " \t");
    if (std.mem.startsWith(u8, trimmed, "W/") or std.mem.startsWith(u8, trimmed, "\"")) {
        const tag = weakEtag(etag);
        const other = weakEtag(trimmed);
        return std.mem.eql(u8, tag, other);
    }
    if (timefmt.parseHttpDate(trimmed)) |seconds| {
        return mtime_sec <= seconds;
    }
    return false;
}

/// If-Modified-Since: not modified when the file mtime is not after the date.
fn ifModifiedSinceMatches(value: []const u8, mtime_sec: i64) bool {
    const trimmed = std.mem.trim(u8, value, " \t");
    const seconds = timefmt.parseHttpDate(trimmed) orelse return false;
    return mtime_sec <= seconds;
}

/// Small response with a known body. Sets Content-Length automatically.
fn sendSimple(
    req: *http.Server.Request,
    version: http.Version,
    status: http.Status,
    body: []const u8,
    keep_alive: bool,
    extra: []const http.Header,
) !u64 {
    var merged: [12]http.Header = undefined;
    var count = extra.len;
    std.mem.copyForwards(http.Header, merged[0..count], extra);
    if (!hasHeader(extra, "server")) {
        merged[count] = .{ .name = "server", .value = server_version };
        count += 1;
    }
    try req.respond(body, .{
        .status = status,
        .version = version,
        .keep_alive = keep_alive,
        .extra_headers = merged[0..count],
    });
    return body.len;
}

/// Bodyless response (e.g. 304). Writes Content-Length: 0, which keeps
/// the connection reusable under HTTP/1.1.
fn sendSimpleTransferNone(
    req: *http.Server.Request,
    version: http.Version,
    status: http.Status,
    extra: []const http.Header,
    keep_alive: bool,
) !u64 {
    return sendSimple(req, version, status, "", keep_alive, extra);
}

fn hasHeader(headers: []const http.Header, name: []const u8) bool {
    for (headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) return true;
    }
    return false;
}

fn serveListing(
    ctx: ConnectionContext,
    alloc: Allocator,
    req: *http.Server.Request,
    state: *RequestState,
    rel: []const u8,
    abs: []const u8,
) !void {
    const version = req.head.version;
    const keep_alive = req.head.keep_alive;

    var dir = std.Io.Dir.openDirAbsolute(ctx.io, abs, .{ .iterate = true }) catch {
        state.status = 500;
        state.bytes = try sendSimple(req, version, .internal_server_error, "Internal Server Error\n", keep_alive, &.{});
        return;
    };
    defer dir.close(ctx.io);

    var entries: std.ArrayList(listing.Entry) = .empty;
    defer entries.deinit(alloc);

    var it = dir.iterate();
    var truncated = false;
    while (it.next(ctx.io) catch null) |entry| {
        if (entries.items.len >= max_listing_entries) {
            truncated = true;
            break;
        }
        const is_dir = entry.kind == .directory;
        const name_copy = try alloc.dupe(u8, entry.name);
        var size: u64 = 0;
        if (!is_dir) {
            if (dir.statFile(ctx.io, entry.name, .{})) |stat| {
                size = stat.size;
            } else |_| {
                size = 0;
            }
        }
        try entries.append(alloc, .{ .name = name_copy, .is_dir = is_dir, .size = size });
    }

    std.mem.sort(listing.Entry, entries.items, {}, struct {
        fn lessThan(_: void, a: listing.Entry, b: listing.Entry) bool {
            if (a.is_dir != b.is_dir) return a.is_dir;
            return std.ascii.lessThanIgnoreCase(a.name, b.name);
        }
    }.lessThan);

    var display_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const display_path = if (rel.len == 0) "/" else blk: {
        if (rel.len + 2 > display_buf.len) return error.NameTooLong;
        display_buf[0] = '/';
        @memcpy(display_buf[1 .. rel.len + 1], rel);
        break :blk display_buf[0 .. rel.len + 1];
    };

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);
    try listing.render(alloc, &body, display_path, entries.items);
    if (truncated) {
        try body.appendSlice(alloc, "<p>Listing truncated at 1000 entries</p>\n");
    }

    state.status = 200;
    state.bytes = try sendSimple(req, version, .ok, body.items, keep_alive, &.{
        .{ .name = "content-type", .value = "text/html; charset=utf-8" },
        .{ .name = "cache-control", .value = "no-cache" },
    });
}

fn setReadTimeout(stream: std.Io.net.Stream, seconds: u32) void {
    if (comptime builtin.os.tag == .linux) {
        // On Linux, SO_RCVTIMEO keeps a silent client from holding a slot forever.
        const tv = std.posix.timeval{ .sec = @intCast(seconds), .usec = 0 };
        const rc = std.os.linux.setsockopt(stream.socket.handle, 1, 0x1006, @ptrCast(&tv), @sizeOf(@TypeOf(tv)));
        if (std.os.linux.errno(rc) != .SUCCESS) {
            // Best effort only; the server runs without the timeout.
        }
    }
}

fn installSignalHandlers() void {
    if (builtin.os.tag == .windows) return; // Default Ctrl+C behavior is fine.
    const handler = struct {
        fn handle(_: std.posix.SIG) callconv(.c) void {
            shutdown_requested.store(true, .release);
        }
    }.handle;
    const action = std.posix.Sigaction{
        .handler = .{ .handler = handler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &action, null);
    std.posix.sigaction(std.posix.SIG.TERM, &action, null);
}

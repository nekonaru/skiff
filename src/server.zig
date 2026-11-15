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
    response_started: bool = false,
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
        const allow = [_]http.Header{.{ .name = "allow", .value = "GET, HEAD" }};
        state.bytes = sendSimple(req, &state, version, .method_not_allowed, "Method Not Allowed\n", keep_alive, &allow) catch 0;
        return state;
    }

    const target = req.head.target;
    const query_start = std.mem.indexOfScalar(u8, target, '?');
    const path_part = if (query_start) |i| target[0..i] else target;
    const query_part: ?[]const u8 = if (query_start) |i| target[i..] else null;

    if (path_part.len == 0 or path_part[0] != '/') {
        state.status = 400;
        state.bytes = sendSimple(req, &state, version, .bad_request, "Bad Request\n", keep_alive, &.{}) catch 0;
        return state;
    }

    var rel_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const rel = fs_guard.normalize(path_part, &rel_buf) catch {
        state.status = 400;
        state.bytes = sendSimple(req, &state, version, .bad_request, "Bad Request\n", keep_alive, &.{}) catch 0;
        return state;
    };

    servePath(ctx, alloc, req, &state, rel, query_part) catch {
        state.status = 500;
        if (!state.response_started) {
            state.bytes = sendSimple(req, &state, version, .internal_server_error, "Internal Server Error\n", keep_alive, &.{}) catch 0;
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

    // Directory? Serve index.html, or the listing, or redirect to the
    // trailing-slash form. With --no-listing, missing index.html hides the
    // directory entirely (404, even with a trailing slash).
    if (openContainedDir(ctx, rel)) |d| {
        var dir = d;
        defer dir.close(ctx.io);

        const path_no_query = req.head.target[0 .. std.mem.indexOfScalar(u8, req.head.target, '?') orelse req.head.target.len];
        if (!std.mem.endsWith(u8, path_no_query, "/")) {
            // With --no-listing, directories are indistinguishable from missing paths.
            if (ctx.cfg.no_listing) {
                state.status = 404;
                state.bytes = try sendSimple(req, state, version, .not_found, "Not Found\n", keep_alive, &.{});
                return;
            }
            const location = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ path_no_query, if (query_part) |q| q else "" });
            defer alloc.free(location);
            const headers = [_]http.Header{.{ .name = "location", .value = location }};
            state.status = 301;
            state.bytes = try sendSimple(req, state, version, .moved_permanently, "Moved Permanently\n", keep_alive, &headers);
            return;
        }
        const index_rel = if (rel.len == 0) @constCast("index.html") else try std.fmt.allocPrint(alloc, "{s}/index.html", .{rel});
        defer if (rel.len != 0) alloc.free(index_rel);
        if (tryServeFile(ctx, req, state, index_rel)) return;
        if (ctx.cfg.no_listing) {
            state.status = 404;
            state.bytes = try sendSimple(req, state, version, .not_found, "Not Found\n", keep_alive, &.{});
            return;
        }
        return serveListing(ctx, alloc, req, state, rel, dir);
    } else |dir_err| switch (dir_err) {
        error.NotFound => {},
        error.Contains => {
            state.status = 403;
            state.bytes = try sendSimple(req, state, version, .forbidden, "Forbidden\n", keep_alive, &.{});
            return;
        },
        error.Internal => return error.Internal,
    }

    // Plain file.
    if (tryServeFile(ctx, req, state, rel)) return;

    if (ctx.cfg.spa) {
        if (tryServeFile(ctx, req, state, "index.html")) return;
    }

    state.status = 404;
    state.bytes = try sendSimple(req, state, version, .not_found, "Not Found\n", keep_alive, &.{});
}

/// Resolve `rel` to its absolute, containment-checked path on Linux/macOS.
/// Kept for macOS, where fd-path introspection is not portable.
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

/// Canonical path of an open directory or file handle, when the platform
/// allows it. Returns null elsewhere (e.g. macOS).
fn fdAbsPath(handle: anytype, out: []u8) ?usize {
    if (comptime builtin.os.tag == .linux) {
        var fd_path: [64]u8 = undefined;
        const pathz = std.fmt.bufPrintSentinel(&fd_path, "/proc/self/fd/{d}", .{@as(std.posix.fd_t, @intCast(handle))}, 0) catch return null;
        const n = std.os.linux.readlink(pathz.ptr, out.ptr, out.len);
        if (std.os.linux.errno(n) != .SUCCESS) return null;
        if (n == 0 or n >= out.len) return null;
        return n;
    }
    if (comptime builtin.os.tag == .windows) {
        var wide: [std.os.windows.PATH_MAX_WIDE]u16 = undefined;
        const wide_slice = std.Io.Threaded.GetFinalPathNameByHandle(
            @ptrCast(handle),
            .{ .volume_name = .Dos },
            &wide,
        ) catch return null;
        const len = std.unicode.wtf16LeToWtf8(out, wide_slice);
        if (len == 0 or len >= out.len) return null;
        return len;
    }
    return null;
}

/// Open `rel` as a file with the containment guarantee enforced on the
/// open handle itself (no check-then-open window on Linux and Windows).
/// On macOS this falls back to realpath-then-open (documented residual).
fn openContainedFile(ctx: ConnectionContext, rel: []const u8) error{ Contains, NotFound, Internal, IsDir }!std.Io.File {
    if (builtin.os.tag == .macos) {
        var abs_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const abs_len = resolveAbs(ctx, rel, &abs_buf) catch |err| switch (err) {
            error.NotFound => return error.NotFound,
            error.Contains => return error.Contains,
            error.Internal => return error.Internal,
        };
        return std.Io.Dir.openFileAbsolute(ctx.io, abs_buf[0..abs_len], .{}) catch |err| switch (err) {
            error.IsDir => return error.IsDir,
            error.FileNotFound, error.NotDir => return error.NotFound,
            else => return error.Internal,
        };
    }

    const linux_open = comptime builtin.os.tag == .linux;
    if (linux_open) {
        var relz_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const relz = std.fmt.bufPrintSentinel(&relz_buf, "{s}", .{rel}, 0) catch return error.Internal;
        const rc = std.os.linux.openat(ctx.root_dir.handle, relz.ptr, .{ .ACCMODE = .RDONLY, .NONBLOCK = true }, 0);
        if (std.os.linux.errno(rc) != .SUCCESS) {
            return switch (std.os.linux.errno(rc)) {
                .NOENT, .NOTDIR, .ACCES => error.NotFound,
                .ISDIR => error.IsDir,
                else => error.Internal,
            };
        }
        return finishFileContain(ctx, .{ .handle = @intCast(rc), .flags = .{ .nonblocking = true } });
    }

    const file = ctx.root_dir.openFile(ctx.io, rel, .{}) catch |err| switch (err) {
        error.IsDir => return error.IsDir,
        else => return error.NotFound,
    };
    return finishFileContain(ctx, file);
}

fn finishFileContain(ctx: ConnectionContext, file: std.Io.File) error{ Contains, Internal }!std.Io.File {
    var abs_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const abs_len = fdAbsPath(file.handle, &abs_buf) orelse {
        file.close(ctx.io);
        return error.Internal;
    };
    if (!fs_guard.isPathInside(ctx.root_real, abs_buf[0..abs_len])) {
        file.close(ctx.io);
        return error.Contains;
    }
    return file;
}

/// Open `rel` as a directory (iterate access) with containment enforced on the
/// open handle. macOS falls back to realpath-then-open.
fn openContainedDir(ctx: ConnectionContext, rel: []const u8) error{ Contains, NotFound, Internal }!std.Io.Dir {
    if (builtin.os.tag == .macos) {
        var abs_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const abs_len = resolveAbs(ctx, rel, &abs_buf) catch |err| switch (err) {
            error.NotFound => return error.NotFound,
            error.Contains => return error.Contains,
            error.Internal => return error.Internal,
        };
        return std.Io.Dir.openDirAbsolute(ctx.io, abs_buf[0..abs_len], .{ .iterate = true }) catch error.NotFound;
    }

    var dir = ctx.root_dir.openDir(ctx.io, if (rel.len == 0) "." else rel, .{ .iterate = true }) catch return error.NotFound;
    var abs_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const abs_len = fdAbsPath(dir.handle, &abs_buf) orelse {
        dir.close(ctx.io);
        return error.Internal;
    };
    if (!fs_guard.isPathInside(ctx.root_real, abs_buf[0..abs_len])) {
        dir.close(ctx.io);
        return error.Contains;
    }
    return dir;
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

    var file = openContainedFile(ctx, rel) catch |err| switch (err) {
        error.NotFound, error.IsDir => return false,
        error.Contains => {
            state.status = 403;
            state.bytes = sendSimple(req, state, version, .forbidden, "Forbidden\n", keep_alive, &.{}) catch 0;
            return true;
        },
        error.Internal => {
            state.status = 500;
            state.bytes = sendSimple(req, state, version, .internal_server_error, "Internal Server Error\n", keep_alive, &.{}) catch 0;
            return true;
        },
    };
    defer file.close(ctx.io);
    const stat = file.stat(ctx.io) catch return false;
    if (stat.kind != .file) return false;

    streamFile(ctx, req, state, rel, file, stat) catch {
        state.status = 500;
        if (!state.response_started) {
            state.bytes = sendSimple(req, state, version, .internal_server_error, "Internal Server Error\n", keep_alive, &.{}) catch 0;
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
    state.response_started = true;
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
        state.bytes = try sendSimpleTransferNone(req, state, version, .not_modified, headers_304, keep_alive);
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
                state.bytes = try sendSimple(req, state, version, .range_not_satisfiable, "Range Not Satisfiable\n", keep_alive, &h);
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

/// If-Range: exact match against our (weak) ETag is the only entity-tag
/// comparison that can pass, since we never send a strong ETag; a quoted
/// strong form can never match it, which is correct under RFC 7233's strong
/// comparison. A date is honored only when it is not earlier than the file
/// mtime.
fn ifRangeMatches(value: []const u8, etag: []const u8, mtime_sec: i64) bool {
    const trimmed = std.mem.trim(u8, value, " \t");
    if (std.mem.startsWith(u8, trimmed, "\"") or std.mem.startsWith(u8, trimmed, "W/")) {
        return std.mem.eql(u8, trimmed, etag);
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
    state: *RequestState,
    version: http.Version,
    status: http.Status,
    body: []const u8,
    keep_alive: bool,
    extra: []const http.Header,
) !u64 {
    state.response_started = true;
    var merged: [14]http.Header = undefined;
    var count = extra.len;
    std.mem.copyForwards(http.Header, merged[0..count], extra);
    if (!hasHeader(extra, "content-type")) {
        merged[count] = .{ .name = "content-type", .value = "text/plain; charset=utf-8" };
        count += 1;
    }
    if (!hasHeader(extra, "x-content-type-options")) {
        merged[count] = .{ .name = "x-content-type-options", .value = "nosniff" };
        count += 1;
    }
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
    state: *RequestState,
    version: http.Version,
    status: http.Status,
    extra: []const http.Header,
    keep_alive: bool,
) !u64 {
    return sendSimple(req, state, version, status, "", keep_alive, extra);
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
    dir_handle: std.Io.Dir,
) !void {
    const version = req.head.version;
    const keep_alive = req.head.keep_alive;

    // Ownership of the directory handle stays with the caller.
    var dir = dir_handle;

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
        const is_link = entry.kind == .sym_link;
        const name_copy = try alloc.dupe(u8, entry.name);
        var size: u64 = 0;
        if (!is_dir and !is_link) {
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
    state.bytes = try sendSimple(req, state, version, .ok, body.items, keep_alive, &.{
        .{ .name = "content-type", .value = "text/html; charset=utf-8" },
        .{ .name = "cache-control", .value = "no-cache" },
        .{ .name = "content-security-policy", .value = "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'" },
    });
}

fn setReadTimeout(stream: std.Io.net.Stream, seconds: u32) void {
    const handle = stream.socket.handle;
    switch (comptime builtin.os.tag) {
        .linux => linuxSetSocketTimeouts(handle, seconds),
        .windows => windowsSetSocketTimeouts(handle, seconds),
        .macos => macosSetSocketTimeouts(handle, seconds),
        else => {},
    }
}

/// Log the timeout failure at most once per process.
fn logTimeoutFailureOnce(comptime what: []const u8) void {
    const State = struct {
        var warned = std.atomic.Value(bool).init(false);
    };
    if (State.warned.swap(true, .acq_rel)) return;
    std.debug.print("skiff: warning: could not set {s} socket timeout; idle connections may linger\n", .{what});
}

fn logTimeoutFailure(comptime what: []const u8) void {
    logTimeoutFailureOnce(what);
}

fn linuxSetSocketTimeouts(handle: std.posix.fd_t, seconds: u32) void {
    const tv = std.posix.timeval{ .sec = @intCast(seconds), .usec = 0 };
    const optval = @as([*]const u8, @ptrCast(&tv));
    const len: u32 = @sizeOf(@TypeOf(tv));
    const rcv = std.os.linux.setsockopt(handle, 1, std.os.linux.SO.RCVTIMEO, optval, len);
    if (std.os.linux.errno(rcv) != .SUCCESS) logTimeoutFailure("read");
    const snd = std.os.linux.setsockopt(handle, 1, std.os.linux.SO.SNDTIMEO, optval, len);
    if (std.os.linux.errno(snd) != .SUCCESS) logTimeoutFailure("write");
}

fn windowsSetSocketTimeouts(handle: std.posix.fd_t, seconds: u32) void {
    _ = handle;
    _ = seconds;
    // Zig's Windows sockets are AFD handles; the AFD driver does not support
    // SO_RCVTIMEO/SO_SNDTIMEO (confirmed: NtDeviceIoControlFile returns
    // STATUS_NOT_SUPPORTED), and the Winsock timeout lives in ws2_32.dll,
    // which does not apply to AFD handles. There is no stdlib path to an
    // idle read timeout on Windows; documented in docs/decisions.md.
}

fn macosSetSocketTimeouts(handle: std.posix.fd_t, seconds: u32) void {
    const Timeval = extern struct { sec: i64, usec: i32 };
    const tv = Timeval{ .sec = @intCast(seconds), .usec = 0 };
    const rc = setsockopt(handle, 0xffff, 0x1006, @ptrCast(&tv), @sizeOf(Timeval));
    if (rc != 0) logTimeoutFailure("read");
    const rc2 = setsockopt(handle, 0xffff, 0x1005, @ptrCast(&tv), @sizeOf(Timeval));
    if (rc2 != 0) logTimeoutFailure("write");
}

extern "c" fn setsockopt(
    fd: std.posix.fd_t,
    level: i32,
    optname: i32,
    optval: [*]const u8,
    optlen: u32,
) i32;

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

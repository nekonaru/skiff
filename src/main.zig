const std = @import("std");
const cli = @import("cli.zig");

pub const version = cli.version;

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    var args_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, alloc);
    defer args_it.deinit();

    var argv: std.ArrayList([:0]const u8) = .empty;
    while (args_it.next()) |arg| {
        try argv.append(alloc, arg);
    }

    var stdout_buf: [2048]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const out = &stdout_writer.interface;

    const result = cli.parse(if (argv.items.len > 0) argv.items[1..] else argv.items) catch |err| switch (err) {
        error.MissingValue, error.InvalidPort, error.UnknownOption => {
            var stderr_buf: [256]u8 = undefined;
            var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
            const err_out = &stderr_writer.interface;
            try err_out.print("skiff: {s} (see --help)\n", .{@errorName(err)});
            try err_out.flush();
            std.process.exit(2);
        },
    };

    switch (result) {
        .help => {
            try out.writeAll(cli.help_text);
            try out.flush();
        },
        .version => {
            try out.print("skiff {s}\n", .{version});
            try out.flush();
        },
        .config => |_| {
            // Serving lands in milestone M1. Skeleton exits 0 so the
            // toolchain and CI can be exercised end to end.
            try out.print("skiff {s} (skeleton)\n", .{version});
            try out.flush();
        },
    }
}

test {
    _ = cli;
}

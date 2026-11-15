const std = @import("std");

/// Minimal civil-from-days date conversion (Howard Hinnant's algorithm)
/// so HTTP dates and log lines do not need extra std machinery.

fn civilFromDays(z: i64) struct { year: i32, month: u8, day: u8 } {
    const shifted = z + 719468;
    const era = @divFloor(shifted, 146097);
    const doe: u64 = @intCast(shifted - era * 146097);
    const yoe: u64 = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    const y: i64 = @as(i64, @intCast(yoe)) + era * 400;
    const doy: u64 = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp: u64 = (5 * doy + 2) / 153;
    const d: u8 = @intCast(doy - (153 * mp + 2) / 5 + 1);
    const m: u8 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    const year: i32 = @intCast(if (m <= 2) y + 1 else y);
    return .{ .year = year, .month = m, .day = d };
}

fn weekdays(z: i64) u8 {
    // 1970-01-01 was a Thursday. 0 = Sunday .. 6 = Saturday.
    const wd = @mod(z + 4, 7);
    return @intCast(wd);
}

const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
const day_names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };

/// Format seconds since the Unix epoch as an IMF-fixdate HTTP date
/// (e.g. "Wed, 16 Nov 2026 12:34:56 GMT"). `out` must be 29 bytes.
pub fn httpDate(seconds: i64, out: *[29]u8) []const u8 {
    const days = @divFloor(seconds, 86400);
    const secs_of_day = seconds - days * 86400;
    const date = civilFromDays(days);
    const wd = weekdays(days);
    const h = @divFloor(secs_of_day, 3600);
    const mi = @divFloor(@mod(secs_of_day, 3600), 60);
    const s = @mod(secs_of_day, 60);
    const slice = std.fmt.bufPrint(out, "{s}, {d:0>2} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} GMT", .{
        day_names[wd], date.day, month_names[date.month - 1], date.year,
        @as(u64, @intCast(h)), @as(u64, @intCast(mi)), @as(u64, @intCast(s)),
    }) catch unreachable;
    return slice;
}

/// Format seconds since the Unix epoch as "YYYY-MM-DD HH:MM:SS" for logs.
pub fn logTimestamp(seconds: i64, out: *[19]u8) []const u8 {
    const days = @divFloor(seconds, 86400);
    const secs_of_day = seconds - days * 86400;
    const date = civilFromDays(days);
    const h = @divFloor(secs_of_day, 3600);
    const mi = @divFloor(@mod(secs_of_day, 3600), 60);
    const s = @mod(secs_of_day, 60);
    const slice = std.fmt.bufPrint(out, "{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        date.year, date.month, date.day,
        @as(u64, @intCast(h)), @as(u64, @intCast(mi)), @as(u64, @intCast(s)),
    }) catch unreachable;
    return slice;
}

/// Seconds since the Unix epoch for a civil date+time (inverse of the above).
fn daysFromCivil(year: i64, month: u8, day: u8) i64 {
    var y = year;
    if (month <= 2) y -= 1;
    const era = @divFloor(y, 400);
    const yoe: u64 = @intCast(y - era * 400);
    const mp: u64 = if (month > 2) month - 3 else month + 9;
    const doy: u64 = (153 * mp + 2) / 5 + @as(u64, day) - 1;
    const doe: u64 = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146097 + @as(i64, @intCast(doe)) - 719468;
}

const month_from_name = [_]struct { name: []const u8, value: u8 }{
    .{ .name = "jan", .value = 1 }, .{ .name = "feb", .value = 2 }, .{ .name = "mar", .value = 3 },
    .{ .name = "apr", .value = 4 }, .{ .name = "may", .value = 5 }, .{ .name = "jun", .value = 6 },
    .{ .name = "jul", .value = 7 }, .{ .name = "aug", .value = 8 }, .{ .name = "sep", .value = 9 },
    .{ .name = "oct", .value = 10 }, .{ .name = "nov", .value = 11 }, .{ .name = "dec", .value = 12 },
};

fn monthByName(name: []const u8) ?u8 {
    for (month_from_name) |m| {
        if (std.ascii.eqlIgnoreCase(m.name, name)) return m.value;
    }
    return null;
}

/// Parse an HTTP date in any of the three formats from RFC 7231:
/// - IMF-fixdate:  "Wed, 16 Nov 2026 12:34:56 GMT"
/// - RFC 850:      "Wednesday, 16-Nov-06 12:34:56 GMT"
/// - ANSI C asctime: "Wed Nov 16 12:34:56 2026"
/// Returns seconds since the Unix epoch, or null when invalid.
pub fn parseHttpDate(text: []const u8) ?i64 {
    var input = std.mem.trim(u8, text, " \t");

    // RFC 7231 dates end in GMT (or UTC); asctime has no zone designator.
    if (std.ascii.endsWithIgnoreCase(input, " gmt")) {
        input = input[0 .. input.len - 4];
    } else if (std.ascii.endsWithIgnoreCase(input, " utc")) {
        input = input[0 .. input.len - 4];
    } else if (input.len == 0 or std.mem.find(u8, input, ",") != null) {
        // RFC formats are required to carry GMT; reject a missing zone.
        return null;
    }
    input = std.mem.trim(u8, input, " \t");

    // Tokenize, then separate the time token (the only one with ':').
    var tokens: [10][]const u8 = undefined;
    var n: usize = 0;
    {
        var it2 = std.mem.tokenizeAny(u8, input, " ,-");
        while (it2.next()) |tok| {
            if (n == tokens.len) return null;
            tokens[n] = tok;
            n += 1;
        }
    }
    var time_index: ?usize = null;
    for (tokens[0..n], 0..) |tok, i| {
        if (std.mem.indexOfScalar(u8, tok, ':') != null) {
            time_index = i;
            break;
        }
    }
    const ti = time_index orelse return null;
    const time_part = tokens[ti];

    var day: ?u8 = null;
    var month: ?u8 = null;
    var year: ?i64 = null;
    for (tokens[0..n], 0..) |tok, i| {
        if (i == ti) continue;
        if (isWeekday(tok)) continue;
        if (monthByName(tok)) |m| {
            if (month != null) return null;
            month = m;
            continue;
        }
        const value = std.fmt.parseInt(i64, tok, 10) catch return null;
        if (value <= 31 and day == null) {
            day = @intCast(value);
        } else if (year == null) {
            year = parseYear(tok) orelse return null;
        } else {
            return null;
        }
    }

    const day_v = day orelse return null;
    if (day_v < 1 or day_v > 31) return null;
    const month_v = month orelse return null;
    const year_v = year orelse return null;

    var time_parts = std.mem.tokenizeScalar(u8, time_part, ':');
    const hour = std.fmt.parseInt(u8, time_parts.next() orelse return null, 10) catch return null;
    const minute = std.fmt.parseInt(u8, time_parts.next() orelse return null, 10) catch return null;
    const second = std.fmt.parseInt(u8, time_parts.next() orelse return null, 10) catch return null;
    if (hour > 23 or minute > 59 or second > 60) return null;

    const days = daysFromCivil(year_v, month_v, day_v);
    return days * 86400 + @as(i64, hour) * 3600 + @as(i64, minute) * 60 + @as(i64, second);
}

fn isWeekday(name: []const u8) bool {
    const day_names_lower = [_][]const u8{
        "sun", "mon", "tue", "wed", "thu", "fri", "sat",
        "sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday",
    };
    for (day_names_lower) |w| {
        if (std.ascii.eqlIgnoreCase(w, name)) return true;
    }
    return false;
}

fn parseYear(text: []const u8) ?i64 {
    const year = std.fmt.parseInt(i64, text, 10) catch return null;
    if (year < 100) {
        // RFC 850 two-digit years: 00-49 -> 2000s, 50-99 -> 1900s.
        return if (year <= 49) 2000 + year else 1900 + year;
    }
    if (year < 1970 or year > 9999) return null;
    return year;
}

test "parseHttpDate" {
    try std.testing.expectEqual(@as(?i64, 1234567890), parseHttpDate("Fri, 13 Feb 2009 23:31:30 GMT"));
    try std.testing.expectEqual(@as(?i64, 1234567890), parseHttpDate("Friday, 13-Feb-09 23:31:30 GMT"));
    try std.testing.expectEqual(@as(?i64, 1234567890), parseHttpDate("Fri Feb 13 23:31:30 2009"));
    try std.testing.expectEqual(@as(?i64, 0), parseHttpDate("Thu, 01 Jan 1970 00:00:00 GMT"));
    try std.testing.expectEqual(@as(?i64, null), parseHttpDate("not a date"));
    try std.testing.expectEqual(@as(?i64, null), parseHttpDate("Fri, 99 Feb 2009 23:31:30 GMT"));
    try std.testing.expectEqual(@as(?i64, 1794787200), parseHttpDate("Mon, 16 Nov 2026 00:00:00 GMT"));
}

test "httpDate known values" {
    var out: [29]u8 = undefined;
    // 1970-01-01 00:00:00 UTC was a Thursday.
    try std.testing.expectEqualStrings("Thu, 01 Jan 1970 00:00:00 GMT", httpDate(0, &out));
    // 2026-11-16 00:00:00 UTC
    try std.testing.expectEqualStrings("Mon, 16 Nov 2026 00:00:00 GMT", httpDate(1794787200, &out));
    // 2009-02-13 23:31:30 UTC, known Friday
    try std.testing.expectEqualStrings("Fri, 13 Feb 2009 23:31:30 GMT", httpDate(1234567890, &out));
    // Leap day handling: 2024-02-29 12:00:00 UTC was a Thursday
    try std.testing.expectEqualStrings("Thu, 29 Feb 2024 12:00:00 GMT", httpDate(1709208000, &out));
}

test "logTimestamp" {
    var out: [19]u8 = undefined;
    try std.testing.expectEqualStrings("1970-01-01 00:00:00", logTimestamp(0, &out));
    try std.testing.expectEqualStrings("2009-02-13 23:31:30", logTimestamp(1234567890, &out));
}

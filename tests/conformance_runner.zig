const std = @import("std");

const action_property = "mf:action";

pub fn run(comptime config: anytype) !void {
    const allocator = std.testing.allocator;
    const manifest = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        config.suite_dir ++ "manifest.ttl",
        allocator,
        .limited(1024 * 1024),
    );
    defer allocator.free(manifest);

    var cursor: usize = 0;
    var case_count: usize = 0;
    while (nextCase(manifest, cursor, config.positive_type, config.negative_type)) |case| {
        cursor = case.next;
        case_count += 1;
        try runCase(config, case);
    }

    // Pin the expected manifest size so a corpus refresh cannot silently skip cases.
    try std.testing.expectEqual(@as(usize, config.expected_count), case_count);
}

fn runCase(comptime config: anytype, case: Case) !void {
    const allocator = std.testing.allocator;
    var path_buffer: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, config.suite_dir ++ "{s}", .{case.action});
    const input = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(1024 * 1024),
    );
    defer allocator.free(input);

    if (case.positive) {
        var owner = config.parse(allocator, input) catch |err| {
            std.log.err("W3C positive syntax case {s} failed: {s}", .{ case.action, @errorName(err) });
            return error.ConformanceFailure;
        };
        owner.deinit();
    } else {
        if (config.parse(allocator, input)) |owner_value| {
            var owner = owner_value;
            owner.deinit();
            std.log.err("W3C negative syntax case {s} was accepted", .{case.action});
            return error.ConformanceFailure;
        } else |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {},
        }
    }
}

const Case = struct {
    action: []const u8,
    positive: bool,
    next: usize,
};

fn nextCase(
    manifest: []const u8,
    start: usize,
    positive_type: []const u8,
    negative_type: []const u8,
) ?Case {
    const positive_at = std.mem.indexOfPos(u8, manifest, start, positive_type);
    const negative_at = std.mem.indexOfPos(u8, manifest, start, negative_type);

    const type_at: usize, const positive: bool = if (positive_at) |position|
        if (negative_at) |negative_position|
            if (position < negative_position) .{ position, true } else .{ negative_position, false }
        else
            .{ position, true }
    else if (negative_at) |position|
        .{ position, false }
    else
        return null;

    const action_at = std.mem.indexOfPos(u8, manifest, type_at, action_property) orelse return null;
    const open = std.mem.indexOfScalarPos(u8, manifest, action_at, '<') orelse return null;
    const close = std.mem.indexOfScalarPos(u8, manifest, open + 1, '>') orelse return null;
    return .{
        .action = manifest[open + 1 .. close],
        .positive = positive,
        .next = close + 1,
    };
}

const std = @import("std");
const zigmantic = @import("zigmantic");

const Kind = enum { positive, negative };

const Case = struct {
    id: []const u8,
    action: []const u8,
    kind: Kind,
};

pub fn run(comptime config: anytype) !void {
    const allocator = std.testing.allocator;
    const manifest = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        config.suite_dir ++ "manifest.ttl",
        allocator,
        .limited(2 * 1024 * 1024),
    );
    defer allocator.free(manifest);

    const entries_at = std.mem.indexOf(u8, manifest, "mf:entries") orelse
        return error.InvalidManifest;
    const entries_open = std.mem.indexOfScalarPos(u8, manifest, entries_at, '(') orelse
        return error.InvalidManifest;
    const entries_close = std.mem.indexOfPos(u8, manifest, entries_open, ") .") orelse
        return error.InvalidManifest;

    var case_count: usize = 0;
    var positive_count: usize = 0;
    var negative_count: usize = 0;
    var expected_failure_count: usize = 0;
    var unexpected: usize = 0;
    var lines = std.mem.splitScalar(u8, manifest[entries_open + 1 .. entries_close], '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        if (trimmed[0] != ':') return error.InvalidManifest;
        const id = trimmed[1..];

        const case = try readCase(manifest, entries_close, id);
        switch (case.kind) {
            .positive => positive_count += 1,
            .negative => negative_count += 1,
        }
        const passed = try runCase(config.suite_dir, case);
        const expected_failure = contains(config.expected_failures, id);
        if (expected_failure) expected_failure_count += 1;
        if (passed == expected_failure) {
            unexpected += 1;
            if (passed) {
                std.log.err("W3C SPARQL syntax case {s} unexpectedly passed", .{id});
            } else {
                std.log.err("W3C SPARQL syntax case {s} failed", .{id});
            }
        }
        case_count += 1;
    }

    try std.testing.expectEqual(@as(usize, config.expected_count), case_count);
    try std.testing.expectEqual(@as(usize, config.expected_positive_count), positive_count);
    try std.testing.expectEqual(@as(usize, config.expected_negative_count), negative_count);
    try std.testing.expectEqual(@as(usize, config.expected_failures.len), expected_failure_count);
    try std.testing.expectEqual(@as(usize, 0), unexpected);
}

fn readCase(manifest: []const u8, definitions_start: usize, id: []const u8) !Case {
    var marker_buffer: [256]u8 = undefined;
    const marker = try std.fmt.bufPrint(&marker_buffer, ":{s} rdf:type", .{id});
    const definition_at = std.mem.indexOfPos(u8, manifest, definitions_start, marker) orelse
        return error.InvalidManifest;
    const block_end = std.mem.indexOfPos(u8, manifest, definition_at + marker.len, "\n:") orelse
        manifest.len;
    const block = manifest[definition_at..block_end];

    const kind: Kind = if (std.mem.indexOf(u8, block, "mf:PositiveSyntaxTest11") != null)
        .positive
    else if (std.mem.indexOf(u8, block, "mf:NegativeSyntaxTest11") != null)
        .negative
    else
        return error.InvalidManifest;

    return .{
        .id = id,
        .action = propertyReference(block, "mf:action") orelse return error.InvalidManifest,
        .kind = kind,
    };
}

fn propertyReference(block: []const u8, property: []const u8) ?[]const u8 {
    const property_at = std.mem.indexOf(u8, block, property) orelse return null;
    const open = std.mem.indexOfScalarPos(u8, block, property_at + property.len, '<') orelse
        return null;
    const close = std.mem.indexOfScalarPos(u8, block, open + 1, '>') orelse return null;
    return block[open + 1 .. close];
}

fn runCase(comptime suite_dir: []const u8, case: Case) !bool {
    const allocator = std.testing.allocator;
    const input = try readSuiteFile(allocator, suite_dir, case.action);
    defer allocator.free(input);

    const accepted = if (zigmantic.sparql.parseQuery(allocator, input)) |query_value| accepted: {
        var query = query_value;
        query.deinit();
        break :accepted true;
    } else |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidUtf8, error.InvalidSyntax => false,
    };
    return accepted == (case.kind == .positive);
}

fn readSuiteFile(
    allocator: std.mem.Allocator,
    comptime suite_dir: []const u8,
    name: []const u8,
) ![]u8 {
    var path_buffer: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, suite_dir ++ "{s}", .{name});
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(2 * 1024 * 1024),
    );
}

fn contains(comptime values: []const []const u8, needle: []const u8) bool {
    inline for (values) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
}

const std = @import("std");
const zigmantic = @import("zigmantic");

const suite_dir = "tests/conformance/rdf11-ntriples/";
const positive_type = "rdf:type rdft:TestNTriplesPositiveSyntax";
const negative_type = "rdf:type rdft:TestNTriplesNegativeSyntax";
const action_property = "mf:action";

test "W3C RDF 1.1 N-Triples syntax manifest" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const manifest = try std.Io.Dir.cwd().readFileAlloc(
        io,
        suite_dir ++ "manifest.ttl",
        allocator,
        .limited(1024 * 1024),
    );
    defer allocator.free(manifest);

    var cursor: usize = 0;
    var case_count: usize = 0;
    while (nextCase(manifest, cursor)) |case| {
        cursor = case.next;
        case_count += 1;

        var path_buffer: [512]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, suite_dir ++ "{s}", .{case.action});
        const input = try std.Io.Dir.cwd().readFileAlloc(
            io,
            path,
            allocator,
            .limited(1024 * 1024),
        );
        defer allocator.free(input);

        if (case.positive) {
            var graph = zigmantic.rdf_io.parseNTriples(allocator, input) catch |err| {
                std.log.err("W3C positive syntax case {s} failed: {s}", .{ case.action, @errorName(err) });
                return error.ConformanceFailure;
            };
            graph.deinit();
        } else {
            if (zigmantic.rdf_io.parseNTriples(allocator, input)) |graph_value| {
                var graph = graph_value;
                graph.deinit();
                std.log.err("W3C negative syntax case {s} was accepted", .{case.action});
                return error.ConformanceFailure;
            } else |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {},
            }
        }
    }

    // Pin the expected manifest size so an upstream refresh cannot silently skip cases.
    try std.testing.expectEqual(@as(usize, 70), case_count);
}

const Case = struct {
    action: []const u8,
    positive: bool,
    next: usize,
};

fn nextCase(manifest: []const u8, start: usize) ?Case {
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

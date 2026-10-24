const std = @import("std");
const zigmantic = @import("zigmantic");

const rdf = zigmantic.rdf;
const rdf_io = zigmantic.rdf_io;

const Kind = enum { positive_syntax, negative_syntax, evaluation };

const Case = struct {
    id: []const u8,
    action: []const u8,
    result: ?[]const u8,
    kind: Kind,
};

const Mapping = struct {
    actual: rdf.TermId,
    expected: rdf.TermId,
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
    const entries_close = std.mem.indexOfPos(u8, manifest, entries_open, "\n    )") orelse
        return error.InvalidManifest;

    var cursor = entries_open + 1;
    var case_count: usize = 0;
    var expected_failure_count: usize = 0;
    var unexpected: usize = 0;
    while (std.mem.indexOfPos(u8, manifest, cursor, "<#")) |id_open| {
        if (id_open >= entries_close) break;
        const id_close = std.mem.indexOfScalarPos(u8, manifest, id_open, '>') orelse
            return error.InvalidManifest;
        const id = manifest[id_open + 2 .. id_close];
        cursor = id_close + 1;

        const case = try readCase(manifest, entries_close, id);
        const passed = try runCase(config.suite_dir, case);
        const expected_failure = contains(config.expected_failures, id);
        if (expected_failure) expected_failure_count += 1;
        if (passed == expected_failure) {
            unexpected += 1;
            if (passed) {
                std.log.err("W3C TriG case {s} unexpectedly passed", .{id});
            } else {
                std.log.err("W3C TriG case {s} failed", .{id});
            }
        }
        case_count += 1;
    }

    try std.testing.expectEqual(@as(usize, config.expected_count), case_count);
    try std.testing.expectEqual(@as(usize, config.expected_failures.len), expected_failure_count);
    try std.testing.expectEqual(@as(usize, 0), unexpected);
}

fn readCase(manifest: []const u8, definitions_start: usize, id: []const u8) !Case {
    var id_buffer: [256]u8 = undefined;
    const marker = try std.fmt.bufPrint(&id_buffer, "<#{s}>", .{id});
    const definition_at = std.mem.indexOfPos(u8, manifest, definitions_start, marker) orelse
        return error.InvalidManifest;
    const block_end = std.mem.indexOfPos(u8, manifest, definition_at, "\n\n") orelse
        manifest.len;
    const block = manifest[definition_at..block_end];

    const kind: Kind = if (std.mem.indexOf(u8, block, "rdft:TestTrigPositiveSyntax") != null)
        .positive_syntax
    else if (std.mem.indexOf(u8, block, "rdft:TestTrigNegativeSyntax") != null)
        .negative_syntax
    else if (std.mem.indexOf(u8, block, "rdft:TestTrigEval") != null)
        .evaluation
    else
        return error.InvalidManifest;

    return .{
        .id = id,
        .action = propertyReference(block, "mf:action") orelse return error.InvalidManifest,
        .result = propertyReference(block, "mf:result"),
        .kind = kind,
    };
}

fn propertyReference(block: []const u8, property: []const u8) ?[]const u8 {
    const property_at = std.mem.indexOf(u8, block, property) orelse return null;
    const open = std.mem.indexOfScalarPos(u8, block, property_at, '<') orelse return null;
    const close = std.mem.indexOfScalarPos(u8, block, open + 1, '>') orelse return null;
    return block[open + 1 .. close];
}

fn runCase(comptime suite_dir: []const u8, case: Case) !bool {
    const allocator = std.testing.allocator;
    const input = try readSuiteFile(allocator, suite_dir, case.action);
    defer allocator.free(input);

    var base_buffer: [512]u8 = undefined;
    const base = try std.fmt.bufPrint(
        &base_buffer,
        "https://w3c.github.io/rdf-tests/rdf/rdf11/rdf-trig/{s}",
        .{case.action},
    );

    if (case.kind == .negative_syntax) {
        if (rdf_io.parseTriG(allocator, input, .{ .base_iri = base })) |dataset_value| {
            var dataset = dataset_value;
            dataset.deinit();
            return false;
        } else |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => true,
        };
    }

    var actual = rdf_io.parseTriG(allocator, input, .{ .base_iri = base }) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return false;
    };
    defer actual.deinit();
    if (case.kind == .positive_syntax) return true;

    const result_name = case.result orelse return error.InvalidManifest;
    const expected_input = try readSuiteFile(allocator, suite_dir, result_name);
    defer allocator.free(expected_input);
    var expected = try rdf_io.parseNQuads(allocator, expected_input);
    defer expected.deinit();
    return datasetsAreIsomorphic(allocator, &actual, &expected);
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

fn datasetsAreIsomorphic(
    allocator: std.mem.Allocator,
    actual: *const rdf.Dataset,
    expected: *const rdf.Dataset,
) !bool {
    if (actual.len() != expected.len()) return false;
    const used = try allocator.alloc(bool, expected.len());
    defer allocator.free(used);
    @memset(used, false);
    var mappings: std.ArrayList(Mapping) = .empty;
    defer mappings.deinit(allocator);
    return matchQuads(allocator, actual, expected, 0, used, &mappings);
}

fn matchQuads(
    allocator: std.mem.Allocator,
    actual: *const rdf.Dataset,
    expected: *const rdf.Dataset,
    actual_index: usize,
    used: []bool,
    mappings: *std.ArrayList(Mapping),
) !bool {
    if (actual_index == actual.len()) return true;
    const quad = actual.items()[actual_index];

    for (expected.items(), 0..) |candidate, expected_index| {
        if (used[expected_index]) continue;
        const mapping_count = mappings.items.len;
        if (try quadsMatch(allocator, actual, quad, expected, candidate, mappings)) {
            used[expected_index] = true;
            if (try matchQuads(allocator, actual, expected, actual_index + 1, used, mappings)) {
                return true;
            }
            used[expected_index] = false;
        }
        mappings.items.len = mapping_count;
    }
    return false;
}

fn quadsMatch(
    allocator: std.mem.Allocator,
    actual: *const rdf.Dataset,
    left: rdf.Quad,
    expected: *const rdf.Dataset,
    right: rdf.Quad,
    mappings: *std.ArrayList(Mapping),
) !bool {
    if (!try graphNamesMatch(allocator, actual, left.graph_name, expected, right.graph_name, mappings)) return false;
    if (!try termsMatch(allocator, actual, left.predicate, expected, right.predicate, mappings)) return false;
    if (!try termsMatch(allocator, actual, left.subject, expected, right.subject, mappings)) return false;
    return termsMatch(allocator, actual, left.object, expected, right.object, mappings);
}

fn graphNamesMatch(
    allocator: std.mem.Allocator,
    actual: *const rdf.Dataset,
    left: rdf.GraphName,
    expected: *const rdf.Dataset,
    right: rdf.GraphName,
    mappings: *std.ArrayList(Mapping),
) !bool {
    return switch (left) {
        .default => right == .default,
        .named => |left_id| switch (right) {
            .default => false,
            .named => |right_id| termsMatch(
                allocator,
                actual,
                left_id,
                expected,
                right_id,
                mappings,
            ),
        },
    };
}

fn termsMatch(
    allocator: std.mem.Allocator,
    actual: *const rdf.Dataset,
    left: rdf.TermId,
    expected: *const rdf.Dataset,
    right: rdf.TermId,
    mappings: *std.ArrayList(Mapping),
) !bool {
    const left_value = actual.terms.view(left) orelse return false;
    const right_value = expected.terms.view(right) orelse return false;
    if (left_value != .blank_node or right_value != .blank_node) {
        if (left_value == .blank_node or right_value == .blank_node) return false;
        return actual.terms.eqlTerm(left, &expected.terms, right);
    }

    for (mappings.items) |mapping| {
        if (mapping.actual == left) return mapping.expected == right;
        if (mapping.expected == right) return false;
    }
    try mappings.append(allocator, .{ .actual = left, .expected = right });
    return true;
}

fn contains(comptime values: []const []const u8, needle: []const u8) bool {
    inline for (values) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
}

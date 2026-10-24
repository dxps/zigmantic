const std = @import("std");
const zigmantic = @import("zigmantic");

const rdf = zigmantic.rdf;
const rdf_io = zigmantic.rdf_io;
const entailment = zigmantic.entailment;

const Kind = enum { positive, negative };
const Regime = enum { simple, rdf, rdfs };

const Case = struct {
    id: []const u8,
    action: []const u8,
    result: ?[]const u8,
    kind: Kind,
    regime: Regime,
    datatypes: entailment.DatatypeProfile,
};

const Mapping = struct {
    expected: rdf.TermId,
    actual: rdf.TermId,
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
    const entries_close = std.mem.indexOfPos(u8, manifest, entries_open, "\n  )") orelse
        return error.InvalidManifest;

    var case_count: usize = 0;
    var expected_failure_count: usize = 0;
    var unexpected: usize = 0;
    var lines = std.mem.splitScalar(u8, manifest[entries_open + 1 .. entries_close], '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        const id_open = std.mem.indexOf(u8, trimmed, "<#") orelse continue;
        const id_close = std.mem.indexOfScalarPos(u8, trimmed, id_open, '>') orelse
            return error.InvalidManifest;
        const id = trimmed[id_open + 2 .. id_close];

        const case = try readCase(manifest, entries_close, id);
        const passed = try runCase(config.suite_dir, case);
        const expected_failure = contains(config.expected_failures, id);
        if (expected_failure) expected_failure_count += 1;
        if (passed == expected_failure) {
            unexpected += 1;
            if (passed) {
                std.log.err("W3C RDF entailment case {s} unexpectedly passed", .{id});
            } else {
                std.log.err("W3C RDF entailment case {s} failed", .{id});
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
    const block_end = std.mem.indexOfPos(u8, manifest, definition_at + marker.len, "\n<#") orelse
        manifest.len;
    const block = manifest[definition_at..block_end];

    const kind: Kind = if (std.mem.indexOf(u8, block, "mf:PositiveEntailmentTest") != null)
        .positive
    else if (std.mem.indexOf(u8, block, "mf:NegativeEntailmentTest") != null)
        .negative
    else
        return error.InvalidManifest;

    const regime_value = propertyString(block, "mf:entailmentRegime") orelse
        return error.InvalidManifest;
    const regime: Regime = if (std.mem.eql(u8, regime_value, "simple"))
        .simple
    else if (std.mem.eql(u8, regime_value, "RDF"))
        .rdf
    else if (std.mem.eql(u8, regime_value, "RDFS"))
        .rdfs
    else
        return error.InvalidManifest;

    return .{
        .id = id,
        .action = propertyReference(block, "mf:action") orelse return error.InvalidManifest,
        .result = propertyReference(block, "mf:result"),
        .kind = kind,
        .regime = regime,
        .datatypes = .{
            .rdf_xml_literal = propertyListContains(
                block,
                "mf:recognizedDatatypes",
                "rdf:XMLLiteral",
            ),
            .xsd_integer = propertyListContains(
                block,
                "mf:recognizedDatatypes",
                "xsd:integer",
            ),
            .xsd_int = propertyListContains(
                block,
                "mf:recognizedDatatypes",
                "xsd:int",
            ),
            .xsd_decimal = propertyListContains(
                block,
                "mf:recognizedDatatypes",
                "xsd:decimal",
            ),
            .xsd_float = propertyListContains(
                block,
                "mf:recognizedDatatypes",
                "xsd:float",
            ),
            .xsd_double = propertyListContains(
                block,
                "mf:recognizedDatatypes",
                "xsd:double",
            ),
        },
    };
}

fn propertyListContains(block: []const u8, property: []const u8, wanted: []const u8) bool {
    const property_at = std.mem.indexOf(u8, block, property) orelse return false;
    const open = std.mem.indexOfScalarPos(u8, block, property_at + property.len, '(') orelse
        return false;
    const close = std.mem.indexOfScalarPos(u8, block, open + 1, ')') orelse return false;
    var values = std.mem.tokenizeAny(u8, block[open + 1 .. close], " \t\r\n");
    while (values.next()) |value| {
        if (std.mem.eql(u8, value, wanted)) return true;
    }
    return false;
}

fn propertyReference(block: []const u8, property: []const u8) ?[]const u8 {
    const property_at = std.mem.indexOf(u8, block, property) orelse return null;
    var open = property_at + property.len;
    while (open < block.len and std.ascii.isWhitespace(block[open])) : (open += 1) {}
    if (open == block.len or block[open] != '<') return null;
    const close = std.mem.indexOfScalarPos(u8, block, open + 1, '>') orelse return null;
    return block[open + 1 .. close];
}

fn propertyString(block: []const u8, property: []const u8) ?[]const u8 {
    const property_at = std.mem.indexOf(u8, block, property) orelse return null;
    const open = std.mem.indexOfScalarPos(u8, block, property_at, '"') orelse return null;
    const close = std.mem.indexOfScalarPos(u8, block, open + 1, '"') orelse return null;
    return block[open + 1 .. close];
}

fn runCase(comptime suite_dir: []const u8, case: Case) !bool {
    const allocator = std.testing.allocator;
    var source = try parseSuiteGraph(allocator, suite_dir, case.action);
    defer source.deinit();
    var expected: ?rdf.Graph = if (case.result) |result_name|
        try parseSuiteGraph(allocator, suite_dir, result_name)
    else
        null;
    defer if (expected) |*graph| graph.deinit();

    var actual = try entailment.Materialization.fromGraph(allocator, &source);
    defer actual.deinit();

    if (case.regime != .simple) _ = try entailment.materializeRdfCore(&actual);
    if (case.regime == .rdfs) {
        if (expected) |*target| {
            _ = try entailment.materializeRdfsContainerMembership(&actual, target);
        }
        _ = try entailment.materializeRdfsCore(&actual);
    }

    const consistent = case.regime == .simple or
        entailment.isDatatypeConsistent(&actual, case.datatypes);
    const entailed = if (!consistent)
        true
    else if (expected) |*target|
        try simplyEntails(allocator, &actual, target, case.datatypes)
    else
        false;
    return entailed == (case.kind == .positive);
}

fn parseSuiteGraph(
    allocator: std.mem.Allocator,
    comptime suite_dir: []const u8,
    name: []const u8,
) !rdf.Graph {
    var path_buffer: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, suite_dir ++ "{s}", .{name});
    const input = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(2 * 1024 * 1024),
    );
    defer allocator.free(input);
    if (std.mem.endsWith(u8, name, ".nt")) return rdf_io.parseNTriples(allocator, input);
    if (std.mem.endsWith(u8, name, ".ttl")) {
        var base_buffer: [512]u8 = undefined;
        const base = try std.fmt.bufPrint(
            &base_buffer,
            "https://w3c.github.io/rdf-tests/rdf/rdf11/rdf-mt/{s}",
            .{name},
        );
        return rdf_io.parseTurtle(allocator, input, .{ .base_iri = base });
    }
    return error.InvalidManifest;
}

fn simplyEntails(
    allocator: std.mem.Allocator,
    actual: *const entailment.Materialization,
    expected: *const rdf.Graph,
    datatypes: entailment.DatatypeProfile,
) !bool {
    var mappings: std.ArrayList(Mapping) = .empty;
    defer mappings.deinit(allocator);
    return matchExpected(allocator, actual, expected, 0, &mappings, datatypes);
}

fn matchExpected(
    allocator: std.mem.Allocator,
    actual: *const entailment.Materialization,
    expected: *const rdf.Graph,
    expected_index: usize,
    mappings: *std.ArrayList(Mapping),
    datatypes: entailment.DatatypeProfile,
) !bool {
    if (expected_index == expected.len()) return true;
    const expected_triple = expected.items()[expected_index];
    var candidates = actual.iterator(.all);
    while (candidates.next()) |candidate| {
        const mapping_count = mappings.items.len;
        if (try triplesMatch(
            allocator,
            actual,
            candidate,
            expected,
            expected_triple,
            mappings,
            datatypes,
        ) and try matchExpected(
            allocator,
            actual,
            expected,
            expected_index + 1,
            mappings,
            datatypes,
        )) {
            return true;
        }
        mappings.items.len = mapping_count;
    }
    return false;
}

fn triplesMatch(
    allocator: std.mem.Allocator,
    actual: *const entailment.Materialization,
    left: rdf.Triple,
    expected: *const rdf.Graph,
    right: rdf.Triple,
    mappings: *std.ArrayList(Mapping),
    datatypes: entailment.DatatypeProfile,
) !bool {
    if (!try termsMatch(allocator, actual, left.predicate, expected, right.predicate, mappings, datatypes)) return false;
    if (!try termsMatch(allocator, actual, left.subject, expected, right.subject, mappings, datatypes)) return false;
    return termsMatch(allocator, actual, left.object, expected, right.object, mappings, datatypes);
}

fn termsMatch(
    allocator: std.mem.Allocator,
    actual: *const entailment.Materialization,
    actual_id: rdf.TermId,
    expected: *const rdf.Graph,
    expected_id: rdf.TermId,
    mappings: *std.ArrayList(Mapping),
    datatypes: entailment.DatatypeProfile,
) !bool {
    const expected_value = expected.terms.view(expected_id) orelse return false;
    if (expected_value != .blank_node) {
        if (try actual.termPoolConst().eqlTerm(actual_id, &expected.terms, expected_id)) return true;
        const actual_value = actual.termPoolConst().view(actual_id) orelse return false;
        if (actual_value != .literal or expected_value != .literal) return false;
        return entailment.recognizedLiteralValuesEqual(
            actual_value.literal,
            expected_value.literal,
            datatypes,
        ) orelse false;
    }
    for (mappings.items) |mapping| {
        if (mapping.expected == expected_id) return mapping.actual == actual_id;
    }
    try mappings.append(allocator, .{ .expected = expected_id, .actual = actual_id });
    return true;
}

fn contains(comptime values: []const []const u8, needle: []const u8) bool {
    inline for (values) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
}

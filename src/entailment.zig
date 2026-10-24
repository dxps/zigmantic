//! Explicit asserted and inferred RDF graph materialization.

const std = @import("std");
const rdf = @import("rdf.zig");
const store_mod = @import("store.zig");

const TripleKey = struct {
    subject: u32,
    predicate: u32,
    object: u32,
};

pub const Origin = enum {
    asserted,
    inferred,
    all,
};

pub const MaterializeResult = struct {
    inferred: usize,
};

/// Owns one RDF term scope and the union of asserted and inferred triples. Asserted
/// provenance is tracked separately and takes precedence when a triple has both origins.
pub const Materialization = struct {
    allocator: std.mem.Allocator,
    storage: store_mod.Store,
    asserted: std.AutoHashMapUnmanaged(TripleKey, void) = .empty,

    pub fn init(allocator: std.mem.Allocator) Materialization {
        return .{
            .allocator = allocator,
            .storage = .init(allocator),
        };
    }

    /// Copies an asserted graph into a new, independent term scope.
    pub fn fromGraph(
        allocator: std.mem.Allocator,
        graph: *const rdf.Graph,
    ) store_mod.Error!Materialization {
        var result = Materialization.init(allocator);
        errdefer result.deinit();

        for (graph.items()) |triple| {
            const copied = rdf.Triple{
                .subject = try result.storage.terms.internView(graph.terms.view(triple.subject) orelse
                    return error.UnknownTerm),
                .predicate = try result.storage.terms.internView(graph.terms.view(triple.predicate) orelse
                    return error.UnknownTerm),
                .object = try result.storage.terms.internView(graph.terms.view(triple.object) orelse
                    return error.UnknownTerm),
            };
            _ = try result.addAsserted(copied);
        }
        return result;
    }

    pub fn deinit(self: *Materialization) void {
        self.asserted.deinit(self.allocator);
        self.storage.deinit();
        self.* = undefined;
    }

    pub fn termPool(self: *Materialization) *rdf.TermPool {
        return &self.storage.terms;
    }

    pub fn termPoolConst(self: *const Materialization) *const rdf.TermPool {
        return &self.storage.terms;
    }

    /// Adds or promotes a triple to asserted provenance. Returns false only when it was
    /// already asserted. Promotion does not change union iteration order.
    pub fn addAsserted(self: *Materialization, triple: rdf.Triple) store_mod.Error!bool {
        try rdf.validateTriple(&self.storage.terms, triple);
        const key = tripleKey(triple);
        if (self.asserted.contains(key)) return false;

        try self.asserted.ensureUnusedCapacity(self.allocator, 1);
        _ = try self.storage.add(toQuad(triple));
        self.asserted.putAssumeCapacity(key, {});
        return true;
    }

    /// Adds a newly inferred triple. Returns false when the union already contains it.
    pub fn addInferred(self: *Materialization, triple: rdf.Triple) store_mod.Error!bool {
        return self.storage.add(toQuad(triple));
    }

    pub fn contains(self: *const Materialization, triple: rdf.Triple) bool {
        return self.storage.contains(toQuad(triple));
    }

    pub fn len(self: *const Materialization, origin: Origin) usize {
        return switch (origin) {
            .asserted => self.asserted.count(),
            .inferred => self.storage.len() - self.asserted.count(),
            .all => self.storage.len(),
        };
    }

    /// Iterates one provenance partition or their set union in first-insertion order.
    /// Mutation invalidates the iterator.
    pub fn iterator(self: *const Materialization, origin: Origin) Iterator {
        return .{
            .inner = self.storage.iterator(.{ .graph_name = .default }),
            .asserted = &self.asserted,
            .origin = origin,
        };
    }
};

/// Adds the eight fixed non-container RDF axiomatic triples and applies RDF 1.1
/// entailment pattern `rdfD2`, which types every predicate occurring in the union as
/// `rdf:Property`. The update is atomic and idempotent. Container-membership axioms and
/// datatype entailment pattern `rdfD1` are not part of this layer.
pub fn materializeRdfCore(materialization: *Materialization) store_mod.Error!MaterializeResult {
    const pool = materialization.termPool();
    const rdf_type = try pool.internNamedNode(rdf.rdf_namespace ++ "type");
    const rdf_property = try pool.internNamedNode(rdf.rdf_namespace ++ "Property");
    const rdf_list = try pool.internNamedNode(rdf.rdf_namespace ++ "List");

    const axiom_subjects = [_]rdf.TermId{
        rdf_type,
        try pool.internNamedNode(rdf.rdf_namespace ++ "subject"),
        try pool.internNamedNode(rdf.rdf_namespace ++ "predicate"),
        try pool.internNamedNode(rdf.rdf_namespace ++ "object"),
        try pool.internNamedNode(rdf.rdf_namespace ++ "first"),
        try pool.internNamedNode(rdf.rdf_namespace ++ "rest"),
        try pool.internNamedNode(rdf.rdf_namespace ++ "value"),
    };
    const rdf_nil = try pool.internNamedNode(rdf.rdf_namespace ++ "nil");

    var predicates: std.ArrayList(rdf.TermId) = .empty;
    defer predicates.deinit(materialization.allocator);
    var triples = materialization.iterator(.all);
    while (triples.next()) |triple| {
        var seen = false;
        for (predicates.items) |predicate| {
            if (predicate == triple.predicate) {
                seen = true;
                break;
            }
        }
        if (!seen) try predicates.append(materialization.allocator, triple.predicate);
    }

    var transaction = try materialization.storage.beginTransaction();
    defer transaction.deinit();
    var inferred: usize = 0;
    for (axiom_subjects) |subject| {
        if (try transaction.add(toQuad(.{
            .subject = subject,
            .predicate = rdf_type,
            .object = rdf_property,
        }))) inferred += 1;
    }
    if (try transaction.add(toQuad(.{
        .subject = rdf_nil,
        .predicate = rdf_type,
        .object = rdf_list,
    }))) inferred += 1;

    for (predicates.items) |predicate| {
        if (try transaction.add(toQuad(.{
            .subject = predicate,
            .predicate = rdf_type,
            .object = rdf_property,
        }))) inferred += 1;
    }
    try transaction.commit();
    return .{ .inferred = inferred };
}

pub const Iterator = struct {
    inner: store_mod.Iterator,
    asserted: *const std.AutoHashMapUnmanaged(TripleKey, void),
    origin: Origin,

    pub fn next(self: *Iterator) ?rdf.Triple {
        while (self.inner.next()) |quad| {
            const triple = rdf.Triple{
                .subject = quad.subject,
                .predicate = quad.predicate,
                .object = quad.object,
            };
            const is_asserted = self.asserted.contains(tripleKey(triple));
            if (self.origin == .all or
                (self.origin == .asserted and is_asserted) or
                (self.origin == .inferred and !is_asserted))
            {
                return triple;
            }
        }
        return null;
    }
};

fn toQuad(triple: rdf.Triple) rdf.Quad {
    return .{
        .subject = triple.subject,
        .predicate = triple.predicate,
        .object = triple.object,
    };
}

fn tripleKey(triple: rdf.Triple) TripleKey {
    return .{
        .subject = @backingInt(triple.subject),
        .predicate = @backingInt(triple.predicate),
        .object = @backingInt(triple.object),
    };
}

test "materialization separates asserted and inferred provenance" {
    var materialization = Materialization.init(std.testing.allocator);
    defer materialization.deinit();

    const terms = materialization.termPool();
    const subject = try terms.internNamedNode("https://example.com/subject");
    const predicate = try terms.internNamedNode("https://example.com/predicate");
    const asserted_object = try terms.internSimpleLiteral("asserted");
    const inferred_object = try terms.internSimpleLiteral("inferred");
    const asserted = rdf.Triple{ .subject = subject, .predicate = predicate, .object = asserted_object };
    const inferred = rdf.Triple{ .subject = subject, .predicate = predicate, .object = inferred_object };

    try std.testing.expect(try materialization.addAsserted(asserted));
    try std.testing.expect(try materialization.addInferred(inferred));
    try std.testing.expect(!(try materialization.addInferred(asserted)));
    try std.testing.expectEqual(@as(usize, 1), materialization.len(.asserted));
    try std.testing.expectEqual(@as(usize, 1), materialization.len(.inferred));
    try std.testing.expectEqual(@as(usize, 2), materialization.len(.all));

    var asserted_only = materialization.iterator(.asserted);
    try std.testing.expectEqual(asserted, asserted_only.next().?);
    try std.testing.expectEqual(@as(?rdf.Triple, null), asserted_only.next());

    var inferred_only = materialization.iterator(.inferred);
    try std.testing.expectEqual(inferred, inferred_only.next().?);
    try std.testing.expectEqual(@as(?rdf.Triple, null), inferred_only.next());
}

test "promoting an inference to asserted preserves union order" {
    var materialization = Materialization.init(std.testing.allocator);
    defer materialization.deinit();

    const terms = materialization.termPool();
    const subject = try terms.internNamedNode("https://example.com/subject");
    const predicate = try terms.internNamedNode("https://example.com/predicate");
    const first_object = try terms.internSimpleLiteral("first");
    const second_object = try terms.internSimpleLiteral("second");
    const first = rdf.Triple{ .subject = subject, .predicate = predicate, .object = first_object };
    const second = rdf.Triple{ .subject = subject, .predicate = predicate, .object = second_object };
    _ = try materialization.addInferred(first);
    _ = try materialization.addAsserted(second);
    try std.testing.expect(try materialization.addAsserted(first));

    try std.testing.expectEqual(@as(usize, 2), materialization.len(.asserted));
    try std.testing.expectEqual(@as(usize, 0), materialization.len(.inferred));
    var all = materialization.iterator(.all);
    try std.testing.expectEqual(first, all.next().?);
    try std.testing.expectEqual(second, all.next().?);
}

test "materialization owns terms copied from an asserted graph" {
    var graph = rdf.Graph.init(std.testing.allocator);
    const subject = try graph.terms.internNamedNode("https://example.com/subject");
    const predicate = try graph.terms.internNamedNode("https://example.com/predicate");
    const object = try graph.terms.internLanguageLiteral("salut", "RO");
    _ = try graph.add(.{ .subject = subject, .predicate = predicate, .object = object });

    var materialization = try Materialization.fromGraph(std.testing.allocator, &graph);
    graph.deinit();
    defer materialization.deinit();

    var asserted = materialization.iterator(.asserted);
    const copied = asserted.next().?;
    try std.testing.expectEqualStrings(
        "https://example.com/subject",
        materialization.termPoolConst().view(copied.subject).?.named_node,
    );
    try std.testing.expectEqualStrings(
        "ro",
        materialization.termPoolConst().view(copied.object).?.literal.language.?,
    );
}

test "RDF core materialization adds finite vocabulary axioms" {
    var materialization = Materialization.init(std.testing.allocator);
    defer materialization.deinit();

    const result = try materializeRdfCore(&materialization);
    try std.testing.expectEqual(@as(usize, 8), result.inferred);
    try std.testing.expectEqual(@as(usize, 0), materialization.len(.asserted));
    try std.testing.expectEqual(@as(usize, 8), materialization.len(.inferred));

    const pool = materialization.termPool();
    const rdf_nil = try pool.internNamedNode(rdf.rdf_namespace ++ "nil");
    const rdf_type = try pool.internNamedNode(rdf.rdf_namespace ++ "type");
    const rdf_list = try pool.internNamedNode(rdf.rdf_namespace ++ "List");
    try std.testing.expect(materialization.contains(.{
        .subject = rdf_nil,
        .predicate = rdf_type,
        .object = rdf_list,
    }));
}

test "RDF rdfD2 materialization types used predicates as properties" {
    var materialization = Materialization.init(std.testing.allocator);
    defer materialization.deinit();

    const pool = materialization.termPool();
    const subject = try pool.internNamedNode("https://example.com/subject");
    const predicate = try pool.internNamedNode("https://example.com/predicate");
    const object = try pool.internSimpleLiteral("object");
    const assertion = rdf.Triple{ .subject = subject, .predicate = predicate, .object = object };
    _ = try materialization.addAsserted(assertion);

    const result = try materializeRdfCore(&materialization);
    try std.testing.expectEqual(@as(usize, 9), result.inferred);
    const rdf_type = try pool.internNamedNode(rdf.rdf_namespace ++ "type");
    const rdf_property = try pool.internNamedNode(rdf.rdf_namespace ++ "Property");
    try std.testing.expect(materialization.contains(.{
        .subject = predicate,
        .predicate = rdf_type,
        .object = rdf_property,
    }));
    try std.testing.expectEqual(@as(usize, 1), materialization.len(.asserted));

    const repeated = try materializeRdfCore(&materialization);
    try std.testing.expectEqual(@as(usize, 0), repeated.inferred);
    try std.testing.expectEqual(@as(usize, 10), materialization.len(.all));
}

fn exerciseMaterializationAllocations(allocator: std.mem.Allocator) !void {
    var graph = rdf.Graph.init(allocator);
    defer graph.deinit();
    const subject = try graph.terms.internBlankNode("subject");
    const predicate = try graph.terms.internNamedNode("https://example.com/predicate");
    const object = try graph.terms.internLanguageLiteral("salut", "RO");
    _ = try graph.add(.{ .subject = subject, .predicate = predicate, .object = object });

    var materialization = try Materialization.fromGraph(allocator, &graph);
    defer materialization.deinit();
    _ = try materializeRdfCore(&materialization);
}

test "graph materialization handles every allocation failure without leaks" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseMaterializationAllocations,
        .{},
    );
}

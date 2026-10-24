//! Explicit asserted and inferred RDF graph materialization.

const std = @import("std");
const rdf = @import("rdf.zig");
const store_mod = @import("store.zig");

const TripleKey = struct {
    subject: u32,
    predicate: u32,
    object: u32,
};

const Mapping = struct {
    expected: rdf.TermId,
    actual: rdf.TermId,
};

pub const Regime = enum {
    simple,
    rdf,
    rdfs,
};

pub const EntailmentOptions = struct {
    regime: Regime = .simple,
    datatypes: DatatypeProfile = .{},
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

/// Determines whether `premise` entails `conclusion` under the selected regime.
/// The input graphs remain unchanged. Conclusion blank nodes are existential, and
/// recognized datatype values participate in equality and `rdfD1` matching.
pub fn entailsGraph(
    allocator: std.mem.Allocator,
    premise: *const rdf.Graph,
    conclusion: *const rdf.Graph,
    options: EntailmentOptions,
) store_mod.Error!bool {
    var materialization = try Materialization.fromGraph(allocator, premise);
    defer materialization.deinit();
    try materializeForRegime(&materialization, conclusion, options.regime);
    if (options.regime != .simple and
        !isDatatypeConsistent(&materialization, options.datatypes))
    {
        return true;
    }
    return materializationEntails(
        allocator,
        &materialization,
        conclusion,
        options.datatypes,
    );
}

/// Reports whether `premise` is satisfiable under the selected regime and
/// recognized datatype profile. Every graph is consistent under simple entailment.
pub fn isGraphConsistent(
    allocator: std.mem.Allocator,
    premise: *const rdf.Graph,
    options: EntailmentOptions,
) store_mod.Error!bool {
    if (options.regime == .simple) return true;
    var materialization = try Materialization.fromGraph(allocator, premise);
    defer materialization.deinit();
    var empty_target = rdf.Graph.init(allocator);
    defer empty_target.deinit();
    try materializeForRegime(&materialization, &empty_target, options.regime);
    return isDatatypeConsistent(&materialization, options.datatypes);
}

fn materializeForRegime(
    materialization: *Materialization,
    conclusion: *const rdf.Graph,
    regime: Regime,
) store_mod.Error!void {
    switch (regime) {
        .simple => {},
        .rdf => {
            _ = try materializeRdfCore(materialization);
            _ = try materializeRdfContainerMembership(materialization, conclusion);
        },
        .rdfs => {
            _ = try materializeRdfCore(materialization);
            _ = try materializeRdfsContainerMembership(materialization, conclusion);
            _ = try materializeRdfsCore(materialization);
        },
    }
}

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

/// Adds the RDF property axiom for every canonical `rdf:_n` IRI occurring in
/// the materialization or requested conclusion. If neither graph names one,
/// `rdf:_1` is used as the finite closure witness. The update is atomic and
/// idempotent.
pub fn materializeRdfContainerMembership(
    materialization: *Materialization,
    target: *const rdf.Graph,
) store_mod.Error!MaterializeResult {
    var membership_properties: std.ArrayList(rdf.TermId) = .empty;
    defer membership_properties.deinit(materialization.allocator);
    try collectMembershipVocabulary(materialization, target, &membership_properties);

    const pool = materialization.termPool();
    const rdf_type = try pool.internNamedNode(rdf.rdf_namespace ++ "type");
    const rdf_property = try pool.internNamedNode(rdf.rdf_namespace ++ "Property");
    var transaction = try materialization.storage.beginTransaction();
    defer transaction.deinit();
    var inferred: usize = 0;
    for (membership_properties.items) |property| {
        if (try transaction.add(toQuad(.{
            .subject = property,
            .predicate = rdf_type,
            .object = rdf_property,
        }))) inferred += 1;
    }
    try transaction.commit();
    return .{ .inferred = inferred };
}

/// Adds the RDF and RDFS axioms for every `rdf:_n` container-membership IRI
/// occurring in either the materialization or the requested conclusion graph.
/// It also applies the corresponding `rdfs12` and `rdfs7` consequences. When
/// neither graph names a membership property, `rdf:_1` is used as the finite
/// closure witness required by the RDF 1.1 Semantics closure construction.
/// The triple update is atomic and idempotent.
pub fn materializeRdfsContainerMembership(
    materialization: *Materialization,
    target: *const rdf.Graph,
) store_mod.Error!MaterializeResult {
    var membership_properties: std.ArrayList(rdf.TermId) = .empty;
    defer membership_properties.deinit(materialization.allocator);

    try collectMembershipVocabulary(materialization, target, &membership_properties);

    var membership_assertions: std.ArrayList(rdf.Triple) = .empty;
    defer membership_assertions.deinit(materialization.allocator);
    var triples = materialization.iterator(.all);
    while (triples.next()) |triple| {
        if (containsTerm(membership_properties.items, triple.predicate)) {
            try membership_assertions.append(materialization.allocator, triple);
        }
    }

    const pool = materialization.termPool();
    const rdf_type = try pool.internNamedNode(rdf.rdf_namespace ++ "type");
    const rdf_property = try pool.internNamedNode(rdf.rdf_namespace ++ "Property");
    const rdfs_container_membership_property = try pool.internNamedNode(
        rdf.rdfs_namespace ++ "ContainerMembershipProperty",
    );
    const rdfs_domain = try pool.internNamedNode(rdf.rdfs_namespace ++ "domain");
    const rdfs_range = try pool.internNamedNode(rdf.rdfs_namespace ++ "range");
    const rdfs_resource = try pool.internNamedNode(rdf.rdfs_namespace ++ "Resource");
    const rdfs_sub_property_of = try pool.internNamedNode(rdf.rdfs_namespace ++ "subPropertyOf");
    const rdfs_member = try pool.internNamedNode(rdf.rdfs_namespace ++ "member");

    var transaction = try materialization.storage.beginTransaction();
    defer transaction.deinit();
    var inferred: usize = 0;
    for (membership_properties.items) |property| {
        const axioms = [_]rdf.Triple{
            .{ .subject = property, .predicate = rdf_type, .object = rdf_property },
            .{ .subject = property, .predicate = rdf_type, .object = rdfs_container_membership_property },
            .{ .subject = property, .predicate = rdfs_domain, .object = rdfs_resource },
            .{ .subject = property, .predicate = rdfs_range, .object = rdfs_resource },
            .{ .subject = property, .predicate = rdfs_sub_property_of, .object = rdfs_member },
        };
        for (axioms) |axiom| {
            if (try transaction.add(toQuad(axiom))) inferred += 1;
        }
    }
    for (membership_assertions.items) |assertion| {
        if (try transaction.add(toQuad(.{
            .subject = assertion.subject,
            .predicate = rdfs_member,
            .object = assertion.object,
        }))) inferred += 1;
    }
    try transaction.commit();
    return .{ .inferred = inferred };
}

/// Adds the finite non-container RDFS axiomatic triples and applies the
/// `rdfs1` through `rdfs13` entailment patterns to a fixed point. Only
/// conclusions representable as ordinary RDF triples are materialized;
/// generalized intermediate triples remain outside the RDF graph model.
/// The triple update is atomic and idempotent.
pub fn materializeRdfsCore(materialization: *Materialization) store_mod.Error!MaterializeResult {
    const pool = materialization.termPool();
    const rdf_type = try pool.internNamedNode(rdf.rdf_namespace ++ "type");
    const rdf_property = try pool.internNamedNode(rdf.rdf_namespace ++ "Property");
    const rdf_statement = try pool.internNamedNode(rdf.rdf_namespace ++ "Statement");
    const rdf_list = try pool.internNamedNode(rdf.rdf_namespace ++ "List");
    const rdfs_domain = try pool.internNamedNode(rdf.rdfs_namespace ++ "domain");
    const rdfs_range = try pool.internNamedNode(rdf.rdfs_namespace ++ "range");
    const rdfs_resource = try pool.internNamedNode(rdf.rdfs_namespace ++ "Resource");
    const rdfs_literal = try pool.internNamedNode(rdf.rdfs_namespace ++ "Literal");
    const rdfs_datatype = try pool.internNamedNode(rdf.rdfs_namespace ++ "Datatype");
    const rdfs_class = try pool.internNamedNode(rdf.rdfs_namespace ++ "Class");
    const rdfs_sub_class_of = try pool.internNamedNode(rdf.rdfs_namespace ++ "subClassOf");
    const rdfs_sub_property_of = try pool.internNamedNode(rdf.rdfs_namespace ++ "subPropertyOf");
    const rdfs_member = try pool.internNamedNode(rdf.rdfs_namespace ++ "member");
    const rdfs_container = try pool.internNamedNode(rdf.rdfs_namespace ++ "Container");
    const rdfs_container_membership_property = try pool.internNamedNode(
        rdf.rdfs_namespace ++ "ContainerMembershipProperty",
    );
    const rdfs_see_also = try pool.internNamedNode(rdf.rdfs_namespace ++ "seeAlso");

    const domain_axioms = [_]struct { subject: rdf.TermId, object: rdf.TermId }{
        .{ .subject = rdf_type, .object = rdfs_resource },
        .{ .subject = rdfs_domain, .object = rdf_property },
        .{ .subject = rdfs_range, .object = rdf_property },
        .{ .subject = rdfs_sub_property_of, .object = rdf_property },
        .{ .subject = rdfs_sub_class_of, .object = rdfs_class },
        .{ .subject = try pool.internNamedNode(rdf.rdf_namespace ++ "subject"), .object = rdf_statement },
        .{ .subject = try pool.internNamedNode(rdf.rdf_namespace ++ "predicate"), .object = rdf_statement },
        .{ .subject = try pool.internNamedNode(rdf.rdf_namespace ++ "object"), .object = rdf_statement },
        .{ .subject = rdfs_member, .object = rdfs_resource },
        .{ .subject = try pool.internNamedNode(rdf.rdf_namespace ++ "first"), .object = rdf_list },
        .{ .subject = try pool.internNamedNode(rdf.rdf_namespace ++ "rest"), .object = rdf_list },
        .{ .subject = rdfs_see_also, .object = rdfs_resource },
        .{ .subject = try pool.internNamedNode(rdf.rdfs_namespace ++ "isDefinedBy"), .object = rdfs_resource },
        .{ .subject = try pool.internNamedNode(rdf.rdfs_namespace ++ "comment"), .object = rdfs_resource },
        .{ .subject = try pool.internNamedNode(rdf.rdfs_namespace ++ "label"), .object = rdfs_resource },
        .{ .subject = try pool.internNamedNode(rdf.rdf_namespace ++ "value"), .object = rdfs_resource },
    };
    const range_axioms = [_]struct { subject: rdf.TermId, object: rdf.TermId }{
        .{ .subject = rdf_type, .object = rdfs_class },
        .{ .subject = rdfs_domain, .object = rdfs_class },
        .{ .subject = rdfs_range, .object = rdfs_class },
        .{ .subject = rdfs_sub_property_of, .object = rdf_property },
        .{ .subject = rdfs_sub_class_of, .object = rdfs_class },
        .{ .subject = try pool.internNamedNode(rdf.rdf_namespace ++ "subject"), .object = rdfs_resource },
        .{ .subject = try pool.internNamedNode(rdf.rdf_namespace ++ "predicate"), .object = rdfs_resource },
        .{ .subject = try pool.internNamedNode(rdf.rdf_namespace ++ "object"), .object = rdfs_resource },
        .{ .subject = rdfs_member, .object = rdfs_resource },
        .{ .subject = try pool.internNamedNode(rdf.rdf_namespace ++ "first"), .object = rdfs_resource },
        .{ .subject = try pool.internNamedNode(rdf.rdf_namespace ++ "rest"), .object = rdf_list },
        .{ .subject = rdfs_see_also, .object = rdfs_resource },
        .{ .subject = try pool.internNamedNode(rdf.rdfs_namespace ++ "isDefinedBy"), .object = rdfs_resource },
        .{ .subject = try pool.internNamedNode(rdf.rdfs_namespace ++ "comment"), .object = rdfs_literal },
        .{ .subject = try pool.internNamedNode(rdf.rdfs_namespace ++ "label"), .object = rdfs_literal },
        .{ .subject = try pool.internNamedNode(rdf.rdf_namespace ++ "value"), .object = rdfs_resource },
    };
    const relation_axioms = [_]rdf.Triple{
        .{
            .subject = try pool.internNamedNode(rdf.rdf_namespace ++ "Alt"),
            .predicate = rdfs_sub_class_of,
            .object = rdfs_container,
        },
        .{
            .subject = try pool.internNamedNode(rdf.rdf_namespace ++ "Bag"),
            .predicate = rdfs_sub_class_of,
            .object = rdfs_container,
        },
        .{
            .subject = try pool.internNamedNode(rdf.rdf_namespace ++ "Seq"),
            .predicate = rdfs_sub_class_of,
            .object = rdfs_container,
        },
        .{
            .subject = rdfs_container_membership_property,
            .predicate = rdfs_sub_class_of,
            .object = rdf_property,
        },
        .{
            .subject = try pool.internNamedNode(rdf.rdfs_namespace ++ "isDefinedBy"),
            .predicate = rdfs_sub_property_of,
            .object = rdfs_see_also,
        },
        .{
            .subject = rdfs_datatype,
            .predicate = rdfs_sub_class_of,
            .object = rdfs_class,
        },
        .{
            .subject = try pool.internNamedNode(rdf.rdf_lang_string),
            .predicate = rdf_type,
            .object = rdfs_datatype,
        },
        .{
            .subject = try pool.internNamedNode(rdf.xsd_string),
            .predicate = rdf_type,
            .object = rdfs_datatype,
        },
    };

    var transaction = try materialization.storage.beginTransaction();
    defer transaction.deinit();
    var inferred: usize = 0;
    for (domain_axioms) |axiom| {
        if (try transaction.add(toQuad(.{
            .subject = axiom.subject,
            .predicate = rdfs_domain,
            .object = axiom.object,
        }))) inferred += 1;
    }
    for (range_axioms) |axiom| {
        if (try transaction.add(toQuad(.{
            .subject = axiom.subject,
            .predicate = rdfs_range,
            .object = axiom.object,
        }))) inferred += 1;
    }
    for (relation_axioms) |axiom| {
        if (try transaction.add(toQuad(axiom))) inferred += 1;
    }

    while (true) {
        const snapshot = try materialization.allocator.alloc(
            rdf.Triple,
            materialization.len(.all),
        );
        defer materialization.allocator.free(snapshot);
        var triples = materialization.iterator(.all);
        var snapshot_index: usize = 0;
        while (triples.next()) |triple| : (snapshot_index += 1) {
            snapshot[snapshot_index] = triple;
        }
        std.debug.assert(snapshot_index == snapshot.len);

        var added_this_round: usize = 0;
        for (snapshot) |triple| {
            added_this_round += @intFromBool(try addRuleTriple(
                &transaction,
                triple.subject,
                rdf_type,
                rdfs_resource,
            )); // rdfs4a
            if (isRdfSubject(pool, triple.object)) {
                added_this_round += @intFromBool(try addRuleTriple(
                    &transaction,
                    triple.object,
                    rdf_type,
                    rdfs_resource,
                )); // rdfs4b
            }
            if (triple.predicate == rdf_type and triple.object == rdf_property) {
                added_this_round += @intFromBool(try addRuleTriple(
                    &transaction,
                    triple.subject,
                    rdfs_sub_property_of,
                    triple.subject,
                )); // rdfs6
            }
            if (triple.predicate == rdf_type and triple.object == rdfs_class) {
                added_this_round += @intFromBool(try addRuleTriple(
                    &transaction,
                    triple.subject,
                    rdfs_sub_class_of,
                    rdfs_resource,
                )); // rdfs8
                added_this_round += @intFromBool(try addRuleTriple(
                    &transaction,
                    triple.subject,
                    rdfs_sub_class_of,
                    triple.subject,
                )); // rdfs10
            }
            if (triple.predicate == rdf_type and triple.object == rdfs_container_membership_property) {
                added_this_round += @intFromBool(try addRuleTriple(
                    &transaction,
                    triple.subject,
                    rdfs_sub_property_of,
                    rdfs_member,
                )); // rdfs12
            }
            if (triple.predicate == rdf_type and triple.object == rdfs_datatype) {
                added_this_round += @intFromBool(try addRuleTriple(
                    &transaction,
                    triple.subject,
                    rdfs_sub_class_of,
                    rdfs_literal,
                )); // rdfs13
            }
        }

        for (snapshot) |relation| {
            for (snapshot) |fact| {
                if (relation.predicate == rdfs_domain and fact.predicate == relation.subject) {
                    added_this_round += @intFromBool(try addRuleTriple(
                        &transaction,
                        fact.subject,
                        rdf_type,
                        relation.object,
                    )); // rdfs2
                }
                if (relation.predicate == rdfs_range and
                    fact.predicate == relation.subject and
                    isRdfSubject(pool, fact.object))
                {
                    added_this_round += @intFromBool(try addRuleTriple(
                        &transaction,
                        fact.object,
                        rdf_type,
                        relation.object,
                    )); // rdfs3
                }
                if (relation.predicate == rdfs_sub_property_of and
                    fact.predicate == rdfs_sub_property_of and
                    relation.object == fact.subject)
                {
                    added_this_round += @intFromBool(try addRuleTriple(
                        &transaction,
                        relation.subject,
                        rdfs_sub_property_of,
                        fact.object,
                    )); // rdfs5
                }
                if (relation.predicate == rdfs_sub_property_of and
                    fact.predicate == relation.subject and
                    isRdfPredicate(pool, relation.object))
                {
                    added_this_round += @intFromBool(try addRuleTriple(
                        &transaction,
                        fact.subject,
                        relation.object,
                        fact.object,
                    )); // rdfs7
                }
                if (relation.predicate == rdfs_sub_class_of and
                    fact.predicate == rdf_type and
                    fact.object == relation.subject)
                {
                    added_this_round += @intFromBool(try addRuleTriple(
                        &transaction,
                        fact.subject,
                        rdf_type,
                        relation.object,
                    )); // rdfs9
                }
                if (relation.predicate == rdfs_sub_class_of and
                    fact.predicate == rdfs_sub_class_of and
                    relation.object == fact.subject)
                {
                    added_this_round += @intFromBool(try addRuleTriple(
                        &transaction,
                        relation.subject,
                        rdfs_sub_class_of,
                        fact.object,
                    )); // rdfs11
                }
            }
        }
        inferred += added_this_round;
        if (added_this_round == 0) break;
    }

    try transaction.commit();
    return .{ .inferred = inferred };
}

fn addRuleTriple(
    transaction: *store_mod.Transaction,
    subject: rdf.TermId,
    predicate: rdf.TermId,
    object: rdf.TermId,
) store_mod.Error!bool {
    return transaction.add(toQuad(.{
        .subject = subject,
        .predicate = predicate,
        .object = object,
    }));
}

fn isRdfSubject(pool: *const rdf.TermPool, term: rdf.TermId) bool {
    return switch (pool.view(term) orelse return false) {
        .named_node, .blank_node => true,
        .literal => false,
    };
}

fn isRdfPredicate(pool: *const rdf.TermPool, term: rdf.TermId) bool {
    return switch (pool.view(term) orelse return false) {
        .named_node => true,
        .blank_node, .literal => false,
    };
}

pub const DatatypeProfile = struct {
    rdf_xml_literal: bool = false,
    xsd_integer: bool = false,
    xsd_int: bool = false,
    xsd_decimal: bool = false,
    xsd_float: bool = false,
    xsd_double: bool = false,
};

const DatatypeKind = enum {
    rdf_lang_string,
    rdf_xml_literal,
    xsd_string,
    xsd_integer,
    xsd_int,
    xsd_decimal,
    xsd_float,
    xsd_double,
};

/// Reports consistency for the mandatory RDF datatypes and the optional datatype
/// IRIs enabled by `profile`. It validates supported lexical forms and detects
/// incompatible RDFS range constraints over known datatype value spaces.
pub fn isDatatypeConsistent(
    materialization: *const Materialization,
    profile: DatatypeProfile,
) bool {
    const pool = materialization.termPoolConst();
    var facts = materialization.iterator(.all);
    while (facts.next()) |fact| {
        const object = pool.view(fact.object) orelse return false;
        const literal = switch (object) {
            .literal => |value| value,
            else => continue,
        };
        if (!isLiteralWellTyped(literal, profile)) return false;

        var constraints = materialization.iterator(.all);
        while (constraints.next()) |constraint| {
            const predicate = pool.view(constraint.predicate) orelse return false;
            const predicate_iri = switch (predicate) {
                .named_node => |iri| iri,
                else => return false,
            };
            if (!std.mem.eql(u8, predicate_iri, rdf.rdfs_namespace ++ "range") or
                constraint.subject != fact.predicate)
            {
                continue;
            }
            const range = pool.view(constraint.object) orelse return false;
            const range_iri = switch (range) {
                .named_node => |iri| iri,
                else => continue,
            };
            if (datatypeMembership(literal, range_iri, profile)) |belongs| {
                if (!belongs) return false;
            }
        }
    }
    return true;
}

pub fn isMandatoryDatatypeConsistent(materialization: *const Materialization) bool {
    return isDatatypeConsistent(materialization, .{});
}

fn isLiteralWellTyped(literal: rdf.LiteralView, profile: DatatypeProfile) bool {
    const kind = datatypeKind(literal.datatype, profile) orelse return true;
    return switch (kind) {
        .xsd_string => literal.language == null,
        .rdf_lang_string => literal.language != null,
        .xsd_integer => isIntegerLexical(literal.lexical_form),
        .xsd_int => isIntLexical(literal.lexical_form),
        .xsd_decimal => parseDecimal(literal.lexical_form) != null,
        .xsd_float => parseXsdFloat(f32, literal.lexical_form) != null,
        .xsd_double => parseXsdFloat(f64, literal.lexical_form) != null,
        .rdf_xml_literal => isSupportedXmlLiteralLexical(literal.lexical_form),
    };
}

fn datatypeMembership(
    literal: rdf.LiteralView,
    datatype: []const u8,
    profile: DatatypeProfile,
) ?bool {
    const target = datatypeKind(datatype, profile) orelse return null;
    const source = datatypeKind(literal.datatype, profile) orelse return null;
    if (!isLiteralWellTyped(literal, profile)) return false;
    return switch (source) {
        .xsd_string => target == .xsd_string and literal.language == null,
        .rdf_lang_string => target == .rdf_lang_string and literal.language != null,
        .rdf_xml_literal => target == .rdf_xml_literal,
        .xsd_integer => switch (target) {
            .xsd_integer => true,
            .xsd_int => integerFitsInt(literal.lexical_form),
            .xsd_decimal => true,
            else => false,
        },
        .xsd_int => target == .xsd_int or target == .xsd_integer or target == .xsd_decimal,
        .xsd_decimal => switch (target) {
            .xsd_decimal => true,
            .xsd_integer => decimalIsInteger(literal.lexical_form),
            .xsd_int => decimalFitsInt(literal.lexical_form),
            else => false,
        },
        .xsd_float => target == .xsd_float or target == .xsd_double,
        .xsd_double => target == .xsd_double,
    };
}

fn datatypeKind(iri: []const u8, profile: DatatypeProfile) ?DatatypeKind {
    if (std.mem.eql(u8, iri, rdf.xsd_string)) return .xsd_string;
    if (std.mem.eql(u8, iri, rdf.rdf_lang_string)) return .rdf_lang_string;
    if (profile.rdf_xml_literal and std.mem.eql(u8, iri, rdf.rdf_xml_literal)) {
        return .rdf_xml_literal;
    }
    if (profile.xsd_integer and std.mem.eql(u8, iri, rdf.xsd_integer)) return .xsd_integer;
    if (profile.xsd_int and std.mem.eql(u8, iri, rdf.xsd_int)) return .xsd_int;
    if (profile.xsd_decimal and std.mem.eql(u8, iri, rdf.xsd_decimal)) return .xsd_decimal;
    if (profile.xsd_float and std.mem.eql(u8, iri, rdf.xsd_float)) return .xsd_float;
    if (profile.xsd_double and std.mem.eql(u8, iri, rdf.xsd_double)) return .xsd_double;
    return null;
}

/// Returns semantic equality for two well-typed literals when both datatype
/// values are understood by `profile`, or `null` when either datatype is unknown.
pub fn recognizedLiteralValuesEqual(
    left: rdf.LiteralView,
    right: rdf.LiteralView,
    profile: DatatypeProfile,
) ?bool {
    const left_kind = datatypeKind(left.datatype, profile) orelse return null;
    const right_kind = datatypeKind(right.datatype, profile) orelse return null;
    if (!isLiteralWellTyped(left, profile) or !isLiteralWellTyped(right, profile)) return false;

    if (isDecimalKind(left_kind) and isDecimalKind(right_kind)) {
        return decimalValuesEqual(left.lexical_form, right.lexical_form);
    }
    if (isFloatKind(left_kind) and isFloatKind(right_kind)) {
        return floatValuesEqual(left_kind, left.lexical_form, right_kind, right.lexical_form);
    }
    return switch (left_kind) {
        .xsd_string => right_kind == .xsd_string and
            std.mem.eql(u8, left.lexical_form, right.lexical_form),
        .rdf_lang_string => right_kind == .rdf_lang_string and
            std.mem.eql(u8, left.lexical_form, right.lexical_form) and
            optionalStringsEqual(left.language, right.language),
        .rdf_xml_literal => right_kind == .rdf_xml_literal and
            std.mem.eql(u8, left.lexical_form, right.lexical_form),
        else => false,
    };
}

/// Returns whether a supported, well-typed literal value belongs to the named
/// recognized datatype, or `null` when either datatype is unknown.
pub fn recognizedLiteralBelongsTo(
    literal: rdf.LiteralView,
    datatype_iri: []const u8,
    profile: DatatypeProfile,
) ?bool {
    return datatypeMembership(literal, datatype_iri, profile);
}

fn isDecimalKind(kind: DatatypeKind) bool {
    return kind == .xsd_integer or kind == .xsd_int or kind == .xsd_decimal;
}

fn isFloatKind(kind: DatatypeKind) bool {
    return kind == .xsd_float or kind == .xsd_double;
}

fn optionalStringsEqual(left: ?[]const u8, right: ?[]const u8) bool {
    if (left) |left_value| {
        const right_value = right orelse return false;
        return std.mem.eql(u8, left_value, right_value);
    }
    return right == null;
}

const DecimalParts = struct {
    negative: bool,
    integer: []const u8,
    fraction: []const u8,
};

fn parseDecimal(lexical: []const u8) ?DecimalParts {
    if (lexical.len == 0) return null;
    var index: usize = 0;
    var negative = false;
    if (lexical[0] == '+' or lexical[0] == '-') {
        negative = lexical[0] == '-';
        index = 1;
    }
    if (index == lexical.len) return null;

    const digits_start = index;
    while (index < lexical.len and std.ascii.isDigit(lexical[index])) : (index += 1) {}
    const integer_end = index;
    var fraction: []const u8 = "";
    if (index < lexical.len and lexical[index] == '.') {
        index += 1;
        const fraction_start = index;
        while (index < lexical.len and std.ascii.isDigit(lexical[index])) : (index += 1) {}
        fraction = lexical[fraction_start..index];
    }
    if (index != lexical.len or (integer_end == digits_start and fraction.len == 0)) return null;

    var integer = lexical[digits_start..integer_end];
    while (integer.len > 0 and integer[0] == '0') integer = integer[1..];
    while (fraction.len > 0 and fraction[fraction.len - 1] == '0') {
        fraction = fraction[0 .. fraction.len - 1];
    }
    if (integer.len == 0 and fraction.len == 0) negative = false;
    return .{ .negative = negative, .integer = integer, .fraction = fraction };
}

fn decimalValuesEqual(left: []const u8, right: []const u8) bool {
    const left_parts = parseDecimal(left) orelse return false;
    const right_parts = parseDecimal(right) orelse return false;
    return left_parts.negative == right_parts.negative and
        std.mem.eql(u8, left_parts.integer, right_parts.integer) and
        std.mem.eql(u8, left_parts.fraction, right_parts.fraction);
}

fn decimalIsInteger(lexical: []const u8) bool {
    const parts = parseDecimal(lexical) orelse return false;
    return parts.fraction.len == 0;
}

fn decimalFitsInt(lexical: []const u8) bool {
    const parts = parseDecimal(lexical) orelse return false;
    if (parts.fraction.len != 0) return false;
    var buffer: [32]u8 = undefined;
    var length: usize = 0;
    if (parts.negative) {
        buffer[0] = '-';
        length = 1;
    }
    const digits = if (parts.integer.len == 0) "0" else parts.integer;
    if (length + digits.len > buffer.len) return false;
    @memcpy(buffer[length .. length + digits.len], digits);
    length += digits.len;
    return isIntLexical(buffer[0..length]);
}

fn parseXsdFloat(comptime T: type, lexical: []const u8) ?T {
    if (std.mem.eql(u8, lexical, "INF")) return std.math.inf(T);
    if (std.mem.eql(u8, lexical, "-INF")) return -std.math.inf(T);
    if (std.mem.eql(u8, lexical, "NaN")) return std.math.nan(T);
    if (lexical.len == 0) return null;
    for (lexical) |byte| if (std.ascii.isWhitespace(byte)) return null;
    return std.fmt.parseFloat(T, lexical) catch null;
}

fn floatValuesEqual(
    left_kind: DatatypeKind,
    left_lexical: []const u8,
    right_kind: DatatypeKind,
    right_lexical: []const u8,
) bool {
    const left: f64 = if (left_kind == .xsd_float)
        @floatCast(parseXsdFloat(f32, left_lexical) orelse return false)
    else
        parseXsdFloat(f64, left_lexical) orelse return false;
    const right: f64 = if (right_kind == .xsd_float)
        @floatCast(parseXsdFloat(f32, right_lexical) orelse return false)
    else
        parseXsdFloat(f64, right_lexical) orelse return false;
    if (std.math.isNan(left) or std.math.isNan(right)) {
        return std.math.isNan(left) and std.math.isNan(right);
    }
    if (left == 0 and right == 0) return std.math.signbit(left) == std.math.signbit(right);
    return left == right;
}

fn isIntegerLexical(lexical: []const u8) bool {
    if (lexical.len == 0) return false;
    var index: usize = 0;
    if (lexical[0] == '+' or lexical[0] == '-') index = 1;
    if (index == lexical.len) return false;
    for (lexical[index..]) |byte| {
        if (!std.ascii.isDigit(byte)) return false;
    }
    return true;
}

fn isIntLexical(lexical: []const u8) bool {
    if (!isIntegerLexical(lexical)) return false;
    _ = std.fmt.parseInt(i32, lexical, 10) catch return false;
    return true;
}

fn integerFitsInt(lexical: []const u8) bool {
    return isIntLexical(lexical);
}

fn isSupportedXmlLiteralLexical(lexical: []const u8) bool {
    var index: usize = 0;
    while (index < lexical.len) {
        if (lexical[index] == '<') {
            if (index + 1 == lexical.len) return false;
            const next = lexical[index + 1];
            if (!(next == '/' or next == '?' or next == '!' or next == '_' or
                std.ascii.isAlphabetic(next) or next >= 0x80)) return false;
            const close = std.mem.indexOfScalarPos(u8, lexical, index + 2, '>') orelse
                return false;
            index = close + 1;
            continue;
        }
        if (lexical[index] == '&') {
            const close = std.mem.indexOfScalarPos(u8, lexical, index + 1, ';') orelse
                return false;
            if (close == index + 1) return false;
            index = close + 1;
            continue;
        }
        index += 1;
    }
    return true;
}

fn materializationEntails(
    allocator: std.mem.Allocator,
    actual: *const Materialization,
    expected: *const rdf.Graph,
    datatypes: DatatypeProfile,
) store_mod.Error!bool {
    var mappings: std.ArrayList(Mapping) = .empty;
    defer mappings.deinit(allocator);
    return matchExpected(allocator, actual, expected, 0, &mappings, datatypes);
}

fn matchExpected(
    allocator: std.mem.Allocator,
    actual: *const Materialization,
    expected: *const rdf.Graph,
    expected_index: usize,
    mappings: *std.ArrayList(Mapping),
    datatypes: DatatypeProfile,
) store_mod.Error!bool {
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
        )) return true;
        mappings.items.len = mapping_count;
    }

    var literal_sources = actual.iterator(.all);
    while (literal_sources.next()) |source| {
        const value = actual.termPoolConst().view(source.object) orelse return error.UnknownTerm;
        if (value != .literal) continue;
        const mapping_count = mappings.items.len;
        if (try generalizedDatatypeTypeMatches(
            allocator,
            actual,
            source.object,
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
        )) return true;
        mappings.items.len = mapping_count;
    }
    return false;
}

fn generalizedDatatypeTypeMatches(
    allocator: std.mem.Allocator,
    actual: *const Materialization,
    literal_id: rdf.TermId,
    expected: *const rdf.Graph,
    triple: rdf.Triple,
    mappings: *std.ArrayList(Mapping),
    datatypes: DatatypeProfile,
) store_mod.Error!bool {
    const subject = expected.terms.view(triple.subject) orelse return error.UnknownTerm;
    if (subject != .blank_node) return false;
    const predicate = expected.terms.view(triple.predicate) orelse return error.UnknownTerm;
    const predicate_iri = switch (predicate) {
        .named_node => |iri| iri,
        else => return false,
    };
    if (!std.mem.eql(u8, predicate_iri, rdf.rdf_namespace ++ "type")) return false;
    const object = expected.terms.view(triple.object) orelse return error.UnknownTerm;
    const datatype_iri = switch (object) {
        .named_node => |iri| iri,
        else => return false,
    };
    const literal = actual.termPoolConst().view(literal_id) orelse return error.UnknownTerm;
    if (literal != .literal) return false;
    if (!(recognizedLiteralBelongsTo(literal.literal, datatype_iri, datatypes) orelse false)) {
        return false;
    }
    return termsMatch(
        allocator,
        actual,
        literal_id,
        expected,
        triple.subject,
        mappings,
        datatypes,
    );
}

fn triplesMatch(
    allocator: std.mem.Allocator,
    actual: *const Materialization,
    left: rdf.Triple,
    expected: *const rdf.Graph,
    right: rdf.Triple,
    mappings: *std.ArrayList(Mapping),
    datatypes: DatatypeProfile,
) store_mod.Error!bool {
    if (!try termsMatch(allocator, actual, left.predicate, expected, right.predicate, mappings, datatypes)) return false;
    if (!try termsMatch(allocator, actual, left.subject, expected, right.subject, mappings, datatypes)) return false;
    return termsMatch(allocator, actual, left.object, expected, right.object, mappings, datatypes);
}

fn termsMatch(
    allocator: std.mem.Allocator,
    actual: *const Materialization,
    actual_id: rdf.TermId,
    expected: *const rdf.Graph,
    expected_id: rdf.TermId,
    mappings: *std.ArrayList(Mapping),
    datatypes: DatatypeProfile,
) store_mod.Error!bool {
    const expected_value = expected.terms.view(expected_id) orelse return error.UnknownTerm;
    if (expected_value != .blank_node) {
        if (try actual.termPoolConst().eqlTerm(actual_id, &expected.terms, expected_id)) return true;
        const actual_value = actual.termPoolConst().view(actual_id) orelse return error.UnknownTerm;
        if (actual_value != .literal or expected_value != .literal) return false;
        return recognizedLiteralValuesEqual(
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

fn collectMembershipVocabulary(
    materialization: *Materialization,
    target: *const rdf.Graph,
    properties: *std.ArrayList(rdf.TermId),
) store_mod.Error!void {
    var triples = materialization.iterator(.all);
    while (triples.next()) |triple| {
        try collectMembershipTerm(
            materialization.termPool(),
            materialization.termPoolConst(),
            triple.subject,
            properties,
            materialization.allocator,
        );
        try collectMembershipTerm(
            materialization.termPool(),
            materialization.termPoolConst(),
            triple.predicate,
            properties,
            materialization.allocator,
        );
        try collectMembershipTerm(
            materialization.termPool(),
            materialization.termPoolConst(),
            triple.object,
            properties,
            materialization.allocator,
        );
    }
    for (target.items()) |triple| {
        try collectMembershipTerm(
            materialization.termPool(),
            &target.terms,
            triple.subject,
            properties,
            materialization.allocator,
        );
        try collectMembershipTerm(
            materialization.termPool(),
            &target.terms,
            triple.predicate,
            properties,
            materialization.allocator,
        );
        try collectMembershipTerm(
            materialization.termPool(),
            &target.terms,
            triple.object,
            properties,
            materialization.allocator,
        );
    }
    if (properties.items.len == 0) {
        try properties.append(
            materialization.allocator,
            try materialization.termPool().internNamedNode(rdf.rdf_namespace ++ "_1"),
        );
    }
}

fn collectMembershipTerm(
    destination: *rdf.TermPool,
    source: *const rdf.TermPool,
    term: rdf.TermId,
    properties: *std.ArrayList(rdf.TermId),
    allocator: std.mem.Allocator,
) store_mod.Error!void {
    const view = source.view(term) orelse return error.UnknownTerm;
    const iri = switch (view) {
        .named_node => |named_node| named_node,
        .literal => |literal| literal.datatype,
        .blank_node => return,
    };
    if (!isContainerMembershipIri(iri)) return;
    const local = try destination.internNamedNode(iri);
    if (!containsTerm(properties.items, local)) try properties.append(allocator, local);
}

fn containsTerm(terms: []const rdf.TermId, wanted: rdf.TermId) bool {
    for (terms) |term| {
        if (term == wanted) return true;
    }
    return false;
}

fn isContainerMembershipIri(iri: []const u8) bool {
    const prefix = rdf.rdf_namespace ++ "_";
    if (!std.mem.startsWith(u8, iri, prefix)) return false;
    const index = iri[prefix.len..];
    if (index.len == 0 or index[0] < '1' or index[0] > '9') return false;
    for (index[1..]) |byte| {
        if (!std.ascii.isDigit(byte)) return false;
    }
    return true;
}

test "container membership IRIs use canonical positive decimal indices" {
    try std.testing.expect(isContainerMembershipIri(rdf.rdf_namespace ++ "_1"));
    try std.testing.expect(isContainerMembershipIri(rdf.rdf_namespace ++ "_42"));
    try std.testing.expect(!isContainerMembershipIri(rdf.rdf_namespace ++ "_"));
    try std.testing.expect(!isContainerMembershipIri(rdf.rdf_namespace ++ "_0"));
    try std.testing.expect(!isContainerMembershipIri(rdf.rdf_namespace ++ "_01"));
    try std.testing.expect(!isContainerMembershipIri(rdf.rdf_namespace ++ "_x"));
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

test "RDFS container materialization adds target-aware axioms and membership" {
    var materialization = Materialization.init(std.testing.allocator);
    defer materialization.deinit();

    const pool = materialization.termPool();
    const subject = try pool.internNamedNode("https://example.com/container");
    const membership = try pool.internNamedNode(rdf.rdf_namespace ++ "_42");
    const object = try pool.internNamedNode("https://example.com/member");
    _ = try materialization.addAsserted(.{
        .subject = subject,
        .predicate = membership,
        .object = object,
    });

    var target = rdf.Graph.init(std.testing.allocator);
    defer target.deinit();
    const target_subject = try target.terms.internNamedNode("https://example.com/container");
    const target_member = try target.terms.internNamedNode(rdf.rdfs_namespace ++ "member");
    const target_object = try target.terms.internNamedNode("https://example.com/member");
    _ = try target.add(.{
        .subject = target_subject,
        .predicate = target_member,
        .object = target_object,
    });

    const result = try materializeRdfsContainerMembership(&materialization, &target);
    try std.testing.expectEqual(@as(usize, 6), result.inferred);
    const rdf_type = try pool.internNamedNode(rdf.rdf_namespace ++ "type");
    const membership_class = try pool.internNamedNode(rdf.rdfs_namespace ++ "ContainerMembershipProperty");
    const member = try pool.internNamedNode(rdf.rdfs_namespace ++ "member");
    try std.testing.expect(materialization.contains(.{
        .subject = membership,
        .predicate = rdf_type,
        .object = membership_class,
    }));
    try std.testing.expect(materialization.contains(.{
        .subject = subject,
        .predicate = member,
        .object = object,
    }));

    const repeated = try materializeRdfsContainerMembership(&materialization, &target);
    try std.testing.expectEqual(@as(usize, 0), repeated.inferred);
}

test "RDFS container materialization includes membership IRIs named only by target" {
    var materialization = Materialization.init(std.testing.allocator);
    defer materialization.deinit();
    var target = rdf.Graph.init(std.testing.allocator);
    defer target.deinit();

    const membership = try target.terms.internNamedNode(rdf.rdf_namespace ++ "_7");
    const rdf_type = try target.terms.internNamedNode(rdf.rdf_namespace ++ "type");
    const membership_class = try target.terms.internNamedNode(rdf.rdfs_namespace ++ "ContainerMembershipProperty");
    _ = try target.add(.{
        .subject = membership,
        .predicate = rdf_type,
        .object = membership_class,
    });

    const result = try materializeRdfsContainerMembership(&materialization, &target);
    try std.testing.expectEqual(@as(usize, 5), result.inferred);
    const local_membership = try materialization.termPool().internNamedNode(rdf.rdf_namespace ++ "_7");
    const local_type = try materialization.termPool().internNamedNode(rdf.rdf_namespace ++ "type");
    const local_class = try materialization.termPool().internNamedNode(
        rdf.rdfs_namespace ++ "ContainerMembershipProperty",
    );
    try std.testing.expect(materialization.contains(.{
        .subject = local_membership,
        .predicate = local_type,
        .object = local_class,
    }));
}

test "RDFS core materialization reaches a rule fixed point" {
    var materialization = Materialization.init(std.testing.allocator);
    defer materialization.deinit();
    const pool = materialization.termPool();

    const rdf_type = try pool.internNamedNode(rdf.rdf_namespace ++ "type");
    const rdfs_domain = try pool.internNamedNode(rdf.rdfs_namespace ++ "domain");
    const rdfs_range = try pool.internNamedNode(rdf.rdfs_namespace ++ "range");
    const rdfs_sub_class_of = try pool.internNamedNode(rdf.rdfs_namespace ++ "subClassOf");
    const rdfs_sub_property_of = try pool.internNamedNode(rdf.rdfs_namespace ++ "subPropertyOf");
    const rdfs_resource = try pool.internNamedNode(rdf.rdfs_namespace ++ "Resource");
    const rdfs_literal = try pool.internNamedNode(rdf.rdfs_namespace ++ "Literal");
    const rdfs_datatype = try pool.internNamedNode(rdf.rdfs_namespace ++ "Datatype");
    const rdfs_container_membership_property = try pool.internNamedNode(
        rdf.rdfs_namespace ++ "ContainerMembershipProperty",
    );
    const rdfs_member = try pool.internNamedNode(rdf.rdfs_namespace ++ "member");
    const subject = try pool.internNamedNode("https://example.com/subject");
    const object = try pool.internNamedNode("https://example.com/object");
    const child_property = try pool.internNamedNode("https://example.com/child-property");
    const parent_property = try pool.internNamedNode("https://example.com/parent-property");
    const child_class = try pool.internNamedNode("https://example.com/Child");
    const parent_class = try pool.internNamedNode("https://example.com/Parent");
    const membership_property = try pool.internNamedNode("https://example.com/membership");
    const datatype = try pool.internNamedNode("https://example.com/datatype");

    const assertions = [_]rdf.Triple{
        .{ .subject = child_property, .predicate = rdfs_sub_property_of, .object = parent_property },
        .{ .subject = parent_property, .predicate = rdfs_domain, .object = child_class },
        .{ .subject = parent_property, .predicate = rdfs_range, .object = parent_class },
        .{ .subject = child_class, .predicate = rdfs_sub_class_of, .object = parent_class },
        .{ .subject = subject, .predicate = child_property, .object = object },
        .{ .subject = membership_property, .predicate = rdf_type, .object = rdfs_container_membership_property },
        .{ .subject = datatype, .predicate = rdf_type, .object = rdfs_datatype },
    };
    for (assertions) |assertion| _ = try materialization.addAsserted(assertion);

    _ = try materializeRdfCore(&materialization);
    const result = try materializeRdfsCore(&materialization);
    try std.testing.expect(result.inferred > 0);
    const consequences = [_]rdf.Triple{
        .{ .subject = subject, .predicate = parent_property, .object = object }, // rdfs7
        .{ .subject = subject, .predicate = rdf_type, .object = child_class }, // rdfs2
        .{ .subject = subject, .predicate = rdf_type, .object = parent_class }, // rdfs9
        .{ .subject = object, .predicate = rdf_type, .object = parent_class }, // rdfs3
        .{ .subject = child_property, .predicate = rdfs_sub_property_of, .object = child_property }, // rdfs6
        .{ .subject = child_class, .predicate = rdfs_sub_class_of, .object = child_class }, // rdfs10
        .{ .subject = child_class, .predicate = rdfs_sub_class_of, .object = rdfs_resource }, // rdfs8/11
        .{ .subject = membership_property, .predicate = rdfs_sub_property_of, .object = rdfs_member }, // rdfs12
        .{ .subject = datatype, .predicate = rdfs_sub_class_of, .object = rdfs_literal }, // rdfs13
    };
    for (consequences) |consequence| try std.testing.expect(materialization.contains(consequence));

    const repeated = try materializeRdfsCore(&materialization);
    try std.testing.expectEqual(@as(usize, 0), repeated.inferred);
}

test "mandatory datatype consistency detects disjoint RDFS literal ranges" {
    var materialization = Materialization.init(std.testing.allocator);
    defer materialization.deinit();
    const pool = materialization.termPool();
    const subject = try pool.internNamedNode("https://example.com/subject");
    const predicate = try pool.internNamedNode("https://example.com/predicate");
    const rdfs_range = try pool.internNamedNode(rdf.rdfs_namespace ++ "range");
    const rdf_lang_string = try pool.internNamedNode(rdf.rdf_lang_string);
    const value = try pool.internSimpleLiteral("value");
    _ = try materialization.addAsserted(.{
        .subject = predicate,
        .predicate = rdfs_range,
        .object = rdf_lang_string,
    });
    _ = try materialization.addAsserted(.{
        .subject = subject,
        .predicate = predicate,
        .object = value,
    });

    try std.testing.expect(!isMandatoryDatatypeConsistent(&materialization));
}

test "mandatory datatype consistency accepts matching language values" {
    var materialization = Materialization.init(std.testing.allocator);
    defer materialization.deinit();
    const pool = materialization.termPool();
    const subject = try pool.internNamedNode("https://example.com/subject");
    const predicate = try pool.internNamedNode("https://example.com/predicate");
    const rdfs_range = try pool.internNamedNode(rdf.rdfs_namespace ++ "range");
    const rdf_lang_string = try pool.internNamedNode(rdf.rdf_lang_string);
    const value = try pool.internLanguageLiteral("salut", "ro");
    _ = try materialization.addAsserted(.{
        .subject = predicate,
        .predicate = rdfs_range,
        .object = rdf_lang_string,
    });
    _ = try materialization.addAsserted(.{
        .subject = subject,
        .predicate = predicate,
        .object = value,
    });

    try std.testing.expect(isMandatoryDatatypeConsistent(&materialization));
}

test "rdf:langString without a language tag is inconsistent" {
    var materialization = Materialization.init(std.testing.allocator);
    defer materialization.deinit();
    const pool = materialization.termPool();
    const subject = try pool.internNamedNode("https://example.com/subject");
    const predicate = try pool.internNamedNode("https://example.com/predicate");
    const invalid = try pool.internTypedLiteral("value", rdf.rdf_lang_string);
    _ = try materialization.addAsserted(.{
        .subject = subject,
        .predicate = predicate,
        .object = invalid,
    });

    try std.testing.expect(!isMandatoryDatatypeConsistent(&materialization));
}

test "optional integer datatypes validate only when explicitly recognized" {
    var materialization = Materialization.init(std.testing.allocator);
    defer materialization.deinit();
    const pool = materialization.termPool();
    const subject = try pool.internNamedNode("https://example.com/subject");
    const predicate = try pool.internNamedNode("https://example.com/predicate");
    const invalid = try pool.internTypedLiteral("not-an-integer", rdf.xsd_integer);
    _ = try materialization.addAsserted(.{
        .subject = subject,
        .predicate = predicate,
        .object = invalid,
    });

    try std.testing.expect(isDatatypeConsistent(&materialization, .{}));
    try std.testing.expect(!isDatatypeConsistent(&materialization, .{ .xsd_integer = true }));
}

test "integer lexical spaces and xsd:int bounds are exact" {
    try std.testing.expect(isIntegerLexical("+00042"));
    try std.testing.expect(isIntegerLexical("-999999999999999999999999999"));
    try std.testing.expect(!isIntegerLexical(""));
    try std.testing.expect(!isIntegerLexical(" 3 "));
    try std.testing.expect(!isIntegerLexical("1.0"));
    try std.testing.expect(isIntLexical("-2147483648"));
    try std.testing.expect(isIntLexical("2147483647"));
    try std.testing.expect(!isIntLexical("-2147483649"));
    try std.testing.expect(!isIntLexical("2147483648"));
}

test "recognized integer subtype ranges detect incompatible values" {
    var materialization = Materialization.init(std.testing.allocator);
    defer materialization.deinit();
    const pool = materialization.termPool();
    const subject = try pool.internNamedNode("https://example.com/subject");
    const predicate = try pool.internNamedNode("https://example.com/predicate");
    const rdfs_range = try pool.internNamedNode(rdf.rdfs_namespace ++ "range");
    const xsd_int = try pool.internNamedNode(rdf.xsd_int);
    const value = try pool.internTypedLiteral("2147483648", rdf.xsd_integer);
    _ = try materialization.addAsserted(.{
        .subject = predicate,
        .predicate = rdfs_range,
        .object = xsd_int,
    });
    _ = try materialization.addAsserted(.{
        .subject = subject,
        .predicate = predicate,
        .object = value,
    });

    try std.testing.expect(!isDatatypeConsistent(&materialization, .{
        .xsd_integer = true,
        .xsd_int = true,
    }));
}

test "recognized XMLLiteral rejects incomplete markup" {
    var materialization = Materialization.init(std.testing.allocator);
    defer materialization.deinit();
    const pool = materialization.termPool();
    const subject = try pool.internNamedNode("https://example.com/subject");
    const predicate = try pool.internNamedNode("https://example.com/predicate");
    const invalid = try pool.internTypedLiteral("<", rdf.rdf_xml_literal);
    _ = try materialization.addAsserted(.{
        .subject = subject,
        .predicate = predicate,
        .object = invalid,
    });

    try std.testing.expect(isDatatypeConsistent(&materialization, .{}));
    try std.testing.expect(!isDatatypeConsistent(&materialization, .{
        .rdf_xml_literal = true,
    }));
}

test "recognized decimal values compare independently of lexical form" {
    const profile = DatatypeProfile{ .xsd_integer = true, .xsd_decimal = true };
    const integer = rdf.LiteralView{
        .lexical_form = "+0010",
        .datatype = rdf.xsd_integer,
        .language = null,
    };
    const decimal = rdf.LiteralView{
        .lexical_form = "10.000",
        .datatype = rdf.xsd_decimal,
        .language = null,
    };
    const different = rdf.LiteralView{
        .lexical_form = "10.001",
        .datatype = rdf.xsd_decimal,
        .language = null,
    };
    try std.testing.expect(recognizedLiteralValuesEqual(integer, decimal, profile).?);
    try std.testing.expect(!recognizedLiteralValuesEqual(integer, different, profile).?);
    try std.testing.expect(decimalValuesEqual("-0.0", "+000.000"));
}

test "recognized IEEE values compare after datatype rounding" {
    const float_profile = DatatypeProfile{ .xsd_float = true };
    const rounded_left = rdf.LiteralView{
        .lexical_form = "16777206.5",
        .datatype = rdf.xsd_float,
        .language = null,
    };
    const rounded_right = rdf.LiteralView{
        .lexical_form = "16777205.5",
        .datatype = rdf.xsd_float,
        .language = null,
    };
    const positive_zero = rdf.LiteralView{
        .lexical_form = "0.0",
        .datatype = rdf.xsd_float,
        .language = null,
    };
    const negative_zero = rdf.LiteralView{
        .lexical_form = "-0.0",
        .datatype = rdf.xsd_float,
        .language = null,
    };
    const infinity = rdf.LiteralView{
        .lexical_form = "1E400",
        .datatype = rdf.xsd_float,
        .language = null,
    };
    const explicit_infinity = rdf.LiteralView{
        .lexical_form = "INF",
        .datatype = rdf.xsd_float,
        .language = null,
    };
    const nan = rdf.LiteralView{
        .lexical_form = "NaN",
        .datatype = rdf.xsd_float,
        .language = null,
    };
    try std.testing.expect(recognizedLiteralValuesEqual(rounded_left, rounded_right, float_profile).?);
    try std.testing.expect(!recognizedLiteralValuesEqual(positive_zero, negative_zero, float_profile).?);
    try std.testing.expect(recognizedLiteralValuesEqual(infinity, explicit_infinity, float_profile).?);
    try std.testing.expect(recognizedLiteralValuesEqual(nan, nan, float_profile).?);
}

test "public simple entailment maps conclusion blank nodes existentially" {
    var premise = rdf.Graph.init(std.testing.allocator);
    defer premise.deinit();
    const premise_subject = try premise.terms.internNamedNode("https://example.com/subject");
    const premise_predicate = try premise.terms.internNamedNode("https://example.com/predicate");
    const premise_object = try premise.terms.internNamedNode("https://example.com/object");
    _ = try premise.add(.{
        .subject = premise_subject,
        .predicate = premise_predicate,
        .object = premise_object,
    });

    var conclusion = rdf.Graph.init(std.testing.allocator);
    defer conclusion.deinit();
    const conclusion_subject = try conclusion.terms.internBlankNode("value");
    const conclusion_predicate = try conclusion.terms.internNamedNode("https://example.com/predicate");
    const conclusion_object = try conclusion.terms.internNamedNode("https://example.com/object");
    _ = try conclusion.add(.{
        .subject = conclusion_subject,
        .predicate = conclusion_predicate,
        .object = conclusion_object,
    });

    try std.testing.expect(try entailsGraph(
        std.testing.allocator,
        &premise,
        &conclusion,
        .{ .regime = .simple },
    ));
}

test "public RDF entailment adds target-only container axioms" {
    var premise = rdf.Graph.init(std.testing.allocator);
    defer premise.deinit();
    var conclusion = rdf.Graph.init(std.testing.allocator);
    defer conclusion.deinit();
    const membership = try conclusion.terms.internNamedNode(rdf.rdf_namespace ++ "_7");
    const rdf_type = try conclusion.terms.internNamedNode(rdf.rdf_namespace ++ "type");
    const rdf_property = try conclusion.terms.internNamedNode(rdf.rdf_namespace ++ "Property");
    _ = try conclusion.add(.{
        .subject = membership,
        .predicate = rdf_type,
        .object = rdf_property,
    });

    try std.testing.expect(try entailsGraph(
        std.testing.allocator,
        &premise,
        &conclusion,
        .{ .regime = .rdf },
    ));
}

test "public RDF entailment exposes rdfD1 through an existential conclusion" {
    var premise = rdf.Graph.init(std.testing.allocator);
    defer premise.deinit();
    const premise_subject = try premise.terms.internNamedNode("https://example.com/subject");
    const premise_predicate = try premise.terms.internNamedNode("https://example.com/predicate");
    const literal = try premise.terms.internTypedLiteral("42", rdf.xsd_integer);
    _ = try premise.add(.{
        .subject = premise_subject,
        .predicate = premise_predicate,
        .object = literal,
    });

    var conclusion = rdf.Graph.init(std.testing.allocator);
    defer conclusion.deinit();
    const conclusion_subject = try conclusion.terms.internNamedNode("https://example.com/subject");
    const conclusion_predicate = try conclusion.terms.internNamedNode("https://example.com/predicate");
    const value = try conclusion.terms.internBlankNode("value");
    const rdf_type = try conclusion.terms.internNamedNode(rdf.rdf_namespace ++ "type");
    const xsd_integer = try conclusion.terms.internNamedNode(rdf.xsd_integer);
    _ = try conclusion.add(.{
        .subject = conclusion_subject,
        .predicate = conclusion_predicate,
        .object = value,
    });
    _ = try conclusion.add(.{
        .subject = value,
        .predicate = rdf_type,
        .object = xsd_integer,
    });

    try std.testing.expect(try entailsGraph(
        std.testing.allocator,
        &premise,
        &conclusion,
        .{
            .regime = .rdf,
            .datatypes = .{ .xsd_integer = true },
        },
    ));
}

test "simple entailment backtracks blank-node mappings" {
    var premise = rdf.Graph.init(std.testing.allocator);
    defer premise.deinit();
    const a = try premise.terms.internNamedNode("https://example.com/a");
    const b = try premise.terms.internNamedNode("https://example.com/b");
    const c = try premise.terms.internNamedNode("https://example.com/c");
    const d = try premise.terms.internNamedNode("https://example.com/d");
    const p = try premise.terms.internNamedNode("https://example.com/p");
    const q = try premise.terms.internNamedNode("https://example.com/q");
    _ = try premise.add(.{ .subject = a, .predicate = p, .object = b });
    _ = try premise.add(.{ .subject = c, .predicate = p, .object = b });
    _ = try premise.add(.{ .subject = c, .predicate = q, .object = d });

    var conclusion = rdf.Graph.init(std.testing.allocator);
    defer conclusion.deinit();
    const x = try conclusion.terms.internBlankNode("x");
    const conclusion_b = try conclusion.terms.internNamedNode("https://example.com/b");
    const conclusion_d = try conclusion.terms.internNamedNode("https://example.com/d");
    const conclusion_p = try conclusion.terms.internNamedNode("https://example.com/p");
    const conclusion_q = try conclusion.terms.internNamedNode("https://example.com/q");
    _ = try conclusion.add(.{ .subject = x, .predicate = conclusion_p, .object = conclusion_b });
    _ = try conclusion.add(.{ .subject = x, .predicate = conclusion_q, .object = conclusion_d });

    try std.testing.expect(try entailsGraph(
        std.testing.allocator,
        &premise,
        &conclusion,
        .{ .regime = .simple },
    ));
}

test "simple entailment permits non-injective cyclic blank-node mappings" {
    var premise = rdf.Graph.init(std.testing.allocator);
    defer premise.deinit();
    const a = try premise.terms.internNamedNode("https://example.com/a");
    const predicate = try premise.terms.internNamedNode("https://example.com/p");
    _ = try premise.add(.{ .subject = a, .predicate = predicate, .object = a });

    var conclusion = rdf.Graph.init(std.testing.allocator);
    defer conclusion.deinit();
    const x = try conclusion.terms.internBlankNode("x");
    const y = try conclusion.terms.internBlankNode("y");
    const conclusion_predicate = try conclusion.terms.internNamedNode("https://example.com/p");
    _ = try conclusion.add(.{ .subject = x, .predicate = conclusion_predicate, .object = y });
    _ = try conclusion.add(.{ .subject = y, .predicate = conclusion_predicate, .object = x });

    try std.testing.expect(try entailsGraph(
        std.testing.allocator,
        &premise,
        &conclusion,
        .{ .regime = .simple },
    ));
}

test "simple entailment rejects inconsistent shared blank-node mappings" {
    var premise = rdf.Graph.init(std.testing.allocator);
    defer premise.deinit();
    const a = try premise.terms.internNamedNode("https://example.com/a");
    const b = try premise.terms.internNamedNode("https://example.com/b");
    const c = try premise.terms.internNamedNode("https://example.com/c");
    const d = try premise.terms.internNamedNode("https://example.com/d");
    const predicate = try premise.terms.internNamedNode("https://example.com/p");
    _ = try premise.add(.{ .subject = a, .predicate = predicate, .object = b });
    _ = try premise.add(.{ .subject = c, .predicate = predicate, .object = d });

    var conclusion = rdf.Graph.init(std.testing.allocator);
    defer conclusion.deinit();
    const x = try conclusion.terms.internBlankNode("x");
    const conclusion_b = try conclusion.terms.internNamedNode("https://example.com/b");
    const conclusion_d = try conclusion.terms.internNamedNode("https://example.com/d");
    const conclusion_predicate = try conclusion.terms.internNamedNode("https://example.com/p");
    _ = try conclusion.add(.{ .subject = x, .predicate = conclusion_predicate, .object = conclusion_b });
    _ = try conclusion.add(.{ .subject = x, .predicate = conclusion_predicate, .object = conclusion_d });

    try std.testing.expect(!(try entailsGraph(
        std.testing.allocator,
        &premise,
        &conclusion,
        .{ .regime = .simple },
    )));
}

fn exerciseSimpleEntailmentAllocations(allocator: std.mem.Allocator) !void {
    var premise = rdf.Graph.init(allocator);
    defer premise.deinit();
    const subject = try premise.terms.internNamedNode("https://example.com/subject");
    const predicate = try premise.terms.internNamedNode("https://example.com/predicate");
    const object = try premise.terms.internNamedNode("https://example.com/object");
    _ = try premise.add(.{ .subject = subject, .predicate = predicate, .object = object });

    var conclusion = rdf.Graph.init(allocator);
    defer conclusion.deinit();
    const blank = try conclusion.terms.internBlankNode("value");
    const conclusion_predicate = try conclusion.terms.internNamedNode("https://example.com/predicate");
    const conclusion_object = try conclusion.terms.internNamedNode("https://example.com/object");
    _ = try conclusion.add(.{
        .subject = blank,
        .predicate = conclusion_predicate,
        .object = conclusion_object,
    });
    if (!try entailsGraph(allocator, &premise, &conclusion, .{ .regime = .simple })) {
        return error.TestUnexpectedResult;
    }
}

test "simple entailment handles every allocation failure without leaks" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseSimpleEntailmentAllocations,
        .{},
    );
}

fn exerciseRdfEntailmentAllocations(allocator: std.mem.Allocator) !void {
    var premise = rdf.Graph.init(allocator);
    defer premise.deinit();
    const subject = try premise.terms.internNamedNode("https://example.com/subject");
    const predicate = try premise.terms.internNamedNode("https://example.com/predicate");
    const literal = try premise.terms.internTypedLiteral("42", rdf.xsd_integer);
    _ = try premise.add(.{ .subject = subject, .predicate = predicate, .object = literal });

    var conclusion = rdf.Graph.init(allocator);
    defer conclusion.deinit();
    const conclusion_subject = try conclusion.terms.internNamedNode("https://example.com/subject");
    const conclusion_predicate = try conclusion.terms.internNamedNode("https://example.com/predicate");
    const value = try conclusion.terms.internBlankNode("value");
    _ = try conclusion.add(.{
        .subject = conclusion_subject,
        .predicate = conclusion_predicate,
        .object = value,
    });
    if (!try entailsGraph(allocator, &premise, &conclusion, .{
        .regime = .rdf,
        .datatypes = .{ .xsd_integer = true },
    })) return error.TestUnexpectedResult;
}

test "RDF entailment handles every allocation failure without leaks" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseRdfEntailmentAllocations,
        .{},
    );
}

fn exerciseRdfsEntailmentAllocations(allocator: std.mem.Allocator) !void {
    var premise = rdf.Graph.init(allocator);
    defer premise.deinit();
    const subject = try premise.terms.internNamedNode("https://example.com/subject");
    const child_property = try premise.terms.internNamedNode("https://example.com/child");
    const parent_property = try premise.terms.internNamedNode("https://example.com/parent");
    const object = try premise.terms.internNamedNode("https://example.com/object");
    const domain = try premise.terms.internNamedNode("https://example.com/Domain");
    const sub_property = try premise.terms.internNamedNode(rdf.rdfs_namespace ++ "subPropertyOf");
    const rdfs_domain = try premise.terms.internNamedNode(rdf.rdfs_namespace ++ "domain");
    _ = try premise.add(.{ .subject = child_property, .predicate = sub_property, .object = parent_property });
    _ = try premise.add(.{ .subject = parent_property, .predicate = rdfs_domain, .object = domain });
    _ = try premise.add(.{ .subject = subject, .predicate = child_property, .object = object });

    var conclusion = rdf.Graph.init(allocator);
    defer conclusion.deinit();
    const conclusion_subject = try conclusion.terms.internNamedNode("https://example.com/subject");
    const rdf_type = try conclusion.terms.internNamedNode(rdf.rdf_namespace ++ "type");
    const conclusion_domain = try conclusion.terms.internNamedNode("https://example.com/Domain");
    _ = try conclusion.add(.{
        .subject = conclusion_subject,
        .predicate = rdf_type,
        .object = conclusion_domain,
    });
    if (!try entailsGraph(allocator, &premise, &conclusion, .{ .regime = .rdfs })) {
        return error.TestUnexpectedResult;
    }
}

test "RDFS entailment handles every allocation failure without leaks" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseRdfsEntailmentAllocations,
        .{},
    );
}

fn exerciseConsistencyAllocations(allocator: std.mem.Allocator) !void {
    var premise = rdf.Graph.init(allocator);
    defer premise.deinit();
    const subject = try premise.terms.internNamedNode("https://example.com/subject");
    const predicate = try premise.terms.internNamedNode("https://example.com/predicate");
    const literal = try premise.terms.internTypedLiteral("value", rdf.rdf_lang_string);
    _ = try premise.add(.{ .subject = subject, .predicate = predicate, .object = literal });
    if (try isGraphConsistent(allocator, &premise, .{ .regime = .rdf })) {
        return error.TestUnexpectedResult;
    }
}

test "consistency checking handles every allocation failure without leaks" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseConsistencyAllocations,
        .{},
    );
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
    _ = try materializeRdfsContainerMembership(&materialization, &graph);
}

test "graph materialization handles every allocation failure without leaks" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseMaterializationAllocations,
        .{},
    );
}

fn exerciseRdfsCoreAllocations(allocator: std.mem.Allocator) !void {
    var materialization = Materialization.init(allocator);
    defer materialization.deinit();
    _ = try materializeRdfsCore(&materialization);
}

test "RDFS core handles every allocation failure without leaks" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseRdfsCoreAllocations,
        .{},
    );
}

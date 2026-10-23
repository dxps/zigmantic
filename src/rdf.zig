//! RDF 1.1 core data model.
//!
//! `TermPool` owns all string and term memory. Graphs and datasets store compact
//! identifiers issued by their own pool; identifiers must never be mixed between
//! owners. Callers can inspect an identifier through `TermPool.view` while the
//! pool remains alive.

const std = @import("std");

pub const rdf_namespace = "http://www.w3.org/1999/02/22-rdf-syntax-ns#";
pub const rdf_lang_string = rdf_namespace ++ "langString";
pub const xsd_namespace = "http://www.w3.org/2001/XMLSchema#";
pub const xsd_string = xsd_namespace ++ "string";

pub const StringId = enum(u32) { _ };
pub const TermId = enum(u32) { _ };

pub const Error = std.mem.Allocator.Error || error{
    InvalidBlankNodeIdentifier,
    InvalidGraphName,
    InvalidIri,
    InvalidLanguageTag,
    InvalidPredicate,
    InvalidSubject,
    InvalidUtf8,
    UnknownTerm,
};

pub const Literal = struct {
    lexical_form: StringId,
    datatype: StringId,
    language: ?StringId = null,
};

pub const Term = union(enum) {
    named_node: StringId,
    blank_node: StringId,
    literal: Literal,
};

pub const LiteralView = struct {
    lexical_form: []const u8,
    datatype: []const u8,
    language: ?[]const u8,
};

pub const TermView = union(enum) {
    named_node: []const u8,
    blank_node: []const u8,
    literal: LiteralView,
};

pub const TermPool = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    string_ids: std.StringHashMapUnmanaged(StringId) = .empty,
    strings: std.ArrayList([]const u8) = .empty,
    terms: std.ArrayList(Term) = .empty,

    pub fn init(allocator: std.mem.Allocator) TermPool {
        return .{
            .allocator = allocator,
            .arena = .init(allocator),
        };
    }

    pub fn deinit(self: *TermPool) void {
        self.terms.deinit(self.allocator);
        self.strings.deinit(self.allocator);
        self.string_ids.deinit(self.allocator);
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn internNamedNode(self: *TermPool, iri: []const u8) Error!TermId {
        if (!isAbsoluteIri(iri)) return error.InvalidIri;
        return self.internTerm(.{ .named_node = try self.internString(iri) });
    }

    pub fn internBlankNode(self: *TermPool, identifier: []const u8) Error!TermId {
        if (!isBlankNodeIdentifier(identifier)) return error.InvalidBlankNodeIdentifier;
        return self.internTerm(.{ .blank_node = try self.internString(identifier) });
    }

    pub fn internSimpleLiteral(self: *TermPool, lexical_form: []const u8) Error!TermId {
        return self.internTypedLiteral(lexical_form, xsd_string);
    }

    pub fn internTypedLiteral(
        self: *TermPool,
        lexical_form: []const u8,
        datatype_iri: []const u8,
    ) Error!TermId {
        if (!std.unicode.utf8ValidateSlice(lexical_form)) return error.InvalidUtf8;
        if (!isAbsoluteIri(datatype_iri)) return error.InvalidIri;

        return self.internTerm(.{ .literal = .{
            .lexical_form = try self.internString(lexical_form),
            .datatype = try self.internString(datatype_iri),
        } });
    }

    pub fn internLanguageLiteral(
        self: *TermPool,
        lexical_form: []const u8,
        language: []const u8,
    ) Error!TermId {
        if (!std.unicode.utf8ValidateSlice(lexical_form)) return error.InvalidUtf8;
        if (!isLanguageTag(language)) return error.InvalidLanguageTag;

        const normalized = try self.allocator.alloc(u8, language.len);
        defer self.allocator.free(normalized);
        for (language, 0..) |byte, index| normalized[index] = std.ascii.toLower(byte);

        return self.internTerm(.{ .literal = .{
            .lexical_form = try self.internString(lexical_form),
            .datatype = try self.internString(rdf_lang_string),
            .language = try self.internString(normalized),
        } });
    }

    pub fn get(self: *const TermPool, id: TermId) ?Term {
        const index: usize = @backingInt(id);
        if (index >= self.terms.items.len) return null;
        return self.terms.items[index];
    }

    pub fn view(self: *const TermPool, id: TermId) ?TermView {
        const term = self.get(id) orelse return null;
        return switch (term) {
            .named_node => |string_id| .{ .named_node = self.string(string_id).? },
            .blank_node => |string_id| .{ .blank_node = self.string(string_id).? },
            .literal => |literal| .{ .literal = .{
                .lexical_form = self.string(literal.lexical_form).?,
                .datatype = self.string(literal.datatype).?,
                .language = if (literal.language) |language| self.string(language).? else null,
            } },
        };
    }

    pub fn count(self: *const TermPool) usize {
        return self.terms.items.len;
    }

    fn string(self: *const TermPool, id: StringId) ?[]const u8 {
        const index: usize = @backingInt(id);
        if (index >= self.strings.items.len) return null;
        return self.strings.items[index];
    }

    fn internString(self: *TermPool, value: []const u8) std.mem.Allocator.Error!StringId {
        if (self.string_ids.get(value)) |id| return id;

        const owned = try self.arena.allocator().dupe(u8, value);
        errdefer self.arena.allocator().free(owned);

        const id: StringId = @fromBackingInt(@intCast(self.strings.items.len));
        try self.strings.append(self.allocator, owned);
        errdefer _ = self.strings.pop();
        try self.string_ids.put(self.allocator, owned, id);
        return id;
    }

    fn internTerm(self: *TermPool, candidate: Term) std.mem.Allocator.Error!TermId {
        for (self.terms.items, 0..) |term, index| {
            if (std.meta.eql(term, candidate)) return @fromBackingInt(@intCast(index));
        }

        const id: TermId = @fromBackingInt(@intCast(self.terms.items.len));
        try self.terms.append(self.allocator, candidate);
        return id;
    }
};

pub const Triple = struct {
    subject: TermId,
    predicate: TermId,
    object: TermId,
};

pub const GraphName = union(enum) {
    default,
    named: TermId,
};

pub const Quad = struct {
    subject: TermId,
    predicate: TermId,
    object: TermId,
    graph_name: GraphName = .default,
};

pub const Graph = struct {
    allocator: std.mem.Allocator,
    terms: TermPool,
    triples: std.ArrayList(Triple) = .empty,

    pub fn init(allocator: std.mem.Allocator) Graph {
        return .{
            .allocator = allocator,
            .terms = .init(allocator),
        };
    }

    pub fn deinit(self: *Graph) void {
        self.triples.deinit(self.allocator);
        self.terms.deinit();
        self.* = undefined;
    }

    pub fn add(self: *Graph, triple: Triple) Error!bool {
        try validateTriple(&self.terms, triple);
        for (self.triples.items) |existing| {
            if (std.meta.eql(existing, triple)) return false;
        }
        try self.triples.append(self.allocator, triple);
        return true;
    }

    pub fn contains(self: *const Graph, triple: Triple) bool {
        for (self.triples.items) |existing| {
            if (std.meta.eql(existing, triple)) return true;
        }
        return false;
    }

    pub fn len(self: *const Graph) usize {
        return self.triples.items.len;
    }

    pub fn items(self: *const Graph) []const Triple {
        return self.triples.items;
    }
};

pub const Dataset = struct {
    allocator: std.mem.Allocator,
    terms: TermPool,
    quads: std.ArrayList(Quad) = .empty,

    pub fn init(allocator: std.mem.Allocator) Dataset {
        return .{
            .allocator = allocator,
            .terms = .init(allocator),
        };
    }

    pub fn deinit(self: *Dataset) void {
        self.quads.deinit(self.allocator);
        self.terms.deinit();
        self.* = undefined;
    }

    pub fn add(self: *Dataset, quad: Quad) Error!bool {
        try validateTriple(&self.terms, .{
            .subject = quad.subject,
            .predicate = quad.predicate,
            .object = quad.object,
        });
        try validateGraphName(&self.terms, quad.graph_name);

        for (self.quads.items) |existing| {
            if (std.meta.eql(existing, quad)) return false;
        }
        try self.quads.append(self.allocator, quad);
        return true;
    }

    pub fn addDefault(self: *Dataset, triple: Triple) Error!bool {
        return self.add(.{
            .subject = triple.subject,
            .predicate = triple.predicate,
            .object = triple.object,
        });
    }

    pub fn contains(self: *const Dataset, quad: Quad) bool {
        for (self.quads.items) |existing| {
            if (std.meta.eql(existing, quad)) return true;
        }
        return false;
    }

    pub fn len(self: *const Dataset) usize {
        return self.quads.items.len;
    }

    pub fn items(self: *const Dataset) []const Quad {
        return self.quads.items;
    }
};

fn validateTriple(pool: *const TermPool, triple: Triple) Error!void {
    const subject = pool.get(triple.subject) orelse return error.UnknownTerm;
    const predicate = pool.get(triple.predicate) orelse return error.UnknownTerm;
    _ = pool.get(triple.object) orelse return error.UnknownTerm;

    switch (subject) {
        .named_node, .blank_node => {},
        .literal => return error.InvalidSubject,
    }
    if (predicate != .named_node) return error.InvalidPredicate;
}

fn validateGraphName(pool: *const TermPool, graph_name: GraphName) Error!void {
    switch (graph_name) {
        .default => {},
        .named => |id| switch (pool.get(id) orelse return error.UnknownTerm) {
            .named_node, .blank_node => {},
            .literal => return error.InvalidGraphName,
        },
    }
}

fn isAbsoluteIri(value: []const u8) bool {
    if (value.len == 0 or !std.unicode.utf8ValidateSlice(value)) return false;

    var colon: ?usize = null;
    for (value, 0..) |byte, index| {
        if (byte <= 0x20 or byte == 0x7f) return false;
        switch (byte) {
            '<', '>', '"', '{', '}', '|', '^', '`', '\\' => return false,
            ':' => if (colon == null) {
                colon = index;
            },
            '/', '?', '#' => if (colon == null) return false,
            else => {},
        }
    }

    const end = colon orelse return false;
    if (end == 0 or !std.ascii.isAlphabetic(value[0])) return false;
    for (value[1..end]) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '+' or byte == '-' or byte == '.')) {
            return false;
        }
    }
    return true;
}

fn isBlankNodeIdentifier(value: []const u8) bool {
    if (value.len == 0 or !std.unicode.utf8ValidateSlice(value)) return false;
    for (value) |byte| {
        if (std.ascii.isWhitespace(byte) or std.ascii.isControl(byte)) return false;
    }
    return true;
}

fn isLanguageTag(value: []const u8) bool {
    if (value.len == 0) return false;
    var previous_hyphen = true;
    for (value) |byte| {
        if (byte == '-') {
            if (previous_hyphen) return false;
            previous_hyphen = true;
        } else if (std.ascii.isAlphanumeric(byte)) {
            previous_hyphen = false;
        } else {
            return false;
        }
    }
    return !previous_hyphen;
}

test "term pool interns RDF terms and exposes borrowed views" {
    var pool = TermPool.init(std.testing.allocator);
    defer pool.deinit();

    const first = try pool.internNamedNode("https://example.com/resource");
    const duplicate = try pool.internNamedNode("https://example.com/resource");
    try std.testing.expectEqual(first, duplicate);
    try std.testing.expectEqual(@as(usize, 1), pool.count());

    const view = pool.view(first).?;
    try std.testing.expectEqualStrings("https://example.com/resource", view.named_node);
}

test "simple and language literals have their RDF 1.1 datatypes" {
    var pool = TermPool.init(std.testing.allocator);
    defer pool.deinit();

    const simple = try pool.internSimpleLiteral("hello");
    const simple_view = pool.view(simple).?.literal;
    try std.testing.expectEqualStrings("hello", simple_view.lexical_form);
    try std.testing.expectEqualStrings(xsd_string, simple_view.datatype);
    try std.testing.expectEqual(@as(?[]const u8, null), simple_view.language);

    const language = try pool.internLanguageLiteral("salut", "RO-Latn");
    const duplicate = try pool.internLanguageLiteral("salut", "ro-latn");
    try std.testing.expectEqual(language, duplicate);

    const language_view = pool.view(language).?.literal;
    try std.testing.expectEqualStrings(rdf_lang_string, language_view.datatype);
    try std.testing.expectEqualStrings("ro-latn", language_view.language.?);
}

test "term constructors reject structurally invalid values" {
    var pool = TermPool.init(std.testing.allocator);
    defer pool.deinit();

    try std.testing.expectError(error.InvalidIri, pool.internNamedNode("relative/path"));
    try std.testing.expectError(error.InvalidIri, pool.internNamedNode("https://example.com/a b"));
    try std.testing.expectError(error.InvalidBlankNodeIdentifier, pool.internBlankNode(""));
    try std.testing.expectError(error.InvalidLanguageTag, pool.internLanguageLiteral("hello", "en--GB"));
}

test "graph has set semantics and validates triple positions" {
    var graph = Graph.init(std.testing.allocator);
    defer graph.deinit();

    const subject = try graph.terms.internNamedNode("https://example.com/alice");
    const predicate = try graph.terms.internNamedNode("https://example.com/name");
    const object = try graph.terms.internSimpleLiteral("Alice");
    const triple = Triple{ .subject = subject, .predicate = predicate, .object = object };

    try std.testing.expect(try graph.add(triple));
    try std.testing.expect(!(try graph.add(triple)));
    try std.testing.expectEqual(@as(usize, 1), graph.len());
    try std.testing.expect(graph.contains(triple));

    try std.testing.expectError(error.InvalidSubject, graph.add(.{
        .subject = object,
        .predicate = predicate,
        .object = subject,
    }));
    try std.testing.expectError(error.InvalidPredicate, graph.add(.{
        .subject = subject,
        .predicate = object,
        .object = subject,
    }));
}

test "dataset supports default, IRI-named, and blank-node-named graphs" {
    var dataset = Dataset.init(std.testing.allocator);
    defer dataset.deinit();

    const subject = try dataset.terms.internNamedNode("https://example.com/alice");
    const predicate = try dataset.terms.internNamedNode("https://example.com/knows");
    const object = try dataset.terms.internBlankNode("bob");
    const graph_iri = try dataset.terms.internNamedNode("https://example.com/graph");
    const graph_blank = try dataset.terms.internBlankNode("graph");
    const literal = try dataset.terms.internSimpleLiteral("not a graph name");

    const triple = Triple{ .subject = subject, .predicate = predicate, .object = object };
    try std.testing.expect(try dataset.addDefault(triple));
    try std.testing.expect(try dataset.add(.{
        .subject = subject,
        .predicate = predicate,
        .object = object,
        .graph_name = .{ .named = graph_iri },
    }));
    try std.testing.expect(try dataset.add(.{
        .subject = subject,
        .predicate = predicate,
        .object = object,
        .graph_name = .{ .named = graph_blank },
    }));
    try std.testing.expectEqual(@as(usize, 3), dataset.len());

    try std.testing.expectError(error.InvalidGraphName, dataset.add(.{
        .subject = subject,
        .predicate = predicate,
        .object = object,
        .graph_name = .{ .named = literal },
    }));
}
